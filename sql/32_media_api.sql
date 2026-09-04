-- =====================================================================
-- 32_media_api.sql  |  the callable surface over the media store
-- =====================================================================
-- Every write here is SECURITY DEFINER and checks authorisation itself.
-- That is not belt-and-braces: a SECURITY DEFINER function runs as its
-- owner, so the caller's RLS does NOT apply inside it. Re-selecting from
-- a view to "check" visibility silently passes for every row. The
-- predicate has to be explicit, and it is sec.can_manage_media().

BEGIN;

-- ---------------------------------------------------------------------
-- One url, whichever kind of row it is
--
-- A seeded row carries a static url. A stored row carries a path and is
-- served through /media/file/<media_id>, which re-asks this same view, as
-- the caller, before handing over any bytes. Nothing downstream has to
-- know which kind it is looking at.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW api.property_media
WITH (security_invoker = true, security_barrier = true) AS
SELECT media_id, property_id,
       COALESCE(url, '/media/file/' || media_id)                    AS url,
       CASE WHEN thumb_url  IS NOT NULL THEN thumb_url
            WHEN thumb_path IS NOT NULL THEN '/media/file/' || media_id || '?v=thumb'
       END                                                          AS thumb_url,
       caption, position, is_primary, reveals_location
FROM core.property_media
WHERE state = 'published'
ORDER BY is_primary DESC, position;

-- Where the bytes are, for the caller who may see them.
--
-- The authorising route needs a path, and it must get it under the
-- caller's own authority. Naming core.property_media from the route does
-- not work: the reader roles hold SELECT on that table but no USAGE on
-- schema core, so the query fails for everyone except an admin -- which
-- would have made every photograph a 404 for the people it is for. A view
-- in api resolves the reference at definition time and still checks the
-- caller's privileges and policies at read time.
--
-- The paths are not themselves sensitive: a listing reference is public
-- and the media_id is already in the caller's hand. What is sensitive is
-- WHICH rows come back, and that is decided by the same policy as
-- everything else.
CREATE VIEW api.media_bytes
WITH (security_invoker = true, security_barrier = true) AS
SELECT media_id, storage_path, thumb_path
FROM core.property_media
WHERE storage_path IS NOT NULL;

-- The panel's view: every state, and the facts needed to decide what to
-- do with each. Row-level security still applies -- an agent sees their
-- own listings' photographs and nobody else's.
CREATE VIEW api.property_media_admin
WITH (security_invoker = true, security_barrier = true) AS
SELECT m.media_id, m.property_id, p.listing_ref,
       COALESCE(m.url, '/media/file/' || m.media_id)                AS url,
       CASE WHEN m.thumb_url  IS NOT NULL THEN m.thumb_url
            WHEN m.thumb_path IS NOT NULL THEN '/media/file/' || m.media_id || '?v=thumb'
       END                                                          AS thumb_url,
       m.caption, m.position, m.is_primary, m.reveals_location,
       m.state, m.original_name, m.byte_size, m.width, m.height,
       m.published_at, m.deleted_at, m.purge_after, m.legal_hold,
       m.storage_path, m.created_at
FROM core.property_media m
JOIN core.property p USING (property_id)
ORDER BY p.listing_ref, m.state, m.is_primary DESC, m.position;

GRANT SELECT ON api.property_media       TO sdi_public, sdi_investor, sdi_agent, sdi_admin;
GRANT SELECT ON api.media_bytes          TO sdi_public, sdi_investor, sdi_agent, sdi_admin;
GRANT SELECT ON api.property_media_admin TO sdi_agent, sdi_admin;

-- ---------------------------------------------------------------------
-- Which property is this folder about
--
-- The scanner cannot read core.property. Every policy on that table is
-- scoped TO a named application role, and sdi_integration is not one of
-- them, so a direct SELECT returns zero rows -- not an error, which is
-- worse: the scanner reported every folder as an unknown listing and
-- looked like it was working. This is the way in, and it authorises
-- explicitly rather than relying on a grant that does not apply.
-- ---------------------------------------------------------------------
CREATE FUNCTION api.listing_id(p_listing_ref text) RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $fn$
DECLARE v_id uuid;
BEGIN
  IF NOT sec.is_internal() THEN
    RAISE EXCEPTION 'not authorised' USING ERRCODE = '42501';
  END IF;
  SELECT property_id INTO v_id FROM core.property
   WHERE upper(listing_ref) = upper(p_listing_ref);
  RETURN v_id;
END;
$fn$;

-- ---------------------------------------------------------------------
-- Register: a file has landed in the store
--
-- Called by the ingest scanner after the bytes are validated, re-encoded
-- and written. It creates a PENDING row: not on the listing, not served,
-- and reveals_location TRUE until a person says otherwise.
-- ---------------------------------------------------------------------
CREATE FUNCTION api.media_register(
    p_property_id  uuid,
    p_sha256       bytea,
    p_bytes        integer,
    p_width        integer,
    p_height       integer,
    p_original     text,
    OUT out_media_id     uuid,
    OUT out_storage_path text,
    OUT out_thumb_path   text)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = core, sec, api, pg_temp
