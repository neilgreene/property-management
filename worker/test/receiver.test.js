'use strict';
const test = require('node:test');
const assert = require('node:assert');
const crypto = require('node:crypto');
const { receive } = require('../src/webhookReceiver');

const { privateKey, publicKey } = crypto.generateKeyPairSync('rsa', {
  modulusLength: 2048,
  publicKeyEncoding:  { type: 'spki',  format: 'pem' },
  privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
});
const sign = (b) => crypto.sign('sha256', b, privateKey).toString('base64');

const cfg = { webhookKey: publicKey, replaySeconds: 300 };
const NOW = Date.parse('2026-01-01T12:00:00Z');

// Minimal stand-in for the pg pool: records what would have been written.
function fakeDb() {
  const seen = new Map();
  return {
    writes: [],
    async query(sql, params) {
      if (/INSERT INTO ghl.webhook_event/.test(sql)) {
        const [webhookId, eventType, occurredAt, signatureOk, payload] = params;
        this.writes.push({ webhookId, eventType, occurredAt, signatureOk, payload });
        if (seen.has(webhookId)) return { rowCount: 0 };
        seen.set(webhookId, true);
        return { rowCount: 1 };
      }
      return { rowCount: 0, rows: [] };
    },
  };
}

function delivery(overrides = {}) {
  return Buffer.from(JSON.stringify({
    webhookId: 'wh_1',
    type: 'InvoicePaid',
    timestamp: '2026-01-01T11:59:00Z',
    ...overrides,
  }));
}

test('accepts a valid delivery and records it', async () => {
  const db = fakeDb();
  const body = delivery();
  const res = await receive(body, { 'x-wh-signature': sign(body) }, { db, cfg, now: NOW });
  assert.equal(res.status, 200);
  assert.equal(res.duplicate, false);
  assert.equal(db.writes.length, 1);
  assert.equal(db.writes[0].signatureOk, true);
});

test('a redelivery is a 200 no-op, not a second side effect', async () => {
  const db = fakeDb();
  const body = delivery();
  const headers = { 'x-wh-signature': sign(body) };
  const first  = await receive(body, headers, { db, cfg, now: NOW });
  const second = await receive(body, headers, { db, cfg, now: NOW });
  assert.equal(first.duplicate, false);
  assert.equal(second.status, 200);
  assert.equal(second.duplicate, true, 'GHL must be told to stop retrying');
});

test('rejects a bad signature with 401 and never marks it processable', async () => {
  const db = fakeDb();
  const body = delivery();
  const res = await receive(body, { 'x-wh-signature': 'AAAA' }, { db, cfg, now: NOW });
  assert.equal(res.status, 401);
  assert.equal(db.writes.length, 1, 'forgery attempt is recorded for audit');
  assert.equal(db.writes[0].signatureOk, false);
});

test('rejects a stale delivery even when correctly signed', async () => {
  const db = fakeDb();
  const body = delivery({ timestamp: '2026-01-01T11:00:00Z' });
  const res = await receive(body, { 'x-wh-signature': sign(body) }, { db, cfg, now: NOW });
  assert.equal(res.status, 400);
  assert.match(res.reason, /replay window/);
  assert.equal(db.writes.length, 0);
});

test('rejects a signed payload with no webhookId', async () => {
  const db = fakeDb();
  const body = Buffer.from(JSON.stringify({ type: 'InvoicePaid', timestamp: '2026-01-01T11:59:00Z' }));
  const res = await receive(body, { 'x-wh-signature': sign(body) }, { db, cfg, now: NOW });
  assert.equal(res.status, 400);
  assert.match(res.reason, /webhookId/);
});

test('rejects a non-Buffer body outright', async () => {
  const db = fakeDb();
  const res = await receive('{"a":1}', {}, { db, cfg, now: NOW });
  assert.equal(res.status, 400);
});

test('header lookup is case-insensitive', async () => {
  const db = fakeDb();
  const body = delivery();
  const res = await receive(body, { 'X-WH-Signature': sign(body) }, { db, cfg, now: NOW });
  assert.equal(res.status, 200);
});
