-- =====================================================================
-- 28_intake.sql  |  spreadsheet in, reviewed, then released
-- =====================================================================
-- Jessica builds an analysis workbook per property and today those numbers
-- reach the marketplace by being retyped. This is the path that replaces
-- that: load the file into a staging area, let a person look at what
-- arrived, then release either the whole batch or the specific rows that
-- passed review.
--
-- THE SHAPE, AND WHY IT IS THIS SHAPE
--
--   batch    one file, one upload, one person, one moment.
--   row      one property. Holds BOTH the verbatim payload and our
--            reading of it, side by side and never merged.
--
-- Keeping `raw` untouched matters more than it looks. When a released
-- listing turns out to say something surprising, the only useful question
-- is "did the spreadsheet say that, or did we mistranslate it?" -- and
-- that question has no answer if the import overwrote its own input. So
-- raw is written once and never edited, and every parsed column beside it
-- is a claim that can be checked against it.
--
-- Nothing here writes to core.property until somebody releases it. A
-- staging table that auto-promotes on a green validation is not a review
-- queue; it is an import with extra steps.
--
-- ONE THING THE WORKBOOK CONTAINS THAT MUST NOT BECOME A COLUMN
--
-- The SDI workbook carries "Schools Rating (scale 3-30)" and a composite
-- FAVORABLE/INSUFFICIENT deal score partly derived from it. Both are
-- registered in gov.prohibited_dimension as fair-housing proxies: school
-- ratings track the demographics of a catchment, and a composite score is
-- a laundered version of whatever went into it. Offering either as
-- something a buyer can filter or sort on is steering, and the Fair
-- Housing Act does not require that anyone intended it.
--
-- They are therefore kept in `raw` -- we do not quietly edit what Jessica
-- supplied, and staff underwriting may legitimately consider schools --
-- and are NEVER promoted to a column in core or api. api.security_invariants()
-- fails if a column by either name appears there, so this is enforced
-- rather than merely intended.

BEGIN;

CREATE SCHEMA IF NOT EXISTS intake;
GRANT USAGE ON SCHEMA intake TO sdi_admin;

CREATE TABLE intake.batch (
    batch_id     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    source_file  text NOT NULL,
    source_kind  text NOT NULL DEFAULT 'sdi_workbook'
                   CHECK (source_kind IN ('sdi_workbook','csv','manual')),
    -- The version of the mapping that produced the parsed columns. When a
    -- workbook template changes, this is what says which rows were read
    -- under which rules.
    mapping_version text NOT NULL DEFAULT 'v1',
    -- Which instrument the data in this file is held under. Nullable,
    -- because a file can be loaded and reviewed before anyone has settled
    -- that question -- but a release with no right recorded leaves the
    -- listing showing up in gov.uncovered_publication, which is the
    -- visible consequence rather than a silent one.
    right_id     text REFERENCES gov.data_right(right_id),
    uploaded_by  uuid REFERENCES core.person(person_id),
    uploaded_at  timestamptz NOT NULL DEFAULT now(),
    note         text,
    status       text NOT NULL DEFAULT 'open'
                   CHECK (status IN ('open','released','abandoned'))
);

CREATE TABLE intake.row (
    row_id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    batch_id     uuid NOT NULL REFERENCES intake.batch(batch_id) ON DELETE CASCADE,
    row_number   integer NOT NULL,

    -- Verbatim. Written once, never updated. See the header.
    raw          jsonb NOT NULL,

    -- Our reading of it.
    street_address text, unit text, city text, state char(2), zip text,
    property_type  text,
    beds smallint, baths numeric(3,1), sqft integer, year_built smallint,
    lat numeric(9,6), lng numeric(9,6),
    list_price        numeric(12,2),
    gross_rent_annual numeric(12,2),
    opex_annual       numeric(12,2),
    hoa_annual        numeric(12,2),
    market_rent_monthly numeric(10,2),
    property_tax_annual numeric(10,2),
    insurance_annual    numeric(10,2),
    maintenance_annual  numeric(10,2),
    management_fee_bps  integer,
    vacancy_allowance_bps integer,
    lot_sqft integer,
    garage_spaces smallint,
    description text,
    internal_notes text,

    -- Review
    status       text NOT NULL DEFAULT 'pending'
                   CHECK (status IN ('pending','invalid','approved','rejected','released')),
    -- Findings, as an array of {level, field, message}. 'error' blocks a
    -- release; 'warning' does not, because a reviewer who cannot release
    -- anything with an oddity in it will stop reading the oddities.
    problems     jsonb NOT NULL DEFAULT '[]'::jsonb,

    reviewed_by  uuid REFERENCES core.person(person_id),
    reviewed_at  timestamptz,
    review_note  text,

    property_id  uuid REFERENCES core.property(property_id),
    released_at  timestamptz,

    UNIQUE (batch_id, row_number)
);
CREATE INDEX ix_intake_row_status ON intake.row (batch_id, status);

