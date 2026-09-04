-- =====================================================================
-- 41_property_manager.sql  |  the metro dropdown is a fee schedule
-- =====================================================================
-- WHAT THE DROPDOWN ACTUALLY IS, stated by the operator:
--
--   "Kansas City-SH and Kansas City-OS are mapped to 2 different property
--    managers. So it is the Metro, plus the property manager. Each metro
--    has property managers in it that charge different fees, so the drop
--    down adjusts how much the property management fees and the leasing
--    fees will be for each house depending on the property manager
--    assigned to them."
--
-- So an entry in that list is not a place. It is a PROGRAMME: a market and
-- the firm managing property in it, and through that firm, the fees a
-- buyer will pay every month. Choosing "Kansas City-SH" on a house is
-- choosing a management company and a fee schedule, and the projection
-- moves accordingly.
--
-- That is why the earlier model was not enough. It recorded that the
-- suffix existed, and left the thing the suffix DECIDES -- the fees --
-- to be typed by hand onto every property, where two people will
-- eventually type different numbers for the same manager and nobody will
-- be able to say which is right.
--
-- WHAT IS STILL UNKNOWN, and recorded as unknown rather than guessed:
--   * What OS and SH stand for. Two managers in Kansas City, names not given.
--   * Every fee schedule except one. The 8.0% management fee and $29.20
--     leasing fee below come from the 401 NW 71st St workbook, which is a
--     Kansas City-SH property, so they are attributed to SH and to nothing
--     else. The others are null: a null fee shows as "not set" in the
--     panel, where a plausible-looking guess would be entered on a house
--     and never questioned.
--   * Whether Resi*, No Monthly Fee and Hybrid are fee plans offered by a
--     manager, programmes in their own right, or something else. They are
--     still marked `arrangement`.

BEGIN;

CREATE TABLE core.property_manager (
    manager_id   text PRIMARY KEY,
    name         text NOT NULL,
    active       boolean NOT NULL DEFAULT true,
    established  text NOT NULL DEFAULT 'unconfirmed'
                   CHECK (established IN ('unconfirmed', 'confirmed')),
    note         text
);

INSERT INTO core.property_manager (manager_id, name, established, note) VALUES
 ('OS', 'Kansas City manager “OS”', 'unconfirmed',
  'Named only by the suffix in the workbook dropdown. The firm''s actual '
  'name is not established.'),
 ('SH', 'Kansas City manager “SH”', 'unconfirmed',
  'As above. The 401 NW 71st St workbook is a Kansas City-SH property, so '
  'its 8.0%% management fee and $29.20 leasing fee are attributed here.');

ALTER TABLE core.property_manager ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.property_manager FORCE  ROW LEVEL SECURITY;
CREATE POLICY pm_read  ON core.property_manager FOR SELECT USING (true);
CREATE POLICY pm_write ON core.property_manager FOR ALL TO sdi_admin
  USING (sec.is_internal()) WITH CHECK (sec.is_internal());
GRANT SELECT ON core.property_manager TO sdi_public, sdi_investor, sdi_agent, sdi_admin;
GRANT INSERT, UPDATE, DELETE ON core.property_manager TO sdi_admin;

-- ---------------------------------------------------------------------
-- The fees hang off the programme, not the property
--
-- Per programme rather than per manager, because the same firm can charge
-- differently in two markets. A property inherits these when its metro is
-- set and may override them -- a house on a legacy contract is a real
-- thing -- but the default comes from one row that one person maintains.
-- ---------------------------------------------------------------------
ALTER TABLE core.metro
    ADD COLUMN manager_id text REFERENCES core.property_manager(manager_id);

COMMENT ON COLUMN core.metro.manager_id IS
    'The firm managing property in this programme. Two Kansas City entries '
    'differ only by this column -- which is the whole reason both exist.';

UPDATE core.metro SET manager_id = 'OS' WHERE metro_code = 'KC-OS';
UPDATE core.metro SET manager_id = 'SH' WHERE metro_code = 'KC-SH';

