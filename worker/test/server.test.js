'use strict';
// The HTTP surface, exercised over a real socket. The point of testing here
// rather than calling receive() directly is the raw body: a signature computed
// over the exact bytes GHL sent must survive transport, and that is only
// really proven end to end.
const test = require('node:test');
const assert = require('node:assert');
const crypto = require('node:crypto');
const { Pool } = require('pg');
const { createServer, MAX_BODY_BYTES } = require('../src/index');

const { privateKey, publicKey } = crypto.generateKeyPairSync('rsa', {
  modulusLength: 2048,
  publicKeyEncoding:  { type: 'spki',  format: 'pem' },
  privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
});
const sign = (b) => crypto.sign('sha256', b, privateKey).toString('base64');
const cfg = { webhookKey: publicKey, replaySeconds: 300 };
const quiet = { warn() {}, error() {}, info() {} };

let pool, server, base, available = true;

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

test('start server', async (t) => {
  try {
    const d = await db();
    await d.query('DELETE FROM ghl.webhook_event');
    server = createServer(d, cfg, quiet);
    await new Promise((r) => server.listen(0, r));
    base = `http://127.0.0.1:${server.address().port}`;
  } catch (e) { available = false; t.skip(`no database: ${e.message}`); }
});

function body(overrides = {}) {
  return Buffer.from(JSON.stringify({
    webhookId: `wh_${Math.random().toString(36).slice(2)}`,
    type: 'LCEmailStats',
    timestamp: new Date().toISOString(),
    ...overrides,
  }));
}

async function post(buf, headers) {
  return fetch(`${base}/webhooks/ghl`, { method: 'POST', body: buf, headers });
}

test('a correctly signed delivery is accepted over the wire', async (t) => {
  if (!available) return t.skip('no database');
  const b = body();
  const res = await post(b, { 'x-wh-signature': sign(b) });
  assert.equal(res.status, 200);
  const j = await res.json();
  assert.equal(j.ok, true);
  assert.equal(j.duplicate, false);
});

test('the raw bytes survive transport — a payload with odd whitespace still verifies', async (t) => {
  if (!available) return t.skip('no database');
  // Deliberately not what JSON.stringify would produce. If anything in the
  // request path re-serialised the body, this signature would fail.
  const b = Buffer.from(
    `{"webhookId":"wh_ws_1",   "type":"LCEmailStats",\n  "timestamp":"${new Date().toISOString()}"}`);
  const res = await post(b, { 'x-wh-signature': sign(b) });
  assert.equal(res.status, 200, 'body must reach the verifier byte-for-byte');
});

test('a forged signature is refused with 401', async (t) => {
  if (!available) return t.skip('no database');
  const res = await post(body(), { 'x-wh-signature': 'AAAA' });
  assert.equal(res.status, 401);
});

test('a redelivery is acknowledged so GHL stops retrying', async (t) => {
  if (!available) return t.skip('no database');
  const b = body({ webhookId: 'wh_repeat' });
  const h = { 'x-wh-signature': sign(b) };
  assert.equal((await post(b, h)).status, 200);
  const second = await post(b, h);
  assert.equal(second.status, 200);
  assert.equal((await second.json()).duplicate, true);
});

test('an oversized body is rejected rather than buffered', async (t) => {
  if (!available) return t.skip('no database');
  const huge = Buffer.alloc(MAX_BODY_BYTES + 1024, 0x61);
  const res = await post(huge, { 'x-wh-signature': 'x' });
  assert.ok(res.status === 413 || res.status >= 400, `got ${res.status}`);
});

test('healthz reports queue depth', async (t) => {
  if (!available) return t.skip('no database');
  const res = await fetch(`${base}/healthz`);
  assert.equal(res.status, 200);
  const j = await res.json();
  for (const k of ['events_pending','bad_signatures','outbox_pending','outbox_stuck','review_open']) {
    assert.equal(typeof j[k], 'number', `healthz must report ${k}`);
  }
});

test('an unknown route is a 404, not a crash', async (t) => {
  if (!available) return t.skip('no database');
  assert.equal((await fetch(`${base}/nope`)).status, 404);
});

test.after(async () => {
  if (server) await new Promise((r) => server.close(r));
  if (pool) await pool.end();
});
