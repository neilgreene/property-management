-- =====================================================================
-- 51_customer_workflow.sql  |  showing a property to a customer
-- =====================================================================
-- Assigning a property to a customer, so the workflow between internal
-- staff and buyers can be exercised end to end.
--
-- THE DECISION THIS FILE MAKES, and it is the one that matters:
--
--   BEING SHOWN A PROPERTY IS NOT BEING TOLD WHERE IT IS.
--
-- sec.is_assigned() ignored assign_role entirely, so a row with
-- assign_role = 'investor' opened the address gate exactly as an agent's
-- did. Nobody had noticed because there was one such row in the whole
-- demo. The moment staff start assigning properties to customers -- which
-- is the entire point of this file -- every assignment would have handed
-- over the address, the exact pin and the exterior photograph, silently,
-- and the fee agreement would have stopped meaning anything.
--
-- The operator's rule is explicit: "The assignment does not mean they see
-- the details. The customer only sees the true numbers on the property
-- for cash flow. Not until after they sign certain contract agreements do
-- they see the details."
--
-- So is_assigned() now means ASSIGNED TO WORK THIS PROPERTY -- an agent or
-- a lender, who need the address to do their job. A customer being shown
-- a property is a different relationship with a different answer, and it
-- runs through the deal pipeline that already exists rather than through
-- a second concept invented here.
--
-- WHY A DEAL AND NOT A NEW TABLE. core.deal already links a property, an
-- investor, an agent and a stage, with append-only stage history written
-- by trigger. "Assign this property to this customer" is a deal at
-- INQUIRY. Inventing core.customer_property beside it would give two
-- answers to "what is this buyer looking at" and guarantee they drift.

BEGIN;

-- ---------------------------------------------------------------------
-- The gate, corrected
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sec.is_assigned(p_property_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1 FROM core.property_assignment a
    WHERE a.property_id = p_property_id
      AND a.person_id  = sec.actor_id()
      -- WORKING the property, not shopping for it. An agent needs the
      -- address to show the house; a lender needs it to value the
      -- collateral. A customer needs neither until they have signed.
      AND a.assign_role IN ('agent', 'lender')
  );
$$;

COMMENT ON FUNCTION sec.is_assigned(uuid) IS
    'True for an agent or lender working the property. Deliberately NOT '
    'true for a customer it has been shown to -- see 51_customer_workflow.sql.';

-- ---------------------------------------------------------------------
-- What a customer has been shown
-- ---------------------------------------------------------------------
-- Their own deals, and nothing about the property that the property's own
-- policies would not already give them. The join is to api.property, so
-- the address column is masked or not by the same rule as everywhere
-- else: this view cannot become a way around the gate because it never
-- reads the base table.
CREATE VIEW api.my_deal
WITH (security_invoker = true, security_barrier = true) AS
SELECT d.deal_id, d.property_id, p.listing_ref, p.city, p.state,
       p.street_address, p.address_unlocked,
       p.list_price, p.beds, p.baths, p.sqft, p.property_type, p.status,
       p.cap_rate, p.noi_annual,
       d.stage_code, s.display_name AS stage, s.position AS stage_position,
       s.is_won, s.is_lost,
       d.amount, d.opened_at, d.closed_at,
       sec.actor_name(d.agent_id) AS agent
FROM core.deal d
JOIN core.pipeline_stage s
  ON s.pipeline_code = d.pipeline_code AND s.stage_code = d.stage_code
JOIN api.property p ON p.property_id = d.property_id
WHERE d.investor_id = sec.actor_id()
ORDER BY s.position, d.opened_at DESC;

GRANT SELECT ON api.my_deal TO sdi_investor, sdi_agent, sdi_admin;

COMMENT ON VIEW api.my_deal IS
    'A customer''s own deals. Joins api.property, so the address is shown '
    'or withheld by the ordinary gate -- being shown a property is not '
    'being told where it is.';

