'use strict';
// End-to-end against a real database. Proves the loop that matters:
// a GHL API response -> the worker -> ghl.fee_agreement -> the gate opens
// -> the investor's address becomes visible through api.property.
//
// Skips cleanly when no database is reachable, so `npm test` still works
// on a machine that has not run ./run.sh.
const test = require('node:test');
const assert = require('node:assert');
const { Pool } = require('pg');
const { syncDocuments } = require('../src/sync/documents');
const { syncTransactions } = require('../src/sync/transactions');

const MARCUS = '22222222-2222-2222-2222-222222222222';
const cfg = { locationId: 'loc_test' };

// Two pools on purpose, mirroring production. The worker connects as
// sdi_integration, which can write the gate but cannot SET ROLE into a web
// persona. Reading back what an investor sees therefore has to go through the
// web tier's own role -- sdi_app. That separation is the point, so the test
// respects it rather than granting itself a shortcut.
let pool, webPool, adminPool;
async function db() {
  if (pool) return pool;
  pool = new Pool({
    host: process.env.PGHOST || '127.0.0.1',
    database: process.env.PGDATABASE || 'sdi',
    user: process.env.PGUSER || 'sdi_integration',
    password: process.env.PGPASSWORD || 'demo_int_pw',
    max: 2,
  });
  await pool.query('SELECT 1');
  return pool;
}
// Fixture role. Setting up and inspecting core.person is not something any
// application role can do -- see test/bootstrap.sql for why that is correct.
async function admin() {
  if (adminPool) return adminPool;
  adminPool = new Pool({
    host: process.env.PGHOST || '127.0.0.1',
    database: process.env.PGDATABASE || 'sdi',
    user: 'sdi_test_admin',
    password: 'demo_test_pw',
    max: 2,
  });
  await adminPool.query('SELECT 1');
  return adminPool;
}
async function web() {
  if (webPool) return webPool;
  webPool = new Pool({
    host: process.env.PGHOST || '127.0.0.1',
    database: process.env.PGDATABASE || 'sdi',
    user: 'sdi_app',
    password: 'demo_app_pw',
    max: 2,
  });
  await webPool.query('SELECT 1');
  return webPool;
}

let available = true;
test('database reachable', async (t) => {
  try { await db(); } catch (e) { available = false; t.skip(`no database: ${e.message}`); }
});

function fakeClient(documents) {
  return {
    async listDocuments({ status, skip = 0 }) {
      if (skip > 0) return { documents: [], total: 0 };
      const d = documents.filter((x) => x.status === status);
      return { documents: d, total: d.length };
    },
  };
}

function doc(overrides = {}) {
  return {
    documentId: 'doc_int_1',
    locationId: 'loc_test',
    name: 'Platform Fee Agreement',
    status: 'completed',
    paymentStatus: 'waiting_for_payment',
    grandTotal: 750.00,
    recipients: [{ contactId: 'ghl_c_marcus' }],
    updatedAt: new Date().toISOString(),
    ...overrides,
  };
}

async function addressVisibleToMarcus() {
  const w = await web();
  const c = await w.connect();
  try {
    await c.query('BEGIN');
    await c.query("SET LOCAL ROLE sdi_investor");
    await c.query("SELECT set_config('app.actor_id', $1, true)", [MARCUS]);
    const { rows } = await c.query(
      'SELECT street_address, address_unlocked FROM api.property ORDER BY listing_ref LIMIT 1');
    await c.query('COMMIT');
    return rows[0];
  } finally { c.release(); }
}

test('setup: link the GHL contact to the person, reset the gate', async (t) => {
  if (!available) return t.skip('no database');
  const a = await admin();
  await a.query('DELETE FROM ghl.fee_agreement');
  await a.query("UPDATE core.person SET fee_agreement_signed_at = NULL WHERE person_id = $1", [MARCUS]);
  await a.query(
    `INSERT INTO ghl.id_map (entity_type, local_id, ghl_id, ghl_object, location_id)
     VALUES ('person', $1, 'ghl_c_marcus', 'contact', 'loc_test')
     ON CONFLICT DO NOTHING`, [MARCUS]);
  const before = await addressVisibleToMarcus();
  assert.equal(before.address_unlocked, false, 'baseline: gate shut');
  assert.equal(before.street_address, null);
});

test('signed but UNPAID does not open the gate', async (t) => {
  if (!available) return t.skip('no database');
  const d = await db();
  const out = await syncDocuments(fakeClient([doc()]), d, cfg);
  assert.equal(out.seen, 1);
  assert.equal(out.opened, 0, 'a completed-but-unpaid document must not unlock');
  const after = await addressVisibleToMarcus();
  assert.equal(after.address_unlocked, false);
  assert.equal(after.street_address, null);
});

