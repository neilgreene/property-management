-- =====================================================================
-- 60_my_properties.sql  |  what a customer's contracts have opened
-- =====================================================================
-- The customer's own list: the properties an approved contract of theirs
-- names, and therefore the ones whose address and photographs they can
-- see. It reads api.property_card, so every field arrives already
-- filtered by the same rules that filter it everywhere else -- the gate
-- is not re-implemented here, which is the only way to be sure the two
-- agree.
--
-- SECURITY DEFINER for the join to core.contract, which no application
-- role may read. The rows themselves still come out of the view, so the
-- address is present or absent for exactly the reason it always was.

BEGIN;

CREATE FUNCTION api.my_properties()
RETURNS TABLE (property_id uuid, listing_ref text, city text, state text,
               property_type text, beds integer, baths numeric, sqft integer,
               list_price numeric, cap_rate numeric, noi_annual numeric,
               street_address text, address_unlocked boolean,
               primary_image text,
               contract_id uuid, contract_reference text,
               approved_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = api, core, sec, pg_temp
AS $$
  SELECT DISTINCT ON (pc.property_id)
         pc.property_id, pc.listing_ref, pc.city, pc.state,
         pc.property_type, pc.beds, pc.baths, pc.sqft,
         pc.list_price, pc.cap_rate, pc.noi_annual,
         pc.street_address, pc.address_unlocked, pc.primary_image,
         k.contract_id, k.reference, k.approved_at
    FROM core.contract k
    JOIN core.contract_property cp ON cp.contract_id = k.contract_id
    JOIN api.property_card pc      ON pc.property_id = cp.property_id
   WHERE k.person_id = sec.actor_id()
     AND k.status = 'approved'
   -- A property can sit on more than one approved contract. It is one
   -- property either way, so the earliest one that opened it is the one
   -- worth naming.
   ORDER BY pc.property_id, k.approved_at;
$$;

REVOKE ALL ON FUNCTION api.my_properties() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.my_properties()
  TO sdi_investor, sdi_agent, sdi_admin;

COMMIT;
