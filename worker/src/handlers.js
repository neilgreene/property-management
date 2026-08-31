// Inbound event dispatch.
//
// Direction matters here and decides most of these handlers. core.property and
// core.person are the system of record; GoHighLevel is downstream of them for
// listings. So an inbound RecordUpdate means somebody edited a property inside
// the CRM, against the grain of the architecture.
//
// Applying that would let the CRM silently overwrite the authoritative row --
// the failure mode that makes two-way sync notorious. Dropping it loses a real
// edit somebody made. Neither is acceptable, so those events are queued for a
// person. Events that genuinely ORIGINATE in GHL -- a signed document, a
// settled payment, a contact created by staff -- are applied directly, because
// for those GHL is the source.
'use strict';

const { markProcessed, markEventFailed, claimPendingEvents } = require('./db');

async function queueForReview(db, evt, { summary, ghlObject, ghlId, localId = null }) {
  await db.query(
    `INSERT INTO ghl.review_queue
        (source, event_type, ghl_object, ghl_id, local_id, summary, proposed)
     VALUES ('webhook', $1, $2, $3, $4, $5, $6)
     ON CONFLICT (ghl_object, ghl_id) WHERE state = 'open' DO UPDATE
        SET proposed = EXCLUDED.proposed, raised_at = now(), summary = EXCLUDED.summary`,
    [evt.event_type, ghlObject, ghlId, localId, summary, evt.payload]
  );
}

// GHL is the source for identity created by staff inside the CRM, so keep the
// map current. Note this only records the mapping -- it does not create a
// core.person, because a contact in the CRM is not automatically a party here.
async function onContact(db, evt) {
  const p = evt.payload || {};
  const ghlId = p.id || p.contactId;
  if (!ghlId) return 'ignored: no contact id';
  const { rowCount } = await db.query(
    `UPDATE ghl.id_map SET synced_at = now()
      WHERE ghl_id = $1 AND ghl_object = 'contact'`, [ghlId]);
  return rowCount ? 'id_map touched' : 'unmapped contact, no local party';
}

// A settled invoice may be the platform fee. The two-condition rule still lives
// in the database, so this only nudges it -- it never decides.
async function onInvoicePaid(db, evt) {
  const p = evt.payload || {};
  const invoiceId = p._id || p.invoiceId || p.id;
  if (!invoiceId) return 'ignored: no invoice id';
  const { rows } = await db.query(
    `SELECT document_id FROM ghl.fee_agreement
      WHERE raw->>'invoiceId' = $1 OR document_id = $1`, [invoiceId]);
  if (rows.length === 0) return 'invoice not linked to a fee agreement';
  const opened = [];
  for (const r of rows) {
    const { rows: out } = await db.query(
      `SELECT ghl.apply_fee_agreement($1) AS opened`, [r.document_id]);
    if (out[0].opened) opened.push(r.document_id);
  }
  return opened.length ? `gate opened for ${opened.join(', ')}` : 'no gate change';
}

const HANDLERS = {
  ContactCreate: onContact,
  ContactUpdate: onContact,
  ContactDelete: onContact,
  InvoicePaid: onInvoicePaid,
  InvoicePartiallyPaid: async () => 'partial payment noted; gate unchanged',
};

// Everything that edits an entity we own goes to a human.
const REVIEW = {
  RecordCreate:  'A property record was created in the CRM',
  RecordUpdate:  'A property record was edited in the CRM',
  RecordDelete:  'A property record was deleted in the CRM',
  OpportunityStageUpdate:  'A deal changed stage in the CRM',
  OpportunityStatusUpdate: 'A deal changed status in the CRM',
};

async function handleOne(db, evt) {
  const fn = HANDLERS[evt.event_type];
  if (fn) return fn(db, evt);

  const summary = REVIEW[evt.event_type];
  if (summary) {
    const p = evt.payload || {};
    await queueForReview(db, evt, {
      summary,
      ghlObject: evt.event_type.startsWith('Record') ? 'record' : 'opportunity',
      ghlId: p.id || p.recordId || p._id || null,
    });
    return 'queued for review';
  }
  // Recorded, no action. The row stays in ghl.webhook_event either way, so
  // nothing is lost by not having a handler yet.
  return 'no handler; recorded only';
}

async function processPending(db, { limit = 50 } = {}) {
  const conn = await db.connect();
  const result = { processed: 0, failed: 0, outcomes: [] };
  try {
    await conn.query('BEGIN');
    const batch = await claimPendingEvents(conn, limit);
    for (const evt of batch) {
      try {
        const outcome = await handleOne(conn, evt);
        await markProcessed(conn, evt.webhook_id);
        result.processed += 1;
        result.outcomes.push({ webhookId: evt.webhook_id, type: evt.event_type, outcome });
      } catch (err) {
        await markEventFailed(conn, evt.webhook_id, err.message);
        result.failed += 1;
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

module.exports = { processPending, handleOne, HANDLERS, REVIEW };
