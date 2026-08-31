-- =====================================================================
-- 10_review_tests.sql  |  acting on the review queue
-- Six checks. Two are the happy path; four are attacks on the allowlist
-- and on who is allowed to decide.
-- =====================================================================
\pset border 2
\set QUIET on
\set ON_ERROR_STOP off

\echo
\echo '=== setup: a CRM edit arrives for a mapped property.'
\echo '===   It proposes a legitimate status change AND, in the same payload,'
\echo '===   a new street address and acquisition cost.'
DELETE FROM ghl.review_queue;
INSERT INTO ghl.id_map (entity_type, local_id, ghl_id, ghl_object, location_id)
VALUES ('property','aaaaaaa1-0000-0000-0000-000000000001','ghl_rec_41','record','loc_test')
ON CONFLICT DO NOTHING;

INSERT INTO ghl.review_queue (source, event_type, ghl_object, ghl_id, summary, proposed)
VALUES ('webhook','RecordUpdate','record','ghl_rec_41',
        'A property record was edited in the CRM',
        '{"properties":{"status":"pending","list_price":"219000",
                        "street_address":"999 Attacker Way",
                        "acquisition_cost":"1"}}'::jsonb);

SELECT listing_ref, status, list_price, street_address, acquisition_cost
FROM core.property WHERE listing_ref = 'SDI-1041';

-- Capture the id up front. Passing a literal matters: if the non-admin cases
-- below read ghl.review_queue in a subquery, they fail on the schema grant and
-- never reach review_decide's own admin check -- proving nothing about it.
SELECT id AS rid FROM ghl.review_queue LIMIT 1
\gset

\echo
\echo '=== 1. ATTACK: an investor tries to decide. Expect: denied.'
BEGIN;
SET LOCAL ROLE sdi_investor;
SELECT set_config('app.actor_id','11111111-1111-1111-1111-111111111111',true);
SELECT api.review_decide(:rid, 'accepted');
ROLLBACK;

\echo
\echo '=== 2. ATTACK: an agent tries to decide. Expect: denied.'
BEGIN;
SET LOCAL ROLE sdi_agent;
SELECT set_config('app.actor_id','44444444-4444-4444-4444-444444444444',true);
SELECT api.review_decide(:rid, 'accepted');
ROLLBACK;

\echo
\echo '=== 3. ATTACK: an invalid decision value. Expect: denied.'
BEGIN;
SET LOCAL ROLE sdi_admin;
SELECT set_config('app.actor_id','77777777-7777-7777-7777-777777777777',true);
SELECT api.review_decide(:rid, 'approved');
ROLLBACK;

\echo
\echo '=== 4. Jessica (admin) accepts. Only allowlisted columns are applied.'
BEGIN;
SET LOCAL ROLE sdi_admin;
SELECT set_config('app.actor_id','77777777-7777-7777-7777-777777777777',true);
SELECT api.review_decide(:rid, 'accepted') AS result;
COMMIT;

\echo
\echo '=== 5. status and list_price moved. street_address and acquisition_cost'
\echo '===    did NOT: the allowlist held, though the payload asked for them.'
SELECT listing_ref, status, list_price, street_address, acquisition_cost
FROM core.property WHERE listing_ref = 'SDI-1041';

\echo
\echo '=== 6. The item is closed and attributed. Deciding it again fails.'
SELECT r.state, p.full_name AS decided_by, r.decided_at IS NOT NULL AS stamped
FROM ghl.review_queue r JOIN core.person p ON p.person_id = r.decided_by;

BEGIN;
SET LOCAL ROLE sdi_admin;
SELECT set_config('app.actor_id','77777777-7777-7777-7777-777777777777',true);
SELECT api.review_decide(:rid, 'rejected');
ROLLBACK;

\echo
\echo '=== 7. Standing invariants still hold.'
SELECT * FROM api.security_invariants();

\echo
\echo '=== Review action checks complete.'
