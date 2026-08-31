#!/usr/bin/env node
// GoHighLevel integration worker.
//
//   POST /webhooks/ghl   receive a delivery
//   GET  /healthz        liveness plus queue depth
//
// plus three loops: process received events, drain the outbox, and reconcile
// on a slower cadence.
//
// The one thing this file must not get wrong is the raw body. GHL signs the
// exact bytes it sent, so the request is buffered and the Buffer is handed to
// the verifier untouched. Any JSON body-parsing middleware placed in front of
// this endpoint would parse-then-discard those bytes and every signature would
// fail -- which is why there is no framework here.
'use strict';

const http = require('http');
const { load, assertLive } = require('./config');
const { makePool } = require('./db');
const { GhlClient } = require('./ghlClient');
const { receive } = require('./webhookReceiver');
const { processPending } = require('./handlers');
const { drainOnce } = require('./outbox');
const { syncDocuments } = require('./sync/documents');
const { syncTransactions } = require('./sync/transactions');

const MAX_BODY_BYTES = 1_000_000;

function readRawBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    let over = false;
    req.on('data', (c) => {
      if (over) return;                 // draining; discard without buffering
      size += c.length;
      if (size > MAX_BODY_BYTES) {
        over = true;
        chunks.length = 0;              // release what we already held
        return;
      }
      chunks.push(c);
    });
    // Drain to the end rather than destroying the socket. Destroying it kills
    // the connection before the 413 can be written, so the caller sees a
    // network error instead of a status it can act on.
    req.on('end', () => {
      if (over) {
        reject(Object.assign(new Error('body too large'), { statusCode: 413 }));
      } else {
        resolve(Buffer.concat(chunks));
      }
    });
    req.on('error', reject);
  });
}

function json(res, status, body) {
  const payload = JSON.stringify(body);
  res.writeHead(status, { 'Content-Type': 'application/json',
                          'Content-Length': Buffer.byteLength(payload) });
  res.end(payload);
}

function createServer(db, cfg, log = console) {
  return http.createServer(async (req, res) => {
    try {
      if (req.method === 'POST' && req.url === '/webhooks/ghl') {
        const raw = await readRawBody(req);
        const out = await receive(raw, req.headers, { db, cfg });
        if (out.status >= 400) {
          log.warn?.(`webhook rejected: ${out.status} ${out.reason || ''}`);
        }
        // Acknowledge fast; the loops do the work. A slow handler here causes
        // GHL to redeliver, which is wasted effort on both sides.
        return json(res, out.status, { ok: out.status < 400, ...out });
      }

      if (req.method === 'GET' && req.url === '/healthz') {
        const { rows } = await db.query(`
          SELECT
            (SELECT count(*)::int FROM ghl.webhook_event WHERE processed_at IS NULL) AS events_pending,
            (SELECT count(*)::int FROM ghl.webhook_event WHERE NOT signature_ok)     AS bad_signatures,
            (SELECT count(*)::int FROM ghl.outbox WHERE state = 'pending')           AS outbox_pending,
            (SELECT count(*)::int FROM ghl.outbox WHERE state IN ('failed','abandoned')) AS outbox_stuck,
            (SELECT count(*)::int FROM ghl.review_queue WHERE state = 'open')        AS review_open`);
        return json(res, 200, { ok: true, ...rows[0] });
      }

      json(res, 404, { ok: false, error: 'not found' });
    } catch (err) {
      const status = err.statusCode || 500;
      log.error?.(`request failed: ${err.message}`);
      json(res, status, { ok: false, error: err.message });
    }
  });
}

// Runs fn on an interval, never overlapping, and never dying on one bad run.
function loop(name, intervalMs, fn, log = console) {
  let stopped = false;
  let timer = null;
  const tick = async () => {
    if (stopped) return;
    try {
      const out = await fn();
      if (out && Object.values(out).some((v) => typeof v === 'number' && v > 0)) {
        log.info?.(`${name}: ${JSON.stringify(out)}`);
      }
    } catch (err) {
      log.error?.(`${name} failed: ${err.message}`);
    }
    if (!stopped) timer = setTimeout(tick, intervalMs);
  };
  timer = setTimeout(tick, intervalMs);
  return () => { stopped = true; if (timer) clearTimeout(timer); };
}

async function main() {
  const cfg = load();
  const log = console;
  assertLive(cfg);

  const db = makePool();
  await db.query('SELECT 1');
  const client = new GhlClient(cfg);

  const stops = [
    loop('events', 5_000,   () => processPending(db), log),
    loop('outbox', 10_000,  () => drainOnce(client, db, cfg), log),
    loop('documents', 300_000, () => syncDocuments(client, db, cfg), log),
    // Overlaps its window by a day on purpose; the upsert is idempotent, so
    // re-seeing a row is cheap and missing one is not.
    loop('transactions', 900_000, () => syncTransactions(client, db, cfg), log),
  ];

  const port = Number(process.env.PORT || 3001);
  const server = createServer(db, cfg, log);
  server.listen(port, () => log.info?.(`ghl worker on http://localhost:${port}`));

  const shutdown = async (sig) => {
    log.info?.(`${sig}: draining`);
    stops.forEach((s) => s());
    server.close();
    await db.end().catch(() => {});
    process.exit(0);
  };
  process.on('SIGINT',  () => shutdown('SIGINT'));
  process.on('SIGTERM', () => shutdown('SIGTERM'));
}

if (require.main === module) {
  main().catch((err) => { console.error(err.message); process.exit(1); });
}

module.exports = { createServer, loop, readRawBody, MAX_BODY_BYTES };
