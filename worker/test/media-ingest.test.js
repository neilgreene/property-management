'use strict';
// End-to-end for the media store: a file lands, is stripped and stored,
// and the row it creates is invisible until somebody publishes it.
//
// The EXIF test is the one that matters. It builds an image carrying GPS
// coordinates, ingests it, and asserts the coordinates are gone from the
// stored bytes. If that ever regresses, the address gate is bypassed by
// anyone who downloads a photograph, and nothing else in the suite would
// notice.
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs/promises');
const path = require('path');
const os = require('os');
const { Pool } = require('pg');

let sharp = null;
try { sharp = require('sharp'); } catch { /* reported below */ }
const ingest = require('../src/media/ingest');

let db, app, integration, root, available = true;

// sdi_test_admin owns the fixtures but cannot SET ROLE -- it is not a
// member of the application roles. sdi_app is, which is how the web tier
// becomes an investor for one transaction. And sdi_integration is what the
// worker actually connects as, so the grant test uses it directly rather
// than by assuming it: a GRANT is only real when the role that uses it is
// the role that was tested.
function as(user, password) {
  return new Pool({
    host: process.env.PGHOST || '127.0.0.1',
    database: process.env.PGDATABASE || 'sdi',
    user, password, max: 2,
  });
}

function admin() {
  return new Pool({
    host: process.env.PGHOST || '127.0.0.1',
    database: process.env.PGDATABASE || 'sdi',
    user: 'sdi_test_admin', password: 'demo_test_pw', max: 4,
  });
}

test('setup: database and sharp', async (t) => {
  if (!sharp) {
    throw new Error('sharp is not installed. `cd worker && npm install` first — '
                  + 'without it nothing strips EXIF and the ingest tests are '
                  + 'meaningless rather than merely absent.');
  }
  try {
    db = admin();
    await db.query('SELECT 1');
  } catch (e) {
    available = false;
    if (process.env.SDI_TEST_NO_DB !== '1') {
      throw new Error(`${e.message}\n\nStart PostgreSQL and run ./db-rebuild.sh, `
                    + 'or set SDI_TEST_NO_DB=1.');
    }
    return t.skip('no database');
  }
  app = as('sdi_app', 'demo_app_pw');
  integration = as('sdi_integration', 'demo_int_pw');
  root = await fs.mkdtemp(path.join(os.tmpdir(), 'sdi-media-'));
  for (const d of ['inbox', 'inbox/_unsorted', 'store', 'quarantine', 'purged']) {
    await fs.mkdir(path.join(root, d), { recursive: true });
  }
});

test('a folder name yields its listing reference, label and all', () => {
  assert.equal(ingest.listingRefFromFolder('SDI-1009'), 'SDI-1009');
  assert.equal(ingest.listingRefFromFolder('SDI-1009 - Columbus OH - 5bd'), 'SDI-1009');
  assert.equal(ingest.listingRefFromFolder('sdi-1010'), 'SDI-1010');
  assert.equal(ingest.listingRefFromFolder('_unsorted'), null);
  assert.equal(ingest.listingRefFromFolder('holiday photos'), null);
});

// Builds a JPEG carrying GPS. Written by hand rather than with a fixture
// file so the test states exactly what it is proving.
async function withGps() {
  const base = await sharp({ create: { width: 800, height: 600, channels: 3,
                                       background: { r: 120, g: 140, b: 160 } } })
    .jpeg().toBuffer();
  const exif = require('sharp');           // sharp writes EXIF via withExif
  return await exif(base).withExif({
    IFD0: { Make: 'TestPhone', Model: 'X1' },
    GPS:  { GPSLatitudeRef: 'N', GPSLatitude: '33/1 40/1 30/1',
            GPSLongitudeRef: 'W', GPSLongitude: '117/1 46/1 12/1' },
  }).toBuffer();
}

