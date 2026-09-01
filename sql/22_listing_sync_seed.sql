-- =====================================================================
-- 22_listing_sync_seed.sql  |  sources, vocabularies, and one real address
-- =====================================================================
-- Four sources, only two of which are switched on, because which sources
-- are trusted is a business decision and this file is where it is
-- recorded rather than argued about in code.

BEGIN;

INSERT INTO feed.listing_source
 (source_code, name, kind, base_url, authoritative, confirm_after, may_retire,
  active, check_cron, notes) VALUES

 ('MLS_RESO','Local MLS (RESO Web API)','reso_web_api',
  NULL, true, 2, true, false, '0 7 * * *',
  'The real answer. RESO Web API is the industry standard and returns '
  'StandardStatus in a fixed vocabulary, which is why the status map below '
  'is complete for it. Requires an MLS membership or approved vendor status, '
  'a signed data agreement, and IDX/VOW/broker-feed scope. INACTIVE until '
  'credentials exist -- base_url and the token come from the environment, '
  'never from this table.'),

 ('RENTCAST','RentCast property records','vendor_api',
  'https://api.rentcast.io/v1', false, 2, false, false, '0 8 * * *',
  'Self-serve, no MLS membership. Good for rent comps and property records; '
  'listing status is derivative rather than primary, so it is ADVISORY: it '
  'raises a flag, it does not change a status.'),

 ('PORTAL_SCRAPE','Consumer portal (scraped)','scrape',
  NULL, false, 3, false, false, NULL,
  'Deliberately advisory and deliberately off. Not mainly a licensing '
  'position: a scraper''s failure mode is a layout change that looks '
  'EXACTLY like "the listing is gone", so a scraper allowed to retire '
  'listings will one day retire the whole portfolio in a single run. If it '
  'is ever switched on it stays advisory and it stays unable to retire.'),

 ('MANUAL','Staff check','manual',
  NULL, true, 1, true, true, NULL,
  'A person looked. Authoritative and immediate -- confirm_after is 1 '
  'because a human is not a flaky feed. This is the source that works '
  'today with no integration at all.')
ON CONFLICT (source_code) DO NOTHING;

-- ---------------------------------------------------------------------
-- Vocabularies.
--
-- RESO StandardStatus is a closed enumeration, so this mapping is
-- complete and an unmapped term from that source means the feed sent
-- something non-standard -- which is worth a flag.
-- ---------------------------------------------------------------------
INSERT INTO feed.status_map (source_code, raw_status, mapped_status) VALUES
 ('MLS_RESO','Active','active'),
 ('MLS_RESO','Coming Soon','coming_soon'),
 -- Escrow. Both of these come back to 'Active' when a deal falls through,
 -- and the reconciler acts on that return immediately.
 ('MLS_RESO','Active Under Contract','pending'),
 ('MLS_RESO','Pending','pending'),
 ('MLS_RESO','Closed','sold'),
 ('MLS_RESO','Canceled','withdrawn'),
 ('MLS_RESO','Expired','withdrawn'),
 ('MLS_RESO','Withdrawn','withdrawn'),
 ('MLS_RESO','Hold','withdrawn'),
 ('MLS_RESO','Delete','withdrawn'),
 ('MLS_RESO','Incomplete','draft'),

 ('RENTCAST','Active','active'),
 ('RENTCAST','Pending','pending'),
 ('RENTCAST','Inactive','withdrawn'),

 ('PORTAL_SCRAPE','For sale','active'),
 ('PORTAL_SCRAPE','Coming soon','coming_soon'),
 ('PORTAL_SCRAPE','Pending','pending'),
 ('PORTAL_SCRAPE','Contingent','pending'),
 ('PORTAL_SCRAPE','Accepting backup offers','pending'),
 ('PORTAL_SCRAPE','Sold','sold'),
 ('PORTAL_SCRAPE','Off market','withdrawn'),

 ('MANUAL','active','active'),
 ('MANUAL','coming_soon','coming_soon'),
 ('MANUAL','pending','pending'),
 ('MANUAL','sold','sold'),
 ('MANUAL','withdrawn','withdrawn'),
 ('MANUAL','back_on_market','active')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------
-- The Irvine address.
--
-- Everything below that is not the address itself is NULL or zero, and
-- the listing is a DRAFT so it reaches nobody but staff. That is not an
-- oversight, it is the point: the facts we have are the ones in the URL
-- we were given -- house number, street, city, state, ZIP. The price, the
-- beds, the square footage and the photographs are somebody's licensed
-- content, and inventing plausible numbers to fill the gaps would produce
-- exactly the kind of confident wrong record this whole schema exists to
-- prevent.
--
-- The coordinate is the 92618 ZIP centroid, not the parcel. It is here
-- because lat/lng are NOT NULL and a map needs somewhere to put the pin;
-- it is accurate to about a mile and must be replaced by the feed.
--
-- The record's job right now is to be the thing the nightly worker
-- watches. Fill it in one of three ways:
--   * MLS_RESO once credentials exist -- it arrives complete;
--   * worker/tools/import-listing.js with a JSON file of the details;
--   * a staff member, through the review queue.
-- ---------------------------------------------------------------------
INSERT INTO core.property
 (property_id, listing_ref, status, city, state, zip, property_type,
  beds, baths, sqft, year_built,
  list_price, gross_rent_annual, opex_annual, hoa_annual,
  street_address, unit, lat, lng, parcel_number, seller_disclosure,
  acquisition_cost, source_channel, internal_notes) VALUES
 ('aaaaaaa1-0000-0000-0000-000000002001','SDI-2001','draft',
  'Irvine','CA','92618','Single Family',
  NULL, NULL, NULL, NULL,
  0, 0, 0, 0,
  '108 Fairgrove', NULL, 33.654000, -117.746000, NULL,
  NULL,
  NULL,'External listing',
  'Tracked from an external consumer-portal listing. Address is from the '
  'source URL; coordinate is the 92618 ZIP centroid, not the parcel. No '
  'price, size or photography has been obtained -- see 22_listing_sync_seed.sql. '
  'Stays draft until a feed or a staff member fills it in.')
ON CONFLICT (property_id) DO NOTHING;

INSERT INTO core.property_brand (property_id, brand_code, published)
VALUES ('aaaaaaa1-0000-0000-0000-000000002001','BRAND_A', false)
ON CONFLICT DO NOTHING;

-- The area figures ARE public information and are worth having in place,
-- so that the moment the listing is filled in it has context. Demo
-- figures, same caveat as every other row in core.market_area.
INSERT INTO core.market_area
 (area_id, city, state, median_household_income, median_home_price,
  median_rent_monthly, rent_growth_1y_bps, vacancy_rate_bps, population)
VALUES ('Irvine, CA','Irvine','CA', 127000, 1520000, 3350, 290, 410, 313685)
ON CONFLICT (area_id) DO NOTHING;

-- The watch itself. This row is what makes the nightly job look at it.
--
-- The external id is the identifier in the source URL. It is stored
-- because re-finding a listing by address is unreliable and re-finding it
-- by the source's own key is not.
INSERT INTO feed.property_external
 (property_id, source_code, external_id, external_url, enabled) VALUES
 ('aaaaaaa1-0000-0000-0000-000000002001','PORTAL_SCRAPE','119681357',
  'https://www.zillow.com/homedetails/108-Fairgrove-Irvine-CA-92618/119681357_zpid/',
  true),
 ('aaaaaaa1-0000-0000-0000-000000002001','MANUAL','108-fairgrove-irvine-ca-92618',
  NULL, true)
ON CONFLICT DO NOTHING;

COMMIT;
