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
  const cards = anon.rows.map((r) => r.primary_image);
  assert.ok(cards.every((u) => /\/mask\//.test(u)),
    'every listing must show a mask, not its own photograph');

  // Drawn from a pool, so the picture carries no information about which
  // property it belongs to -- and a listing whose card image is visibly
  // its own exterior under a watermark is not masked at all.
  assert.ok(new Set(cards).size > 1, 'the pool is not being used');

  // Stable, though. A card that changes picture on every load reads as a
  // broken image and defeats caching.
  const again = await (await fetch(`${base}/api/listings`)).json();
  assert.deepEqual(again.rows.map((r) => r.primary_image), cards,
    'the same property must draw the same mask every time');

  // And the drill-down agrees: one masked tile, not a gallery.
  const one = await (await fetch(
    `${base}/api/property?id=${anon.rows[0].property_id}`)).json();
  assert.equal(one.media.length, 1, 'a masked listing has exactly one image');
  assert.match(one.media[0].url, /\/mask\//);
  assert.match(one.media[0].caption, /Not this property/);

  const login = await jsonPost('/api/login', { email: 'ruth@example.com', password: 'ruth-pw' });
  const cookie = login.headers.get('set-cookie').split(';')[0];
  const ruth = await (await fetch(`${base}/api/listings`, { headers: { cookie } })).json();
  assert.ok(new Set(ruth.rows.map((r) => r.primary_image)).size > 1,
    'a caller past the fee gate sees the real photographs, each its own');
  const ruthOne = await (await fetch(
    `${base}/api/property?id=${anon.rows[0].property_id}`, { headers: { cookie } })).json();
  assert.ok(ruthOne.media.length > 1, 'and a gallery rather than a single tile');
});

// ---- the properties panel -------------------------------------------
// The arithmetic assertions are against the 401 NW 71st St workbook, which
// is the only figures in this system that came from outside it. If a
// change to api.property_admin ever stops reconciling to that sheet, this
// is where it shows.
const JESS = '77777777-7777-7777-7777-777777777777';

async function staffCookie() {
  const d = await db();
  await d.query('SELECT api.set_password($1, $2)',
                [JESS, await auth.hashPassword('jess-pw')]);
  const r = await jsonPost('/api/login', { email: 'jpool2@yahoo.com', password: 'jess-pw' });
  return r.headers.get('set-cookie').split(';')[0];
}

test('the properties panel is staff only', async (t) => {
  if (!available) return t.skip('no server');
  assert.equal((await fetch(`${base}/api/admin/properties`)).status, 403);

  const login = await jsonPost('/api/login', { email: 'ruth@example.com', password: 'ruth-pw' });
  const investor = login.headers.get('set-cookie').split(';')[0];
  assert.equal((await fetch(`${base}/api/admin/properties`,
    { headers: { cookie: investor } })).status, 403,
    'an investor with the fee paid still has no business editing the numbers');

  const cookie = await staffCookie();
  const ok = await fetch(`${base}/api/admin/properties`, { headers: { cookie } });
  assert.equal(ok.status, 200);
  assert.ok((await ok.json()).rows.length > 0);
});

test('the derived figures reconcile to the workbook', async (t) => {
  if (!available) return t.skip('no server');
  const cookie = await staffCookie();
  const list = await (await fetch(`${base}/api/admin/properties?q=SDI-1009`,
    { headers: { cookie } })).json();
  const id = list.rows[0].property_id;
  const { property: p } = await (await fetch(`${base}/api/admin/property?id=${id}`,
    { headers: { cookie } })).json();

  assert.equal(Number(p.improvement_estimate), 3750,
    'improvements are costed at the middle of the range, not the top');
  assert.equal(Number(p.total_cost), 307084);
  assert.equal(Number(p.day_one_equity), -7084);
  assert.equal(Number(p.down_payment_amount), 88500);
  assert.equal(Number(p.financed_amount), 206500);
  assert.equal(Math.round(Number(p.monthly_mortgage)), 1304);
  assert.equal(Number(p.cash_outlay), 100584);
});

