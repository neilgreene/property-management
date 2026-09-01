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
const auth = require('./auth');

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

const MIME = { '.html': 'text/html', '.css': 'text/css', '.js': 'text/javascript' };

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

const PORT = process.env.PORT || 3000;
server.listen(PORT, () => console.log(`SDI demo on http://localhost:${PORT}`));
