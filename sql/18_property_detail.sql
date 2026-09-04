-- =====================================================================
-- 18_property_detail.sql  |  the drill-down: media, detail, market data
-- =====================================================================
-- Three tables behind one view.
--
--   market_area     regional figures, shared by every property in a city.
--                   Normalised because they are a property OF THE AREA, not
--                   of the house -- duplicating median income onto 24 rows
--                   means 24 places to update when the figure moves.
--
--   property_detail one row per property. The operating detail an investor
--                   actually underwrites on: taxes, insurance, utilities,
--                   management, vacancy, and what it rents for today.
--
--   property_media  photographs.
--
-- Banding: all of this is band 1. It is the analysis that sells the
-- listing, so withholding it would defeat the purpose. The street address
-- stays band 2 and the acquisition cost stays band 3, exactly as before.
--
-- With one exception, and it matters. A photograph of the front of a house
-- identifies the property as surely as its address -- a street number on a
-- door, a recognisable streetscape. So media carries `reveals_location`,
-- and any image flagged that way is released on the same predicate as the
-- address itself. Interior shots stay public. Getting this wrong would
-- reopen the gate through the picture gallery.

BEGIN;

-- ---------------------------------------------------------------------
CREATE TABLE core.market_area (
    area_id          text PRIMARY KEY,          -- 'Cleveland, OH'
    city             text NOT NULL,
    state            char(2) NOT NULL,
    median_household_income numeric(12,2),
    median_home_price       numeric(12,2),
    median_rent_monthly     numeric(10,2),
    rent_growth_1y_bps      integer,            -- basis points, not a float
    vacancy_rate_bps        integer,
    population              integer,
    price_to_income         numeric(5,2)
        GENERATED ALWAYS AS (median_home_price / NULLIF(median_household_income,0)) STORED,
    as_of            date NOT NULL DEFAULT current_date,
    UNIQUE (city, state)
);

-- ---------------------------------------------------------------------
CREATE TABLE core.property_detail (
    property_id      uuid PRIMARY KEY REFERENCES core.property(property_id) ON DELETE CASCADE,
    headline         text,
    description      text,

    -- What it earns
    market_rent_monthly     numeric(10,2),
    rent_basis              text CHECK (rent_basis IN ('in_place','market_estimate','pro_forma')),

    -- What it costs to hold. Annual unless the name says otherwise.
    property_tax_annual     numeric(10,2),
    insurance_annual        numeric(10,2),
    utilities_monthly       numeric(10,2),
    utilities_paid_by       text CHECK (utilities_paid_by IN ('owner','tenant','split')),
    maintenance_annual      numeric(10,2),
    management_fee_bps      integer,            -- of gross rent
    vacancy_allowance_bps   integer,

    -- The building
    lot_sqft         integer,
    stories          smallint,
    garage_spaces    smallint,
    heating          text,
    cooling          text,
    roof_year        smallint,
    last_renovated   smallint,
    parking          text,
    features         jsonb NOT NULL DEFAULT '[]'::jsonb,

    updated_at       timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
CREATE TABLE core.property_media (
    media_id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    property_id      uuid NOT NULL REFERENCES core.property(property_id) ON DELETE CASCADE,
    url              text NOT NULL,
    -- A downscaled copy of `url`, for cards and grids. Null means there is
    -- no smaller version and the full file is the only one there is; every
    -- reader must therefore coalesce rather than assume. It carries no
    -- visibility of its own: it is the same picture, so it is released or
    -- withheld with the row that owns it.
    thumb_url        text,
    caption          text,
    position         integer NOT NULL DEFAULT 0,
    is_primary       boolean NOT NULL DEFAULT false,
    -- The gate, applied to pictures. An exterior or street view identifies
    -- the property; it is released on the same terms as the address.
    reveals_location boolean NOT NULL DEFAULT false
);
CREATE INDEX ix_media_property ON core.property_media (property_id, position);
CREATE UNIQUE INDEX ux_media_primary ON core.property_media (property_id) WHERE is_primary;

-- The card hero is a generic, type-keyed illustration: it shows no street,
-- no number and no surroundings, so it is not location-revealing and is not
-- gated. Kept distinct from `front`, which is the actual exterior and is.
COMMENT ON COLUMN core.property_media.reveals_location IS
    'True for exterior and street views. Such an image is band 2: showing '
    'it to an ungated caller would reopen the address gate through the '
    'photo gallery.';

-- ---------------------------------------------------------------------
-- Policies. market_area is reference data; the other two follow their
-- property, so their visibility is stated by reference rather than
-- restated -- the two cannot then drift apart.
-- ---------------------------------------------------------------------
ALTER TABLE core.market_area     ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.market_area     FORCE  ROW LEVEL SECURITY;
ALTER TABLE core.property_detail ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.property_detail FORCE  ROW LEVEL SECURITY;
ALTER TABLE core.property_media  ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.property_media  FORCE  ROW LEVEL SECURITY;

CREATE POLICY market_area_read ON core.market_area FOR SELECT USING (true);

CREATE POLICY property_detail_read ON core.property_detail
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM api.property v
             WHERE v.property_id = core.property_detail.property_id));

