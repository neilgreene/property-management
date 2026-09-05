// =====================================================================
// server.js  |  SDI visibility demo
// =====================================================================
// The whole point of this file is how little it does. It never filters,
// never masks, never checks a role. It opens a transaction, declares who
// is asking, runs one fixed query, and returns whatever the database
// chose to hand back.
// =====================================================================

const http = require('http');
const fs   = require('fs');
const path = require('path');
const { Pool } = require('pg');
const auth  = require('./auth');
const media = require('./media');
const nlq   = require('./nlq');
const images = require('./images');
const share  = require('./share');

const pool = new Pool({
  host:     process.env.PGHOST     || 'localhost',
  port:     process.env.PGPORT     || 5432,
  database: process.env.PGDATABASE || 'sdi',
  user:     process.env.PGUSER     || 'sdi_app',
  password: process.env.PGPASSWORD || 'demo_app_pw',
  max: 8,
});

// Where uploaded and ingested photographs live. A shared mount in
// production, so it is deliberately outside the image and outside
// web/public/ -- nothing here is reachable by path, only through
// /media/file/<media_id> after the database has authorised the caller.
const MEDIA_ROOT = path.resolve(process.env.SDI_MEDIA_ROOT || '/srv/media');

// Personas are a demo affordance only. In production this mapping comes
// out of the session/JWT after authentication; the database contract is
// identical either way.
const PERSONAS = {
  anon:   { label: 'Not signed in',  role: 'sdi_public',   actor: null,
            note: 'Anonymous browser' },
  marcus: { label: 'Marcus Pell',    role: 'sdi_investor',
            actor: '22222222-2222-2222-2222-222222222222',
            note: 'Investor — fee agreement not signed' },
  ruth:   { label: 'Ruth Okonkwo',   role: 'sdi_investor',
            actor: '11111111-1111-1111-1111-111111111111',
            note: 'Investor — fee agreement signed' },
  tom:    { label: 'Tom Bradbury',   role: 'sdi_agent',
            actor: '44444444-4444-4444-4444-444444444444',
            note: 'Agent — 4 assigned properties' },
  dan:    { label: 'Dan Beitor',     role: 'sdi_admin',
            actor: '66666666-6666-6666-6666-666666666666',
            note: 'Internal staff' },
  jessica:{ label: 'Jessica Pool',   role: 'sdi_admin',
            actor: '77777777-7777-7777-7777-777777777777',
            note: 'Internal staff — admin' },
};

// This string is a constant. It is the argument the demo is making:
// every persona below runs these exact characters.
const LISTING_SQL = `SELECT listing_ref, status, city, state, property_type,
       beds, baths, sqft, list_price, cap_rate, noi_annual,
       street_address, unit, parcel_number, lat, lng,
       address_unlocked, brand_service_tier, brand_platform_fee
FROM   api.property
ORDER  BY listing_ref`;

const INTERNAL_SQL = `SELECT listing_ref, acquisition_cost, source_channel,
       internal_notes, gross_margin
FROM   api.property_internal
ORDER  BY listing_ref`;

// Demo personas are a switch, not the default. They exist because showing
// Ruth and Marcus side by side is the clearest way to demonstrate the model
// to someone non-technical -- but a dropdown that hands out an admin session
// must never be reachable by accident. Off unless explicitly enabled.
const DEMO_PERSONAS = process.env.DEMO_PERSONAS === '1';

// Identity: { role: <db role>, actor: <person uuid|null>, label }
// Produced either by a real session or, when enabled, by a demo persona.
async function runAs(identity, brand) {
  const p = identity;
  if (!p || !p.role) throw new Error('no identity');

  const client = await pool.connect();
  try {
    await client.query('BEGIN');

    // SET LOCAL ROLE, not SET ROLE. Reverts at COMMIT, so a pooled
    // connection cannot carry one user's identity into the next request.
    await client.query(`SET LOCAL ROLE ${p.role}`);

    // Transaction-local context, parameterised. Never string-built --
    // this value decides what the caller can see.
    await client.query(
      `SELECT set_config('app.actor_id', $1, true),
              set_config('app.brand',    $2, true)`,
      [p.actor || '', brand]
    );

    const listings = await client.query(LISTING_SQL);

    // Attempted for every persona on purpose. Non-admins get a hard
    // "permission denied" from the ACL, which is worth showing.
    let internal = null, internalError = null;
    try {
      const r = await client.query(INTERNAL_SQL);
      internal = r.rows;
    } catch (e) {
      internalError = e.message;
    }

    let invariants = null;
    try {
      const r = await client.query('SELECT * FROM api.security_invariants()');
      invariants = r.rows;
    } catch (e) { /* not admin; expected */ }

    await client.query('COMMIT');
    return {
      persona: p,
      brand,
      sql: LISTING_SQL,
      internalSql: INTERNAL_SQL,
      rows: listings.rows,
      internal, internalError, invariants,
    };
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    throw e;
  } finally {
    client.release();
  }
}

