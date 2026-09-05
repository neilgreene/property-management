-- =====================================================================
-- 63_customer_contact.sql  |  how to reach a customer, and how to sort them
-- =====================================================================
-- Addresses and telephone numbers live on core.customer_profile rather
-- than on core.person. core.person.phone is the ACCOUNT HOLDER'S own
-- number -- what they put on their profile page and what a colleague sees
-- in the rail. These are the CRM's record of a customer, they arrive from
-- GoHighLevel with everything else in this file, and one of the two will
-- be wrong first. Keeping them apart means it is always clear which one
-- somebody edited.

BEGIN;

ALTER TABLE core.customer_profile
  ADD COLUMN home_address  text,
  ADD COLUMN work_address  text,
  ADD COLUMN phone_home    text,
  ADD COLUMN phone_work    text,
  ADD COLUMN phone_mobile  text;

-- ---------------------------------------------------------------------
-- Sorting people by surname
-- ---------------------------------------------------------------------
-- "Ruiz, Dana" -- a list of customers is looked up by surname, so that is
-- what it sorts on and what it shows.
--
-- The last whitespace-separated token is the surname and the rest are
-- given names. That is right for the names here and wrong for plenty of
-- others: compound surnames, names written family-name-first, single-word
-- names. It is a display convenience over a single `full_name` column,
-- not a claim about how names work -- when that matters, the fix is to
-- store the parts separately rather than to guess harder here.
CREATE FUNCTION core.sort_name(p_full text) RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT CASE
    WHEN btrim(COALESCE(p_full, '')) = '' THEN ''
    WHEN strpos(btrim(p_full), ' ') = 0 THEN btrim(p_full)
    ELSE regexp_replace(btrim(p_full), '^(.*)\s+(\S+)$', '\2, \1')
  END;
$$;

-- ---------------------------------------------------------------------
-- The list, rebuilt. A set-returning function's row type cannot be
-- altered by CREATE OR REPLACE, so it is dropped and recreated -- which
-- drops its grants with it, hence the explicit GRANT at the foot.
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS api.customer_list();

CREATE FUNCTION api.customer_list()
RETURNS TABLE (person_id uuid, full_name text, sort_name text,
               email text, phone text,
               phone_home text, phone_work text, phone_mobile text,
               home_address text, work_address text,
               signed boolean, agent_id uuid, agent_name text,
               target_metro text, budget_low numeric, budget_high numeric,
               notes text, active boolean, external_ref text,
               opportunity_count bigint, contract_count bigint,
               approved_contracts bigint, unlocked_properties bigint)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $$
  SELECT p.person_id, p.full_name, core.sort_name(p.full_name),
         p.email, p.phone,
         c.phone_home, c.phone_work, c.phone_mobile,
         c.home_address, c.work_address,
         p.fee_agreement_signed_at IS NOT NULL,
         c.agent_id, ag.full_name,
         c.target_metro, c.budget_low, c.budget_high, c.notes, p.active,
         c.external_ref,
         (SELECT count(*) FROM core.opportunity o WHERE o.person_id = p.person_id),
         (SELECT count(*) FROM core.contract k WHERE k.person_id = p.person_id),
         (SELECT count(*) FROM core.contract k
           WHERE k.person_id = p.person_id AND k.status = 'approved'),
         (SELECT count(DISTINCT cp.property_id)
            FROM core.contract k
            JOIN core.contract_property cp ON cp.contract_id = k.contract_id
           WHERE k.person_id = p.person_id AND k.status = 'approved')
    FROM core.person p
    LEFT JOIN core.customer_profile c ON c.person_id = p.person_id
    LEFT JOIN core.person ag ON ag.person_id = c.agent_id
   WHERE p.role = 'investor' AND sec.is_internal()
   ORDER BY core.sort_name(p.full_name);
$$;

DROP FUNCTION IF EXISTS api.my_customers();

