-- =====================================================================
-- 11_pipeline.sql  |  deals, stages, and the history of both
-- =====================================================================
-- A deal is where a property and an investor meet, so it inherits the
-- visibility problem: an agent may see only their own deals, an investor
-- only theirs, and neither may see the internal band on the property the
-- deal points at. The policies below reuse sec.actor() rather than
-- inventing a second notion of identity.
--
-- Stage history is append-only and written by trigger, not by the
-- application. "When did this go under contract" is the question the
-- business actually asks, and an application that forgets to log once
-- makes the answer permanently wrong.

BEGIN;

CREATE TABLE core.pipeline (
    pipeline_code text PRIMARY KEY,
    display_name  text NOT NULL,
    brand_code    text REFERENCES core.brand(brand_code),
    active        boolean NOT NULL DEFAULT true
);

CREATE TABLE core.pipeline_stage (
    pipeline_code text    NOT NULL REFERENCES core.pipeline(pipeline_code) ON DELETE CASCADE,
    stage_code    text    NOT NULL,
    display_name  text    NOT NULL,
    position      integer NOT NULL,
    is_won        boolean NOT NULL DEFAULT false,
    is_lost       boolean NOT NULL DEFAULT false,
    PRIMARY KEY (pipeline_code, stage_code),
    UNIQUE (pipeline_code, position),
    -- A stage cannot be both the win and the loss.
    CONSTRAINT stage_outcome_exclusive CHECK (NOT (is_won AND is_lost))
);

CREATE TABLE core.deal (
    deal_id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    external_ref  text UNIQUE,
    property_id   uuid NOT NULL REFERENCES core.property(property_id) ON DELETE RESTRICT,
    investor_id   uuid          REFERENCES core.person(person_id),
    agent_id      uuid          REFERENCES core.person(person_id),
    pipeline_code text NOT NULL,
    stage_code    text NOT NULL,
    amount        numeric(12,2),
    opened_at     timestamptz NOT NULL DEFAULT now(),
    closed_at     timestamptz,
    lost_reason   text,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (pipeline_code, stage_code)
        REFERENCES core.pipeline_stage(pipeline_code, stage_code),
    -- A closed deal must say when. An open one must not pretend it did.
    CONSTRAINT deal_closed_consistent CHECK (
        (closed_at IS NULL) OR (closed_at >= opened_at)
    )
);
CREATE INDEX ix_deal_property ON core.deal (property_id);
CREATE INDEX ix_deal_investor ON core.deal (investor_id);
CREATE INDEX ix_deal_agent    ON core.deal (agent_id);
CREATE INDEX ix_deal_open     ON core.deal (pipeline_code, stage_code)
    WHERE closed_at IS NULL;

-- Append-only. No UPDATE or DELETE grant is ever issued on this table.
CREATE TABLE core.deal_stage_history (
    id            bigserial PRIMARY KEY,
    deal_id       uuid NOT NULL REFERENCES core.deal(deal_id) ON DELETE CASCADE,
    from_stage    text,
    to_stage      text NOT NULL,
    changed_at    timestamptz NOT NULL DEFAULT now(),
    changed_by    uuid,
    -- Time spent in the stage being left. Computed on write, because
    -- deriving it later means re-deriving it correctly every time.
    seconds_in_from bigint
);
CREATE INDEX ix_stage_history_deal ON core.deal_stage_history (deal_id, changed_at);

COMMENT ON TABLE core.deal_stage_history IS
    'Append-only, written by trigger. The application cannot forget to log '
    'a transition, and cannot rewrite one after the fact.';

-- ---------------------------------------------------------------------
-- History is a trigger, not a convention
-- ---------------------------------------------------------------------
-- Two triggers, not one. A BEFORE INSERT cannot write the history row:
-- the deal does not exist yet, so the foreign key fails. So BEFORE sets
-- the fields that must be consistent on the row itself, and AFTER writes
-- the log once the row is really there.
CREATE FUNCTION core.sync_deal_closed() RETURNS trigger
LANGUAGE plpgsql
SET search_path = core, pg_temp
AS $$
BEGIN
    -- Entering a terminal stage closes the deal; leaving one reopens it.
    -- Deriving closed_at here means it can never disagree with stage_code.
    IF EXISTS (SELECT 1 FROM core.pipeline_stage s
                WHERE s.pipeline_code = NEW.pipeline_code
                  AND s.stage_code    = NEW.stage_code
                  AND (s.is_won OR s.is_lost)) THEN
        NEW.closed_at := COALESCE(NEW.closed_at, now());
    ELSE
        NEW.closed_at  := NULL;
        NEW.lost_reason := NULL;
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION core.log_stage_change() RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $$
DECLARE
    actor uuid;
    prev  timestamptz;
BEGIN
    IF TG_OP = 'UPDATE' AND NEW.stage_code IS NOT DISTINCT FROM OLD.stage_code THEN
        RETURN NULL;
    END IF;

    -- Best effort: a background job has no actor, and recording that
    -- honestly is better than inventing one.
    BEGIN
        actor := NULLIF(current_setting('app.actor_id', true), '')::uuid;
    EXCEPTION WHEN others THEN actor := NULL;
    END;

    SELECT max(changed_at) INTO prev
      FROM core.deal_stage_history WHERE deal_id = NEW.deal_id;

    INSERT INTO core.deal_stage_history
        (deal_id, from_stage, to_stage, changed_by, seconds_in_from)
    VALUES (
        NEW.deal_id,
        CASE WHEN TG_OP = 'UPDATE' THEN OLD.stage_code ELSE NULL END,
        NEW.stage_code,
        actor,
        CASE WHEN prev IS NULL THEN NULL
             ELSE EXTRACT(EPOCH FROM (now() - prev))::bigint END
    );
    RETURN NULL;
END;
$$;

CREATE TRIGGER deal_closed_sync
    BEFORE INSERT OR UPDATE OF stage_code ON core.deal
    FOR EACH ROW EXECUTE FUNCTION core.sync_deal_closed();

CREATE TRIGGER deal_stage_log
    AFTER INSERT OR UPDATE OF stage_code ON core.deal
    FOR EACH ROW EXECUTE FUNCTION core.log_stage_change();

CREATE FUNCTION core.touch_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at := now(); RETURN NEW; END;
$$;

CREATE TRIGGER deal_touch BEFORE UPDATE ON core.deal
    FOR EACH ROW EXECUTE FUNCTION core.touch_updated_at();

COMMIT;