test('payment settles and the address becomes visible', async (t) => {
  if (!available) return t.skip('no database');
  const d = await db();
  const paid = doc({ paymentStatus: 'paid', updatedAt: new Date().toISOString() });
  const out = await syncDocuments(fakeClient([paid]), d, cfg);
  assert.equal(out.opened, 1);
  const after = await addressVisibleToMarcus();
  assert.equal(after.address_unlocked, true);
  assert.ok(after.street_address && after.street_address.length > 0,
            'the whole point: band 2 released by a settled fee agreement');
});

test('re-running the sync is inert', async (t) => {
  if (!available) return t.skip('no database');
  const d = await db();
  const a = await admin();
  const { rows: b } = await a.query(
    'SELECT fee_agreement_signed_at AS ts FROM core.person WHERE person_id = $1', [MARCUS]);
  const paid = doc({ paymentStatus: 'paid', updatedAt: new Date().toISOString() });
  await syncDocuments(fakeClient([paid]), d, cfg);
  const { rows: after } = await a.query(
    'SELECT fee_agreement_signed_at AS ts FROM core.person WHERE person_id = $1', [MARCUS]);
  assert.deepEqual(after[0].ts, b[0].ts, 'replay must not move the signature timestamp');
});

test('transaction sync mirrors rows and advances the cursor', async (t) => {
  if (!available) return t.skip('no database');
  const d = await db();
  const a2 = await admin();
  await a2.query('DELETE FROM ghl.transaction');
  await a2.query("DELETE FROM ghl.sync_state WHERE resource = 'transactions'");
  const client = {
    calls: 0,
    async listTransactions() {
      this.calls += 1;
      if (this.calls > 1) return { data: [] };
      return { data: [{
        _id: 'txn_1', altId: 'loc_test', contactId: 'ghl_c_marcus',
        invoiceId: 'inv_1', amount: 750.00, currency: 'USD', amountRefunded: 0,
        status: 'succeeded', liveMode: true, paymentProvider: 'stripe',
        entityType: 'invoice', entityId: 'inv_1',
        createdAt: '2026-08-30T10:00:00Z', updatedAt: '2026-08-30T10:00:00Z',
      }] };
    },
  };
  const out = await syncTransactions(client, d, cfg);
  assert.equal(out.seen, 1);
  const { rows } = await d.query('SELECT amount, live_mode, status FROM ghl.transaction');
  assert.equal(rows.length, 1);
  assert.equal(Number(rows[0].amount), 750);
  assert.equal(rows[0].live_mode, true);
  const { rows: cur } = await d.query(
    "SELECT cursor_at FROM ghl.sync_state WHERE resource = 'transactions'");
  assert.ok(cur[0].cursor_at, 'cursor advanced for the next sweep');
});

// This suite's whole purpose is to prove the gate OPENS, which means it
// ends with Marcus's gate open unless it puts it back. It did not, and
// that quietly destroyed the demo's central contrast -- Marcus and Ruth
// side by side, identical but for one timestamp -- every time the tests
// ran. Restoring is not optional for a suite that mutates shared fixture
// data.
test('teardown: the demo fixture is exactly as seeded', async (t) => {
  if (!available) return t.skip('no database');
  const a = await admin();
  await a.query('DELETE FROM ghl.fee_agreement');
  await a.query("DELETE FROM ghl.id_map WHERE ghl_id = 'ghl_c_marcus'");
  await a.query(
    'UPDATE core.person SET fee_agreement_signed_at = NULL WHERE person_id = $1', [MARCUS]);

  // Asserted, not assumed. A restore that silently fails is the same bug
  // one layer down, and this is the fourth time this class of pollution
  // has cost time on this project.
  const { rows } = await a.query(
    `SELECT email, fee_agreement_signed_at IS NOT NULL AS gated
       FROM core.person WHERE email IN ('marcus@example.com','ruth@example.com')
      ORDER BY email`);
  const state = Object.fromEntries(rows.map((r) => [r.email, r.gated]));
  assert.equal(state['marcus@example.com'], false,
    'Marcus must end with his gate SHUT -- the demo compares him against Ruth');
  assert.equal(state['ruth@example.com'], true,
    'Ruth must end with her gate OPEN');
});

test.after(async () => {
  if (pool) await pool.end();
  if (webPool) await webPool.end();
  if (adminPool) await adminPool.end();
});