test('a save is recorded field by field, and an unknown field is refused', async (t) => {
  if (!available) return t.skip('no server');
  const cookie = await staffCookie();
  const list = await (await fetch(`${base}/api/admin/properties?q=SDI-1010`,
    { headers: { cookie } })).json();
  const id = list.rows[0].property_id;

  const before = await (await fetch(`${base}/api/admin/property?id=${id}`,
    { headers: { cookie } })).json();
  const was = before.property.insurance_annual;

  const r = await jsonPost('/api/admin/property',
    { property_id: id, patch: { insurance_annual: '1234' } }, cookie);
  const d = await r.json();
  assert.equal(d.changed.length, 1);
  assert.equal(d.changed[0].field, 'insurance_annual');
  assert.equal(Number(d.property.insurance_annual), 1234);

  // Saving the same value again writes nothing: a change log full of
  // no-op entries is a change log nobody reads.
  const again = await (await jsonPost('/api/admin/property',
    { property_id: id, patch: { insurance_annual: '1234' } }, cookie)).json();
  assert.equal(again.changed.length, 0);

  const after = await (await fetch(`${base}/api/admin/property?id=${id}`,
    { headers: { cookie } })).json();
  assert.ok(after.history.some((h) => h.field === 'insurance_annual'),
    'the change must appear in the history');

  // A field outside the allowlist is refused, not silently dropped --
  // ignoring it would look like a successful save and lose the edit.
  const bad = await jsonPost('/api/admin/property',
    { property_id: id, patch: { acquisition_cost: '1' } }, cookie);
  assert.equal(bad.status, 400);
  assert.match((await bad.json()).error, /not editable/);

  // Put it back.
  await jsonPost('/api/admin/property',
    { property_id: id, patch: { insurance_annual: was == null ? '' : String(was) } }, cookie);
});

test('a later fee schedule does not restate an earlier agreement', async (t) => {
  if (!available) return t.skip('no server');
  const d = await db();
  const cookie = await staffCookie();
  const list = await (await fetch(`${base}/api/admin/properties?q=SDI-1009`,
    { headers: { cookie } })).json();
  const id = list.rows[0].property_id;

  const before = await (await fetch(`${base}/api/admin/property?id=${id}`,
    { headers: { cookie } })).json();
  assert.equal(Number(before.property.management_fee_bps), 800,
    'the fixture is on the January schedule');
  assert.equal(before.fees.schedule_superseded, false);

  // sdi_test_admin is not a member of sdi_admin, so it cannot SET ROLE to
  // it. It does not need to: api.record_fee_schedule authorises on the
  // ACTOR being internal, which Jessica is, not on the connection role.
  await d.query("SELECT set_config('app.actor_id', $1, false)", [JESS]);
  const newId = (await d.query(
    "SELECT api.record_fee_schedule('KC-SH', $1::date, 1000, 35.00, NULL, 'test') AS id",
    ['2026-03-01'])).rows[0].id;
  try {
    const after = await (await fetch(`${base}/api/admin/property?id=${id}`,
      { headers: { cookie } })).json();
    assert.equal(Number(after.property.management_fee_bps), 800,
      'RAISING THE PROGRAMME FEE CHANGED AN AGREED PROPERTY — a fee is copied '
      + 'onto a property once, never read live, or every past deal is restated '
      + 'the moment a manager puts its prices up');
    assert.equal(after.fees.schedule_superseded, true,
      'and the panel must be able to say the property is on an older schedule');
    assert.equal(Number(after.fees.current_management_fee_bps), 1000);
  } finally {
    await d.query('DELETE FROM core.fee_schedule WHERE schedule_id = $1', [newId]);
  }
});

