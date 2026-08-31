'use strict';
// Migration passes. The cases that matter are ordering and resumability:
// a link whose endpoints are not yet mapped, and a pass re-run after a crash.
const test = require('node:test');
const assert = require('node:assert');
const { Pool } = require('pg');
const { jsonAdapter, assertAdapter } = require('../src/migrate/source');
const { loadPeople, loadProperties, loadLinks, reconcile } = require('../src/migrate/passes');
const { drainOnce } = require('../src/outbox');

const cfg = { locationId: 'loc_test', maxRetries: 3 };
const P1 = '11111111-aaaa-4aaa-8aaa-111111111111';
const R1 = '22222222-bbbb-4bbb-8bbb-222222222222';

const EXTRACT = {
  people: [
    { sourceId: 'espo_p_1', personId: P1, email: 'inv@example.com',
      firstName: 'Ada', lastName: 'Investor' },
  ],
  properties: [
    { sourceId: 'espo_r_1', propertyId: R1, fields: { city: 'Cleveland', list_price: 184000 } },
  ],
  links: [{ propertyId: R1, personId: P1, kind: 'assigned_investor' }],
  deals: [],
};

let pool, available = true;
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
async function reset(d) {
  await d.query('DELETE FROM ghl.outbox');
  await d.query("DELETE FROM ghl.id_map WHERE location_id='loc_test'");
}

test('database reachable', async (t) => {
  try { await db(); } catch (e) { available = false; t.skip(`no database: ${e.message}`); }
});

test('adapter contract rejects an incomplete implementation', () => {
  assert.throws(() => assertAdapter({ people: () => {} }), /missing properties/);
});

test('people and properties stage into the outbox', async (t) => {
  if (!available) return t.skip('no database');
  const d = await db(); await reset(d);
  const src = jsonAdapter(EXTRACT);
  assert.deepEqual(await loadPeople(d, src, cfg), { queued: 1, skipped: 0 });
  assert.deepEqual(await loadProperties(d, src, cfg), { queued: 1, skipped: 0 });
  const { rows } = await d.query("SELECT count(*)::int n FROM ghl.outbox WHERE state='pending'");
  assert.equal(rows[0].n, 2);
});

test('a re-run after a crash does not duplicate work', async (t) => {
  if (!available) return t.skip('no database');
  const d = await db();
  const src = jsonAdapter(EXTRACT);
  // Same passes again, as if the process died and was restarted.
  assert.deepEqual(await loadPeople(d, src, cfg), { queued: 0, skipped: 1 });
  assert.deepEqual(await loadProperties(d, src, cfg), { queued: 0, skipped: 1 });
  const { rows } = await d.query('SELECT count(*)::int n FROM ghl.outbox');
  assert.equal(rows[0].n, 2, 'idempotency key collapsed the repeat');
});

test('links cannot resolve before their endpoints are mapped', async (t) => {
  if (!available) return t.skip('no database');
  const d = await db();
  const out = await loadLinks(d, jsonAdapter(EXTRACT), cfg);
  assert.equal(out.queued, 0);
  assert.equal(out.unresolved.length, 1,
    'a link whose endpoints have no GHL id must be reported, never silently dropped');
});

test('after the drain, the same link pass resolves', async (t) => {
  if (!available) return t.skip('no database');
  const d = await db();
  let n = 0;
  const client = {
    async upsertContact() { return { contact: { id: `ghl_c_${++n}` } }; },
    async createRecord()  { return { record:  { id: `ghl_r_${++n}` } }; },
  };
  const drained = await drainOnce(client, d, cfg);
  assert.equal(drained.sent, 2);

  const out = await loadLinks(d, jsonAdapter(EXTRACT), cfg);
  assert.equal(out.unresolved.length, 0);
  assert.equal(out.queued, 1, 'the association pass only works after passes 3 and 4');
});

test('reconcile reports the shortfall between source and destination', async (t) => {
  if (!available) return t.skip('no database');
  const d = await db();
  const r = await reconcile(d, jsonAdapter(EXTRACT), cfg);
  assert.equal(r.source.people, 1);
  assert.equal(r.mapped.person, 1);
  assert.equal(r.shortfall.person, 0);
  assert.equal(r.shortfall.property, 0);
});

test('reconcile surfaces a shortfall when a record never landed', async (t) => {
  if (!available) return t.skip('no database');
  const d = await db();
  const bigger = { ...EXTRACT, people: [...EXTRACT.people, { sourceId: 'espo_p_2', personId: null }] };
  const r = await reconcile(d, jsonAdapter(bigger), cfg);
  assert.equal(r.shortfall.person, 1, 'a missing record must show up as a number, not a silence');
});

test.after(async () => { if (pool) await pool.end(); });
