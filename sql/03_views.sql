-- =====================================================================
-- 03_views.sql  |  Column masking (the VPD column-security analogue)
-- =====================================================================
-- Postgres column GRANTs raise "permission denied for column" on
-- SELECT *, which breaks the Oracle habit of "select * still works, you
-- just see less". These views restore that behaviour: every column is
-- always present in the result, unauthorised ones come back NULL.
--
-- security_invoker = true   (PG15+) -- the view executes as the CALLER,
--   so RLS on core.property applies to them. Without this a view is
--   definer-rights and silently bypasses every policy in 02.
--   Consequence: the caller needs SELECT on the base tables too. That is
--   why the grants below exist, and why the schema lockdown matters.
--
-- security_barrier = true   -- stops the planner pushing a user-supplied
--   WHERE clause underneath the view's own quals. Postgres costs user
--   functions cheaply, so without the barrier a caller can attach a
--   VOLATILE function that fires on rows they were never allowed to see.
--
-- ---------------------------------------------------------------------
-- Three independent layers, so no single mistake exposes everything:
--
--   rows    -> RLS policies. Hard ACL. Cannot be bypassed from SQL.
--   band 3  -> column-level GRANT. Hard ACL. Non-admin roles hold no
--              privilege on acquisition_cost/source_channel/internal_notes
--              at all, so the internal band stays unreachable even if
--              somebody later grants USAGE on core by mistake.
--   band 2  -> CASE masking in the view + no USAGE on schema core.
--              Softer by necessity: signed and unsigned investors share
--              one role, and column ACLs cannot tell them apart. The gate
--              is a data predicate, so it has to live in the view. Oracle
--              VPD column masking has the same property.
-- ---------------------------------------------------------------------

-- Band 1 + 2 columns only. Note what is absent.
GRANT SELECT (property_id, listing_ref, status, city, state, zip,
              property_type, beds, baths, sqft, year_built,
              list_price, gross_rent_annual, opex_annual, hoa_annual,
              noi_annual, cap_rate,
              street_address, unit, lat, lng, parcel_number,
              seller_disclosure, created_at)
   ON core.property TO sdi_public, sdi_investor, sdi_agent;

GRANT SELECT ON core.property TO sdi_admin;

GRANT SELECT ON core.property_brand, core.brand TO
      sdi_public, sdi_investor, sdi_agent, sdi_admin;
GRANT SELECT ON core.property_assignment TO sdi_investor, sdi_agent, sdi_admin;
GRANT SELECT, INSERT, DELETE ON core.saved_property TO sdi_investor;
GRANT SELECT ON core.saved_property TO sdi_admin;

-- ---------------------------------------------------------------------
-- api.property -- the surface every role reads. Bands 1 and 2 only.
-- ---------------------------------------------------------------------
CREATE VIEW api.property
WITH (security_invoker = true, security_barrier = true) AS
SELECT
    p.property_id,
    p.listing_ref,
    p.status,
    p.city,
    p.state,
    p.zip,
    p.property_type,
    p.beds,
    p.baths,
    p.sqft,
    p.year_built,

    -- Brand lens: the concierge brand shows its own marked-up price.
    COALESCE(pb.brand_price, p.list_price)          AS list_price,
    p.gross_rent_annual,
    p.opex_annual,
    p.hoa_annual,
    p.noi_annual,
    p.cap_rate,
    b.service_tier                                  AS brand_service_tier,
    b.platform_fee                                  AS brand_platform_fee,

    -- band 2 -- gated on the fee agreement
    CASE WHEN sec.can_see_address(p.property_id)
         THEN p.street_address END                  AS street_address,
    CASE WHEN sec.can_see_address(p.property_id)
         THEN p.unit END                            AS unit,
    CASE WHEN sec.can_see_address(p.property_id)
         THEN p.parcel_number END                   AS parcel_number,
    CASE WHEN sec.can_see_address(p.property_id)
         THEN p.seller_disclosure END               AS seller_disclosure,

    -- Coordinates degrade rather than disappear: ungated callers get a
    -- deterministic ~1km offset so the map still renders a neighbourhood
    -- and cannot be de-fuzzed by averaging repeated loads.
    CASE WHEN sec.can_see_address(p.property_id)
         THEN p.lat ELSE sec.jitter(p.lat, p.property_id, 'lat') END AS lat,
    CASE WHEN sec.can_see_address(p.property_id)
         THEN p.lng ELSE sec.jitter(p.lng, p.property_id, 'lng') END AS lng,
    sec.can_see_address(p.property_id)             AS address_unlocked
