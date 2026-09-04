-- =====================================================================
-- 33_interior_media.sql  |  real interiors in place of the drawings
-- =====================================================================
-- 30_stock_media.sql gave every listing one supplied photograph as its
-- card image. Behind it, the gallery was still three generated
-- illustrations -- a drawn living room, kitchen and bedroom -- which
-- looked odd sitting immediately after a real photograph.
--
-- Seventy-five interiors were supplied, three per listing, named for the
-- listing they belong to: property_07_living.jpg and so on. The number in
-- the filename is the listing's position in listing_ref order, which is
-- the same pairing 30_stock_media.sql used for the exteriors -- so a
-- listing's card and its interiors stay together across a rebuild.
--
-- Same two facts as the exteriors, and they still decide everything:
--
--   These are not photographs of these properties, so reveals_location is
--   FALSE. The flag means IDENTIFYING, not INTERIOR. A photograph of a
--   different kitchen identifies nothing.
--
--   Every caption says so. A stock interior presented without
--   qualification reads as a picture of the property, and an investor who
--   walks the house and finds a different kitchen stops trusting the
--   numbers too.
--
-- These are static assets in the container image, like the exteriors --
-- NOT rows in the media store built in 31/32. That is deliberate: the
-- store is for operational photography that staff add and manage, and
-- mixing a demo seed into it would make the store's contents a mixture of
-- things that can be purged and things that would come back on the next
-- deploy.

BEGIN;

-- The generated interiors, removed.
DELETE FROM core.property_media
 WHERE position IN (2, 3, 4)
   AND url LIKE '/media/%';

-- And the generated hero at position 0. It was the card image until
-- 30_stock_media put a photograph in front of it; since then it has been a
-- drawing sitting between a real photograph and three real interiors,
-- which reads as a broken image rather than a placeholder. The renderer
-- still draws one on demand -- app.js falls back to it when a file will
-- not load -- so nothing loses its safety net.
--
-- Matched on the url, not the position: 108 Fairgrove's position 0 is a
-- real front elevation that is gated, and deleting it would remove the
-- only genuinely location-revealing image in the system.
DELETE FROM core.property_media
 WHERE url LIKE '/media/%/hero.svg';

WITH numbered AS (
    SELECT property_id,
           row_number() OVER (ORDER BY listing_ref) AS n
    FROM core.property
), rooms(position, slug, caption) AS (
    VALUES (2, 'living',  'Living area'),
           (3, 'kitchen', 'Kitchen'),
           (4, 'bedroom', 'Primary bedroom')
)
INSERT INTO core.property_media
 (property_id, url, thumb_url, caption, position, is_primary,
  reveals_location, state)
SELECT n.property_id,
       '/assets/property_'       || lpad(n.n::text, 2, '0') || '_' || r.slug || '.jpg',
       '/assets/thumb/property_' || lpad(n.n::text, 2, '0') || '_' || r.slug || '.jpg',
       r.caption || ' — representative photo, not the actual property',
       r.position,
       false,
       false,
       'published'
FROM numbered n CROSS JOIN rooms r
WHERE n.n <= 25
  AND NOT EXISTS (SELECT 1 FROM core.property_media m
                   WHERE m.property_id = n.property_id
                     AND m.position = r.position);

-- Same instrument as the exteriors: same supplier, same unestablished
-- licence. Recorded rather than assumed, so the open question stays
-- visible in gov.uncovered_publication rather than quietly closing.
INSERT INTO gov.property_provenance (property_id, right_id, scope)
SELECT DISTINCT property_id, 'STOCK-PHOTOGRAPHY', 'media'
FROM core.property_media WHERE position IN (2, 3, 4)
ON CONFLICT DO NOTHING;

COMMIT;
