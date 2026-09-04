-- =====================================================================
-- 30_stock_media.sql  |  supplied photography as the card image
-- =====================================================================
-- Twenty-five photographs were supplied and placed in web/public/assets.
-- This points each listing at one.
--
-- THE THING THAT DECIDES EVERYTHING ELSE HERE: these are not photographs
-- of these properties. They are representative images. That single fact
-- settles two questions that would otherwise be judgement calls.
--
--   reveals_location is FALSE. The whole point of that flag is that a
--   photograph of a house identifies it. A photograph of a DIFFERENT
--   house identifies nothing, so gating it would withhold something that
--   protects nobody -- and would teach the next person that the flag
--   means "exterior" when it means "identifying".
--
--   The caption says so. A stock exterior presented without qualification
--   reads as a picture of the property, which is a small deception that
--   compounds: an investor who drives past and finds a different house
--   stops trusting the numbers too.
--
-- The generated illustration stays as the fallback for anything without a
-- photograph, and the generated `front` stays gated, because it stands in
-- for the real exterior that does not exist yet.
--
-- Each row carries two files: the supplied 1280px original in `url`, and a
-- 720px copy in `thumb_url`. Twenty-five cards on one page came to 9.4 MB
-- of the former and 2.1 MB of the latter, which is the whole reason the
-- second column exists. Both are the same picture, so both are released or
-- withheld together -- the thumbnail is not a way around a gated image.

BEGIN;

-- ---------------------------------------------------------------------
-- The instrument
--
-- Recorded UNREVIEWED because where these came from has not been
-- established. That is not a formality: an Unsplash or Pexels licence
-- permits commercial use without attribution, a Getty comp does not, and
-- an MLS photograph is the listing broker's. Same pixels, three very
-- different answers, and the difference only shows up in a demand letter.
-- ---------------------------------------------------------------------
INSERT INTO gov.data_right
 (right_id, name, grantor, instrument, reference, survives_termination,
  review_status, notes) VALUES
 ('STOCK-PHOTOGRAPHY','Supplied listing photography','Operator (source unestablished)',
  'owner_consent','web/public/assets/property_01..25.jpg', false, 'unreviewed',
  'Supplied by the operator and placed in the repository. The source and licence '
  'are NOT established. Confirm before any public launch: a stock licence that '
  'permits commercial use without attribution, a licence that requires '
  'attribution, and a listing photograph belonging to a broker are three '
  'different positions that look identical on disk.')
ON CONFLICT (right_id) DO NOTHING;

INSERT INTO gov.data_right_territory (right_id, territory_id)
VALUES ('STOCK-PHOTOGRAPHY','US') ON CONFLICT DO NOTHING;

-- Narrow, and unclear where it is unclear. gov.may_use() honours only
-- counsel-confirmed rights, so nothing here grants anything yet.
INSERT INTO gov.data_right_use (right_id, use_code, posture, condition) VALUES
 ('STOCK-PHOTOGRAPHY','internal_analysis','granted',NULL),
 ('STOCK-PHOTOGRAPHY','gated_display','unclear','Turns on the licence'),
 ('STOCK-PHOTOGRAPHY','public_display','unclear','Turns on the licence'),
 ('STOCK-PHOTOGRAPHY','derive','unclear',NULL),
 ('STOCK-PHOTOGRAPHY','redistribute','refused',NULL),
 ('STOCK-PHOTOGRAPHY','export','refused',NULL),
 ('STOCK-PHOTOGRAPHY','marketing','unclear','The use most licences price separately'),
 ('STOCK-PHOTOGRAPHY','model_training','refused',NULL)
ON CONFLICT DO NOTHING;

INSERT INTO gov.obligation (right_id, kind, detail, enforcement) VALUES
 ('STOCK-PHOTOGRAPHY','notice',
  'Establish the source and licence of property_01..25.jpg before public launch. '
  'If attribution is required, it must appear wherever the image does.',
  'procedural'),
 ('STOCK-PHOTOGRAPHY','display_restriction',
  'Every use must be captioned as representative. These are not photographs of '
  'the properties they illustrate.',
  'procedural');

-- ---------------------------------------------------------------------
-- One photograph per listing, in listing_ref order
--
-- Deterministic rather than random so a rebuild produces the same
-- pairing: a listing whose picture changes on every deploy looks broken
-- even when nothing is.
-- ---------------------------------------------------------------------
-- ux_media_primary is a unique index on (property_id) WHERE is_primary, so
-- the sitting primary has to step aside BEFORE the new one is inserted --
-- not after. Doing it the other way round fails on the first row, which
-- is how this was written the first time.
UPDATE core.property_media m SET is_primary = false
 WHERE m.is_primary
   AND m.property_id IN (
       SELECT property_id FROM (
           SELECT property_id, row_number() OVER (ORDER BY listing_ref) AS n
           FROM core.property) q
        WHERE q.n <= 25);

-- One photograph per listing, in listing_ref order. Deterministic rather
-- than random so a rebuild produces the same pairing: a listing whose
-- picture changes on every deploy looks broken even when nothing is.
WITH numbered AS (
    SELECT property_id,
           row_number() OVER (ORDER BY listing_ref) AS n
    FROM core.property
)
INSERT INTO core.property_media
 (property_id, url, thumb_url, caption, position, is_primary, reveals_location)
SELECT n.property_id,
       '/assets/property_'       || lpad(n.n::text, 2, '0') || '.jpg',
       '/assets/thumb/property_' || lpad(n.n::text, 2, '0') || '.jpg',
       'Representative photo — not the actual property',
       -1,        -- ahead of the generated images
       true,
       false
FROM numbered n
WHERE n.n <= 25
  AND NOT EXISTS (SELECT 1 FROM core.property_media m
                   WHERE m.property_id = n.property_id AND m.position = -1);

INSERT INTO gov.property_provenance (property_id, right_id, scope)
SELECT DISTINCT property_id, 'STOCK-PHOTOGRAPHY', 'media'
FROM core.property_media WHERE position = -1
ON CONFLICT DO NOTHING;

COMMIT;
