-- =====================================================================
-- 05_tests.sql  |  Walkthrough. Run: psql -d sdi -f sql/05_tests.sql
-- =====================================================================
\pset border 2
\set ON_ERROR_ROLLBACK on
\set ON_ERROR_STOP off
\set QUIET on

\echo ''
\echo '=== 1. Anonymous visitor. SELECT with no WHERE clause.'
\echo '===    Expect 5 rows: draft/pending/sold drop out by policy, not by app code.'
RESET ROLE; SET ROLE sdi_public;
BEGIN;
SELECT set_config('app.actor_id','',true), set_config('app.brand','BRAND_A',true) \g /dev/null
SELECT listing_ref, status, city, list_price, cap_rate, street_address, lat
FROM api.property ORDER BY listing_ref;

\echo ''
\echo '=== 2. Investor with no approved contract (Marcus).'
\echo '===    Same SQL. Address withheld, coordinates fuzzed. 6 rows (pending visible).'
COMMIT;
RESET ROLE; SET ROLE sdi_investor;
BEGIN;
SELECT set_config('app.actor_id','22222222-2222-2222-2222-222222222222',true),
       set_config('app.brand','BRAND_A',true) \g /dev/null
SELECT listing_ref, status, street_address, lat, lng, address_unlocked
FROM api.property ORDER BY listing_ref;

\echo ''
\echo '=== 3. Same role, same query, an APPROVED CONTRACT (Ruth).'
\echo '===    Address and true coordinates appear -- for the properties her
\echo '===    contract names, and no others. Zero application logic involved.''
COMMIT;
RESET ROLE; SET ROLE sdi_investor;
BEGIN;
SELECT set_config('app.actor_id','11111111-1111-1111-1111-111111111111',true),
       set_config('app.brand','BRAND_A',true) \g /dev/null
SELECT listing_ref, status, street_address, lat, lng, address_unlocked
FROM api.property ORDER BY listing_ref;

\echo ''
\echo '=== 4. Agent Tom. Only his 4 assigned properties, including the unpublished'
\echo '===    draft. Address unlocked by assignment, not by a contract.'
COMMIT;
RESET ROLE; SET ROLE sdi_agent;
BEGIN;
SELECT set_config('app.actor_id','44444444-4444-4444-4444-444444444444',true),
       set_config('app.brand','BRAND_A',true) \g /dev/null
SELECT listing_ref, status, street_address, address_unlocked
FROM api.property ORDER BY listing_ref;

\echo ''
\echo '=== 4b. Agent tries to read the internal band. Expect: permission denied.'
SELECT acquisition_cost FROM api.property_internal LIMIT 1;

\echo ''
\echo '=== 5. Admin. All 8 rows plus the internal band and derived margin.'
COMMIT;
RESET ROLE; SET ROLE sdi_admin;
BEGIN;
SELECT set_config('app.actor_id','66666666-6666-6666-6666-666666666666',true),
       set_config('app.brand','BRAND_A',true) \g /dev/null
SELECT p.listing_ref, p.status, p.street_address,
       i.acquisition_cost, i.gross_margin, left(i.internal_notes,34) AS notes
FROM api.property p JOIN api.property_internal i USING (property_id)
ORDER BY p.listing_ref;

\echo ''
\echo '=== 6. Dual brand. Identical query, brand switched to KAVADOO.'
\echo '===    3 rows, concierge pricing, 2500 fee. Same underlying rows as BRAND_A.'
COMMIT;
RESET ROLE; SET ROLE sdi_public;
BEGIN;
SELECT set_config('app.actor_id','',true), set_config('app.brand','KAVADOO',true) \g /dev/null
SELECT listing_ref, city, list_price, brand_service_tier, brand_platform_fee
FROM api.property ORDER BY listing_ref;

\echo ''
\echo '=== 7. ATTACK: bypass the view, hit the base table directly.'
\echo '===    Expect: permission denied for schema core.'
COMMIT;
RESET ROLE; SET ROLE sdi_investor;
BEGIN;
SELECT set_config('app.actor_id','22222222-2222-2222-2222-222222222222',true) \g /dev/null
SELECT street_address FROM core.property LIMIT 1;
ROLLBACK; BEGIN;
SELECT set_config('app.actor_id','22222222-2222-2222-2222-222222222222',true), set_config('app.brand','BRAND_A',true) \g /dev/null

\echo ''
\echo '=== 8. ATTACK: read another investor''s saved list.'
\echo '===    Marcus expects 0. Ruth expects 2. Same query, same role.'
SELECT set_config('app.actor_id','22222222-2222-2222-2222-222222222222',true) \g /dev/null
SELECT 'marcus' AS who, count(*) FROM api.my_saved;
COMMIT; BEGIN;
SELECT set_config('app.actor_id','11111111-1111-1111-1111-111111111111',true) \g /dev/null
SELECT 'ruth' AS who, count(*) FROM api.my_saved;

\echo ''
\echo '=== 9. ATTACK: save a property the caller cannot see (the draft).'
\echo '===    Expect: property not visible to this session.'
SELECT api.save_property('aaaaaaa1-0000-0000-0000-000000000007');
ROLLBACK; BEGIN;
SELECT set_config('app.actor_id','22222222-2222-2222-2222-222222222222',true), set_config('app.brand','BRAND_A',true) \g /dev/null

\echo ''
\echo '=== 9b. Legitimate save of a visible property. Expect: true.'
SELECT api.save_property('aaaaaaa1-0000-0000-0000-000000000002');

\echo ''
\echo '=== 10. ATTACK: side-channel via a cheap VOLATILE predicate.'
\echo '===     Without security_barrier the planner runs leak() before the RLS'
\echo '===     filter and prints rows the caller cannot select.'
\echo '===     Expect: NOTICE lines only for the 5 rows already visible.'
COMMIT;
RESET ROLE;
CREATE OR REPLACE FUNCTION public.leak(t text) RETURNS boolean
LANGUAGE plpgsql VOLATILE COST 1 AS $$
BEGIN RAISE NOTICE 'saw ==> %', coalesce(t,'(masked)'); RETURN true; END $$;
GRANT EXECUTE ON FUNCTION public.leak(text) TO sdi_public;
SET ROLE sdi_public;
BEGIN;
SELECT set_config('app.actor_id','',true), set_config('app.brand','BRAND_A',true) \g /dev/null
SELECT count(*) AS rows_seen FROM api.property WHERE public.leak(street_address);
COMMIT;

\echo ''
\echo '=== 11. Standing security invariants. Expect: zero rows.'
COMMIT;
RESET ROLE; SET ROLE sdi_admin;
BEGIN;
SELECT set_config('app.actor_id','66666666-6666-6666-6666-666666666666',true) \g /dev/null
SELECT * FROM api.security_invariants();
COMMIT;

COMMIT;
RESET ROLE;
\echo ''
\echo '=== Walkthrough complete.'
