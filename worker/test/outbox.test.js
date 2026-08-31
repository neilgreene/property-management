'use strict';
// Outbox drain, against a real database. The interesting cases are all
// failure cases: what happens when a write may or may not have landed.
const test = require('node:test');
const assert = require('node:assert');
const { Pool } = require('pg');
const { drainOnce, enqueue, backoffSeconds } = require('../src/outbox');
const { GhlError } = require('../src/ghlClient');

const cfg = { locationId: 'loc_test', maxRetries: 3 };
const PROP = '33333333-3333-3333-3333-333333333333';

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
  await d.query("DELETE FROM ghl.id_map WHERE location_id = 'loc_test'");
}

function clientThat(behaviour) {
  return {
    calls: 0,
    async upsertContact(p) { this.calls += 1; return behaviour(p, this.calls); },
    async createRecord(k, p) { this.calls += 1; return behaviour(p, this.calls); },
  };
}

test('database reachable', async (t) => {
  try { await db(); } catch (e) { available = false; t.skip(`no database: ${e.message}`); }
});

test('enqueue is idempotent on the key', async (t) => {
  if (!available) return t.skip('no database');
  const d = await db(); await reset(d);
  const a = await enqueue(d, { idempotencyKey: 'k1', operation: 'contact.upsert',
                               entityType: 'person', localId: PROP, payload: { email: 'a@b.c' } });
  const b = await enqueue(d, { idempotencyKey: 'k1', operation: 'contact.upsert',
                               entityType: 'person', localId: PROP, payload: { email: 'a@b.c' } });
  assert.ok(a, 'first enqueue returns an id');
  assert.equal(b, null, 'second is a no-op, not a duplicate row');
  const { rows } = await d.query('SELECT count(*)::int n FROM ghl.outbox');
  assert.equal(rows[0].n, 1);
});

test('a successful send records the id mapping', async (t) => {
  if (!available) return t.skip('no database');
  const d = await db(); await reset(d);
  await enqueue(d, { idempotencyKey: 'k2', operation: 'contact.upsert',
                     entityType: 'person', localId: PROP, payload: { email: 'a@b.c' } });
  const client = clientThat(() => ({ contact: { id: 'ghl_contact_9' } }));
  const out = await drainOnce(client, d, cfg);
  assert.equal(out.sent, 1);
  const { rows } = await d.query(
    `SELECT ghl_id FROM ghl.id_map WHERE entity_type='person' AND local_id=$1`, [PROP]);
  assert.equal(rows[0].ghl_id, 'ghl_contact_9');
});

test('a retryable failure schedules a retry rather than failing', async (t) => {
  if (!available) return t.skip('no database');
  const d = await db(); await reset(d);
  await enqueue(d, { idempotencyKey: 'k3', operation: 'contact.upsert',
                     entityType: 'person', localId: PROP, payload: {} });
  const client = clientThat(() => {
    throw new GhlError('boom', { status: 503, body: '', retryable: true });
  });
  const out = await drainOnce(client, d, cfg);
  assert.equal(out.retried, 1);
  const { rows } = await d.query('SELECT state, attempts, next_attempt_at > now() AS deferred FROM ghl.outbox');
  assert.equal(rows[0].state, 'pending');
  assert.equal(rows[0].attempts, 1);
  assert.equal(rows[0].deferred, true, 'backoff pushes the next attempt out');
});

test('a 403 fails immediately — a missing scope will never succeed', async (t) => {
  if (!available) return t.skip('no database');
  const d = await db(); await reset(d);
  await enqueue(d, { idempotencyKey: 'k4', operation: 'contact.upsert',
                     entityType: 'person', localId: PROP, payload: {} });
  const client = clientThat(() => {
    throw new GhlError('forbidden', { status: 403, body: '', retryable: false });
  });
  const out = await drainOnce(client, d, cfg);
  assert.equal(out.failed, 1);
  const { rows } = await d.query('SELECT state FROM ghl.outbox');
  assert.equal(rows[0].state, 'failed');
});

test('exhausting retries abandons rather than looping forever', async (t) => {
  if (!available) return t.skip('no database');
  const d = await db(); await reset(d);
  await enqueue(d, { idempotencyKey: 'k5', operation: 'contact.upsert',
                     entityType: 'person', localId: PROP, payload: {} });
  await d.query('UPDATE ghl.outbox SET attempts = $1', [cfg.maxRetries - 1]);
  const client = clientThat(() => {
    throw new GhlError('still down', { status: 503, body: '', retryable: true });
  });
  await drainOnce(client, d, cfg);
  const { rows } = await d.query('SELECT state FROM ghl.outbox');
  assert.equal(rows[0].state, 'abandoned');
});

test('an ambiguous create adopts the existing record instead of duplicating', async (t) => {
  if (!available) return t.skip('no database');
  const d = await db(); await reset(d);
  // Simulates: a previous attempt reached GHL and created the record, but the
  // response never came back, so the row is still pending. Without the id_map
  // check the retry creates a second property in GHL.
  await d.query(
    `INSERT INTO ghl.id_map (entity_type, local_id, ghl_id, ghl_object, location_id)
     VALUES ('property', $1, 'ghl_record_existing', 'record', 'loc_test')`, [PROP]);
  await enqueue(d, { idempotencyKey: 'k6', operation: 'record.create',
                     entityType: 'property', localId: PROP,
                     payload: { schemaKey: 'property', name: 'x' } });
  const client = clientThat(() => { throw new Error('must not be called'); });
  const out = await drainOnce(client, d, cfg);
  assert.equal(out.adopted, 1);
  assert.equal(client.calls, 0, 'no second create was attempted');
  const { rows } = await d.query('SELECT state, ghl_id FROM ghl.outbox');
  assert.equal(rows[0].state, 'sent');
  assert.equal(rows[0].ghl_id, 'ghl_record_existing');
});

test('an unknown operation fails loudly rather than silently draining', async (t) => {
  if (!available) return t.skip('no database');
  const d = await db(); await reset(d);
  await enqueue(d, { idempotencyKey: 'k7', operation: 'nonsense.op',
                     entityType: 'person', localId: PROP, payload: {} });
  const out = await drainOnce(clientThat(() => ({})), d, cfg);
  assert.equal(out.failed, 1);
  const { rows } = await d.query('SELECT state, last_error FROM ghl.outbox');
  assert.equal(rows[0].state, 'failed');
  assert.match(rows[0].last_error, /no handler/);
});

test('backoff grows and is capped', () => {
  assert.ok(backoffSeconds(1) < backoffSeconds(3));
  assert.equal(backoffSeconds(50), 3600, 'capped at an hour');
});

test.after(async () => { if (pool) await pool.end(); });
