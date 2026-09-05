-- =====================================================================
-- 59_contract_tests.sql  |  does an approved contract open the right doors
-- =====================================================================
-- The assertions that matter are the NEGATIVE ones. A contract that
-- unlocks everything, or unlocks before it is paid, is worse than no
-- contract at all -- it looks like it is working.
\set ON_ERROR_STOP on
\pset pager off

BEGIN;

DO $$
DECLARE
  v_bev  uuid := '88888888-0000-0000-0000-000000000002';  -- has NOT signed
  v_dana uuid := '88888888-0000-0000-0000-000000000004';  -- has NOT signed
  v_on   uuid;    -- a property on Bev's approved contract
  v_off  uuid;    -- a property NOT on any approved contract of hers
  v_k    uuid;
  v_got  boolean;
  v_stage text;
BEGIN
  SELECT cp.property_id INTO v_on
    FROM core.contract k JOIN core.contract_property cp USING (contract_id)
   WHERE k.reference = 'SDI-C-1001' LIMIT 1;

  SELECT cp.property_id INTO v_off
    FROM core.contract k JOIN core.contract_property cp USING (contract_id)
   WHERE k.reference = 'SDI-C-1002' LIMIT 1;   -- signed, NOT paid

  -- ---- as Bev -------------------------------------------------------
  -- As the owner, with Bev as the ACTOR. sec.actor_role() reads the
  -- person row, so the predicates behave exactly as they would for her
  -- while this block can still read core to check its own work. Running
  -- it under SET ROLE sdi_investor would fail on core -- no application
  -- role holds USAGE there, which is the point.
  PERFORM set_config('app.actor_id', v_bev::text, true);

  v_got := sec.has_approved_contract(v_on);
  IF NOT v_got THEN
    RAISE EXCEPTION 'FAIL: an approved contract did not unlock its own property';
  END IF;

  v_got := sec.has_approved_contract(v_off);
  IF v_got THEN
    RAISE EXCEPTION 'FAIL: A SIGNED BUT UNPAID CONTRACT UNLOCKED A PROPERTY. '
                    'Payment is the second half of the gate.';
  END IF;

  -- Nothing else on the platform.
  IF EXISTS (
      SELECT 1 FROM core.property p
       WHERE p.property_id NOT IN (
               SELECT cp.property_id FROM core.contract k
                 JOIN core.contract_property cp USING (contract_id)
                WHERE k.person_id = v_bev AND k.status = 'approved')
         AND sec.has_approved_contract(p.property_id)) THEN
    RAISE EXCEPTION 'FAIL: A CONTRACT UNLOCKED A PROPERTY IT DOES NOT NAME.';
  END IF;

  -- ---- as Dana: her contract is sent, untouched ----------------------
  PERFORM set_config('app.actor_id', v_dana::text, true);
  IF EXISTS (SELECT 1 FROM core.property p WHERE sec.has_approved_contract(p.property_id)) THEN
    RAISE EXCEPTION 'FAIL: an unsigned, unpaid contract unlocked something';
  END IF;

  -- Dana's own contract is not Bev's to see, and vice versa.
  IF EXISTS (SELECT 1 FROM api.my_contracts() WHERE reference = 'SDI-C-1001') THEN
    RAISE EXCEPTION 'FAIL: a customer can see another customer''s contract';
  END IF;
  -- And a draft is not shown to the customer at all.
  IF EXISTS (SELECT 1 FROM api.my_contracts() WHERE reference = 'SDI-C-1004') THEN
    RAISE EXCEPTION 'FAIL: a draft contract was shown to the customer';
  END IF;

  RAISE NOTICE 'contract gate: approved unlocks only what it names; '
               'signed-but-unpaid unlocks nothing';
END $$;

-- ---------------------------------------------------------------------
-- The lifecycle: paying the second half approves it, and that is what
-- opens the property. Run as staff, then checked as the customer.
-- ---------------------------------------------------------------------
DO $$
DECLARE
  v_dana uuid := '88888888-0000-0000-0000-000000000004';
  v_jess uuid := '77777777-7777-7777-7777-777777777777';
  v_k    uuid;
  v_prop uuid;
  v_stage text;