-- Whether a given person has signed. A SECURITY DEFINER helper because
-- the view below is security_invoker, so an EXISTS against core.person
-- inside it runs as the CALLER -- who holds no privilege on that table.
-- Staff-gated inside, so it cannot become a way to ask about anybody.
CREATE FUNCTION sec.person_signed(p_person_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $$
  SELECT CASE WHEN sec.is_internal() THEN EXISTS (
    SELECT 1 FROM core.person
     WHERE person_id = p_person_id AND fee_agreement_signed_at IS NOT NULL
  ) END;
$$;

-- Staff view of the same thing: who is looking at this property.
CREATE VIEW api.property_interest
WITH (security_invoker = true, security_barrier = true) AS
SELECT d.deal_id, d.property_id,
       d.investor_id,
       sec.actor_name(d.investor_id) AS customer,
       sec.actor_name(d.agent_id)    AS agent,
       d.stage_code, s.display_name  AS stage, s.position AS stage_position,
       s.is_won, s.is_lost,
       d.amount, d.opened_at, d.closed_at,
       -- Whether this customer would see the address today. Staff assign
       -- properties expecting a buyer to be able to act on them, and "they
       -- cannot see where it is yet" is the thing they need to know.
       sec.person_signed(d.investor_id) AS customer_signed
FROM core.deal d
JOIN core.pipeline_stage s
  ON s.pipeline_code = d.pipeline_code AND s.stage_code = d.stage_code
ORDER BY s.position, d.opened_at DESC;

GRANT SELECT ON api.property_interest TO sdi_agent, sdi_admin;

-- ---------------------------------------------------------------------
-- Assigning
-- ---------------------------------------------------------------------
-- Internal staff only, deliberately: agents assigning to their own
-- customers is a later decision and this file does not make it.
CREATE FUNCTION api.assign_to_customer(p_property_id uuid, p_person_id uuid,
                                       p_agent_id uuid DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $fn$
DECLARE v_id uuid; v_role text;
BEGIN
  IF NOT sec.is_internal() THEN
    RAISE EXCEPTION 'staff only' USING ERRCODE = '42501';
  END IF;
  SELECT role::text INTO v_role FROM core.person
   WHERE person_id = p_person_id AND active;
  IF v_role IS NULL THEN
    RAISE EXCEPTION 'no such person';
  END IF;
  IF v_role <> 'investor' THEN
    RAISE EXCEPTION 'a property is shown to a customer, not to a %', v_role;
  END IF;

  -- One open deal per property per customer. Assigning twice is somebody
  -- clicking twice, not a second interest in the same house.
  SELECT deal_id INTO v_id FROM core.deal
   WHERE property_id = p_property_id AND investor_id = p_person_id
     AND closed_at IS NULL;
  IF v_id IS NOT NULL THEN RETURN v_id; END IF;

  INSERT INTO core.deal (property_id, investor_id, agent_id,
                         pipeline_code, stage_code)
  VALUES (p_property_id, p_person_id, p_agent_id, 'ACQUISITION', 'INQUIRY')
  RETURNING deal_id INTO v_id;
  RETURN v_id;
END;
$fn$;

CREATE FUNCTION api.move_deal(p_deal_id uuid, p_stage text,
                              p_lost_reason text DEFAULT NULL)
RETURNS boolean
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $fn$
DECLARE v_won boolean; v_lost boolean; n integer;
BEGIN
  IF NOT sec.is_internal() THEN
    RAISE EXCEPTION 'staff only' USING ERRCODE = '42501';
  END IF;
  SELECT is_won, is_lost INTO v_won, v_lost FROM core.pipeline_stage
   WHERE pipeline_code = 'ACQUISITION' AND stage_code = p_stage;
  IF v_won IS NULL THEN
    RAISE EXCEPTION '% is not a stage of this pipeline', p_stage;
  END IF;

  -- Closing sets closed_at in the same statement that sets the stage. A
  -- deal marked Closed with no closing date is a reporting hole that
  -- nobody notices until somebody asks how long deals take.
  UPDATE core.deal
     SET stage_code = p_stage,
         closed_at  = CASE WHEN v_won OR v_lost THEN now() ELSE NULL END,
         lost_reason = CASE WHEN v_lost
                            THEN NULLIF(btrim(COALESCE(p_lost_reason, '')), '') END,
         updated_at = now()
   WHERE deal_id = p_deal_id;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n > 0;
END;
$fn$;

CREATE FUNCTION api.unassign_customer(p_deal_id uuid)
RETURNS boolean
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $fn$
DECLARE n integer;
BEGIN
  IF NOT sec.is_internal() THEN
    RAISE EXCEPTION 'staff only' USING ERRCODE = '42501';
  END IF;
  -- Withdrawn, not deleted. The stage history is the record of what was
  -- shown to whom, and deleting the deal deletes that too.
  UPDATE core.deal SET stage_code = 'CLOSED_LOST', closed_at = now(),
                       lost_reason = 'withdrawn', updated_at = now()
   WHERE deal_id = p_deal_id AND closed_at IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n > 0;
END;
$fn$;

-- Who a property can be shown to. Staff need a list of customers, and
-- core.person is not readable by the web tier.
CREATE FUNCTION api.customers()
RETURNS TABLE (person_id uuid, full_name text, email text, signed boolean)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $$
  SELECT p.person_id, p.full_name, p.email,
         p.fee_agreement_signed_at IS NOT NULL
    FROM core.person p
   WHERE p.role = 'investor' AND p.active
     AND sec.is_internal()
   ORDER BY p.full_name;
$$;

-- The stages, for a dropdown. Through api like everything else: no
-- application role holds USAGE on core, so naming core.pipeline_stage
-- from the web tier fails -- which it did, and this is the third time in
-- this branch that boundary has caught a read written the short way.
CREATE FUNCTION api.acquisition_stages()
-- `position` is a reserved word in a RETURNS TABLE list, so the column
-- carries the name the views already use for it.
RETURNS TABLE (stage_code text, display_name text, stage_position integer,
               is_won boolean, is_lost boolean)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = core, pg_temp
AS $$
  SELECT s.stage_code, s.display_name, s.position, s.is_won, s.is_lost
    FROM core.pipeline_stage s
   WHERE s.pipeline_code = 'ACQUISITION'
   ORDER BY s.position;
$$;

REVOKE ALL ON FUNCTION api.acquisition_stages() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.acquisition_stages()
    TO sdi_investor, sdi_agent, sdi_admin;

REVOKE ALL ON FUNCTION api.assign_to_customer(uuid, uuid, uuid),
                       api.move_deal(uuid, text, text),
                       api.unassign_customer(uuid), api.customers() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.assign_to_customer(uuid, uuid, uuid),
                          api.move_deal(uuid, text, text),
                          api.unassign_customer(uuid), api.customers()
    TO sdi_agent, sdi_admin;

-- ---------------------------------------------------------------------
-- More people to exercise it with
-- ---------------------------------------------------------------------
-- Three investors was enough to demonstrate a gate and is not enough to
-- demonstrate a workflow. These are deliberately a mixed bag: two who
-- have signed the fee agreement and two who have not, because the whole
-- point of the exercise is watching the same assignment behave
-- differently either side of that line.
INSERT INTO core.person (person_id, full_name, email, role, home_brand,
                         fee_agreement_signed_at, active)
VALUES
  ('88888888-0000-0000-0000-000000000001', 'Alan Whitfield',
   'awhitfield@example.com', 'investor', 'BRAND_A', now() - interval '40 days', true),
  ('88888888-0000-0000-0000-000000000002', 'Bev Nakamura',
   'bnakamura@example.com', 'investor', 'BRAND_A', NULL, true),
  ('88888888-0000-0000-0000-000000000003', 'Carl Ozanne',
   'cozanne@example.com', 'investor', 'BRAND_A', now() - interval '9 days', true),
  ('88888888-0000-0000-0000-000000000004', 'Dana Ruiz',
   'druiz@example.com', 'investor', 'BRAND_A', NULL, true)
ON CONFLICT (person_id) DO NOTHING;

COMMIT;
