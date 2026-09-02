#!/usr/bin/env node
// =====================================================================
// load-intake.js  |  JSON from a workbook into the review queue
// =====================================================================
//   python3 tools/workbook-to-json.py *.xlsm > batch.json
//   node worker/tools/load-intake.js batch.json --note "August sourcing"
//
// Creates one batch, one row per property, validates every row, and
// prints what a reviewer needs to decide on. It does NOT create a single
// listing: nothing reaches core.property until somebody releases it.
//
// The whole payload is stored verbatim in intake.row.raw alongside our
// reading of it. When a released listing later says something surprising,
// the only useful question is whether the spreadsheet said that or
// whether we mistranslated it -- and that question has no answer if the
// import overwrote its own input.
'use strict';

const fs = require('fs');
const { makePool } = require('../src/db');

const FIELDS = [
  'street_address', 'unit', 'city', 'state', 'zip', 'property_type',
  'beds', 'baths', 'sqft', 'year_built', 'lat', 'lng',
  'list_price', 'gross_rent_annual', 'opex_annual', 'hoa_annual',
  'market_rent_monthly', 'property_tax_annual', 'insurance_annual',
  'maintenance_annual', 'management_fee_bps', 'vacancy_allowance_bps',
  'lot_sqft', 'garage_spaces', 'description', 'internal_notes',
];

(async () => {
  const path = process.argv[2];
  if (!path) {
    console.error('usage: load-intake.js <batch.json> [--note "text"]');
    process.exit(2);
  }
  const ni = process.argv.indexOf('--note');
  const note = ni > 0 ? process.argv[ni + 1] : null;
  // Which instrument this file's contents are held under. Optional at
  // load time -- the question can outlive the upload -- but a release
  // with none recorded leaves the listing in gov.uncovered_publication.
  const ri = process.argv.indexOf('--right');
  const rightId = ri > 0 ? process.argv[ri + 1] : 'SDI-WORKBOOK';

  const doc = JSON.parse(fs.readFileSync(path, 'utf8'));
  if (!Array.isArray(doc.rows) || !doc.rows.length) {
    console.error('refused: no rows in the file');
    process.exit(2);
  }

  const pool = makePool();
  const db = await pool.connect();
  try {
    await db.query('BEGIN');

    const b = await db.query(
      `INSERT INTO intake.batch (source_file, source_kind, mapping_version, note, right_id)
       VALUES ($1,$2,$3,$4,$5) RETURNING batch_id`,
      [doc.source_file || path, doc.source_kind || 'sdi_workbook',
       doc.mapping_version || 'v1', note, rightId || null]);
    const batchId = b.rows[0].batch_id;

    for (const [i, r] of doc.rows.entries()) {
      // The coordinate the workbook does not carry. A ZIP centroid is
      // accurate to about a mile, which is exactly what an ungated viewer
      // is shown anyway -- but a row with no centroid is left without one
      // so validation blocks it, rather than being quietly placed at the
      // centre of the wrong city.
      let lat = r.lat ?? null, lng = r.lng ?? null;
      if (lat == null && r.zip) {
        const c = await db.query(
          'SELECT lat, lng FROM intake.zip_centroid WHERE zip = $1', [r.zip]);
        if (c.rowCount) ({ lat, lng } = c.rows[0]);
      }

      const vals = FIELDS.map((f) => (f === 'lat' ? lat : f === 'lng' ? lng : r[f] ?? null));
      const cols = ['batch_id', 'row_number', 'raw', ...FIELDS];
      const ph = cols.map((_, n) => `$${n + 1}`);
      ph[2] = `$3::jsonb`;
      await db.query(
        `INSERT INTO intake.row (${cols.join(',')}) VALUES (${ph.join(',')})`,
        [batchId, i + 1, JSON.stringify(r.raw ?? r), ...vals]);
    }

    await db.query('SELECT intake.validate_batch($1)', [batchId]);
    await db.query('COMMIT');

    const rows = (await db.query(
      `SELECT row_number, status, street_address, city, state, list_price,
              gross_rent_annual, cap_rate, problems
         FROM api.intake_row WHERE batch_id = $1 ORDER BY row_number`, [batchId])).rows;

    console.log(`batch ${batchId}`);
    console.log(`  ${rows.length} row(s) from ${doc.source_file}\n`);
    for (const r of rows) {
      const cap = r.cap_rate == null ? '   —  ' : (Number(r.cap_rate) * 100).toFixed(2) + '%';
      console.log(`  ${String(r.row_number).padStart(2)}. [${r.status.padEnd(8)}] `
        + `${(r.street_address || '(no address)').padEnd(22)} ${(r.city || '').padEnd(14)}`
        + ` $${Number(r.list_price || 0).toLocaleString().padStart(9)}  cap ${cap}`);
      for (const p of r.problems || []) {
        console.log(`      ${p.level === 'error' ? 'ERROR  ' : 'warning'} ${p.field}: ${p.message}`);
      }
    }

    const invalid = rows.filter((r) => r.status === 'invalid').length;
    console.log(`\n  ${rows.length - invalid} ready for review, ${invalid} blocked.`);
    console.log('\n  Approve everything releasable, then release:');
    console.log(`    SELECT api.approve_batch('${batchId}');`);
    console.log(`    SELECT * FROM api.release_batch('${batchId}');`);
    if (rightId) {
      const r = (await db.query(
        'SELECT review_status FROM gov.data_right WHERE right_id = $1', [rightId])).rows[0];
      if (r && r.review_status !== 'counsel_confirmed') {
        console.log(`\n  Note: data right ${rightId} is ${r.review_status}. Releasing under it`);
        console.log('  publishes with a warning and lists the property in');
        console.log('  gov.uncovered_publication until the instrument is confirmed.');
      }
    }
    console.log('\n  Or pick specific rows:');
    console.log(`    SELECT api.review_intake_rows(ARRAY['<row_id>']::uuid[], 'approved');`);
    console.log(`    SELECT * FROM api.release_intake_rows(ARRAY['<row_id>']::uuid[]);`);
  } catch (e) {
    await db.query('ROLLBACK').catch(() => {});
    console.error('load failed:', e.message);
    process.exitCode = 1;
  } finally {
    db.release(); await pool.end();
  }
})();
