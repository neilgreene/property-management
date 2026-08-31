'use strict';
const test = require('node:test');
const assert = require('node:assert');
const { GhlClient, GhlError, backoffMs } = require('../src/ghlClient');

const cfg = {
  baseUrl: 'https://services.leadconnectorhq.com',
  apiVersion: '2021-07-28',
  token: 'tok_test',
  locationId: 'loc_1',
  ratePerSecond: 1000,   // effectively disable pacing in tests
  maxRetries: 3,
};

function res(status, body = '', headers = {}) {
  return {
    ok: status >= 200 && status < 300,
    status,
    headers: { get: (n) => headers[n.toLowerCase()] ?? null },
    text: async () => body,
  };
}

function recorder(responses) {
  const calls = [];
  let i = 0;
  const fetchImpl = async (url, init) => {
    calls.push({ url, init });
    const r = responses[Math.min(i, responses.length - 1)];
    i += 1;
    return typeof r === 'function' ? r() : r;
  };
  return { calls, fetchImpl };
}

test('sets the required Version header and bearer token on every call', async () => {
  const { calls, fetchImpl } = recorder([res(200, '{"ok":true}')]);
  const c = new GhlClient(cfg, { fetchImpl });
  await c.listTransactions();
  const h = calls[0].init.headers;
  assert.equal(h.Version, '2021-07-28', 'omitting Version is a deterministic failure');
  assert.equal(h.Authorization, 'Bearer tok_test');
});

test('transactions call carries the required altId/altType pair', async () => {
  const { calls, fetchImpl } = recorder([res(200, '{"data":[]}')]);
  const c = new GhlClient(cfg, { fetchImpl });
  await c.listTransactions();
  const u = new URL(calls[0].url);
  assert.equal(u.searchParams.get('altId'), 'loc_1');
  assert.equal(u.searchParams.get('altType'), 'location');
});

test('documents call targets the proposals module with locationId', async () => {
  const { calls, fetchImpl } = recorder([res(200, '{"documents":[]}')]);
  const c = new GhlClient(cfg, { fetchImpl });
  await c.listDocuments({ status: 'completed' });
  const u = new URL(calls[0].url);
  assert.equal(u.pathname, '/proposals/document');
  assert.equal(u.searchParams.get('status'), 'completed');
  assert.equal(u.searchParams.get('locationId'), 'loc_1');
});

test('retries a 429 then succeeds', async () => {
  const { calls, fetchImpl } = recorder([
    res(429, 'slow down', { 'retry-after': '0' }),
    res(200, '{"data":[]}'),
  ]);
  const c = new GhlClient(cfg, { fetchImpl, sleep: async () => {} });
  const out = await c.listTransactions();
  assert.deepEqual(out, { data: [] });
  assert.equal(calls.length, 2);
});

test('does not retry a 403 — a missing scope will never succeed', async () => {
  const { calls, fetchImpl } = recorder([res(403, 'forbidden')]);
  const c = new GhlClient(cfg, { fetchImpl, sleep: async () => {} });
  await assert.rejects(() => c.listTransactions(), (e) => {
    assert.ok(e instanceof GhlError);
    assert.equal(e.status, 403);
    assert.equal(e.retryable, false);
    return true;
  });
  assert.equal(calls.length, 1, 'retrying a scope error just burns rate budget');
});

test('gives up after maxRetries on persistent 500', async () => {
  const { calls, fetchImpl } = recorder([res(500, 'boom')]);
  const c = new GhlClient(cfg, { fetchImpl, sleep: async () => {} });
  await assert.rejects(() => c.listTransactions());
  assert.equal(calls.length, cfg.maxRetries + 1);
});

test('captures rate-limit headers for budget monitoring', async () => {
  const { fetchImpl } = recorder([res(200, '{}', {
    'x-ratelimit-daily-remaining': '199950',
    'x-ratelimit-limit-daily': '200000',
    'x-ratelimit-max': '100',
    'x-ratelimit-interval-milliseconds': '10000',
  })]);
  const c = new GhlClient(cfg, { fetchImpl });
  await c.listTransactions();
  assert.equal(c.rateSnapshot.dailyRemaining, 199950);
  assert.equal(c.rateSnapshot.max, 100);
});

test('backoff is bounded and jittered', () => {
  assert.ok(backoffMs(1) >= 500 && backoffMs(1) < 1000);
  assert.ok(backoffMs(20) <= 30250, 'must not grow without bound');
  assert.equal(backoffMs(1, '2'), 2000, 'honours Retry-After');
});

test('rate limiter paces calls', async () => {
  const { fetchImpl } = recorder([res(200, '{}')]);
  const c = new GhlClient({ ...cfg, ratePerSecond: 50 }, { fetchImpl });
  const t0 = Date.now();
  await Promise.all([c.listTransactions(), c.listTransactions(), c.listTransactions()]);
  assert.ok(Date.now() - t0 >= 35, 'three calls at 50/s should take ~40ms');
});
