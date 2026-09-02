#!/usr/bin/env node
// =====================================================================
// record-data-right.js  |  put a real instrument into the register
// =====================================================================
//   node tools/record-data-right.js right.json
//   node tools/record-data-right.js right.json --confirm "J. Smith, counsel"
//
// The register is only worth having if it matches the agreements the
// business actually holds, and transcribing those is a person's job, not
// a scraper's. This is the loader for that transcription.
//
// It refuses to mark a right counsel-confirmed from the file itself.
// review_status can only reach 'counsel_confirmed' through --confirm with
// a named reviewer, because "somebody set a flag in a JSON file" and "a
// lawyer read the contract" must not look the same afterwards.
//
// See docs/data-rights-intake.md for the questionnaire this file answers.
'use strict';

const fs = require('fs');
const { makePool } = require('../src/db');

const USES = ['internal_analysis', 'gated_display', 'public_display', 'derive',
              'redistribute', 'export', 'marketing', 'model_training'];

function fail(msg) { console.error('refused:', msg); process.exit(2); }

(async () => {
  const path = process.argv[2];
  if (!path) fail('usage: record-data-right.js <file.json> [--confirm "reviewer name"]');
  const ci = process.argv.indexOf('--confirm');
  const reviewer = ci > 0 ? process.argv[ci + 1] : null;
  if (ci > 0 && !reviewer) fail('--confirm needs a reviewer name');

  const d = JSON.parse(fs.readFileSync(path, 'utf8'));
  for (const k of ['right_id', 'name', 'grantor', 'instrument', 'territories', 'uses']) {
    if (d[k] === undefined) fail(`missing required field: ${k}`);
  }
  if (!Array.isArray(d.territories) || !d.territories.length) {
    fail('territories must be a non-empty list. A right with no territory covers nothing, '
       + 'and recording it as covering everything is how a Cleveland feed ends up '
       + 'publishing a house in Irvine.');
  }
  const unknown = Object.keys(d.uses).filter((u) => !USES.includes(u));
  if (unknown.length) fail(`unknown use codes: ${unknown.join(', ')}`);

  const pool = makePool();
  const db = await pool.connect();
  try {
    await db.query('BEGIN');

    for (const t of d.territories) {
      const { rowCount } = await db.query(
        'SELECT 1 FROM gov.territory WHERE territory_id = $1', [t]);
      if (!rowCount) {
        throw new Error(`territory ${t} is not defined. Add it to gov.territory first, `
                      + 'including its parent and, for a market, its member places.');
      }
    }

    await db.query(
      `INSERT INTO gov.data_right
         (right_id, name, grantor, instrument, source_code, reference,
          counterparty_contact, effective_from, effective_to,
          survives_termination, review_status, reviewed_by, reviewed_on, notes)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14)
       ON CONFLICT (right_id) DO UPDATE SET
         name = EXCLUDED.name, grantor = EXCLUDED.grantor,
         instrument = EXCLUDED.instrument, source_code = EXCLUDED.source_code,
         reference = EXCLUDED.reference,
         counterparty_contact = EXCLUDED.counterparty_contact,
         effective_from = EXCLUDED.effective_from,
         effective_to = EXCLUDED.effective_to,
         survives_termination = EXCLUDED.survives_termination,
         notes = EXCLUDED.notes`,
      [d.right_id, d.name, d.grantor, d.instrument, d.source_code || null,
       d.reference || null, d.contact || null,
       d.effective_from || null, d.effective_to || null,
       !!d.survives_termination,
       // Never from the file. See the header.
       reviewer ? 'counsel_confirmed' : 'unreviewed',
       reviewer, reviewer ? new Date().toISOString().slice(0, 10) : null,
       d.notes || null]);

    if (reviewer) {
      await db.query(
        `UPDATE gov.data_right SET review_status = 'counsel_confirmed',
                reviewed_by = $2, reviewed_on = current_date WHERE right_id = $1`,
        [d.right_id, reviewer]);
    }

    await db.query('DELETE FROM gov.data_right_territory WHERE right_id = $1', [d.right_id]);
    for (const t of d.territories) {
      await db.query(
        'INSERT INTO gov.data_right_territory (right_id, territory_id) VALUES ($1,$2)',
        [d.right_id, t]);
    }

    await db.query('DELETE FROM gov.data_right_use WHERE right_id = $1', [d.right_id]);
    for (const use of USES) {
      const v = d.uses[use];
      // A use the file does not mention is 'unclear', never 'granted'.
      // Silence is not permission, and writing every use out explicitly
      // means a reader can tell "we did not ask" from "they said no".
      const posture = v === undefined ? 'unclear'
        : typeof v === 'string' ? v
        : v === true ? 'granted' : v === false ? 'refused' : (v.posture || 'unclear');
      const condition = (v && typeof v === 'object' && v.condition) || null;
      if (!['granted', 'refused', 'unclear'].includes(posture)) {
        throw new Error(`use ${use}: posture must be granted, refused or unclear`);
      }
      await db.query(
        `INSERT INTO gov.data_right_use (right_id, use_code, posture, condition)
         VALUES ($1,$2,$3,$4)`, [d.right_id, use, posture, condition]);
    }

    for (const o of d.obligations || []) {
      await db.query(
        `INSERT INTO gov.obligation
           (right_id, kind, interval_hours, text_required, detail, enforcement)
         VALUES ($1,$2,$3,$4,$5,$6)`,
        [d.right_id, o.kind, o.interval_hours ?? null, o.text_required || null,
         o.detail, o.enforcement || 'unenforced']);
    }

    // Attach it to properties, if the file says which.
    let attached = 0;
    for (const ref of d.covers_listing_refs || []) {
      for (const scope of d.scopes || ['listing_facts']) {
        const r = await db.query(
          `INSERT INTO gov.property_provenance (property_id, right_id, scope)
           SELECT property_id, $2, $3 FROM core.property WHERE listing_ref = $1
           ON CONFLICT DO NOTHING`, [ref, d.right_id, scope]);
        attached += r.rowCount;
      }
    }

    await db.query('COMMIT');

    const granted = Object.entries(d.uses)
      .filter(([, v]) => v === true || v === 'granted' || (v && v.posture === 'granted'))
      .map(([k]) => k);
    console.log(`${d.right_id}: recorded, ${reviewer ? 'counsel-confirmed' : 'UNREVIEWED'}`);
    console.log(`  territories: ${d.territories.join(', ')}`);
    console.log(`  granted:     ${granted.join(', ') || '(none)'}`);
    if (attached) console.log(`  attached to ${attached} property/scope pairs`);
    if (!reviewer) {
      console.log('\n  Note: gov.may_use() only honours a counsel-confirmed right, so this');
      console.log('  one grants nothing yet. Re-run with --confirm "name" once reviewed.');
    }
  } catch (e) {
    await db.query('ROLLBACK').catch(() => {});
    console.error('failed:', e.message);
    process.exitCode = 1;
  } finally {
    db.release(); await pool.end();
  }
})();
