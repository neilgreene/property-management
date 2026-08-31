'use strict';
const test = require('node:test');
const assert = require('node:assert');
const crypto = require('node:crypto');
const { verifySignature, checkFreshness } = require('../src/signature');

// A locally generated keypair stands in for GHL's published one. The algorithm
// under test is the same; only the key differs.
const { privateKey, publicKey } = crypto.generateKeyPairSync('rsa', {
  modulusLength: 2048,
  publicKeyEncoding:  { type: 'spki',  format: 'pem' },
  privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
});

function sign(buf) {
  return crypto.sign('sha256', buf, privateKey).toString('base64');
}

test('accepts a correctly signed body', () => {
  const body = Buffer.from(JSON.stringify({ webhookId: 'a', timestamp: '2026-01-01T00:00:00Z' }));
  assert.equal(verifySignature(body, sign(body), publicKey), true);
});

test('rejects a tampered body', () => {
  const body = Buffer.from('{"webhookId":"a"}');
  const sig = sign(body);
  const tampered = Buffer.from('{"webhookId":"b"}');
  assert.equal(verifySignature(tampered, sig, publicKey), false);
});

test('rejects a signature from a different key', () => {
  const other = crypto.generateKeyPairSync('rsa', {
    modulusLength: 2048,
    privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
    publicKeyEncoding:  { type: 'spki',  format: 'pem' },
  });
  const body = Buffer.from('{"webhookId":"a"}');
  const sig = crypto.sign('sha256', body, other.privateKey).toString('base64');
  assert.equal(verifySignature(body, sig, publicKey), false);
});

test('rejects empty and malformed signatures', () => {
  const body = Buffer.from('{}');
  assert.equal(verifySignature(body, '', publicKey), false);
  assert.equal(verifySignature(body, null, publicKey), false);
  assert.equal(verifySignature(body, 'not-base64!!', publicKey), false);
});

test('re-serialising the body breaks verification (raw bytes matter)', () => {
  // This is the trap the receiver is built to avoid: parse-then-stringify
  // changes whitespace and key order, and the signature no longer matches.
  const original = Buffer.from('{"webhookId":"a",  "timestamp":"2026-01-01T00:00:00Z"}');
  const sig = sign(original);
  const reserialised = Buffer.from(JSON.stringify(JSON.parse(original.toString())));
  assert.equal(verifySignature(original, sig, publicKey), true);
  assert.equal(verifySignature(reserialised, sig, publicKey), false);
});

test('demands a Buffer, not a string', () => {
  assert.throws(() => verifySignature('{"a":1}', 'x', publicKey), TypeError);
});

test('freshness window accepts recent and rejects stale', () => {
  const now = Date.parse('2026-01-01T12:00:00Z');
  assert.equal(checkFreshness({ timestamp: '2026-01-01T11:58:00Z' }, 300, now).ok, true);
  assert.equal(checkFreshness({ timestamp: '2026-01-01T11:50:00Z' }, 300, now).ok, false);
});

test('freshness rejects future timestamps outside the window too', () => {
  const now = Date.parse('2026-01-01T12:00:00Z');
  assert.equal(checkFreshness({ timestamp: '2026-01-01T12:10:00Z' }, 300, now).ok, false);
});

test('freshness rejects missing and unparseable timestamps', () => {
  assert.equal(checkFreshness({}, 300).ok, false);
  assert.equal(checkFreshness({ timestamp: 'yesterday' }, 300).ok, false);
});

module.exports = { privateKey, publicKey, sign };