-- ---------------------------------------------------------------------
-- Fee schedules are VERSIONED, and this is the important part
--
-- Stated by the operator: fees "could be SET at time of a deal - but they
-- may change their fees at a later date and we would not want that to
-- reverse recalculate prior agreements at prior fees."
--
-- So a manager's fees are not a column that gets edited. They are a series
-- of dated rows, appended and never rewritten, and a property records
-- WHICH ROW its own figures came from. Raising a fee in March adds a March
-- schedule; a deal agreed in January still points at the January one, and
-- its projection still reconciles to the sheet somebody signed.
--
-- Two separate facts, and conflating them is the whole trap:
--   * what the manager charges TODAY          -- core.fee_schedule
--   * what THIS property is charged           -- the property's own
--                                                management_fee_bps and
--                                                leasing_fee_monthly
-- The second is never derived from the first at read time. It is copied
-- once, deliberately, by a person, and stamped with where it came from.
-- ---------------------------------------------------------------------
CREATE TABLE core.fee_schedule (
    schedule_id         serial PRIMARY KEY,
    metro_code          text NOT NULL REFERENCES core.metro(metro_code),
    effective_from      date NOT NULL,
    management_fee_bps  integer,
    leasing_fee_monthly numeric(10,2),
    monthly_flat_fee    numeric(10,2),
    recorded_at         timestamptz NOT NULL DEFAULT now(),
    recorded_by         uuid REFERENCES core.person(person_id),
    note                text,
    UNIQUE (metro_code, effective_from),
    CONSTRAINT fee_range CHECK (management_fee_bps IS NULL
        OR (management_fee_bps >= 0 AND management_fee_bps <= 5000))
);

COMMENT ON TABLE core.fee_schedule IS
    'Append-only. A fee change is a new row with a later effective_from, '
    'never an UPDATE -- editing one in place would silently restate every '
    'deal that was agreed under it.';

CREATE INDEX ix_fee_schedule ON core.fee_schedule (metro_code, effective_from DESC);

ALTER TABLE core.fee_schedule ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.fee_schedule FORCE  ROW LEVEL SECURITY;
CREATE POLICY fee_read  ON core.fee_schedule FOR SELECT USING (true);
-- Insert only. No UPDATE and no DELETE policy, for anybody, on purpose:
-- the append-only rule is enforced by the absence of a way to break it
-- rather than by everyone remembering.
CREATE POLICY fee_write ON core.fee_schedule FOR INSERT TO sdi_admin
  WITH CHECK (sec.is_internal());
GRANT SELECT ON core.fee_schedule TO sdi_public, sdi_investor, sdi_agent, sdi_admin;

-- Recording a fee change goes through a function, not a table grant. The
-- reader roles hold no USAGE on schema core, so a raw INSERT would work
-- only from a psql prompt -- and a rule this consequential should be one
-- named operation that validates and refuses, rather than whatever
-- somebody types at a prompt.
CREATE FUNCTION api.record_fee_schedule(
    p_metro_code      text,
    p_effective_from  date,
    p_management_fee_bps  integer DEFAULT NULL,
    p_leasing_fee_monthly numeric DEFAULT NULL,
    p_monthly_flat_fee    numeric DEFAULT NULL,
    p_note            text    DEFAULT NULL)
RETURNS integer
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $fn$
DECLARE v_id integer;
BEGIN
  IF NOT sec.is_internal() THEN
    RAISE EXCEPTION 'recording a fee schedule is an admin decision'
      USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM core.metro WHERE metro_code = p_metro_code) THEN
    RAISE EXCEPTION 'no such programme: %', p_metro_code;
  END IF;
  -- Two schedules starting on the same day is a contradiction, not a
  -- correction. If a mistake needs undoing, the answer is a new row with
  -- a later date and a note saying so, because whatever was agreed under
  -- the wrong one was still agreed.
  INSERT INTO core.fee_schedule
    (metro_code, effective_from, management_fee_bps, leasing_fee_monthly,
     monthly_flat_fee, recorded_by, note)
  VALUES
    (p_metro_code, p_effective_from, p_management_fee_bps, p_leasing_fee_monthly,
     p_monthly_flat_fee, sec.actor_id(), p_note)
  RETURNING schedule_id INTO v_id;
  RETURN v_id;
END;
$fn$;

REVOKE ALL ON FUNCTION api.record_fee_schedule(text,date,integer,numeric,numeric,text)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.record_fee_schedule(text,date,integer,numeric,numeric,text)
  TO sdi_admin;

