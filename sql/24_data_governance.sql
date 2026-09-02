-- =====================================================================
-- 24_data_governance.sql  |  what we are allowed to do with this data
-- =====================================================================
-- Every listing in this system is somebody else's data held under some
-- instrument -- an MLS participation agreement, a vendor subscription, a
-- seller's own submission, a public record. Each instrument says three
-- things that matter operationally:
--
--   WHERE   it applies. A feed licensed for the Cleveland market does not
--           cover a house in Irvine, and using it there is a breach even
--           though the software would work perfectly.
--   WHAT    may be done with it. "You may display this to a registered
--           consumer" is not "you may publish this to the open web", and
--           neither is "you may export it in bulk" or "you may train a
--           model on it".
--   UNTIL   when, and what must be done in return -- attribution,
--           refresh cadence, removal within N hours of a delisting.
--
-- Those three facts decide whether a property may legally be published,
-- so they belong where the publication decision is made: in the database,
-- next to the row. A licence recorded in a spreadsheet is a licence that
-- gets breached the week somebody forgets the spreadsheet exists.
--
-- WHAT THIS FILE IS NOT. It is not legal advice and it is not a claim
-- about what any particular agreement says. It is the SHAPE that holds
-- whatever the signed agreements say, plus a register of the regimes that
-- have been identified as applying, each of which counsel has to confirm
-- against the actual instrument. Everything seeded here is marked with
-- its review status, and an unreviewed right is visibly unreviewed rather
-- than quietly treated as settled.

BEGIN;

CREATE SCHEMA IF NOT EXISTS gov;
GRANT USAGE ON SCHEMA gov TO sdi_admin;

-- ---------------------------------------------------------------------
-- WHERE: territory
--
-- A containment tree, because rights are granted at wildly different
-- granularities -- a nationwide vendor subscription, a state, a single
-- MLS whose footprint is a handful of counties. A right lists the
-- territories it covers and a property is inside one if the tree says so.
-- ---------------------------------------------------------------------
CREATE TABLE gov.territory (
    territory_id text PRIMARY KEY,          -- 'US', 'US-OH', 'MLS-NEOHREX'
    kind         text NOT NULL CHECK (kind IN ('country','state','county','metro','mls_market')),
    name         text NOT NULL,
    country      char(2) NOT NULL DEFAULT 'US',
    state        char(2),                   -- set for state-level and below
    parent_id    text REFERENCES gov.territory(territory_id),
    notes        text,
    CHECK (kind = 'country' OR state IS NOT NULL OR kind = 'mls_market')
);

-- A market's footprint stated as explicit places. An MLS covers the towns
-- it covers; there is no rule that derives that, so it is listed.
CREATE TABLE gov.territory_place (
    territory_id text NOT NULL REFERENCES gov.territory(territory_id) ON DELETE CASCADE,
    city         text NOT NULL,
    state        char(2) NOT NULL,
    PRIMARY KEY (territory_id, city, state)
);

