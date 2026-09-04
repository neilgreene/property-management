-- =====================================================================
-- 40_property_admin.sql  |  what an internal user sees and can change
-- =====================================================================
-- One view and one write function behind the properties panel.
--
-- THE COMPUTED FIGURES LIVE HERE, NOT IN THE BROWSER. Day-one equity,
-- total cost, cash outlay, the mortgage payment and net operating income
-- are derived in the view. The panel shows them updating as somebody
-- types, but it recomputes them for display only -- the number that is
-- stored, reported and published comes from this file. The alternative is
-- the spreadsheet's besetting problem: the same formula written in three
-- places and corrected in two.
--
-- WRITES GO THROUGH ONE FUNCTION WITH AN EXPLICIT FIELD LIST. Not a
-- generic "update these columns" -- an allowlist, so a field that is not
-- meant to be editable cannot become editable by a caller naming it.
-- listing_ref, acquisition_cost and the address are deliberately absent.

BEGIN;

CREATE VIEW api.property_admin
WITH (security_invoker = true, security_barrier = true) AS
SELECT
    p.property_id, p.listing_ref, p.status,
    p.street_address, p.unit, p.city, p.state, p.zip, p.metro_code,
    m.label AS metro_label,
    p.property_type, p.beds, p.baths, p.sqft, p.year_built,
    p.list_price, p.hoa_annual, p.lat, p.lng,
    p.internal_notes,

    d.headline, d.description,
    d.market_rent_monthly, d.rent_basis,
    d.property_tax_annual, d.insurance_annual,
    d.utilities_monthly, d.utilities_paid_by,
    d.maintenance_annual, d.management_fee_bps, d.vacancy_allowance_bps,
    d.lot_sqft, d.stories, d.garage_spaces, d.heating, d.cooling,
    d.roof_year, d.last_renovated, d.parking, d.features,

    u.offer_used, u.suggested_offer_low, u.suggested_offer_high,
    u.asking_price, u.market_value_after,
    u.improvements_low, u.improvements_high,
    u.closing_costs, u.mortgage_costs, u.other_fees, u.original_listed_on,
    u.down_payment_pct, u.interest_rate, u.mortgage_term_years,
    u.rent_upper_monthly, u.rent_lower_monthly, u.leasing_fee_monthly,
    u.updated_at AS underwriting_updated_at,

    -- Days on market, counted rather than stored, so it is never stale.
    (current_date - u.original_listed_on)                        AS days_on_market,

    -- Improvements are a RANGE, and the workbook costs the deal at the
    -- MIDDLE of it, not the top. Worth stating because it was not obvious
    -- and the first version of this view guessed the high end: against
    -- 401 NW 71st St that produced a total cost of $308,334 where the
    -- workbook says $307,084, and the $1,250 gap is exactly half the
    -- $2,500-$5,000 improvement range. With the midpoint every figure on
    -- the sheet reconciles to the cent.
    (COALESCE(u.offer_used, 0) + core.improvement_estimate(u.improvements_low, u.improvements_high)
     + COALESCE(u.closing_costs, 0) + COALESCE(u.mortgage_costs, 0)
     + COALESCE(u.other_fees, 0))                                AS total_cost,

    (COALESCE(u.market_value_after, 0)
     - (COALESCE(u.offer_used, 0) + core.improvement_estimate(u.improvements_low, u.improvements_high)
        + COALESCE(u.closing_costs, 0) + COALESCE(u.mortgage_costs, 0)
        + COALESCE(u.other_fees, 0)))                            AS day_one_equity,

    round(COALESCE(u.offer_used, 0) * COALESCE(u.down_payment_pct, 0), 2)
                                                                 AS down_payment_amount,
    round(COALESCE(u.offer_used, 0) * (1 - COALESCE(u.down_payment_pct, 0)), 2)
                                                                 AS financed_amount,

    core.monthly_payment(
        COALESCE(u.offer_used, 0) * (1 - COALESCE(u.down_payment_pct, 0)),
        u.interest_rate, u.mortgage_term_years)                  AS monthly_mortgage,

    -- Out of pocket: the deposit plus everything not financed.
    (round(COALESCE(u.offer_used, 0) * COALESCE(u.down_payment_pct, 0), 2)
     + core.improvement_estimate(u.improvements_low, u.improvements_high)
     + COALESCE(u.closing_costs, 0) + COALESCE(u.mortgage_costs, 0)
     + COALESCE(u.other_fees, 0))                                AS cash_outlay,

    core.improvement_estimate(u.improvements_low, u.improvements_high)
                                                                 AS improvement_estimate,

    -- The operating picture, on the same definitions the listing uses.
    (COALESCE(d.market_rent_monthly, 0) * 12)                    AS gross_rent_annual,
    round(COALESCE(d.market_rent_monthly, 0) * 12
          * COALESCE(d.vacancy_allowance_bps, 0) / 10000.0, 2)   AS vacancy_annual,
    round(COALESCE(d.market_rent_monthly, 0) * 12
          * COALESCE(d.management_fee_bps, 0) / 10000.0, 2)      AS management_annual,
    (COALESCE(d.property_tax_annual, 0) + COALESCE(d.insurance_annual, 0)
     + COALESCE(d.maintenance_annual, 0)
     + CASE WHEN d.utilities_paid_by = 'owner'
            THEN COALESCE(d.utilities_monthly, 0) * 12 ELSE 0 END)
                                                                 AS opex_annual,
    p.noi_annual, p.cap_rate,

    -- The card image, read through api.property_media so it obeys the same
    -- rules as everywhere else. Staff are past the gate, so this is the
    -- real photograph rather than a mask -- which is the point: somebody
    -- editing the numbers should be able to see which house they are
    -- editing without opening another screen.
    (SELECT COALESCE(mm.thumb_url, mm.url)
       FROM api.property_media mm
      WHERE mm.property_id = p.property_id
      ORDER BY mm.is_primary DESC, mm.position
      LIMIT 1)                                                   AS primary_image,

    (SELECT count(*) FROM core.property_media pm
      WHERE pm.property_id = p.property_id AND pm.state = 'published')::int
                                                                 AS published_photos,
    (SELECT count(*) FROM core.property_media pm
      WHERE pm.property_id = p.property_id AND pm.state = 'pending')::int
                                                                 AS pending_photos