-- The one schedule that is established: the 401 NW 71st St workbook is a
-- Kansas City-SH property, so its 8.0% management fee and $29.20 leasing
-- fee are attributed to SH and to no other programme.
INSERT INTO core.fee_schedule
 (metro_code, effective_from, management_fee_bps, leasing_fee_monthly, note) VALUES
 ('KC-SH', DATE '2026-01-01', 800, 29.20,
  'Taken from the 401 NW 71st St workbook. The effective date is a '
  'placeholder: when this schedule actually began is not established.');

-- ---------------------------------------------------------------------
-- What the panel reads when the dropdown changes
--
-- Returns the programme's defaults so the panel can offer them. It does
-- not write: an operator sees what the manager charges and applies it
-- deliberately, because a fee that changes underneath a saved analysis is
-- how a projection stops matching the sheet it was signed off from.
-- ---------------------------------------------------------------------
-- As of a date, defaulting to today. The parameter is not decoration:
-- reconciling a deal agreed in January means asking what the schedule was
-- in January, and a function that only knows about today cannot answer it.
-- SECURITY DEFINER, and the reason is worth stating because it has caught
-- this project three times now. A VIEW resolves its references when it is
-- defined, so a caller needs privileges on the view and not on the schema
-- underneath. A SQL FUNCTION body is resolved when it runs, as the caller,
-- so an invoker-rights function reading core fails for every reader role
-- -- none of which holds USAGE on that schema. Nothing here is sensitive:
-- the same fees are already on api.metro.
CREATE FUNCTION api.metro_fees(p_metro_code text, p_as_of date DEFAULT current_date)
RETURNS TABLE (metro_code text, label text, manager_id text, manager_name text,
               schedule_id integer, effective_from date,
               management_fee_bps integer, leasing_fee_monthly numeric,
               monthly_flat_fee numeric, established text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = core, pg_temp
AS $$
  SELECT m.metro_code, m.label, m.manager_id, pm.name,
         f.schedule_id, f.effective_from,
         f.management_fee_bps, f.leasing_fee_monthly, f.monthly_flat_fee,
         COALESCE(pm.established, 'unconfirmed')
    FROM core.metro m
    LEFT JOIN core.property_manager pm ON pm.manager_id = m.manager_id
    LEFT JOIN LATERAL (
      SELECT * FROM core.fee_schedule s
       WHERE s.metro_code = m.metro_code AND s.effective_from <= p_as_of
       ORDER BY s.effective_from DESC LIMIT 1) f ON true
   WHERE m.metro_code = p_metro_code;
$$;

GRANT EXECUTE ON FUNCTION api.metro_fees(text, date)
    TO sdi_public, sdi_investor, sdi_agent, sdi_admin;

-- The columns below are the schedule in force TODAY. A property that took
-- its fees from an earlier one keeps them; nothing here reaches back.
CREATE OR REPLACE VIEW api.metro
WITH (security_invoker = true, security_barrier = true) AS
SELECT m.metro_code, m.label, m.kind, m.metro_name, m.state, m.arrangement,
       m.sort_order, m.active, m.classified, m.note,
       m.manager_id, pm.name AS manager_name,
       f.schedule_id       AS current_schedule_id,
       f.effective_from    AS current_effective_from,
       f.management_fee_bps, f.leasing_fee_monthly, f.monthly_flat_fee
FROM core.metro m
LEFT JOIN core.property_manager pm ON pm.manager_id = m.manager_id
LEFT JOIN LATERAL (
  SELECT * FROM core.fee_schedule s
   WHERE s.metro_code = m.metro_code AND s.effective_from <= current_date
   ORDER BY s.effective_from DESC LIMIT 1) f ON true
ORDER BY m.sort_order;

-- ---------------------------------------------------------------------
-- What this property is actually charged, and where it came from
-- ---------------------------------------------------------------------
ALTER TABLE core.property_underwriting
    ADD CONSTRAINT uw_fee_schedule
        FOREIGN KEY (fee_schedule_id) REFERENCES core.fee_schedule(schedule_id);

COMMENT ON COLUMN core.property_underwriting.fee_schedule_id IS
    'Which version of the programme''s fee schedule this property''s fees '
    'were copied from, and when. Recorded so a later increase is visibly a '
    'later increase rather than a discrepancy nobody can explain.';

CREATE FUNCTION api.apply_fee_schedule(p_property_id uuid)
RETURNS TABLE (field text, old_value text, new_value text)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = core, sec, api, pg_temp
AS $fn$
DECLARE f record; v_metro text;
BEGIN
  IF NOT sec.can_manage_media(p_property_id) THEN
    RAISE EXCEPTION 'not authorised' USING ERRCODE = '42501';
  END IF;
  SELECT metro_code INTO v_metro FROM core.property WHERE property_id = p_property_id;
  IF v_metro IS NULL THEN
    RAISE EXCEPTION 'this property has no programme, so there is no schedule to apply';
  END IF;

  SELECT * INTO f FROM core.fee_schedule s
   WHERE s.metro_code = v_metro AND s.effective_from <= current_date
   ORDER BY s.effective_from DESC LIMIT 1;
  IF f IS NULL THEN
    RAISE EXCEPTION 'no fee schedule has been recorded for %', v_metro;
  END IF;

  INSERT INTO core.property_detail (property_id) VALUES (p_property_id)
    ON CONFLICT DO NOTHING;
  INSERT INTO core.property_underwriting (property_id) VALUES (p_property_id)
    ON CONFLICT DO NOTHING;

  IF f.management_fee_bps IS NOT NULL THEN
    RETURN QUERY SELECT * FROM api.property_save(p_property_id,
      jsonb_build_object('management_fee_bps', f.management_fee_bps::text));
  END IF;
  IF f.leasing_fee_monthly IS NOT NULL THEN
    RETURN QUERY SELECT * FROM api.property_save(p_property_id,
      jsonb_build_object('leasing_fee_monthly', f.leasing_fee_monthly::text));
  END IF;

  UPDATE core.property_underwriting
     SET fee_schedule_id = f.schedule_id, fees_applied_at = now()
   WHERE property_id = p_property_id;
END;
$fn$;

REVOKE ALL ON FUNCTION api.apply_fee_schedule(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.apply_fee_schedule(uuid) TO sdi_agent, sdi_admin;

-- ---------------------------------------------------------------------
-- Is this property on the current schedule, or an older one
--
-- Both answers are legitimate. A property agreed under January's fees
-- SHOULD still be on January's fees. What nobody should have to do is work
-- out which by comparing two numbers in two screens, so the difference is
-- computed here and the panel states it.
-- ---------------------------------------------------------------------
CREATE VIEW api.property_fee_status
WITH (security_invoker = true, security_barrier = true) AS
SELECT p.property_id, p.metro_code, m.label AS metro_label, pm.name AS manager_name,
       d.management_fee_bps          AS property_management_fee_bps,
       u.leasing_fee_monthly         AS property_leasing_fee_monthly,
       u.fee_schedule_id, u.fees_applied_at,
       applied.effective_from        AS applied_effective_from,
       cur.schedule_id               AS current_schedule_id,
       cur.effective_from            AS current_effective_from,
       cur.management_fee_bps        AS current_management_fee_bps,
       cur.leasing_fee_monthly       AS current_leasing_fee_monthly,
       (cur.schedule_id IS NOT NULL
        AND u.fee_schedule_id IS DISTINCT FROM cur.schedule_id) AS schedule_superseded,
       (cur.management_fee_bps  IS DISTINCT FROM d.management_fee_bps
        OR cur.leasing_fee_monthly IS DISTINCT FROM u.leasing_fee_monthly) AS fees_differ
FROM core.property p
LEFT JOIN core.property_detail       d ON d.property_id = p.property_id
LEFT JOIN core.property_underwriting u ON u.property_id = p.property_id
LEFT JOIN core.metro                 m ON m.metro_code  = p.metro_code
LEFT JOIN core.property_manager     pm ON pm.manager_id = m.manager_id
LEFT JOIN core.fee_schedule     applied ON applied.schedule_id = u.fee_schedule_id
LEFT JOIN LATERAL (
  SELECT * FROM core.fee_schedule s
   WHERE s.metro_code = p.metro_code AND s.effective_from <= current_date
   ORDER BY s.effective_from DESC LIMIT 1) cur ON true;

GRANT SELECT ON api.property_fee_status TO sdi_agent, sdi_admin;

COMMIT;
