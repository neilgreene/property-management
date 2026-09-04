-- =====================================================================
-- 42_underwriting_seed.sql  |  one property, worked through
-- =====================================================================
-- The figures from the 401 NW 71st St, Kansas City workbook, put onto one
-- demo listing so the panel has something real in it.
--
-- ONE, not twenty-five. Deriving an offer, an improvement range and a
-- financing structure for the other twenty-four from their list prices
-- would be inventing numbers that look researched, and somebody would
-- eventually quote one. The rest show "not set", which is what they are.
--
-- These figures reconcile exactly to the sheet: total cost $307,084,
-- day-one equity -$7,084, down payment $88,500, financed $206,500,
-- monthly payment $1,304, cash outlay $100,584. If a change to the view's
-- arithmetic ever breaks that, 05_tests will say so.

BEGIN;

INSERT INTO core.property_underwriting
 (property_id, offer_used, suggested_offer_low, suggested_offer_high,
  asking_price, market_value_after, improvements_low, improvements_high,
  closing_costs, mortgage_costs, other_fees, original_listed_on,
  down_payment_pct, interest_rate, mortgage_term_years,
  rent_upper_monthly, rent_lower_monthly, leasing_fee_monthly)
SELECT property_id,
       295000, 290000, 295000,
       299900, 300000, 2500, 5000,
       3688, 2581, 2065, DATE '2026-08-17',
       0.3000, 0.06490, 30,
       2250, 2100, 29.20
FROM core.property WHERE listing_ref = 'SDI-1009'
ON CONFLICT (property_id) DO NOTHING;

-- It is a Kansas City-SH property, which is what makes its 8.0% management
-- fee and $29.20 leasing fee attributable to that programme at all.
UPDATE core.property SET metro_code = 'KC-SH' WHERE listing_ref = 'SDI-1009';

UPDATE core.property_underwriting u
   SET fee_schedule_id = s.schedule_id, fees_applied_at = now()
  FROM core.fee_schedule s, core.property p
 WHERE u.property_id = p.property_id
   AND p.listing_ref = 'SDI-1009'
   AND s.metro_code = 'KC-SH' AND s.effective_from = DATE '2026-01-01';

UPDATE core.property_detail d
   SET management_fee_bps = 800, vacancy_allowance_bps = 400,
       property_tax_annual = 2760, insurance_annual = 1800,
       maintenance_annual = 1200, market_rent_monthly = 2100
  FROM core.property p
 WHERE d.property_id = p.property_id AND p.listing_ref = 'SDI-1009';

COMMIT;
