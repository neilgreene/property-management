-- =====================================================================
-- 27_governance_tests.sql  |  the register, exercised
-- =====================================================================
-- Run: psql -d sdi -f sql/27_governance_tests.sql
--
-- What is being checked is not that the tables exist. It is that the
-- four ways a right fails to apply -- unreviewed, expired, out of
-- territory, use not granted -- each produce a refusal on their own, and
-- that flipping enforcement to blocking actually blocks.
--
-- Restores everything, including the enforcement mode.
\pset border 2
\set ON_ERROR_STOP off
\set QUIET on

BEGIN;
CREATE TEMP TABLE _mode AS SELECT enforcement_mode FROM gov.policy;
COMMIT;

-- Two fixture properties with NO provenance of their own. The demo
-- dataset is entirely covered by DEMO-SYNTH, so testing against it would
-- prove nothing -- every answer would already be yes for a reason that
-- has nothing to do with what is being checked.
BEGIN;
INSERT INTO core.property (property_id, listing_ref, status, city, state, zip,
  property_type, list_price, gross_rent_annual, opex_annual, hoa_annual,
  street_address, lat, lng) VALUES
 ('aaaaaaa1-0000-0000-0000-00000000de01','SDI-TEST-OH','active','Cleveland','OH','44109',
  'Single Family',100000,12000,4000,0,'1 Test St',41.44,-81.70),
 ('aaaaaaa1-0000-0000-0000-00000000de02','SDI-TEST-FL','active','Tampa','FL','33604',
  'Single Family',100000,12000,4000,0,'2 Test St',27.96,-82.45)
ON CONFLICT (property_id) DO NOTHING;
COMMIT;

\echo ''
\echo '=== 0. Where the register stands.'
SELECT * FROM api.governance_status;

\echo ''
\echo '=== 1. A right is built up one failing condition at a time.'
\echo '===    Each step fixes exactly one thing, and may_use stays false'
\echo '===    until every condition holds. These are AND, not a score.'
BEGIN;
INSERT INTO gov.data_right (right_id, name, grantor, instrument, review_status)
VALUES ('TEST-RIGHT','Test instrument','Test grantor','vendor_subscription','unreviewed');
INSERT INTO gov.property_provenance (property_id, right_id, scope) VALUES
 ('aaaaaaa1-0000-0000-0000-00000000de01','TEST-RIGHT','listing_facts'),
 ('aaaaaaa1-0000-0000-0000-00000000de02','TEST-RIGHT','listing_facts');
COMMIT;

SELECT '1. provenance only'          AS step, gov.may_use('aaaaaaa1-0000-0000-0000-00000000de01','public_display') AS may_publish;
BEGIN;
INSERT INTO gov.data_right_use (right_id, use_code, posture)
VALUES ('TEST-RIGHT','public_display','granted');
COMMIT;
SELECT '2. + use granted'            AS step, gov.may_use('aaaaaaa1-0000-0000-0000-00000000de01','public_display') AS may_publish;
BEGIN;
INSERT INTO gov.data_right_territory (right_id, territory_id) VALUES ('TEST-RIGHT','US-OH');
COMMIT;
SELECT '3. + territory Ohio'         AS step, gov.may_use('aaaaaaa1-0000-0000-0000-00000000de01','public_display') AS may_publish;
BEGIN;
UPDATE gov.data_right SET review_status='counsel_confirmed', reviewed_by='test'
 WHERE right_id='TEST-RIGHT';
COMMIT;
SELECT '4. + counsel confirmed'      AS step, gov.may_use('aaaaaaa1-0000-0000-0000-00000000de01','public_display') AS may_publish;

\echo ''
\echo '=== 2. Territory. The same confirmed right does NOT reach the Florida'
\echo '===    property. This is the licensing breach the schema exists to'
\echo '===    make impossible -- the software would work perfectly.'
SELECT p.listing_ref, p.city, p.state,
       gov.may_use(p.property_id,'public_display') AS may_publish
FROM core.property p WHERE p.listing_ref LIKE 'SDI-TEST-%' ORDER BY 1;

\echo ''
\echo '=== 3. Expiry. A right that ran out yesterday stops applying today,'
\echo '===    with no job to run and nothing to remember.'
BEGIN;
UPDATE gov.data_right SET effective_to = current_date - 1 WHERE right_id='TEST-RIGHT';
COMMIT;
SELECT 'expired yesterday' AS state,
       gov.may_use('aaaaaaa1-0000-0000-0000-00000000de01','public_display') AS may_publish;