AS $fn$
DECLARE v_ref text; v_dupe record;
BEGIN
  -- One predicate, no special cases. The unattended scanner authorises the
  -- same way a person does, by holding an actor -- the media ingest service
  -- account created in 31_media_store.sql. An earlier version exempted the
  -- sdi_integration connection role by name instead; that could not be
  -- tested without connecting as that exact role, and a rule that cannot be
  -- tested is a rule nobody knows is still working.
  IF NOT sec.can_manage_media(p_property_id) THEN
    RAISE EXCEPTION 'not authorised to add media to this property'
      USING ERRCODE = '42501';
  END IF;

  -- The same photograph arriving twice is the normal case, not the rare
  -- one: a re-copied folder, a retried scan. Return the row that already
  -- exists rather than failing, so a re-run is harmless.
  SELECT media_id, storage_path, thumb_path INTO v_dupe
    FROM core.property_media
   WHERE property_id = p_property_id AND content_sha256 = p_sha256
     AND state <> 'purged';
  IF FOUND THEN
    out_media_id     := v_dupe.media_id;
    out_storage_path := v_dupe.storage_path;
    out_thumb_path   := v_dupe.thumb_path;
    RETURN;
  END IF;

  SELECT listing_ref INTO v_ref FROM core.property WHERE property_id = p_property_id;

  -- The id is generated here so the path can be built from it, which is
  -- the point: the filename IS the primary key. Somebody holding a file
  -- identifies it with one query and no lookup table. Deciding the path
  -- here rather than in the caller also means one place knows the
  -- convention, so a second ingest route cannot invent a different one.
  out_media_id     := gen_random_uuid();
  out_storage_path := 'store/' || v_ref || '/' || out_media_id || '-orig.jpg';
  out_thumb_path   := 'store/' || v_ref || '/' || out_media_id || '-720.jpg';

  INSERT INTO core.property_media
    (media_id, property_id, url, storage_path, thumb_path, content_sha256,
     byte_size, width, height, original_name, caption, position, is_primary,
     reveals_location, state, created_by)
  VALUES
    (out_media_id, p_property_id, NULL, out_storage_path, out_thumb_path,
     p_sha256, p_bytes, p_width, p_height, p_original, NULL,
     COALESCE((SELECT max(position) + 1 FROM core.property_media
                WHERE property_id = p_property_id), 10),
     false,
     true,          -- fail closed. An unclassified photograph is assumed
                    -- to identify the property until a human says not.
     'pending', sec.actor_id());

  PERFORM core.log_media(out_media_id, p_property_id, 'registered',
                         jsonb_build_object('original', p_original,
                                            'bytes', p_bytes));
END;
$fn$;

-- ---------------------------------------------------------------------
-- Assign: what this photograph is
-- ---------------------------------------------------------------------
CREATE FUNCTION api.media_assign(
    p_media_id uuid,
    p_caption  text DEFAULT NULL,
    p_position integer DEFAULT NULL)
RETURNS boolean
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = core, sec, api, pg_temp
AS $fn$
DECLARE v_prop uuid;
BEGIN
  SELECT property_id INTO v_prop FROM core.property_media WHERE media_id = p_media_id;
  IF v_prop IS NULL OR NOT sec.can_manage_media(v_prop) THEN
    RAISE EXCEPTION 'not authorised' USING ERRCODE = '42501';
  END IF;

  UPDATE core.property_media
     SET caption  = COALESCE(p_caption,  caption),
         position = COALESCE(p_position, position)
   WHERE media_id = p_media_id;

  PERFORM core.log_media(p_media_id, v_prop, 'assigned',
                         jsonb_build_object('caption', p_caption,
                                            'position', p_position));
  RETURN true;
END;
$fn$;

-- ---------------------------------------------------------------------
-- The gate, as an operation
--
-- Only an admin. And un-gating is one-way in the sense that matters:
-- anyone shown the photograph has it, and re-gating does not take it
-- back. So it is logged as its own action rather than folded into a
-- general update.
-- ---------------------------------------------------------------------
CREATE FUNCTION api.media_set_gated(p_media_id uuid, p_gated boolean)
RETURNS boolean
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = core, sec, api, pg_temp
AS $fn$
DECLARE v_prop uuid; v_was boolean;
BEGIN
  SELECT property_id, reveals_location INTO v_prop, v_was
    FROM core.property_media WHERE media_id = p_media_id;
  IF v_prop IS NULL THEN RETURN false; END IF;

  IF NOT p_gated AND NOT sec.is_internal() THEN
    RAISE EXCEPTION 'releasing a location-revealing photograph is an admin decision'
      USING ERRCODE = '42501';
  END IF;
  IF NOT sec.can_manage_media(v_prop) THEN
    RAISE EXCEPTION 'not authorised' USING ERRCODE = '42501';
  END IF;

  UPDATE core.property_media SET reveals_location = p_gated WHERE media_id = p_media_id;

  IF v_was IS DISTINCT FROM p_gated THEN
    PERFORM core.log_media(p_media_id, v_prop,
                           CASE WHEN p_gated THEN 'gated' ELSE 'ungated' END);
  END IF;
  RETURN true;
