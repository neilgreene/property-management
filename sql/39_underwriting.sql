-- =====================================================================
-- 39_underwriting.sql  |  the numbers behind the listing
-- =====================================================================
-- The published listing carries what an investor underwrites on: price,
-- rent, expenses, cap rate. The workbook carries the layer beneath that --
-- what was offered, what was asked, what the improvements will cost, how
-- it is financed. None of it was stored anywhere, so a member of staff
-- managing a property had a spreadsheet and no system.
--
-- BAND 3. Every column here is internal. An offer, a suggested range and a
-- day-one equity figure tell a buyer what the operator paid and what
-- margin is in the deal, which is exactly what acquisition_cost is already
-- withheld for. The table is granted to staff and to nobody else, and it
-- appears in no view a buyer can read.
--
-- NOT HERE: the workbook's Schools Rating. gov.prohibited_dimension lists
-- school_rating as a proxy for race and national origin -- "offering one
-- as a ranking axis is steering by another name" -- and the standing
-- invariant fails the build if it ever appears as a column in the api
-- schema. Storing it as a structured, sortable number in a marketplace
-- database is one careless view definition away from being a filter. It
-- belongs in internal_notes as prose, where it cannot be sorted on.

BEGIN;

CREATE TABLE core.property_underwriting (
    property_id            uuid PRIMARY KEY
                             REFERENCES core.property(property_id) ON DELETE CASCADE,

    -- B. Purchase assumptions
    offer_used             numeric(12,2),   -- the offer this analysis is built on
    suggested_offer_low    numeric(12,2),
    suggested_offer_high   numeric(12,2),
    asking_price           numeric(12,2),
    market_value_after     numeric(12,2),   -- after improvements
    improvements_low       numeric(12,2),
    improvements_high      numeric(12,2),
    closing_costs          numeric(12,2),
    mortgage_costs         numeric(12,2),
    other_fees             numeric(12,2),
    original_listed_on     date,

    -- C. Financing assumptions
    down_payment_pct       numeric(6,4),    -- 0.3000 = 30%
    interest_rate          numeric(7,5),    -- 0.06490 = 6.490%
    mortgage_term_years    smallint,

    -- D. Rent and letting, where the workbook is finer than the listing
    rent_upper_monthly     numeric(10,2),
    rent_lower_monthly     numeric(10,2),
    leasing_fee_monthly    numeric(10,2),

    -- Which version of the programme's fee schedule these fees were copied
    -- from. The foreign key is added in 41, once that table exists; the
    -- columns live here because they belong to the property, not to the
    -- schedule. See 41_property_manager.sql for why this is a copy and not
    -- a lookup.
    fee_schedule_id        integer,
    fees_applied_at        timestamptz,

    updated_at             timestamptz NOT NULL DEFAULT now(),
    updated_by             uuid REFERENCES core.person(person_id),

    CONSTRAINT uw_offer_range CHECK (
        suggested_offer_low IS NULL OR suggested_offer_high IS NULL
        OR suggested_offer_low <= suggested_offer_high),
    CONSTRAINT uw_improvement_range CHECK (
        improvements_low IS NULL OR improvements_high IS NULL
        OR improvements_low <= improvements_high),
    CONSTRAINT uw_rent_range CHECK (
        rent_lower_monthly IS NULL OR rent_upper_monthly IS NULL
        OR rent_lower_monthly <= rent_upper_monthly),
    -- A down payment over 100% or a negative rate is a typo, and a typo
    -- that reaches a projection is worse than a rejected save.
    CONSTRAINT uw_down_payment CHECK (down_payment_pct IS NULL
        OR (down_payment_pct >= 0 AND down_payment_pct <= 1)),
    CONSTRAINT uw_rate CHECK (interest_rate IS NULL
        OR (interest_rate >= 0 AND interest_rate < 1)),
    CONSTRAINT uw_term CHECK (mortgage_term_years IS NULL
        OR (mortgage_term_years > 0 AND mortgage_term_years <= 50))
);

ALTER TABLE core.property_underwriting ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.property_underwriting FORCE  ROW LEVEL SECURITY;

-- Staff only, and an agent only for their own book. No policy for
-- sdi_public or sdi_investor at all: absence is the strongest statement
-- the system can make about a band 3 table.
CREATE POLICY uw_staff ON core.property_underwriting FOR ALL
  USING (sec.can_manage_media(property_id))
  WITH CHECK (sec.can_manage_media(property_id));

GRANT SELECT, INSERT, UPDATE, DELETE ON core.property_underwriting
    TO sdi_agent, sdi_admin;

-- ---------------------------------------------------------------------
-- The mortgage payment, in one place
--
-- The panel shows it, a projection uses it, and a report will want it.
-- Written once so the three cannot disagree -- a spreadsheet's besetting
-- problem is the same formula typed four times and edited three.
-- ---------------------------------------------------------------------
CREATE FUNCTION core.monthly_payment(
    p_principal numeric, p_annual_rate numeric, p_years integer)
RETURNS numeric
LANGUAGE sql IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_principal IS NULL OR p_years IS NULL OR p_years <= 0 THEN NULL
    -- A zero-rate loan is not a division by zero, it is principal over
    -- months. Worth handling: an operator clearing the rate field to try
    -- something should get a number, not an error.
    WHEN COALESCE(p_annual_rate, 0) = 0 THEN round(p_principal / (p_years * 12), 2)
    ELSE round(
      p_principal * (p_annual_rate / 12)
      / (1 - power(1 + (p_annual_rate / 12), -(p_years * 12))), 2)
  END;
$$;

-- ---------------------------------------------------------------------
-- What the improvements are costed at
--
-- The workbook records a range and costs the deal at the MIDDLE of it.
-- Confirmed against 401 NW 71st St: $2,500-$5,000 improvements, and the
-- sheet's total cost of $307,084 is only reachable with $3,750. Costing at
-- the high end -- the obvious guess, and the one made first -- came out
-- $1,250 heavy on every derived figure.
--
-- One end alone falls back to that end, because a range with one bound is
-- an estimate somebody has half-entered, not an error.
-- ---------------------------------------------------------------------
CREATE FUNCTION core.improvement_estimate(p_low numeric, p_high numeric)
RETURNS numeric
LANGUAGE sql IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_low IS NOT NULL AND p_high IS NOT NULL THEN round((p_low + p_high) / 2, 2)
    ELSE COALESCE(p_high, p_low, 0)
  END;
$$;

-- ---------------------------------------------------------------------
-- Every change, recorded
--
-- Field by field rather than a row snapshot. "Somebody edited this
-- property on Tuesday" does not answer the question people actually ask,
-- which is "who moved the vacancy rate to six per cent, and when".
-- ---------------------------------------------------------------------
CREATE TABLE core.property_change (
    change_id   bigserial PRIMARY KEY,
    property_id uuid NOT NULL,
    field       text NOT NULL,
    old_value   text,
    new_value   text,
    actor_id    uuid,
    at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_property_change ON core.property_change (property_id, at DESC);

ALTER TABLE core.property_change ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.property_change FORCE  ROW LEVEL SECURITY;
CREATE POLICY change_read ON core.property_change FOR SELECT
  USING (sec.can_manage_media(property_id));
GRANT SELECT ON core.property_change TO sdi_agent, sdi_admin;

COMMIT;