FROM core.property p
LEFT JOIN core.property_brand pb
       ON pb.property_id = p.property_id
      AND pb.brand_code  = sec.current_brand()
LEFT JOIN core.brand b
       ON b.brand_code   = sec.current_brand();

GRANT SELECT ON api.property
   TO sdi_public, sdi_investor, sdi_agent, sdi_admin;

-- ---------------------------------------------------------------------
-- api.property_internal -- band 3. Admin only, twice over: the view is
-- granted only to sdi_admin, AND no other role holds a column privilege
-- on the columns it reads.
-- ---------------------------------------------------------------------
CREATE VIEW api.property_internal
WITH (security_invoker = true, security_barrier = true) AS
SELECT
    p.property_id,
    p.listing_ref,
    p.acquisition_cost,
    p.source_channel,
    p.internal_notes,
    COALESCE(pb.brand_price, p.list_price) - p.acquisition_cost AS gross_margin
FROM core.property p
LEFT JOIN core.property_brand pb
       ON pb.property_id = p.property_id
      AND pb.brand_code  = sec.current_brand();

GRANT SELECT ON api.property_internal TO sdi_admin;

CREATE VIEW api.my_saved
WITH (security_invoker = true, security_barrier = true) AS
SELECT s.property_id, s.saved_at, p.listing_ref, p.city, p.state
FROM core.saved_property s
JOIN core.property p USING (property_id);

GRANT SELECT ON api.my_saved TO sdi_investor, sdi_admin;

-- ---------------------------------------------------------------------
-- Standing invariant. Must always return zero rows. Wire it into CI or a
-- nightly check -- granting USAGE on core to an app role is the one
-- change that quietly dismantles band 2 masking.
-- ---------------------------------------------------------------------
CREATE FUNCTION api.security_invariants()
RETURNS TABLE (violation text, detail text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = core, sec, pg_catalog, pg_temp
AS $inv$
SELECT 'schema core reachable by app role'::text AS violation,
       r.rolname::text AS detail
FROM pg_roles r
WHERE r.rolname IN ('sdi_public','sdi_investor','sdi_agent')
  AND has_schema_privilege(r.rolname, 'core', 'USAGE')
UNION ALL
SELECT 'internal column readable by non-admin', r.rolname || '.' || c
FROM pg_roles r,
     unnest(ARRAY['acquisition_cost','source_channel','internal_notes']) c
WHERE r.rolname IN ('sdi_public','sdi_investor','sdi_agent')
  AND has_column_privilege(r.rolname, 'core.property', c, 'SELECT')
UNION ALL
SELECT 'RLS disabled on protected table', c.relname::text
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'core' AND c.relkind = 'r' AND NOT c.relrowsecurity
UNION ALL
SELECT 'view is not security_invoker', c.relname::text
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'api' AND c.relkind = 'v'
  AND NOT COALESCE((SELECT option_value = 'true'
                    FROM pg_options_to_table(c.reloptions)
                    WHERE option_name = 'security_invoker'), false);
$inv$;

REVOKE ALL ON FUNCTION api.security_invariants() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.security_invariants() TO sdi_admin;

-- ---------------------------------------------------------------------
-- Write path for saved properties. SECURITY DEFINER because app roles
-- hold no USAGE on core -- but person_id is taken from session context,
-- never from an argument, so the caller cannot act as anyone else. The
-- visibility check re-reads through api.property, so an investor cannot
-- save a listing their own RLS policy hides.
-- ---------------------------------------------------------------------
CREATE FUNCTION api.save_property(p_property_id uuid) RETURNS boolean
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $fn$
DECLARE v_actor uuid := sec.actor_id();
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '28000';
  END IF;
  -- Deliberately NOT "SELECT FROM api.property". Inside a SECURITY DEFINER
  -- function the effective user is the owner, so the view's RLS would be
  -- evaluated as the owner and pass for every row. Call the shared
  -- predicate the policy itself uses instead.
  IF NOT sec.property_visible_to_investor(p_property_id) THEN
    RAISE EXCEPTION 'property not visible to this session' USING ERRCODE = '42501';
  END IF;
  INSERT INTO core.saved_property (person_id, property_id)
  VALUES (v_actor, p_property_id)
  ON CONFLICT DO NOTHING;
  RETURN true;
END $fn$;

REVOKE ALL ON FUNCTION api.save_property(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.save_property(uuid) TO sdi_investor;