-- ZIP centroids, because the workbook carries an address and no
-- coordinates, and core.property requires a point. A centroid is accurate
-- to a mile or so, which is precisely the accuracy an ungated viewer gets
-- anyway -- and once the address is unlocked the pin is only as good as
-- this table, so a row with no centroid is a validation ERROR rather than
-- a silent (0,0).
CREATE TABLE intake.zip_centroid (
    zip   text PRIMARY KEY,
    city  text NOT NULL,
    state char(2) NOT NULL,
    lat   numeric(9,6) NOT NULL,
    lng   numeric(9,6) NOT NULL,
    source text NOT NULL DEFAULT 'approximate'
);

-- Seeded for the ZIPs the current workbooks land in. This is not a
-- geocoder and does not pretend to be: a ZIP with no row here produces a
-- blocking validation error, which is the correct outcome -- far better
-- than a listing quietly pinned to the middle of the wrong city.
INSERT INTO intake.zip_centroid (zip, city, state, lat, lng) VALUES
 ('64118','Kansas City','MO', 39.224700, -94.577200),
 ('64063','Lees Summit','MO', 38.910800, -94.372200)
ON CONFLICT (zip) DO NOTHING;

COMMENT ON TABLE intake.zip_centroid IS
    'Approximate ZIP centroids. Replace with a real geocoder before the '
    'address gate opens on anything that matters: once unlocked, the pin '
    'is only as accurate as this table.';

-- ---------------------------------------------------------------------
-- Validation
--
-- Runs over the parsed columns, never over `raw`. Errors block release;
-- warnings are shown and do not. The split matters: a reviewer forced to
-- clear every oddity before releasing anything stops reading the
-- oddities, and then the warnings are worth nothing.
-- ---------------------------------------------------------------------
CREATE FUNCTION intake.validate(p_row_id uuid) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = intake, core, pg_temp
AS $fn$
DECLARE
  r intake.row%ROWTYPE;
  p jsonb := '[]'::jsonb;
  v_components numeric;
  v_dup uuid;