// ---- notes -----------------------------------------------------------
test('notes are attributed, dated, and public or internal', async (t) => {
  if (!available) return t.skip('no server');
  const cookie = await staffCookie();
  const list = await (await fetch(`${base}/api/admin/properties?q=SDI-1011`,
    { headers: { cookie } })).json();
  const id = list.rows[0].property_id;

  const pub = await (await jsonPost('/api/admin/note',
    { property_id: id, body: 'Roof replaced 2024, receipts on file.',
      visibility: 'public' }, cookie)).json();
  await jsonPost('/api/admin/note',
    { property_id: id, body: 'Seller motivated; will not go below 152.',
      visibility: 'internal' }, cookie);

  const mine = pub.notes.find((n2) => /Roof replaced/.test(n2.body));
  assert.equal(mine.author, 'Jessica Pool', 'a note carries who wrote it');
  assert.ok(mine.created_at, 'and when');
  assert.equal(mine.is_mine, true);

  const staffSees = await (await fetch(`${base}/api/admin/property?id=${id}`,
    { headers: { cookie } })).json();
  assert.equal(staffSees.notes.length, 2, 'staff see both');

  // The public one reaches the listing; the internal one does not, and an
  // internal note is where somebody writes what the seller will accept.
  const anon = await (await fetch(`${base}/api/property?id=${id}`)).json();
  assert.equal(anon.notes.length, 1);
  assert.match(anon.notes[0].body, /Roof replaced/);
  assert.ok(!JSON.stringify(anon).includes('will not go below'),
    'AN INTERNAL NOTE REACHED AN ANONYMOUS CALLER');

  // Removing is soft, so the note leaves the listing and the record of it
  // having been written does not.
  const gone = await (await jsonPost('/api/admin/note',
    { property_id: id, note_id: mine.note_id, remove: true }, cookie)).json();
  assert.ok(!gone.notes.some((n2) => n2.note_id === mine.note_id));
  const d = await db();
  const row = (await d.query(
    'SELECT deleted_at, deleted_by FROM core.property_note WHERE note_id = $1',
    [mine.note_id])).rows[0];
  assert.ok(row.deleted_at && row.deleted_by, 'the row survives, marked deleted');

  // Clean up the internal one too.
  const left = gone.notes.find((n2) => /will not go below/.test(n2.body));
  if (left) await jsonPost('/api/admin/note',
    { property_id: id, note_id: left.note_id, remove: true }, cookie);
});

// ---- severity --------------------------------------------------------
test('a flagged note raises the property flag until somebody resolves it', async (t) => {
  if (!available) return t.skip('no server');
  const cookie = await staffCookie();
  const list = await (await fetch(`${base}/api/admin/properties?q=SDI-1012`,
    { headers: { cookie } })).json();
  const id = list.rows[0].property_id;
  assert.equal(list.rows[0].flag, 'ok', 'a property with no open notes is clear');

  const a = await (await jsonPost('/api/admin/note',
    { property_id: id, body: 'Chase the agent for the rental restrictions.',
      visibility: 'internal', severity: 'attention' }, cookie)).json();
  assert.equal(a.flag.flag, 'attention');
  assert.equal(a.flag.open_attention, 1);

  // Critical outranks attention: a property with both flies the red one.
  const c = await (await jsonPost('/api/admin/note',
    { property_id: id, body: 'Failed inspection — falling out of escrow.',
      visibility: 'internal', severity: 'critical' }, cookie)).json();
  assert.equal(c.flag.flag, 'critical', 'the worst open note decides the flag');
  assert.equal(c.flag.open_critical, 1);
  assert.equal(c.flag.open_attention, 1);

  const crit = c.notes.find((n2) => /Failed inspection/.test(n2.body));
  const attn = c.notes.find((n2) => /rental restrictions/.test(n2.body));
  assert.equal(crit.is_open, true);

  // Resolving is the whole reason severity is not a ratchet: without it a
  // critical note written in March still stops somebody's morning in June.
  const r = await (await jsonPost('/api/admin/note',
    { property_id: id, note_id: crit.note_id, resolve: true,
      resolution: 'Re-inspected clean; seller credit agreed.' }, cookie)).json();
  assert.equal(r.flag.flag, 'attention', 'closing the critical one drops the flag back');
  const closed = r.notes.find((n2) => n2.note_id === crit.note_id);
  assert.equal(closed.is_open, false);
  assert.equal(closed.resolved_by_name, 'Jessica Pool', 'and who said so');
  assert.match(closed.resolution, /seller credit/);

  const reopened = await (await jsonPost('/api/admin/note',
    { property_id: id, note_id: crit.note_id, reopen: true }, cookie)).json();
  assert.equal(reopened.flag.flag, 'critical', 'and it can be put back');

  for (const n2 of [crit, attn]) {
    await jsonPost('/api/admin/note',
      { property_id: id, note_id: n2.note_id, remove: true }, cookie);
  }
  const end = await (await fetch(`${base}/api/admin/property?id=${id}`,
    { headers: { cookie } })).json();
  assert.equal(end.flag.flag, 'ok', 'a deleted note stops flying its flag');
});