-- ---------------------------------------------------------------------
-- WHAT: the instrument
-- ---------------------------------------------------------------------
CREATE TABLE gov.data_right (
    right_id       text PRIMARY KEY,
    name           text NOT NULL,

    -- Who granted it and under what.
    grantor        text NOT NULL,           -- 'NEOHREX', 'RentCast, Inc.', 'the seller'
    instrument     text NOT NULL CHECK (instrument IN
                     ('mls_participation','idx_addendum','vow_addendum','broker_feed',
                      'vendor_subscription','purchase','public_record','seller_submission',
                      'owner_consent','none')),
    -- 'none' is a real and important value: it records that we hold data
    -- under no instrument at all, which is a finding, not a blank.

    source_code    text REFERENCES feed.listing_source(source_code),
    reference      text,                    -- contract number, order id, URL of the record
    counterparty_contact text,

    effective_from date,
    effective_to   date,                    -- NULL = perpetual (rare; check the instrument)

    -- Does the right survive the agreement ending? Most feed licences do
    -- not: termination obliges deletion. That is the single most
    -- expensive clause to discover late.
    survives_termination boolean NOT NULL DEFAULT false,

    -- Review posture. An unreviewed right is not a right we may rely on.
    review_status  text NOT NULL DEFAULT 'unreviewed'
                     CHECK (review_status IN ('unreviewed','in_review','counsel_confirmed','rejected')),
    reviewed_by    text,
    reviewed_on    date,
    notes          text,
    created_at     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE gov.data_right_territory (
    right_id     text NOT NULL REFERENCES gov.data_right(right_id) ON DELETE CASCADE,
    territory_id text NOT NULL REFERENCES gov.territory(territory_id),
    PRIMARY KEY (right_id, territory_id)
);

-- The permitted-use vocabulary. Separate rows rather than boolean columns
-- because "not granted" and "explicitly refused" are different facts and
-- a missing row must never read as permission.
CREATE TABLE gov.use_kind (
    use_code text PRIMARY KEY,
    label    text NOT NULL,
    detail   text NOT NULL
);

INSERT INTO gov.use_kind (use_code, label, detail) VALUES
 ('internal_analysis','Internal analysis','Staff underwriting and reporting. Never leaves the organisation'),
 ('gated_display','Display to registered users','Shown to a person who has an account and has accepted terms. The VOW-shaped permission'),
 ('public_display','Display to the open web','Shown to an anonymous visitor. The IDX-shaped permission, and the narrower one'),
 ('derive','Publish derived figures','Cap rate, NOI, rent-to-income. Some licences permit the derivation but not the underlying figure'),
 ('redistribute','Onward syndication','Passing the data to a third party or another portal'),
 ('export','Bulk export','Handing a file to a customer or partner'),
 ('marketing','Outbound marketing','Using it to build campaign audiences or message content'),
 ('model_training','Model training','Training or fine-tuning a model on it. Increasingly an explicit licence term and almost never granted by default');

CREATE TABLE gov.data_right_use (
    right_id  text NOT NULL REFERENCES gov.data_right(right_id) ON DELETE CASCADE,
    use_code  text NOT NULL REFERENCES gov.use_kind(use_code),
    -- 'granted' / 'refused' / 'unclear'. Unclear is not permission.
    posture   text NOT NULL DEFAULT 'unclear'
                CHECK (posture IN ('granted','refused','unclear')),
    condition text,                          -- 'with broker attribution', 'aggregate only'
    PRIMARY KEY (right_id, use_code)
);

-- ---------------------------------------------------------------------
-- UNTIL / IN RETURN: obligations
-- ---------------------------------------------------------------------
CREATE TABLE gov.obligation (
    obligation_id  bigserial PRIMARY KEY,
    right_id       text NOT NULL REFERENCES gov.data_right(right_id) ON DELETE CASCADE,
    kind           text NOT NULL CHECK (kind IN
                     ('attribution','refresh_interval','removal_sla','retention_limit',
                      'audit_right','display_restriction','commingling_restriction',
                      'deletion_on_termination','notice')),
    -- The machine-actionable part, where there is one.
    interval_hours integer,
    text_required  text,                     -- exact attribution wording, when specified
    detail         text NOT NULL,
    -- Is it enforced by this system, by a person, or not yet at all?
    enforcement    text NOT NULL DEFAULT 'unenforced'
                     CHECK (enforcement IN ('automatic','procedural','unenforced'))
);

-- ---------------------------------------------------------------------
-- Which right each property's data is held under
--
-- Per property rather than per source, because the same property can
-- arrive twice -- once from a feed and once from the seller -- and the
-- rights differ. The strongest applicable right wins at display time;
-- this table records what is actually held.
-- ---------------------------------------------------------------------
CREATE TABLE gov.property_provenance (
    property_id  uuid NOT NULL REFERENCES core.property(property_id) ON DELETE CASCADE,
    right_id     text NOT NULL REFERENCES gov.data_right(right_id),
    -- Which part of the record this right covers. Photographs are
    -- routinely licensed separately and more narrowly than the listing
    -- facts, which is exactly the mistake that gets a portal sued.
    scope        text NOT NULL DEFAULT 'listing_facts'
                   CHECK (scope IN ('listing_facts','media','valuation','market_data','contact')),
    acquired_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (property_id, right_id, scope)
);
CREATE INDEX ix_provenance_right ON gov.property_provenance (right_id);

-- ---------------------------------------------------------------------
-- The register of regimes
--
-- Not a substitute for advice. It is the list of what has been
-- IDENTIFIED as applying, what each one constrains, and -- the column
-- that makes it more than a wall poster -- where in this system the
-- constraint is actually enforced. A regulation with an empty control is
-- a gap that is visible instead of assumed.
-- ---------------------------------------------------------------------
CREATE TABLE gov.regulation (
    reg_code    text PRIMARY KEY,
    name        text NOT NULL,
    citation    text,
    regime      text NOT NULL CHECK (regime IN
                  ('fair_housing','lending','data_licensing','privacy','marketing',
                   'intellectual_property','licensing_conduct','payments','security')),
    applies_when text NOT NULL,              -- the trigger condition, so scope creep is visible
    constrains  text NOT NULL,
    our_posture text NOT NULL,
    status      text NOT NULL DEFAULT 'identified'
                  CHECK (status IN ('identified','counsel_confirmed','not_applicable','deferred')),
    reviewed_on date
);

CREATE TABLE gov.regulation_control (
    reg_code  text NOT NULL REFERENCES gov.regulation(reg_code) ON DELETE CASCADE,
    control   text NOT NULL,                 -- what stops the breach
    located_in text NOT NULL,                -- the file, table, function or test
    kind      text NOT NULL CHECK (kind IN ('technical','procedural','contractual','absent')),
    PRIMARY KEY (reg_code, control)
);

-- ---------------------------------------------------------------------
-- Fair housing: the dimensions that must never become a filter
--
-- This is the one register in this file with teeth in the application,
-- and it deserves its own explanation.
--
-- A property marketplace that lets a user filter or an algorithm rank on
-- a protected characteristic -- or on a proxy for one -- is steering,
-- whether or not anyone intended it. The Fair Housing Act does not
-- require intent. A recommendation engine is as capable of it as a
-- dropdown, which is why this list exists BEFORE there is a
-- recommendation engine.
--
-- The proxies are the hard part and are listed explicitly, because a
-- system that blocks 'race' and allows 'percent_white_by_tract' has
-- blocked nothing. Note in particular that the marketplace holds
-- median household income by area: legitimate for estimating what a
-- property rents for, illegitimate as an axis a buyer sorts on.
-- ---------------------------------------------------------------------
CREATE TABLE gov.prohibited_dimension (
    dimension text PRIMARY KEY,
    basis     text NOT NULL,                 -- protected class or the proxy's target
    kind      text NOT NULL CHECK (kind IN ('protected_class','proxy')),
    rationale text NOT NULL
);

INSERT INTO gov.prohibited_dimension (dimension, basis, kind, rationale) VALUES
 ('race','race','protected_class','FHA 42 U.S.C. 3604'),
 ('color','color','protected_class','FHA 42 U.S.C. 3604'),
 ('religion','religion','protected_class','FHA 42 U.S.C. 3604'),
 ('national_origin','national origin','protected_class','FHA 42 U.S.C. 3604'),
 ('sex','sex','protected_class','FHA 42 U.S.C. 3604, incl. gender identity and sexual orientation per HUD guidance'),
 ('familial_status','familial status','protected_class','FHA 42 U.S.C. 3604'),
 ('disability','disability','protected_class','FHA 42 U.S.C. 3604'),
 ('age','age','protected_class','State law in several jurisdictions'),
 ('marital_status','marital status','protected_class','State law in several jurisdictions'),
 ('source_of_income','source of income','protected_class','State and local law; voucher-holder exclusion'),
 -- Proxies. The whole point.
 ('school_rating','race and national origin','proxy',
  'School ratings correlate strongly with the demographics of the catchment. Offering one as a ranking axis is steering by another name'),
 ('area_racial_composition','race','proxy','Direct'),
 ('area_median_income_as_ranking','race and national origin','proxy',
  'Held for rent estimation, which is legitimate. Offering it as an axis a buyer sorts or filters on is not'),
 ('crime_index','race and national origin','proxy',
  'Reported-crime indices track policing intensity as much as risk and correlate with race'),
 ('neighbourhood_desirability','multiple','proxy',
  'A composite score is a laundered version of whatever went into it'),
 ('language_spoken','national origin','proxy','Direct'),
 ('religious_institution_proximity','religion','proxy','Direct');

-- ---------------------------------------------------------------------
-- Does a right cover this property?
-- ---------------------------------------------------------------------

-- Territory containment, walked upward from the property's own state.
CREATE FUNCTION gov.territory_covers(p_territory_id text, p_city text, p_state char(2))
RETURNS boolean
LANGUAGE sql STABLE
SET search_path = gov, pg_temp
AS $$
  WITH RECURSIVE down AS (
    SELECT territory_id, kind, state FROM gov.territory WHERE territory_id = p_territory_id
    UNION ALL
    SELECT t.territory_id, t.kind, t.state
      FROM gov.territory t JOIN down d ON t.parent_id = d.territory_id
  )
  SELECT EXISTS (
    -- A country- or state-level territory covers by state.
    SELECT 1 FROM down
     WHERE (kind = 'country' AND p_state IS NOT NULL)
        OR (kind IN ('state','county','metro') AND state = p_state)
    UNION ALL
    -- A named market covers the places it lists, and nothing else.
    SELECT 1 FROM gov.territory_place tp JOIN down ON down.territory_id = tp.territory_id
     WHERE tp.city = p_city AND tp.state = p_state
  );
$$;

-- The question the publication path asks.
--
-- Every clause is a reason a right does NOT apply, and they are all
-- stated positively so that adding a new one cannot accidentally widen
-- the answer: unreviewed is not permission, expired is not permission,
-- 'unclear' is not permission, and out-of-territory is not permission.
CREATE FUNCTION gov.may_use(p_property_id uuid, p_use_code text,
                            p_scope text DEFAULT 'listing_facts')
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = gov, core, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM core.property p
    JOIN gov.property_provenance pv ON pv.property_id = p.property_id
                                   AND pv.scope = p_scope
    JOIN gov.data_right r           ON r.right_id = pv.right_id
    JOIN gov.data_right_use u       ON u.right_id = r.right_id AND u.use_code = p_use_code
    WHERE p.property_id = p_property_id
      AND u.posture = 'granted'
      AND r.review_status = 'counsel_confirmed'
      AND (r.effective_from IS NULL OR r.effective_from <= current_date)
      AND (r.effective_to   IS NULL OR r.effective_to   >= current_date)
      AND EXISTS (
        SELECT 1 FROM gov.data_right_territory rt
         WHERE rt.right_id = r.right_id
           AND gov.territory_covers(rt.territory_id, p.city, p.state))
  );