BEGIN
  SELECT * INTO r FROM intake.row WHERE row_id = p_row_id;
  IF NOT FOUND THEN RETURN NULL; END IF;

  -- Required to exist as a property at all.
  IF coalesce(btrim(r.street_address),'') = '' THEN
    p := p || jsonb_build_object('level','error','field','street_address','message','no street address');
  END IF;
  IF coalesce(btrim(r.city),'') = '' OR r.state IS NULL THEN
    p := p || jsonb_build_object('level','error','field','city','message','city or state missing');
  END IF;
  IF r.list_price IS NULL OR r.list_price <= 0 THEN
    p := p || jsonb_build_object('level','error','field','list_price','message','no usable price');
  END IF;
  IF r.gross_rent_annual IS NULL OR r.gross_rent_annual <= 0 THEN
    p := p || jsonb_build_object('level','error','field','gross_rent_annual','message','no usable rent');
  END IF;
  IF r.lat IS NULL OR r.lng IS NULL THEN
    p := p || jsonb_build_object('level','error','field','lat',
           'message','no coordinate; add the ZIP to intake.zip_centroid');
  END IF;

  -- Already here?
  SELECT property_id INTO v_dup FROM core.property
   WHERE lower(btrim(street_address)) = lower(btrim(r.street_address))
     AND lower(city) = lower(r.city) AND state = r.state;
  IF v_dup IS NOT NULL THEN
    p := p || jsonb_build_object('level','error','field','street_address',
           'message','a property with this address already exists');
  END IF;

  -- Twice in the same file.
  IF EXISTS (SELECT 1 FROM intake.row o
              WHERE o.batch_id = r.batch_id AND o.row_id <> r.row_id
                AND lower(btrim(o.street_address)) = lower(btrim(r.street_address))) THEN
    p := p || jsonb_build_object('level','error','field','street_address',
           'message','this address appears more than once in the batch');
  END IF;

  -- Sanity, as warnings. Each of these is a plausible typo rather than an
  -- impossibility, which is exactly why a person should see it.
  IF r.beds IS NOT NULL AND (r.beds < 0 OR r.beds > 20) THEN
    p := p || jsonb_build_object('level','warning','field','beds','message','unusual bedroom count');
  END IF;
  IF r.sqft IS NOT NULL AND (r.sqft < 200 OR r.sqft > 20000) THEN
    p := p || jsonb_build_object('level','warning','field','sqft','message','unusual floor area');
  END IF;
  IF r.year_built IS NOT NULL AND (r.year_built < 1800
      OR r.year_built > extract(year from current_date) + 2) THEN
    p := p || jsonb_build_object('level','warning','field','year_built','message','unusual year built');
  END IF;
  IF r.opex_annual IS NOT NULL AND r.gross_rent_annual IS NOT NULL
     AND r.opex_annual >= r.gross_rent_annual THEN
    p := p || jsonb_build_object('level','warning','field','opex_annual',
           'message','operating expenses meet or exceed gross rent');
  END IF;

  -- Does the workbook's own expense total agree with its own components?
  -- Worth checking rather than assuming, because this is the figure the
  -- published cap rate is computed from.
  --
  -- All six components, not the three obvious ones. Management and
  -- vacancy are carried as rates rather than amounts, so they have to be
  -- applied to the rent to be comparable -- and an earlier version that
  -- summed only tax, insurance and maintenance flagged every correctly
  -- built workbook. A check that fires on everything is one a reviewer
  -- learns to click past, which costs more than not having it.
  v_components := coalesce(r.property_tax_annual,0)
                + coalesce(r.insurance_annual,0)
                + coalesce(r.maintenance_annual,0)
                + coalesce(r.gross_rent_annual,0) * coalesce(r.management_fee_bps,0) / 10000.0
                + coalesce(r.gross_rent_annual,0) * coalesce(r.vacancy_allowance_bps,0) / 10000.0;
  IF r.opex_annual IS NOT NULL AND v_components > 0
     AND abs(r.opex_annual - v_components) > greatest(r.opex_annual * 0.12, 600) THEN
    p := p || jsonb_build_object('level','warning','field','opex_annual',
           'message', format('expense total %s does not reconcile with its components (%s)',
                             round(r.opex_annual), round(v_components)));
  END IF;

  UPDATE intake.row
     SET problems = p,
         status = CASE
                    WHEN status IN ('released','rejected') THEN status
                    WHEN EXISTS (SELECT 1 FROM jsonb_array_elements(p) e
                                  WHERE e->>'level' = 'error') THEN 'invalid'
                    WHEN status = 'approved' THEN 'approved'
                    ELSE 'pending'
                  END
   WHERE row_id = p_row_id;

  RETURN p;
END $fn$;

CREATE FUNCTION intake.validate_batch(p_batch_id uuid) RETURNS integer
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = intake, pg_temp
AS $fn$
DECLARE n integer := 0; rec record;
BEGIN
  FOR rec IN SELECT row_id FROM intake.row WHERE batch_id = p_batch_id LOOP
    PERFORM intake.validate(rec.row_id); n := n + 1;
  END LOOP;
  RETURN n;
END $fn$;

-- ---------------------------------------------------------------------
-- Review
-- ---------------------------------------------------------------------
CREATE FUNCTION api.review_intake_rows(p_row_ids uuid[], p_decision text,
                                       p_note text DEFAULT NULL)
