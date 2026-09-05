-- =====================================================================
-- 49_projection.sql  |  the multi-year projection, and the benchmarks
-- =====================================================================
-- Sections 1, 2, I and II of the workbook. These are the pages a buyer
-- decides on: not what the house costs, but what holding it does over
-- five, ten, fifteen and twenty years.
--
-- THE ARITHMETIC IS RECONCILED AGAINST THE SHEET, not inferred from the
-- labels. At 4% appreciation on a $300,000 after-improvement value:
--
--   projected value  yr 5  $364,996  = 300,000 x 1.04^5   -- exact
--                    yr 10 $444,073   yr 15 $540,283   yr 20 $657,337
--   equity increase  yr 5  $78,211   = (value - balance) - initial equity
--   total gain       yr 5  $90,566   = cash flow + equity increase
--   annual ROI       yr 5  18.0%     = avg gain per year / cash out of pocket
--
-- Three things in there are easy to get wrong, and each changes the
-- answer by more than a rounding:
--
--   APPRECIATION COMPOUNDS ON THE AFTER-IMPROVEMENT VALUE, not on the
--   offer and not on total cost. A property bought under market shows
--   that uplift on day one, not smeared across twenty years.
--
--   ROI IS AGAINST CASH OUT OF POCKET, not against total cost. It is the
--   return on what the investor actually put in; measuring against the
--   financed total quietly divides by three.
--
--   VACANCY AND MANAGEMENT ARE PERCENTAGES OF RENT, so they grow with
--   revenue, not with expenses. Treating them as flat costs understates
--   them every year after the first by exactly the amount rent has risen.
--
-- REVENUE AND EXPENSES DRIFT APART ON PURPOSE -- 3% against 2% -- and the
-- gap is most of why year twenty looks different from year one. Holding
-- them equal makes every projection optimistic in the same direction,
-- which is the failure nobody catches because it never produces an
-- obviously silly number.

BEGIN;

-- ---------------------------------------------------------------------
-- The assumptions -- sections I and II
-- ---------------------------------------------------------------------
-- Per property, because a deal agreed under one set of assumptions must
-- not be restated when somebody revises the house view. Same reasoning as
-- the fee schedules in 41_property_manager.sql. Defaults are the
-- workbook's own.
--
-- Vacancy and the management fee are deliberately NOT here: the property
-- already carries them, and a second copy is a second answer.
CREATE TABLE core.projection_assumption (
    property_id     uuid PRIMARY KEY REFERENCES core.property(property_id) ON DELETE CASCADE,
    revenue_growth  numeric(6,4) NOT NULL DEFAULT 0.0300,
    expense_growth  numeric(6,4) NOT NULL DEFAULT 0.0200,
    appreciation    numeric(6,4) NOT NULL DEFAULT 0.0400,
    land_pct        numeric(5,4) NOT NULL DEFAULT 0.2500,
    selling_costs   numeric(5,4) NOT NULL DEFAULT 0.0750,
    tax_ordinary    numeric(5,4) NOT NULL DEFAULT 0.2500,
    tax_capital     numeric(5,4) NOT NULL DEFAULT 0.1500,
    tax_state       numeric(5,4) NOT NULL DEFAULT 0.1000,
    updated_at      timestamptz NOT NULL DEFAULT now(),
    updated_by      uuid REFERENCES core.person(person_id),
    -- A rate outside these bounds is a typo, not a forecast. 30% annual
    -- appreciation compounds to a number somebody would otherwise quote.
    CONSTRAINT pa_sane CHECK (
        revenue_growth BETWEEN -0.5 AND 0.5 AND
        expense_growth BETWEEN -0.5 AND 0.5 AND
        appreciation   BETWEEN -0.5 AND 0.5 AND
        land_pct       BETWEEN 0 AND 1 AND
        selling_costs  BETWEEN 0 AND 0.5 AND
        tax_ordinary   BETWEEN 0 AND 1 AND
        tax_capital    BETWEEN 0 AND 1 AND
        tax_state      BETWEEN 0 AND 1)
);