$$;

-- Everything known about why a property may or may not be shown. The
-- answer an operator needs when a listing will not publish.
CREATE VIEW gov.property_rights AS
SELECT p.property_id, p.listing_ref, p.city, p.state,
       pv.scope, r.right_id, r.name AS right_name, r.grantor, r.instrument,
       r.review_status, r.effective_from, r.effective_to,
       (r.effective_to IS NOT NULL AND r.effective_to < current_date) AS expired,
       u.use_code, u.posture, u.condition,
       EXISTS (SELECT 1 FROM gov.data_right_territory rt
                WHERE rt.right_id = r.right_id
                  AND gov.territory_covers(rt.territory_id, p.city, p.state)) AS in_territory
FROM core.property p
JOIN gov.property_provenance pv ON pv.property_id = p.property_id
JOIN gov.data_right r           ON r.right_id = pv.right_id
LEFT JOIN gov.data_right_use u  ON u.right_id = r.right_id;

-- ---------------------------------------------------------------------
-- Enforcement: publication requires a right
--
-- A trigger rather than a check somewhere in the application, for the
-- same reason the address gate is a policy rather than an if-statement:
-- there is more than one way to write to this table, and the rule has to
-- hold for all of them.
-- ---------------------------------------------------------------------
-- How hard the rule bites. This exists because the business operates
-- today: a control that blocks publication the moment it is deployed
-- would take a working marketplace off the air over paperwork that has
-- simply not been transcribed yet.
--
--   advisory  the default. Publication proceeds; every uncovered listing
--             is reported by api.security_invariants() and listed in
--             gov.uncovered_publication. You can see the whole gap on day
--             one without anything breaking.
--   blocking  publication requires a confirmed right. This is the go-live
--             gate, flipped once the register reflects reality.
--
-- Advisory is a deliberate, recorded choice with a visible consequence,
-- not the absence of a decision.
CREATE TABLE gov.policy (
    id               boolean PRIMARY KEY DEFAULT true CHECK (id),
    enforcement_mode text NOT NULL DEFAULT 'advisory'
                       CHECK (enforcement_mode IN ('advisory','blocking')),
    changed_at       timestamptz NOT NULL DEFAULT now(),
    changed_by       text,
    note             text
);
INSERT INTO gov.policy (id, note) VALUES
 (true, 'Advisory until the register reflects the instruments the business actually holds. '
        'Flip to blocking as the go-live gate.');

