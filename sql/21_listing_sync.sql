-- =====================================================================
-- 21_listing_sync.sql  |  keeping listing status honest against a feed
-- =====================================================================
-- The problem. A property in this marketplace is also listed somewhere
-- else -- an MLS, a portal, a wholesaler's sheet. It goes under contract,
-- it sells, it is withdrawn, and nobody tells us. An investor who calls
-- about a house that went pending three weeks ago is the single most
-- expensive kind of stale data this system can hold.
--
-- The wrinkle that shapes the whole design: ESCROW FAILS. A property that
-- went pending comes back to market perhaps one time in five. So this is
-- not a one-way "mark it gone" job -- it has to follow the source in both
-- directions, and a design that only knows how to retire a listing will
-- quietly bury the ones that come back.
--
-- Four tables and one rule.
--
--   listing_source     who is telling us. Not all sources are equal, so
--                      each one carries how far we trust it.
--   property_external  the mapping: our property <-> their id.
--   observation        append-only. What a source said, when, verbatim,
--                      alongside our reading of it. Never updated.
--   status_change      what we actually did about it, and why.
--
-- The rule: an observation NEVER writes core.property.status directly.
-- It is recorded, then reconciled. That separation is what makes the
-- history readable after the fact ("why is this pending?") and what lets
-- an unreliable source raise a flag without being allowed to act.

BEGIN;

CREATE SCHEMA IF NOT EXISTS feed;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sdi_integration') THEN
    CREATE ROLE sdi_integration NOLOGIN;
  END IF;
END $$;

GRANT USAGE ON SCHEMA feed TO sdi_integration;

