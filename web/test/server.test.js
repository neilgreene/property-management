'use strict';
// The HTTP surface. The assertion that matters most is negative: with demo
// personas off, no request can become somebody else by asking.
const test = require('node:test');
const assert = require('node:assert');
const { Pool } = require('pg');
const auth = require('../auth');

const RUTH = '11111111-1111-1111-1111-111111111111';
let pool, proc, base, available = true;

async function db() {
  if (pool) return pool;
  pool = new Pool({
    host: process.env.PGHOST || '127.0.0.1',
    database: process.env.PGDATABASE || 'sdi',
    user: 'sdi_test_admin', password: 'demo_test_pw', max: 3,
  });
  await pool.query('SELECT 1');
  return pool;
}

function startServer(env) {
  const { spawn } = require('node:child_process');
  return new Promise((resolve, reject) => {
    const p = spawn(process.execPath, [require.resolve('../server.js')], {
      env: { ...process.env, PORT: '0', COOKIE_INSECURE: '1',
             PGHOST: '127.0.0.1', PGDATABASE: process.env.PGDATABASE || 'sdi',
             PGUSER: 'sdi_app', PGPASSWORD: 'demo_app_pw', ...env },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let out = '';
    p.stdout.on('data', (d) => {
      out += d.toString();
      const m = out.match(/http:\/\/localhost:(\d+)/);
      if (m) resolve({ proc: p, base: `http://127.0.0.1:${m[1]}` });
    });
    p.stderr.on('data', (d) => reject(new Error(d.toString())));
    setTimeout(() => reject(new Error('server did not start')), 8000);
  });
}

test('setup', async (t) => {
  try {
    const d = await db();
    await d.query('DELETE FROM core.session');
    await d.query('SELECT api.set_password($1, $2)',
                  [RUTH, await auth.hashPassword('ruth-pw')]);
    // PORT=0 asks the OS for a free port; server.js prints the fixed PORT, so
    // pick one explicitly instead.
    const port = 3400 + Math.floor(Math.random() * 200);
    const s = await startServer({ PORT: String(port) });
    proc = s.proc; base = `http://127.0.0.1:${port}`;
  } catch (e) { available = false; t.skip(`cannot start: ${e.message}`); }
});

const jsonPost = (path, body, cookie) => fetch(base + path, {
  method: 'POST',
  headers: { 'Content-Type': 'application/json', ...(cookie ? { cookie } : {}) },
  body: JSON.stringify(body),
});

test('anonymous sees listings with no address', async (t) => {
  if (!available) return t.skip('no server');
  const r = await fetch(`${base}/api/view`);
  const j = await r.json();
  assert.equal(j.persona.role, 'sdi_public');
  assert.ok(j.rows.length > 0);
  assert.equal(j.rows[0].street_address, null);
});

test('a persona cannot be assumed by query parameter', async (t) => {
  if (!available) return t.skip('no server');
  // The demo switcher is off by default. If it were consulted anyway, this
  // request would return an administrator's view to an anonymous caller.
  for (const p of ['dan', 'jessica', 'ruth', 'tom']) {
    const j = await (await fetch(`${base}/api/view?persona=${p}`)).json();
    assert.equal(j.persona.role, 'sdi_public', `?persona=${p} changed identity`);
    assert.equal(j.rows[0].street_address, null);
  }
});

test('signing in returns a cookie and the right role', async (t) => {
  if (!available) return t.skip('no server');
  const r = await jsonPost('/api/login', { email: 'ruth@example.com', password: 'ruth-pw' });
  assert.equal(r.status, 200);
  const j = await r.json();
  assert.equal(j.ok, true);
  assert.equal(j.role, 'investor');
  const c = r.headers.get('set-cookie');
  assert.match(c, /sdi_session=/);
  assert.match(c, /HttpOnly/);
});

test('a signed-in investor sees the address; the same request without the cookie does not', async (t) => {
  if (!available) return t.skip('no server');
  const login = await jsonPost('/api/login', { email: 'ruth@example.com', password: 'ruth-pw' });
  const cookie = login.headers.get('set-cookie').split(';')[0];

  const signedIn = await (await fetch(`${base}/api/view`, { headers: { cookie } })).json();
  assert.equal(signedIn.persona.role, 'sdi_investor');
  assert.ok(signedIn.rows[0].street_address, 'Ruth has signed the agreement');

  const anon = await (await fetch(`${base}/api/view`)).json();
  assert.equal(anon.rows[0].street_address, null);
});

test('a wrong password is 401 and issues no cookie', async (t) => {
  if (!available) return t.skip('no server');
  const r = await jsonPost('/api/login', { email: 'ruth@example.com', password: 'nope' });
  assert.equal(r.status, 401);
  assert.equal(r.headers.get('set-cookie'), null);
});

test('an unknown account gives the identical response', async (t) => {
  if (!available) return t.skip('no server');
  const a = await jsonPost('/api/login', { email: 'nobody@example.com', password: 'x' });
  const b = await jsonPost('/api/login', { email: 'ruth@example.com', password: 'x' });
  assert.equal(a.status, b.status);
  assert.deepEqual(await a.json(), await b.json());
});

test('a forged cookie is ignored', async (t) => {
  if (!available) return t.skip('no server');
  const j = await (await fetch(`${base}/api/view`,
    { headers: { cookie: 'sdi_session=totally-made-up' } })).json();
  assert.equal(j.persona.role, 'sdi_public');
});

test('logging out returns the caller to anonymous', async (t) => {
  if (!available) return t.skip('no server');
  const login = await jsonPost('/api/login', { email: 'ruth@example.com', password: 'ruth-pw' });
  const cookie = login.headers.get('set-cookie').split(';')[0];
  assert.equal((await (await fetch(`${base}/api/view`, { headers: { cookie } })).json()).persona.role,
               'sdi_investor');
  await jsonPost('/api/logout', {}, cookie);
  const after = await (await fetch(`${base}/api/view`, { headers: { cookie } })).json();
  assert.equal(after.persona.role, 'sdi_public', 'the token must be dead server-side, not just cleared client-side');
});

test('whoami reports the truth and does not leak the persona list', async (t) => {
  if (!available) return t.skip('no server');
  const j = await (await fetch(`${base}/api/whoami`)).json();
  assert.equal(j.signedIn, false);
  assert.equal(j.demoPersonas, false);
  assert.deepEqual(j.personas, [], 'the switcher list is not served when it is disabled');
});

// The favourites grid and the search grid are different queries over
// different views. They must not disagree about which photograph a listing
// has -- and they did: the card image was a subquery written inside the
// search query, so favourites had no such column and silently fell back to
// a generated drawing. Nothing failed; one page just quietly showed
// something else. This asserts the two agree, listing by listing.
test('favourites and the search grid show the same photograph', async (t) => {
  if (!available) return t.skip('no server');
  const login = await jsonPost('/api/login', { email: 'ruth@example.com', password: 'ruth-pw' });
  const cookie = login.headers.get('set-cookie').split(';')[0];

  // /api/listings, which is what the grid calls. /api/view is the older
  // demo endpoint and returns neither property_id nor the card image, so a
  // test written against it would prove nothing about either page.
  const listings = await (await fetch(`${base}/api/listings`, { headers: { cookie } })).json();
  // Ruth starts with favourites of her own from the seed. Note what was
  // there and add only listings that were not, so the cleanup restores the
  // fixture rather than emptying it.
  const before = new Set(((await (await fetch(`${base}/api/favorites`,
    { headers: { cookie } })).json()).rows).map((r) => r.property_id));
  const target = listings.rows.filter((r) => !before.has(r.property_id)).slice(0, 3);
  assert.ok(target.length, 'the fixture must offer listings that are not already saved');

  for (const r of target) {
    await jsonPost('/api/favorite', { property_id: r.property_id }, cookie);
  }
  try {
    const favs = await (await fetch(`${base}/api/favorites`, { headers: { cookie } })).json();
    const byId = new Map(favs.rows.map((f) => [f.property_id, f]));
    for (const r of target) {
      const f = byId.get(r.property_id);
      assert.ok(f, `${r.listing_ref} is missing from favourites`);
      assert.ok(r.primary_image, `${r.listing_ref} has no card image in the grid`);
      assert.equal(f.primary_image, r.primary_image,
        `${r.listing_ref}: favourites and the grid disagree about the card image`);
    }
  } finally {
    // Leave the fixture as it was found. A test that quietly leaves
    // favourites behind changes what the next one sees.
    for (const r of target) {
      await fetch(`${base}/api/favorite`, {
        method: 'DELETE', headers: { cookie, 'Content-Type': 'application/json' },
        body: JSON.stringify({ property_id: r.property_id }),
      });
    }
    const after = await (await fetch(`${base}/api/favorites`, { headers: { cookie } })).json();
    assert.equal(after.rows.length, before.size,
      'the cleanup must leave the fixture exactly as it was found');
  }
});

test('the login page is served', async (t) => {
  if (!available) return t.skip('no server');
  const r = await fetch(`${base}/login.html`);
  assert.equal(r.status, 200);
  assert.match(await r.text(), /Sign in/);
});

test.after(async () => {
  if (proc) proc.kill();
  if (pool) await pool.end();
});