test('the properties list filters by flag', async (t) => {
  if (!available) return t.skip('no server');
  const cookie = await staffCookie();
  const get = async (qs) => (await fetch(`${base}/api/admin/properties${qs}`,
    { headers: { cookie } })).json();

  const all = await get('');
  assert.equal(all.counts.all, all.rows.length, 'the tally covers everything listed');
  assert.equal(all.counts.ok + all.counts.attention + all.counts.critical, all.counts.all,
    'every property lands in exactly one bucket');

  const crit = await get('?flag=critical');
  assert.equal(crit.rows.length, all.counts.critical);
  assert.ok(crit.rows.every((r) => r.flag === 'critical'));
  // Counted over the whole list, not the filtered one -- otherwise filtering
  // to Critical hides the fact that anything else needs looking at.
  assert.equal(crit.counts.all, all.counts.all, 'the tallies do not collapse to the filter');

  const attn = await get('?flag=attention');
  assert.ok(attn.rows.every((r) => r.flag === 'attention'));

  // A property nobody has written a note about is CLEAR, not missing.
  // api.property_flag left-joins the notes onto every property, so it
  // reports 'ok' rather than nothing -- and the filter still coalesces,
  // because a property_admin row with no matching flag row would otherwise
  // fall out of every bucket and be unreachable from any chip.
  const clear = await get('?flag=ok');
  assert.equal(clear.rows.length, all.counts.ok);
  assert.ok(clear.rows.every((r) => (r.flag || 'ok') === 'ok'));
  const noNotes = clear.rows.find((r) => r.listing_ref === 'SDI-1009');
  assert.ok(noNotes, 'a property with no notes at all appears under Clear');
  assert.equal(noNotes.last_note_at, null, 'and it really has none');

  // Search AND flag, not search OR flag. The search is three ORs; without
  // parentheses around them a flag clause binds to the last one alone and
  // silently returns the wrong rows.
  const both = await get('?flag=critical&q=Memphis');
  assert.ok(both.rows.every((r) => r.flag === 'critical' && /Memphis/i.test(r.city)));
  const none = await get('?flag=critical&q=Irvine');
  assert.equal(none.rows.length, 0,
    'A FLAG FILTER THAT WIDENS ON SEARCH — the two must intersect, never union');

  const bogus = await get('?flag=; DROP TABLE core.property--');
  assert.equal(bogus.rows.length, all.rows.length,
    'an unrecognised flag is ignored rather than interpreted');
});

test('an ordinary note has nothing to resolve', async (t) => {
  if (!available) return t.skip('no server');
  const cookie = await staffCookie();
  const list = await (await fetch(`${base}/api/admin/properties?q=SDI-1012`,
    { headers: { cookie } })).json();
  const id = list.rows[0].property_id;
  const a = await (await jsonPost('/api/admin/note',
    { property_id: id, body: 'Spoke to the agent, nothing to report.',
      visibility: 'internal' }, cookie)).json();
  const n2 = a.notes.find((x) => /nothing to report/.test(x.body));
  assert.equal(n2.severity, 'note', 'unflagged by default — the level is opt-in');
  const bad = await jsonPost('/api/admin/note',
    { property_id: id, note_id: n2.note_id, resolve: true }, cookie);
  assert.equal(bad.status, 400);
  assert.match((await bad.json()).error, /nothing to resolve/);
  await jsonPost('/api/admin/note',
    { property_id: id, note_id: n2.note_id, remove: true }, cookie);
});

test("a buyer's flag is computed over the notes a buyer can see", async (t) => {
  if (!available) return t.skip('no server');
  const cookie = await staffCookie();
  const list = await (await fetch(`${base}/api/admin/properties?q=SDI-1013`,
    { headers: { cookie } })).json();
  const id = list.rows[0].property_id;
  const c = await (await jsonPost('/api/admin/note',
    { property_id: id, body: 'Title problem — do not proceed.',
      visibility: 'internal', severity: 'critical' }, cookie)).json();
  const note = c.notes.find((n2) => /Title problem/.test(n2.body));
  try {
    const anon = await (await fetch(`${base}/api/listings`)).json();
    const row = anon.rows.find((r2) => r2.property_id === id);
    assert.equal(row.flag, 'ok',
      'AN INTERNAL FLAG LEAKED TO AN ANONYMOUS CALLER — the flag is derived '
      + 'from notes the row policy lets the caller see, and a buyer must not '
      + 'be able to infer an internal note from a red pennant');
    assert.ok(!JSON.stringify(anon).includes('Title problem'));
  } finally {
    await jsonPost('/api/admin/note',
      { property_id: id, note_id: note.note_id, remove: true }, cookie);
  }
});