RETURNS integer
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = intake, core, sec, pg_temp
AS $fn$
DECLARE v_actor uuid := sec.actor_id(); n integer;
BEGIN
  IF v_actor IS NULL OR NOT sec.is_internal() THEN
    RAISE EXCEPTION 'staff only' USING ERRCODE = '42501';
  END IF;
  IF p_decision NOT IN ('approved','rejected','pending') THEN
    RAISE EXCEPTION 'decision must be approved, rejected or pending' USING ERRCODE = '22023';
  END IF;

  UPDATE intake.row
     SET status = p_decision, reviewed_by = v_actor, reviewed_at = now(),
         review_note = coalesce(p_note, review_note)
   WHERE row_id = ANY(p_row_ids)
     -- A released row is finished. A row with a blocking error cannot be
     -- approved -- approving past an error is how the validation stops
     -- meaning anything.
     AND status <> 'released'
     AND (p_decision <> 'approved' OR status <> 'invalid');
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $fn$;

-- Approve everything in a batch that is not blocked. The "select ALL"
-- affordance, and deliberately narrower than it sounds: it approves what
-- is releasable and leaves the invalid rows exactly where they are.
CREATE FUNCTION api.approve_batch(p_batch_id uuid, p_note text DEFAULT NULL)
RETURNS integer
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = intake, sec, pg_temp
AS $fn$
DECLARE ids uuid[];
BEGIN
  SELECT array_agg(row_id) INTO ids FROM intake.row
   WHERE batch_id = p_batch_id AND status = 'pending';
  IF ids IS NULL THEN RETURN 0; END IF;
  RETURN api.review_intake_rows(ids, 'approved', p_note);
END $fn$;

-- ---------------------------------------------------------------------
-- Release: staging becomes a listing
--
-- The only place in this file that writes to core.property, and it only
-- ever acts on rows a person marked approved.
-- ---------------------------------------------------------------------
-- Listing references come from a sequence, not from count(*). Counting
-- rows reuses a number after a deletion and races two concurrent
-- releases into the same reference -- and listing_ref is UNIQUE, so the
-- second one fails at commit having already done its work.
CREATE SEQUENCE intake.listing_ref_seq;
GRANT USAGE ON SEQUENCE intake.listing_ref_seq TO sdi_admin;

CREATE FUNCTION api.release_intake_rows(p_row_ids uuid[], p_brand text DEFAULT 'BRAND_A',
                                        p_publish boolean DEFAULT true)
RETURNS TABLE (out_row_id uuid, out_listing_ref text, out_property_id uuid, outcome text)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = intake, core, gov, sec, pg_temp
AS $fn$
-- The OUT parameters are prefixed because PL/pgSQL resolves a bare name
-- to the variable before the column, so an OUT parameter called
-- listing_ref silently shadows core.property.listing_ref inside every
-- query in this body.
DECLARE v_actor uuid := sec.actor_id(); r intake.row%ROWTYPE; v_pid uuid; v_ref text;
        v_right text;
