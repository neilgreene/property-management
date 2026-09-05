-- =====================================================================
-- 50_search_criteria.sql  |  what a search is allowed to ask for
-- =====================================================================
-- The criteria vocabulary grows, so that an admin can ask the questions
-- they actually have -- "what is flagged and stale", "what is under 15%
-- five-year ROI" -- rather than only the ones the first version of the
-- form happened to offer.
--
-- THIS FILE IS HALF OF A PAIR. The other half is KEYS in web/nlq.js, and
-- the two lists must agree: what cannot be stored must not be produced.
-- They disagreed once already -- the map viewport keys were produced and
-- then violated this constraint the moment somebody saved the search --
-- so the constraint is written out in full rather than being relaxed, and
-- the test suite asserts the two lists match.
--
-- SOME OF THESE ARE STAFF-ONLY, AND THAT IS ENFORCED TWICE. The web tier
-- drops them for a caller who is not staff and says which it dropped.
-- Underneath, the views they read -- api.property_projection,
-- api.share_log, api.property_fee_status -- refuse a non-staff caller on
-- their own account. So a filter on five-year ROI cannot be used as an
-- oracle to binary-search a figure the caller may not see: it returns
-- nothing, rather than returning the answer one bisection at a time.
-- That second layer is the one that matters, because it is the one that
-- survives somebody removing the first by mistake.

BEGIN;

ALTER TABLE core.saved_search DROP CONSTRAINT saved_search_known_keys;

ALTER TABLE core.saved_search ADD CONSTRAINT saved_search_known_keys CHECK (
    criteria - ARRAY[
        -- what a buyer asks for
        'q','city','state','property_type','status',
        'min_price','max_price',
        'min_beds','max_beds',
        'min_baths','max_baths',
        'min_sqft','max_sqft',
        'sort',
        -- what staff ask for. Stored the same way and refused the same
        -- way: a saved search is not a way to keep a filter you have
        -- since lost the right to use.
        'flag','min_roi','max_roi','no_photos','not_shared_days','fees_stale'
    ] = '{}'::jsonb
);

COMMENT ON CONSTRAINT saved_search_known_keys ON core.saved_search IS
    'Mirrors KEYS in web/nlq.js. The two are asserted equal by the test '
    'suite -- a key produced but not storable fails only when somebody '
    'saves, which is long after the code that produced it was written.';

-- ---------------------------------------------------------------------
-- Five-year return, one row per property
-- ---------------------------------------------------------------------
-- A filter needs this per property, and api.property_projection returns
-- four rows per property by design. This is the one horizon a search
-- sorts and filters on.
--
-- HONEST ABOUT THE COST: this calls a plpgsql function once per row. At
-- twenty-five properties that is free and at ten thousand it is not. When
-- the book grows this wants materialising -- a table refreshed when
-- underwriting or assumptions change -- and the shape of the view stays
-- the same, so nothing above it changes when that day comes.
CREATE VIEW api.property_return
WITH (security_invoker = true, security_barrier = true) AS
SELECT p.property_id, r.annual_roi AS roi_5yr, r.total_gain AS gain_5yr,
       r.avg_cash_per_month AS cash_5yr
FROM api.property p
CROSS JOIN LATERAL (
    SELECT * FROM api.property_projection(p.property_id) WHERE years = 5
) r;

GRANT SELECT ON api.property_return TO sdi_agent, sdi_admin;

COMMENT ON VIEW api.property_return IS
    'Five-year figures, one row per property. Empty for a caller the '
    'projection refuses, so filtering on it cannot become an oracle.';

-- ---------------------------------------------------------------------
-- When a listing was last shared
-- ---------------------------------------------------------------------
CREATE VIEW api.property_share_age
WITH (security_invoker = true, security_barrier = true) AS
SELECT p.property_id,
       max(s.created_at)                                   AS last_shared_at,
       count(s.share_id)::int                              AS share_count,
       count(*) FILTER (WHERE s.unmasked)::int             AS unmasked_count
FROM api.property p
LEFT JOIN core.share_event s ON s.property_id = p.property_id
GROUP BY p.property_id;

GRANT SELECT ON api.property_share_age TO sdi_agent, sdi_admin;

COMMIT;
