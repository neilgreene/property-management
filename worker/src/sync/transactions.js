// Transaction reconciliation.
//
// GHL exposes no endpoint that creates a transaction, so this is strictly a
// mirror. Webhooks are the primary path; this sweep exists because webhook
// delivery is neither exactly-once nor ordered, and a ledger you cannot
// reconcile is a ledger you cannot trust.
'use strict';

const { upsertTransaction, readCursor, writeCursor } = require('../db');

const RESOURCE = 'transactions';

function normalise(t, locationId) {
  return {
    ghlId:          t._id,
    locationId:     t.altId || locationId,
    contactId:      t.contactId || null,
    invoiceId:      t.invoiceId || null,
    subscriptionId: t.subscriptionId || null,
    amount:         t.amount ?? 0,
    currency:       (t.currency || 'USD').toUpperCase().slice(0, 3),
    amountRefunded: t.amountRefunded ?? 0,
    status:         t.status,
    liveMode:       t.liveMode === true,
    paymentProvider: t.paymentProvider || null,
    entityType:     t.entityType || null,
    entityId:       t.entityId || null,
    createdAt:      t.createdAt,
    updatedAt:      t.updatedAt || t.createdAt,
    raw:            t,
  };
}

function isoDate(d) { return new Date(d).toISOString().slice(0, 10); }

async function syncTransactions(client, db, cfg, { since, until = new Date() } = {}) {
  const cursor = since || (await readCursor(db, RESOURCE));
  // Overlap the window by a day: late-arriving rows are cheap to re-see and
  // expensive to miss. The upsert is idempotent, so overlap costs nothing.
  const startAt = cursor
    ? isoDate(new Date(new Date(cursor).getTime() - 86400000))
    : undefined;

  let offset = 0, seen = 0, high = cursor || null;

  for (;;) {
    const page = await client.listTransactions({
      startAt, endAt: isoDate(until), limit: 100, offset,
    });
    const rows = page?.data || page?.transactions || [];
    if (rows.length === 0) break;

    for (const raw of rows) {
      const t = normalise(raw, cfg.locationId);
      if (!t.ghlId) continue;
      await upsertTransaction(db, t);
      seen += 1;
      if (t.updatedAt && (!high || t.updatedAt > high)) high = t.updatedAt;
    }

    offset += rows.length;
    if (rows.length < 100) break;
  }

  await writeCursor(db, RESOURCE, cfg.locationId, high, seen);
  return { seen, cursor: high };
}

module.exports = { syncTransactions, normalise, RESOURCE };