CREATE FUNCTION gov.assert_publishable() RETURNS trigger
LANGUAGE plpgsql
SET search_path = gov, core, pg_temp
AS $fn$
DECLARE mode text;
BEGIN
  IF NOT NEW.published THEN RETURN NEW; END IF;
  IF gov.may_use(NEW.property_id, 'public_display') THEN RETURN NEW; END IF;

  SELECT enforcement_mode INTO mode FROM gov.policy;
  IF mode = 'blocking' THEN
    RAISE EXCEPTION
      'no confirmed data right permits public display of this property'
      USING ERRCODE = '42501',
            DETAIL  = 'See gov.property_rights for which right is missing, expired, '
                      'unreviewed, or out of territory.',
            HINT    = 'Record the instrument in gov.data_right and its permitted uses '
                      'in gov.data_right_use, or leave the listing unpublished.';
  END IF;

  -- Advisory. Say so once, loudly enough to appear in the logs, and let
  -- the work continue. The standing invariant is the durable record.
  RAISE WARNING 'publishing % with no confirmed data right (governance is advisory)',
                NEW.property_id;
  RETURN NEW;
END $fn$;

CREATE TRIGGER property_brand_requires_right
  BEFORE INSERT OR UPDATE OF published ON core.property_brand
  FOR EACH ROW EXECUTE FUNCTION gov.assert_publishable();

