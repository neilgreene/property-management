-- =====================================================================
-- 57_contract_actions.sql  |  the contract lifecycle
-- =====================================================================
-- A contract is created against a customer, given one or more properties,
-- and sent. The customer signs it and pays the fee. WHICHEVER OF THOSE
-- TWO HAPPENS SECOND approves it, and approval is what opens the address
-- and the photographs for the properties named on it.
--
-- There is deliberately NO api.approve_contract(). Approval is not a
-- decision anybody makes; it is what a signature and a payment add up to.
-- A gate an administrator can open by choosing a value from a dropdown is
-- not a gate, and the CHECK constraints in 55 make such a row impossible
-- to write in any case.

BEGIN;

-- What a contract is waiting for, derived rather than stored. A stored
-- copy is a second answer that drifts the first time somebody updates one
-- column and not the other.
CREATE FUNCTION core.contract_stage(p_status text, p_sent timestamptz,
                                    p_signed timestamptz, p_paid timestamptz)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT CASE
    WHEN p_status = 'approved'  THEN 'approved'
    WHEN p_status = 'declined'  THEN 'declined'
    WHEN p_status = 'withdrawn' THEN 'withdrawn'
    WHEN p_sent IS NULL         THEN 'draft'
    WHEN p_signed IS NULL AND p_paid IS NULL THEN 'awaiting signature and payment'
    WHEN p_signed IS NULL       THEN 'awaiting signature'
    WHEN p_paid IS NULL         THEN 'awaiting payment'
    ELSE 'approved'
  END;
$$;

