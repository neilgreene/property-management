-- =====================================================================
-- 23_listing_sync_tests.sql  |  the walkthrough that matters
-- =====================================================================
-- Run: psql -d sdi -f sql/23_listing_sync_tests.sql
--
-- The scenario is the one the design exists for: a listing goes under
-- contract, escrow fails, and it comes back to market. Plus the two
-- failure modes that would be expensive: a feed outage, and a source
-- that is not allowed to act.
--
-- Restores everything it changes -- these tests run against the demo
-- database and a test that leaves a property pending is a test that
-- breaks the demo.
\pset border 2
\set ON_ERROR_STOP off
\set QUIET on

BEGIN;
CREATE TEMP TABLE _saved AS
  SELECT property_id, status FROM core.property
   WHERE listing_ref IN ('SDI-1041','SDI-2001');
COMMIT;

\echo ''
\echo '=== 0. Set up. SDI-1041 gains an authoritative MLS watch.'
BEGIN;
INSERT INTO feed.property_external (property_id, source_code, external_id)
SELECT property_id, 'MLS_RESO', 'TEST-KEY-1041' FROM core.property WHERE listing_ref='SDI-1041'
ON CONFLICT DO NOTHING;
UPDATE feed.listing_source SET active = true WHERE source_code = 'MLS_RESO';
COMMIT;

\echo ''
\echo '=== 1. The MLS says "Active Under Contract". confirm_after is 2, so'
\echo '===    the first sighting changes nothing. One reading of a feed is'
\echo '===    not evidence.'
SELECT result FROM feed.observe(
  (SELECT property_id FROM core.property WHERE listing_ref='SDI-1041'),
  'MLS_RESO','found','Active Under Contract', 228000);
SELECT listing_ref, status FROM core.property WHERE listing_ref='SDI-1041';

\echo ''
\echo '=== 2. It says it again. Now the listing moves to pending.'
SELECT result FROM feed.observe(
  (SELECT property_id FROM core.property WHERE listing_ref='SDI-1041'),
  'MLS_RESO','found','Active Under Contract', 228000);
SELECT listing_ref, status FROM core.property WHERE listing_ref='SDI-1041';

\echo ''
\echo '=== 3. ESCROW FAILS. The MLS returns it to Active.'
\echo '===    Acted on the FIRST sighting, deliberately: a saleable house'
\echo '===    shown as unavailable costs a sale every night it waits, and'
\echo '===    this is the cheap direction to be wrong in.'
SELECT result FROM feed.observe(
  (SELECT property_id FROM core.property WHERE listing_ref='SDI-1041'),
  'MLS_RESO','found','Active', 228000);
SELECT listing_ref, status FROM core.property WHERE listing_ref='SDI-1041';

\echo ''
\echo '=== 4. The feed goes down. Three errors in a row.'
\echo '===    Expect: nothing. An outage is not a market emptying.'
SELECT result FROM feed.observe(
  (SELECT property_id FROM core.property WHERE listing_ref='SDI-1041'),
  'MLS_RESO','error',NULL,NULL,NULL,'HTTP 503');
SELECT result FROM feed.observe(
  (SELECT property_id FROM core.property WHERE listing_ref='SDI-1041'),
  'MLS_RESO','error',NULL,NULL,NULL,'timeout');
SELECT result FROM feed.observe(
  (SELECT property_id FROM core.property WHERE listing_ref='SDI-1041'),
  'MLS_RESO','error',NULL,NULL,NULL,'timeout');
SELECT listing_ref, status FROM core.property WHERE listing_ref='SDI-1041';

\echo ''
\echo '=== 5. The listing genuinely disappears from the feed. Twice.'
\echo '===    Gone is not the same as sold, so it becomes withdrawn --'
\echo '===    the reversible one. We do not know which, so we do not guess.'
SELECT result FROM feed.observe(
  (SELECT property_id FROM core.property WHERE listing_ref='SDI-1041'),'MLS_RESO','missing');
SELECT result FROM feed.observe(
  (SELECT property_id FROM core.property WHERE listing_ref='SDI-1041'),'MLS_RESO','missing');
SELECT listing_ref, status FROM core.property WHERE listing_ref='SDI-1041';

\echo ''
\echo '=== 6. The audit trail. Every change, with the reason and the'
\echo '===    observation that caused it.'
SELECT p.listing_ref, c.from_status, c.to_status, c.actor, c.reason
FROM feed.status_change c JOIN core.property p USING (property_id)
WHERE p.listing_ref='SDI-1041' ORDER BY c.change_id;

\echo ''
\echo '=== 7. An ADVISORY source reports the same thing twice.'
\echo '===    Expect: a flag, and no status change. A scraper asks.'
BEGIN;
UPDATE core.property SET status='active' WHERE listing_ref='SDI-1041';
INSERT INTO feed.property_external (property_id, source_code, external_id)
SELECT property_id, 'RENTCAST', 'TEST-RC-1041' FROM core.property WHERE listing_ref='SDI-1041'
ON CONFLICT DO NOTHING;
COMMIT;
SELECT result FROM feed.observe(
  (SELECT property_id FROM core.property WHERE listing_ref='SDI-1041'),
  'RENTCAST','found','Pending');
SELECT result FROM feed.observe(
  (SELECT property_id FROM core.property WHERE listing_ref='SDI-1041'),
  'RENTCAST','found','Pending');
SELECT listing_ref, status FROM core.property WHERE listing_ref='SDI-1041';
SELECT kind, detail FROM api.listing_review_queue WHERE listing_ref='SDI-1041';

\echo ''
\echo '=== 8. A term nobody has mapped. Recorded, flagged, never guessed.'
SELECT result FROM feed.observe(
  (SELECT property_id FROM core.property WHERE listing_ref='SDI-1041'),
  'MLS_RESO','found','Auction Hold Pending Bank Approval');
SELECT kind, detail FROM api.listing_review_queue
 WHERE listing_ref='SDI-1041' AND kind='unmapped_status';

\echo ''
\echo '=== 9. The Irvine listing. Watched, and deliberately still a draft:'
\echo '===    it is tracked before it is trusted.'
SELECT p.listing_ref, p.status, p.street_address, p.city, p.state, p.zip,
       x.source_code, x.external_id
FROM core.property p JOIN feed.property_external x USING (property_id)
WHERE p.listing_ref='SDI-2001' ORDER BY x.source_code;

\echo ''
\echo '=== 10. Teardown. Everything this file touched is put back.'
BEGIN;
DELETE FROM feed.status_change WHERE property_id IN (SELECT property_id FROM _saved);
DELETE FROM feed.review_flag   WHERE property_id IN (SELECT property_id FROM _saved);
DELETE FROM feed.observation   WHERE property_id IN (SELECT property_id FROM _saved);
DELETE FROM feed.property_external
 WHERE source_code IN ('MLS_RESO','RENTCAST')
   AND property_id IN (SELECT property_id FROM _saved);
UPDATE core.property p SET status = s.status FROM _saved s
 WHERE p.property_id = s.property_id;
UPDATE feed.listing_source SET active = false WHERE source_code = 'MLS_RESO';
COMMIT;
SELECT listing_ref, status FROM core.property
 WHERE listing_ref IN ('SDI-1041','SDI-2001') ORDER BY 1;
