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

async function runAs(personaKey, brand) {
  const p = PERSONAS[personaKey];
  if (!p) throw new Error('unknown persona');

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
      persona: { key: personaKey, ...p },
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
async function probeBaseTable(personaKey) {
  const p = PERSONAS[personaKey];
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

const MIME = { '.html': 'text/html', '.css': 'text/css', '.js': 'text/javascript' };

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');

  if (url.pathname === '/api/view') {
    try {
      const data = await runAs(url.searchParams.get('persona') || 'anon',
                              url.searchParams.get('brand')   || 'BRAND_A');
      res.writeHead(200, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify(data));
    } catch (e) {
      res.writeHead(500, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ error: e.message }));
    }
  }

  if (url.pathname === '/api/probe') {
    const data = await probeBaseTable(url.searchParams.get('persona') || 'anon');
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

const PORT = process.env.PORT || 3000;
server.listen(PORT, () => console.log(`SDI demo on http://localhost:${PORT}`));