FROM core.property p
LEFT JOIN core.property_detail       d ON d.property_id = p.property_id
LEFT JOIN core.property_underwriting u ON u.property_id = p.property_id
LEFT JOIN core.metro                 m ON m.metro_code  = p.metro_code;

GRANT SELECT ON api.property_admin TO sdi_agent, sdi_admin;

-- ---------------------------------------------------------------------
-- Saving
--
-- A jsonb patch against an allowlist, one field at a time, each change
-- recorded with its old and new value. Fields absent from the patch are
-- left alone, so two people editing different halves of the panel do not
-- overwrite each other with stale values read at page load.
-- ---------------------------------------------------------------------
CREATE FUNCTION api.property_save(p_property_id uuid, p_patch jsonb)
RETURNS TABLE (field text, old_value text, new_value text)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = core, sec, api, pg_temp
AS $fn$
DECLARE
  k text; v text; old text; stored text; tbl text; ftype text; n integer;
  -- The allowlist. Absent on purpose: listing_ref (an identifier people
  -- quote), acquisition_cost (band 3 and set at purchase), the address
  -- and the coordinates (changing them silently moves a listing), and
  -- status, which has its own transitions.
  cols constant jsonb := jsonb_build_object(
    'detail', jsonb_build_array(
      'headline','description','market_rent_monthly','rent_basis',
      'property_tax_annual','insurance_annual','utilities_monthly',
      'utilities_paid_by','maintenance_annual','management_fee_bps',
      'vacancy_allowance_bps','lot_sqft','stories','garage_spaces',
      'heating','cooling','roof_year','last_renovated','parking'),
    'underwriting', jsonb_build_array(
      'offer_used','suggested_offer_low','suggested_offer_high','asking_price',
      'market_value_after','improvements_low','improvements_high',
      'closing_costs','mortgage_costs','other_fees','original_listed_on',
      'down_payment_pct','interest_rate','mortgage_term_years',
      'rent_upper_monthly','rent_lower_monthly','leasing_fee_monthly'),
    'property', jsonb_build_array(
      'beds','baths','sqft','year_built','list_price','hoa_annual',
      'property_type','metro_code','internal_notes')
  );
