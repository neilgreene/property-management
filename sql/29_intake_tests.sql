-- =====================================================================
-- 29_intake_tests.sql  |  spreadsheet to listing, and the refusals
-- =====================================================================
-- Run: psql -d sdi -f sql/29_intake_tests.sql
--
-- What is checked is not that a row can be inserted. It is that nothing
-- reaches core.property except by a person's decision, that the blocking
-- validations actually block, and that "release ALL" means "release all
-- the APPROVED ones" rather than everything in the file.
--
-- Restores everything it changes.
\pset border 2
\set ON_ERROR_STOP off
\set QUIET on

BEGIN;
CREATE TEMP TABLE _before AS SELECT count(*) AS n FROM core.property;
COMMIT;

BEGIN;
INSERT INTO intake.zip_centroid (zip, city, state, lat, lng)
VALUES ('99001','Testville','WA',47.500000,-117.600000) ON CONFLICT DO NOTHING;

INSERT INTO intake.batch (batch_id, source_file, note, right_id) VALUES
 ('bbbbbbb1-0000-0000-0000-000000000001','test.xlsm','walkthrough','SDI-WORKBOOK');

INSERT INTO intake.row
 (batch_id, row_number, raw, street_address, city, state, zip, property_type,
  beds, baths, sqft, year_built, lat, lng, list_price, gross_rent_annual,
  opex_annual, hoa_annual, market_rent_monthly, property_tax_annual,
  insurance_annual, maintenance_annual, management_fee_bps, vacancy_allowance_bps) VALUES
 -- clean
 ('bbbbbbb1-0000-0000-0000-000000000001',1,'{"note":"clean"}'::jsonb,
  '1 Clean St','Testville','WA','99001','Single Family',3,2,1500,2001,
  47.5,-117.6, 200000, 24000, 8000, 0, 2000, 2400, 1200, 1200, 800, 400),
 -- no price
 ('bbbbbbb1-0000-0000-0000-000000000001',2,'{"note":"no price"}'::jsonb,
  '2 Broke St','Testville','WA','99001','Single Family',3,2,1500,2001,
  47.5,-117.6, NULL, 24000, 8000, 0, 2000, 2400, 1200, 1200, 800, 400),
 -- no coordinate
 ('bbbbbbb1-0000-0000-0000-000000000001',3,'{"note":"no coords"}'::jsonb,
  '3 Nowhere St','Testville','WA','99001','Single Family',3,2,1500,2001,
  NULL,NULL, 200000, 24000, 8000, 0, 2000, 2400, 1200, 1200, 800, 400),
 -- duplicated within the same file. Note that BOTH copies get flagged,
 -- not just the second: the system cannot know which one was intended,
 -- so it refuses them together and leaves the choice to a person. That is
 -- also why this duplicates row 2 rather than row 1 -- flagging a pair
 -- takes the clean row out of the batch with it.
 ('bbbbbbb1-0000-0000-0000-000000000001',4,'{"note":"dup"}'::jsonb,
  '2 Broke St','Testville','WA','99001','Single Family',3,2,1500,2001,
  47.5,-117.6, 210000, 24000, 8000, 0, 2000, 2400, 1200, 1200, 800, 400),
 -- an address that already exists in core.property
 ('bbbbbbb1-0000-0000-0000-000000000001',5,'{"note":"already listed"}'::jsonb,
  (SELECT street_address FROM core.property WHERE listing_ref='SDI-1041'),
  (SELECT city FROM core.property WHERE listing_ref='SDI-1041'),
  (SELECT state FROM core.property WHERE listing_ref='SDI-1041'),
  '99001','Single Family',3,2,1500,2001,47.5,-117.6,
  200000, 24000, 8000, 0, 2000, 2400, 1200, 1200, 800, 400);
COMMIT;

\echo ''
\echo '=== 1. Validation. Each blocked row names its own reason, and a'
\echo '===    clean row is pending -- not approved. Nothing auto-promotes.'
SELECT intake.validate_batch('bbbbbbb1-0000-0000-0000-000000000001') AS validated;
SELECT row_number, status, street_address,
       coalesce(string_agg(p->>'message', '; '), '') AS problems
FROM intake.row LEFT JOIN LATERAL jsonb_array_elements(problems) p ON true
WHERE batch_id='bbbbbbb1-0000-0000-0000-000000000001'
GROUP BY row_number, status, street_address ORDER BY row_number;

