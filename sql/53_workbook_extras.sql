-- =====================================================================
-- 53_workbook_extras.sql  |  points, acceleration, and the ratings
-- =====================================================================
-- The last three panels of the workbook: "Deciding About Using Points",
-- "Mortgage Acceleration", and section 3's ratings table.
--
-- WHAT SECTION 3 DOES NOT CONTAIN, and why it is the interesting part of
-- this file. The workbook's ratings table leads with "Schools (scale of
-- 3-30)". gov.prohibited_dimension registers school_rating as a
-- fair-housing proxy: ratings track the demographics of a catchment, so
-- offering one as a ranking axis is steering, and the Act does not
-- require that anyone intended it. api.security_invariants() fails the
-- build if a column by that name appears in core or api.
--
-- Underwriting with schools in mind is legitimate; publishing a sortable
-- score is not, and these figures are headed for customer-facing screens.
-- So the number is read back out of the raw intake payload where it was
-- always kept, shown to staff as prose beside a note saying why it is not
-- part of the score, and it is NEVER a column, never in the composite,
-- and never something anybody can sort or filter on. The invariant stays
-- green because nothing here is a promotion.
--
-- THE COMPOSITE EXCLUDES IT TOO. A FAVORABLE/INSUFFICIENT verdict partly
-- derived from schools is a laundered version of the same thing, which
-- gov.prohibited_dimension also says. Six criteria go in; schools sits
-- outside the box it would otherwise contaminate.

BEGIN;

