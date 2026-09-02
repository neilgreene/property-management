-- =====================================================================
-- 26_fairgrove_media.sql  |  a real photograph, and its provenance
-- =====================================================================
-- The operator supplied a photograph of 108 Fairgrove. It is the first
-- real image in the system, and it is worth walking through what that
-- costs, because it exercises three separate mechanisms at once.
--
-- 1. IT IS AN EXTERIOR SHOT, so reveals_location is true and it is
--    released on the same predicate as the street address. An ungated
--    visitor will not be told it exists. This is the rule from
--    18_property_detail.sql meeting its first real photograph.
--
-- 2. IT NEEDS A PROVENANCE RECORD. A listing photograph is normally the
--    copyright of the photographer or the listing broker -- not the
--    seller and not the portal it was seen on. The operator has directed
--    that it be used, which is a business decision they are entitled to
--    make; what this file does is make sure the basis for it is written
--    down and marked unreviewed, rather than the image simply appearing
--    with no record of where the right came from. That is the whole
--    point of gov.data_right: not to refuse, but to leave a trail.
--
-- 3. IT IS SERVED AS A STATIC FILE, and that is a real limitation worth
--    stating rather than glossing. Files under web/public/ are reachable
--    by anyone who guesses the path, so the database gate controls who is
--    TOLD the url, not who can fetch it. For synthetic illustrations that
--    is fine. For a genuinely location-revealing photograph it is not,
--    and before this goes anywhere public the gated media needs to move
--    behind an authorising route or signed, expiring urls. Logged in
--    section 10 of the system documentation as an open gap.

BEGIN;

-- ---------------------------------------------------------------------
-- The right
-- ---------------------------------------------------------------------
INSERT INTO gov.data_right
 (right_id, name, grantor, instrument, source_code, reference,
  effective_from, effective_to, survives_termination,
  review_status, notes) VALUES
 ('OPERATOR-SUPPLIED','Media supplied by the operator','SDI operator','owner_consent',
  NULL,'Supplied directly by the operator for 108 Fairgrove, Irvine CA',
  current_date, NULL, false,
  'unreviewed',
  'The operator supplied this image and directed its use. What is NOT established is '
  'who holds the copyright -- for a listing photograph that is usually the photographer '
  'or the listing broker, and a seller''s permission does not transfer it. Confirm the '
  'chain before this image is shown outside a demonstration. Recorded as unreviewed so '
  'the question stays visible instead of dissolving into "it was already on the site".')
ON CONFLICT (right_id) DO NOTHING;

INSERT INTO gov.data_right_territory (right_id, territory_id) VALUES
 ('OPERATOR-SUPPLIED','US')
ON CONFLICT DO NOTHING;

-- Narrow on purpose. Gated display is what the product needs; onward
-- syndication and model training are exactly the uses a photographer's
-- licence would not cover, so they are refused rather than left blank.
INSERT INTO gov.data_right_use (right_id, use_code, posture, condition) VALUES
 ('OPERATOR-SUPPLIED','internal_analysis','granted',NULL),
 ('OPERATOR-SUPPLIED','gated_display','granted','Released only with the street address, per reveals_location'),
 ('OPERATOR-SUPPLIED','public_display','unclear','Not established. Treated as not granted'),
 ('OPERATOR-SUPPLIED','derive','unclear',NULL),
 ('OPERATOR-SUPPLIED','redistribute','refused',NULL),
 ('OPERATOR-SUPPLIED','export','refused',NULL),
 ('OPERATOR-SUPPLIED','marketing','refused','A listing photo in an ad is the classic infringement claim'),
 ('OPERATOR-SUPPLIED','model_training','refused',NULL)
ON CONFLICT DO NOTHING;

INSERT INTO gov.obligation (right_id, kind, detail, enforcement) VALUES
 ('OPERATOR-SUPPLIED','notice',
  'Establish who holds copyright in this photograph before any public display.',
  'procedural');

-- Media provenance for this property now points at the operator's right
-- rather than at the "no instrument" placeholder.
INSERT INTO gov.property_provenance (property_id, right_id, scope)
SELECT property_id, 'OPERATOR-SUPPLIED', 'media'
FROM core.property WHERE listing_ref = 'SDI-2001'
ON CONFLICT DO NOTHING;

DELETE FROM gov.property_provenance
 WHERE right_id = 'NONE-EXTERNAL' AND scope = 'media'
   AND property_id IN (SELECT property_id FROM core.property WHERE listing_ref = 'SDI-2001');

-- ---------------------------------------------------------------------
-- The image
-- ---------------------------------------------------------------------
INSERT INTO core.property_media
 (property_id, url, caption, position, is_primary, reveals_location)
SELECT property_id, '/assets/108-fairgrove/front.jpg',
       'Front elevation', 0, true, true
FROM core.property WHERE listing_ref = 'SDI-2001'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------
-- What the photograph itself establishes
--
-- Only what is visible in it. Two storeys, an attached garage with a
-- single and a double door, craftsman detailing, lap siding, a tile
-- roof, a covered upper balcony, a concrete driveway and mature planting.
-- Beds, baths, square footage, price and year built are NOT visible in a
-- photograph and remain null -- a photo is evidence of construction, not
-- of a floor plan.
-- ---------------------------------------------------------------------
INSERT INTO core.property_detail
 (property_id, headline, description, stories, garage_spaces, parking,
  roof_year, features)
SELECT property_id,
       'Two-storey craftsman in Irvine',
       'Two-storey detached house with attached three-car garage, craftsman '
       'detailing, lap siding and a tile roof. Covered upper balcony over the '
       'entry, concrete driveway, established planting. Financial detail and '
       'room counts are not yet on file -- see gov.property_rights for what is '
       'held and under what instrument.',
       2, 3, 'Attached garage',
       NULL,
       '["Attached garage","Covered balcony","Tile roof","Established landscaping"]'::jsonb
FROM core.property WHERE listing_ref = 'SDI-2001'
ON CONFLICT (property_id) DO UPDATE SET
  headline = EXCLUDED.headline, description = EXCLUDED.description,
  stories = EXCLUDED.stories, garage_spaces = EXCLUDED.garage_spaces,
  parking = EXCLUDED.parking, features = EXCLUDED.features,
  updated_at = now();

UPDATE core.property SET property_type = 'Single Family'
 WHERE listing_ref = 'SDI-2001';

COMMIT;
