// =====================================================================
// listings/nightly.js  |  the sweep
// =====================================================================
// Walks every enabled watch, oldest check first, asks the source, and
// hands the answer to the database. It decides nothing: feed.observe()
// records what was seen and feed.reconcile() decides what it means, so
// the policy ("two agreeing checks before believing a delisting", "an
// advisory source only raises a flag") lives in one place and is the
// same whether the observation came from this loop, from a backfill, or
// from a staff member.
//
// Oldest first matters. A run that is cut short -- a timeout, a
// deployment, a rate limit -- has still done the most overdue work.
'use strict';

const crypto = require('crypto');
const { build } = require('./adapters');

// Between calls to the same source. A feed under a data agreement will
// have its own limit; this is the floor that keeps us from being the
// reason it gets tightened.
const DEFAULT_GAP_MS = 1200;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function due(db, limit) {
  const { rows } = await db.query(
    `SELECT d.*, p.street_address, p.city, p.state, p.zip
       FROM feed.due_for_check d
       JOIN core.property p ON p.property_id = d.property_id
      LIMIT $1`, [limit]);
  return rows;
}

// `adapters` is injectable so a test can drive the loop from a script
// without an HTTP client. It is a parameter rather than a module-level
// hook because destructuring `build` at import time makes the export
// unpatchable -- a test that monkey-patches it silently tests nothing.
async function run(db, {
  limit = 500, gapMs = DEFAULT_GAP_MS, env = process.env, log = console,
  adapters = null,
} = {}) {
  const runId = crypto.randomUUID();
  adapters = adapters || build(db, env);
  const rows = await due(db, limit);
  const tally = { run_id: runId, checked: 0, found: 0, missing: 0, errors: 0,
                  changed: [], flagged: 0, skipped: 0 };

  const lastCall = new Map();

  for (const row of rows) {
    const adapter = adapters.get(row.source_code);
    if (!adapter) { tally.skipped++; continue; }

    // Space out calls per source, not globally: two sources have no
    // reason to wait for each other.
    const since = Date.now() - (lastCall.get(row.source_code) || 0);
    if (since < gapMs) await sleep(gapMs - since);
    lastCall.set(row.source_code, Date.now());

    let r;
    try {
      r = await adapter.check({
        property_id: row.property_id,
        external_id: row.external_id,
        external_url: row.external_url,
        property: { street_address: row.street_address, city: row.city,
                    state: row.state, zip: row.zip },
      });
    } catch (e) {
      // An adapter that throws is an adapter that could not tell us. It
      // is never an absence.
      r = { outcome: 'error', error: `adapter threw: ${e.message}` };
    }

    tally.checked++;
    tally[r.outcome === 'found' ? 'found' : r.outcome === 'missing' ? 'missing' : 'errors']++;

    const { rows: out } = await db.query(
      `SELECT * FROM feed.observe($1,$2,$3,$4,$5,$6,$7,$8)`,
      [row.property_id, row.source_code, r.outcome, r.raw_status || null,
       r.list_price ?? null, r.payload ? JSON.stringify(r.payload) : null,
       r.error || null, runId]);

    const result = out[0] && out[0].result;
    if (result && result.includes('->')) {
      tally.changed.push({ listing_ref: row.listing_ref, source: row.source_code, result });
      log.info?.(`${row.listing_ref}: ${result} (${row.source_code})`);
    } else if (result && result.includes('flag')) {
      tally.flagged++;
    }
  }

  log.info?.(`listing sweep ${runId}: ${tally.checked} checked, `
    + `${tally.changed.length} status changes, ${tally.flagged} flagged, `
    + `${tally.errors} errors`);
  return tally;
}

module.exports = { run, due };
