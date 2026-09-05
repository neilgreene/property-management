-- =====================================================================
-- 56_contract_api.sql  |  reading and moving the new entities
-- =====================================================================
-- Everything the web tier can do with agents, customers, opportunities
-- and contracts. Separate from 55 for the same reason 32_media_api.sql is
-- separate from 31_media_store.sql: the tables settle, the surface over
-- them does not.
--
-- All SECURITY DEFINER. No application role holds USAGE on core, so this
-- is not a preference -- a view or function body that reads core as the
-- caller fails outright. That boundary has caught a read written the
-- short way several times in this branch.

BEGIN;

-- ---------------------------------------------------------------------
-- Who may act
-- ---------------------------------------------------------------------
-- Staff, or the customer named on the contract. A customer signs and pays
-- their own; staff do everything else and can do those two on their
-- behalf, because in the mock nobody is going to open a second browser.
CREATE FUNCTION sec.may_touch_contract(p_contract_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $$
  SELECT sec.is_internal()
      OR EXISTS (SELECT 1 FROM core.contract c
                  WHERE c.contract_id = p_contract_id
                    AND c.person_id = sec.actor_id());
$$;

-- ---------------------------------------------------------------------
-- Agents
-- ---------------------------------------------------------------------
CREATE FUNCTION api.agents()
RETURNS TABLE (person_id uuid, full_name text, email text, phone text,
               licence_no text, brokerage text, metro_code text,
               notes text, active boolean, external_ref text,
               customer_count bigint, open_opportunities bigint)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $$
  SELECT p.person_id, p.full_name, p.email, p.phone,
         a.licence_no, a.brokerage, a.metro_code, a.notes, p.active,
         a.external_ref,
         (SELECT count(*) FROM core.customer_profile c WHERE c.agent_id = p.person_id),
         (SELECT count(*) FROM core.opportunity o
           WHERE o.agent_id = p.person_id AND o.status = 'open')
    FROM core.person p
    LEFT JOIN core.agent_profile a ON a.person_id = p.person_id
   WHERE p.role = 'agent' AND sec.is_internal()
   ORDER BY p.full_name;
$$;

CREATE FUNCTION api.save_agent(p_person_id uuid, p_licence_no text,
                               p_brokerage text, p_metro_code text,
                               p_notes text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $$
BEGIN
  IF NOT sec.is_internal() THEN
    RAISE EXCEPTION 'staff only';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM core.person
                  WHERE person_id = p_person_id AND role = 'agent') THEN
    RAISE EXCEPTION 'not an agent';
  END IF;
  INSERT INTO core.agent_profile (person_id, licence_no, brokerage, metro_code, notes)
  VALUES (p_person_id, p_licence_no, p_brokerage, p_metro_code, p_notes)
  ON CONFLICT (person_id) DO UPDATE
    SET licence_no = EXCLUDED.licence_no,
        brokerage  = EXCLUDED.brokerage,
        metro_code = EXCLUDED.metro_code,
        notes      = EXCLUDED.notes,
        updated_at = now();
END $$;

-- ---------------------------------------------------------------------
-- Customers
-- ---------------------------------------------------------------------
CREATE FUNCTION api.customer_list()
RETURNS TABLE (person_id uuid, full_name text, email text, phone text,
               signed boolean, agent_id uuid, agent_name text,
               target_metro text, budget_low numeric, budget_high numeric,
               notes text, active boolean, external_ref text,
               opportunity_count bigint, contract_count bigint,
               approved_contracts bigint, unlocked_properties bigint)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $$
  SELECT p.person_id, p.full_name, p.email, p.phone,
         p.fee_agreement_signed_at IS NOT NULL,
         c.agent_id, ag.full_name,
         c.target_metro, c.budget_low, c.budget_high, c.notes, p.active,
         c.external_ref,
         (SELECT count(*) FROM core.opportunity o WHERE o.person_id = p.person_id),
         (SELECT count(*) FROM core.contract k WHERE k.person_id = p.person_id),
         (SELECT count(*) FROM core.contract k
           WHERE k.person_id = p.person_id AND k.status = 'approved'),
         -- What this customer can actually see, which is the number the
         -- whole feature exists to control.
         (SELECT count(DISTINCT cp.property_id)
            FROM core.contract k
            JOIN core.contract_property cp ON cp.contract_id = k.contract_id
           WHERE k.person_id = p.person_id AND k.status = 'approved')
    FROM core.person p
    LEFT JOIN core.customer_profile c ON c.person_id = p.person_id
    LEFT JOIN core.person ag ON ag.person_id = c.agent_id
   WHERE p.role = 'investor' AND sec.is_internal()
   ORDER BY p.full_name;
$$;

CREATE FUNCTION api.save_customer(p_person_id uuid, p_agent_id uuid,
                                  p_target_metro text, p_budget_low numeric,
                                  p_budget_high numeric, p_notes text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $$
BEGIN
  IF NOT sec.is_internal() THEN
    RAISE EXCEPTION 'staff only';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM core.person
                  WHERE person_id = p_person_id AND role = 'investor') THEN
    RAISE EXCEPTION 'not a customer';
  END IF;
  IF p_agent_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM core.person
                      WHERE person_id = p_agent_id AND role = 'agent') THEN
    RAISE EXCEPTION 'not an agent';
  END IF;
  INSERT INTO core.customer_profile (person_id, agent_id, target_metro,
                                     budget_low, budget_high, notes)
  VALUES (p_person_id, p_agent_id, p_target_metro, p_budget_low, p_budget_high, p_notes)
  ON CONFLICT (person_id) DO UPDATE
    SET agent_id     = EXCLUDED.agent_id,
        target_metro = EXCLUDED.target_metro,
        budget_low   = EXCLUDED.budget_low,
        budget_high  = EXCLUDED.budget_high,
        notes        = EXCLUDED.notes,
        updated_at   = now();
