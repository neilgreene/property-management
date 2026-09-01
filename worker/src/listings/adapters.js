// =====================================================================
// listings/adapters.js  |  where a listing's status comes from
// =====================================================================
// One interface, four implementations, none of which the reconciler knows
// anything about:
//
//     async check({ external_id, external_url, property }) ->
//         { outcome, raw_status?, list_price?, payload?, error? }
//
//     outcome: 'found'   we read it
//              'missing' the source answered and it was not there
//              'error'   we could not tell
//
// The distinction between 'missing' and 'error' is the one that matters.
// An adapter that reports a timeout as 'missing' will, over one bad
// night, walk the entire portfolio to withdrawn. When in doubt an adapter
// MUST return 'error': the reconciler ignores errors and acts on
// absences, so the cost of the two mistakes is not symmetric.
//
// Nothing here maps status vocabulary. The adapter reports the source's
// own word and feed.status_map translates it, so adding a term a portal
// invented last week is a row in a table, not a release.
'use strict';

// ---------------------------------------------------------------------
// MANUAL -- the one that works today
//
// A person checked, and told us. Reads from a queue table rather than the
// network. This is not a placeholder for a real integration: for a
// portfolio of two dozen properties a staff member with a browser IS the
// integration, and it is authoritative in a way no feed is.
// ---------------------------------------------------------------------
function manualAdapter(db) {
  return {
    code: 'MANUAL',
    async check({ property_id }) {
      const { rows } = await db.query(
        `SELECT raw_status, list_price, noted_at
           FROM feed.manual_check
          WHERE property_id = $1 AND consumed_at IS NULL
          ORDER BY noted_at
          LIMIT 1`, [property_id]);
      if (!rows.length) return { outcome: 'error', error: 'no manual check pending' };
      await db.query(
        `UPDATE feed.manual_check SET consumed_at = now()
          WHERE property_id = $1 AND consumed_at IS NULL`, [property_id]);
      return { outcome: 'found', raw_status: rows[0].raw_status,
               list_price: rows[0].list_price, payload: { via: 'staff' } };
    },
  };
}

// ---------------------------------------------------------------------
// RESO Web API -- the one that is correct
//
// The industry standard, served by essentially every modern MLS, and the
// reason feed.status_map is complete for MLS_RESO: StandardStatus is a
// closed enumeration.
//
// Not reachable without credentials, and credentials mean an MLS
// membership or approved vendor status plus a signed data agreement. So
// this is written and untested against a live feed -- the query shape and
// the field names are the standard's, and the first live run will find
// whatever the local MLS does differently. That is expected; it is why
// confirm_after is 2 for this source.
// ---------------------------------------------------------------------
function resoAdapter({ baseUrl, token, fetchImpl = fetch, timeoutMs = 15000 }) {
  return {
    code: 'MLS_RESO',
    async check({ external_id }) {
      if (!baseUrl || !token) return { outcome: 'error', error: 'RESO not configured' };
      const url = `${baseUrl.replace(/\/$/, '')}/Property('${encodeURIComponent(external_id)}')`
                + '?$select=ListingKey,StandardStatus,MlsStatus,ListPrice,ModificationTimestamp';
      const ctl = AbortController ? new AbortController() : null;
      const timer = ctl && setTimeout(() => ctl.abort(), timeoutMs);
      try {
        const r = await fetchImpl(url, {
          headers: { Authorization: `Bearer ${token}`, Accept: 'application/json' },
          signal: ctl && ctl.signal,
        });
        // 404 is the one status that means the listing is genuinely not
        // in the feed. Every other failure is 'error'.
        if (r.status === 404) return { outcome: 'missing', payload: { http: 404 } };
        if (!r.ok) return { outcome: 'error', error: `HTTP ${r.status}` };
        const j = await r.json();
        const raw = j.StandardStatus || j.MlsStatus;
        if (!raw) return { outcome: 'error', error: 'no status field in response' };
        return { outcome: 'found', raw_status: raw, list_price: j.ListPrice ?? null, payload: j };
      } catch (e) {
        return { outcome: 'error', error: e.name === 'AbortError' ? 'timeout' : e.message };
      } finally { if (timer) clearTimeout(timer); }
    },
  };
}

// ---------------------------------------------------------------------
// RentCast -- the one available without an MLS membership
//
// Self-serve API key, property records and rent estimates. Listing status
// is derivative here rather than primary, which is why the source row
// marks it advisory: it is good enough to raise a flag and not good
// enough to retire a listing unattended.
// ---------------------------------------------------------------------
function rentcastAdapter({ baseUrl = 'https://api.rentcast.io/v1', apiKey,
                           fetchImpl = fetch, timeoutMs = 15000 }) {
  return {
    code: 'RENTCAST',
    async check({ property }) {
      if (!apiKey) return { outcome: 'error', error: 'RentCast not configured' };
      const addr = [property.street_address, property.city, property.state, property.zip]
        .filter(Boolean).join(', ');
      const url = `${baseUrl}/listings/sale?address=${encodeURIComponent(addr)}&status=Active`;
      const ctl = AbortController ? new AbortController() : null;
      const timer = ctl && setTimeout(() => ctl.abort(), timeoutMs);
      try {
        const r = await fetchImpl(url, { headers: { 'X-Api-Key': apiKey },
                                         signal: ctl && ctl.signal });
        if (!r.ok) return { outcome: 'error', error: `HTTP ${r.status}` };
        const j = await r.json();
        const hit = Array.isArray(j) ? j[0] : j;
        if (!hit) return { outcome: 'missing', payload: { matched: 0 } };
        return { outcome: 'found', raw_status: hit.status || 'Active',
                 list_price: hit.price ?? null, payload: hit };
      } catch (e) {
        return { outcome: 'error', error: e.name === 'AbortError' ? 'timeout' : e.message };
      } finally { if (timer) clearTimeout(timer); }
    },
  };
}

// ---------------------------------------------------------------------
// Consumer portal -- the one people ask for, disabled
//
// Left as a named, wired-in seam rather than an implementation, and it
// stays that way for a reason that is engineering before it is legal:
// a scraper cannot reliably distinguish "this listing is gone" from "the
// page changed shape". Both render as a missing selector. A source whose
// most common failure mode is indistinguishable from its most destructive
// signal must never be authoritative, so even a working one would be
// pinned to advisory and barred from retiring a listing -- which is
// exactly what feed.listing_source already says about PORTAL_SCRAPE.
//
// If it is ever implemented, those two flags stay where they are.
// ---------------------------------------------------------------------
function portalAdapter() {
  return {
    code: 'PORTAL_SCRAPE',
    async check() {
      return { outcome: 'error',
               error: 'portal adapter not implemented; source is advisory and inactive' };
    },
  };
}

function build(db, env = process.env) {
  const all = [
    manualAdapter(db),
    resoAdapter({ baseUrl: env.RESO_BASE_URL, token: env.RESO_TOKEN }),
    rentcastAdapter({ apiKey: env.RENTCAST_API_KEY }),
    portalAdapter(),
  ];
  return new Map(all.map((a) => [a.code, a]));
}

module.exports = { build, manualAdapter, resoAdapter, rentcastAdapter, portalAdapter };
