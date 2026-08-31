// Database access for the integration worker. Connects as sdi_integration,
// which holds USAGE on ghl plus the narrow core grants it needs -- never as
// the web tier's role, and never as a superuser.
'use strict';

const { Pool } = require('pg');

function makePool(env = process.env) {
  return new Pool({
    host:     env.PGHOST     || '127.0.0.1',
    port:     Number(env.PGPORT || 5432),
    database: env.PGDATABASE || 'sdi',
    user:     env.PGUSER     || 'sdi_integration',
    password: env.PGPASSWORD,
    max: Number(env.PG_POOL_MAX || 4),
  });
}

// Records a delivery. Returns { stored, duplicate }.
//
// Insert before acting: a duplicate webhookId is an idempotent no-op, which is
// what makes redelivery safe. Rows that failed signature verification are kept
// for audit and are never marked processed.
async function recordWebhook(db, { webhookId, eventType, occurredAt, signatureOk, payload }) {
  const { rowCount } = await db.query(
    `INSERT INTO ghl.webhook_event
         (webhook_id, event_type, occurred_at, signature_ok, payload)
     VALUES ($1, $2, $3, $4, $5)
     ON CONFLICT (webhook_id) DO NOTHING`,
    [webhookId, eventType, occurredAt, signatureOk, payload]
  );
  return { stored: rowCount === 1, duplicate: rowCount === 0 };
}

async function claimPendingEvents(db, limit = 50) {
  const { rows } = await db.query(
    `SELECT webhook_id, event_type, occurred_at, payload
       FROM ghl.webhook_event
      WHERE processed_at IS NULL
        AND signature_ok
      ORDER BY occurred_at
      LIMIT $1
      FOR UPDATE SKIP LOCKED`,
    [limit]
  );
  return rows;
}

async function markProcessed(db, webhookId) {
  await db.query(
    `UPDATE ghl.webhook_event SET processed_at = now() WHERE webhook_id = $1`,
    [webhookId]
  );
}

async function markEventFailed(db, webhookId, message) {
  await db.query(
    `UPDATE ghl.webhook_event
        SET attempts = attempts + 1, last_error = $2
      WHERE webhook_id = $1`,
    [webhookId, String(message).slice(0, 2000)]
  );
}

// Upserts observed document state, then lets the database decide whether the
// gate opens. The two-condition rule lives in ghl.apply_fee_agreement() so it
// is stated exactly once.
async function upsertFeeAgreement(db, doc) {
  await db.query(
    `INSERT INTO ghl.fee_agreement
         (document_id, location_id, person_id, ghl_contact_id, status,
          payment_status, grand_total, ghl_updated_at, raw)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
     ON CONFLICT (document_id) DO UPDATE SET
         status         = EXCLUDED.status,
         payment_status = EXCLUDED.payment_status,
         grand_total    = EXCLUDED.grand_total,
         person_id      = COALESCE(ghl.fee_agreement.person_id, EXCLUDED.person_id),
         ghl_updated_at = EXCLUDED.ghl_updated_at,
         observed_at    = now(),
         raw            = EXCLUDED.raw
     WHERE EXCLUDED.ghl_updated_at >= ghl.fee_agreement.ghl_updated_at`,
    [doc.documentId, doc.locationId, doc.personId, doc.ghlContactId, doc.status,
     doc.paymentStatus, doc.grandTotal, doc.updatedAt, doc.raw]
  );
  const { rows } = await db.query(`SELECT ghl.apply_fee_agreement($1) AS opened`,
                                  [doc.documentId]);
  return rows[0].opened;
}

async function upsertTransaction(db, t) {
  await db.query(
    `INSERT INTO ghl.transaction
        (ghl_id, location_id, contact_id, invoice_id, subscription_id, amount,
         currency, amount_refunded, status, live_mode, payment_provider,
         entity_type, entity_id, ghl_created_at, ghl_updated_at, raw)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16)
     ON CONFLICT (ghl_id) DO UPDATE SET
         status          = EXCLUDED.status,
         amount          = EXCLUDED.amount,
         amount_refunded = EXCLUDED.amount_refunded,
         ghl_updated_at  = EXCLUDED.ghl_updated_at,
         synced_at       = now(),
         raw             = EXCLUDED.raw
     WHERE EXCLUDED.ghl_updated_at >= ghl.transaction.ghl_updated_at`,
    [t.ghlId, t.locationId, t.contactId, t.invoiceId, t.subscriptionId, t.amount,
     t.currency, t.amountRefunded, t.status, t.liveMode, t.paymentProvider,
     t.entityType, t.entityId, t.createdAt, t.updatedAt, t.raw]
  );
}

async function readCursor(db, resource) {
  const { rows } = await db.query(
    `SELECT cursor_at FROM ghl.sync_state WHERE resource = $1`, [resource]);
  return rows[0]?.cursor_at || null;
}

async function writeCursor(db, resource, locationId, cursorAt, seen) {
  await db.query(
    `INSERT INTO ghl.sync_state
         (resource, location_id, cursor_at, last_run_at, last_ok_at, records_seen)
     VALUES ($1,$2,$3,now(),now(),$4)
     ON CONFLICT (resource) DO UPDATE SET
         cursor_at    = GREATEST(EXCLUDED.cursor_at, ghl.sync_state.cursor_at),
         last_run_at  = now(),
         last_ok_at   = now(),
         last_error   = NULL,
         records_seen = ghl.sync_state.records_seen + EXCLUDED.records_seen`,
    [resource, locationId, cursorAt, seen]
  );
}

module.exports = {
  makePool, recordWebhook, claimPendingEvents, markProcessed, markEventFailed,
  upsertFeeAgreement, upsertTransaction, readCursor, writeCursor,
};