END;
$fn$;

-- ---------------------------------------------------------------------
-- The KEY image
--
-- ux_media_primary is a unique index on (property_id) WHERE is_primary,
-- so the sitting primary steps aside BEFORE the new one takes it. Doing
-- it the other way round fails, which is how this was written the first
-- time in 30_stock_media.sql.
-- ---------------------------------------------------------------------
CREATE FUNCTION api.media_set_primary(p_media_id uuid)
RETURNS boolean
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = core, sec, api, pg_temp
AS $fn$
DECLARE v_prop uuid; v_state core.media_state; v_gated boolean;
BEGIN
  SELECT property_id, state, reveals_location INTO v_prop, v_state, v_gated
    FROM core.property_media WHERE media_id = p_media_id;
  IF v_prop IS NULL OR NOT sec.can_manage_media(v_prop) THEN
    RAISE EXCEPTION 'not authorised' USING ERRCODE = '42501';
  END IF;
  IF v_state <> 'published' THEN
    RAISE EXCEPTION 'an unpublished photograph cannot be the card image';
  END IF;
  -- A gated photograph as the card image would put the property's
  -- identity on the search results page for everyone. The card is the
  -- one image an ungated visitor always sees.
  IF v_gated THEN
    RAISE EXCEPTION 'a location-revealing photograph cannot be the card image';
  END IF;

  UPDATE core.property_media SET is_primary = false
   WHERE property_id = v_prop AND is_primary;
  UPDATE core.property_media SET is_primary = true
   WHERE media_id = p_media_id;

  PERFORM core.log_media(p_media_id, v_prop, 'assigned',
                         jsonb_build_object('is_primary', true));
  RETURN true;
END;
$fn$;

-- ---------------------------------------------------------------------
-- Publish / unpublish
--
-- Unpublish is immediate and reversible. Destruction is separate and
-- later: purge_after is set here, and nothing removes bytes until it
-- passes and no hold is in force.
-- ---------------------------------------------------------------------
CREATE FUNCTION api.media_publish(p_media_ids uuid[])
RETURNS integer
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = core, sec, api, pg_temp
AS $fn$
DECLARE r record; n integer := 0;
BEGIN
  FOR r IN SELECT media_id, property_id FROM core.property_media
            WHERE media_id = ANY(p_media_ids) AND state IN ('pending','unpublished')
  LOOP
    IF NOT sec.can_manage_media(r.property_id) THEN
      RAISE EXCEPTION 'not authorised for %', r.property_id USING ERRCODE = '42501';
    END IF;
    UPDATE core.property_media
       SET state = 'published', published_at = now(),
           deleted_at = NULL, purge_after = NULL
     WHERE media_id = r.media_id;
    PERFORM core.log_media(r.media_id, r.property_id, 'published');
    n := n + 1;
  END LOOP;
  RETURN n;
END;
$fn$;

CREATE FUNCTION api.media_unpublish(p_media_ids uuid[], p_reason text,
                                    p_retain_days integer DEFAULT 30)
RETURNS integer
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = core, sec, api, pg_temp
AS $fn$
DECLARE r record; n integer := 0;
BEGIN
  FOR r IN SELECT media_id, property_id FROM core.property_media
            WHERE media_id = ANY(p_media_ids) AND state <> 'purged'
  LOOP
    IF NOT sec.can_manage_media(r.property_id) THEN
      RAISE EXCEPTION 'not authorised for %', r.property_id USING ERRCODE = '42501';
    END IF;
    UPDATE core.property_media
       SET state = 'unpublished', is_primary = false, deleted_at = now(),
           purge_after = current_date + p_retain_days
     WHERE media_id = r.media_id;
    PERFORM core.log_media(r.media_id, r.property_id, 'unpublished',
                           jsonb_build_object('reason', p_reason,
                                              'retain_days', p_retain_days));
    n := n + 1;
  END LOOP;
  RETURN n;
END;
$fn$;