BEGIN
  PERFORM set_config('app.actor_id', v_jess::text, true);

  SELECT k.contract_id, cp.property_id INTO v_k, v_prop
    FROM core.contract k JOIN core.contract_property cp USING (contract_id)
   WHERE k.reference = 'SDI-C-1003' LIMIT 1;

  -- Before: locked for Dana.
  PERFORM set_config('app.actor_id', v_dana::text, true);
  IF sec.has_approved_contract(v_prop) THEN
    RAISE EXCEPTION 'FAIL: locked property was already open';
  END IF;

  -- Dana signs. Still not approved -- she has not paid.
  v_stage := api.sign_contract(v_k);
  IF v_stage <> 'awaiting payment' THEN
    RAISE EXCEPTION 'FAIL: after signing, stage was % (expected awaiting payment)', v_stage;
  END IF;
  IF sec.has_approved_contract(v_prop) THEN
    RAISE EXCEPTION 'FAIL: SIGNING ALONE OPENED THE PROPERTY. The fee is the other half.';
  END IF;

  -- She pays. That is the second fact, so it approves.
  v_stage := api.record_payment(v_k, 'ch_test_0001');
  IF v_stage <> 'approved' THEN
    RAISE EXCEPTION 'FAIL: after paying, stage was % (expected approved)', v_stage;
  END IF;
  IF NOT sec.has_approved_contract(v_prop) THEN
    RAISE EXCEPTION 'FAIL: a signed and paid contract did not open its property';
  END IF;
  IF NOT sec.can_see_address(v_prop) THEN
    RAISE EXCEPTION 'FAIL: the address gate did not follow the contract';
  END IF;

  RAISE NOTICE 'lifecycle: sign -> awaiting payment -> pay -> approved -> address open';
END $$;

-- ---------------------------------------------------------------------
-- The things that must be refused.
-- ---------------------------------------------------------------------
DO $$
DECLARE
  v_jess uuid := '77777777-7777-7777-7777-777777777777';
  v_bev  uuid := '88888888-0000-0000-0000-000000000002';
  v_k uuid; v_p uuid; v_ok boolean;
BEGIN
  PERFORM set_config('app.actor_id', v_jess::text, true);

  SELECT contract_id INTO v_k FROM core.contract WHERE reference = 'SDI-C-1001';
  SELECT property_id INTO v_p FROM core.property
   WHERE property_id NOT IN (SELECT property_id FROM core.contract_property
                              WHERE contract_id = v_k) LIMIT 1;

  -- Adding a property to an APPROVED contract would unlock it with no
  -- signature and no payment behind it.
  v_ok := false;
  BEGIN
    PERFORM api.add_contract_property(v_k, v_p);
    v_ok := true;
  EXCEPTION WHEN others THEN NULL;
  END;
  IF v_ok THEN
    RAISE EXCEPTION 'FAIL: A PROPERTY WAS ADDED TO AN APPROVED CONTRACT. '
                    'That unlocks it without anybody agreeing to it.';
  END IF;

  -- A contract with no properties unlocks nothing and must not be sent.
  INSERT INTO core.contract (reference, person_id, fee_amount, status)
  VALUES ('SDI-C-TEST1', v_bev, 750, 'draft') RETURNING contract_id INTO v_k;
  v_ok := false;
  BEGIN
    PERFORM api.send_contract(v_k);
    v_ok := true;
  EXCEPTION WHEN others THEN NULL;
  END;
  IF v_ok THEN
    RAISE EXCEPTION 'FAIL: an empty contract was sent';
  END IF;

  -- An approved row without both facts must be unrepresentable, even
  -- from a psql prompt with every privilege.
  v_ok := false;
  BEGIN
    UPDATE core.contract SET status = 'approved', approved_at = now()
     WHERE reference = 'SDI-C-TEST1';
    v_ok := true;
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  IF v_ok THEN
    RAISE EXCEPTION 'FAIL: A CONTRACT WAS APPROVED WITHOUT A SIGNATURE OR A '
                    'PAYMENT. The constraint is what makes the gate a gate.';
  END IF;

  RAISE NOTICE 'refusals: no adding to an approved contract, no empty send, '
               'no approval without both facts';
END $$;

ROLLBACK;
