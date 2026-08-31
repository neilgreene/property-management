-- =====================================================================
-- 02_policies.sql  |  Session context, security predicates, RLS
-- =====================================================================

-- ---------------------------------------------------------------------
-- Session context  (the SYS_CONTEXT analogue)
-- ---------------------------------------------------------------------
-- The web tier calls set_config('app.actor_id', ..., true) inside an
-- explicit transaction. The trailing `true` makes it transaction-local,
-- so a pooled connection cannot carry one user's context into the next
-- request. Anything that must survive a COMMIT is a bug.
--
-- Every function here is SECURITY DEFINER with a pinned search_path.
-- Definer rights are required, not decorative: app roles hold no USAGE
-- on core, so a plain invoker-rights function could not read core.person
-- to answer "have I signed the fee agreement?". This is the narrow,
-- audited hole that replaces a table grant.

CREATE FUNCTION sec.actor_id() RETURNS uuid
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT NULLIF(current_setting('app.actor_id', true), '')::uuid;
$$;

CREATE FUNCTION sec.current_brand() RETURNS text
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT COALESCE(NULLIF(current_setting('app.brand', true), ''), 'BRAND_A');
$$;

CREATE FUNCTION sec.actor() RETURNS core.person
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $$
  SELECT * FROM core.person WHERE person_id = sec.actor_id() AND active;
$$;

CREATE FUNCTION sec.actor_role() RETURNS sec.actor_role
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $$
  SELECT COALESCE((sec.actor()).role, 'public'::sec.actor_role);
$$;

CREATE FUNCTION sec.is_internal() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $$
  SELECT sec.actor_role() = 'admin';
$$;

-- The $750 gate, expressed as a predicate on the actor's own row rather
-- than as a role grant. That is what lets the KAVADOO tier reuse the
-- same mechanism in Phase 4 with a different predicate instead of a
-- schema change.
CREATE FUNCTION sec.fee_agreement_signed() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $$
  SELECT (sec.actor()).fee_agreement_signed_at IS NOT NULL;
$$;

CREATE FUNCTION sec.is_assigned(p_property_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1 FROM core.property_assignment a
    WHERE a.property_id = p_property_id
      AND a.person_id  = sec.actor_id()
  );
$$;

-- Address unlocks for: internal staff, the assigned agent or lender, or
-- an investor who has signed. Three different reasons, one predicate.
CREATE FUNCTION sec.can_see_address(p_property_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $$
  SELECT sec.is_internal()
      OR sec.is_assigned(p_property_id)
      OR (sec.actor_role() = 'investor' AND sec.fee_agreement_signed());
$$;

-- Single source of truth for investor row visibility. The RLS policy and
-- the save_property write path both call this so they cannot drift.
-- Needed because a SECURITY DEFINER write function runs as its owner and
-- therefore does NOT get the caller's RLS applied -- checking visibility
-- by re-selecting from the view inside such a function silently passes
-- for every row. The predicate has to be explicit and shared.
CREATE FUNCTION sec.property_visible_to_investor(p_property_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM core.property p
    JOIN core.property_brand pb ON pb.property_id = p.property_id
    WHERE p.property_id = p_property_id
      AND p.status IN ('active','coming_soon','pending')
      AND pb.brand_code = sec.current_brand()
      AND pb.published
  );
$$;

-- Deterministic coordinate jitter for the public map pin. The same
-- property always lands on the same fuzzed point, so a viewer cannot
-- average repeated loads to recover the true location.
CREATE FUNCTION sec.jitter(v numeric, seed uuid, salt text) RETURNS numeric
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT round(v + ((hashtext(seed::text || salt) % 1600)::numeric / 100000), 6);
$$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA sec FROM PUBLIC;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA sec
   TO sdi_public, sdi_investor, sdi_agent, sdi_admin;

-- ---------------------------------------------------------------------
-- Row-level security
-- ---------------------------------------------------------------------
ALTER TABLE core.property            ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.property            FORCE  ROW LEVEL SECURITY;
ALTER TABLE core.property_brand      ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.property_brand      FORCE  ROW LEVEL SECURITY;
ALTER TABLE core.saved_property      ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.saved_property      FORCE  ROW LEVEL SECURITY;
ALTER TABLE core.property_assignment ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.property_assignment FORCE  ROW LEVEL SECURITY;
ALTER TABLE core.person              ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.person              FORCE  ROW LEVEL SECURITY;
ALTER TABLE core.brand               ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.brand               FORCE  ROW LEVEL SECURITY;

-- Anonymous browsing: live listings only, on the brand being viewed.
-- Sold and pending fall out of the feed the instant status flips. No
-- workflow, no tag toggle, no window where a stale cache shows them.
CREATE POLICY prop_public_read ON core.property
  FOR SELECT TO sdi_public
  USING (
    status IN ('active','coming_soon')
    AND EXISTS (SELECT 1 FROM core.property_brand pb
                WHERE pb.property_id = property.property_id
                  AND pb.brand_code  = sec.current_brand()
                  AND pb.published)
  );

CREATE POLICY prop_investor_read ON core.property
  FOR SELECT TO sdi_investor
  USING (sec.property_visible_to_investor(property.property_id));

-- Agents see only their own book, but at any status: they have to work
-- pending and sold deals, and drafts they are preparing.
CREATE POLICY prop_agent_read ON core.property
  FOR SELECT TO sdi_agent
  USING (sec.is_assigned(property.property_id));

CREATE POLICY prop_admin_all ON core.property
  FOR ALL TO sdi_admin
  USING (sec.is_internal()) WITH CHECK (sec.is_internal());

CREATE POLICY brand_read ON core.brand
  FOR SELECT TO sdi_public, sdi_investor, sdi_agent, sdi_admin USING (true);

CREATE POLICY pb_read ON core.property_brand
  FOR SELECT TO sdi_public, sdi_investor, sdi_agent
  USING (brand_code = sec.current_brand() AND published);

CREATE POLICY pb_admin ON core.property_brand
  FOR ALL TO sdi_admin USING (sec.is_internal()) WITH CHECK (sec.is_internal());

CREATE POLICY assign_self ON core.property_assignment
  FOR SELECT TO sdi_agent, sdi_investor
  USING (person_id = sec.actor_id());

CREATE POLICY assign_admin ON core.property_assignment
  FOR ALL TO sdi_admin USING (sec.is_internal()) WITH CHECK (sec.is_internal());

-- WITH CHECK on writes: an investor cannot save on someone else's behalf.
CREATE POLICY saved_own ON core.saved_property
  FOR ALL TO sdi_investor
  USING      (person_id = sec.actor_id())
  WITH CHECK (person_id = sec.actor_id());

CREATE POLICY saved_admin ON core.saved_property
  FOR ALL TO sdi_admin USING (sec.is_internal()) WITH CHECK (sec.is_internal());