-- ---------------------------------------------------------------------
-- Legal hold
-- ---------------------------------------------------------------------
CREATE FUNCTION api.media_set_hold(p_media_id uuid, p_hold boolean, p_reason text)
RETURNS boolean
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = core, sec, api, pg_temp
AS $fn$
DECLARE v_prop uuid;
BEGIN
  IF NOT sec.is_internal() THEN
    RAISE EXCEPTION 'legal hold is an admin decision' USING ERRCODE = '42501';
  END IF;
  SELECT property_id INTO v_prop FROM core.property_media WHERE media_id = p_media_id;
  IF v_prop IS NULL THEN RETURN false; END IF;
  UPDATE core.property_media SET legal_hold = p_hold WHERE media_id = p_media_id;
  PERFORM core.log_media(p_media_id, v_prop,
                         CASE WHEN p_hold THEN 'held' ELSE 'released' END,
                         jsonb_build_object('reason', p_reason));
  RETURN true;
END;
$fn$;

-- ---------------------------------------------------------------------
-- What the purge job may destroy
--
-- Returns rows, and destroys nothing. The caller removes the bytes and
-- then calls media_purged() to record it -- in that order, so a crash
-- between the two leaves a file to be found again rather than a row
-- claiming a file that is gone.
-- ---------------------------------------------------------------------
CREATE FUNCTION api.media_purge_due()
RETURNS TABLE (media_id uuid, storage_path text, thumb_path text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $$
  SELECT m.media_id, m.storage_path, m.thumb_path
    FROM core.property_media m
   WHERE sec.is_internal()
     AND m.state = 'unpublished'
     AND NOT m.legal_hold
     AND m.purge_after IS NOT NULL
     AND m.purge_after <= current_date
     AND m.storage_path IS NOT NULL;
$$;

CREATE FUNCTION api.media_purged(p_media_id uuid)
RETURNS boolean
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = core, sec, api, pg_temp
AS $fn$
DECLARE v_prop uuid;
BEGIN
  IF NOT sec.is_internal() THEN
    RAISE EXCEPTION 'not authorised' USING ERRCODE = '42501';
  END IF;
  SELECT property_id INTO v_prop FROM core.property_media WHERE media_id = p_media_id;
  IF v_prop IS NULL THEN RETURN false; END IF;
  UPDATE core.property_media
     SET state = 'purged', storage_path = NULL, thumb_path = NULL,
         url = COALESCE(url, '/media/purged'), content_sha256 = NULL
   WHERE media_id = p_media_id;
  PERFORM core.log_media(p_media_id, v_prop, 'purged');
  RETURN true;
END;
$fn$;

-- ---------------------------------------------------------------------
-- Reconciliation input: every path the database believes exists
-- ---------------------------------------------------------------------
CREATE FUNCTION api.media_paths()
RETURNS TABLE (media_id uuid, storage_path text, thumb_path text, state core.media_state)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $$
  SELECT m.media_id, m.storage_path, m.thumb_path, m.state
    FROM core.property_media m
   WHERE sec.is_internal() AND m.storage_path IS NOT NULL;
$$;

REVOKE ALL ON FUNCTION
    api.media_register(uuid,bytea,integer,integer,integer,text),
    api.media_assign(uuid,text,integer),
    api.media_set_gated(uuid,boolean),
    api.media_set_primary(uuid),
    api.media_publish(uuid[]),
    api.media_unpublish(uuid[],text,integer),
    api.media_set_hold(uuid,boolean,text),
    api.media_purge_due(),
    api.media_purged(uuid),
    api.media_paths(),
    api.listing_id(text)
  FROM PUBLIC;

GRANT EXECUTE ON FUNCTION
    api.media_register(uuid,bytea,integer,integer,integer,text),
    api.media_assign(uuid,text,integer),
    api.media_set_gated(uuid,boolean),
    api.media_set_primary(uuid),
    api.media_publish(uuid[]),
    api.media_unpublish(uuid[],text,integer)
  TO sdi_agent, sdi_admin;

GRANT EXECUTE ON FUNCTION
    api.media_set_hold(uuid,boolean,text),
    api.media_purge_due(),
    api.media_purged(uuid),
    api.media_paths()
  TO sdi_admin;

-- The worker's connection role. It registers, reconciles and purges --
-- the unattended jobs -- and is deliberately NOT granted media_publish:
-- a scanner that can publish defeats the review step entirely, which is
-- the one thing standing between a dropped file and a live listing.
--
-- Two independent controls apply to the destructive ones. The GRANT here,
-- and sec.is_internal() inside the function, which requires an admin
-- actor. Losing either alone is not enough.
GRANT USAGE ON SCHEMA api TO sdi_integration;
GRANT EXECUTE ON FUNCTION
    api.listing_id(text),
    api.media_register(uuid,bytea,integer,integer,integer,text),
    api.media_paths(),
    api.media_purge_due(),
    api.media_purged(uuid)
  TO sdi_integration;
GRANT EXECUTE ON FUNCTION api.listing_id(text) TO sdi_agent, sdi_admin;

COMMIT;
