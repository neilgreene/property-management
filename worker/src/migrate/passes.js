// EspoCRM -> GoHighLevel load, in passes.
//
// GHL has no transactional import, so ordering is the whole game. An
// association can only be created once both of its endpoints exist, and the
// GHL ids of those endpoints only exist after the pass that created them. That
// forces this sequence, and it is why ghl.id_map is written as the load runs
// rather than at the end:
//
//   1 schemas      custom object definitions
//   2 associations association types between schemas
//   3 people       contacts        -> id_map
//   4 properties   object records  -> id_map
//   5 links        relations       (reads id_map from 3 and 4)
//   6 deals        opportunities
//   7 reconcile    counts and spot checks against the source
//
// Every pass is restartable. Passes 3, 4 and 6 stage work in ghl.outbox and let
// the drainer do the talking, so a crash mid-pass loses nothing: re-running
// re-enqueues, the idempotency key collapses duplicates, and the drainer's
// id_map check stops an ambiguous create from twinning a record.
'use strict';

const { enqueue } = require('../outbox');

const PASSES = ['schemas', 'associations', 'people', 'properties', 'links', 'deals', 'reconcile'];

function key(op, sourceId) { return `${op}:${sourceId}`; }

// --- pass 3 -----------------------------------------------------------
async function loadPeople(db, source, { locationId }) {
  let queued = 0, skipped = 0;
  for await (const p of source.people()) {
    if (!p.sourceId) { skipped += 1; continue; }
    const localId = p.personId || null;
    const id = await enqueue(db, {
      idempotencyKey: key('contact.upsert', p.sourceId),
      operation: 'contact.upsert',
      entityType: 'person',
      localId,
      payload: {
        email: p.email, phone: p.phone,
        firstName: p.firstName, lastName: p.lastName,
        tags: p.tags || [],
        customFields: p.customFields || [],
        __source: { system: 'espocrm', id: p.sourceId, locationId },
      },
    });
    if (id) queued += 1; else skipped += 1;
  }
  return { queued, skipped };
}

// --- pass 4 -----------------------------------------------------------
async function loadProperties(db, source, { locationId, schemaKey = 'property' }) {
  let queued = 0, skipped = 0;
  for await (const r of source.properties()) {
    if (!r.sourceId) { skipped += 1; continue; }
    const id = await enqueue(db, {
      idempotencyKey: key('record.create', r.sourceId),
      operation: 'record.create',
      entityType: 'property',
      localId: r.propertyId || null,
      payload: {
        schemaKey,
        properties: r.fields || {},
        __source: { system: 'espocrm', id: r.sourceId, locationId },
      },
    });
    if (id) queued += 1; else skipped += 1;
  }
  return { queued, skipped };
}

// --- pass 5 -----------------------------------------------------------
// The pass that a CSV import cannot do. Both endpoints must already carry GHL
// ids; anything unresolved is reported rather than silently dropped, because a
// missing link is invisible in the destination and looks like clean data.
async function loadLinks(db, source, { locationId }) {
  let queued = 0, unresolved = [];
  for await (const l of source.links()) {
    const { rows } = await db.query(
      `SELECT
         (SELECT ghl_id FROM ghl.id_map
           WHERE entity_type='property' AND local_id=$1 AND location_id=$3) AS prop,
         (SELECT ghl_id FROM ghl.id_map
           WHERE entity_type='person'   AND local_id=$2 AND location_id=$3) AS person`,
      [l.propertyId, l.personId, locationId]
    );
    const { prop, person } = rows[0];
    if (!prop || !person) {
      unresolved.push({ ...l, missing: !prop ? 'property' : 'person' });
      continue;
    }
    const id = await enqueue(db, {
      idempotencyKey: key('relation.create', `${l.propertyId}:${l.personId}:${l.kind}`),
      operation: 'relation.create',
      entityType: 'relation',
      localId: null,
      payload: { firstRecordId: prop, secondRecordId: person, kind: l.kind, locationId },
    });
    if (id) queued += 1;
  }
  return { queued, unresolved };
}

// --- pass 7 -----------------------------------------------------------
async function reconcile(db, source, { locationId }) {
  const counts = { people: 0, properties: 0 };
  for await (const _ of source.people()) counts.people += 1;
  for await (const _ of source.properties()) counts.properties += 1;

  const { rows } = await db.query(
    `SELECT entity_type, count(*)::int AS n
       FROM ghl.id_map WHERE location_id = $1 GROUP BY entity_type`, [locationId]);
  const mapped = Object.fromEntries(rows.map((r) => [r.entity_type, r.n]));

  const { rows: stuck } = await db.query(
    `SELECT state, count(*)::int AS n FROM ghl.outbox
      WHERE state <> 'sent' GROUP BY state`);

  return {
    source: counts,
    mapped: { person: mapped.person || 0, property: mapped.property || 0 },
    shortfall: {
      person: counts.people - (mapped.person || 0),
      property: counts.properties - (mapped.property || 0),
    },
    outboxNotSent: Object.fromEntries(stuck.map((r) => [r.state, r.n])),
  };
}

module.exports = { PASSES, loadPeople, loadProperties, loadLinks, reconcile, key };
