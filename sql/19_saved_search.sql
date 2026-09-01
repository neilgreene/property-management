-- =====================================================================
-- 19_saved_search.sql  |  saved searches and the favourites card view
-- =====================================================================
-- A saved search is a named set of filter criteria an investor can come
-- back to. Two decisions worth stating.
--
-- 1. Criteria are stored as jsonb, not as columns. The filter set will
--    grow -- map bounds, property type, cap-rate floor -- and each
--    addition would otherwise be a migration. The cost of jsonb is that
--    it accepts anything, so:
--
-- 2. The keys are constrained here, at the table. The application also
--    allowlists filter names before it builds SQL, but a stored search is
--    replayed later, possibly by different code. Something that cannot be
--    stored cannot be replayed. Values are still the application's job to
--    bind -- this constraint bounds the shape, not the contents.
--
-- Saved searches are private. Not band 2, not staff-visible: what an
-- investor is hunting for is their own business, so the policy is owner
-- equality with no admin override.

BEGIN;

CREATE TABLE core.saved_search (
    search_id    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    person_id    uuid NOT NULL REFERENCES core.person(person_id) ON DELETE CASCADE,
    name         text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 80),
    criteria     jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at   timestamptz NOT NULL DEFAULT now(),
    last_run_at  timestamptz,
    run_count    integer NOT NULL DEFAULT 0,
    UNIQUE (person_id, name),

    CONSTRAINT saved_search_criteria_object
        CHECK (jsonb_typeof(criteria) = 'object'),

    -- The allowlist, as a pure expression: strip every known key and
    -- what remains must be empty. (A CHECK cannot contain a subquery, so
    -- jsonb_object_keys is not available here -- the `-` operator is.)
    CONSTRAINT saved_search_known_keys CHECK (
        criteria - ARRAY['q','city','state','property_type','status',
                         'min_price','max_price',
                         'min_beds','max_beds',
                         'min_baths','max_baths',
                         'min_sqft','max_sqft',
                         'sort'] = '{}'::jsonb
    ),

    -- Bound the size too. A criteria blob is a handful of scalars; a
    -- megabyte of it is an attempt at something else.
    CONSTRAINT saved_search_small CHECK (length(criteria::text) <= 2000)
);

CREATE INDEX ix_saved_search_person ON core.saved_search (person_id, created_at DESC);

ALTER TABLE core.saved_search ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.saved_search FORCE  ROW LEVEL SECURITY;

CREATE POLICY saved_search_own ON core.saved_search
  FOR ALL
  USING      (person_id = sec.actor_id())
  WITH CHECK (person_id = sec.actor_id());

GRANT SELECT, INSERT, UPDATE, DELETE ON core.saved_search
   TO sdi_investor, sdi_agent, sdi_admin;

-- ---------------------------------------------------------------------
CREATE VIEW api.my_saved_search
WITH (security_invoker = true, security_barrier = true) AS
SELECT search_id, name, criteria, created_at, last_run_at, run_count
FROM core.saved_search
ORDER BY created_at DESC;

GRANT SELECT ON api.my_saved_search TO sdi_investor, sdi_agent, sdi_admin;

-- ---------------------------------------------------------------------
-- Favourites, as cards rather than as ids.
--
-- api.my_saved already answers "which ids did I save". The marketplace
-- needs the whole listing to draw a card, and it must be the SAME masked
-- listing the search results draw -- an address that is hidden in the
-- grid must not appear because the property was favourited. So this view
-- joins to api.property, not to core.property: the mask is inherited, not
-- reimplemented.
-- ---------------------------------------------------------------------
CREATE VIEW api.my_favorite
WITH (security_invoker = true, security_barrier = true) AS
SELECT p.*, s.saved_at
FROM core.saved_property s
JOIN api.property p ON p.property_id = s.property_id;

GRANT SELECT ON api.my_favorite TO sdi_investor, sdi_admin;

-- ---------------------------------------------------------------------
-- Write paths
-- ---------------------------------------------------------------------

-- Upsert by name: saving "Cleveland duplexes" twice updates the criteria
-- rather than failing or accumulating near-duplicates.
CREATE FUNCTION api.save_search(p_name text, p_criteria jsonb)
RETURNS uuid
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $fn$
DECLARE v_actor uuid := sec.actor_id(); v_id uuid;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '28000';
  END IF;

  INSERT INTO core.saved_search (person_id, name, criteria)
  VALUES (v_actor, btrim(p_name), coalesce(p_criteria, '{}'::jsonb))
  ON CONFLICT (person_id, name)
  DO UPDATE SET criteria = EXCLUDED.criteria
  RETURNING search_id INTO v_id;

  RETURN v_id;
END $fn$;

CREATE FUNCTION api.delete_saved_search(p_search_id uuid) RETURNS boolean
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $fn$
DECLARE v_actor uuid := sec.actor_id(); n integer;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '28000';
  END IF;
  -- Owner equality is stated here as well as in the policy. This function
  -- is SECURITY DEFINER, so the policy does not protect it.
  DELETE FROM core.saved_search
   WHERE search_id = p_search_id AND person_id = v_actor;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n > 0;
END $fn$;

-- Called when a saved search is replayed. Returns the criteria so the
-- caller gets the filters and the bookkeeping in one round trip.
CREATE FUNCTION api.run_saved_search(p_search_id uuid) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $fn$
DECLARE v_actor uuid := sec.actor_id(); v_criteria jsonb;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '28000';
  END IF;
  UPDATE core.saved_search
     SET last_run_at = now(), run_count = run_count + 1
   WHERE search_id = p_search_id AND person_id = v_actor
  RETURNING criteria INTO v_criteria;

  IF v_criteria IS NULL THEN
    RAISE EXCEPTION 'no such saved search' USING ERRCODE = '42501';
  END IF;
  RETURN v_criteria;
END $fn$;

REVOKE ALL ON FUNCTION api.save_search(text, jsonb)      FROM PUBLIC;
REVOKE ALL ON FUNCTION api.delete_saved_search(uuid)     FROM PUBLIC;
REVOKE ALL ON FUNCTION api.run_saved_search(uuid)        FROM PUBLIC;

GRANT EXECUTE ON FUNCTION api.save_search(text, jsonb)   TO sdi_investor, sdi_agent, sdi_admin;
GRANT EXECUTE ON FUNCTION api.delete_saved_search(uuid)  TO sdi_investor, sdi_agent, sdi_admin;
GRANT EXECUTE ON FUNCTION api.run_saved_search(uuid)     TO sdi_investor, sdi_agent, sdi_admin;

COMMIT;