test('an empty note is refused', async (t) => {
  if (!available) return t.skip('no server');
  const cookie = await staffCookie();
  const list = await (await fetch(`${base}/api/admin/properties?q=SDI-1011`,
    { headers: { cookie } })).json();
  const r = await jsonPost('/api/admin/note',
    { property_id: list.rows[0].property_id, body: '   ', visibility: 'internal' }, cookie);
  assert.equal(r.status, 400);
  assert.match((await r.json()).error, /not a note/);
});

// ---- profile ---------------------------------------------------------
test('a profile is your own, and the photograph is stripped on the way in', async (t) => {
  if (!available) return t.skip('no server');
  assert.equal((await fetch(`${base}/api/profile`)).status, 403,
    'a profile belongs to somebody');

  const cookie = await staffCookie();
  const me = await (await fetch(`${base}/api/profile`, { headers: { cookie } })).json();
  assert.equal(me.email, 'jpool2@yahoo.com');
  assert.equal(me.role, 'admin');

  // The name is editable.
  const renamed = await (await jsonPost('/api/profile',
    { full_name: 'Jessica  Pool ' }, cookie)).json();
  assert.equal(renamed.full_name, 'Jessica  Pool', 'trimmed at the ends, not inside');
  await jsonPost('/api/profile', { full_name: 'Jessica Pool' }, cookie);

  // A one-character name is refused rather than stored.
  const bad = await jsonPost('/api/profile', { full_name: 'J' }, cookie);
  assert.equal(bad.status, 400);

  // Anything that is not an image is refused.
  const notImage = await jsonPost('/api/profile/photo',
    { image: 'data:text/plain;base64,aGVsbG8=' }, cookie);
  assert.equal(notImage.status, 400);
  assert.match((await notImage.json()).error, /not an image/);
});

// The regression this exists for: the upload route read the request body
// under the DEFAULT 8 KB cap, which every JSON endpoint here wants and no
// photograph on earth fits inside. A real 29 KB avatar was rejected before
// it reached any of the checks that were supposed to judge it -- and because
// an over-length body destroyed the socket, the browser got no response at
// all and the page sat there saying nothing.
//
// The old test passed throughout, because it only ever posted a few hundred
// bytes of synthetic colour. A photograph-sized photograph is the whole point.
test('a photograph-sized photograph uploads', async (t) => {
  if (!available) return t.skip('no server');
  const sharp = require('sharp');
  const cookie = await staffCookie();

  // Noise, not flat colour: a solid image compresses to a few hundred bytes
  // and would sail under the very limit this test exists to hold down.
  const px = Buffer.alloc(900 * 900 * 3);
  for (let i = 0; i < px.length; i++) px[i] = (i * 2654435761) % 256;
  const photo = await sharp(px, { raw: { width: 900, height: 900, channels: 3 } })
    .jpeg({ quality: 90 }).toBuffer();
  assert.ok(photo.length > 60 * 1024,
    `the fixture must be photograph-sized, got ${photo.length} bytes`);

  const r = await jsonPost('/api/profile/photo',
    { image: 'data:image/jpeg;base64,' + photo.toString('base64') }, cookie);
  assert.equal(r.status, 200,
    'A 29 KB AVATAR WAS REJECTED BY THE TRANSPORT before any rule about '
    + 'images got to judge it. The body cap on this route must clear '
    + 'base64 of the largest image the route claims to accept');
  const d = await r.json();
  assert.match(d.avatar, /^avatars\/[0-9a-f-]{36}\.jpg$/);
  assert.ok(d.bytes > 0 && d.bytes < photo.length,
    're-encoded down to an avatar, not stored as sent');

  // And it comes back out.
  const img = await fetch(`${base}/media/avatar/77777777-7777-7777-7777-777777777777`,
    { headers: { cookie } });
  assert.equal(img.status, 200);
  assert.equal(img.headers.get('content-type'), 'image/jpeg');

  await jsonPost('/api/profile/photo', { remove: true }, cookie);
});

