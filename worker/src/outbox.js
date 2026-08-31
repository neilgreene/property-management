// Outbox drain.
//
// GHL has no transactional import and no Idempotency-Key header, so "did my
// write land?" is genuinely ambiguous after a timeout. Three things together
// make retry safe:
//
//   1. Prefer upsert endpoints (/contacts/upsert, /opportunities/upsert).
//      Replaying one is inert by construction.
//   2. For endpoints with no upsert (/objects/{key}/records), consult
//      ghl.id_map BEFORE creating. If this local_id already has a GHL id, the
//      previous attempt did land and we adopt it instead of creating a twin.
//   3. Claim rows FOR UPDATE SKIP LOCKED so two drainers cannot race the same
//      row.
//
// Without (2) an ambiguous failure on a create silently duplicates the record,
// which is exactly the failure mode that makes a half-finished migration
// unrecoverable.
'use strict';

const { GhlError } = require('./ghlClient');

const TERMINAL_STATUS = new Set([400, 401, 403, 404, 409, 422]);

function backoffSeconds(attempts) {
  return Math.min(2 ** attempts * 5, 3600); // 10s, 20s, 40s ... capped at 1h
}

async function claimBatch(db, limit) {
  const { rows } = await db.query(
    `SELECT id, idempotency_key, operation, entity_type, local_id, payload, attempts
       FROM ghl.outbox
      WHERE state = 'pending'
        AND next_attempt_at <= now()
      ORDER BY id
      LIMIT $1
      FOR UPDATE SKIP LOCKED`,
    [limit]
  );
  return rows;
}

async function alreadyMapped(db, entityType, localId, locationId) {
  if (!entityType || !localId) return null;
  const { rows } = await db.query(
    `SELECT ghl_id FROM ghl.id_map
      WHERE entity_type = $1 AND local_id = $2 AND location_id = $3`,
    [entityType, localId, locationId]
  );
  return rows[0]?.ghl_id || null;
}

async function recordMapping(db, entityType, localId, ghlId, ghlObject, locationId) {
  if (!entityType || !localId || !ghlId) return;
  await db.query(
    `INSERT INTO ghl.id_map (entity_type, local_id, ghl_id, ghl_object, location_id)
     VALUES ($1,$2,$3,$4,$5)
     ON CONFLICT (entity_type, local_id, location_id) DO UPDATE
       SET ghl_id = EXCLUDED.ghl_id, synced_at = now()`,
    [entityType, localId, ghlId, ghlObject, locationId]
  );
}

// operation -> { call, objectKind }. Each call returns the GHL id it created
// or updated, so the drainer can record the mapping in the same transaction.
const HANDLERS = {
  'contact.upsert': {
    objectKind: 'contact',
    async call(client, payload) {
      const r = await client.upsertContact(payload);
      return r?.contact?.id || r?.id || null;
    },
  },
  'relation.create': {
    objectKind: 'record',
    async call(client, payload) {
      const r = await client.createRelation(payload);
      return r?.relation?.id || r?.id || null;
    },
  },
  'record.create': {
    objectKind: 'record',
    async call(client, payload) {
      const { schemaKey, ...rest } = payload;
      const r = await client.createRecord(schemaKey, rest);
      return r?.record?.id || r?.id || null;
    },
  },
};

async function drainOnce(client, db, cfg, { limit = 50, handlers = HANDLERS } = {}) {
  const conn = await db.connect();
  const result = { sent: 0, retried: 0, failed: 0, adopted: 0 };
  try {
    await conn.query('BEGIN');
    const batch = await claimBatch(conn, limit);

    for (const row of batch) {
      const handler = handlers[row.operation];
      if (!handler) {
        await conn.query(
          `UPDATE ghl.outbox SET state='failed', last_error=$2 WHERE id=$1`,
          [row.id, `no handler for operation '${row.operation}'`]);
        result.failed += 1;
        continue;
      }

      // (2) above: a create whose previous attempt may have landed.
      const existing = await alreadyMapped(conn, row.entity_type, row.local_id, cfg.locationId);
      if (existing && row.operation.endsWith('.create')) {
        await conn.query(
          `UPDATE ghl.outbox SET state='sent', ghl_id=$2, sent_at=now() WHERE id=$1`,
          [row.id, existing]);
        result.adopted += 1;
        continue;
      }

      try {
        const ghlId = await handler.call(client, row.payload);
        await recordMapping(conn, row.entity_type, row.local_id, ghlId,
                            handler.objectKind, cfg.locationId);
        await conn.query(
          `UPDATE ghl.outbox SET state='sent', ghl_id=$2, sent_at=now(),
                  attempts = attempts + 1, last_error = NULL
            WHERE id=$1`,
          [row.id, ghlId]);
        result.sent += 1;
      } catch (err) {
        const status = err instanceof GhlError ? err.status : 0;
        const attempts = row.attempts + 1;
        const terminal = TERMINAL_STATUS.has(status);
        const exhausted = attempts >= cfg.maxRetries;

        if (terminal || exhausted) {
          await conn.query(
            `UPDATE ghl.outbox
                SET state = $3, attempts = $2, last_error = $4
              WHERE id = $1`,
            [row.id, attempts, terminal ? 'failed' : 'abandoned',
             `${status || 'network'}: ${String(err.message).slice(0, 500)}`]);
          result.failed += 1;
        } else {
          await conn.query(
            `UPDATE ghl.outbox
                SET attempts = $2,
                    next_attempt_at = now() + make_interval(secs => $3),
                    last_error = $4
              WHERE id = $1`,
            [row.id, attempts, backoffSeconds(attempts),
             `${status || 'network'}: ${String(err.message).slice(0, 500)}`]);
          result.retried += 1;
        }
      }
    }

    await conn.query('COMMIT');
    return result;
  } catch (e) {
    await conn.query('ROLLBACK').catch(() => {});
    throw e;
  } finally {
    conn.release();
  }
}

// Stages an outbound write. Call inside the same transaction as the local
// change so a crash between the two cannot lose the intent.
async function enqueue(db, { idempotencyKey, operation, entityType, localId, payload }) {
  const { rows } = await db.query(
    `INSERT INTO ghl.outbox (idempotency_key, operation, entity_type, local_id, payload)
     VALUES ($1,$2,$3,$4,$5)
     ON CONFLICT (idempotency_key) DO NOTHING
     RETURNING id`,
    [idempotencyKey, operation, entityType, localId, payload]
  );
  return rows[0]?.id || null;   // null means it was already queued
}

module.exports = { drainOnce, enqueue, backoffSeconds, HANDLERS, TERMINAL_STATUS };
