-- =====================================================================
-- 61_agent_views.sql  |  an agent's own book
-- =====================================================================
-- sec.is_internal() is admin, not staff-in-general, so every function in
-- 56 is closed to agents -- correct for the administrative lists, and
-- wrong for the one question an agent actually has: how are MY customers
-- getting on.
--
-- So this is not a relaxation of those functions. It is a different
-- question with a different scope: rows where the caller is the named
-- agent. An administrator sees the same shape for everybody, because an
-- administrator asking about a book is asking about all of them.

BEGIN;

CREATE FUNCTION api.my_customers()
RETURNS TABLE (person_id uuid, full_name text, email text, phone text,
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
  SELECT p.person_id, p.full_name, p.email, p.phone,
         c.target_metro, c.budget_low, c.budget_high, c.notes,
         (SELECT count(*) FROM core.opportunity o WHERE o.person_id = p.person_id),
         (SELECT count(*) FROM core.contract k
           WHERE k.person_id = p.person_id AND k.status <> 'draft'),
         -- Sent, not signed. The agent's job is to chase this one.
         (SELECT count(*) FROM core.contract k
           WHERE k.person_id = p.person_id AND k.status = 'sent'
             AND k.signed_at IS NULL),
         -- Signed, not paid. A different chase, and the more urgent one:
         -- they have agreed and the property is still shut.
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
   ORDER BY p.full_name;
$$;

-- The contracts belonging to the caller's customers, for the same reason.
CREATE FUNCTION api.my_customer_contracts(p_person_id uuid DEFAULT NULL)
RETURNS TABLE (contract_id uuid, reference text, status text, stage text,
               person_id uuid, customer_name text,
               property_count bigint, fee_amount numeric,
               sent_at timestamptz, signed_at timestamptz,
               paid_at timestamptz, approved_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $$
  SELECT k.contract_id, k.reference, k.status,
         core.contract_stage(k.status, k.sent_at, k.signed_at, k.paid_at),
         k.person_id, cu.full_name,
         (SELECT count(*) FROM core.contract_property cp
           WHERE cp.contract_id = k.contract_id),
         k.fee_amount, k.sent_at, k.signed_at, k.paid_at, k.approved_at
    FROM core.contract k
    JOIN core.person cu ON cu.person_id = k.person_id
    JOIN core.customer_profile c ON c.person_id = k.person_id
   WHERE (sec.is_internal() OR c.agent_id = sec.actor_id())
     AND (p_person_id IS NULL OR k.person_id = p_person_id)
   ORDER BY k.created_at DESC;
$$;

REVOKE ALL ON FUNCTION api.my_customers() FROM PUBLIC;
REVOKE ALL ON FUNCTION api.my_customer_contracts(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.my_customers() TO sdi_agent, sdi_admin;
GRANT EXECUTE ON FUNCTION api.my_customer_contracts(uuid) TO sdi_agent, sdi_admin;

COMMIT;
