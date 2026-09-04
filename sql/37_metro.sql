-- =====================================================================
-- 37_metro.sql  |  the markets, as the business actually keeps them
-- =====================================================================
-- The workbook's Metro dropdown, verbatim:
--
--   Kansas City-OS, Birmingham, Nashville, Atlanta, St. Louis,
--   Kansas City-SH, Resi*, Dallas, Houston, Tampa,
--   No Monthly Fee, Hybrid
--
-- THREE OF THOSE ARE NOT PLACES. "No Monthly Fee", "Hybrid" and "Resi*"
-- describe how a property is managed or charged for, not where it is. Two
-- others -- Kansas City-OS and Kansas City-SH -- are one city under two
-- arrangements. So the list is a single control doing two jobs, which is
-- entirely reasonable in a spreadsheet and becomes a problem the first
-- time somebody asks "show me everything in Kansas City" or puts a market
-- filter on the public site: a filter built on this list would offer
-- "Hybrid" as a place to buy a house.
--
-- Modelled faithfully rather than tidied away. Every entry is here with
-- the exact label the workbook shows, in the order it shows them, so an
-- import matches and nothing has to be renamed by hand. What is added is
-- the distinction the spreadsheet leaves implicit: `kind` says whether an
-- entry is a market or an arrangement, and `metro_name` carries the
-- geography where there is one. Nothing is lost and the two jobs can be
-- separated when somebody decides how.
--
-- The classification below is INFERRED FROM THE LABELS and has not been
-- confirmed. It is recorded in `classified` so the guesses are visible
-- rather than passing as fact.

BEGIN;

CREATE TABLE core.metro (
    metro_code   text PRIMARY KEY,
    label        text NOT NULL UNIQUE,     -- exactly as the workbook shows it
    kind         text NOT NULL DEFAULT 'market'
                   CHECK (kind IN ('market', 'arrangement')),
    metro_name   text,                     -- the geography, where there is one
    state        char(2),
    arrangement  text,                     -- the -OS / -SH suffix, or the whole label
    sort_order   integer NOT NULL DEFAULT 0,
    active       boolean NOT NULL DEFAULT true,
    classified   text NOT NULL DEFAULT 'inferred'
                   CHECK (classified IN ('inferred', 'confirmed')),
    note         text,
    CONSTRAINT metro_geography CHECK (
        (kind = 'market'      AND metro_name IS NOT NULL) OR
        (kind = 'arrangement' AND metro_name IS NULL))
);

COMMENT ON COLUMN core.metro.kind IS
    'market: a place a property can be in. arrangement: a management or fee '
    'structure that shares the workbook dropdown with the places. A market '
    'filter must offer only the former, or it offers Hybrid as a city.';
COMMENT ON COLUMN core.metro.classified IS
    'inferred: this row''s kind was guessed from its label and nobody has '
    'confirmed it. confirmed: somebody who knows has said so.';

INSERT INTO core.metro
 (metro_code, label, kind, metro_name, state, arrangement, sort_order, note) VALUES
 ('KC-OS',      'Kansas City-OS', 'market', 'Kansas City', 'MO', 'OS', 10,
                'One of two Kansas City arrangements. What OS stands for is not established.'),
 ('BHM',        'Birmingham',     'market', 'Birmingham',  'AL', NULL, 20, NULL),
 ('BNA',        'Nashville',      'market', 'Nashville',   'TN', NULL, 30, NULL),
 ('ATL',        'Atlanta',        'market', 'Atlanta',     'GA', NULL, 40, NULL),
 ('STL',        'St. Louis',      'market', 'St. Louis',   'MO', NULL, 50, NULL),
 ('KC-SH',      'Kansas City-SH', 'market', 'Kansas City', 'MO', 'SH', 60,
                'The other Kansas City arrangement. What SH stands for is not established.'),
 ('RESI',       'Resi*',          'arrangement', NULL, NULL, 'Resi*', 70,
                'Not a place. The asterisk suggests a footnote in the workbook that has '
                'not been read.'),
 ('DFW',        'Dallas',         'market', 'Dallas',      'TX', NULL, 80, NULL),
 ('HOU',        'Houston',        'market', 'Houston',     'TX', NULL, 90, NULL),
 ('TPA',        'Tampa',          'market', 'Tampa',       'FL', NULL, 100, NULL),
 ('NO-FEE',     'No Monthly Fee', 'arrangement', NULL, NULL, 'No Monthly Fee', 110,
                'A fee structure, not a place.'),
 ('HYBRID',     'Hybrid',         'arrangement', NULL, NULL, 'Hybrid', 120,
                'A management arrangement, not a place.');

-- ---------------------------------------------------------------------
-- Properties point at one
--
-- Nullable, because the twenty-five demo listings predate the list and
-- five of their cities are not in it. Backfilled below where the city
-- matches unambiguously; the rest stay null rather than being assigned to
-- the nearest-looking market, which would be inventing data.
-- ---------------------------------------------------------------------
ALTER TABLE core.property
    ADD COLUMN metro_code text REFERENCES core.metro(metro_code);

CREATE INDEX ix_property_metro ON core.property (metro_code) WHERE metro_code IS NOT NULL;

UPDATE core.property p SET metro_code = m.metro_code
  FROM core.metro m
 WHERE m.kind = 'market'
   AND m.metro_name = p.city
   AND m.state = p.state
   -- Kansas City has two entries, so the city alone does not identify one.
   -- Left null deliberately: a listing assigned to the wrong arrangement
   -- reports against the wrong programme, and nobody would notice.
   AND (SELECT count(*) FROM core.metro x
         WHERE x.kind = 'market' AND x.metro_name = p.city AND x.state = p.state) = 1;

-- ---------------------------------------------------------------------
-- Visibility
--
-- A market is band 1. It is coarser than the city, which is already
-- public on every card, so publishing it discloses nothing new -- and it
-- is what an investor filters on when they think in regions rather than
-- towns.
-- ---------------------------------------------------------------------
ALTER TABLE core.metro ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.metro FORCE  ROW LEVEL SECURITY;
CREATE POLICY metro_read ON core.metro FOR SELECT USING (true);
CREATE POLICY metro_write ON core.metro FOR ALL TO sdi_admin
  USING (sec.is_internal()) WITH CHECK (sec.is_internal());

GRANT SELECT ON core.metro TO sdi_public, sdi_investor, sdi_agent, sdi_admin;
GRANT INSERT, UPDATE, DELETE ON core.metro TO sdi_admin;

CREATE VIEW api.metro
WITH (security_invoker = true, security_barrier = true) AS
SELECT metro_code, label, kind, metro_name, state, arrangement,
       sort_order, active, classified, note
FROM core.metro
ORDER BY sort_order;

GRANT SELECT ON api.metro TO sdi_public, sdi_investor, sdi_agent, sdi_admin;

COMMIT;
