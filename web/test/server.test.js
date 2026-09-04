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

// The map viewport as a filter. Ruth throughout, because coordinates are
// band 2 now: nobody without the fee agreement gets a position at all, so
// there is no viewport to test for an anonymous caller.
test('coordinates are withheld unless the address is unlocked', async (t) => {
  if (!available) return t.skip('no server');
  const anon = await (await fetch(`${base}/api/listings`)).json();
  assert.ok(anon.rows.length, 'the fixture must return listings');
  assert.ok(anon.rows.every((r) => r.lat === null && r.lng === null),
    'an ungated caller received a coordinate \u2014 a point on a map is an address '
    + 'written differently, and hiding the map in the browser would leave this '
    + 'one View Source away');
  assert.equal(anon.identity.mapAccess, false);

  const login = await jsonPost('/api/login', { email: 'ruth@example.com', password: 'ruth-pw' });
  const cookie = login.headers.get('set-cookie').split(';')[0];
  const ruth = await (await fetch(`${base}/api/listings`, { headers: { cookie } })).json();
  assert.ok(ruth.rows.every((r) => r.lat !== null),
    'a caller past the fee gate must get positions, or there is no map for anybody');
  assert.equal(ruth.identity.mapAccess, true);
});

test('the map viewport filters the listings', async (t) => {
  if (!available) return t.skip('no server');
  const login = await jsonPost('/api/login', { email: 'ruth@example.com', password: 'ruth-pw' });
  const cookie = login.headers.get('set-cookie').split(';')[0];
  const get = async (qs) => (await (await fetch(`${base}/api/listings${qs}`,
    { headers: { cookie } })).json());

  const all = await get('');
  assert.ok(all.rows.length > 2, 'the fixture must have listings to narrow');

  const target = all.rows.find((r) => r.lat != null);
  const d = 0.02;
  const near = await get(`?bbox_s=${target.lat - d}&bbox_n=${Number(target.lat) + d}`
                       + `&bbox_w=${target.lng - d}&bbox_e=${Number(target.lng) + d}`);
  assert.ok(near.rows.some((r) => r.property_id === target.property_id));
  assert.ok(near.rows.length < all.rows.length, 'the box actually excluded something');

  // A box on the far side of the world returns nothing rather than
  // everything -- an ignored filter is worse than a rejected one.
  assert.equal((await get('?bbox_s=-40&bbox_n=-35&bbox_w=140&bbox_e=150')).rows.length, 0);

  // Negative longitudes survive the validator. Every listing here is in the
  // western hemisphere, so a rule that dropped negatives would leave the
  // filter silently unapplied.
  assert.ok((await get('?bbox_s=24&bbox_n=50&bbox_w=-125&bbox_e=-66')).rows.length > 0,
    'a negative longitude must not be discarded');
});

test('a stale bounding box does not empty the results for a caller with no map', async (t) => {
  if (!available) return t.skip('no server');
  // Signing out with a viewport in the url used to leave a box filtering
  // rows that no longer carry a position, so every result vanished behind
  // an explanation about a map the caller could not see.
  const anon = await (await fetch(
    `${base}/api/listings?bbox_s=24&bbox_n=50&bbox_w=-125&bbox_e=-66`)).json();
  assert.ok(anon.rows.length > 0,
    'a listing you cannot place is not outside the box; it is not on the map at all');
});

test('the viewport filter uses the coordinate the caller was shown', async (t) => {
  if (!available) return t.skip('no server');
  const d = await db();
  // With map disclosure set to 'none' an ungated listing has no coordinate
  // at all, so this leak cannot happen by construction. The guard still
  // belongs in the query rather than in the setting: 'approximate' is one
  // UPDATE away and the design conflict register has that question open.
  // So the test flips the setting, proves the guard, and puts it back.
  await d.query("UPDATE sec.disclosure SET map_mode = 'approximate' WHERE id");
  try {
    const anon = await (await fetch(`${base}/api/listings`)).json();
    const row = anon.rows.find((r) => !r.address_unlocked && r.lat != null);
    assert.ok(row, 'approximate mode must publish a fuzzed position');

    const truth = (await d.query(
      'SELECT lat, lng FROM core.property WHERE property_id = $1', [row.property_id])).rows[0];
    const e = 0.002;                             // ~200m, well inside the ~1km offset
    const tight = await (await fetch(`${base}/api/listings`
      + `?bbox_s=${truth.lat - e}&bbox_n=${Number(truth.lat) + e}`
      + `&bbox_w=${truth.lng - e}&bbox_e=${Number(truth.lng) + e}`)).json();
    assert.ok(!tight.rows.some((r) => r.property_id === row.property_id),
      'a box drawn on the TRUE position matched the listing \u2014 the filter is reading '
      + 'the real coordinate, which turns the map into a way to binary-search a gated address');

    const shown = await (await fetch(`${base}/api/listings`
      + `?bbox_s=${row.lat - e}&bbox_n=${Number(row.lat) + e}`
      + `&bbox_w=${row.lng - e}&bbox_e=${Number(row.lng) + e}`)).json();
    assert.ok(shown.rows.some((r) => r.property_id === row.property_id),
      'the listing must be found where its own pin is drawn');
  } finally {
    await d.query("UPDATE sec.disclosure SET map_mode = 'none' WHERE id");
    assert.equal((await d.query('SELECT map_mode FROM sec.disclosure')).rows[0].map_mode,
      'none', 'the setting must be put back');
  }
});

// Photographs are band 2 with the address and the map: one masked image
// until access is granted, and no way to fetch anything behind it.
test('photographs are masked until access is granted', async (t) => {
  if (!available) return t.skip('no server');
  const anon = await (await fetch(`${base}/api/listings`)).json();
  const cards = new Set(anon.rows.map((r) => r.primary_image));
  assert.equal(cards.size, 1, 'every listing shows the same masked image');
  assert.match([...cards][0], /masked/);

  // And the drill-down agrees: one masked tile, not a gallery.
  const one = await (await fetch(
    `${base}/api/property?id=${anon.rows[0].property_id}`)).json();
  assert.equal(one.media.length, 1, 'a masked listing has exactly one image');
  assert.match(one.media[0].url, /masked/);
  assert.match(one.media[0].caption, /released when the agreement is signed/);

  const login = await jsonPost('/api/login', { email: 'ruth@example.com', password: 'ruth-pw' });
  const cookie = login.headers.get('set-cookie').split(';')[0];
  const ruth = await (await fetch(`${base}/api/listings`, { headers: { cookie } })).json();
  assert.ok(new Set(ruth.rows.map((r) => r.primary_image)).size > 1,
    'a caller past the fee gate sees the real photographs, each its own');
  const ruthOne = await (await fetch(
    `${base}/api/property?id=${anon.rows[0].property_id}`, { headers: { cookie } })).json();
  assert.ok(ruthOne.media.length > 1, 'and a gallery rather than a single tile');
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
