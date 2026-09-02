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

const pool = new Pool({
  host:     process.env.PGHOST     || 'localhost',
  port:     process.env.PGPORT     || 5432,
  database: process.env.PGDATABASE || 'sdi',
  user:     process.env.PGUSER     || 'sdi_app',
  password: process.env.PGPASSWORD || 'demo_app_pw',
  max: 8,
});

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
function readBody(req, limit = 8192) {
  return new Promise((resolve, reject) => {
    const chunks = []; let size = 0;
    req.on('data', (c) => {
      size += c.length;
      if (size > limit) { reject(new Error('body too large')); req.destroy(); return; }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

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
function criteriaFrom(params) {
  const c = {};
  for (const [k, v] of params) {
    const key = ALIASES[k] || k;
    if (v === '' || v === null) continue;
    c[key] = v;
  }
  return nlq.interpret(c);
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
  try {
    const r = await client.query('SELECT property_id FROM core.saved_property');
    return r.rows.map((x) => x.property_id);
  } catch { return []; }
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
  // Free text, matched against the fields a caller can see in every case.
  // Deliberately NOT against street_address: matching on a masked column
  // would let a caller confirm an address by probing for it.
  if (criteria.q) {
    args.push('%' + criteria.q + '%');
    where.push(`(p.city ILIKE $${args.length} OR p.property_type ILIKE $${args.length}
                 OR p.listing_ref ILIKE $${args.length} OR p.state ILIKE $${args.length})`);
  }

  const sort = SORTS[criteria.sort] || SORTS.ref;
  const sql =
    `SELECT p.property_id, p.listing_ref, p.status, p.city, p.state, p.zip, p.property_type,
            p.beds, p.baths, p.sqft, p.year_built, p.list_price, p.noi_annual,
            p.cap_rate, p.gross_rent_annual, p.hoa_annual,
            p.street_address, p.unit, p.lat, p.lng, p.address_unlocked,
            p.brand_service_tier, p.brand_platform_fee
       FROM api.property p
      ${where.length ? 'WHERE ' + where.join(' AND ') : ''}
      ORDER BY ${sort}`;
  return { sql, args };
}

async function listings(identity, params) {
  const criteria = criteriaFrom(params);
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

    return {
      identity: { label: identity.label, role: identity.role, note: identity.note,
                  signedIn: identity.key === 'session', canFavorite: favs !== null &&
                    (identity.role === 'sdi_investor' || identity.role === 'sdi_admin') },
      criteria, applied: criteria, sort: criteria.sort || 'ref',
      facets, cities, types, count: rows.length, rows,
    };
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
      'SELECT media_id, url, caption, position, is_primary, reveals_location '
      + 'FROM api.property_media WHERE property_id = $1', [id]);
    let is_favorite = false;
    try {
      const f = await client.query(
        'SELECT 1 FROM core.saved_property WHERE property_id = $1', [id]);
      is_favorite = f.rows.length > 0;
    } catch { /* role cannot hold favourites */ }
    return { property: r.rows[0], media: m.rows, is_favorite };
  });
}

async function setFavorite(identity, id, on) {
  return withTx(identity, null, async (client) => {
    const fn = on ? 'api.save_property($1)' : 'api.unsave_property($1)';
    const r = await client.query(`SELECT ${fn} AS ok`, [id]);
    return { ok: r.rows[0].ok, is_favorite: on && r.rows[0].ok };
  });
}

async function favorites(identity, brand) {
  return withTx(identity, brand, async (client) => {
    const r = await client.query(
      'SELECT * FROM api.my_favorite ORDER BY saved_at DESC');
    for (const row of r.rows) row.is_favorite = true;
    return { count: r.rows.length, rows: r.rows };
  });
}

async function savedSearches(identity) {
  return withTx(identity, null, async (client) =>
    ({ rows: (await client.query('SELECT * FROM api.my_saved_search')).rows }));
}

async function saveSearch(identity, name, criteria) {
  // interpret() again on the way in. The browser already sent canonical
  // keys, but this is a write, and a write validates its own input.
  const clean = nlq.interpret(criteria);
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
    return { ok: true, criteria: nlq.interpret(r.rows[0].criteria) };
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

  if (url.pathname === '/api/whoami') {
    const who = await identityFor(req, url);
    res.writeHead(200, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({
      label: who.label, role: who.role, note: who.note,
      signedIn: who.key === 'session',
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
      const criteria = nlq.interpret(nlq.parse(String(body.text || '').slice(0, 300), cities));
      res.writeHead(200, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ criteria, explain: nlq.explain(criteria) }));
    } catch (e) {
      console.error('parse failed:', e.message);
      res.writeHead(500, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ error: 'parse failed' }));
    }
  }

  // ---- placeholder photography ------------------------------------------
  // Which images a caller is TOLD about is decided in the database. This
  // route only draws; it is reached with an id the caller already has.
  if (url.pathname.startsWith('/media/')) {
    const m = /^\/media\/([0-9a-f-]{36})\/([a-z]+)\.svg$/i.exec(url.pathname);
    if (!m) { res.writeHead(404); return res.end('Not found'); }
    const svg = media.render(m[1], m[2]);
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

  const file = url.pathname === '/' ? '/index.html' : url.pathname;
  const full = path.join(__dirname, 'public', path.normalize(file).replace(/^(\.\.[/\\])+/, ''));
  fs.readFile(full, (err, buf) => {
    if (err) { res.writeHead(404); return res.end('Not found'); }
    res.writeHead(200, { 'Content-Type': MIME[path.extname(full)] || 'text/plain' });
    res.end(buf);
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

  let banned;
  try {
    const r = await pool.query('SELECT dimension, basis FROM api.prohibited_dimensions');
    banned = r.rows;
  } catch (e) {
    // Not fatal: an older database has no register. Loud, though --
    // silently skipping a safety check is how it stops existing.
    console.warn('WARNING: could not read the fair-housing register '
      + `(${e.message}). Filter names are unchecked.`);
    return;
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
