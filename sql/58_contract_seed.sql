-- =====================================================================
-- 58_contract_seed.sql  |  mock agents, customers, opportunities, contracts
-- =====================================================================
-- Stands in for what GoHighLevel will supply. Deliberately a mixed bag:
-- a contract at every stage, so the panels have something to show and the
-- gate can be watched behaving differently either side of approval.
--
-- The customers used here are Bev and Dana, who have NOT signed the
-- platform fee agreement. That is on purpose: with the blanket unlock
-- still in place, using a signed investor would prove nothing -- they can
-- already see every address, and a contract would change nothing you
-- could observe.

BEGIN;

-- Agent detail for the two seeded agents. metro_code is the FEE SCHEDULE
-- vocabulary (STL, KC-SH, ...), not a list of cities -- a property in
-- Cleveland is priced under whichever programme applies, and the two
-- vocabularies do not line up one to one.
INSERT INTO core.agent_profile (person_id, licence_no, brokerage, metro_code, notes)
VALUES
  ('44444444-4444-4444-4444-444444444444', 'OH-2291043', 'Bradbury Realty',
   'STL', 'Midwest. Fee schedule follows the STL programme.'),
  ('55555555-5555-5555-5555-555555555555', 'IN-8830112', 'Raman Property Group',
   'KC-SH', 'Kansas City, on the SH schedule.')
ON CONFLICT (person_id) DO NOTHING;

-- Customers, with an agent looking after each.
INSERT INTO core.customer_profile (person_id, agent_id, target_metro,
                                   budget_low, budget_high, notes)
VALUES
  ('88888888-0000-0000-0000-000000000001',
   '44444444-4444-4444-4444-444444444444', 'STL', 80000, 250000,
   'Cash buyer, wants turnkey.'),
  ('88888888-0000-0000-0000-000000000002',
   '44444444-4444-4444-4444-444444444444', 'STL', 60000, 150000,
   'First purchase. Financing.'),
  ('88888888-0000-0000-0000-000000000003',
   '55555555-5555-5555-5555-555555555555', 'KC-SH', 100000, 400000,
   'Building a portfolio, wants three this year.'),
  ('88888888-0000-0000-0000-000000000004',
   '55555555-5555-5555-5555-555555555555', 'KC-SH', 150000, 500000,
   'Section 8 focus.')
ON CONFLICT (person_id) DO NOTHING;

DO $$
DECLARE
  v_bev  uuid := '88888888-0000-0000-0000-000000000002';
  v_dana uuid := '88888888-0000-0000-0000-000000000004';
  v_tom  uuid := '44444444-4444-4444-4444-444444444444';
  v_pri  uuid := '55555555-5555-5555-5555-555555555555';
  v_opp  uuid;
  v_k    uuid;
  v_p    uuid[];
BEGIN
  -- Four properties to work with, whichever ones this database has.
  SELECT array_agg(property_id ORDER BY listing_ref)
    INTO v_p
    FROM (SELECT property_id, listing_ref FROM core.property
           WHERE status = 'active' ORDER BY listing_ref LIMIT 4) t;
  IF v_p IS NULL OR array_length(v_p, 1) < 4 THEN
    RAISE NOTICE 'fewer than four active properties; skipping contract seed';
    RETURN;
  END IF;

  -- ---- Bev: an opportunity of three, a contract APPROVED on two -------
  INSERT INTO core.opportunity (opportunity_id, person_id, agent_id, title, notes)
  VALUES (gen_random_uuid(), v_bev, v_tom, 'Bev — Cleveland starter pair',
          'Two to begin with, a third if the numbers hold.')
  RETURNING opportunity_id INTO v_opp;
  INSERT INTO core.opportunity_property (opportunity_id, property_id)
  VALUES (v_opp, v_p[1]), (v_opp, v_p[2]), (v_opp, v_p[3]);

  INSERT INTO core.contract (reference, person_id, opportunity_id, fee_amount,
                             status, sent_at, signed_at, paid_at, approved_at,
                             payment_ref, notes)
  VALUES ('SDI-C-1001', v_bev, v_opp, 750.00, 'approved',
          now() - interval '9 days', now() - interval '7 days',
          now() - interval '6 days', now() - interval '6 days',
          'ch_mock_1001', 'Signed and paid. Two properties released.')
  RETURNING contract_id INTO v_k;
  INSERT INTO core.contract_property (contract_id, property_id)
  VALUES (v_k, v_p[1]), (v_k, v_p[2]);
  INSERT INTO core.contract_history (contract_id, event, to_status, detail)
  VALUES (v_k, 'created', 'draft', NULL),
         (v_k, 'sent', 'sent', NULL),
         (v_k, 'signed', NULL, NULL),
         (v_k, 'paid', NULL, 'ch_mock_1001'),
         (v_k, 'approved', 'approved', 'signed and paid');

  -- ---- Bev again: a second contract, signed but NOT paid -------------
  -- The one that shows payment is the thing that opens the door.
  INSERT INTO core.contract (reference, person_id, opportunity_id, fee_amount,
                             status, sent_at, signed_at, notes)
  VALUES ('SDI-C-1002', v_bev, v_opp, 750.00, 'sent',
          now() - interval '3 days', now() - interval '2 days',
          'Signed. Awaiting the fee.')
  RETURNING contract_id INTO v_k;
  INSERT INTO core.contract_property (contract_id, property_id) VALUES (v_k, v_p[3]);
  INSERT INTO core.contract_history (contract_id, event, to_status)
  VALUES (v_k, 'created', 'draft'), (v_k, 'sent', 'sent'), (v_k, 'signed', NULL);

  -- ---- Dana: sent, neither signed nor paid ---------------------------
  INSERT INTO core.opportunity (opportunity_id, person_id, agent_id, title, notes)
  VALUES (gen_random_uuid(), v_dana, v_pri, 'Dana — Indianapolis section 8', NULL)
  RETURNING opportunity_id INTO v_opp;
  INSERT INTO core.opportunity_property (opportunity_id, property_id)
  VALUES (v_opp, v_p[4]);

  INSERT INTO core.contract (reference, person_id, opportunity_id, fee_amount,
                             status, sent_at, notes)
  VALUES ('SDI-C-1003', v_dana, v_opp, 750.00, 'sent',
          now() - interval '1 day', 'Sent. Nothing back yet.')
  RETURNING contract_id INTO v_k;
  INSERT INTO core.contract_property (contract_id, property_id) VALUES (v_k, v_p[4]);
  INSERT INTO core.contract_history (contract_id, event, to_status)
  VALUES (v_k, 'created', 'draft'), (v_k, 'sent', 'sent');

  -- ---- Dana: a draft, not yet sent -----------------------------------
  INSERT INTO core.contract (reference, person_id, fee_amount, status, notes)
  VALUES ('SDI-C-1004', v_dana, 750.00, 'draft', 'Being prepared.')
  RETURNING contract_id INTO v_k;
  INSERT INTO core.contract_property (contract_id, property_id) VALUES (v_k, v_p[1]);
  INSERT INTO core.contract_history (contract_id, event, to_status)
  VALUES (v_k, 'created', 'draft');
END $$;

COMMIT;
