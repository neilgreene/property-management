-- =====================================================================
-- 62_contract_gate.sql  |  a contract is the only way a customer gets in
-- =====================================================================
-- AN AND GATE, NOT AN OR GATE.
--
-- A customer signs a contract AND pays its fee. Both, and only then, the
-- properties named on that contract open for them. The AND is enforced on
-- the table -- `contract_approved_needs_both` -- so `status = 'approved'`
-- cannot mean anything else, and sec.has_approved_contract() only has to
-- ask about status.
--
-- What comes out is the blanket clause. Until now a customer who had
-- signed the platform-wide fee agreement saw EVERY address on the site,
-- one signature for the lot, sitting as an OR beside the contract rule.
-- That gave the system two different meanings of "signed" -- a flag on the
-- person, and a signature on a contract -- which is confusing in exactly
-- the way that matters: it is hard to answer "why can this person see
-- this address" without checking both.
--
-- core.person.fee_agreement_signed_at STAYS. It is still a true record of
-- something that happened and api.property_interest still reports it. It
-- simply no longer opens anything by itself.
--
-- The two remaining clauses are not customer paths and are unchanged:
-- internal staff, and the agent or lender assigned to a property.

BEGIN;

CREATE OR REPLACE FUNCTION sec.can_see_address(p_property_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $$
  SELECT sec.is_internal()
      OR sec.is_assigned(p_property_id)
      OR sec.has_approved_contract(p_property_id);
$$;

-- ---------------------------------------------------------------------
-- The investors who used to be let in by the flag now need contracts, or
-- the demo shows four people who can suddenly see nothing.
-- ---------------------------------------------------------------------
DO $$
DECLARE
  v_p uuid[];
  v_k uuid;
  r record;
  i  int;
BEGIN
  SELECT array_agg(property_id ORDER BY listing_ref) INTO v_p
    FROM (SELECT property_id, listing_ref FROM core.property
           WHERE status = 'active' ORDER BY listing_ref LIMIT 12) t;
  IF v_p IS NULL OR array_length(v_p, 1) < 12 THEN
    RAISE NOTICE 'not enough active properties; skipping the contract backfill';
    RETURN;
  END IF;

  -- Ruth first and widest: she is the worked example in the documentation
  -- and every walkthrough opens with her seeing an address.
  FOR r IN
    SELECT * FROM (VALUES
      ('11111111-1111-1111-1111-111111111111'::uuid, 'SDI-C-1010', 1, 4),
      ('33333333-3333-3333-3333-333333333333'::uuid, 'SDI-C-1011', 5, 6),
      ('88888888-0000-0000-0000-000000000001'::uuid, 'SDI-C-1012', 7, 8),
      ('88888888-0000-0000-0000-000000000003'::uuid, 'SDI-C-1013', 9, 9)
    ) AS t(person_id, reference, lo, hi)
  LOOP
    INSERT INTO core.contract (reference, person_id, fee_amount, status,
                               sent_at, signed_at, paid_at, approved_at,
                               payment_ref, notes)
    VALUES (r.reference, r.person_id, 750.00, 'approved',
            now() - interval '30 days', now() - interval '28 days',
            now() - interval '28 days', now() - interval '28 days',
            'ch_backfill_' || r.reference,
            'Signed and paid.')
    ON CONFLICT (reference) DO NOTHING
    RETURNING contract_id INTO v_k;

    IF v_k IS NOT NULL THEN
      FOR i IN r.lo..r.hi LOOP
        INSERT INTO core.contract_property (contract_id, property_id)
        VALUES (v_k, v_p[i]) ON CONFLICT DO NOTHING;
      END LOOP;
      INSERT INTO core.contract_history (contract_id, event, to_status, detail)
      VALUES (v_k, 'created', 'draft', NULL),
             (v_k, 'sent',    'sent',  NULL),
             (v_k, 'signed',  NULL,    NULL),
             (v_k, 'paid',    NULL,    'ch_backfill_' || r.reference),
             (v_k, 'approved','approved', 'signed and paid');
    END IF;
  END LOOP;

  -- And one that is signed but NOT paid, so the demo carries a property
  -- that is agreed and still shut. That is the state the whole AND exists
  -- to describe, and without an example of it nobody sees the difference.
  INSERT INTO core.contract (reference, person_id, fee_amount, status,
                             sent_at, signed_at, notes)
  VALUES ('SDI-C-1014', '88888888-0000-0000-0000-000000000003', 750.00, 'sent',
          now() - interval '4 days', now() - interval '2 days',
          'Signed. The fee has not arrived, so this one is still shut.')
  ON CONFLICT (reference) DO NOTHING
  RETURNING contract_id INTO v_k;
  IF v_k IS NOT NULL THEN
    INSERT INTO core.contract_property (contract_id, property_id)
    VALUES (v_k, v_p[10]) ON CONFLICT DO NOTHING;
    INSERT INTO core.contract_history (contract_id, event, to_status)
    VALUES (v_k, 'created', 'draft'), (v_k, 'sent', 'sent'), (v_k, 'signed', NULL);
  END IF;
END $$;

COMMIT;
