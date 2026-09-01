-- =====================================================================
-- 07_ghl_tests.sql  |  GHL bridge checks
-- Run after 06. Verifies the fee gate opens band 2 end to end, and that
-- the CRM schema is unreachable from the web personas.
-- =====================================================================
\pset border 2
\set QUIET on
\set ON_ERROR_STOP off

\echo
\echo '=== 1. Marcus has not signed. Address withheld (baseline).'
BEGIN;
SET LOCAL ROLE sdi_investor;
SELECT set_config('app.actor_id','22222222-2222-2222-2222-222222222222',true);
SELECT listing_ref, street_address, address_unlocked
FROM api.property ORDER BY listing_ref LIMIT 2;
COMMIT;

\echo
\echo '=== 2. GHL reports the document completed but NOT paid.'
\echo '===    Expect apply_fee_agreement = false, address still withheld.'
INSERT INTO ghl.fee_agreement
  (document_id, location_id, person_id, ghl_contact_id, status,
   payment_status, grand_total, ghl_updated_at, raw)
VALUES
  ('doc_marcus_1','loc_test','22222222-2222-2222-2222-222222222222','ghl_c_marcus',
   'completed','waiting_for_payment', 750.00, now(), '{}'::jsonb);

SELECT ghl.apply_fee_agreement('doc_marcus_1') AS unlocked_on_unpaid;

BEGIN;
SET LOCAL ROLE sdi_investor;
SELECT set_config('app.actor_id','22222222-2222-2222-2222-222222222222',true);
SELECT listing_ref, street_address, address_unlocked
FROM api.property ORDER BY listing_ref LIMIT 2;
COMMIT;

\echo
\echo '=== 3. Payment settles. Expect true, and band 2 opens.'
UPDATE ghl.fee_agreement SET payment_status='paid', ghl_updated_at=now()
 WHERE document_id='doc_marcus_1';

SELECT ghl.apply_fee_agreement('doc_marcus_1') AS unlocked_on_paid;

BEGIN;
SET LOCAL ROLE sdi_investor;
SELECT set_config('app.actor_id','22222222-2222-2222-2222-222222222222',true);
SELECT listing_ref, street_address, address_unlocked
FROM api.property ORDER BY listing_ref LIMIT 2;
COMMIT;

\echo
\echo '=== 4. Idempotency: re-applying must not move the timestamp.'
SELECT fee_agreement_signed_at AS before_replay FROM core.person
 WHERE person_id='22222222-2222-2222-2222-222222222222';
SELECT ghl.apply_fee_agreement('doc_marcus_1') AS replayed;
SELECT fee_agreement_signed_at AS after_replay FROM core.person
 WHERE person_id='22222222-2222-2222-2222-222222222222';

\echo
\echo '=== 5. ATTACK: web persona reads the CRM schema. Expect denied.'
BEGIN;
SET LOCAL ROLE sdi_investor;
SELECT count(*) FROM ghl.transaction;
ROLLBACK;

\echo
\echo '=== 6. ATTACK: web persona opens its own gate. Expect denied.'
BEGIN;
SET LOCAL ROLE sdi_investor;
UPDATE core.person SET fee_agreement_signed_at = now();
ROLLBACK;

\echo
\echo '=== 7. Standing invariants still hold after adding the ghl schema.'
SELECT * FROM api.security_invariants();

-- Shut Marcus's gate again. Check 3 has to COMMIT to show the unlock
-- persisting, so it cannot roll back -- but leaving him unlocked destroys
-- the demo's central comparison, where he and Ruth differ by exactly one
-- settled agreement.
UPDATE core.person SET fee_agreement_signed_at = NULL
 WHERE email = 'marcus@example.com';
DELETE FROM ghl.fee_agreement WHERE document_id = 'doc_marcus_1';
DELETE FROM ghl.id_map WHERE ghl_id = 'ghl_c_marcus';

\echo
\echo '=== GHL bridge checks complete.'