CREATE FUNCTION api.contracts(p_person_id uuid DEFAULT NULL)
RETURNS TABLE (contract_id uuid, reference text, status text, stage text,
               person_id uuid, customer_name text,
               opportunity_id uuid, opportunity_title text,
               property_count bigint, fee_amount numeric,
               sent_at timestamptz, signed_at timestamptz, paid_at timestamptz,
               approved_at timestamptz, notes text, external_ref text,
               created_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $$
  SELECT k.contract_id, k.reference, k.status,
         core.contract_stage(k.status, k.sent_at, k.signed_at, k.paid_at),
         k.person_id, cu.full_name,
         k.opportunity_id, o.title,
         (SELECT count(*) FROM core.contract_property cp
           WHERE cp.contract_id = k.contract_id),
         k.fee_amount, k.sent_at, k.signed_at, k.paid_at, k.approved_at,
         k.notes, k.external_ref, k.created_at
    FROM core.contract k
    JOIN core.person cu ON cu.person_id = k.person_id
    LEFT JOIN core.opportunity o ON o.opportunity_id = k.opportunity_id
   WHERE sec.is_internal()
     AND (p_person_id IS NULL OR k.person_id = p_person_id)
   ORDER BY k.created_at DESC;
$$;

-- The customer's own view of their contracts. Not gated on is_internal(),
-- because the whole point is that they can see it -- gated on it being
-- theirs, which is a different question with a different answer.
CREATE FUNCTION api.my_contracts()
RETURNS TABLE (contract_id uuid, reference text, status text, stage text,
               property_count bigint, fee_amount numeric,
               sent_at timestamptz, signed_at timestamptz, paid_at timestamptz,
               approved_at timestamptz, notes text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $$
  SELECT k.contract_id, k.reference, k.status,
         core.contract_stage(k.status, k.sent_at, k.signed_at, k.paid_at),
         (SELECT count(*) FROM core.contract_property cp
           WHERE cp.contract_id = k.contract_id),
         k.fee_amount, k.sent_at, k.signed_at, k.paid_at, k.approved_at, k.notes
    FROM core.contract k
   WHERE k.person_id = sec.actor_id()
     AND k.status <> 'draft'          -- a draft has not been sent to them
   ORDER BY k.created_at DESC;
$$;

CREATE FUNCTION api.contract_properties(p_contract_id uuid)
RETURNS TABLE (property_id uuid, listing_ref text, city text, state text,
               list_price numeric, added_at timestamptz, unlocked boolean)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $$
  SELECT p.property_id, p.listing_ref, p.city, p.state, p.list_price,
         cp.added_at, k.status = 'approved'
    FROM core.contract_property cp
    JOIN core.contract k ON k.contract_id = cp.contract_id
    JOIN core.property p ON p.property_id = cp.property_id
   WHERE cp.contract_id = p_contract_id
     AND sec.may_touch_contract(p_contract_id)
   ORDER BY p.listing_ref;
$$;

-- ---------------------------------------------------------------------
-- Creating and filling one
-- ---------------------------------------------------------------------
CREATE FUNCTION api.create_contract(p_person_id uuid, p_fee_amount numeric,
                                    p_opportunity_id uuid DEFAULT NULL,
                                    p_notes text DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $$
DECLARE v_id uuid; v_ref text;
BEGIN
  IF NOT sec.is_internal() THEN
    RAISE EXCEPTION 'staff only';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM core.person
                  WHERE person_id = p_person_id AND role = 'investor') THEN
    RAISE EXCEPTION 'contracts are held by customers';
  END IF;

  -- A human reference, because nobody reads a uuid down a telephone.
  v_ref := 'SDI-C-' || lpad(
    (COALESCE((SELECT max(substring(reference from 7)::int)
                 FROM core.contract
                WHERE reference ~ '^SDI-C-[0-9]+$'), 1000) + 1)::text, 4, '0');

  INSERT INTO core.contract (reference, person_id, opportunity_id,
                             fee_amount, notes, created_by)
  VALUES (v_ref, p_person_id, p_opportunity_id, p_fee_amount, p_notes,
          sec.actor_id())
  RETURNING contract_id INTO v_id;

  INSERT INTO core.contract_history (contract_id, event, to_status, changed_by)
  VALUES (v_id, 'created', 'draft', sec.actor_id());
  RETURN v_id;
END $$;

CREATE FUNCTION api.add_contract_property(p_contract_id uuid, p_property_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $$
DECLARE v_status text;
BEGIN
  IF NOT sec.is_internal() THEN
    RAISE EXCEPTION 'staff only';
  END IF;
  SELECT status INTO v_status FROM core.contract WHERE contract_id = p_contract_id;
  IF v_status IS NULL THEN
    RAISE EXCEPTION 'no such contract';
  END IF;
  -- ADDING A PROPERTY TO AN APPROVED CONTRACT WOULD UNLOCK IT SILENTLY,
  -- with no signature and no payment covering it. The customer agreed to
  -- a set of properties; this would change the set after the fact.
  IF v_status = 'approved' THEN
    RAISE EXCEPTION 'this contract is approved -- raise a new one rather than '
                    'adding a property the customer has not agreed to';
  END IF;
  IF v_status IN ('declined','withdrawn') THEN
    RAISE EXCEPTION 'this contract is %', v_status;
  END IF;

  INSERT INTO core.contract_property (contract_id, property_id)
  VALUES (p_contract_id, p_property_id)
  ON CONFLICT DO NOTHING;

  INSERT INTO core.contract_history (contract_id, event, changed_by, detail)
  VALUES (p_contract_id, 'property_added', sec.actor_id(),
          (SELECT listing_ref FROM core.property WHERE property_id = p_property_id));
END $$;

CREATE FUNCTION api.remove_contract_property(p_contract_id uuid, p_property_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $$
DECLARE v_status text;
BEGIN
  IF NOT sec.is_internal() THEN
    RAISE EXCEPTION 'staff only';
  END IF;
  SELECT status INTO v_status FROM core.contract WHERE contract_id = p_contract_id;
  IF v_status = 'approved' THEN
    RAISE EXCEPTION 'this contract is approved -- withdraw it rather than '
                    'removing a property from what was agreed';
  END IF;
  DELETE FROM core.contract_property
   WHERE contract_id = p_contract_id AND property_id = p_property_id;
  INSERT INTO core.contract_history (contract_id, event, changed_by, detail)
  VALUES (p_contract_id, 'property_removed', sec.actor_id(),
          (SELECT listing_ref FROM core.property WHERE property_id = p_property_id));
END $$;

-- ---------------------------------------------------------------------
-- Moving it
-- ---------------------------------------------------------------------
CREATE FUNCTION api.send_contract(p_contract_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $$
DECLARE v_status text; v_n int;
BEGIN
  IF NOT sec.is_internal() THEN
    RAISE EXCEPTION 'staff only';
  END IF;
  SELECT status INTO v_status FROM core.contract WHERE contract_id = p_contract_id;
  IF v_status IS DISTINCT FROM 'draft' THEN
    RAISE EXCEPTION 'only a draft can be sent (this one is %)', COALESCE(v_status, 'missing');
  END IF;
  SELECT count(*) INTO v_n FROM core.contract_property WHERE contract_id = p_contract_id;
  IF v_n = 0 THEN
    RAISE EXCEPTION 'a contract with no properties unlocks nothing -- add at least one';
  END IF;

  UPDATE core.contract SET status = 'sent', sent_at = now()
   WHERE contract_id = p_contract_id;
  INSERT INTO core.contract_history (contract_id, event, from_status, to_status, changed_by)
  VALUES (p_contract_id, 'sent', 'draft', 'sent', sec.actor_id());
END $$;

-- The two that matter. Each does its own half AND the approval, in a
-- SINGLE statement.
--
-- Not for elegance. `contract_both_means_approved` says a row cannot be
-- signed and paid while still sitting in 'sent'. Written as two
-- statements -- set paid_at, then set status -- the row passes through
-- exactly that state between them, and a CHECK constraint is evaluated
-- per statement, not at commit. It failed immediately, which is the
-- constraint doing its job: the intermediate state was one I had declared
-- impossible, so the answer is to stop creating it rather than to weaken
-- what the table promises. Postgres cannot defer a CHECK, and a
-- deferrable one would only move the same problem to commit time.

CREATE FUNCTION api.sign_contract(p_contract_id uuid)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $$
DECLARE v_status text; v_sent timestamptz; v_approved boolean;
BEGIN
  IF NOT sec.may_touch_contract(p_contract_id) THEN
    RAISE EXCEPTION 'not your contract';
  END IF;
  SELECT status, sent_at INTO v_status, v_sent
    FROM core.contract WHERE contract_id = p_contract_id;
  IF v_status IS NULL THEN RAISE EXCEPTION 'no such contract'; END IF;
  IF v_sent IS NULL THEN
    RAISE EXCEPTION 'this contract has not been sent yet';
  END IF;
  IF v_status IN ('declined','withdrawn') THEN
    RAISE EXCEPTION 'this contract is %', v_status;
  END IF;

  -- Signs, and approves in the same statement when the fee is already
  -- paid -- so the signed-and-paid-but-not-approved row never exists.
  UPDATE core.contract
     SET signed_at   = COALESCE(signed_at, now()),
         status      = CASE WHEN paid_at IS NOT NULL THEN 'approved' ELSE status END,
         approved_at = CASE WHEN paid_at IS NOT NULL
                            THEN COALESCE(approved_at, now()) ELSE approved_at END
   WHERE contract_id = p_contract_id
   RETURNING (status = 'approved' AND v_status <> 'approved') INTO v_approved;

  INSERT INTO core.contract_history (contract_id, event, changed_by)
  VALUES (p_contract_id, 'signed', sec.actor_id());
  IF v_approved THEN
    INSERT INTO core.contract_history (contract_id, event, from_status,
                                       to_status, changed_by, detail)
    VALUES (p_contract_id, 'approved', v_status, 'approved', sec.actor_id(),
            'signed and paid');
  END IF;

  RETURN (SELECT core.contract_stage(status, sent_at, signed_at, paid_at)
            FROM core.contract WHERE contract_id = p_contract_id);
END $$;

CREATE FUNCTION api.record_payment(p_contract_id uuid, p_payment_ref text DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $$
DECLARE v_status text; v_sent timestamptz; v_approved boolean;
BEGIN
  IF NOT sec.may_touch_contract(p_contract_id) THEN
    RAISE EXCEPTION 'not your contract';
  END IF;
  SELECT status, sent_at INTO v_status, v_sent
    FROM core.contract WHERE contract_id = p_contract_id;
  IF v_status IS NULL THEN RAISE EXCEPTION 'no such contract'; END IF;
  IF v_sent IS NULL THEN
    RAISE EXCEPTION 'this contract has not been sent yet';
  END IF;
  IF v_status IN ('declined','withdrawn') THEN
    RAISE EXCEPTION 'this contract is %', v_status;
  END IF;

  -- Pays, and approves in the same statement when it is already signed.
  UPDATE core.contract
     SET paid_at     = COALESCE(paid_at, now()),
         payment_ref = COALESCE(p_payment_ref, payment_ref),
         status      = CASE WHEN signed_at IS NOT NULL THEN 'approved' ELSE status END,
         approved_at = CASE WHEN signed_at IS NOT NULL
                            THEN COALESCE(approved_at, now()) ELSE approved_at END
   WHERE contract_id = p_contract_id
   RETURNING (status = 'approved' AND v_status <> 'approved') INTO v_approved;

  INSERT INTO core.contract_history (contract_id, event, changed_by, detail)
  VALUES (p_contract_id, 'paid', sec.actor_id(), p_payment_ref);
  IF v_approved THEN
    INSERT INTO core.contract_history (contract_id, event, from_status,
                                       to_status, changed_by, detail)
    VALUES (p_contract_id, 'approved', v_status, 'approved', sec.actor_id(),
            'signed and paid');
  END IF;

  RETURN (SELECT core.contract_stage(status, sent_at, signed_at, paid_at)
            FROM core.contract WHERE contract_id = p_contract_id);
END $$;

CREATE FUNCTION api.end_contract(p_contract_id uuid, p_status text, p_reason text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $$
DECLARE v_status text;
BEGIN
  IF NOT sec.is_internal() THEN
    RAISE EXCEPTION 'staff only';
  END IF;
  IF p_status NOT IN ('declined','withdrawn') THEN
    RAISE EXCEPTION 'a contract ends declined or withdrawn, not %', p_status;
  END IF;
  SELECT status INTO v_status FROM core.contract WHERE contract_id = p_contract_id;
  IF v_status IS NULL THEN RAISE EXCEPTION 'no such contract'; END IF;

  -- Withdrawing an approved contract RE-LOCKS its properties for that
  -- customer, because the gate reads status. That is the correct
  -- behaviour and it is worth saying out loud: this is not a filing
  -- action, it takes access away.
  UPDATE core.contract
     SET status = p_status, decided_by = sec.actor_id(), decided_reason = p_reason
   WHERE contract_id = p_contract_id;
  INSERT INTO core.contract_history (contract_id, event, from_status, to_status,
                                     changed_by, detail)
  VALUES (p_contract_id, p_status, v_status, p_status, sec.actor_id(), p_reason);
END $$;

CREATE FUNCTION api.contract_history(p_contract_id uuid)
RETURNS TABLE (event text, from_status text, to_status text,
               changed_at timestamptz, changed_by text, detail text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $$
  SELECT h.event, h.from_status, h.to_status, h.changed_at,
         p.full_name, h.detail
    FROM core.contract_history h
    LEFT JOIN core.person p ON p.person_id = h.changed_by
   WHERE h.contract_id = p_contract_id
     AND sec.may_touch_contract(p_contract_id)
   ORDER BY h.changed_at, h.id;
$$;

-- ---------------------------------------------------------------------
-- Grants. Staff functions to staff roles; the customer's own two actions
-- and their own list to sdi_investor as well.
-- ---------------------------------------------------------------------
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'api.agents()', 'api.save_agent(uuid,text,text,text,text)',
    'api.customer_list()', 'api.save_customer(uuid,uuid,text,numeric,numeric,text)',
    'api.opportunities(uuid)', 'api.opportunity_properties(uuid)',
    'api.create_opportunity(uuid,text,uuid,text)',
    'api.add_opportunity_property(uuid,uuid)',
    'api.remove_opportunity_property(uuid,uuid)',
    'api.close_opportunity(uuid,text)',
    'api.contracts(uuid)', 'api.create_contract(uuid,numeric,uuid,text)',
    'api.add_contract_property(uuid,uuid)',
    'api.remove_contract_property(uuid,uuid)',
    'api.send_contract(uuid)', 'api.end_contract(uuid,text,text)']
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO sdi_agent, sdi_admin', f);
  END LOOP;

  FOREACH f IN ARRAY ARRAY[
    'api.my_contracts()', 'api.contract_properties(uuid)',
    'api.sign_contract(uuid)', 'api.record_payment(uuid,text)',
    'api.contract_history(uuid)']
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO sdi_investor, sdi_agent, sdi_admin', f);
  END LOOP;
END $$;

REVOKE ALL ON FUNCTION sec.may_touch_contract(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sec.may_touch_contract(uuid)
  TO sdi_investor, sdi_agent, sdi_admin;

COMMIT;