// Demonstrates that going around the api schema fails at the database,
// not at some allowlist in this file.
// Reads a request body, capped. The login route is the only thing that
// takes one, and an uncapped read on an unauthenticated endpoint is a
// free way to make the process eat memory.
// The default is small on purpose: every route here takes a short JSON
// object, and an uncapped read on an unauthenticated endpoint is a way to
// exhaust memory from outside. A route that legitimately receives more --
// an uploaded photograph -- passes its own limit and says why.
//
// OVER-LIMIT DRAINS RATHER THAN DESTROYS. Destroying the socket the moment
// the cap is passed means the caller never receives a response at all: the
// browser reports a network failure, the page has no status code to react
// to, and the person sees nothing happen. Draining costs the tail of one
// request and buys a 413 somebody can read. Past a hard ceiling it is a
// flood rather than a large upload, and then the socket does go.
function readBody(req, limit = 8192) {
  return new Promise((resolve, reject) => {
    const chunks = []; let size = 0; let over = false;
    const ceiling = limit * 4;
    req.on('data', (c) => {
      size += c.length;
      if (over) { if (size > ceiling) req.destroy(); return; }
      if (size > limit) {
        over = true;
        const e = new Error('body too large');
        e.code = 'BODY_TOO_LARGE';
        req.resume();
        return reject(e);
      }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

// A photograph, base64'd inside a JSON object. images.MAX_INPUT caps the
// DECODED bytes at 8 MB; base64 inflates by a third, and the JSON wrapper
// adds a little, so the transport limit has to be meaningfully higher than
// the limit that actually matters. Setting them equal is how an upload that
// passes every stated check dies in the plumbing.
const UPLOAD_LIMIT = 12 * 1024 * 1024;

// Filtered listings.
//
// Every filter is a bound parameter appended to a query against api.property,
// never string-built and never applied in JavaScript after the fact. Two
// consequences worth being explicit about:
//
//   A filter can only ever NARROW what the caller was already allowed to see.
//   The view's masking and the table's row policies run first; these clauses
//   run inside that result. There is no filter value that widens it.
//
//   Filtering in the database rather than the browser means a listing the
//   caller cannot see is never sent and then hidden. It is not sent.
const FILTERS = [
  ['min_price', 'p.list_price >= $', Number],
  ['max_price', 'p.list_price <= $', Number],
  ['min_beds',  'p.beds       >= $', Number],
  ['max_beds',  'p.beds       <= $', Number],
  ['min_baths', 'p.baths      >= $', Number],
  ['max_baths', 'p.baths      <= $', Number],
  ['min_sqft',  'p.sqft       >= $', Number],
  ['max_sqft',  'p.sqft       <= $', Number],
];

// Non-numeric filters. Same rule: an allowlisted clause, a bound value.
const TEXT_FILTERS = [
  ['city',          'p.city          = $'],
  ['state',         'p.state         = $'],
  ['property_type', 'p.property_type = $'],
  ['status',        'p.status        = $'],
];

// The camelCase names the first version of this demo used. Kept so an old
// bookmark still works; the snake_case names are canonical because they
// are the ones the database's saved-search allowlist accepts, and having
// one spelling for "the same filter" in two places was a bug waiting.
const ALIASES = {
  minPrice: 'min_price', maxPrice: 'max_price', minBeds: 'min_beds',
  maxBeds: 'max_beds', minBaths: 'min_baths', maxBaths: 'max_baths',
  minSqft: 'min_sqft', maxSqft: 'max_sqft', propertyType: 'property_type',
};

// URLSearchParams -> plain criteria object, canonical names only.
// `staff` decides whether the operational criteria survive interpret().
// Defaulting it to false means a call site that forgets to pass it gets
// the safe answer rather than the convenient one.
function criteriaFrom(params, staff = false) {
  const c = {};
  for (const [k, v] of params) {
    const key = ALIASES[k] || k;
    if (v === '' || v === null) continue;
    c[key] = v;
  }
  return nlq.interpret(c, { staff });
}

function isStaff(identity) {
  return identity.role === 'sdi_agent' || identity.role === 'sdi_admin';
}

const SORTS = {
  price_asc:  'p.list_price ASC NULLS LAST',
  price_desc: 'p.list_price DESC NULLS LAST',
  sqft_desc:  'p.sqft DESC NULLS LAST',
  beds_desc:  'p.beds DESC NULLS LAST',
  cap_desc:   'p.cap_rate DESC NULLS LAST',
  ref:        'p.listing_ref ASC',
};

// One transaction, one identity, one unit of work. Every route below goes
// through here, so there is exactly one place that decides who the
// database thinks is asking -- and it is three statements long.
async function withTx(identity, brand, fn) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    // SET LOCAL ROLE, not SET ROLE. Reverts at COMMIT, so a pooled
    // connection cannot carry one user's identity into the next request.
    await client.query(`SET LOCAL ROLE ${identity.role}`);
    await client.query(
      `SELECT set_config('app.actor_id', $1, true), set_config('app.brand', $2, true)`,
      [identity.actor || '', brand || 'BRAND_A']);
    const out = await fn(client);
    await client.query('COMMIT');
    return out;
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    throw e;
  } finally {
    client.release();
  }
}

// Which of these listings has the caller favourited. Empty for anyone who
// cannot hold favourites (anonymous, agent) -- the view is not granted to
// them and the failure is expected, not an error.
async function favoriteIds(client) {
  // The SAVEPOINT is the point of this function. An expected failure still
  // aborts the whole transaction, so every statement after it fails too
  // with "current transaction is aborted" -- and this one used to be last,
  // which is the only reason that never showed. Rolling back to a
  // savepoint contains the expected failure to itself, so the caller can
  // add a statement after this one without discovering the coupling.
  await client.query('SAVEPOINT favs');
  try {
    const r = await client.query('SELECT property_id FROM core.saved_property');
    await client.query('RELEASE SAVEPOINT favs');
    return r.rows.map((x) => x.property_id);
  } catch {
    await client.query('ROLLBACK TO SAVEPOINT favs');
    return [];
  }
}

function buildListingQuery(criteria) {
  const where = [];
  const args = [];

  for (const [name, clause] of FILTERS) {
    const v = criteria[name];
    if (v === undefined) continue;
    args.push(v);
    where.push(clause + args.length);
  }
  for (const [name, clause] of TEXT_FILTERS) {
    const v = criteria[name];
    if (v === undefined) continue;
    args.push(v);
    where.push(clause + args.length);
  }
  // The map viewport.
  //
  // Filtered on p.lat and p.lng from api.property_card, which are the
  // PUBLISHED coordinates -- offset by roughly a kilometre for any listing
  // whose address is still gated. That is load-bearing in two ways.
  //
  // It keeps the list and the pins honest: a listing appears in the
  // results exactly when the pin the caller was shown is on screen.
  //
  // And it does not leak. Filtering on the true coordinate would let a
  // caller shrink the box around a gated listing until it dropped out of
  // the results, and binary-search their way to the address the whole
  // platform exists to withhold. The fuzz has to be applied before the
  // comparison, not after.
  //
  // `lat IS NULL OR` is not a loophole, it is the rule for a caller who has
  // no coordinates at all. Since map disclosure was tightened, an ungated
  // caller sees no positions and gets no map -- and a bounding box left in
  // a bookmarked url would otherwise match nothing and empty their results
  // with an explanation about a map they cannot see. A listing you cannot
  // place is not outside the box; it is not on the map at all.
  if (criteria.bbox_s !== undefined && criteria.bbox_n !== undefined) {
    args.push(criteria.bbox_s, criteria.bbox_n);
    where.push(`(p.lat IS NULL OR p.lat BETWEEN $${args.length - 1} AND $${args.length})`);
  }
  if (criteria.bbox_w !== undefined && criteria.bbox_e !== undefined) {
    args.push(criteria.bbox_w, criteria.bbox_e);
    const w = args.length - 1, e = args.length;
    // A viewport dragged across the antimeridian arrives with west east of
    // east. Two ranges, not one, or the box silently matches nothing.
    where.push(criteria.bbox_w <= criteria.bbox_e
      ? `(p.lng IS NULL OR p.lng BETWEEN $${w} AND $${e})`
      : `(p.lng IS NULL OR p.lng >= $${w} OR p.lng <= $${e})`);
  }

  // Free text, matched against the fields a caller can see in every case.
  // Deliberately NOT against street_address: matching on a masked column
  // would let a caller confirm an address by probing for it.
  if (criteria.q) {
    args.push('%' + criteria.q + '%');
    where.push(`(p.city ILIKE $${args.length} OR p.property_type ILIKE $${args.length}
                 OR p.listing_ref ILIKE $${args.length} OR p.state ILIKE $${args.length})`);
  }

  // The operational criteria, each joining a view that refuses a caller
  // who may not read it. A filter on five-year ROI therefore returns
  // NOTHING for an unauthorised caller rather than returning the answer a
  // bisection at a time -- the gate is in the join, not only in the
  // interpret() that dropped the key upstream.
  if (criteria.flag) {
    args.push(criteria.flag);
    where.push(`COALESCE((SELECT f.flag FROM api.property_flag f
                           WHERE f.property_id = p.property_id), 'ok') = $${args.length}`);
  }
  if (criteria.min_roi != null) {
    args.push(criteria.min_roi);
    where.push(`(SELECT r.roi_5yr FROM api.property_return r
                  WHERE r.property_id = p.property_id) >= $${args.length}`);
  }
  if (criteria.max_roi != null) {
    args.push(criteria.max_roi);
    where.push(`(SELECT r.roi_5yr FROM api.property_return r
                  WHERE r.property_id = p.property_id) <= $${args.length}`);
  }
  if (criteria.no_photos) {
    // Counted through api.property_media, so "no photographs" means none
    // THIS CALLER can see -- which for staff is the real answer and for
    // anyone else would be a different question. Staff-only, so it is the
    // real answer.
    where.push(`NOT EXISTS (SELECT 1 FROM api.property_media m
                             WHERE m.property_id = p.property_id
                               AND m.url NOT LIKE '/assets/mask/%')`);
  }
  if (criteria.fees_stale) {
    where.push(`EXISTS (SELECT 1 FROM api.property_fee_status s
                         WHERE s.property_id = p.property_id
                           AND s.schedule_superseded)`);
  }
  if (criteria.not_shared_days != null) {
    args.push(criteria.not_shared_days);
    where.push(`COALESCE((SELECT a.last_shared_at FROM api.property_share_age a
                           WHERE a.property_id = p.property_id),
                         '-infinity'::timestamptz)
                < now() - ($${args.length} || ' days')::interval`);
  }

  const sort = SORTS[criteria.sort] || SORTS.ref;
  const sql =
    `SELECT p.property_id, p.listing_ref, p.status, p.city, p.state, p.zip, p.property_type,
            p.beds, p.baths, p.sqft, p.year_built, p.list_price, p.noi_annual,
            p.cap_rate, p.gross_rent_annual, p.hoa_annual,
            p.street_address, p.unit, p.lat, p.lng, p.address_unlocked,
            p.brand_service_tier, p.brand_platform_fee,
            -- The card image comes from api.property_card, which is where
            -- it is defined. It used to be a subquery written here, which
            -- meant the favourites list -- reading a different view -- had
            -- no card image and silently fell back to a generated drawing.
            -- One definition, two consumers, and they cannot drift.
            p.primary_image,
            -- Whose note, and when. Which note is "last" is decided by the
            -- row policy, not here: staff see internal notes so theirs may
            -- be an internal one, everyone else gets the latest public.
            p.last_note_author, p.last_note_author_id, p.last_note_at,
            p.last_note_visibility, p.last_note_body,
            -- The flag is computed from notes the caller can see, so a
            -- buyer's is almost always green. The browser shows it to
            -- staff only: green on a listing page reads as an assurance.
            p.flag, p.open_critical, p.open_attention
       FROM api.property_card p
      ${where.length ? 'WHERE ' + where.join(' AND ') : ''}
      ORDER BY ${sort}`;
  return { sql, args };
}

async function listings(identity, params) {
  const criteria = criteriaFrom(params, isStaff(identity));
  const { sql, args } = buildListingQuery(criteria);

  return withTx(identity, params.get('brand'), async (client) => {
    const rows = (await client.query(sql, args)).rows;

    // The facet ranges come from the same policy-bounded relation, so the
    // slider bounds a caller sees are the bounds of their own data.
    const facets = (await client.query(
      `SELECT min(list_price)::int AS min_price, max(list_price)::int AS max_price,
              min(beds) AS min_beds,  max(beds) AS max_beds,
              min(sqft) AS min_sqft,  max(sqft) AS max_sqft,
              count(*)::int AS total
         FROM api.property p`)).rows[0];

    // The city list feeds both the filter dropdown and the plain-English
    // parser. Drawn from api.property so it lists only cities this caller
    // has a listing in -- the vocabulary is bounded by the policy too.
    const cities = (await client.query(
      `SELECT DISTINCT city FROM api.property ORDER BY city`)).rows.map((r) => r.city);
    const types = (await client.query(
      `SELECT DISTINCT property_type FROM api.property ORDER BY property_type`))
      .rows.map((r) => r.property_type);

    const favs = new Set(await favoriteIds(client));
    for (const r of rows) r.is_favorite = favs.has(r.property_id);

    // Whether to draw a map at all. Asked of the database rather than
    // inferred from the rows in hand: a filter that happens to return
    // nothing must not read as "you have lost map access", and a caller
    // whose current page is empty may still have a map on the next.
    const mapAccess = (await client.query('SELECT api.map_access() AS ok')).rows[0].ok;

    return {
      identity: identityBlock(identity, { mapAccess, canFavorite: favs !== null }),
      criteria, applied: criteria, sort: criteria.sort || 'ref',
      // Which criteria were dropped for want of the right to use them.
      // A saved search made by an admin and later opened by an investor
      // must not quietly return different results with no explanation.
      ignored: criteria.__ignored && criteria.__ignored.length
        ? criteria.__ignored : undefined,
      facets, cities, types, count: rows.length, rows,
    };
  });
}

// ---------------------------------------------------------------------
// The properties panel
//
// Staff only, and the database says so rather than the route: every query
// here goes through api.property_admin or api.property_save, neither of
// which is granted to a reader role. A signed-in investor reaching these
// urls gets the same refusal as an anonymous one.
// ---------------------------------------------------------------------
async function adminPropertyList(identity, brand, q, flag) {
  return withTx(identity, brand, async (client) => {
    const args = [];
    const clauses = [];
    // PARENTHESISED. The search is three ORs; a second filter appended to it
    // unbracketed becomes `ref OR city OR address AND flag`, which binds the
    // flag to the address alone and quietly returns the wrong rows.
    if (q) {
      args.push('%' + q + '%');
      clauses.push(`(a.listing_ref ILIKE $${args.length} OR a.city ILIKE $${args.length}`
                 + ` OR a.street_address ILIKE $${args.length})`);
    }
    // 'ok' is a real choice, not the absence of one: "show me the properties
    // with nothing outstanding" is a different question from "show me all".
    // A property with no notes has no row in the flag view, so ok has to
    // cover null as well or the clean ones vanish from their own filter.
    if (flag === 'critical' || flag === 'attention') {
      args.push(flag);
      clauses.push(`f.flag = $${args.length}`);
    } else if (flag === 'ok') {
      clauses.push(`COALESCE(f.flag, 'ok') = 'ok'`);
    }
    const where = clauses.length ? 'WHERE ' + clauses.join(' AND ') : '';
    const rows = (await client.query(
      `SELECT a.property_id, a.listing_ref, a.status, a.street_address, a.city, a.state,
              a.metro_label, a.property_type, a.beds, a.baths, a.sqft, a.list_price,
              a.cap_rate, a.primary_image, a.published_photos, a.pending_photos,
              a.underwriting_updated_at,
              n.last_note_author, n.last_note_author_id, n.last_note_at,
              n.last_note_visibility, n.last_note_body,
              f.flag, f.open_critical, f.open_attention
         FROM api.property_admin a
         LEFT JOIN api.property_last_note n ON n.property_id = a.property_id
         LEFT JOIN api.property_flag       f ON f.property_id = a.property_id
         ${where} ORDER BY a.listing_ref`, args)).rows;
    const metros = (await client.query(
      `SELECT metro_code, label, kind FROM api.metro WHERE active ORDER BY sort_order`)).rows;
    // Counted over the WHOLE list, not the filtered one, so the chips keep
    // saying how much there is of each. Counts that collapse to the current
    // filter make it impossible to see there is anything else to look at.
    const tally = (await client.query(
      `SELECT COALESCE(f.flag, 'ok') AS flag, count(*)::int AS n
         FROM api.property_admin a
         LEFT JOIN api.property_flag f ON f.property_id = a.property_id
        GROUP BY 1`)).rows;
    const counts = { all: 0, ok: 0, attention: 0, critical: 0 };
    for (const t of tally) { counts[t.flag] = t.n; counts.all += t.n; }
    return { rows, metros, count: rows.length, counts, flag: flag || 'all' };
  });
}

async function adminProperty(identity, brand, id) {
  return withTx(identity, brand, async (client) => {
    const r = await client.query(
      'SELECT * FROM api.property_admin WHERE property_id = $1', [id]);
    if (!r.rows.length) return null;
    const history = (await client.query(
      'SELECT * FROM api.property_history WHERE property_id = $1 LIMIT 40', [id])).rows;
    const metros = (await client.query(
      `SELECT metro_code, label, kind, manager_name, management_fee_bps,
              leasing_fee_monthly, current_effective_from
         FROM api.metro WHERE active ORDER BY sort_order`)).rows;
    const fees = (await client.query(
      'SELECT * FROM api.property_fee_status WHERE property_id = $1', [id])).rows[0] || null;
    const notes = (await client.query(
      'SELECT * FROM api.property_note WHERE property_id = $1', [id])).rows;
    const flag = (await client.query(
      'SELECT * FROM api.property_flag WHERE property_id = $1', [id])).rows[0] || null;
    // Who this listing has been sent to, and whether the document carried
    // the address. Beside the property rather than in a separate audit
    // screen: the question is always "who has had THIS one", and an audit
    // log nobody passes is an audit log nobody reads.
    const shares = (await client.query(
      'SELECT * FROM api.share_log WHERE property_id = $1 LIMIT 40', [id])).rows;
    // Sections 1, 2, I and II of the workbook. Computed in the database
    // rather than mirrored into the browser like the single-year figures
    // are: a twenty-year amortisation implemented twice is two answers
    // waiting to disagree, and this one is not cheap enough to be worth
    // recomputing on every keystroke anyway.
    const interest = (await client.query(
      'SELECT * FROM api.property_interest WHERE property_id = $1', [id])).rows;
    const customers = (await client.query('SELECT * FROM api.customers()')).rows;
    const stages = (await client.query(
      'SELECT * FROM api.acquisition_stages()')).rows;
    const projection = (await client.query(
      'SELECT * FROM api.property_projection($1)', [id])).rows;
    const benchmark = (await client.query(
      'SELECT * FROM api.property_benchmark($1)', [id])).rows[0] || null;
    const assumptions = (await client.query(
      'SELECT * FROM api.property_assumptions($1)', [id])).rows[0] || null;
    return { property: r.rows[0], history, metros, fees, notes, flag, shares,
             projection, benchmark, assumptions, interest, customers, stages };
  });
}

async function adminPropertySave(identity, brand, id, patch) {
  return withTx(identity, brand, async (client) => {
    const changed = (await client.query(
      'SELECT * FROM api.property_save($1, $2)', [id, JSON.stringify(patch)])).rows;
    const r = await client.query(
      'SELECT * FROM api.property_admin WHERE property_id = $1', [id]);
    return { changed, property: r.rows[0] };
  });
}

// The drill-down. One property, its detail, its photographs.
//
// Note what is NOT here: any check that the caller may see this property.
// api.property_detail is a view over api.property, so a property the
// caller cannot see returns zero rows and this returns 404. The 404 is
// produced by the row policy, not by an if-statement in this file.
async function propertyDetail(identity, id, brand) {
  return withTx(identity, brand, async (client) => {
    const r = await client.query('SELECT * FROM api.property_detail WHERE property_id = $1', [id]);
    if (!r.rows.length) return null;
    const m = await client.query(
      'SELECT media_id, url, thumb_url, caption, position, is_primary, reveals_location '
      // ORDERED, EXPLICITLY. This had no ORDER BY and took whatever order
      // the view happened to return -- and api.property_media is a UNION
      // (real rows, plus the synthetic mask row), so that order is
      // arbitrary and changes with the plan. The browser uses media[0] as
      // the lead photograph, so the panel was showing whichever row came
      // back first: on SDI-1009 a generated line drawing, with the real
      // photograph demoted into the thumbnail strip beneath it.
      //
      // The same ordering as api.property_card uses to pick the card
      // image. Those two disagreeing is how a listing shows one picture on
      // the card and a different one when you open it.
      + 'FROM api.property_media WHERE property_id = $1'
      + ' ORDER BY is_primary DESC, position', [id]);
    // Public notes travel with the listing. They are band 1, like the
    // description -- the row policy has already decided which the caller
    // may see, so nothing is filtered again here.
    const notes = (await client.query(
      'SELECT note_id, body, author, created_at FROM api.property_note'
      + " WHERE property_id = $1 AND visibility = 'public'", [id])).rows;
    let is_favorite = false;
    try {
      const f = await client.query(
        'SELECT 1 FROM core.saved_property WHERE property_id = $1', [id]);
      is_favorite = f.rows.length > 0;
    } catch { /* role cannot hold favourites */ }
    return { property: r.rows[0], media: m.rows, notes, is_favorite };
  });
}

async function setFavorite(identity, id, on) {
  return withTx(identity, null, async (client) => {
    const fn = on ? 'api.save_property($1)' : 'api.unsave_property($1)';
    const r = await client.query(`SELECT ${fn} AS ok`, [id]);
    return { ok: r.rows[0].ok, is_favorite: on && r.rows[0].ok };
  });
}

// What the browser needs to know about who is asking. Built in ONE place
// because two payloads carry it: the listings page and the favourites page.
// The favourites reply used to omit it entirely, which was invisible while
// favourites could only be reached by toggling -- a listings load had always
// happened first and the browser still had the old copy. The moment
// /?fav=1 became a link people could arrive on directly, that first load
// carried no identity at all and the heart buttons stopped being drawn.
function identityBlock(identity, { mapAccess = false, canFavorite = true } = {}) {
  return {
    label: identity.label, role: identity.role, note: identity.note,
    signedIn: identity.key === 'session',
    mapAccess,
    canFavorite: canFavorite
      && (identity.role === 'sdi_investor' || identity.role === 'sdi_admin'),
  };
}

async function favorites(identity, brand) {
  return withTx(identity, brand, async (client) => {
    const r = await client.query(
      'SELECT * FROM api.my_favorite ORDER BY saved_at DESC');
    for (const row of r.rows) row.is_favorite = true;
    const mapAccess = (await client.query('SELECT api.map_access() AS ok')).rows[0].ok;
    return {
      count: r.rows.length, rows: r.rows,
      identity: identityBlock(identity, { mapAccess }),
    };
  });
}

// ---------------------------------------------------------------------
// The intake review queue
//
// Every one of these is staff-only, and none of them says so. The
// functions behind them are granted to sdi_admin alone, so an investor
// who calls them gets a refusal from the database rather than passing an
// if-statement here. Keeping the check in one place -- the grant --
// rather than two is what stops the two disagreeing later.
// ---------------------------------------------------------------------
async function intakeBatches(identity) {
  return withTx(identity, null, async (client) =>
    ({ rows: (await client.query('SELECT * FROM api.intake_batch')).rows }));
}

async function intakeRows(identity, batchId) {
  return withTx(identity, null, async (client) =>
    ({ rows: (await client.query(
        'SELECT * FROM api.intake_row WHERE batch_id = $1 ORDER BY row_number',
        [batchId])).rows }));
}

// The verbatim payload for one row. This is the answer to "did the
// spreadsheet say that, or did we mistranslate it?", so the reviewer
// needs it at hand rather than in a database client.
async function intakeRaw(identity, rowId) {
  return withTx(identity, null, async (client) => {
    const r = await client.query(
      'SELECT raw FROM intake.row WHERE row_id = $1', [rowId]);
    return r.rows.length ? { raw: r.rows[0].raw } : null;
  });
}

async function intakeReview(identity, rowIds, decision, note) {
  return withTx(identity, null, async (client) => {
    const r = await client.query(
      'SELECT api.review_intake_rows($1::uuid[], $2, $3) AS n', [rowIds, decision, note]);
    return { changed: r.rows[0].n };
  });
}

async function intakeApproveBatch(identity, batchId, note) {
  return withTx(identity, null, async (client) => {
    const r = await client.query('SELECT api.approve_batch($1, $2) AS n', [batchId, note]);
    return { changed: r.rows[0].n };
  });
}

async function intakeRelease(identity, { rowIds, batchId, publish }) {
  return withTx(identity, null, async (client) => {
    const q = rowIds
      ? ['SELECT * FROM api.release_intake_rows($1::uuid[], $2, $3)',
         [rowIds, 'BRAND_A', publish !== false]]
      : ['SELECT * FROM api.release_batch($1, $2, $3)',
         [batchId, 'BRAND_A', publish !== false]];
    const r = await client.query(q[0], q[1]);

    // Governance is advisory, so a release can succeed and still leave the
    // listing uncovered. Reporting that back with the result is the only
    // way the reviewer learns it without going looking.
    let uncovered = [];
    try {
      uncovered = (await client.query(
        'SELECT listing_ref, reason FROM gov.uncovered_publication')).rows;
    } catch { /* not granted; not fatal */ }
    return { released: r.rows, uncovered };
  });
}

async function savedSearches(identity) {
  return withTx(identity, null, async (client) =>
    ({ rows: (await client.query('SELECT * FROM api.my_saved_search')).rows }));
}

async function saveSearch(identity, name, criteria) {
  // interpret() again on the way in. The browser already sent canonical
  // keys, but this is a write, and a write validates its own input --
  // including the right to use the operational criteria. Saving is not a
  // way to keep a filter somebody would be refused if they asked for it.
  const clean = nlq.interpret(criteria, { staff: isStaff(identity) });
  return withTx(identity, null, async (client) => {
    const r = await client.query('SELECT api.save_search($1, $2::jsonb) AS id',
                                 [name, JSON.stringify(clean)]);
    return { ok: true, search_id: r.rows[0].id, criteria: clean };
  });
}

async function deleteSearch(identity, id) {
  return withTx(identity, null, async (client) => {
    const r = await client.query('SELECT api.delete_saved_search($1) AS ok', [id]);
    return { ok: r.rows[0].ok };
  });
}

async function runSearch(identity, id) {
  return withTx(identity, null, async (client) => {
    const r = await client.query('SELECT api.run_saved_search($1) AS criteria', [id]);
    // Interpreted against the CURRENT caller, not against whoever saved
    // it. A search saved by an admin and opened after a role change comes
    // back without the criteria that role no longer carries.
    return { ok: true, criteria: nlq.interpret(r.rows[0].criteria,
                                               { staff: isStaff(identity) }) };
  });
}

async function probeBaseTable(identity) {
  const p = identity;
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query(`SET LOCAL ROLE ${p.role}`);
    await client.query(`SELECT set_config('app.actor_id', $1, true)`, [p.actor || '']);
    const r = await client.query('SELECT street_address FROM core.property LIMIT 3');
    await client.query('COMMIT');
    return { ok: true, rows: r.rows };
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    return { ok: false, error: e.message };
  } finally {
    client.release();
  }
}

// Which build is this?
//
// Asked constantly and previously unanswerable from the running system: a
// deployed change that is not visible looks identical to a change that was
// never deployed, and the only way to tell them apart was to go and read a
// registry. So the build says its own name, in the corner of every screen.
//
// SINGLE SOURCE. The version lives in the repository's VERSION file and
// nowhere else. CI reads it at build time and bakes it in along with the
// commit; a container built any other way honestly says "dev" rather than
// inventing a number, because a wrong version is worse than no version --
// it is the thing somebody trusts while chasing the wrong bug.
const BUILD = (() => {
  let version = process.env.SDI_VERSION || null;
  if (!version) {
    // Running from a clone rather than the image: read it from the file it
    // lives in, so local development is never mislabelled either.
    try {
      version = fs.readFileSync(path.join(__dirname, '..', 'VERSION'), 'utf8').trim();
    } catch { /* not a clone */ }
  }
  const commit = (process.env.SDI_COMMIT || '').trim().slice(0, 7);
  return { version: version || 'dev', commit: commit || null };
})();

const MIME = {
  '.html': 'text/html', '.css': 'text/css', '.js': 'text/javascript',
  // Real listing photography lives under public/assets/ and is served
  // from here. Which images a caller is TOLD about is still decided by
  // core.property_media's row policy -- but note that a file under
  // public/ is reachable by anyone who guesses its path, so a genuinely
  // gated photograph must not be served this way in production. See the
  // note in 26_fairgrove_media.sql.
  '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png',
  '.webp': 'image/webp', '.svg': 'image/svg+xml', '.avif': 'image/avif',
};

const ANON = { key: 'anon', label: 'Not signed in', role: 'sdi_public',
               actor: null, note: 'Anonymous visitor' };

// The one place a request becomes an identity.
//
// A real session wins. A demo persona is consulted only when DEMO_PERSONAS
// is on, so the default deployment has exactly one way to become anybody:
// signing in.
async function identityFor(req, url) {
  const token = auth.tokenFromRequest(req);
  if (token) {
    const s = await auth.resolveSession(pool, token);
    if (s) {
      const role = auth.dbRoleFor(s.role);
      if (role) {
        return { key: 'session', label: s.full_name, role,
                 actor: s.person_id, note: `Signed in as ${s.role}` };
      }
    }
  }
  if (DEMO_PERSONAS) {
    const key = url.searchParams.get('persona');
    if (key && PERSONAS[key]) return { key, ...PERSONAS[key] };
  }
  return ANON;
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');

  const secureCookie = process.env.COOKIE_INSECURE !== '1';

  // ---- authentication ---------------------------------------------------
  if (url.pathname === '/api/login' && req.method === 'POST') {
    try {
      const body = JSON.parse(await readBody(req) || '{}');
      const out = await auth.authenticate(pool, body.email || '', body.password || '', {
        userAgent: req.headers['user-agent'] || null,
        // Behind a proxy this must come from a trusted forwarded header, not
        // the socket. Left as the socket address until a proxy is in front.
        ip: (req.socket && req.socket.remoteAddress) || null,
      });
      if (!out.ok) {
        // One message, one shape, whatever went wrong. Distinguishing
        // "no such account" from "wrong password" is an enumeration oracle.
        res.writeHead(401, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify({ ok: false, error: out.reason }));
      }
      res.writeHead(200, {
        'Content-Type': 'application/json',
        'Set-Cookie': auth.sessionCookie(out.token, { secure: secureCookie }),
      });
      return res.end(JSON.stringify({
        ok: true, name: out.full_name, role: out.role, expiresAt: out.expires_at,
      }));
    } catch (e) {
      // Specific in the log, generic on the wire. The caller learns nothing
      // about why; the operator learns everything.
      console.error('login failed:', e.message);
      res.writeHead(400, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ ok: false, error: 'bad request' }));
    }
  }

  if (url.pathname === '/api/logout' && req.method === 'POST') {
    await auth.logout(pool, auth.tokenFromRequest(req));
    res.writeHead(200, {
      'Content-Type': 'application/json',
      'Set-Cookie': auth.clearCookie({ secure: secureCookie }),
    });
    return res.end(JSON.stringify({ ok: true }));
  }

  // ---- share a listing as a document ------------------------------------
  //
  // A GET, because the browser has to be able to navigate to it and receive
  // a file. It has a side effect -- the log row -- which a GET is not
  // supposed to have, and that is a deliberate trade: the alternative is a
  // POST that returns bytes the page then has to turn into a download
  // itself, and a share that is not logged is worse than a GET that is not
  // pure. Nothing here is cacheable and the headers say so.
  if (url.pathname.startsWith('/api/share/') && req.method === 'GET') {
    const m = /^\/api\/share\/([0-9a-f-]{36})\.pdf$/i.exec(url.pathname);
    if (!m) { res.writeHead(404); return res.end('Not found'); }
    const id = m[1];
    const wantUnmask = url.searchParams.get('unmask') === '1';
    const recipient = (url.searchParams.get('to') || '').trim();
    let identity = null;
    try {
      identity = await identityFor(req, url);
      const brand = url.searchParams.get('brand');
      const out = await withTx(identity, brand, async (client) => {
        const prop = (await client.query(
          'SELECT * FROM api.property WHERE property_id = $1', [id])).rows[0];
        if (!prop) return null;

        // THE ONE PLACE THE DECISION IS MADE. `wantUnmask` is a request off
        // a query string; api.share_context answers it against
        // sec.can_see_address(). Everything downstream reads ctx.unmasked
        // and never the parameter, so there is no path where the checkbox
        // is consulted on its own.
        const ctx = (await client.query(
          'SELECT * FROM api.share_context($1, $2)', [id, wantUnmask])).rows[0];
        if (!ctx) return null;

        // Which image, decided by the same answer. When masked, the mask
        // is a static file under public/; when unmasked, the real one comes
        // out of the media store through the view that governs it.
        let imagePath = null;
        if (ctx.unmasked) {
          const mrow = (await client.query(
            `SELECT b.storage_path, b.thumb_path
               FROM api.property_media m
               JOIN api.media_bytes b ON b.media_id = m.media_id
              WHERE m.property_id = $1
              ORDER BY m.is_primary DESC, m.position LIMIT 1`, [id])).rows[0];
          if (mrow) {
            const rel = mrow.storage_path;
            const full = path.resolve(MEDIA_ROOT, rel);
            if (full === MEDIA_ROOT || full.startsWith(MEDIA_ROOT + path.sep)) {
              imagePath = full;
            }
          }
        } else if (ctx.mask_url) {
          // The mask is served from public/, so it is resolved against that
          // root and checked the same way a stored path is.
          const rel = String(ctx.mask_url).replace(/^\//, '');
          const root = path.join(__dirname, 'public');
          const full = path.resolve(root, rel);
          if (full.startsWith(root + path.sep)) imagePath = full;
        }

        // Recorded before the bytes are produced. If writing the log fails,
        // no document is generated -- an unlogged share is the thing this
        // whole feature exists to prevent.
        await client.query('SELECT api.record_share($1, $2, $3)',
          [id, ctx.unmasked, recipient]);

        return { prop, ctx, imagePath };
      });

      if (!out) { res.writeHead(404); return res.end('Not found'); }
      let image = null;
      if (out.imagePath) {
        try { image = await fs.promises.readFile(out.imagePath); } catch { image = null; }
      }
      // Who prepared it, by the name the system knows them by rather than
      // anything typed in. A document that names its author wrongly is
      // worse than one that does not name them.
      const who = identity.key === 'session' ? identity.label : 'SDI';
      res.writeHead(200, {
        'Content-Type': 'application/pdf',
        'Content-Disposition': `attachment; filename="${out.prop.listing_ref}`
          + `${out.ctx.unmasked ? '' : '-summary'}.pdf"`,
        // Never cached, anywhere. A masked and an unmasked document share a
        // url that differs only by a query parameter, and a cache that
        // conflated them would hand somebody the wrong one.
        'Cache-Control': 'no-store, private',
      });
      return share.render({
        property: out.prop, unmasked: out.ctx.unmasked, image,
        sharedBy: who, recipient, build: BUILD.version,
      }).pipe(res);
    } catch (e) {
      console.error('share failed:', e.message);
      const plain = /say who this is going to|no such property/.test(e.message);
      res.writeHead(plain ? 400 : 403, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ error: plain ? e.message : 'not permitted' }));
    }
  }

  // Whether the unmask option may even be offered. Asked of the database
  // rather than inferred in the browser from whether an address happens to
  // be present: a listing whose address is null for some other reason must
  // not read as "you may not unmask", and vice versa.
  if (url.pathname.startsWith('/api/share-context/') && req.method === 'GET') {
    const id = url.pathname.slice('/api/share-context/'.length);
    if (!/^[0-9a-f-]{36}$/i.test(id)) { res.writeHead(404); return res.end('Not found'); }
    try {
      const identity = await identityFor(req, url);
      const row = (await withTx(identity, url.searchParams.get('brand'), (c) =>
        c.query('SELECT may_unmask FROM api.share_context($1, false)', [id])
      )).rows[0];
      res.writeHead(row ? 200 : 404, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify(row || { error: 'not found' }));
    } catch (e) {
      // Falling back to "no" is the safe direction, but it must not be a
      // silent one: a broken query here looks exactly like a refusal, and
      // the control would quietly disappear for everybody.
      console.error('share-context failed:', e.message);
      res.writeHead(200, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ may_unmask: false }));
    }
  }

  if (url.pathname === '/api/whoami') {
    const who = await identityFor(req, url);
    res.writeHead(200, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({
      label: who.label, role: who.role, note: who.note,
      signedIn: who.key === 'session',
      // Not gated. Which build is running is not a secret, and an anonymous
      // visitor reporting a bug needs to be able to say which one they saw.
      build: BUILD,
      demoPersonas: DEMO_PERSONAS,
      personas: DEMO_PERSONAS
        ? Object.entries(PERSONAS).map(([k, v]) => ({ key: k, label: v.label, note: v.note }))
        : [],
    }));
  }

  // ---- listings, filtered -----------------------------------------------
  if (url.pathname === '/api/listings') {
    try {
      const identity = await identityFor(req, url);
      const data = await listings(identity, url.searchParams);
      res.writeHead(200, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify(data));
    } catch (e) {
      console.error('listings failed:', e.message);
      res.writeHead(500, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ error: 'query failed' }));
    }
  }

  // ---- the drill-down ---------------------------------------------------
  if (url.pathname === '/api/property') {
    try {
      const identity = await identityFor(req, url);
      const id = url.searchParams.get('id') || '';
      if (!/^[0-9a-f-]{36}$/i.test(id)) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify({ error: 'bad id' }));
      }
      const data = await propertyDetail(identity, id, url.searchParams.get('brand'));
      if (!data) {
        // Not "forbidden". A listing this caller may not see does not
        // exist as far as this caller is concerned, and saying otherwise
        // would confirm the listing_ref space to anyone who guessed.
        res.writeHead(404, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify({ error: 'not found' }));
      }
      res.writeHead(200, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify(data));
    } catch (e) {
      console.error('detail failed:', e.message);
      res.writeHead(500, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ error: 'query failed' }));
    }
  }

  // ---- favourites -------------------------------------------------------
  if (url.pathname === '/api/favorite' && (req.method === 'POST' || req.method === 'DELETE')) {
    try {
      const identity = await identityFor(req, url);
      const body = JSON.parse(await readBody(req) || '{}');
      const id = String(body.property_id || '');
      if (!/^[0-9a-f-]{36}$/i.test(id)) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify({ error: 'bad id' }));
      }
      const data = await setFavorite(identity, id, req.method === 'POST');
      res.writeHead(200, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify(data));
    } catch (e) {
      // api.save_property raises 28000 when nobody is signed in and 42501
      // when the listing is not visible. Both are the caller's problem and
      // both are reported without saying which.
      console.error('favorite failed:', e.message);
      res.writeHead(403, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ error: 'not permitted' }));
    }
  }

  // What a customer has been shown. Their own deals, joined to
  // api.property, so the address is present or absent by the ordinary
  // gate rather than by anything decided here.
  if (url.pathname === '/api/my-deals' && req.method === 'GET') {
    try {
      const identity = await identityFor(req, url);
      const d = await withTx(identity, url.searchParams.get('brand'), (c) =>
        c.query('SELECT * FROM api.my_deal'));
      res.writeHead(200, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ rows: d.rows }));
    } catch (e) {
      console.error('my-deals failed:', e.message);
      res.writeHead(403, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ error: 'not permitted' }));
    }
  }

  if (url.pathname === '/api/favorites') {
    try {
      const identity = await identityFor(req, url);
      const data = await favorites(identity, url.searchParams.get('brand'));
      res.writeHead(200, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify(data));
    } catch {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ count: 0, rows: [] }));
    }
  }

  // ---- saved searches ---------------------------------------------------
  if (url.pathname === '/api/saved-search') {
    try {
      const identity = await identityFor(req, url);
      if (req.method === 'GET') {
        const data = await savedSearches(identity);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify(data));
      }
      if (req.method === 'POST') {
        const body = JSON.parse(await readBody(req) || '{}');
        const name = String(body.name || '').trim().slice(0, 80);
        if (!name) {
          res.writeHead(400, { 'Content-Type': 'application/json' });
          return res.end(JSON.stringify({ error: 'name required' }));
        }
        const data = await saveSearch(identity, name, body.criteria || {});
        res.writeHead(200, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify(data));
      }
      if (req.method === 'DELETE') {
        const body = JSON.parse(await readBody(req) || '{}');
        const data = await deleteSearch(identity, String(body.search_id || ''));
        res.writeHead(200, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify(data));
      }
    } catch (e) {
      console.error('saved search failed:', e.message);
      res.writeHead(403, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ error: 'not permitted' }));
    }
  }

  if (url.pathname === '/api/saved-search/run' && req.method === 'POST') {
    try {
      const identity = await identityFor(req, url);
      const body = JSON.parse(await readBody(req) || '{}');
      const data = await runSearch(identity, String(body.search_id || ''));
      res.writeHead(200, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify(data));
    } catch (e) {
      console.error('run saved search failed:', e.message);
      res.writeHead(404, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ error: 'not found' }));
    }
  }

  // ---- intake review ----------------------------------------------------
  if (url.pathname.startsWith('/api/intake/')) {
    try {
      const identity = await identityFor(req, url);
      const what = url.pathname.slice('/api/intake/'.length);

      if (what === 'batches' && req.method === 'GET') {
        const d = await intakeBatches(identity);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify(d));
      }
      if (what === 'rows' && req.method === 'GET') {
        const d = await intakeRows(identity, url.searchParams.get('batch_id'));
        res.writeHead(200, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify(d));
      }
      if (what === 'raw' && req.method === 'GET') {
        const d = await intakeRaw(identity, url.searchParams.get('row_id'));
        res.writeHead(d ? 200 : 404, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify(d || { error: 'not found' }));
      }
      if (what === 'review' && req.method === 'POST') {
        const b = JSON.parse(await readBody(req) || '{}');
        const d = await intakeReview(identity, b.row_ids || [], b.decision, b.note || null);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify(d));
      }
      if (what === 'approve-batch' && req.method === 'POST') {
        const b = JSON.parse(await readBody(req) || '{}');
        const d = await intakeApproveBatch(identity, b.batch_id, b.note || null);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify(d));
      }
      if (what === 'release' && req.method === 'POST') {
        const b = JSON.parse(await readBody(req) || '{}');
        const d = await intakeRelease(identity, {
          rowIds: b.row_ids, batchId: b.batch_id, publish: b.publish });
        res.writeHead(200, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify(d));
      }
      res.writeHead(404, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ error: 'not found' }));
    } catch (e) {
      // 'staff only' and 'permission denied' both arrive here. The caller
      // is told it was refused, not which grant refused it.
      console.error('intake failed:', e.message);
      res.writeHead(403, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ error: 'not permitted' }));
    }
  }

  // ---- your own profile --------------------------------------------------
  if (url.pathname.startsWith('/api/profile')) {
    try {
      const identity = await identityFor(req, url);
      const brand = url.searchParams.get('brand');

      if (req.method === 'GET') {
        const d = await withTx(identity, brand, (c) =>
          c.query('SELECT * FROM api.my_profile()'));
        res.writeHead(200, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify(d.rows[0] || null));
      }

      const b = JSON.parse(await readBody(req,
        url.pathname === '/api/profile/photo' ? UPLOAD_LIMIT : undefined) || '{}');

      if (url.pathname === '/api/profile/photo' && req.method === 'POST') {
        // Removing a photograph clears the row and leaves the file: the
        // next upload overwrites it, and a delete that races an in-flight
        // read is a broken image for no benefit.
        if (b.remove) {
          await withTx(identity, brand, (c) => c.query('SELECT api.set_avatar(NULL)'));
          res.writeHead(200, { 'Content-Type': 'application/json' });
          return res.end(JSON.stringify({ ok: true, avatar: null }));
        }
        const raw = images.decodeDataUrl(b.image);
        if (!raw) {
          res.writeHead(400, { 'Content-Type': 'application/json' });
          return res.end(JSON.stringify({ error: 'that is not an image, or it is too large' }));
        }
        const me = (await withTx(identity, brand, (c) =>
          c.query('SELECT person_id FROM api.my_profile()'))).rows[0];
        if (!me) {
          res.writeHead(403, { 'Content-Type': 'application/json' });
          return res.end(JSON.stringify({ error: 'not signed in' }));
        }
        // Re-encode first, write second, record third. A row must never
        // point at a file that was not written.
        const jpeg = await images.toSquareJpeg(raw);
        const rel = `avatars/${me.person_id}.jpg`;
        await fs.promises.mkdir(path.join(MEDIA_ROOT, 'avatars'), { recursive: true });
        await fs.promises.writeFile(path.join(MEDIA_ROOT, rel), jpeg);
        await withTx(identity, brand, (c) => c.query('SELECT api.set_avatar($1)', [rel]));
        res.writeHead(200, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify({ ok: true, avatar: rel, bytes: jpeg.length }));
      }

      if (req.method === 'POST') {
        await withTx(identity, brand, (c) =>
          c.query('SELECT api.update_profile($1)', [b.full_name || '']));
        const d = await withTx(identity, brand, (c) =>
          c.query('SELECT * FROM api.my_profile()'));
        res.writeHead(200, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify(d.rows[0]));
      }
      res.writeHead(404, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ error: 'not found' }));
    } catch (e) {
      if (e.code === 'BODY_TOO_LARGE') {
        res.writeHead(413, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify({ error: 'that image is too large to upload' }));
      }
      const plain = /not signed in|at least two characters|not an image|avatar path/
        .test(e.message);
      console.error('profile failed:', e.message);
      res.writeHead(plain ? 400 : 403, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ error: plain ? e.message : 'not permitted' }));
    }
  }

  // A colleague's photograph, served under the same rule as every other
  // stored file: the database decides, the filesystem does not.
  if (url.pathname.startsWith('/media/avatar/')) {
    const id = url.pathname.slice('/media/avatar/'.length);
    if (!/^[0-9a-f-]{36}$/i.test(id)) { res.writeHead(404); return res.end('Not found'); }
    let rel = null;
    try {
      const identity = await identityFor(req, url);
      rel = (await withTx(identity, null, (c) =>
        c.query('SELECT api.avatar_path($1) AS p', [id]))).rows[0].p;
    } catch { rel = null; }
    if (!rel) { res.writeHead(404); return res.end('Not found'); }
    const full = path.resolve(MEDIA_ROOT, rel);
    if (!full.startsWith(MEDIA_ROOT + path.sep)) { res.writeHead(404); return res.end('Not found'); }
    return fs.readFile(full, (err, buf) => {
      if (err) { res.writeHead(404); return res.end('Not found'); }
      res.writeHead(200, { 'Content-Type': 'image/jpeg',
                           'Cache-Control': 'private, max-age=300' });
      res.end(buf);
    });
  }

  // ---- the properties panel ---------------------------------------------
  if (url.pathname.startsWith('/api/admin/')) {
    try {
      const identity = await identityFor(req, url);
      const brand = url.searchParams.get('brand');
      const what = url.pathname.slice('/api/admin/'.length);

      if (what === 'properties' && req.method === 'GET') {
        const d = await adminPropertyList(identity, brand,
          url.searchParams.get('q'), url.searchParams.get('flag'));
        res.writeHead(200, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify(d));
      }
      if (what === 'property' && req.method === 'GET') {
        const d = await adminProperty(identity, brand, url.searchParams.get('id'));
        res.writeHead(d ? 200 : 404, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify(d || { error: 'not found' }));
      }
      if (what === 'note' && req.method === 'POST') {
        const b = JSON.parse(await readBody(req) || '{}');
        const d = await withTx(identity, brand, async (client) => {
          if (b.note_id && b.remove) {
            await client.query('SELECT api.delete_note($1)', [b.note_id]);
          } else if (b.note_id && b.resolve) {
            await client.query('SELECT api.resolve_note($1, $2)',
              [b.note_id, b.resolution || null]);
          } else if (b.note_id && b.reopen) {
            await client.query('SELECT api.reopen_note($1)', [b.note_id]);
          } else if (b.note_id) {
            await client.query('SELECT api.edit_note($1, $2)', [b.note_id, b.body]);
          } else {
            await client.query('SELECT api.add_note($1, $2, $3, $4)',
              [b.property_id, b.body, b.visibility || 'internal', b.severity || 'note']);
          }
          // The flag travels back with the notes. It is derived from them,
          // so returning one without the other lets the header disagree
          // with the list it was computed from.
          return {
            notes: (await client.query(
              'SELECT * FROM api.property_note WHERE property_id = $1',
              [b.property_id])).rows,
            flag: (await client.query(
              'SELECT * FROM api.property_flag WHERE property_id = $1',
              [b.property_id])).rows[0] || null,
          };
        });
        res.writeHead(200, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify(d));
      }
      if (what === 'assign' && req.method === 'POST') {
        const b = JSON.parse(await readBody(req) || '{}');
        const d = await withTx(identity, brand, async (client) => {
          if (b.deal_id && b.stage) {
            await client.query('SELECT api.move_deal($1, $2, $3)',
              [b.deal_id, b.stage, b.reason || null]);
          } else if (b.deal_id && b.remove) {
            await client.query('SELECT api.unassign_customer($1)', [b.deal_id]);
          } else {
            await client.query('SELECT api.assign_to_customer($1, $2)',
              [b.property_id, b.person_id]);
          }
          return { interest: (await client.query(
            'SELECT * FROM api.property_interest WHERE property_id = $1',
            [b.property_id])).rows };
        });
        res.writeHead(200, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify(d));
      }
      if (what === 'assumptions' && req.method === 'POST') {
        const b = JSON.parse(await readBody(req) || '{}');
        const d = await withTx(identity, brand, async (client) => {
          await client.query('SELECT api.save_assumptions($1, $2::jsonb)',
            [b.property_id, JSON.stringify(b.patch || {})]);
          // The projection is returned with the assumptions that produced
          // it, in one transaction. Saving and then re-reading in a second
          // round trip is how a screen ends up showing last year's figures
          // beside this year's inputs.
          return {
            assumptions: (await client.query(
              'SELECT * FROM api.property_assumptions($1)',
              [b.property_id])).rows[0] || null,
            projection: (await client.query(
              'SELECT * FROM api.property_projection($1)', [b.property_id])).rows,
            benchmark: (await client.query(
              'SELECT * FROM api.property_benchmark($1)', [b.property_id])).rows[0] || null,
          };
        });
        res.writeHead(200, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify(d));
      }
      if (what === 'apply-fees' && req.method === 'POST') {
        const b = JSON.parse(await readBody(req) || '{}');
        const d = await withTx(identity, brand, async (client) => {
          const changed = (await client.query(
            'SELECT * FROM api.apply_fee_schedule($1)', [b.property_id])).rows;
          const prop = (await client.query(
            'SELECT * FROM api.property_admin WHERE property_id = $1', [b.property_id])).rows[0];
          const fees = (await client.query(
            'SELECT * FROM api.property_fee_status WHERE property_id = $1',
            [b.property_id])).rows[0] || null;
          return { changed, property: prop, fees };
        });
        res.writeHead(200, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify(d));
      }
      if (what === 'property' && req.method === 'POST') {
        const b = JSON.parse(await readBody(req) || '{}');
        if (!/^[0-9a-f-]{36}$/i.test(b.property_id || '')) {
          res.writeHead(400, { 'Content-Type': 'application/json' });
          return res.end(JSON.stringify({ error: 'bad id' }));
        }
        const d = await adminPropertySave(identity, brand, b.property_id, b.patch || {});
        res.writeHead(200, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify(d));
      }
      res.writeHead(404, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ error: 'not found' }));
    } catch (e) {
      // A refused save and a refused read arrive here alike. The message
      // from api.property_save is safe to pass on -- "field x is not
      // editable here" tells the caller what to fix and reveals nothing --
      // but a permission failure is reported without saying which grant.
      // Messages safe to pass back: each names something the caller can fix
      // and reveals nothing. Anything else is reported as a plain refusal.
      // (No /x flag in JavaScript, so this stays on one line.)
      const editable = /is not editable here|no fee schedule|no programme|no such programme|not a note|public or internal|only the author|shown to a customer, not|no such person|not a stage of|nothing to resolve|attention or critical/
        .test(e.message);
      console.error('admin failed:', e.message);
      res.writeHead(editable ? 400 : 403, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ error: editable ? e.message : 'not permitted' }));
    }
  }

  // ---- plain-English search ---------------------------------------------
  // The text never reaches SQL. It becomes a criteria object, the object
  // is validated against a fixed key set, and the caller gets back both
  // the criteria and a sentence saying what was understood.
  if (url.pathname === '/api/parse' && req.method === 'POST') {
    try {
      const identity = await identityFor(req, url);
      const body = JSON.parse(await readBody(req) || '{}');
      const cities = await withTx(identity, null, async (client) =>
        (await client.query('SELECT DISTINCT city FROM api.property ORDER BY city'))
          .rows.map((r) => r.city));
      // SCREENED BEFORE PARSED. The output validator guards the shape of
      // the criteria; this guards the request. "A good school district"
      // parses to entirely legal keys -- a city and a bedroom count --
      // and is steering all the same, so the only place to catch it is
      // before anything has been turned into a filter.
      const text = String(body.text || '').slice(0, 300);
      const screened = await withTx(identity, null, (client) =>
        client.query('SELECT * FROM api.screen_search_text($1)', [text]));
      if (screened.rows.length) {
        // 422, not 400: the request was understood perfectly well. It is
        // being declined, and the caller is told exactly why and what
        // they can ask for instead.
        res.writeHead(422, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify({
          refused: true,
          matched: screened.rows.map((r) => ({
            phrase: r.matched, basis: r.basis, kind: r.kind })),
          error: 'This search cannot be run.',
        }));
      }

      // Parsed for everybody, gated for this caller. Parsing conditionally
      // would mean the same sentence understood two ways depending on who
      // typed it, which is far harder to reason about than one parse and
      // one gate.
      const criteria = nlq.interpret(
        nlq.parse(text, cities),
        { staff: isStaff(identity) });
      res.writeHead(200, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({
        criteria, explain: nlq.explain(criteria),
        ignored: criteria.__ignored && criteria.__ignored.length
          ? criteria.__ignored : undefined,
      }));
    } catch (e) {
      console.error('parse failed:', e.message);
      res.writeHead(500, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ error: 'parse failed' }));
    }
  }

  // ---- stored photography, served under authority -----------------------
  //
  // This is the route the whole media store exists for. A file under
  // web/public/ is fetchable by anyone who guesses its path -- the
  // database decided who was TOLD a photograph existed, never who could
  // fetch it. Here the request itself re-asks the database, AS THE CALLER,
  // and a row the caller cannot see is a 404 rather than a refusal: a 403
  // would confirm the photograph exists, which is half of what the gate
  // is withholding.
  if (url.pathname.startsWith('/media/file/')) {
    const id = url.pathname.slice('/media/file/'.length);
    if (!/^[0-9a-f-]{36}$/i.test(id)) { res.writeHead(404); return res.end('Not found'); }
    const wantThumb = url.searchParams.get('v') === 'thumb';

    // One query, inside the caller's own transaction. api.media_bytes is
    // security_invoker over a FORCE ROW LEVEL SECURITY table, so the same
    // policy that decides whether this caller may be TOLD the photograph
    // exists decides whether this lookup returns a path at all. No row, no
    // bytes, and no separate privileged read that could drift from it.
    let paths = null;
    try {
      const identity = await identityFor(req, url);
      paths = (await withTx(identity, url.searchParams.get('brand'), (c) =>
        c.query('SELECT storage_path, thumb_path FROM api.media_bytes'
                + ' WHERE media_id = $1', [id])
      )).rows[0] || null;
    } catch { paths = null; }
    const rel = paths && (wantThumb ? (paths.thumb_path || paths.storage_path)
                                    : paths.storage_path);
    if (!rel) { res.writeHead(404); return res.end('Not found'); }

    // The path came from our own database, but it still gets resolved and
    // checked against the root. A stored path is data, and data that
    // becomes a filesystem path without a boundary check is how a store
    // turns into a file server for the whole disk.
    const full = path.resolve(MEDIA_ROOT, rel);
    if (full !== MEDIA_ROOT && !full.startsWith(MEDIA_ROOT + path.sep)) {
      res.writeHead(404); return res.end('Not found');
    }
    return fs.readFile(full, (err, buf) => {
      if (err) { res.writeHead(404); return res.end('Not found'); }
      res.writeHead(200, {
        'Content-Type': MIME[path.extname(full).toLowerCase()] || 'application/octet-stream',
        // Private: a gated photograph must not be held by a shared cache
        // that would then serve it to somebody the gate is closed against.
        // The short max-age is also the tail on a purge -- see section 6.3
        // of the media lifecycle document.
        'Cache-Control': 'private, max-age=300',
      });
      res.end(buf);
    });
  }

  // ---- placeholder photography ------------------------------------------
  // Which images a caller is TOLD about is decided in the database. This
  // route only draws; it is reached with an id the caller already has.
  if (url.pathname.startsWith('/media/')) {
    const m = /^\/media\/([0-9a-f-]{36})\/([a-z]+)\.svg$/i.exec(url.pathname);
    if (!m) { res.writeHead(404); return res.end('Not found'); }
    // The hero's massing depends on the property type, so look it up.
    // Read through api.property, which means an id the caller cannot see
    // simply renders the generic form rather than confirming anything.
    let ptype = null;
    if (m[2] === 'hero') {
      try {
        const identity = await identityFor(req, url);
        ptype = (await withTx(identity, null, (c) =>
          c.query('SELECT property_type FROM api.property WHERE property_id = $1', [m[1]])
        )).rows[0]?.property_type || null;
      } catch { /* fall through to the generic form */ }
    }
    const svg = media.render(m[1], m[2], ptype);
    if (!svg) { res.writeHead(404); return res.end('Not found'); }
    res.writeHead(200, {
      'Content-Type': 'image/svg+xml',
      'Cache-Control': 'public, max-age=86400',
    });
    return res.end(svg);
  }

  // ---- data -------------------------------------------------------------
  if (url.pathname === '/api/view') {
    try {
      const identity = await identityFor(req, url);
      const data = await runAs(identity, url.searchParams.get('brand') || 'BRAND_A');
      res.writeHead(200, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify(data));
    } catch (e) {
      res.writeHead(500, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ error: e.message }));
    }
  }

  if (url.pathname === '/api/probe') {
    const identity = await identityFor(req, url);
    const data = await probeBaseTable(identity);
    res.writeHead(200, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify(data));
  }

  // Static files, with revalidation.
  //
  // These went out with NO caching headers at all -- no Cache-Control, no
  // ETag, no Last-Modified -- which does not mean "do not cache". With
  // nothing to go on a browser falls back to HEURISTIC caching and reuses a
  // .js or .css file for as long as it likes without asking. So a deployed
  // change to the rail, a stylesheet or a page script could sit there
  // invisible behind a stale copy, and the only cure anybody knew was a hard
  // refresh. That is not a browser quirk to work around; it is this server
  // failing to say anything about freshness.
  //
  // `no-cache` is the confusing name for the right behaviour: STORE IT, and
  // ASK BEFORE EVERY USE. The ask is conditional, so an unchanged file costs
  // a 304 with no body rather than a re-download, and a changed one arrives
  // immediately without anybody being told to clear anything.
  const file = url.pathname === '/' ? '/index.html' : url.pathname;
  const full = path.join(__dirname, 'public', path.normalize(file).replace(/^(\.\.[/\\])+/, ''));
  fs.stat(full, (serr, st) => {
    if (serr || !st.isFile()) { res.writeHead(404); return res.end('Not found'); }
    // Size and mtime together. mtime alone has one-second resolution, and two
    // edits inside the same second during a deploy would look identical.
    const tag = `W/"${st.size.toString(16)}-${st.mtimeMs.toString(16)}"`;
    const lastMod = st.mtime.toUTCString();
    const headers = {
      'Content-Type': MIME[path.extname(full)] || 'text/plain',
      'Cache-Control': 'no-cache',
      'ETag': tag,
      'Last-Modified': lastMod,
    };
    const inm = req.headers['if-none-match'];
    const ims = req.headers['if-modified-since'];
    if (inm === tag || (!inm && ims && Date.parse(ims) >= Math.floor(st.mtimeMs / 1000) * 1000)) {
      res.writeHead(304, headers);
      return res.end();
    }
    fs.readFile(full, (err, buf) => {
      if (err) { res.writeHead(404); return res.end('Not found'); }
      res.writeHead(200, headers);
      res.end(buf);
    });
  });
});

