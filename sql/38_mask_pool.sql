-- =====================================================================
-- 38_mask_pool.sql  |  a pool of masks, not one mask
-- =====================================================================
-- The rule: an unapproved caller sees a masked image that has nothing to
-- do with the property, EVEN WHEN the property has photographs of its own.
-- Not its own photograph watermarked -- a different house entirely.
--
-- That distinction is the whole point. A watermark over the real exterior
-- still shows the real exterior: the roofline, the street trees, the
-- neighbour's fence. Anyone who has driven the block recognises it, and a
-- reverse image search does not read watermarks. Substituting a different
-- property discloses nothing at all, which is what "masked" has to mean if
-- it is to mean anything.
--
-- WHY THE ASSIGNMENT IS STABLE RATHER THAN RE-ROLLED PER REQUEST. A card
-- whose picture changes on every page load reads as a broken image, defeats
-- browser caching, and makes the grid flicker while somebody scrolls. So a
-- property is paired with a mask by hashing its id: unpredictable from the
-- outside, identical on every load, and -- this is the part that matters --
-- carrying no information, because the mask is a photograph of a different
-- house whichever one is drawn.

BEGIN;

CREATE TABLE core.mask_image (
    mask_id     integer PRIMARY KEY,
    url         text NOT NULL,
    thumb_url   text,
    caption     text,
    active      boolean NOT NULL DEFAULT true,
    added_at    timestamptz NOT NULL DEFAULT now(),
    note        text
);

COMMENT ON TABLE core.mask_image IS
    'Stand-in photographs shown in place of a withheld gallery. Each is a '
    'real interior or exterior carrying the operator''s branding, and none '
    'is a photograph of the property it is shown for.';

INSERT INTO core.mask_image (mask_id, url, thumb_url, note)
SELECT n,
       '/assets/mask/mask_'       || lpad(n::text, 2, '0') || '.jpg',
       '/assets/thumb/mask/mask_' || lpad(n::text, 2, '0') || '.jpg',
       'Placeholder until the branded image is dropped at this path.'
FROM generate_series(1, 6) AS n;

ALTER TABLE core.mask_image ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.mask_image FORCE  ROW LEVEL SECURITY;
CREATE POLICY mask_read  ON core.mask_image FOR SELECT USING (true);
CREATE POLICY mask_write ON core.mask_image FOR ALL TO sdi_admin
  USING (sec.is_internal()) WITH CHECK (sec.is_internal());
GRANT SELECT ON core.mask_image TO sdi_public, sdi_investor, sdi_agent, sdi_admin;
GRANT INSERT, UPDATE, DELETE ON core.mask_image TO sdi_admin;

-- ---------------------------------------------------------------------
-- Which mask this property wears
--
-- hashtextextended rather than random(): the same property gets the same
-- mask on every load, and a caller cannot tell from the picture which
-- property they are looking at -- both of which are true of a hash and
-- neither of which is true of a value that changes per request.
--
-- Falls back to sec.disclosure.mask_url when the pool is empty, so an
-- operator who deactivates every mask gets the single stand-in rather
-- than a listing with no picture at all.
-- ---------------------------------------------------------------------
CREATE FUNCTION sec.mask_for(p_property_id uuid)
RETURNS TABLE (url text, thumb_url text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $$
  WITH pool AS (
    SELECT m.url, m.thumb_url,
           row_number() OVER (ORDER BY m.mask_id) - 1 AS n,
           count(*)     OVER ()                       AS total
      FROM core.mask_image m WHERE m.active
  )
  SELECT p.url, p.thumb_url
    FROM pool p
   WHERE p.n = abs(hashtextextended(p_property_id::text, 0)) % p.total
  UNION ALL
  SELECT d.mask_url, d.mask_thumb
    FROM sec.disclosure d
   WHERE NOT EXISTS (SELECT 1 FROM core.mask_image WHERE active)
  LIMIT 1;
$$;

REVOKE ALL ON FUNCTION sec.mask_for(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sec.mask_for(uuid)
    TO sdi_public, sdi_investor, sdi_agent, sdi_admin, sdi_integration;

-- ---------------------------------------------------------------------
-- The view draws from the pool
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
SELECT p.property_id, p.property_id, mk.url, mk.thumb_url,
       'Not this property. Photographs are released when the agreement is signed.',
       0, true, false
FROM api.property p
CROSS JOIN LATERAL sec.mask_for(p.property_id) mk
WHERE NOT EXISTS (SELECT 1 FROM core.property_media m
                   WHERE m.property_id = p.property_id
                     AND m.state = 'published');

COMMIT;
