-- =====================================================================
-- 14_pipeline_tests.sql  |  deal visibility and stage history
-- Eight checks. Four are attacks.
-- =====================================================================
\pset border 2
\set QUIET on
\set ON_ERROR_STOP off

\echo
\echo '=== 1. Ruth (investor) sees only her own deal.'
BEGIN;
SET LOCAL ROLE sdi_investor;
SELECT set_config('app.actor_id','11111111-1111-1111-1111-111111111111',true);
SELECT listing_ref, stage_name, amount, investor_name, agent_name FROM api.deal ORDER BY listing_ref;
COMMIT;

\echo
\echo '=== 2. Marcus sees only his. Same SQL, same role, different rows.'
BEGIN;
SET LOCAL ROLE sdi_investor;
SELECT set_config('app.actor_id','22222222-2222-2222-2222-222222222222',true);
SELECT listing_ref, stage_name, amount FROM api.deal ORDER BY listing_ref;
COMMIT;

\echo
\echo '=== 3. Tom (agent) sees the two deals he is the agent on -- across'
\echo '===    two different investors, and both pipelines.'
BEGIN;
SET LOCAL ROLE sdi_agent;
SELECT set_config('app.actor_id','44444444-4444-4444-4444-444444444444',true);
SELECT COALESCE(listing_ref,'(property not visible)') AS listing,
       pipeline_code, stage_name, investor_name
FROM api.deal ORDER BY pipeline_code;
COMMIT;

\echo
\echo '=== 4. ATTACK: the public role reads deals. Expect: denied.'
\echo '===    A deal is never public, at any stage.'
BEGIN;
SET LOCAL ROLE sdi_public;
SELECT count(*) FROM api.deal;
ROLLBACK;

\echo
\echo '=== 5. ATTACK: Priya (agent) reads Toms deal by naming its id.'
\echo '===    Expect 0 rows -- the policy is per row, not per query.'
BEGIN;
SET LOCAL ROLE sdi_agent;
SELECT set_config('app.actor_id','55555555-5555-5555-5555-555555555555',true);
SELECT count(*) AS rows_for_priya FROM api.deal
 WHERE deal_id = 'dddddddd-0000-0000-0000-000000000001';
COMMIT;

\echo
\echo '=== 6. ATTACK: Marcus reads Ruths stage history directly.'
\echo '===    History must follow the deal, not stand open beside it.'
BEGIN;
SET LOCAL ROLE sdi_investor;
SELECT set_config('app.actor_id','22222222-2222-2222-2222-222222222222',true);
SELECT count(*) AS history_rows_visible FROM api.deal_history
 WHERE deal_id = 'dddddddd-0000-0000-0000-000000000001';
COMMIT;

\echo
\echo '=== 7. Ruth sees her own transition log, in order.'
BEGIN;
SET LOCAL ROLE sdi_investor;
SELECT set_config('app.actor_id','11111111-1111-1111-1111-111111111111',true);
-- Order by id: several transitions in one transaction share a
-- timestamp, so changed_at alone is not a stable sort.
SELECT from_stage, to_stage FROM api.deal_history ORDER BY id;
COMMIT;

\echo
\echo '=== 8. Moving to a terminal stage closes the deal; the trigger keeps'
\echo '===    closed_at and stage_code from ever disagreeing.'
-- Inside a transaction that rolls back, so re-running this script does not
-- accumulate stage history and quietly change what check 7 reports.
BEGIN;
UPDATE core.deal SET stage_code='CLOSED_WON' WHERE external_ref='ESPO-D-1';
SELECT external_ref, stage_code, closed_at IS NOT NULL AS closed FROM core.deal
 WHERE external_ref='ESPO-D-1';
UPDATE core.deal SET stage_code='CONTRACT' WHERE external_ref='ESPO-D-1';
SELECT external_ref, stage_code, closed_at IS NOT NULL AS closed FROM core.deal
 WHERE external_ref='ESPO-D-1';
ROLLBACK;

\echo
\echo '=== 9. Standing invariants still hold.'
SELECT * FROM api.security_invariants();

\echo
\echo '=== Pipeline checks complete.'
