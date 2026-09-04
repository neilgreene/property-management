-- =====================================================================
-- 36_media_masking.sql  |  one masked image until access is granted
-- =====================================================================
-- Photographs join the address and the map in band 2. Until now only the
-- exterior was gated, on the reasoning that a front elevation identifies a
-- house and an interior does not. The business decision is now stricter:
-- no photographs at all until access is granted, and a single masked image
-- in their place.
--
-- Which is right for more than tidiness. Interiors identify a property to
-- anybody who has walked it, an agent recognises a kitchen, and a
-- reverse image search does not care which room it is. "Interiors are
-- safe" was always an assumption rather than a fact.
--
-- ENFORCED IN THE ROW POLICY, NOT IN THE VIEW. Masking only in the view
-- would leave core.property_media readable by any caller who could reach
-- the table, which is every reader role. The policy decides who gets a row
-- at all; the view then supplies the mask where there is nothing to show,
-- so a listing still has a picture and the page still has a shape.
--
-- The predicate is sec.can_see_address(), the same one that releases the
-- street address and the map pin. One question -- has this caller been
-- granted this property -- answered once. Internal staff, the assigned
-- agent or lender, and an investor whose agreement is on file.

BEGIN;

ALTER TABLE sec.disclosure
    ADD COLUMN media_mode text NOT NULL DEFAULT 'masked'
        CHECK (media_mode IN ('masked', 'exterior_only')),
    ADD COLUMN mask_url   text NOT NULL DEFAULT '/assets/masked.jpg',
    ADD COLUMN mask_thumb text NOT NULL DEFAULT '/assets/thumb/masked.jpg';

COMMENT ON COLUMN sec.disclosure.media_mode IS
    'masked: no photographs until sec.can_see_address(). exterior_only: the '
    'older rule, where only images flagged reveals_location were withheld.';
COMMENT ON COLUMN sec.disclosure.mask_url IS
    'The stand-in shown in place of a withheld gallery. Replacing the file '
    'at this path changes every listing at once; no rebuild.';

CREATE FUNCTION sec.media_mode() RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = sec, pg_temp
AS $$ SELECT media_mode FROM sec.disclosure WHERE id $$;

CREATE FUNCTION sec.mask_url() RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = sec, pg_temp
AS $$ SELECT mask_url FROM sec.disclosure WHERE id $$;

CREATE FUNCTION sec.mask_thumb() RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = sec, pg_temp
AS $$ SELECT mask_thumb FROM sec.disclosure WHERE id $$;

REVOKE ALL ON FUNCTION sec.media_mode(), sec.mask_url(), sec.mask_thumb() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sec.media_mode(), sec.mask_url(), sec.mask_thumb()
    TO sdi_public, sdi_investor, sdi_agent, sdi_admin, sdi_integration;

-- ---------------------------------------------------------------------
-- The row policy, with the gate widened from the exterior to the gallery
-- ---------------------------------------------------------------------
DROP POLICY property_media_read ON core.property_media;
CREATE POLICY property_media_read ON core.property_media
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM api.property v
             WHERE v.property_id = core.property_media.property_id)
    AND (state = 'published' OR sec.can_manage_media(core.property_media.property_id))
    AND CASE
          WHEN sec.can_manage_media(core.property_media.property_id) THEN true
          WHEN sec.media_mode() = 'masked'
            THEN sec.can_see_address(core.property_media.property_id)
          ELSE NOT reveals_location
                 OR sec.can_see_address(core.property_media.property_id)
        END
  );

-- ---------------------------------------------------------------------
-- The view supplies the mask where the policy left nothing
--
-- A listing with no visible photographs gets exactly one synthetic row.
-- Its media_id is the property_id: stable across reloads, so the client
-- can key on it, and deliberately not the id of any real row -- there is
-- no file behind it and /media/file/ will not serve it.
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
UNION ALL
SELECT p.property_id, p.property_id,
       sec.mask_url(), sec.mask_thumb(),
       'Photographs are released when the agreement is signed',
       0, true, false
FROM api.property p
WHERE NOT EXISTS (SELECT 1 FROM core.property_media m
                   WHERE m.property_id = p.property_id
                     AND m.state = 'published');

COMMIT;