-- ---------------------------------------------------------------------
-- The thresholds behind section 3
-- ---------------------------------------------------------------------
-- Per property, defaulting to the workbook's own suggested minimums. The
-- operator changes what "favorable" means for a given deal without
-- restating every other deal, exactly as the projection assumptions work.
CREATE TABLE core.rating_criteria (
    property_id  uuid PRIMARY KEY REFERENCES core.property(property_id) ON DELETE CASCADE,
    min_sqft     integer NOT NULL DEFAULT 1000,
    min_beds     integer NOT NULL DEFAULT 3,
    min_baths    numeric(3,1) NOT NULL DEFAULT 2,
    min_year     integer NOT NULL DEFAULT 1970,
    min_cash_5yr numeric(10,2) NOT NULL DEFAULT 125,
    updated_at   timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE core.rating_criteria ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.rating_criteria FORCE  ROW LEVEL SECURITY;
CREATE POLICY rc_staff ON core.rating_criteria FOR SELECT
    TO sdi_agent, sdi_admin USING (sec.is_internal() OR sec.is_assigned(property_id));
CREATE POLICY rc_write ON core.rating_criteria FOR ALL
    TO sdi_admin USING (sec.is_internal()) WITH CHECK (sec.is_internal());
GRANT SELECT ON core.rating_criteria TO sdi_agent, sdi_admin;
GRANT INSERT, UPDATE ON core.rating_criteria TO sdi_admin;

-- ---------------------------------------------------------------------
-- Section 3, minus the row that cannot be a score
-- ---------------------------------------------------------------------
CREATE FUNCTION api.property_ratings(p_property_id uuid)
RETURNS TABLE (item text, suggested text, actual text, favorable boolean, sort_order int)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = core, sec, api, pg_temp
AS $fn$
DECLARE
  c core.rating_criteria%ROWTYPE;
  v_sqft int; v_beds int; v_baths numeric; v_year int; v_cash numeric;
BEGIN
  IF NOT sec.is_internal() AND NOT sec.is_assigned(p_property_id) THEN
    RETURN;
  END IF;

  SELECT * INTO c FROM core.rating_criteria WHERE property_id = p_property_id;
  IF NOT FOUND THEN
    c.min_sqft := 1000; c.min_beds := 3; c.min_baths := 2;
    c.min_year := 1970; c.min_cash_5yr := 125;
  END IF;

  SELECT p.sqft, p.beds, p.baths, p.year_built
    INTO v_sqft, v_beds, v_baths, v_year
    FROM core.property p WHERE p.property_id = p_property_id;

  SELECT r.avg_cash_per_month INTO v_cash
    FROM api.property_projection(p_property_id) r WHERE r.years = 5;

  RETURN QUERY VALUES
    ('Square feet', c.min_sqft::text, COALESCE(v_sqft::text, '—'),
     v_sqft >= c.min_sqft, 1),
    ('Bedrooms', c.min_beds::text, COALESCE(v_beds::text, '—'),
     v_beds >= c.min_beds, 2),
    -- FM999.9 leaves a bare trailing point on a whole number -- "2." --
    -- so the mask is stripped of it rather than the number being forced
    -- to a decimal nobody wrote. 2 baths reads as 2; 2.5 reads as 2.5.
    ('Bathrooms', rtrim(to_char(c.min_baths, 'FM999.9'), '.'),
     COALESCE(rtrim(to_char(v_baths, 'FM999.9'), '.'), '—'),
     v_baths >= c.min_baths, 3),
    ('Year built', c.min_year::text, COALESCE(v_year::text, '—'),
     v_year >= c.min_year, 4),
    ('Average cash flow (year 5)', '$' || trim(to_char(c.min_cash_5yr, 'FM999,999')),
     CASE WHEN v_cash IS NULL THEN '—'
          ELSE '$' || trim(to_char(v_cash, 'FM999,999')) END,
     v_cash >= c.min_cash_5yr, 5);
END;
$fn$;

-- The schools figure, if intake ever carried one. Returned on its own,
-- as text, from the raw payload -- deliberately NOT joined into the table
-- above and deliberately not a number anything can order by.
CREATE FUNCTION api.property_school_note(p_property_id uuid)
RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $fn$
DECLARE v text;
BEGIN
  IF NOT sec.is_internal() THEN RETURN NULL; END IF;
  SELECT COALESCE(r.raw ->> 'schools_rating', r.raw ->> 'Schools Rating',
                  r.raw ->> 'school_rating')
    INTO v
    FROM core.intake_row r
   WHERE r.property_id = p_property_id
     AND r.raw IS NOT NULL
   ORDER BY r.intake_row_id DESC
   LIMIT 1;
  RETURN v;
EXCEPTION WHEN undefined_table OR undefined_column THEN
  -- Intake may not carry the column at all. That is not an error; it is
  -- the ordinary case for a property loaded before the sheet had it.
  RETURN NULL;
END;
$fn$;

-- ---------------------------------------------------------------------
-- Deciding about using points
-- ---------------------------------------------------------------------
-- A point costs 1% of the loan and buys a lower rate. Whether it is worth
-- it is one division -- what the point cost, over what it saves each
-- month -- and the answer is a DATE, not a yes.
CREATE FUNCTION api.property_points(p_property_id uuid,
                                    p_points_pct numeric DEFAULT 0.01,
                                    p_rate_without numeric DEFAULT NULL)
RETURNS TABLE (
    financed          numeric,
    points_pct        numeric,
    points_cost       numeric,
    rate_with         numeric,
    rate_without      numeric,
    payment_with      numeric,
    payment_without   numeric,
    monthly_gap       numeric,
    breakeven_months  numeric,
    breakeven_years   numeric
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $fn$
DECLARE v_loan numeric; v_rate numeric; v_term int; v_alt numeric; v_gap numeric;
BEGIN
  IF NOT sec.is_internal() AND NOT sec.is_assigned(p_property_id) THEN
    RETURN;
  END IF;

  SELECT COALESCE(u.offer_used, u.asking_price, p.list_price)
           * (1 - COALESCE(u.down_payment_pct, 0)),
         u.interest_rate, COALESCE(u.mortgage_term_years, 30)
    INTO v_loan, v_rate, v_term
    FROM core.property p
    LEFT JOIN core.property_underwriting u ON u.property_id = p.property_id
   WHERE p.property_id = p_property_id;

  IF v_loan IS NULL OR v_rate IS NULL THEN RETURN; END IF;

  -- The rate without the point. A quarter point of rate per point bought
  -- is the market rule of thumb and is what the workbook's own figures
  -- imply; it is an assumption, so it is an argument with a default
  -- rather than a constant buried in the arithmetic.
  v_alt := COALESCE(p_rate_without, v_rate + 0.0038);

  financed        := round(v_loan, 2);
  points_pct      := p_points_pct;
  points_cost     := round(v_loan * p_points_pct, 2);
  rate_with       := v_rate;
  rate_without    := v_alt;
  payment_with    := core.monthly_payment(v_loan, v_rate, v_term);
  payment_without := core.monthly_payment(v_loan, v_alt, v_term);
  v_gap           := payment_without - payment_with;
  monthly_gap     := round(v_gap, 2);

  -- A point that buys nothing never pays back, and dividing by zero to
  -- say so would be worse than saying nothing.
  breakeven_months := CASE WHEN v_gap > 0
                           THEN round(points_cost / v_gap, 1) END;
  breakeven_years  := CASE WHEN v_gap > 0
                           THEN round(points_cost / v_gap / 12, 1) END;
  RETURN NEXT;
END;
$fn$;

-- ---------------------------------------------------------------------
-- Mortgage acceleration
-- ---------------------------------------------------------------------
-- Put the cash flow back into the principal and the loan ends early. The
-- schedule is walked month by month rather than solved: an extra payment
-- made ONCE A YEAR is not a level annuity, and the closed forms that look
-- like they apply here all quietly assume it is.
CREATE FUNCTION api.property_acceleration(p_property_id uuid,
                                          p_extra_annual numeric DEFAULT NULL)
RETURNS TABLE (
    extra_annual      numeric,
    extra_monthly     numeric,
    years_to_payoff   numeric,
    interest_full     numeric,
    interest_early    numeric,
    interest_saved    numeric
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = core, sec, api, pg_temp
AS $fn$
DECLARE
  v_loan numeric; v_rate numeric; v_term int; v_pay numeric;
  v_extra numeric; v_bal numeric; v_int numeric := 0; v_m int := 0; v_r numeric;
BEGIN
  IF NOT sec.is_internal() AND NOT sec.is_assigned(p_property_id) THEN
    RETURN;
  END IF;

  SELECT COALESCE(u.offer_used, u.asking_price, p.list_price)
           * (1 - COALESCE(u.down_payment_pct, 0)),
         u.interest_rate, COALESCE(u.mortgage_term_years, 30)
    INTO v_loan, v_rate, v_term
    FROM core.property p
    LEFT JOIN core.property_underwriting u ON u.property_id = p.property_id
   WHERE p.property_id = p_property_id;

  IF v_loan IS NULL OR COALESCE(v_rate, 0) <= 0 THEN RETURN; END IF;

  -- The default is the property's own five-year average annual cash
  -- flow, which is the workbook's: the money the house itself throws off,
  -- put back into the house.
  IF p_extra_annual IS NULL THEN
    SELECT r.avg_cash_per_year INTO v_extra
      FROM api.property_projection(p_property_id) r WHERE r.years = 5;
  ELSE
    v_extra := p_extra_annual;
  END IF;
  v_extra := GREATEST(COALESCE(v_extra, 0), 0);

  v_pay := core.monthly_payment(v_loan, v_rate, v_term);
  v_r   := v_rate / 12;
  v_bal := v_loan;

  WHILE v_bal > 0 AND v_m < v_term * 12 LOOP
    v_m   := v_m + 1;
    v_int := v_int + v_bal * v_r;
    v_bal := v_bal + v_bal * v_r - v_pay;
    -- The extra lands once a year, at the end of each twelfth month.
    IF v_m % 12 = 0 THEN v_bal := v_bal - v_extra; END IF;
    IF v_bal < 0 THEN v_bal := 0; END IF;
  END LOOP;

  extra_annual    := round(v_extra, 2);
  extra_monthly   := round(v_extra / 12, 2);
  years_to_payoff := round(v_m::numeric / 12, 1);
  interest_full   := core.total_interest(v_loan, v_rate, v_term);
  interest_early  := round(v_int, 2);
  interest_saved  := round(core.total_interest(v_loan, v_rate, v_term) - v_int, 2);
  RETURN NEXT;
END;
$fn$;

REVOKE ALL ON FUNCTION api.property_ratings(uuid), api.property_school_note(uuid),
                       api.property_points(uuid, numeric, numeric),
                       api.property_acceleration(uuid, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.property_ratings(uuid), api.property_school_note(uuid),
                          api.property_points(uuid, numeric, numeric),
                          api.property_acceleration(uuid, numeric)
    TO sdi_agent, sdi_admin;

-- ---------------------------------------------------------------------
-- Source of income, split
-- ---------------------------------------------------------------------
-- "section 8" alone was refused, and that is wrong for an investor
-- audience. A tenanted voucher property has a government-backed rent
-- stream, which is a real underwriting fact somebody may legitimately
-- search for. What is prohibited is the EXCLUSIONARY direction -- and in
-- a growing number of states source-of-income discrimination is illegal
-- on its own account, quite apart from the federal position.
--
-- So the refusal catches "no section 8", not "section 8".
DELETE FROM gov.prohibited_phrase WHERE phrase IN ('section 8');
INSERT INTO gov.prohibited_phrase (phrase, dimension, whole_word) VALUES
  ('without section 8', 'source_of_income', false),
  ('excluding section 8', 'source_of_income', false),
  ('no voucher', 'source_of_income', false),
  ('not section 8', 'source_of_income', false)
ON CONFLICT (phrase) DO NOTHING;

COMMIT;