test('an oversized body is answered, not dropped', async (t) => {
  if (!available) return t.skip('no server');
  const cookie = await staffCookie();
  // Past the transport limit. The caller must get a status code it can show
  // somebody -- a destroyed socket reaches the browser as a network failure
  // with nothing to report, which is what "nothing happens" looked like.
  const huge = 'A'.repeat(13 * 1024 * 1024);
  const r = await jsonPost('/api/profile/photo',
    { image: 'data:image/jpeg;base64,' + huge }, cookie);
  assert.equal(r.status, 413);
  assert.match((await r.json()).error, /too large/);
});

// A deployed change to the rail sitting invisible behind a browser's cached
// copy of nav.js is not a browser quirk. It is this server sending no
// freshness information at all, which leaves a browser free to guess.
test('static files can be revalidated rather than guessed at', async (t) => {
  if (!available) return t.skip('no server');
  const r = await fetch(`${base}/nav.js`);
  assert.equal(r.status, 200);
  const tag = r.headers.get('etag');
  assert.ok(tag, 'a static file must carry an ETag');
  assert.ok(r.headers.get('last-modified'), 'and a Last-Modified');
  assert.equal(r.headers.get('cache-control'), 'no-cache',
    'store it, but ask before every use -- not "do not store"');

  // Unchanged: a 304 and no body, so revalidating is cheap.
  const again = await fetch(`${base}/nav.js`, { headers: { 'If-None-Match': tag } });
  assert.equal(again.status, 304);
  assert.equal(await again.text(), '');

  // A different tag means the file moved on and must be sent in full.
  const stale = await fetch(`${base}/nav.js`, { headers: { 'If-None-Match': 'W/"0-0"' } });
  assert.equal(stale.status, 200);
  assert.ok((await stale.text()).length > 0);
});

test('the running build says which build it is', async (t) => {
  if (!available) return t.skip('no server');
  // Not gated: an anonymous visitor reporting a bug has to be able to say
  // which build they saw.
  const who = await (await fetch(`${base}/api/whoami`)).json();
  assert.ok(who.build, 'whoami carries the build');
  assert.match(who.build.version, /^\d+\.\d+\.\d+$|^dev$/,
    'a version read from the VERSION file, or an honest "dev"');
  // Run from a clone, so it must have found the real file rather than
  // falling back -- a fallback here would hide a broken stamp in the image.
  const onDisk = require('fs')
    .readFileSync(require('path').join(__dirname, '..', '..', 'VERSION'), 'utf8').trim();
  assert.equal(who.build.version, onDisk,
    'THE REPORTED VERSION MUST BE THE ONE IN THE FILE — a version that is '
    + 'wrong is worse than absent, being the thing somebody trusts while '
    + 'chasing the wrong bug');
});

// ---- sharing ---------------------------------------------------------
//
// READING THE PDF PROPERLY MATTERS HERE. pdfkit compresses its content
// streams, so searching the raw bytes for an address finds nothing whether
// the address is on the page or not -- which would make the central
// assertion of this whole feature pass by accident. So the streams are
// inflated and the text operators read, and there is a test below that
// checks this extractor can see an address when one IS present. A masking
// test that cannot detect the unmasked case proves nothing.
function pdfText(buf) {
  const zlib = require('zlib');
  let out = '';
  let i = 0;
  while ((i = buf.indexOf('stream', i)) !== -1) {
    if (buf.slice(i - 3, i).toString() === 'end') { i += 6; continue; }
    let start = i + 6;
    if (buf[start] === 0x0d) start++;
    if (buf[start] === 0x0a) start++;
    const end = buf.indexOf('endstream', start);
    if (end === -1) break;
    let text = null;
    try { text = zlib.inflateSync(buf.slice(start, end)).toString('latin1'); }
    catch { text = ''; }
    // pdfkit writes its glyphs as HEX strings inside TJ arrays --
    // [<534449> 0] TJ is "SDI". Reading for parenthesised literals instead
    // silently returned nothing, which made the masking assertion pass
    // whether or not the address was on the page.
    for (const m of text.matchAll(/<([0-9A-Fa-f]+)>/g)) {
      const h = m[1];
      if (h.length % 2) continue;
      out += Buffer.from(h, 'hex').toString('latin1');
    }
    // and literal strings, for anything not written that way
    for (const m of text.matchAll(/\(((?:\\.|[^\\()])*)\)\s*T[jJ]/g)) {
      out += m[1].replace(/\\([()\\])/g, '$1') + ' ';
    }
    i = end + 9;
  }
  return out;
}


