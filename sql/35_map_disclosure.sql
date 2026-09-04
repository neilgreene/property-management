-- =====================================================================
-- 35_map_disclosure.sql  |  no map without access
-- =====================================================================
-- Until now an ungated caller got coordinates offset by roughly a
-- kilometre, so the map still drew a neighbourhood. The reasoning was that
-- a fuzzed point discloses a market, not a house.
--
-- The business decision is now stricter: the map is for callers who have
-- been granted the address, on the same predicate as the address itself.
-- Everyone else gets no coordinates at all.
--
-- HIDING THE MAP IN THE BROWSER WOULD NOT HAVE BEEN THIS. The coordinates
-- travelled in the listings payload, so a hidden map would have left them
-- one View Source away -- protection that looks real on screen and is not
-- there at all. The withholding has to happen in the view, which is what
-- this file changes.
--
-- WHY A SETTING RATHER THAN A REWRITE. This question has already moved
-- once, and the design conflict register still has C3 (how coarse a
-- location may be shown) and C5 (whether blurring is required) open. So
-- the three positions are named and one is selected, rather than the
-- selected one being welded into a view definition and the alternative
-- deleted. Changing the answer is an UPDATE, not a migration.
--
--   none         no coordinates unless the address is unlocked.   <-- now
--   approximate  a deterministic ~1km offset for everyone else.
--   exact        the true position to everybody. Never appropriate here;
--                present so the enumeration is honest about what the
--                column can mean rather than implying it is safe.

BEGIN;

CREATE TABLE sec.disclosure (
    id          boolean PRIMARY KEY DEFAULT true CHECK (id),
    map_mode    text NOT NULL DEFAULT 'none'
                  CHECK (map_mode IN ('none', 'approximate', 'exact')),
    changed_at  timestamptz NOT NULL DEFAULT now(),
    changed_by  text,
    note        text
);

INSERT INTO sec.disclosure (id, map_mode, note) VALUES
 (true, 'none',
  'The map is shown only to callers who have been granted the address: '
  'internal staff, the assigned agent or lender, and an investor whose fee '
  'agreement is on file. Set to approximate to restore the fuzzed pin for '
  'everyone, which is what this system did before.');

-- Read by api.property on every row, so it is STABLE and SECURITY DEFINER:
-- the reader roles hold no privilege on sec.disclosure, and should not --
-- a caller must not be able to read the policy in order to be governed by
-- it, still less to write it.
CREATE FUNCTION sec.map_mode() RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = sec, pg_temp
AS $$
  SELECT map_mode FROM sec.disclosure WHERE id;
$$;

-- The setting itself is an admin's to read and change: which locations the
-- platform discloses is an operating decision, not a schema migration.
-- Nobody else gets the table -- a caller must not be able to read the
-- policy in order to be governed by it, and sec.map_mode() is SECURITY
-- DEFINER precisely so they do not need to.
GRANT SELECT, UPDATE ON sec.disclosure TO sdi_admin;

REVOKE ALL ON FUNCTION sec.map_mode() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sec.map_mode()
    TO sdi_public, sdi_investor, sdi_agent, sdi_admin, sdi_integration;

-- ---------------------------------------------------------------------
-- The view, with the coordinate rule replaced
--
-- CREATE OR REPLACE keeps the column list, the grants and every policy
-- written in terms of this view -- core.property_media's row policy among
-- them. Only the two coordinate expressions change.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW api.property
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

    -- Coordinates are band 2, on the same predicate as the address. A
    -- point on a map is an address written differently.
    CASE WHEN sec.can_see_address(p.property_id) THEN p.lat
         WHEN sec.map_mode() = 'approximate'     THEN sec.jitter(p.lat, p.property_id, 'lat')
         WHEN sec.map_mode() = 'exact'           THEN p.lat
    END                                             AS lat,
    CASE WHEN sec.can_see_address(p.property_id) THEN p.lng
         WHEN sec.map_mode() = 'approximate'     THEN sec.jitter(p.lng, p.property_id, 'lng')
         WHEN sec.map_mode() = 'exact'           THEN p.lng
    END                                             AS lng,
    sec.can_see_address(p.property_id)             AS address_unlocked
FROM core.property p
LEFT JOIN core.property_brand pb
       ON pb.property_id = p.property_id
      AND pb.brand_code  = sec.current_brand()
LEFT JOIN core.brand b
       ON b.brand_code   = sec.current_brand();

-- ---------------------------------------------------------------------
-- Does this caller get a map at all
--
-- The browser needs to know whether to draw one, and the honest answer is
-- "is there anything you could plot". An agent gets a map of their own
-- book; an investor past the fee gate gets the whole set; everybody else
-- gets nothing, and the panel is not rendered rather than rendered empty.
-- ---------------------------------------------------------------------
CREATE FUNCTION api.map_access() RETURNS boolean
LANGUAGE sql STABLE SECURITY INVOKER
SET search_path = api, pg_temp
AS $$
  SELECT EXISTS (SELECT 1 FROM api.property WHERE lat IS NOT NULL);
$$;

GRANT EXECUTE ON FUNCTION api.map_access()
    TO sdi_public, sdi_investor, sdi_agent, sdi_admin;

COMMIT;