BEGIN
  IF v_actor IS NULL OR NOT sec.is_internal() THEN
    RAISE EXCEPTION 'staff only' USING ERRCODE = '42501';
  END IF;

  FOR r IN SELECT * FROM intake.row WHERE intake.row.row_id = ANY(p_row_ids) LOOP
    SELECT b.right_id INTO v_right FROM intake.batch b WHERE b.batch_id = r.batch_id;
    IF r.status <> 'approved' THEN
      out_row_id := r.row_id; out_listing_ref := NULL; out_property_id := NULL;
      outcome := format('skipped: status is %s, not approved', r.status);
      RETURN NEXT; CONTINUE;
    END IF;

    v_ref := 'SDI-' || to_char(now(),'YYMM') || '-'
             || lpad(nextval('intake.listing_ref_seq')::text, 3, '0');

    INSERT INTO core.property
      (listing_ref, status, city, state, zip, property_type, beds, baths, sqft, year_built,
       list_price, gross_rent_annual, opex_annual, hoa_annual,
       street_address, unit, lat, lng, source_channel, internal_notes)
    VALUES
      (v_ref, 'active', r.city, r.state, r.zip,
       coalesce(r.property_type,'Single Family'), r.beds, r.baths, r.sqft, r.year_built,
       r.list_price, r.gross_rent_annual, coalesce(r.opex_annual,0), coalesce(r.hoa_annual,0),
       r.street_address, r.unit, r.lat, r.lng, 'Workbook import', r.internal_notes)
    RETURNING core.property.property_id INTO v_pid;

    INSERT INTO core.property_brand (property_id, brand_code, published)
    VALUES (v_pid, p_brand, p_publish);

    INSERT INTO core.property_detail
      (property_id, headline, description, market_rent_monthly, rent_basis,
       property_tax_annual, insurance_annual, maintenance_annual,
       management_fee_bps, vacancy_allowance_bps, lot_sqft, garage_spaces)
    VALUES
      (v_pid,
       format('%s-bed %s in %s', coalesce(r.beds,0),
              lower(coalesce(r.property_type,'home')), r.city),
       r.description, r.market_rent_monthly, 'market_estimate',
       r.property_tax_annual, r.insurance_annual, r.maintenance_annual,
       r.management_fee_bps, r.vacancy_allowance_bps, r.lot_sqft, r.garage_spaces);

    -- Provenance, if the batch names an instrument. Recorded per scope so
    -- the listing facts and any media it later gains are not conflated:
    -- listing copy and photographs are routinely licensed more narrowly
    -- than the numbers.
    IF v_right IS NOT NULL THEN
      INSERT INTO gov.property_provenance (property_id, right_id, scope)
      SELECT v_pid, v_right, sc
        FROM unnest(ARRAY['listing_facts','valuation']) AS sc
      ON CONFLICT DO NOTHING;
    END IF;

    UPDATE intake.row SET status = 'released', property_id = v_pid, released_at = now()
     WHERE intake.row.row_id = r.row_id;

    out_row_id := r.row_id; out_listing_ref := v_ref; out_property_id := v_pid;
    outcome := 'released';
    RETURN NEXT;
  END LOOP;

  -- A batch with nothing left to release is finished, however it got
  -- there. Closing it only in release_batch() left a batch released row
  -- by row still reading "open" forever, which is the sort of small lie
  -- that makes people stop trusting the status column.
  UPDATE intake.batch b SET status = 'released'
   WHERE b.status = 'open'
     AND EXISTS (SELECT 1 FROM intake.row x
                  WHERE x.batch_id = b.batch_id AND x.status = 'released')
     AND NOT EXISTS (SELECT 1 FROM intake.row x
                      WHERE x.batch_id = b.batch_id AND x.status IN ('approved','pending'));
END $fn$;

CREATE FUNCTION api.release_batch(p_batch_id uuid, p_brand text DEFAULT 'BRAND_A',
                                  p_publish boolean DEFAULT true)
RETURNS TABLE (out_row_id uuid, out_listing_ref text, out_property_id uuid, outcome text)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = intake, sec, pg_temp
AS $fn$
DECLARE ids uuid[];
BEGIN
  SELECT array_agg(intake.row.row_id) INTO ids FROM intake.row
   WHERE batch_id = p_batch_id AND status = 'approved';
  IF ids IS NULL THEN RETURN; END IF;
  -- release_intake_rows closes the batch itself when nothing is left.
  RETURN QUERY SELECT * FROM api.release_intake_rows(ids, p_brand, p_publish);
END $fn$;

-- ---------------------------------------------------------------------
-- What a reviewer reads
-- ---------------------------------------------------------------------
CREATE VIEW api.intake_batch
WITH (security_invoker = true, security_barrier = true) AS
SELECT b.batch_id, b.source_file, b.source_kind, b.mapping_version,
       b.uploaded_at, b.note, b.status,
       count(r.*)                                            AS rows_total,
       count(*) FILTER (WHERE r.status = 'pending')          AS rows_pending,
       count(*) FILTER (WHERE r.status = 'invalid')          AS rows_invalid,
       count(*) FILTER (WHERE r.status = 'approved')         AS rows_approved,
       count(*) FILTER (WHERE r.status = 'rejected')         AS rows_rejected,
       count(*) FILTER (WHERE r.status = 'released')         AS rows_released
FROM intake.batch b LEFT JOIN intake.row r USING (batch_id)
GROUP BY b.batch_id, b.source_file, b.source_kind, b.mapping_version,
         b.uploaded_at, b.note, b.status
ORDER BY b.uploaded_at DESC;

