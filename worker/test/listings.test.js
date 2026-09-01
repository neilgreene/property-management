'use strict';
// The nightly listing sweep, against a real database.
//
// The adapter is a stub, deliberately. What is being tested is not
// whether an HTTP client works -- it is the discipline around it: that an
// error never becomes an absence, that an advisory source cannot move a
// status, and that a listing which comes back to market comes back
// immediately. Those are the properties a live feed will stress, and they
// are testable without one.
const test = require('node:test');
const assert = require('node:assert');
const { Pool } = require('pg');
const { run } = require('../src/listings/nightly');

// Picked at setup rather than hard-coded, and its original status is
// captured and restored. An earlier version of this file named a listing
// that happens to be seeded 'sold', silently did nothing, and then
// "restored" it to active -- quietly rewriting the demo dataset. A test
// that assumes a fixture's state instead of reading it is a test that
// eventually edits it.
let pool, available = true, pid = null, ref = null, originalStatus = null;

async function db() {
  if (pool) return pool;
  pool = new Pool({
    host: process.env.PGHOST || '127.0.0.1',
    database: process.env.PGDATABASE || 'sdi',
    user: 'sdi_test_admin',
    password: process.env.PGTESTPASSWORD || 'demo_test_pw',
    max: 2,
  });
  await pool.query('SELECT 1');
  return pool;
}

// An adapter map that answers from a script. Injected into run() rather
// than patched onto the module: nightly.js destructures build() at
// import, so a monkey-patch would be a test that quietly tests nothing.
function stub(code, answers) {
  return new Map([[code, {
    code,
    async check() { return answers.shift() || { outcome: 'error', error: 'script exhausted' }; },
  }]]);
}

test('setup', async (t) => {
  try { await db(); } catch { available = false; return t.skip('no database'); }
  const d = await db();
  const r = await d.query(
    `SELECT property_id, listing_ref, status FROM core.property
      WHERE status = 'active' ORDER BY listing_ref LIMIT 1`);
  if (!r.rows.length) { available = false; return t.skip('demo dataset not loaded'); }
  ({ property_id: pid, listing_ref: ref, status: originalStatus } = r.rows[0]);
  await d.query(`UPDATE feed.listing_source SET active = true WHERE source_code = 'MLS_RESO'`);
  await d.query(
    `INSERT INTO feed.property_external (property_id, source_code, external_id)
     VALUES ($1,'MLS_RESO','TEST-SWEEP') ON CONFLICT DO NOTHING`, [pid]);
});

async function status(d) {
  return (await d.query('SELECT status FROM core.property WHERE property_id = $1', [pid]))
    .rows[0].status;
}

test('an error is never read as an absence', async (t) => {
  if (!available) return t.skip('no database');
  const d = await db();
  const tally = await run(d, { gapMs: 0, limit: 200,
    adapters: stub('MLS_RESO', [{ outcome: 'error', error: 'HTTP 503' }]) });
  assert.equal(tally.errors, 1);
  assert.equal(await status(d), 'active', 'a failing feed must not retire a listing');
  const miss = (await d.query(
    'SELECT miss_streak FROM feed.property_external WHERE property_id=$1 AND source_code=$2',
    [pid, 'MLS_RESO'])).rows[0].miss_streak;
  assert.equal(miss, 0, 'an error must not advance the miss streak');
});

test('two agreeing sightings move it to pending; one does not', async (t) => {
  if (!available) return t.skip('no database');
  const d = await db();
  await run(d, { gapMs: 0, limit: 200,
    adapters: stub('MLS_RESO', [{ outcome: 'found', raw_status: 'Pending' }]) });
  assert.equal(await status(d), 'active', 'one sighting is not evidence');

  await run(d, { gapMs: 0, limit: 200,
    adapters: stub('MLS_RESO', [{ outcome: 'found', raw_status: 'Pending' }]) });
  assert.equal(await status(d), 'pending');
});

test('escrow fails: back to active on the first sighting', async (t) => {
  if (!available) return t.skip('no database');
  const d = await db();
  const tally = await run(d, { gapMs: 0, limit: 200,
    adapters: stub('MLS_RESO', [{ outcome: 'found', raw_status: 'Active' }]) });
  assert.equal(await status(d), 'active',
    'a relisted property must be saleable again immediately');
  assert.equal(tally.changed.some((c) => c.result === 'pending -> active'), true);
});

test('an advisory source flags rather than acts', async (t) => {
  if (!available) return t.skip('no database');
  const d = await db();
  await d.query(
    `INSERT INTO feed.property_external (property_id, source_code, external_id)
     VALUES ($1,'RENTCAST','TEST-ADVISORY') ON CONFLICT DO NOTHING`, [pid]);
  await d.query(`UPDATE feed.listing_source SET active = true WHERE source_code='RENTCAST'`);
  const before = (await d.query(
    `SELECT count(*)::int n FROM feed.review_flag WHERE property_id=$1 AND resolved_at IS NULL`,
    [pid])).rows[0].n;

  try {
    await run(d, { gapMs: 0, limit: 200,
      adapters: stub('RENTCAST', [{ outcome: 'found', raw_status: 'Pending' }]) });
    assert.equal(await status(d), 'active', 'an advisory source must not change a status');
    const after = (await d.query(
      `SELECT count(*)::int n FROM feed.review_flag WHERE property_id=$1 AND resolved_at IS NULL`,
      [pid])).rows[0].n;
    assert.equal(after > before, true, 'it must raise a flag instead');
  } finally {
    await d.query(`UPDATE feed.listing_source SET active = false WHERE source_code='RENTCAST'`);
  }
});

test('teardown: the demo dataset is left exactly as it was found', async (t) => {
  if (!available) return t.skip('no database');
  const d = await db();
  await d.query('DELETE FROM feed.status_change WHERE property_id = $1', [pid]);
  await d.query('DELETE FROM feed.review_flag   WHERE property_id = $1', [pid]);
  await d.query('DELETE FROM feed.observation   WHERE property_id = $1', [pid]);
  await d.query(`DELETE FROM feed.property_external
                  WHERE property_id = $1 AND source_code IN ('MLS_RESO','RENTCAST')`, [pid]);
  await d.query(`UPDATE feed.listing_source SET active = false
                  WHERE source_code IN ('MLS_RESO','RENTCAST')`);
  await d.query('UPDATE core.property SET status = $2 WHERE property_id = $1',
                [pid, originalStatus]);
  assert.equal(await status(d), originalStatus);
});

test.after(async () => { if (pool) await pool.end(); });