RESET ROLE; SET ROLE sdi_admin;
BEGIN;
SELECT set_config('app.actor_id','77777777-7777-7777-7777-777777777777',true),
       set_config('app.brand','BRAND_A',true) \g /dev/null

\echo ''
\echo '=== 2. An invalid row cannot be approved. Approving past a blocking'
\echo '===    error is how validation stops meaning anything.'
SELECT api.review_intake_rows(
  ARRAY(SELECT row_id FROM intake.row
         WHERE batch_id='bbbbbbb1-0000-0000-0000-000000000001' AND row_number=2),
  'approved') AS rows_changed;
SELECT row_number, status FROM intake.row
 WHERE batch_id='bbbbbbb1-0000-0000-0000-000000000001' AND row_number=2;

\echo ''
\echo '=== 3. A pending row cannot be released. Review is not advisory.'
SELECT outcome FROM api.release_intake_rows(
  ARRAY(SELECT row_id FROM intake.row
         WHERE batch_id='bbbbbbb1-0000-0000-0000-000000000001' AND row_number=1));

\echo ''
\echo '=== 4. Approve ALL. Only the releasable row moves; the four blocked'
\echo '===    rows stay exactly where they were.'
SELECT api.approve_batch('bbbbbbb1-0000-0000-0000-000000000001') AS approved;
SELECT row_number, status FROM intake.row
 WHERE batch_id='bbbbbbb1-0000-0000-0000-000000000001' ORDER BY row_number;

\echo ''
\echo '=== 5. Release the batch. One listing is created.'
SELECT out_listing_ref, outcome FROM api.release_batch('bbbbbbb1-0000-0000-0000-000000000001');

\echo ''
\echo '=== 6. It is a real listing, with its detail and its provenance.'
-- Read through api, not core. Staff hold no direct grant on core -- that
-- is the whole point of the schema separation, and forgetting it here
-- aborts the transaction and silently rolls back the release above.
SELECT d.listing_ref, d.street_address, d.city, d.list_price,
       round(d.cap_rate*100,2)||'%' AS cap, d.market_rent_monthly,
       (SELECT string_agg(pv.right_id||'/'||pv.scope, ' ')
          FROM gov.property_provenance pv WHERE pv.property_id=d.property_id) AS provenance
FROM api.property_detail d
WHERE d.street_address='1 Clean St';

\echo ''
\echo '=== 7. Re-validating row 1 now finds it already listed. Loading the'
\echo '===    same workbook twice cannot create the property twice.'
COMMIT;
BEGIN;
SELECT intake.validate(row_id) IS NOT NULL AS revalidated FROM intake.row
 WHERE batch_id='bbbbbbb1-0000-0000-0000-000000000001' AND row_number=1;
COMMIT;
SELECT row_number, status, (SELECT string_agg(p->>'message','; ')
       FROM jsonb_array_elements(problems) p) AS problems
FROM intake.row WHERE batch_id='bbbbbbb1-0000-0000-0000-000000000001' AND row_number=1;

\echo ''
\echo '=== 8. An investor sees it like any other listing -- gated.'
COMMIT;
RESET ROLE; SET ROLE sdi_investor;
BEGIN;
SELECT set_config('app.actor_id','22222222-2222-2222-2222-222222222222',true),
       set_config('app.brand','BRAND_A',true) \g /dev/null
SELECT listing_ref, city, state, list_price, street_address, address_unlocked
FROM api.property WHERE city='Testville';
COMMIT;

\echo ''
\echo '=== 9. Teardown.'
RESET ROLE;
BEGIN;
-- Order matters: intake.row holds a foreign key to the property it
-- released, so the batch goes first. Deleting the property first fails,
-- aborts the transaction, and leaves BOTH behind.
DELETE FROM intake.batch WHERE batch_id='bbbbbbb1-0000-0000-0000-000000000001';
DELETE FROM gov.property_provenance WHERE property_id IN
  (SELECT property_id FROM core.property WHERE street_address='1 Clean St');
DELETE FROM core.property_brand WHERE property_id IN
  (SELECT property_id FROM core.property WHERE street_address='1 Clean St');
DELETE FROM core.property WHERE street_address='1 Clean St';
DELETE FROM intake.zip_centroid WHERE zip='99001';
COMMIT;
SELECT (SELECT n FROM _before) AS properties_before,
       (SELECT count(*) FROM core.property) AS properties_after,
       (SELECT count(*) FROM api.security_invariants()) AS invariant_violations;
