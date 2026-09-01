#!/usr/bin/env node
// Run the listing sweep once. This is what the nightly schedule calls:
//
//   docker compose run --rm worker node tools/check-listings.js
//   0 7 * * *  cd /srv/sdi && docker compose run --rm worker node tools/check-listings.js
//
// Safe to run by hand at any time. Every source is rate-limited per
// source, an observation is idempotent in effect (recording the same
// status twice changes nothing), and a run that dies part way through
// has simply done less work -- there is no half-applied state, because
// each property is one transaction.
'use strict';

const { makePool } = require('../src/db');
const { run } = require('../src/listings/nightly');

(async () => {
  const pool = makePool();
  try {
    const t = await run(pool, { log: console });
    console.log(JSON.stringify(t, null, 2));
    process.exitCode = 0;
  } catch (e) {
    console.error('sweep failed:', e.message);
    process.exitCode = 1;
  } finally {
    await pool.end();
  }
})();