test('a shared document is masked by default, for everybody', async (t) => {
  if (!available) return t.skip('no server');
  const cookie = await staffCookie();
  const list = await (await fetch(`${base}/api/admin/properties?q=SDI-1013`,
    { headers: { cookie } })).json();
  const id = list.rows[0].property_id;
  const addr = list.rows[0].street_address;
  assert.ok(addr, 'the fixture has an address to withhold');

  // Staff CAN see the address, and still get a masked document unless they
  // ask. The default is not "masked for people who cannot see it" -- it is
  // masked for everyone, because the common case is sending it onward.
  const r = await fetch(`${base}/api/share/${id}.pdf?to=A%20prospect`,
    { headers: { cookie } });
  assert.equal(r.status, 200);
  assert.equal(r.headers.get('content-type'), 'application/pdf');
  assert.match(r.headers.get('cache-control'), /no-store/);
  const raw = Buffer.from(await r.arrayBuffer());
  assert.equal(raw.slice(0, 5).toString(), '%PDF-');
  const masked = pdfText(raw);
  assert.ok(masked.length > 200, 'the extractor read the document');
  assert.ok(!masked.includes(addr),
    'A DEFAULT SHARE CARRIED THE STREET ADDRESS — masked is the default for '
    + 'every caller including staff, or the first use on a prospect leaks');
  assert.ok(masked.includes('WITHHELD'), 'and it says so on its face');
  // The numbers are never the thing withheld -- an investor decides on the
  // cash flow and only then signs for the identity of the house.
  assert.ok(/NET OPERATING INCOME|Net operating income/i.test(masked),
    'a masked document still carries the full financial detail');
});

test('an unmask request is answered by the database, not honoured', async (t) => {
  if (!available) return t.skip('no server');
  const staff = await staffCookie();
  const list = await (await fetch(`${base}/api/admin/properties?q=SDI-1013`,
    { headers: { cookie: staff } })).json();
  const id = list.rows[0].property_id;
  const addr = list.rows[0].street_address;

  // Staff asked, and may, so they get it -- with the document saying plainly
  // what it contains.
  const yes = await fetch(`${base}/api/share/${id}.pdf?unmask=1&to=Ruth%20Okonkwo`,
    { headers: { cookie: staff } });
  assert.equal(yes.status, 200);
  const full = pdfText(Buffer.from(await yes.arrayBuffer()));
  assert.ok(full.includes(addr),
    'a permitted unmask releases the address -- and this assertion passing is '
    + 'what proves the masked test above is not passing vacuously');
  assert.ok(full.includes('RELEASED'), 'and the document is marked as carrying it');

  // An anonymous caller asks for exactly the same thing. The query string is
  // identical; the answer is not, because the answer is not the query
  // string's to give.
  const no = await fetch(`${base}/api/share/${id}.pdf?unmask=1&to=Anyone`);
  assert.equal(no.status, 200, 'the masked document is still produced');
  const denied = pdfText(Buffer.from(await no.arrayBuffer()));
  assert.ok(!denied.includes(addr),
    'UNMASK=1 OPENED THE GATE FOR AN UNAUTHORISED CALLER — the parameter is a '
    + 'request and sec.can_see_address() is the answer; a checkbox must never '
    + 'be the thing that decides');
  assert.ok(denied.includes('WITHHELD'));
});

