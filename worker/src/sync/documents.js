// Fee agreement reconciliation.
//
// GHL publishes no document-signed event in its 58-event webhook catalogue, so
// this state is polled. The worker records what GHL reports and then asks the
// database whether the gate opens -- the two-condition rule (completed/accepted
// AND paid) lives in ghl.apply_fee_agreement() so it is stated exactly once and
// cannot drift between the poller and a future webhook path.
'use strict';

const { upsertFeeAgreement, writeCursor } = require('../db');

const RESOURCE = 'documents';
const TERMINAL = ['completed', 'accepted'];

function normalise(doc, locationId) {
  const recipient = Array.isArray(doc.recipients) ? doc.recipients[0] : null;
  return {
    documentId:   doc.documentId || doc._id,
    locationId:   doc.locationId || locationId,
    personId:     null,               // resolved by contact map below
    ghlContactId: recipient?.contactId || null,
    status:       doc.status,
    paymentStatus: doc.paymentStatus,
    grandTotal:   doc.grandTotal ?? null,
    updatedAt:    doc.updatedAt || doc.createdAt,
    raw:          doc,
  };
}

async function resolvePerson(db, ghlContactId) {
  if (!ghlContactId) return null;
  const { rows } = await db.query(
    `SELECT local_id FROM ghl.id_map
      WHERE ghl_id = $1 AND entity_type = 'person' AND ghl_object = 'contact'`,
    [ghlContactId]
  );
  return rows[0]?.local_id || null;
}

async function syncDocuments(client, db, cfg, { statuses = TERMINAL } = {}) {
  let seen = 0, opened = 0, high = null;

  for (const status of statuses) {
    let skip = 0;
    for (;;) {
      const page = await client.listDocuments({ status, limit: 100, skip });
      const docs = page?.documents || [];
      if (docs.length === 0) break;

      for (const raw of docs) {
        const doc = normalise(raw, cfg.locationId);
        if (!doc.documentId) continue;
        doc.personId = await resolvePerson(db, doc.ghlContactId);
        const didOpen = await upsertFeeAgreement(db, doc);
        if (didOpen) opened += 1;
        seen += 1;
        if (doc.updatedAt && (!high || doc.updatedAt > high)) high = doc.updatedAt;
      }

      skip += docs.length;
      if (page.total !== undefined && skip >= page.total) break;
    }
  }

  await writeCursor(db, RESOURCE, cfg.locationId, high, seen);
  return { seen, opened };
}

module.exports = { syncDocuments, normalise, RESOURCE };