test('ingest strips EXIF, including the GPS coordinates', async (t) => {
  if (!available) return t.skip('no database');
  const buf = await withGps();
  const before = await sharp(buf).metadata();
  assert.ok(before.exif && before.exif.length > 0, 'the fixture must HAVE exif');

  const dir = path.join(root, 'inbox', 'SDI-1009 - Columbus OH');
  await fs.mkdir(dir, { recursive: true });
  await fs.writeFile(path.join(dir, 'IMG_4471.jpg'), buf);

  const { results } = await ingest.scan({ db, sharp, root, settleMs: 5 });
  const r = results.find((x) => x.file === 'IMG_4471.jpg');
  assert.equal(r.outcome, 'ingested', JSON.stringify(r));
  assert.equal(r.strippedExif, true, 'the source is recorded as having carried exif');

  const stored = await fs.readFile(path.join(root, 'store', 'SDI-1009',
                                             `${r.mediaId}-orig.jpg`));
  const after = await sharp(stored).metadata();
  assert.ok(!after.exif, 'STORED BYTES STILL CARRY EXIF — the address is in the file');
  // And the raw bytes, in case a future sharp reports metadata differently.
  assert.ok(!stored.includes(Buffer.from('TestPhone')), 'camera make survived');
  assert.ok(!stored.includes(Buffer.from('GPS')), 'a GPS tag survived');
});

// The scan above ran on the fixture pool. This one runs it the way the
// deployment does -- connected as sdi_integration -- because that is the
// only way to find out whether the grants are real. The first version of
// this ingest read core.property directly; every RLS policy on that table
// is scoped TO a named application role, sdi_integration is not one, and
// the read returned zero rows rather than an error. Every folder came back
// as an unknown listing and the scanner looked like it was working. A test
// on the admin pool could never have seen it.
test('the scan works as the role the worker actually connects as', async (t) => {
  if (!available) return t.skip('no database');
  const dir = path.join(root, 'inbox', 'SDI-1010 - Memphis TN');
  await fs.mkdir(dir, { recursive: true });
  await fs.writeFile(path.join(dir, 'as-integration.jpg'),
    await sharp({ create: { width: 640, height: 480, channels: 3,
                            background: { r: 200, g: 180, b: 160 } } }).jpeg().toBuffer());

  const { results } = await ingest.scan({ db: integration, sharp, root, settleMs: 5 });
  const r = results.find((x) => x.file === 'as-integration.jpg');
  assert.equal(r.outcome, 'ingested',
    `the worker's own role could not ingest: ${JSON.stringify(r)}`);
  assert.equal(r.listingRef, 'SDI-1010');
});

test('the filename is the media_id, and both variants are written', async (t) => {
  if (!available) return t.skip('no database');
  const { rows } = await db.query(
    "SELECT media_id, storage_path, thumb_path FROM core.property_media"
    + " WHERE original_name = 'IMG_4471.jpg'");
  assert.equal(rows.length, 1);
  const m = rows[0];
  assert.equal(m.storage_path, `store/SDI-1009/${m.media_id}-orig.jpg`);
  assert.equal(m.thumb_path,   `store/SDI-1009/${m.media_id}-720.jpg`);
  await fs.access(path.join(root, m.storage_path));
  await fs.access(path.join(root, m.thumb_path));
});

test('an arriving photograph is pending and gated, not published', async (t) => {
  if (!available) return t.skip('no database');
  const { rows } = await db.query(
    "SELECT state, reveals_location, is_primary FROM core.property_media"
    + " WHERE original_name = 'IMG_4471.jpg'");
  assert.equal(rows[0].state, 'pending',
    'a photograph must not be live because it arrived');
  assert.equal(rows[0].reveals_location, true,
    'fail closed: unclassified means assumed identifying');
  assert.equal(rows[0].is_primary, false);
});

test('a pending photograph is invisible to an investor', async (t) => {
  if (!available) return t.skip('no database');
  const { rows } = await db.query(
    "SELECT media_id FROM core.property_media WHERE original_name = 'IMG_4471.jpg'");
  const id = rows[0].media_id;
  const c = await app.connect();
  try {
    await c.query('BEGIN');
    await c.query('SET LOCAL ROLE sdi_investor');
    await c.query("SELECT set_config('app.actor_id',"
                + " '11111111-1111-1111-1111-111111111111', true)");  // Ruth, gate open
    const r = await c.query('SELECT 1 FROM api.property_media WHERE media_id = $1', [id]);
    assert.equal(r.rows.length, 0,
      'even a fully gated investor must not see an unpublished photograph');
    // And the route's own lookup, which is what actually decides whether
    // bytes leave the building.
    const b = await c.query('SELECT 1 FROM api.media_bytes WHERE media_id = $1', [id]);
    assert.equal(b.rows.length, 0, 'no row, no path, no bytes');
  } finally { await c.query('ROLLBACK').catch(() => {}); c.release(); }
});

