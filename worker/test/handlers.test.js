'use strict';
// Event dispatch. The interesting assertion is the one about direction:
// an edit made in the CRM to something we own must reach a human, not the row.
const test = require('node:test');
const assert = require('node:assert');
const { Pool } = require('pg');
const { processPending } = require('../src/handlers');

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

async function deliver(d, { id, type, payload = {}, ok = true }) {
  await d.query(
    `INSERT INTO ghl.webhook_event (webhook_id, event_type, occurred_at, signature_ok, payload)
     VALUES ($1,$2,now(),$3,$4) ON CONFLICT DO NOTHING`,
    [id, type, ok, payload]);
}

async function reset(d) {
  await d.query('DELETE FROM ghl.webhook_event');
  await d.query('DELETE FROM ghl.review_queue');
}

test('database reachable', async (t) => {
  try { await db(); } catch (e) { available = false; t.skip(`no database: ${e.message}`); }
});

test('an edit made in the CRM to a property is queued, not applied', async (t) => {
  if (!available) return t.skip('no database');
  const d = await db(); await reset(d);
  await deliver(d, { id: 'e1', type: 'RecordUpdate',
                     payload: { id: 'ghl_rec_1', properties: { city: 'Toledo' } } });
  const out = await processPending(d);
  assert.equal(out.processed, 1);
  assert.equal(out.outcomes[0].outcome, 'queued for review');
  const { rows } = await d.query(
    "SELECT summary, state, ghl_id FROM ghl.review_queue WHERE ghl_id='ghl_rec_1'");
  assert.equal(rows.length, 1);
  assert.equal(rows[0].state, 'open');
  assert.match(rows[0].summary, /edited in the CRM/);
});

test('repeat edits to one object collapse to a single open decision', async (t) => {
  if (!available) return t.skip('no database');
  const d = await db();
  await deliver(d, { id: 'e2', type: 'RecordUpdate',
                     payload: { id: 'ghl_rec_1', properties: { city: 'Akron' } } });
  await processPending(d);
  const { rows } = await d.query(
    "SELECT count(*)::int n FROM ghl.review_queue WHERE ghl_id='ghl_rec_1' AND state='open'");
  assert.equal(rows[0].n, 1, 'five CRM edits are one decision for a human, not five');
});

test('an unsigned event is never processed', async (t) => {
  if (!available) return t.skip('no database');
  const d = await db(); await reset(d);
  await deliver(d, { id: 'e3', type: 'RecordUpdate', payload: { id: 'x' }, ok: false });
  const out = await processPending(d);
  assert.equal(out.processed, 0, 'signature_ok = false must not be picked up');
  const { rows } = await d.query(
    "SELECT processed_at FROM ghl.webhook_event WHERE webhook_id='e3'");
  assert.equal(rows[0].processed_at, null);
});

test('an event with no handler is marked processed, not left to pile up', async (t) => {
  if (!available) return t.skip('no database');
  const d = await db(); await reset(d);
  await deliver(d, { id: 'e4', type: 'LCEmailStats', payload: {} });
  const out = await processPending(d);
  assert.equal(out.processed, 1);
  assert.match(out.outcomes[0].outcome, /recorded only/);
});

test('processing is idempotent — a second pass finds nothing', async (t) => {
  if (!available) return t.skip('no database');
  const d = await db();
  const second = await processPending(d);
  assert.equal(second.processed, 0);
});

test('an invoice not linked to a fee agreement changes no gate', async (t) => {
  if (!available) return t.skip('no database');
  const d = await db(); await reset(d);
  await deliver(d, { id: 'e5', type: 'InvoicePaid', payload: { _id: 'inv_unknown' } });
  const out = await processPending(d);
  assert.match(out.outcomes[0].outcome, /not linked/);
});

test.after(async () => { if (pool) await pool.end(); });