CREATE POLICY property_media_read ON core.property_media
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM api.property v
             WHERE v.property_id = core.property_media.property_id)
    AND (NOT reveals_location OR sec.can_see_address(core.property_media.property_id))
  );

GRANT SELECT ON core.market_area, core.property_detail, core.property_media
    TO sdi_public, sdi_investor, sdi_agent, sdi_admin;

-- ---------------------------------------------------------------------
-- The view the application reads
-- ---------------------------------------------------------------------
CREATE VIEW api.property_detail
WITH (security_invoker = true, security_barrier = true) AS
SELECT p.property_id, p.listing_ref, p.status, p.city, p.state, p.zip,
       p.property_type, p.beds, p.baths, p.sqft, p.year_built,
       p.list_price, p.gross_rent_annual, p.opex_annual, p.hoa_annual,
       p.noi_annual, p.cap_rate,
       p.street_address, p.unit, p.lat, p.lng, p.address_unlocked,
       p.brand_service_tier, p.brand_platform_fee,

       d.headline, d.description,
       d.market_rent_monthly, d.rent_basis,
       d.property_tax_annual, d.insurance_annual,
       d.utilities_monthly, d.utilities_paid_by,
       d.maintenance_annual, d.management_fee_bps, d.vacancy_allowance_bps,
       d.lot_sqft, d.stories, d.garage_spaces, d.heating, d.cooling,
       d.roof_year, d.last_renovated, d.parking, d.features,

       m.median_household_income, m.median_rent_monthly AS area_median_rent,
       m.median_home_price       AS area_median_price,
       m.rent_growth_1y_bps, m.vacancy_rate_bps AS area_vacancy_bps,
       m.population, m.price_to_income,

       -- Rent as a share of what the area actually earns. The number an
       -- investor asks for first: a rent far above local income is a
       -- vacancy risk however good the yield looks on paper.
       CASE WHEN m.median_household_income > 0
            THEN round((d.market_rent_monthly * 12 / m.median_household_income)::numeric, 4)
       END AS rent_to_area_income,

       (SELECT count(*) FROM core.property_media mm
         WHERE mm.property_id = p.property_id) AS media_count
FROM api.property p
LEFT JOIN core.property_detail d ON d.property_id = p.property_id
LEFT JOIN core.market_area     m ON m.city = p.city AND m.state = p.state;

CREATE VIEW api.property_media
WITH (security_invoker = true, security_barrier = true) AS
SELECT media_id, property_id, url, thumb_url, caption, position, is_primary, reveals_location
FROM core.property_media
ORDER BY is_primary DESC, position;

GRANT SELECT ON api.property_detail, api.property_media
    TO sdi_public, sdi_investor, sdi_agent, sdi_admin;

-- ---------------------------------------------------------------------
-- Un-favouriting. Saving already exists; removing did not.
-- ---------------------------------------------------------------------
CREATE FUNCTION api.unsave_property(p_property_id uuid) RETURNS boolean
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $fn$
DECLARE v_actor uuid := sec.actor_id(); n integer;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '28000';
  END IF;
  DELETE FROM core.saved_property
   WHERE person_id = v_actor AND property_id = p_property_id;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n > 0;
END $fn$;

REVOKE ALL ON FUNCTION api.unsave_property(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.unsave_property(uuid) TO sdi_investor, sdi_admin;
GRANT EXECUTE ON FUNCTION api.save_property(uuid)   TO sdi_admin;

COMMIT;