-- Band 3. The operator's view of the future, and the tax rates are
-- working assumptions rather than advice -- publishing them invites
-- somebody to rely on them.
ALTER TABLE core.projection_assumption ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.projection_assumption FORCE  ROW LEVEL SECURITY;
CREATE POLICY pa_staff ON core.projection_assumption FOR SELECT
    TO sdi_agent, sdi_admin USING (sec.is_internal() OR sec.is_assigned(property_id));
CREATE POLICY pa_write ON core.projection_assumption FOR ALL
    TO sdi_admin USING (sec.is_internal()) WITH CHECK (sec.is_internal());
GRANT SELECT ON core.projection_assumption TO sdi_agent, sdi_admin;
GRANT INSERT, UPDATE ON core.projection_assumption TO sdi_admin;

COMMENT ON TABLE core.projection_assumption IS
    'Per property, so revising the house view does not restate a deal '
    'already agreed under the old one.';

-- ---------------------------------------------------------------------
-- What the rent is taken at
--
-- The MIDDLE of the range, exactly as improvements are costed at the
-- middle of theirs -- and established the same way, by reconciling to the
-- sheet rather than by reading a label. Rent per square foot of $1.33 on
-- 1,632 sqft is $2,175 a month, which is the midpoint of $2,100-$2,250
-- and is neither end of it.
-- ---------------------------------------------------------------------
CREATE FUNCTION core.rent_estimate(p_low numeric, p_high numeric)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_low IS NOT NULL AND p_high IS NOT NULL THEN round((p_low + p_high) / 2, 2)
    ELSE COALESCE(p_high, p_low)
  END;
$$;

-- ---------------------------------------------------------------------
-- Amortisation
-- ---------------------------------------------------------------------
-- Closed form. Iterating a schedule row by row would drift by cents and
-- be slower; this is the standard identity and matches a lender to the
-- penny.
CREATE FUNCTION core.loan_balance(p_principal numeric, p_annual_rate numeric,
                                  p_years integer, p_months_paid integer)
RETURNS numeric
LANGUAGE sql IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_principal IS NULL OR p_years IS NULL OR p_years <= 0 THEN NULL
    WHEN p_months_paid >= p_years * 12 THEN 0::numeric
    WHEN COALESCE(p_annual_rate, 0) = 0 THEN
      round(p_principal * (1 - p_months_paid::numeric / (p_years * 12)), 2)
    ELSE GREATEST(round(
      p_principal * power(1 + p_annual_rate / 12, p_months_paid)
      - core.monthly_payment(p_principal, p_annual_rate, p_years)
        * ((power(1 + p_annual_rate / 12, p_months_paid) - 1) / (p_annual_rate / 12)),
      2), 0)
  END;
$$;

CREATE FUNCTION core.total_interest(p_principal numeric, p_annual_rate numeric,
                                    p_years integer, p_months integer DEFAULT NULL)
RETURNS numeric
LANGUAGE sql IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_principal IS NULL OR p_years IS NULL OR p_years <= 0 THEN NULL
    ELSE round(
      core.monthly_payment(p_principal, p_annual_rate, p_years)
        * LEAST(COALESCE(p_months, p_years * 12), p_years * 12)
      - (p_principal - core.loan_balance(p_principal, p_annual_rate, p_years,
           LEAST(COALESCE(p_months, p_years * 12), p_years * 12))), 2)
  END;
$$;