CREATE VIEW api.intake_row
WITH (security_invoker = true, security_barrier = true) AS
SELECT row_id, batch_id, row_number, status, problems,
       street_address, unit, city, state, zip, property_type,
       beds, baths, sqft, year_built, list_price,
       gross_rent_annual, opex_annual, hoa_annual, market_rent_monthly,
       -- The derived figures a reviewer actually judges on, computed here
       -- rather than trusted from the file.
       (gross_rent_annual - coalesce(opex_annual,0) - coalesce(hoa_annual,0)) AS noi_annual,
       round((gross_rent_annual - coalesce(opex_annual,0) - coalesce(hoa_annual,0))
             / NULLIF(list_price,0), 4)                                       AS cap_rate,
       reviewed_at, review_note, property_id, released_at
FROM intake.row
ORDER BY batch_id, row_number;

GRANT SELECT ON ALL TABLES IN SCHEMA intake TO sdi_admin;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA intake TO sdi_integration;
GRANT USAGE ON SCHEMA intake TO sdi_integration;
GRANT SELECT ON api.intake_batch, api.intake_row TO sdi_admin, sdi_integration;

REVOKE ALL ON FUNCTION api.review_intake_rows(uuid[], text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.approve_batch(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.release_intake_rows(uuid[], text, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.release_batch(uuid, text, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.review_intake_rows(uuid[], text, text)     TO sdi_admin;
GRANT EXECUTE ON FUNCTION api.approve_batch(uuid, text)                  TO sdi_admin;
GRANT EXECUTE ON FUNCTION api.release_intake_rows(uuid[], text, boolean) TO sdi_admin;
GRANT EXECUTE ON FUNCTION api.release_batch(uuid, text, boolean)         TO sdi_admin;
GRANT EXECUTE ON FUNCTION intake.validate(uuid)        TO sdi_admin, sdi_integration;
GRANT EXECUTE ON FUNCTION intake.validate_batch(uuid)  TO sdi_admin, sdi_integration;

-- ---------------------------------------------------------------------
-- The instrument the workbooks are held under
--
-- Two different things arrive in one file and they are not held on the
-- same terms, which is why this is recorded as unreviewed rather than
-- waved through.
--
--   The financial modelling -- offer, rents, expenses, projections -- is
--   SDI's own work. Nobody else has a claim in it.
--
--   The property description is verbatim MLS listing copy ("Welcome home
--   to this beautifully updated property...") written by the listing
--   agent. Whether SDI may republish it turns on the MLS agreement, and
--   that has not been established.
--
-- So: recorded, narrow, and visibly unconfirmed. gov.may_use() honours
-- only counsel-confirmed rights, so this grants nothing yet -- releasing
-- under it produces an advisory warning and a row in
-- gov.uncovered_publication rather than silent publication.
-- ---------------------------------------------------------------------
INSERT INTO gov.data_right
 (right_id, name, grantor, instrument, reference, survives_termination,
  review_status, notes) VALUES
 ('SDI-WORKBOOK','SDI analysis workbook','SDI','seller_submission',
  'Per-property .xlsm analysis workbooks', true, 'unreviewed',
  'The financial analysis is SDI''s own and needs no external instrument. The '
  'listing DESCRIPTION carried in the same file is verbatim MLS copy authored '
  'by the listing agent, and the right to republish it has not been '
  'established -- that is what keeps this row unreviewed. Splitting the two '
  'means recording where the description actually comes from, per property.')
ON CONFLICT (right_id) DO NOTHING;

INSERT INTO gov.data_right_territory (right_id, territory_id)
VALUES ('SDI-WORKBOOK','US') ON CONFLICT DO NOTHING;

INSERT INTO gov.data_right_use (right_id, use_code, posture, condition) VALUES
 ('SDI-WORKBOOK','internal_analysis','granted',NULL),
 ('SDI-WORKBOOK','gated_display','unclear','Turns on the MLS agreement for the listing copy'),
 ('SDI-WORKBOOK','public_display','unclear','Same question'),
 ('SDI-WORKBOOK','derive','granted','The derived figures are SDI''s own work'),
 ('SDI-WORKBOOK','redistribute','refused',NULL),
 ('SDI-WORKBOOK','export','refused',NULL),
 ('SDI-WORKBOOK','marketing','unclear',NULL),
 ('SDI-WORKBOOK','model_training','refused',NULL)
ON CONFLICT DO NOTHING;

COMMIT;