-- The gap, standing. Every listing on public display that no confirmed
-- right covers, and the nearest reason why.
CREATE VIEW gov.uncovered_publication AS
SELECT p.property_id, p.listing_ref, p.city, p.state, pb.brand_code,
       CASE
         WHEN NOT EXISTS (SELECT 1 FROM gov.property_provenance v
                           WHERE v.property_id = p.property_id)
           THEN 'no provenance recorded'
         WHEN NOT EXISTS (SELECT 1 FROM gov.property_rights g
                           WHERE g.property_id = p.property_id AND g.in_territory)
           THEN 'right does not cover this territory'
         WHEN NOT EXISTS (SELECT 1 FROM gov.property_rights g
                           WHERE g.property_id = p.property_id
                             AND g.review_status = 'counsel_confirmed')
           THEN 'right is not counsel-confirmed'
         WHEN EXISTS (SELECT 1 FROM gov.property_rights g
                       WHERE g.property_id = p.property_id AND g.expired)
           THEN 'right has expired'
         ELSE 'public_display not granted'
       END AS reason
FROM core.property p
JOIN core.property_brand pb ON pb.property_id = p.property_id AND pb.published
WHERE NOT gov.may_use(p.property_id, 'public_display');

-- ---------------------------------------------------------------------
-- Removal obligations
--
-- IDX and VOW rules typically require a delisted property to disappear
-- from display within a stated number of hours. That is a deadline, and
-- a deadline nobody computes is a deadline nobody meets -- so it is
-- computed here, from the obligation row, against the feed's own record
-- of when the listing went away.
-- ---------------------------------------------------------------------
CREATE VIEW gov.removal_due AS
SELECT p.property_id, p.listing_ref, p.status, pb.brand_code, pb.published,
       r.right_id, o.interval_hours, x.last_seen_at,
       x.last_seen_at + make_interval(hours => o.interval_hours) AS remove_by,
       now() > x.last_seen_at + make_interval(hours => o.interval_hours) AS overdue
