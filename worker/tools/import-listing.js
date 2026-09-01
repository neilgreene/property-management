#!/usr/bin/env node
// =====================================================================
// import-listing.js  |  fill in a tracked listing by hand
// =====================================================================
// The path that works with no integration at all: somebody reads a
// listing, writes the numbers into a JSON file, and this loads them.
//
//   node tools/import-listing.js listing.json
//
// The file:
//   {
//     "listing_ref": "SDI-2001",
//     "status": "active",
//     "beds": 4, "baths": 3, "sqft": 2450, "year_built": 2004,
//     "list_price": 1685000,
//     "gross_rent_annual": 78000, "opex_annual": 24000, "hoa_annual": 2400,
//     "lat": 33.6541, "lng": -117.7462,
//     "detail": { "headline": "...", "market_rent_monthly": 6500, ... }
//   }
//
// Only the keys present are written -- this is a merge, not a replace, so
// re-running it with one corrected field does not blank the others.
//
// It writes through core directly as sdi_integration rather than through
// api, because api's write surface is scoped to what a signed-in person
// may do and this is an operator tool. It still records a status change
// with an actor, so the nightly reconciler sees a human decision and
// defers to it.
'use strict';

const fs = require('fs');
const { makePool } = require('../src/db');

const PROPERTY_FIELDS = ['status', 'property_type', 'beds', 'baths', 'sqft', 'year_built',
  'list_price', 'gross_rent_annual', 'opex_annual', 'hoa_annual',
  'street_address', 'unit', 'lat', 'lng', 'parcel_number', 'seller_disclosure',
  'city', 'state', 'zip', 'internal_notes'];

const DETAIL_FIELDS = ['headline', 'description', 'market_rent_monthly', 'rent_basis',
  'property_tax_annual', 'insurance_annual', 'utilities_monthly', 'utilities_paid_by',
  'maintenance_annual', 'management_fee_bps', 'vacancy_allowance_bps',
  'lot_sqft', 'stories', 'garage_spaces', 'heating', 'cooling', 'roof_year',
  'last_renovated', 'parking'];

(async () => {
  const path = process.argv[2];
  if (!path) { console.error('usage: import-listing.js <file.json>'); process.exit(2); }
  const doc = JSON.parse(fs.readFileSync(path, 'utf8'));
  if (!doc.listing_ref) { console.error('listing_ref is required'); process.exit(2); }

  const pool = makePool();
  const db = await pool.connect();
  try {
    await db.query('BEGIN');
    const { rows } = await db.query(
      'SELECT property_id, status FROM core.property WHERE listing_ref = $1', [doc.listing_ref]);
    if (!rows.length) throw new Error(`no property with listing_ref ${doc.listing_ref}`);
    const { property_id, status: was } = rows[0];

    const sets = [], args = [property_id];
    for (const f of PROPERTY_FIELDS) {
      if (doc[f] === undefined) continue;
      args.push(doc[f]); sets.push(`${f} = $${args.length}`);
    }
    if (sets.length) {
      await db.query(`UPDATE core.property SET ${sets.join(', ')} WHERE property_id = $1`, args);
    }

    if (doc.detail) {
      const cols = ['property_id'], vals = ['$1'], dargs = [property_id];
      for (const f of DETAIL_FIELDS) {
        if (doc.detail[f] === undefined) continue;
        dargs.push(doc.detail[f]); cols.push(f); vals.push(`$${dargs.length}`);
      }
      if (doc.detail.features) {
        dargs.push(JSON.stringify(doc.detail.features));
        cols.push('features'); vals.push(`$${dargs.length}::jsonb`);
      }
      const updates = cols.slice(1).map((c) => `${c} = EXCLUDED.${c}`).join(', ');
      await db.query(
        `INSERT INTO core.property_detail (${cols.join(',')}) VALUES (${vals.join(',')})
         ON CONFLICT (property_id) DO UPDATE SET ${updates}, updated_at = now()`, dargs);
    }

    if (doc.status && doc.status !== was) {
      await db.query(
        `INSERT INTO feed.status_change
           (property_id, from_status, to_status, reason, source_code, actor)
         VALUES ($1,$2,$3,$4,'MANUAL',$5)`,
        [property_id, was, doc.status,
         doc.reason || `imported from ${path}`,
         doc.actor || 'operator']);
    }
    if (doc.published !== undefined) {
      await db.query(
        `INSERT INTO core.property_brand (property_id, brand_code, published)
         VALUES ($1, $2, $3)
         ON CONFLICT (property_id, brand_code) DO UPDATE SET published = EXCLUDED.published`,
        [property_id, doc.brand_code || 'BRAND_A', !!doc.published]);
    }

    await db.query('COMMIT');
    console.log(`${doc.listing_ref}: updated${doc.status && doc.status !== was
      ? ` (${was} -> ${doc.status})` : ''}`);
  } catch (e) {
    await db.query('ROLLBACK').catch(() => {});
    console.error('import failed:', e.message);
    process.exitCode = 1;
  } finally {
    db.release(); await pool.end();
  }
})();