BEGIN;
UPDATE gov.data_right SET effective_to = NULL WHERE right_id='TEST-RIGHT';
COMMIT;

\echo ''
\echo '=== 4. Use. A right granting public display says nothing about'
\echo '===    exporting or training on the data. Silence is not permission.'
SELECT k.use_code, coalesce(u.posture,'(no row)') AS posture,
       gov.may_use('aaaaaaa1-0000-0000-0000-00000000de01', k.use_code) AS may
FROM gov.use_kind k LEFT JOIN gov.data_right_use u
  ON u.use_code = k.use_code AND u.right_id='TEST-RIGHT'
ORDER BY k.use_code;

\echo ''
\echo '=== 5. Scope. A right over listing facts says nothing about the'
\echo '===    photographs, which is how portals get sued.'
SELECT 'listing_facts' AS scope, gov.may_use('aaaaaaa1-0000-0000-0000-00000000de01','public_display','listing_facts') AS may
UNION ALL
SELECT 'media',                  gov.may_use('aaaaaaa1-0000-0000-0000-00000000de01','public_display','media');

\echo ''
\echo '=== 6. Advisory mode: publishing an uncovered listing warns and'
\echo '===    proceeds. A control that took a live marketplace off the air'
\echo '===    on the day it shipped would simply be reverted.'
BEGIN;
UPDATE gov.policy SET enforcement_mode='advisory';
-- The Florida fixture: covered by a right that does not reach it.
INSERT INTO core.property_brand (property_id, brand_code, published)
VALUES ('aaaaaaa1-0000-0000-0000-00000000de02','BRAND_A',true)
ON CONFLICT (property_id, brand_code) DO UPDATE SET published = true;
COMMIT;
SELECT listing_ref, reason FROM gov.uncovered_publication ORDER BY 1;

\echo ''
\echo '=== 7. Blocking mode: the same insert is refused, and the invariant'
\echo '===    now reports the backlog. Flipping the mode is the go-live gate.'
BEGIN;
UPDATE gov.policy SET enforcement_mode='blocking';
COMMIT;
SELECT count(*) AS invariant_violations_in_blocking_mode FROM api.security_invariants();
BEGIN;
UPDATE core.property_brand SET published = false
 WHERE property_id = 'aaaaaaa1-0000-0000-0000-00000000de02';
COMMIT;
BEGIN;
UPDATE core.property_brand SET published = true
 WHERE property_id = 'aaaaaaa1-0000-0000-0000-00000000de02';
COMMIT;
SELECT 'still unpublished after the refused update' AS state, published
FROM core.property_brand WHERE property_id='aaaaaaa1-0000-0000-0000-00000000de02';

\echo ''
\echo '=== 8. Fair housing. No protected characteristic or named proxy is'
\echo '===    exposed anywhere a caller could filter on it.'
SELECT count(*) AS prohibited_dimensions_registered FROM gov.prohibited_dimension;
SELECT violation, detail FROM api.security_invariants()
 WHERE violation = 'prohibited dimension exposed in api';
\echo '===    (zero rows above is the pass. The web tier refuses to start if'
\echo '===     its filter allowlist ever intersects this register.)'

\echo ''
\echo '=== 9. The compliance register, and its honest gaps.'
SELECT reg_code, regime, status, gap FROM api.compliance_register
 WHERE gap ORDER BY reg_code;

\echo ''
\echo '=== 10. Teardown.'
BEGIN;
DELETE FROM core.property_brand
 WHERE property_id IN (SELECT property_id FROM core.property WHERE listing_ref LIKE 'SDI-TEST-%');
DELETE FROM gov.property_provenance
 WHERE property_id IN (SELECT property_id FROM core.property WHERE listing_ref LIKE 'SDI-TEST-%');
DELETE FROM core.property WHERE listing_ref LIKE 'SDI-TEST-%';
DELETE FROM gov.property_provenance WHERE right_id='TEST-RIGHT';
DELETE FROM gov.data_right      WHERE right_id='TEST-RIGHT';
UPDATE gov.policy SET enforcement_mode = (SELECT enforcement_mode FROM _mode);
COMMIT;
SELECT (SELECT enforcement_mode FROM gov.policy) AS mode_restored,
       (SELECT count(*) FROM api.security_invariants()) AS invariant_violations;