FROM core.property p
JOIN core.property_brand pb     ON pb.property_id = p.property_id AND pb.published
JOIN gov.property_provenance pv ON pv.property_id = p.property_id
JOIN gov.data_right r           ON r.right_id = pv.right_id
JOIN gov.obligation o           ON o.right_id = r.right_id AND o.kind = 'removal_sla'
LEFT JOIN feed.property_external x ON x.property_id = p.property_id
                                  AND x.source_code = r.source_code
WHERE p.status IN ('sold','withdrawn')
   OR x.last_seen_at IS NULL;

-- Unpublishes anything past its removal deadline. Idempotent, and safe to
-- run on a schedule beside the listing sweep.
CREATE FUNCTION gov.enforce_removals() RETURNS integer
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = gov, core, pg_temp
AS $fn$
DECLARE n integer;
BEGIN
  UPDATE core.property_brand pb SET published = false
   WHERE pb.published
     AND EXISTS (SELECT 1 FROM gov.removal_due d
                  WHERE d.property_id = pb.property_id
                    AND d.brand_code = pb.brand_code
                    AND d.overdue);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $fn$;

-- ---------------------------------------------------------------------
-- Staff-facing surface
-- ---------------------------------------------------------------------
CREATE VIEW api.data_rights
WITH (security_invoker = true, security_barrier = true) AS
SELECT * FROM gov.property_rights;

CREATE VIEW api.compliance_register
WITH (security_invoker = true, security_barrier = true) AS
SELECT g.reg_code, g.name, g.citation, g.regime, g.applies_when,
       g.constrains, g.our_posture, g.status,
       coalesce(string_agg(c.control || ' (' || c.located_in || ')', '; '
                           ORDER BY c.control), 'NO CONTROL RECORDED') AS controls,
       bool_or(c.kind = 'absent') OR count(c.*) = 0 AS gap
FROM gov.regulation g
LEFT JOIN gov.regulation_control c ON c.reg_code = g.reg_code
GROUP BY g.reg_code, g.name, g.citation, g.regime, g.applies_when,
         g.constrains, g.our_posture, g.status;

GRANT SELECT ON ALL TABLES IN SCHEMA gov TO sdi_admin;
GRANT SELECT ON api.data_rights, api.compliance_register TO sdi_admin;
GRANT EXECUTE ON FUNCTION gov.may_use(uuid, text, text) TO sdi_admin, sdi_integration;
GRANT EXECUTE ON FUNCTION gov.territory_covers(text, text, char) TO sdi_admin, sdi_integration;