test('a published photograph resolves to a path for a caller past the fee gate', async (t) => {
  if (!available) return t.skip('no database');
  const { rows } = await db.query(
    "SELECT media_id FROM core.property_media WHERE original_name = 'IMG_4471.jpg'");
  const id = rows[0].media_id;
  await db.query("SELECT set_config('app.actor_id',"
               + " '66666666-6666-6666-6666-666666666666', false)");
  await db.query('SELECT api.media_publish($1)', [[id]]);
  await db.query('SELECT api.media_set_gated($1, false)', [id]);

  const asInvestor = async (actor) => {
    const c = await app.connect();
    try {
      await c.query('BEGIN');
      await c.query('SET LOCAL ROLE sdi_investor');
      await c.query("SELECT set_config('app.actor_id', $1, true)", [actor]);
      return (await c.query('SELECT storage_path FROM api.media_bytes'
                          + ' WHERE media_id = $1', [id])).rows;
    } finally { await c.query('ROLLBACK').catch(() => {}); c.release(); }
  };

  // Ruth's agreement is on file, so she gets the path. This also proves the
  // route's own lookup works for a reader role: they hold SELECT on
  // core.property_media but no USAGE on schema core, so reading the table
  // directly would 404 every photograph for everyone but an admin.
  const ruth = await asInvestor('11111111-1111-1111-1111-111111111111');
  assert.equal(ruth.length, 1, 'a caller past the fee gate must get the path');
  assert.match(ruth[0].storage_path, /^store\/SDI-1009\//);

  // Marcus has not signed. Under masked media mode a photograph is band 2
  // like the address, so he gets no row and therefore no bytes -- not a
  // smaller image, not a watermark, nothing to fetch.
  const marcus = await asInvestor('22222222-2222-2222-2222-222222222222');
  assert.equal(marcus.length, 0,
    'an ungated caller resolved a photograph to a file path');

  // Put it back the way the later tests expect.
  await db.query('SELECT api.media_set_gated($1, true)', [id]);
  await db.query('SELECT api.media_unpublish($1, $2, $3)', [[id], 'restore fixture', 30]);
  const back = await db.query('SELECT state FROM core.property_media WHERE media_id = $1', [id]);
  assert.equal(back.rows[0].state, 'unpublished', 'fixture restored');
});

test('the ingest role can register but cannot publish', async (t) => {
  if (!available) return t.skip('no database');
  const { rows } = await db.query(
    "SELECT media_id FROM core.property_media WHERE original_name = 'IMG_4471.jpg'");
  await assert.rejects(
    () => integration.query('SELECT api.media_publish($1)', [[rows[0].media_id]]),
    /permission denied/i,
    'an unattended scanner that can publish defeats the review step');
});

test('a file that is not an image is quarantined, not stored', async (t) => {
  if (!available) return t.skip('no database');
  const dir = path.join(root, 'inbox', 'SDI-1009 - Columbus OH');
  await fs.writeFile(path.join(dir, 'notes.jpg'), 'this is text, not a photograph');
  const { results } = await ingest.scan({ db, sharp, root, settleMs: 5 });
  const r = results.find((x) => x.file === 'notes.jpg');
  assert.equal(r.outcome, 'quarantined');
  const q = await fs.readdir(path.join(root, 'quarantine'));
  assert.ok(q.some((f) => f.endsWith('notes.jpg')), 'the file is kept for diagnosis');
});

test('the same photograph twice makes one row', async (t) => {
  if (!available) return t.skip('no database');
  const buf = await withGps();
  const dir = path.join(root, 'inbox', 'SDI-1009 - Columbus OH');
  await fs.writeFile(path.join(dir, 'copy-of-4471.jpg'), buf);
  await ingest.scan({ db, sharp, root, settleMs: 5 });
  const { rows } = await db.query(
    "SELECT count(*)::int AS n FROM core.property_media"
    + " WHERE property_id = (SELECT property_id FROM core.property"
    + "                       WHERE listing_ref = 'SDI-1009')"
    + "   AND storage_path IS NOT NULL");
  assert.equal(rows[0].n, 1, 'a re-copied folder must not duplicate the gallery');
});

test('an unknown listing folder is reported, never guessed at', async (t) => {
  if (!available) return t.skip('no database');
  await fs.mkdir(path.join(root, 'inbox', 'SDI-9999'), { recursive: true });
  const { results } = await ingest.scan({ db, sharp, root, settleMs: 5 });
  assert.ok(results.some((x) => x.outcome === 'unknown-listing'
                             && x.listingRef === 'SDI-9999'));
});

test('_unsorted is counted, not ingested', async (t) => {
  if (!available) return t.skip('no database');
  const buf = await withGps();
  await fs.writeFile(path.join(root, 'inbox', '_unsorted', 'stray.jpg'), buf);
  const { results } = await ingest.scan({ db, sharp, root, settleMs: 5 });
  const u = results.find((x) => x.folder === '_unsorted');
  assert.equal(u.outcome, 'unsorted');
  assert.equal(u.files, 1);
});

test('publishing makes it visible, and unpublishing sets a purge date', async (t) => {
  if (!available) return t.skip('no database');
  const { rows } = await db.query(
    "SELECT media_id FROM core.property_media WHERE original_name = 'IMG_4471.jpg'");
  const id = rows[0].media_id;

  await db.query("SELECT set_config('app.actor_id',"
               + " '66666666-6666-6666-6666-666666666666', false)");   // Dan, admin
  assert.equal((await db.query('SELECT api.media_publish($1) AS n', [[id]])).rows[0].n, 1);

  const v = await db.query('SELECT state, published_at FROM core.property_media'
                         + ' WHERE media_id = $1', [id]);
  assert.equal(v.rows[0].state, 'published');
  assert.ok(v.rows[0].published_at);

  await db.query('SELECT api.media_unpublish($1, $2, $3)', [[id], 'test', 30]);
  const u = await db.query('SELECT state, purge_after, deleted_at'
                         + ' FROM core.property_media WHERE media_id = $1', [id]);
  assert.equal(u.rows[0].state, 'unpublished');
  assert.ok(u.rows[0].deleted_at, 'unpublish records when');
  assert.ok(u.rows[0].purge_after, 'and when the bytes may go — not now');

  // Restore, so the fixture is left as the next test would expect it.
  await db.query('SELECT api.media_publish($1)', [[id]]);
});

test('legal hold keeps a due purge off the list', async (t) => {
  if (!available) return t.skip('no database');
  const { rows } = await db.query(
    "SELECT media_id FROM core.property_media WHERE original_name = 'IMG_4471.jpg'");
  const id = rows[0].media_id;
  await db.query("SELECT set_config('app.actor_id',"
               + " '66666666-6666-6666-6666-666666666666', false)");
  await db.query('SELECT api.media_unpublish($1, $2, $3)', [[id], 'test', 0]);

  let due = await db.query('SELECT media_id FROM api.media_purge_due()');
  assert.ok(due.rows.some((r) => r.media_id === id), 'due with no hold');

  await db.query('SELECT api.media_set_hold($1, true, $2)', [id, 'in dispute']);
  due = await db.query('SELECT media_id FROM api.media_purge_due()');
  assert.ok(!due.rows.some((r) => r.media_id === id),
    'a hold must beat retention, or cleanup destroys the evidence');

  await db.query('SELECT api.media_set_hold($1, false, $2)', [id, 'released']);
});

test('a gated photograph cannot be made the card image', async (t) => {
  if (!available) return t.skip('no database');
  const { rows } = await db.query(
    "SELECT media_id FROM core.property_media WHERE original_name = 'IMG_4471.jpg'");
  const id = rows[0].media_id;
  await db.query("SELECT set_config('app.actor_id',"
               + " '66666666-6666-6666-6666-666666666666', false)");
  await db.query('SELECT api.media_publish($1)', [[id]]);
  await assert.rejects(
    () => db.query('SELECT api.media_set_primary($1)', [id]),
    /location-revealing/,
    'the card is the one image every ungated visitor sees');
});

test('teardown', async (t) => {
  if (!available) return t.skip('no database');
  await db.query("DELETE FROM core.property_media WHERE storage_path IS NOT NULL");
  await db.end(); await app.end(); await integration.end();
  await fs.rm(root, { recursive: true, force: true });
});