END $$;

-- ---------------------------------------------------------------------
-- Opportunities
-- ---------------------------------------------------------------------
CREATE FUNCTION api.opportunities(p_person_id uuid DEFAULT NULL)
RETURNS TABLE (opportunity_id uuid, title text, status text,
               person_id uuid, customer_name text,
               agent_id uuid, agent_name text,
               property_count bigint, notes text,
               created_at timestamptz, closed_at timestamptz,
               external_ref text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $$
  SELECT o.opportunity_id, o.title, o.status,
         o.person_id, cu.full_name, o.agent_id, ag.full_name,
         (SELECT count(*) FROM core.opportunity_property op
           WHERE op.opportunity_id = o.opportunity_id),
         o.notes, o.created_at, o.closed_at, o.external_ref
    FROM core.opportunity o
    JOIN core.person cu ON cu.person_id = o.person_id
    LEFT JOIN core.person ag ON ag.person_id = o.agent_id
   WHERE sec.is_internal()
     AND (p_person_id IS NULL OR o.person_id = p_person_id)
   ORDER BY o.created_at DESC;
$$;

CREATE FUNCTION api.opportunity_properties(p_opportunity_id uuid)
RETURNS TABLE (property_id uuid, listing_ref text, city text, state text,
               list_price numeric, added_at timestamptz,
               on_contract boolean, unlocked boolean)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $$
  SELECT p.property_id, p.listing_ref, p.city, p.state, p.list_price,
         op.added_at,
         EXISTS (SELECT 1 FROM core.contract k
                   JOIN core.contract_property cp ON cp.contract_id = k.contract_id
                  WHERE cp.property_id = p.property_id
                    AND k.person_id = o.person_id),
         EXISTS (SELECT 1 FROM core.contract k
                   JOIN core.contract_property cp ON cp.contract_id = k.contract_id
                  WHERE cp.property_id = p.property_id
                    AND k.person_id = o.person_id
                    AND k.status = 'approved')
    FROM core.opportunity_property op
    JOIN core.opportunity o ON o.opportunity_id = op.opportunity_id
    JOIN core.property p ON p.property_id = op.property_id
   WHERE op.opportunity_id = p_opportunity_id
     AND sec.is_internal()
   ORDER BY p.listing_ref;
$$;

CREATE FUNCTION api.create_opportunity(p_person_id uuid, p_title text,
                                       p_agent_id uuid DEFAULT NULL,
                                       p_notes text DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $$
DECLARE v_id uuid;
BEGIN
  IF NOT sec.is_internal() THEN
    RAISE EXCEPTION 'staff only';
  END IF;
  IF btrim(COALESCE(p_title, '')) = '' THEN
    RAISE EXCEPTION 'an opportunity needs a title';
  END IF;
  INSERT INTO core.opportunity (person_id, agent_id, title, notes, created_by)
  VALUES (p_person_id, p_agent_id, btrim(p_title), p_notes, sec.actor_id())
  RETURNING opportunity_id INTO v_id;
  RETURN v_id;
END $$;

CREATE FUNCTION api.add_opportunity_property(p_opportunity_id uuid,
                                             p_property_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $$
BEGIN
  IF NOT sec.is_internal() THEN
    RAISE EXCEPTION 'staff only';
  END IF;
  INSERT INTO core.opportunity_property (opportunity_id, property_id, added_by)
  VALUES (p_opportunity_id, p_property_id, sec.actor_id())
  ON CONFLICT DO NOTHING;
END $$;

CREATE FUNCTION api.remove_opportunity_property(p_opportunity_id uuid,
                                                p_property_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $$
BEGIN
  IF NOT sec.is_internal() THEN
    RAISE EXCEPTION 'staff only';
  END IF;
  DELETE FROM core.opportunity_property
   WHERE opportunity_id = p_opportunity_id AND property_id = p_property_id;
END $$;

CREATE FUNCTION api.close_opportunity(p_opportunity_id uuid, p_status text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $$
BEGIN
  IF NOT sec.is_internal() THEN
    RAISE EXCEPTION 'staff only';
  END IF;
  IF p_status NOT IN ('open','won','lost') THEN
    RAISE EXCEPTION 'unknown opportunity status: %', p_status;
  END IF;
  UPDATE core.opportunity
     SET status = p_status,
         closed_at = CASE WHEN p_status = 'open' THEN NULL ELSE now() END
   WHERE opportunity_id = p_opportunity_id;
END $$;

COMMIT;