CREATE FUNCTION api.my_customers()
RETURNS TABLE (person_id uuid, full_name text, sort_name text,
               email text, phone text,
               phone_home text, phone_work text, phone_mobile text,
               home_address text, work_address text,
               target_metro text, budget_low numeric, budget_high numeric,
               notes text,
               opportunity_count bigint,
               contracts_total bigint,
               contracts_awaiting_signature bigint,
               contracts_awaiting_payment bigint,
               contracts_approved bigint,
               properties_unlocked bigint,
               last_activity timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $$
  SELECT p.person_id, p.full_name, core.sort_name(p.full_name),
         p.email, p.phone,
         c.phone_home, c.phone_work, c.phone_mobile,
         c.home_address, c.work_address,
         c.target_metro, c.budget_low, c.budget_high, c.notes,
         (SELECT count(*) FROM core.opportunity o WHERE o.person_id = p.person_id),
         (SELECT count(*) FROM core.contract k
           WHERE k.person_id = p.person_id AND k.status <> 'draft'),
         (SELECT count(*) FROM core.contract k
           WHERE k.person_id = p.person_id AND k.status = 'sent'
             AND k.signed_at IS NULL),
         (SELECT count(*) FROM core.contract k
           WHERE k.person_id = p.person_id AND k.status = 'sent'
             AND k.signed_at IS NOT NULL AND k.paid_at IS NULL),
         (SELECT count(*) FROM core.contract k
           WHERE k.person_id = p.person_id AND k.status = 'approved'),
         (SELECT count(DISTINCT cp.property_id)
            FROM core.contract k
            JOIN core.contract_property cp ON cp.contract_id = k.contract_id
           WHERE k.person_id = p.person_id AND k.status = 'approved'),
         GREATEST(
           (SELECT max(h.changed_at) FROM core.contract_history h
              JOIN core.contract k ON k.contract_id = h.contract_id
             WHERE k.person_id = p.person_id),
           (SELECT max(o.created_at) FROM core.opportunity o
             WHERE o.person_id = p.person_id))
    FROM core.person p
    JOIN core.customer_profile c ON c.person_id = p.person_id
   WHERE p.role = 'investor' AND p.active
     AND (sec.is_internal() OR c.agent_id = sec.actor_id())
   ORDER BY core.sort_name(p.full_name);
$$;

-- Saving the contact details as well as the rest.
DROP FUNCTION IF EXISTS api.save_customer(uuid, uuid, text, numeric, numeric, text);

CREATE FUNCTION api.save_customer(p_person_id uuid, p_agent_id uuid,
                                  p_target_metro text, p_budget_low numeric,
                                  p_budget_high numeric, p_notes text,
                                  p_home_address text DEFAULT NULL,
                                  p_work_address text DEFAULT NULL,
                                  p_phone_home text DEFAULT NULL,
                                  p_phone_work text DEFAULT NULL,
                                  p_phone_mobile text DEFAULT NULL)
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
                                     budget_low, budget_high, notes,
                                     home_address, work_address,
                                     phone_home, phone_work, phone_mobile)
  VALUES (p_person_id, p_agent_id, p_target_metro, p_budget_low, p_budget_high,
          p_notes, p_home_address, p_work_address,
          p_phone_home, p_phone_work, p_phone_mobile)
  ON CONFLICT (person_id) DO UPDATE
    SET agent_id     = EXCLUDED.agent_id,
        target_metro = EXCLUDED.target_metro,
        budget_low   = EXCLUDED.budget_low,
        budget_high  = EXCLUDED.budget_high,
        notes        = EXCLUDED.notes,
        home_address = EXCLUDED.home_address,
        work_address = EXCLUDED.work_address,
        phone_home   = EXCLUDED.phone_home,
        phone_work   = EXCLUDED.phone_work,
        phone_mobile = EXCLUDED.phone_mobile,
        updated_at   = now();
END $$;

-- Something to look at.
UPDATE core.customer_profile SET
  home_address = CASE person_id
    WHEN '88888888-0000-0000-0000-000000000001' THEN '2214 Fairmount Blvd, Cleveland Heights, OH 44106'
    WHEN '88888888-0000-0000-0000-000000000002' THEN '918 W 32nd St, Kansas City, MO 64108'
    WHEN '88888888-0000-0000-0000-000000000003' THEN '77 Prospect Ave, Indianapolis, IN 46203'
    WHEN '88888888-0000-0000-0000-000000000004' THEN '450 Belmont Ave, Tampa, FL 33606' END,
  work_address = CASE person_id
    WHEN '88888888-0000-0000-0000-000000000001' THEN 'Whitfield Holdings, 1100 Superior Ave E, Cleveland, OH 44114'
    WHEN '88888888-0000-0000-0000-000000000003' THEN 'Ozanne Capital, 201 N Illinois St, Indianapolis, IN 46204' END,
  phone_mobile = CASE person_id
    WHEN '88888888-0000-0000-0000-000000000001' THEN '+1 216 555 0142'
    WHEN '88888888-0000-0000-0000-000000000002' THEN '+1 816 555 0198'
    WHEN '88888888-0000-0000-0000-000000000003' THEN '+1 317 555 0176'
    WHEN '88888888-0000-0000-0000-000000000004' THEN '+1 813 555 0121' END,
  phone_home = CASE person_id
    WHEN '88888888-0000-0000-0000-000000000001' THEN '+1 216 555 0110'
    WHEN '88888888-0000-0000-0000-000000000003' THEN '+1 317 555 0155' END,
  phone_work = CASE person_id
    WHEN '88888888-0000-0000-0000-000000000001' THEN '+1 216 555 0180'
    WHEN '88888888-0000-0000-0000-000000000003' THEN '+1 317 555 0190' END
WHERE person_id IN ('88888888-0000-0000-0000-000000000001',
                    '88888888-0000-0000-0000-000000000002',
                    '88888888-0000-0000-0000-000000000003',
                    '88888888-0000-0000-0000-000000000004');

REVOKE ALL ON FUNCTION api.customer_list() FROM PUBLIC;
REVOKE ALL ON FUNCTION api.my_customers() FROM PUBLIC;
REVOKE ALL ON FUNCTION api.save_customer(uuid,uuid,text,numeric,numeric,text,
                                         text,text,text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.customer_list() TO sdi_agent, sdi_admin;
GRANT EXECUTE ON FUNCTION api.my_customers() TO sdi_agent, sdi_admin;
GRANT EXECUTE ON FUNCTION api.save_customer(uuid,uuid,text,numeric,numeric,text,
                                            text,text,text,text,text)
  TO sdi_agent, sdi_admin;

COMMIT;