// ---------------------------------------------------------------------
// Fair housing, asserted at startup
//
// gov.prohibited_dimension lists the protected characteristics and the
// identified proxies for them. Nothing here may become a filter, a sort
// key or an audience dimension: filtering on a proxy is steering whether
// or not anyone intended it, and the Fair Housing Act does not require
// intent.
//
// The check runs here, against the database, rather than being a comment
// above the FILTERS array -- because the array is what a future feature
// edits, and a rule that lives only in a comment is a rule that survives
// exactly until someone is in a hurry. A violation stops the process:
// serving a discriminatory filter is worse than being down.
//
// Note what this cannot catch: a dimension added under an innocent name.
// That is what the register's `basis` column and code review are for. It
// catches the careless case, which is the common one.
async function assertNoProhibitedFilters() {
  const names = new Set([
    ...FILTERS.map(([n]) => n),
    ...TEXT_FILTERS.map(([n]) => n),
    ...Object.keys(SORTS),
    ...Object.keys(ALIASES),
    'q',
  ].map((n) => n.toLowerCase()));

  // Two failures look identical from here and must not be treated the
  // same. A database that has no register is an older deployment, and
  // running unchecked against it is a considered trade. A database we
  // could not REACH is almost always this container winning the race
  // against a Postgres that is still running its init scripts -- and an
  // earlier version of this function caught both in one clause, so the
  // safety check announced a warning once at boot and then never ran
  // again for the life of the process. That is worse than having no
  // check, because the log line looks like diligence.
  //
  // So: retry a connection failure, and only accept a genuinely absent
  // register as the benign case.
  const ABSENT = new Set([
    '42P01',   // undefined_table
    '3F000',   // invalid_schema_name
    '42501',   // insufficient_privilege
  ]);
  // Budget deliberately generous. `depends_on: service_healthy` does NOT
  // settle this: the postgres entrypoint runs its init scripts against a
  // temporary server on a unix socket, so pg_isready reports healthy while
  // TCP is still refused, and a first boot that loads the whole schema
  // takes well over the ~25s an earlier 15-attempt budget allowed. The
  // container then died on a FATAL and only came back because of the
  // restart policy -- correct, but alarming and avoidable.
  //
  // ~2 minutes covers a cold start with a full schema load. It still
  // refuses to serve rather than serve unchecked.
  const ATTEMPTS = 45;
  let banned = null;

  for (let i = 1; i <= ATTEMPTS; i++) {
    try {
      const r = await pool.query('SELECT dimension, basis FROM api.prohibited_dimensions');
      banned = r.rows;
      break;
    } catch (e) {
      if (ABSENT.has(e.code)) {
        console.warn('WARNING: this database has no fair-housing register '
          + `(${e.code}). Filter names are unchecked -- see sql/24_data_governance.sql.`);
        return;
      }
      if (i === ATTEMPTS) {
        console.error(`FATAL: could not reach the database to read the fair-housing `
          + `register after ${ATTEMPTS} attempts over ~2 minutes (${e.message}).`);
        console.error('Refusing to start: serving unchecked filters is worse than being down.');
        process.exit(1);
      }
      await new Promise((r) => setTimeout(r, Math.min(250 * i, 3000)));
    }
  }

  const hits = banned.filter((b) => names.has(b.dimension.toLowerCase()));
  if (hits.length) {
    console.error('FATAL: a search filter names a prohibited dimension.');
    for (const h of hits) console.error(`  ${h.dimension} — proxy for or directly ${h.basis}`);
    console.error('See gov.prohibited_dimension. Refusing to start.');
    process.exit(1);
  }
  console.log(`fair-housing register: ${banned.length} dimensions, none exposed as filters`);
}

const PORT = process.env.PORT || 3000;
assertNoProhibitedFilters().then(() => {
  server.listen(PORT, () => console.log(`SDI marketplace on http://localhost:${PORT}`));
});
