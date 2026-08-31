-- =====================================================================
-- 12_pipeline_policies.sql  |  who sees which deals
-- =====================================================================
-- A deal joins a property to an investor, so it inherits the visibility
-- problem rather than escaping it. The rules, all reusing sec.actor():
--
--   investor  their own deals only
--   agent     deals they are the agent on
--   admin     all
--   public    none -- a deal is never public, at any stage
--
-- amount is band 2: it is what an investor is paying, so it goes to the
-- parties to the deal and to staff, and to nobody else.

BEGIN;

ALTER TABLE core.deal               ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.deal               FORCE  ROW LEVEL SECURITY;
ALTER TABLE core.deal_stage_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.deal_stage_history FORCE  ROW LEVEL SECURITY;
ALTER TABLE core.pipeline           ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.pipeline           FORCE  ROW LEVEL SECURITY;
ALTER TABLE core.pipeline_stage     ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.pipeline_stage     FORCE  ROW LEVEL SECURITY;

-- Pipeline definitions are not sensitive; the deals inside them are.
CREATE POLICY pipeline_read       ON core.pipeline       FOR SELECT USING (true);
CREATE POLICY pipeline_stage_read ON core.pipeline_stage FOR SELECT USING (true);

CREATE FUNCTION sec.can_see_deal(p_investor uuid, p_agent uuid)
RETURNS boolean
LANGUAGE sql STABLE
SET search_path = sec, core, pg_temp
AS $$
  SELECT CASE (SELECT role FROM sec.actor())
           WHEN 'admin'    THEN true
           WHEN 'agent'    THEN p_agent    = sec.actor_id()
           WHEN 'investor' THEN p_investor = sec.actor_id()
           ELSE false
         END;
$$;

CREATE POLICY deal_read ON core.deal
  FOR SELECT USING (sec.can_see_deal(investor_id, agent_id));

-- History follows the deal it belongs to. Stated once, by reference, so
-- the two cannot drift apart.
CREATE POLICY deal_history_read ON core.deal_stage_history
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM core.deal d
             WHERE d.deal_id = core.deal_stage_history.deal_id
               AND sec.can_see_deal(d.investor_id, d.agent_id))
  );

-- An agent legitimately needs the investor's name on their own deal, and
-- an investor needs their agent's. But core.person is RLS'd to self, so a
-- plain join would either return NULL or -- if the policy were loosened --
-- expose the whole directory.
--
-- So exactly one field is released, and only to someone who already shares
-- a deal with that person. Definer-rights, because the check has to see
-- rows the caller cannot; the check itself is what keeps that safe.
CREATE FUNCTION sec.deal_party_name(p_person uuid)
RETURNS text
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = sec, core, pg_temp
AS $$
  SELECT p.full_name
    FROM core.person p
   WHERE p.person_id = p_person
     AND (
       (SELECT role FROM sec.actor()) = 'admin'
       OR EXISTS (
            SELECT 1 FROM core.deal d
             WHERE (d.investor_id = p_person OR d.agent_id = p_person)
               AND sec.can_see_deal(d.investor_id, d.agent_id))
     );
$$;

COMMENT ON FUNCTION sec.deal_party_name(uuid) IS
    'Releases a full name, and nothing else, to a counterparty on a shared '
    'deal. Returns NULL to everyone else, including for a person who exists.';

-- ---------------------------------------------------------------------
-- Views
-- ---------------------------------------------------------------------
-- LEFT JOIN to core.property, not INNER. core.property has its own RLS, so
-- an inner join silently DROPS a deal whose property the caller cannot see
-- -- an agent would lose a deal they are party to, with no error and no
-- clue why. Being party to a deal makes the deal visible; the property
-- columns then fill in only as far as the property's own policy allows.
CREATE VIEW api.deal
WITH (security_invoker = true, security_barrier = true) AS
SELECT d.deal_id,
       d.property_id,
       p.listing_ref,
       p.city,
       p.state,
       d.pipeline_code,
       d.stage_code,
       s.display_name AS stage_name,
       s.position     AS stage_position,
       s.is_won, s.is_lost,
       d.amount,
       sec.deal_party_name(d.investor_id) AS investor_name,
       sec.deal_party_name(d.agent_id)    AS agent_name,
       d.opened_at, d.closed_at, d.lost_reason,
       -- Age in the current stage, from the append-only log rather than
       -- from a column someone has to remember to maintain.
       EXTRACT(EPOCH FROM (now() - COALESCE(
           (SELECT max(h.changed_at) FROM core.deal_stage_history h
             WHERE h.deal_id = d.deal_id), d.opened_at)))::bigint AS seconds_in_stage
FROM core.deal d
LEFT JOIN core.property p  ON p.property_id = d.property_id
JOIN core.pipeline_stage s ON s.pipeline_code = d.pipeline_code
                          AND s.stage_code    = d.stage_code;

CREATE VIEW api.deal_history
WITH (security_invoker = true, security_barrier = true) AS
SELECT h.id, h.deal_id, h.from_stage, h.to_stage, h.changed_at,
       h.seconds_in_from,
       sec.deal_party_name(h.changed_by) AS changed_by_name
FROM core.deal_stage_history h;

-- security_invoker views resolve their base tables as the CALLER, so the
-- roles need the table privilege here as well as on the view. They still
-- do not get USAGE on core, so they cannot name these tables in a query
-- of their own -- name resolution fails before any ACL is consulted.
-- That is the same split 03_views.sql uses for core.property.
GRANT SELECT ON core.deal, core.deal_stage_history,
                core.pipeline, core.pipeline_stage
    TO sdi_investor, sdi_agent, sdi_admin;

GRANT EXECUTE ON FUNCTION sec.deal_party_name(uuid)
    TO sdi_investor, sdi_agent, sdi_admin;

GRANT SELECT ON api.deal, api.deal_history
    TO sdi_investor, sdi_agent, sdi_admin;

-- Deliberately not granted to sdi_public. A deal is never public.

COMMIT;