BEGIN
  IF NOT sec.can_manage_media(p_property_id) THEN
    RAISE EXCEPTION 'not authorised to edit this property' USING ERRCODE = '42501';
  END IF;

  -- The child rows may not exist yet; a property imported before this
  -- table did has no underwriting row until somebody opens the panel.
  INSERT INTO core.property_detail (property_id) VALUES (p_property_id)
    ON CONFLICT DO NOTHING;
  INSERT INTO core.property_underwriting (property_id) VALUES (p_property_id)
    ON CONFLICT DO NOTHING;

  FOR k, v IN SELECT * FROM jsonb_each_text(p_patch) LOOP
    tbl := CASE
      WHEN cols->'detail'       @> to_jsonb(k) THEN 'property_detail'
      WHEN cols->'underwriting' @> to_jsonb(k) THEN 'property_underwriting'
      WHEN cols->'property'     @> to_jsonb(k) THEN 'property'
    END;
    -- An unknown key is refused, not ignored. Ignoring it means a typo in
    -- a field name looks like a successful save and loses the edit.
    IF tbl IS NULL THEN
      RAISE EXCEPTION 'field % is not editable here', k USING ERRCODE = '22023';
    END IF;

    SELECT format_type(a.atttypid, a.atttypmod) INTO ftype
      FROM pg_attribute a
     WHERE a.attrelid = ('core.' || tbl)::regclass AND a.attname = k;

    EXECUTE format(
      'SELECT %I::text FROM core.%I WHERE property_id = $1', k, tbl)
      INTO old USING p_property_id;

    -- The comparison happens IN THE COLUMN'S OWN TYPE, inside the UPDATE,
    -- rather than between text renderings. numeric(12,2) renders 1234 as
    -- "1234.00", so comparing strings made every re-save of an unchanged
    -- form look like a change: open the panel, press Save, and the history
    -- gained an entry saying 1234.00 became 1234. A change log that fills
    -- with no-ops is a change log nobody reads.
    EXECUTE format(
      'UPDATE core.%I SET %I = NULLIF($2, '''')::text::%s
        WHERE property_id = $1 AND %I IS DISTINCT FROM NULLIF($2, '''')::text::%s',
      tbl, k, ftype, k, ftype)
      USING p_property_id, v;
    GET DIAGNOSTICS n = ROW_COUNT;

    IF n > 0 THEN
      -- Read back rather than logging the input: the column may have
      -- rounded or normalised it, and the log should say what was stored.
      EXECUTE format('SELECT %I::text FROM core.%I WHERE property_id = $1', k, tbl)
        INTO stored USING p_property_id;

      INSERT INTO core.property_change (property_id, field, old_value, new_value, actor_id)
      VALUES (p_property_id, k, old, stored, sec.actor_id());

      field := k; old_value := old; new_value := stored; RETURN NEXT;
    END IF;
  END LOOP;

  UPDATE core.property_underwriting
     SET updated_at = now(), updated_by = sec.actor_id()
   WHERE property_id = p_property_id;
  UPDATE core.property_detail SET updated_at = now()
   WHERE property_id = p_property_id;
END;
$fn$;

REVOKE ALL ON FUNCTION api.property_save(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.property_save(uuid, jsonb) TO sdi_agent, sdi_admin;

-- Who made a change, by name.
--
-- A SECURITY DEFINER lookup rather than a join, because the history view
-- runs with the caller's rights and no staff role holds SELECT on
-- core.person -- the identity tables are read through sec predicates, not
-- directly. Widening that grant to render a name would be a large change
-- for a small label. This returns one name for one id the caller already
-- has in front of them, and nothing else.
CREATE FUNCTION sec.actor_name(p_person_id uuid) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = core, pg_temp
AS $$
  SELECT COALESCE((SELECT full_name FROM core.person WHERE person_id = p_person_id),
                  'system');
$$;

REVOKE ALL ON FUNCTION sec.actor_name(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sec.actor_name(uuid) TO sdi_agent, sdi_admin;

-- The change log, for the panel's history strip.
CREATE VIEW api.property_history
WITH (security_invoker = true, security_barrier = true) AS
SELECT c.change_id, c.property_id, c.field, c.old_value, c.new_value, c.at,
       sec.actor_name(c.actor_id) AS actor
FROM core.property_change c
ORDER BY c.at DESC;

GRANT SELECT ON api.property_history TO sdi_agent, sdi_admin;

COMMIT;