-- ---------------------------------------------------------------------
-- Standing invariants, extended
--
-- The contract on api.security_invariants() is that it returns ZERO rows
-- in a correct system, so it can be wired into CI and a nightly check.
-- Adding a row that is permanently true would destroy that, which is why
-- the coverage check below is gated on blocking mode: while governance is
-- advisory the gap is reported by gov.uncovered_publication, and the
-- moment the mode is flipped to blocking the same gap becomes a hard
-- failure. The flip is the go-live gate, and the invariant is what keeps
-- it flipped.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.security_invariants()
RETURNS TABLE (violation text, detail text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = core, sec, gov, pg_catalog, pg_temp
AS $inv$
SELECT 'schema core reachable by app role'::text AS violation,
       r.rolname::text AS detail
FROM pg_roles r
WHERE r.rolname IN ('sdi_public','sdi_investor','sdi_agent')
  AND has_schema_privilege(r.rolname, 'core', 'USAGE')
UNION ALL
SELECT 'internal column readable by non-admin', r.rolname || '.' || c
FROM pg_roles r,
     unnest(ARRAY['acquisition_cost','source_channel','internal_notes']) c
WHERE r.rolname IN ('sdi_public','sdi_investor','sdi_agent')
  AND has_column_privilege(r.rolname, 'core.property', c, 'SELECT')
UNION ALL
SELECT 'RLS disabled on protected table', c.relname::text
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'core' AND c.relkind = 'r' AND NOT c.relrowsecurity
UNION ALL
SELECT 'view is not security_invoker', c.relname::text
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'api' AND c.relkind = 'v'
  AND NOT COALESCE((SELECT option_value = 'true'
                    FROM pg_options_to_table(c.reloptions)
                    WHERE option_name = 'security_invoker'), false)

-- ---- governance --------------------------------------------------
UNION ALL
-- Fair housing, enforced structurally. If a protected characteristic or
-- a named proxy ever appears as a column any caller can read, it can be
-- filtered on, and a filter on it is steering. Catching it here means a
-- future migration cannot introduce one quietly.
SELECT 'prohibited dimension exposed in api', n.nspname || '.' || c.relname || '.' || a.attname
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
JOIN gov.prohibited_dimension d ON lower(a.attname) = d.dimension
WHERE n.nspname IN ('api','core') AND c.relkind IN ('r','v')
UNION ALL
-- A right that ran out while listings were still being published under it.
SELECT DISTINCT 'expired data right still covering a published listing',
       r.right_id || ' expired ' || r.effective_to::text || ', covers ' || p.listing_ref
FROM gov.data_right r
JOIN gov.property_provenance pv ON pv.right_id = r.right_id
JOIN core.property p            ON p.property_id = pv.property_id
JOIN core.property_brand pb     ON pb.property_id = p.property_id AND pb.published
WHERE r.effective_to IS NOT NULL AND r.effective_to < current_date
UNION ALL
-- Only once governance is blocking. See the comment above.
SELECT 'published listing with no confirmed data right',
       u.listing_ref || ' (' || u.reason || ')'
FROM gov.uncovered_publication u
WHERE (SELECT enforcement_mode FROM gov.policy) = 'blocking';
$inv$;

REVOKE ALL ON FUNCTION api.security_invariants() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.security_invariants() TO sdi_admin;

-- What the web tier reads at startup, and what an operator reads to see
-- where the register actually stands.
CREATE VIEW api.governance_status
WITH (security_invoker = true, security_barrier = true) AS
SELECT (SELECT enforcement_mode FROM gov.policy)                    AS enforcement_mode,
       (SELECT count(*) FROM gov.data_right)                        AS rights_recorded,
       (SELECT count(*) FROM gov.data_right
         WHERE review_status = 'counsel_confirmed')                 AS rights_confirmed,
       (SELECT count(*) FROM gov.uncovered_publication)             AS uncovered_published,
       (SELECT count(*) FROM core.property_brand WHERE published)   AS published_total,
       (SELECT count(*) FROM gov.regulation)                        AS regulations_registered,
       (SELECT count(*) FROM gov.regulation g
         WHERE NOT EXISTS (SELECT 1 FROM gov.regulation_control c
                            WHERE c.reg_code = g.reg_code AND c.kind <> 'absent'))
                                                                    AS regulations_without_control;

GRANT SELECT ON api.governance_status TO sdi_admin;

-- The list the application must not contradict. Readable by the app role
-- itself, because the web tier asserts against it before it serves a
-- request -- a control is worth more when the thing it constrains checks
-- it rather than being audited later.
CREATE VIEW api.prohibited_dimensions
WITH (security_invoker = true, security_barrier = true) AS
SELECT dimension, basis, kind, rationale FROM gov.prohibited_dimension;

GRANT USAGE  ON SCHEMA gov TO sdi_app;
GRANT SELECT ON gov.prohibited_dimension TO sdi_app;
GRANT SELECT ON api.prohibited_dimensions TO sdi_app, sdi_admin;

COMMIT;