-- ---------------------------------------------------------------------
-- Section 1 -- the projection
-- ---------------------------------------------------------------------
-- SECURITY DEFINER over band 3 inputs, with the caller's right checked
-- explicitly: a definer function does not get the caller's RLS, so
-- re-selecting from a view inside one passes for every row.
CREATE FUNCTION api.property_projection(p_property_id uuid)
RETURNS TABLE (
    years              integer,
    projected_value    numeric,
    loan_balance       numeric,
    cumulative_cash    numeric,
    equity_increase    numeric,
    total_gain         numeric,
    avg_cash_per_year  numeric,
    avg_cash_per_month numeric,
    avg_gain_per_year  numeric,
    annual_roi         numeric
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $fn$
DECLARE
  a       core.projection_assumption%ROWTYPE;
  v_after numeric; v_loan numeric; v_rate numeric; v_term integer;
  v_pay   numeric; v_outlay numeric; v_initial_equity numeric;
  v_rent0 numeric; v_opex0 numeric; v_vac numeric; v_mgmt numeric;
  h integer; i integer;
  v_cash numeric; v_val numeric; v_bal numeric; v_eq numeric; v_gain numeric;
BEGIN
  IF NOT sec.is_internal() AND NOT sec.is_assigned(p_property_id) THEN
    RETURN;
  END IF;

  SELECT * INTO a FROM core.projection_assumption WHERE property_id = p_property_id;
  IF NOT FOUND THEN
    -- The house view, without requiring a row to exist. A property nobody
    -- has customised still projects.
    a.revenue_growth := 0.03; a.expense_growth := 0.02; a.appreciation := 0.04;
  END IF;

  -- EVERY INPUT BELOW IS THE ONE THE PANEL ALREADY SHOWS. Rent, vacancy,
  -- management and operating expenses are read on exactly the definitions
  -- api.property_admin uses. A projection built on a different basis would
  -- contradict the figures printed six inches above it on the same screen,
  -- and which one somebody believed would be a coin toss.
  SELECT u.market_value_after,
         COALESCE(u.offer_used, u.asking_price, p.list_price)
           * (1 - COALESCE(u.down_payment_pct, 0)),
         u.interest_rate,
         COALESCE(u.mortgage_term_years, 30),
         COALESCE(core.rent_estimate(u.rent_lower_monthly, u.rent_upper_monthly),
                  d.market_rent_monthly, 0) * 12,
         COALESCE(d.vacancy_allowance_bps, 0) / 10000.0,
         COALESCE(d.management_fee_bps, 0) / 10000.0,
         COALESCE(d.property_tax_annual, 0) + COALESCE(d.insurance_annual, 0)
           + COALESCE(d.maintenance_annual, 0)
           + CASE WHEN d.utilities_paid_by = 'owner'
                  THEN COALESCE(d.utilities_monthly, 0) * 12 ELSE 0 END
           + COALESCE(u.leasing_fee_monthly, 0) * 12
    INTO v_after, v_loan, v_rate, v_term, v_rent0, v_vac, v_mgmt, v_opex0
    FROM core.property p
    LEFT JOIN core.property_underwriting u ON u.property_id = p.property_id
    LEFT JOIN core.property_detail d       ON d.property_id = p.property_id
   WHERE p.property_id = p_property_id;

  IF v_after IS NULL OR v_loan IS NULL THEN RETURN; END IF;

  v_pay := core.monthly_payment(v_loan, v_rate, v_term);
  v_initial_equity := v_after - v_loan;

  -- What the investor actually put in: the same cash outlay the panel
  -- shows, and the denominator of every ROI below.
  SELECT COALESCE(u.offer_used, u.asking_price, 0) * COALESCE(u.down_payment_pct, 0)
       + core.improvement_estimate(u.improvements_low, u.improvements_high)
       + COALESCE(u.closing_costs, 0) + COALESCE(u.mortgage_costs, 0)
       + COALESCE(u.other_fees, 0)
    INTO v_outlay
    FROM core.property_underwriting u WHERE u.property_id = p_property_id;

  FOREACH h IN ARRAY ARRAY[5, 10, 15, 20] LOOP
    -- Accumulated year by year, because revenue and expenses grow at
    -- different rates: a closed form needs one rate and would quietly
    -- pick the wrong one.
    v_cash := 0;
    FOR i IN 1..h LOOP
      v_cash := v_cash
        + (v_rent0 * power(1 + a.revenue_growth, i - 1)) * (1 - v_vac - v_mgmt)
        - (v_opex0 * power(1 + a.expense_growth, i - 1))
        - COALESCE(v_pay, 0) * 12;
    END LOOP;

    v_val  := v_after * power(1 + a.appreciation, h);
    v_bal  := core.loan_balance(v_loan, v_rate, v_term, h * 12);
    v_eq   := (v_val - v_bal) - v_initial_equity;
    v_gain := v_cash + v_eq;

    years              := h;
    projected_value    := round(v_val, 2);
    loan_balance       := round(v_bal, 2);
    cumulative_cash    := round(v_cash, 2);
    equity_increase    := round(v_eq, 2);
    total_gain         := round(v_gain, 2);
    avg_cash_per_year  := round(v_cash / h, 2);
    avg_cash_per_month := round(v_cash / h / 12, 2);
    avg_gain_per_year  := round(v_gain / h, 2);
    annual_roi         := CASE WHEN COALESCE(v_outlay, 0) > 0
                               THEN round(v_gain / h / v_outlay, 4) END;
    RETURN NEXT;
  END LOOP;
END;
$fn$;

-- ---------------------------------------------------------------------
-- Section 2 -- benchmark indicators, year one
-- ---------------------------------------------------------------------
-- Per square foot, which is how these compare between markets. All three
-- are YEAR ONE deliberately: the workbook's heading says so, and a
-- cash-flow-per-foot averaged over twenty years flatters every property
-- equally and therefore ranks none of them.
CREATE FUNCTION api.property_benchmark(p_property_id uuid)
RETURNS TABLE (price_per_sqft numeric, rent_per_sqft numeric, cash_per_sqft numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $fn$
DECLARE
  v_sqft numeric; v_price numeric; v_rent numeric; v_loan numeric;
  v_rate numeric; v_term integer; v_off numeric; v_opex numeric;
  v_pay  numeric; v_year1 numeric;
BEGIN
  IF NOT sec.is_internal() AND NOT sec.is_assigned(p_property_id) THEN
    RETURN;
  END IF;

  SELECT NULLIF(p.sqft, 0)::numeric,
         COALESCE(u.offer_used, u.asking_price, p.list_price),
         COALESCE(core.rent_estimate(u.rent_lower_monthly, u.rent_upper_monthly),
                  d.market_rent_monthly),
         COALESCE(u.offer_used, u.asking_price, p.list_price)
           * (1 - COALESCE(u.down_payment_pct, 0)),
         u.interest_rate,
         COALESCE(u.mortgage_term_years, 30),
         (COALESCE(d.vacancy_allowance_bps, 0) + COALESCE(d.management_fee_bps, 0))
           / 10000.0,
         COALESCE(d.property_tax_annual, 0) + COALESCE(d.insurance_annual, 0)
           + COALESCE(d.maintenance_annual, 0)
           + CASE WHEN d.utilities_paid_by = 'owner'
                  THEN COALESCE(d.utilities_monthly, 0) * 12 ELSE 0 END
           + COALESCE(u.leasing_fee_monthly, 0) * 12
    INTO v_sqft, v_price, v_rent, v_loan, v_rate, v_term, v_off, v_opex
    FROM core.property p
    LEFT JOIN core.property_underwriting u ON u.property_id = p.property_id
    LEFT JOIN core.property_detail d       ON d.property_id = p.property_id
   WHERE p.property_id = p_property_id;

  IF v_sqft IS NULL THEN RETURN; END IF;

  v_pay   := core.monthly_payment(v_loan, v_rate, v_term);
  v_year1 := (COALESCE(v_rent, 0) * 12) * (1 - v_off)
             - COALESCE(v_opex, 0) - COALESCE(v_pay, 0) * 12;

  price_per_sqft := CASE WHEN v_price IS NOT NULL THEN round(v_price / v_sqft, 2) END;
  rent_per_sqft  := CASE WHEN v_rent  IS NOT NULL THEN round(v_rent  / v_sqft, 2) END;
  cash_per_sqft  := round(v_year1 / 12 / v_sqft, 2);
  RETURN NEXT;
END;
$fn$;

-- ---------------------------------------------------------------------
-- Reading the assumptions
-- ---------------------------------------------------------------------
-- Through api, not by naming core.projection_assumption from the web
-- tier. No application role holds USAGE on core, so a query that reaches
-- across fails with "permission denied for schema core" -- the boundary
-- doing its job, and the fourth time in this branch it has caught a read
-- written the short way.
--
-- Returns the house view when no row exists, so the panel never has to
-- decide what a missing assumption means.
CREATE FUNCTION api.property_assumptions(p_property_id uuid)
RETURNS TABLE (revenue_growth numeric, expense_growth numeric,
               appreciation numeric, land_pct numeric, selling_costs numeric,
               tax_ordinary numeric, tax_capital numeric, tax_state numeric,
               customised boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $fn$
DECLARE a core.projection_assumption%ROWTYPE;
BEGIN
  IF NOT sec.is_internal() AND NOT sec.is_assigned(p_property_id) THEN
    RETURN;
  END IF;
  SELECT * INTO a FROM core.projection_assumption WHERE property_id = p_property_id;
  IF FOUND THEN
    RETURN QUERY SELECT a.revenue_growth, a.expense_growth, a.appreciation,
                        a.land_pct, a.selling_costs, a.tax_ordinary,
                        a.tax_capital, a.tax_state, true;
  ELSE
    RETURN QUERY SELECT 0.0300::numeric, 0.0200::numeric, 0.0400::numeric,
                        0.2500::numeric, 0.0750::numeric, 0.2500::numeric,
                        0.1500::numeric, 0.1000::numeric, false;
  END IF;
END;
$fn$;

-- ---------------------------------------------------------------------
-- Writing the assumptions
-- ---------------------------------------------------------------------
CREATE FUNCTION api.save_assumptions(p_property_id uuid, p_patch jsonb)
RETURNS boolean
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $fn$
DECLARE k text; v text;
  -- An allowlist, like api.property_save. A jsonb patch applied without
  -- one is a way to write any column the table happens to have.
  allowed text[] := ARRAY['revenue_growth','expense_growth','appreciation',
                          'land_pct','selling_costs','tax_ordinary',
                          'tax_capital','tax_state'];
BEGIN
  IF NOT sec.is_internal() THEN
    RAISE EXCEPTION 'staff only' USING ERRCODE = '42501';
  END IF;
  INSERT INTO core.projection_assumption (property_id) VALUES (p_property_id)
  ON CONFLICT (property_id) DO NOTHING;

  FOR k, v IN SELECT * FROM jsonb_each_text(p_patch) LOOP
    IF NOT (k = ANY(allowed)) THEN
      RAISE EXCEPTION '% is not an assumption', k;
    END IF;
    EXECUTE format('UPDATE core.projection_assumption SET %I = $2::numeric,'
                   ' updated_at = now(), updated_by = $3 WHERE property_id = $1', k)
      USING p_property_id, v, sec.actor_id();
  END LOOP;
  RETURN true;
END;
$fn$;

REVOKE ALL ON FUNCTION api.property_projection(uuid), api.property_benchmark(uuid),
                       api.property_assumptions(uuid),
                       api.save_assumptions(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.property_projection(uuid), api.property_benchmark(uuid),
                          api.property_assumptions(uuid)
    TO sdi_agent, sdi_admin;
GRANT EXECUTE ON FUNCTION api.save_assumptions(uuid, jsonb) TO sdi_admin;

COMMIT;