-- ---------------------------------------------------------------------
-- Who is telling us
-- ---------------------------------------------------------------------
CREATE TABLE feed.listing_source (
    source_code   text PRIMARY KEY,
    name          text NOT NULL,
    kind          text NOT NULL CHECK (kind IN
                    ('reso_web_api','vendor_api','manual','csv','scrape')),
    base_url      text,

    -- The decision every integration eventually has to make explicitly,
    -- so it is a column rather than an assumption in the worker.
    --
    -- authoritative: this source's word alone may change our status.
    --                An MLS feed under a signed data agreement is.
    -- advisory:      this source may only raise a flag for a human. A
    --                scraper is advisory whatever its accuracy, because
    --                its failure mode is a silent layout change that
    --                looks exactly like "the listing is gone".
    authoritative boolean NOT NULL DEFAULT false,

    -- How many consecutive checks must agree before we act. One missed
    -- fetch is a network blip, not a delisting.
    confirm_after smallint NOT NULL DEFAULT 2 CHECK (confirm_after BETWEEN 1 AND 10),

    -- May this source retire a listing outright (sold/withdrawn)? Even an
    -- authoritative feed is usually allowed to move a listing to pending
    -- unattended but not to sold, because sold is the one transition this
    -- business does not undo.
    may_retire    boolean NOT NULL DEFAULT false,

    active        boolean NOT NULL DEFAULT true,
    check_cron    text,
    notes         text,
    created_at    timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- Their vocabulary -> ours
--
-- Every feed has its own words. RESO says 'Active Under Contract', one
-- portal says 'Pending', another says 'Contingent'. Mapping them in a
-- TABLE rather than in a switch statement means a new source, or a term
-- a source added last week, is a row -- not a deploy.
--
-- An unmapped term is not an error and is not guessed. It is recorded
-- with mapped_status NULL, which is a visible, queryable "we saw
-- something we do not understand" rather than a silent default.
-- ---------------------------------------------------------------------
CREATE TABLE feed.status_map (
    source_code   text NOT NULL REFERENCES feed.listing_source(source_code) ON DELETE CASCADE,
    raw_status    text NOT NULL,
    mapped_status text CHECK (mapped_status IN
                    ('draft','active','coming_soon','pending','sold','withdrawn')),
    PRIMARY KEY (source_code, raw_status)
);
-- Case-insensitive uniqueness. A primary key cannot be an expression, so
-- the case rule is an index: 'Pending' and 'pending' are one term.
CREATE UNIQUE INDEX ux_status_map_ci ON feed.status_map (source_code, lower(raw_status));

-- ---------------------------------------------------------------------
-- Our property <-> their id
-- ---------------------------------------------------------------------
CREATE TABLE feed.property_external (
    property_id     uuid NOT NULL REFERENCES core.property(property_id) ON DELETE CASCADE,
    source_code     text NOT NULL REFERENCES feed.listing_source(source_code) ON DELETE CASCADE,

    -- Their key. A RESO ListingKey, an MLS number, a portal's zpid.
    external_id     text NOT NULL,
    external_url    text,

    first_seen_at   timestamptz NOT NULL DEFAULT now(),
    -- Distinct on purpose: "we looked" and "we found it" are different
    -- facts, and their difference is exactly how a delisting is detected.
    last_checked_at timestamptz,
    last_seen_at    timestamptz,

    last_raw_status text,
    last_price      numeric(12,2),
    miss_streak     smallint NOT NULL DEFAULT 0,
    agree_streak    smallint NOT NULL DEFAULT 0,

    enabled         boolean NOT NULL DEFAULT true,
    PRIMARY KEY (property_id, source_code),
    UNIQUE (source_code, external_id)
);

-- ---------------------------------------------------------------------
-- Append-only. What was seen.
-- ---------------------------------------------------------------------
CREATE TABLE feed.observation (
    observation_id  bigserial PRIMARY KEY,
    run_id          uuid,
    property_id     uuid NOT NULL REFERENCES core.property(property_id) ON DELETE CASCADE,
    source_code     text NOT NULL REFERENCES feed.listing_source(source_code) ON DELETE CASCADE,
    observed_at     timestamptz NOT NULL DEFAULT now(),

    -- 'found'    the listing was there and readable
    -- 'missing'  the source answered, and the listing was not in it
    -- 'error'    we could not tell. NOT the same as missing, and treating
    --            it as missing is how a feed outage retires a portfolio.
    outcome         text NOT NULL CHECK (outcome IN ('found','missing','error')),

    raw_status      text,
    mapped_status   text,
    list_price      numeric(12,2),
    payload         jsonb,
    error_detail    text
);
CREATE INDEX ix_obs_property ON feed.observation (property_id, observed_at DESC);
CREATE INDEX ix_obs_run      ON feed.observation (run_id);
-- The unmapped-term worklist, which is the thing an operator should be
-- reading weekly. Partial, so it stays small.
CREATE INDEX ix_obs_unmapped ON feed.observation (source_code, raw_status)
    WHERE outcome = 'found' AND mapped_status IS NULL;

-- ---------------------------------------------------------------------
-- What we did about it
-- ---------------------------------------------------------------------
CREATE TABLE feed.status_change (
    change_id      bigserial PRIMARY KEY,
    property_id    uuid NOT NULL REFERENCES core.property(property_id) ON DELETE CASCADE,
    from_status    text NOT NULL,
    to_status      text NOT NULL,
    reason         text NOT NULL,
    source_code    text REFERENCES feed.listing_source(source_code),
    observation_id bigint REFERENCES feed.observation(observation_id),
    -- 'worker' for an automatic change, a person_id for a human one. A
    -- human change is a fact the reconciler must respect, not overwrite.
    actor          text NOT NULL DEFAULT 'worker',
    changed_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_change_property ON feed.status_change (property_id, changed_at DESC);

-- Flagged for a person. An advisory source, an unmapped term, or a
-- retirement the worker is not allowed to make on its own lands here
-- instead of changing anything.
CREATE TABLE feed.review_flag (
    flag_id        bigserial PRIMARY KEY,
    property_id    uuid NOT NULL REFERENCES core.property(property_id) ON DELETE CASCADE,
    source_code    text REFERENCES feed.listing_source(source_code),
    observation_id bigint REFERENCES feed.observation(observation_id),
    kind           text NOT NULL,
    detail         text NOT NULL,
    raised_at      timestamptz NOT NULL DEFAULT now(),
    resolved_at    timestamptz,
    resolved_by    uuid REFERENCES core.person(person_id),
    resolution     text
);
CREATE INDEX ix_flag_open ON feed.review_flag (property_id) WHERE resolved_at IS NULL;

-- ---------------------------------------------------------------------
-- The manual queue
--
-- A staff member looked at the listing and is telling us what they saw.
-- It is a queue rather than a direct write because it goes through the
-- SAME reconciler as every feed: one code path decides what a status
-- report means, so a human check is auditable, reversible and visible in
-- feed.observation next to the automated ones -- instead of being an
-- UPDATE that leaves no trace of who or why.
-- ---------------------------------------------------------------------
CREATE TABLE feed.manual_check (
    check_id    bigserial PRIMARY KEY,
    property_id uuid NOT NULL REFERENCES core.property(property_id) ON DELETE CASCADE,
    raw_status  text NOT NULL,
    list_price  numeric(12,2),
    note        text,
    noted_by    uuid REFERENCES core.person(person_id),
    noted_at    timestamptz NOT NULL DEFAULT now(),
    consumed_at timestamptz
);
CREATE INDEX ix_manual_pending ON feed.manual_check (property_id, noted_at)
    WHERE consumed_at IS NULL;

-- ---------------------------------------------------------------------
-- Reconciliation
--
-- One function, called once per observation. Everything it is allowed to
-- do is bounded by the source's own row, so tightening a source is a
-- data change and not a code change.
-- ---------------------------------------------------------------------
CREATE FUNCTION feed.reconcile(p_observation_id bigint) RETURNS text
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = feed, core, pg_temp
AS $fn$
DECLARE
  o          feed.observation%ROWTYPE;
  s          feed.listing_source%ROWTYPE;
  x          feed.property_external%ROWTYPE;
  cur_status text;
  target     text;
  human_at   timestamptz;
BEGIN
  SELECT * INTO o FROM feed.observation WHERE observation_id = p_observation_id;
  IF NOT FOUND THEN RETURN 'no such observation'; END IF;
  SELECT * INTO s FROM feed.listing_source     WHERE source_code = o.source_code;
  SELECT * INTO x FROM feed.property_external
   WHERE property_id = o.property_id AND source_code = o.source_code;
  SELECT status INTO cur_status FROM core.property WHERE property_id = o.property_id;

  -- An error is not a signal. Record the streak stays where it was and
  -- leave. A feed that is down must not look like a market that emptied.
  IF o.outcome = 'error' THEN
    UPDATE feed.property_external SET last_checked_at = o.observed_at
     WHERE property_id = o.property_id AND source_code = o.source_code;
    RETURN 'error ignored';
  END IF;

  -- A staff member who set the status by hand after this observation was
  -- taken knows something the feed does not. Defer.
  SELECT max(changed_at) INTO human_at FROM feed.status_change
   WHERE property_id = o.property_id AND actor <> 'worker';
  IF human_at IS NOT NULL AND human_at > o.observed_at THEN
    RETURN 'superseded by a human change';
  END IF;

  IF o.outcome = 'missing' THEN
    UPDATE feed.property_external
       SET last_checked_at = o.observed_at,
           miss_streak = miss_streak + 1, agree_streak = 0
     WHERE property_id = o.property_id AND source_code = o.source_code
    RETURNING * INTO x;

    IF x.miss_streak < s.confirm_after THEN
      RETURN format('missing, %s of %s', x.miss_streak, s.confirm_after);
    END IF;
    -- Gone from the feed is not the same as sold. We do not know which,
    -- so we do not guess: withdrawn is the reversible one.
    target := 'withdrawn';
  ELSE
    UPDATE feed.property_external
       SET last_checked_at = o.observed_at, last_seen_at = o.observed_at,
           last_raw_status = o.raw_status, last_price = o.list_price,
           miss_streak = 0,
           agree_streak = CASE WHEN last_raw_status IS NOT DISTINCT FROM o.raw_status
                               THEN agree_streak + 1 ELSE 1 END
     WHERE property_id = o.property_id AND source_code = o.source_code
    RETURNING * INTO x;

    IF o.mapped_status IS NULL THEN
      INSERT INTO feed.review_flag (property_id, source_code, observation_id, kind, detail)
      VALUES (o.property_id, o.source_code, o.observation_id, 'unmapped_status',
              format('%s reported %L, which has no mapping', o.source_code, o.raw_status));
      RETURN 'unmapped status flagged';
    END IF;
    target := o.mapped_status;
  END IF;

  IF target = cur_status THEN
    RETURN 'no change';
  END IF;

  -- Everything below is a real transition. Three gates in order of how
  -- much damage getting it wrong would do.

  -- 1. An advisory source never writes. It asks.
  IF NOT s.authoritative THEN
    INSERT INTO feed.review_flag (property_id, source_code, observation_id, kind, detail)
    VALUES (o.property_id, o.source_code, o.observation_id, 'advisory_status_change',
            format('%s suggests %s -> %s', o.source_code, cur_status, target));
    RETURN 'flagged for review';
  END IF;

  -- 2. Retiring a listing needs the explicit permission. 'sold' in
  --    particular is the transition nobody undoes by accident, so a
  --    source that may not retire only ever gets to raise it.
  IF target IN ('sold','withdrawn') AND NOT s.may_retire THEN
    INSERT INTO feed.review_flag (property_id, source_code, observation_id, kind, detail)
    VALUES (o.property_id, o.source_code, o.observation_id, 'retire_requires_review',
            format('%s reports %s; source may not retire listings', o.source_code, target));
    RETURN 'retirement flagged';
  END IF;

  -- 3. Confirmation. The source must have said the same thing twice --
  --    except coming back to market, which is acted on the first time it
  --    is seen. A failed escrow is a listing that is live again NOW, and
  --    waiting a night to believe it is a night of a saleable property
  --    shown as unavailable. The asymmetry is deliberate: this direction
  --    is the cheap one to get wrong.
  --
  --    Only for the 'found' branch. An absence counts its own
  --    confirmations in miss_streak, above, and reaching this line at all
  --    means it already cleared them -- checking agree_streak here too
  --    would demand a confirmation that the missing path never records,
  --    and no listing would ever be retired.
  IF o.outcome = 'found' AND target <> 'active' AND x.agree_streak < s.confirm_after THEN
    RETURN format('awaiting confirmation, %s of %s', x.agree_streak, s.confirm_after);
  END IF;

  UPDATE core.property SET status = target WHERE property_id = o.property_id;
  INSERT INTO feed.status_change
    (property_id, from_status, to_status, reason, source_code, observation_id)
  VALUES (o.property_id, cur_status, target,
          CASE WHEN o.outcome = 'missing'
               THEN format('absent from %s for %s consecutive checks', o.source_code, x.miss_streak)
               ELSE format('%s reports %L', o.source_code, o.raw_status) END,
          o.source_code, o.observation_id);

  RETURN format('%s -> %s', cur_status, target);
END $fn$;

-- Record and reconcile in one call, so the worker cannot record an
-- observation and then fail before acting on it.
CREATE FUNCTION feed.observe(
    p_property_id uuid, p_source_code text, p_outcome text,
    p_raw_status text DEFAULT NULL, p_list_price numeric DEFAULT NULL,
    p_payload jsonb DEFAULT NULL, p_error text DEFAULT NULL,
    p_run_id uuid DEFAULT NULL)
RETURNS TABLE (observation_id bigint, result text)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = feed, core, pg_temp
AS $fn$
DECLARE v_id bigint; v_mapped text;
BEGIN
  SELECT m.mapped_status INTO v_mapped
    FROM feed.status_map m
   WHERE m.source_code = p_source_code
     AND lower(m.raw_status) = lower(p_raw_status);

  INSERT INTO feed.observation
    (run_id, property_id, source_code, outcome, raw_status, mapped_status,
     list_price, payload, error_detail)
  VALUES (p_run_id, p_property_id, p_source_code, p_outcome, p_raw_status, v_mapped,
          p_list_price, p_payload, p_error)
  RETURNING feed.observation.observation_id INTO v_id;

  RETURN QUERY SELECT v_id, feed.reconcile(v_id);
END $fn$;

-- What the nightly job should look at, oldest check first, so a run that
-- is cut short has still done the most overdue work.
CREATE VIEW feed.due_for_check AS
SELECT x.property_id, x.source_code, x.external_id, x.external_url,
       x.last_checked_at, x.miss_streak, p.listing_ref, p.status AS our_status,
       s.kind, s.base_url
FROM feed.property_external x
JOIN feed.listing_source s ON s.source_code = x.source_code
JOIN core.property p       ON p.property_id = x.property_id
WHERE x.enabled AND s.active
  AND p.status IN ('active','coming_soon','pending')
ORDER BY x.last_checked_at NULLS FIRST;

GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA feed TO sdi_integration;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA feed TO sdi_integration;
GRANT EXECUTE ON FUNCTION feed.reconcile(bigint) TO sdi_integration;
GRANT EXECUTE ON FUNCTION feed.observe(uuid,text,text,text,numeric,jsonb,text,uuid)
   TO sdi_integration;

-- ---------------------------------------------------------------------
-- Staff-facing surface
-- ---------------------------------------------------------------------
CREATE VIEW api.listing_feed_status
WITH (security_invoker = true, security_barrier = true) AS
SELECT p.listing_ref, p.property_id, p.status AS our_status,
       x.source_code, x.external_id, x.external_url,
       x.last_raw_status, x.last_seen_at, x.last_checked_at,
       x.miss_streak, x.agree_streak,
       (SELECT count(*) FROM feed.review_flag f
         WHERE f.property_id = p.property_id AND f.resolved_at IS NULL) AS open_flags
FROM api.property p
LEFT JOIN feed.property_external x ON x.property_id = p.property_id;

CREATE VIEW api.listing_review_queue
WITH (security_invoker = true, security_barrier = true) AS
SELECT f.flag_id, f.property_id, p.listing_ref, p.status AS our_status,
       f.source_code, f.kind, f.detail, f.raised_at,
       o.raw_status, o.list_price, o.observed_at
FROM feed.review_flag f
JOIN core.property p         ON p.property_id = f.property_id
LEFT JOIN feed.observation o ON o.observation_id = f.observation_id
WHERE f.resolved_at IS NULL
ORDER BY f.raised_at;

GRANT USAGE  ON SCHEMA feed TO sdi_admin;
GRANT SELECT ON ALL TABLES IN SCHEMA feed TO sdi_admin;
GRANT SELECT ON api.listing_feed_status, api.listing_review_queue TO sdi_admin;

-- A human acting on a flag. Writes the same status_change table the
-- worker does, with actor = the person, which is what makes the
-- "defer to a human" rule in reconcile() work.
CREATE FUNCTION api.resolve_listing_flag(
    p_flag_id bigint, p_new_status text DEFAULT NULL, p_resolution text DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = feed, core, sec, pg_temp
AS $fn$
DECLARE v_actor uuid := sec.actor_id(); f feed.review_flag%ROWTYPE; cur text;
BEGIN
  IF v_actor IS NULL OR NOT sec.is_internal() THEN
    RAISE EXCEPTION 'staff only' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO f FROM feed.review_flag WHERE flag_id = p_flag_id AND resolved_at IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'no such open flag' USING ERRCODE = '42501'; END IF;

  IF p_new_status IS NOT NULL THEN
    SELECT status INTO cur FROM core.property WHERE property_id = f.property_id;
    UPDATE core.property SET status = p_new_status WHERE property_id = f.property_id;
    INSERT INTO feed.status_change
      (property_id, from_status, to_status, reason, source_code, observation_id, actor)
    VALUES (f.property_id, cur, p_new_status,
            coalesce(p_resolution, 'resolved from the review queue'),
            f.source_code, f.observation_id, v_actor::text);
  END IF;

  UPDATE feed.review_flag
     SET resolved_at = now(), resolved_by = v_actor,
         resolution = coalesce(p_resolution, 'reviewed')
   WHERE flag_id = p_flag_id;
  RETURN 'resolved';
END $fn$;

REVOKE ALL ON FUNCTION api.resolve_listing_flag(bigint, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.resolve_listing_flag(bigint, text, text) TO sdi_admin;

-- A staff member reporting what they saw. The sweep picks it up on its
-- next run; nothing here changes a status directly.
CREATE FUNCTION api.record_manual_check(
    p_property_id uuid, p_raw_status text,
    p_list_price numeric DEFAULT NULL, p_note text DEFAULT NULL)
RETURNS bigint
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = feed, core, sec, pg_temp
AS $fn$
DECLARE v_actor uuid := sec.actor_id(); v_id bigint;
BEGIN
  IF v_actor IS NULL OR NOT sec.is_internal() THEN
    RAISE EXCEPTION 'staff only' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM feed.status_map
                  WHERE source_code = 'MANUAL' AND lower(raw_status) = lower(p_raw_status)) THEN
    RAISE EXCEPTION 'unknown status %', p_raw_status USING ERRCODE = '22023';
  END IF;
  INSERT INTO feed.manual_check (property_id, raw_status, list_price, note, noted_by)
  VALUES (p_property_id, p_raw_status, p_list_price, p_note, v_actor)
  RETURNING check_id INTO v_id;
  RETURN v_id;
END $fn$;

REVOKE ALL ON FUNCTION api.record_manual_check(uuid, text, numeric, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.record_manual_check(uuid, text, numeric, text) TO sdi_admin;

COMMIT;
