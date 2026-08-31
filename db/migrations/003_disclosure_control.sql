-- 003_disclosure_control.sql
--
-- Makes the address/financial gate a database boundary rather than a
-- convention. Hiding a field in the browser is presentation, not access
-- control: if the client fetches the row, the client has the row. So the
-- public read path is given a role that is physically incapable of selecting
-- restricted columns.
--
-- Roles
--   pmp_app    - the integration service and admin API. Full access.
--   pmp_public - the unauthenticated web read path. property_public only.

BEGIN;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pmp_app') THEN
        CREATE ROLE pmp_app NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pmp_public') THEN
        CREATE ROLE pmp_public NOLOGIN;
    END IF;
END $$;

-- ------------------------------------------------------- public projection
-- Restricted columns are absent from this view entirely. There is no filter
-- to forget and no flag to get wrong: the columns are not reachable.
CREATE VIEW property_public AS
SELECT
    p.id,
    p.headline,
    p.display_region,
    p.property_type,
    p.beds,
    p.baths,
    p.sqft,
    p.year_built,
    p.asking_price_minor,
    p.currency,
    p.cap_rate_bps,
    p.day1_cashflow_minor,
    p.five_year_net_minor,
    p.hoa_monthly_minor,
    p.hero_image_url,
    p.analysis,
    p.status,
    p.listed_at
FROM property p
WHERE p.public_visible
  AND p.status = 'active';

COMMENT ON VIEW property_public IS
    'The only relation the unauthenticated read path may query. Contains no '
    'street address, coordinates, parcel id, seller notes or restricted '
    'analysis. Adding a restricted column here is a disclosure incident.';

-- ---------------------------------------------- entitled detail accessor
-- Restricted fields are released only through this function, which checks
-- the viewer's server-side entitlement. The caller cannot pass the answer in.
CREATE FUNCTION property_detail_for(p_party_id bigint, p_property_id bigint)
RETURNS TABLE (
    id                  bigint,
    headline            text,
    street_address      text,
    unit_number         text,
    postal_code         text,
    latitude            numeric(9,6),
    longitude           numeric(9,6),
    parcel_id           text,
    seller_notes        text,
    restricted_analysis jsonb
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT p.id, p.headline, p.street_address, p.unit_number, p.postal_code,
           p.latitude, p.longitude, p.parcel_id, p.seller_notes,
           p.restricted_analysis
    FROM property p
    WHERE p.id = p_property_id
      AND EXISTS (
          SELECT 1 FROM party q
          WHERE q.id = p_party_id
            AND q.active
            AND q.entitlement = 'granted'
      );
$$;

COMMENT ON FUNCTION property_detail_for(bigint, bigint) IS
    'Returns zero rows when the party is not entitled. Entitlement is read '
    'from the party table, never from a caller-supplied argument.';

-- ------------------------------------------------------------------ grants
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM PUBLIC;
REVOKE ALL ON SCHEMA public FROM PUBLIC;

GRANT USAGE ON SCHEMA public TO pmp_app, pmp_public;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO pmp_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO pmp_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO pmp_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT USAGE, SELECT ON SEQUENCES TO pmp_app;

-- The public role gets the view and nothing else. Not the base table.
GRANT SELECT ON property_public TO pmp_public;
GRANT EXECUTE ON FUNCTION property_detail_for(bigint, bigint) TO pmp_app;

COMMIT;