test('every generated document is logged, with who and to whom', async (t) => {
  if (!available) return t.skip('no server');
  const cookie = await staffCookie();
  const list = await (await fetch(`${base}/api/admin/properties?q=SDI-1020`,
    { headers: { cookie } })).json();
  const id = list.rows[0].property_id;
  const d = await db();
  const before = Number((await d.query(
    'SELECT count(*) n FROM core.share_event WHERE property_id = $1', [id])).rows[0].n);

  await fetch(`${base}/api/share/${id}.pdf?to=Marcus%20Pell%20at%20Northgate`,
    { headers: { cookie } });
  await fetch(`${base}/api/share/${id}.pdf?unmask=1&to=Ines%20Duarte`,
    { headers: { cookie } });

  const rows = (await d.query(
    `SELECT unmasked, recipient, shared_by FROM core.share_event
      WHERE property_id = $1 ORDER BY created_at`, [id])).rows.slice(before);
  assert.equal(rows.length, 2, 'one row per document, not one per property');
  assert.equal(rows[0].unmasked, false);
  assert.match(rows[0].recipient, /Northgate/, 'who it went to, as given');
  assert.equal(rows[1].unmasked, true, 'and whether it carried the address');
  assert.ok(rows[0].shared_by, 'and who made it');

  await d.query('DELETE FROM core.share_event WHERE property_id = $1', [id]);
});

test('a share without a recipient is refused', async (t) => {
  if (!available) return t.skip('no server');
  const cookie = await staffCookie();
  const list = await (await fetch(`${base}/api/admin/properties?q=SDI-1013`,
    { headers: { cookie } })).json();
  const id = list.rows[0].property_id;
  // "Who was it sent to" is the question the log exists to answer, so a
  // document that cannot answer it is not generated at all.
  const r = await fetch(`${base}/api/share/${id}.pdf?to=`, { headers: { cookie } });
  assert.equal(r.status, 400);
  assert.match((await r.json()).error, /say who this is going to/);
  const r2 = await fetch(`${base}/api/share/${id}.pdf?to=..`, { headers: { cookie } });
  assert.equal(r2.status, 400, 'and a placeholder is not a recipient');
});

test('the unmask control is offered only where it would be honoured', async (t) => {
  if (!available) return t.skip('no server');
  const cookie = await staffCookie();
  const list = await (await fetch(`${base}/api/admin/properties?q=SDI-1013`,
    { headers: { cookie } })).json();
  const id = list.rows[0].property_id;

  const asStaff = await (await fetch(`${base}/api/share-context/${id}`,
    { headers: { cookie } })).json();
  assert.equal(asStaff.may_unmask, true);

  const asAnon = await (await fetch(`${base}/api/share-context/${id}`)).json();
  assert.equal(asAnon.may_unmask, false,
    'hiding the control is a courtesy; the refusal above is the boundary');
});

// The break this exists for: server.js gained require('./share') and the
// Dockerfile's COPY line did not gain share.js. The image built, pushed,
// passed all 71 of these tests, and then refused connections on a machine
// somebody had already deployed to. Nothing in a test suite that runs
// against a source tree can see a file the IMAGE is missing -- so this test
// reads the Dockerfile.
test('the image copies every module the server imports', async () => {
  const fs = require('fs');
  const path = require('path');
  const root = path.join(__dirname, '..');
  const src = fs.readFileSync(path.join(root, 'server.js'), 'utf8');
  const mods = [...src.matchAll(/require\(['"](\.\/[^'"]+)['"]\)/g)].map((m) => m[1]);
  assert.ok(mods.length >= 4, 'found the local imports');

  for (const m of mods) {
    const file = m.slice(2) + (m.endsWith('.js') ? '' : '.js');
    assert.ok(fs.existsSync(path.join(root, file)), `${file} exists in the source tree`);
  }

  const dockerfile = fs.readFileSync(path.join(root, 'Dockerfile'), 'utf8');
  const copies = [...dockerfile.matchAll(/^COPY\s+(.+?)\s+\.\/$/gm)]
    .flatMap((m) => m[1].split(/\s+/));
  // A glob covers everything at this level and cannot go stale, which is the
  // point. An explicit list is allowed only if it is actually complete --
  // and it went stale twice, so the glob is what should be here.
  const globbed = copies.some((c) => c === '*.js');
  for (const m of mods) {
    const file = m.slice(2) + (m.endsWith('.js') ? '' : '.js');
    assert.ok(globbed || copies.includes(file),
      `THE IMAGE WOULD NOT CONTAIN ${file} — server.js requires it and the `
      + 'Dockerfile does not copy it. This breaks only in a deployed '
      + 'container, on its first request, long after every test has passed');
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
