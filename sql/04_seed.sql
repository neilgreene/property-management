-- =====================================================================
-- 04_seed.sql  |  Demo data. Fixed UUIDs so the walkthrough is repeatable.
-- =====================================================================

INSERT INTO core.brand (brand_code, display_name, service_tier, platform_fee) VALUES
  ('BRAND_A', 'SDI Marketplace',  'self_service', 750.00),
  ('KAVADOO', 'Kavadoo Advisory', 'concierge',   2500.00);

INSERT INTO core.person (person_id, role, full_name, email, fee_agreement_signed_at, home_brand) VALUES
  ('11111111-1111-1111-1111-111111111111','investor','Ruth Okonkwo',  'ruth@example.com',   now() - interval '30 days','BRAND_A'),
  ('22222222-2222-2222-2222-222222222222','investor','Marcus Pell',   'marcus@example.com', NULL,                       'BRAND_A'),
  ('33333333-3333-3333-3333-333333333333','investor','Ines Duarte',   'ines@example.com',   now() - interval '5 days',  'KAVADOO'),
  ('44444444-4444-4444-4444-444444444444','agent',   'Tom Bradbury',  'tom@example.com',    NULL,                       'BRAND_A'),
  ('55555555-5555-5555-5555-555555555555','agent',   'Priya Raman',   'priya@example.com',  NULL,                       'BRAND_A'),
  ('66666666-6666-6666-6666-666666666666','admin',   'Dan Beitor',    'dan@example.com',    NULL,                       'BRAND_A');

INSERT INTO core.property
 (property_id, listing_ref, status, city, state, zip, property_type, beds, baths, sqft, year_built,
  list_price, gross_rent_annual, opex_annual, hoa_annual,
  street_address, unit, lat, lng, parcel_number, seller_disclosure,
  acquisition_cost, source_channel, internal_notes) VALUES
 ('aaaaaaa1-0000-0000-0000-000000000001','SDI-1041','active','Huntsville','AL','35801','Single Family',3,2.0,1580,2004,
  228000,25800,7200,0,'4417 Bramblewood Dr',NULL,34.730369,-86.586104,'12-04-33-1-002','Roof replaced 2021; seller financing considered',
  198500,'Wholesaler - Redstone','Seller motivated, will take 219k. Do not surface.'),

 ('aaaaaaa1-0000-0000-0000-000000000002','SDI-1042','active','Cleveland','OH','44109','Duplex',4,2.0,2140,1962,
  184000,27600,9800,0,'3312 Denison Ave',NULL,41.447800,-81.700400,'009-21-114','Tenant in place unit B, lease thru 2027',
  152000,'Direct mail','Both units section 8. Cash flow strong, cosmetics weak.'),

 ('aaaaaaa1-0000-0000-0000-000000000003','SDI-1043','active','Kansas City','MO','64131','Single Family',3,1.5,1320,1958,
  165000,20400,6600,0,'7809 Walnut St',NULL,38.999500,-94.585900,'46-820-09-11','As-is, no repairs',
  141000,'MLS - agent network','Inspection flagged foundation hairline. Disclose at LOI only.'),

 ('aaaaaaa1-0000-0000-0000-000000000004','SDI-1044','coming_soon','Tampa','FL','33610','Single Family',4,2.0,1760,1998,
  312000,33600,11400,1800,'2205 E Osborne Ave',NULL,27.995600,-82.435400,'A-28-29-19-000','New HVAC 2023',
  271000,'Builder relationship','Builder will do 3 more at this price if we move fast.'),

 ('aaaaaaa1-0000-0000-0000-000000000005','SDI-1045','pending','Indianapolis','IN','46203','Single Family',3,2.0,1440,1974,
  178000,21600,7100,0,'1533 Spann Ave',NULL,39.752200,-86.132900,'49-11-33-104','Roof 2019',
  149500,'Wholesaler - Midwest','Under contract w/ Ruth. Backup offer from Marcus pending.'),

 ('aaaaaaa1-0000-0000-0000-000000000006','SDI-1046','sold','Memphis','TN','38111','Single Family',3,1.0,1180,1955,
  132000,18000,6200,0,'3744 Kimball Ave',NULL,35.108900,-89.936700,'061032-00019','Sold as-is',
  112000,'Auction','Closed Feb. Margin 20k. Reference comp for 38111.'),

 ('aaaaaaa1-0000-0000-0000-000000000007','SDI-1047','draft','Birmingham','AL','35206','Duplex',4,2.0,1960,1949,
  148000,24000,9100,0,'7712 5th Ave S',NULL,33.549800,-86.716200,'23-00-14-2-011','Pending inspection',
  118000,'Wholesaler - Redstone','NOT VETTED. Do not publish until survey back.'),

 ('aaaaaaa1-0000-0000-0000-000000000008','SDI-1048','active','Huntsville','AL','35810','Single Family',3,2.0,1490,2011,
  245000,26400,7600,0,'118 Cedar Gap Rd',NULL,34.782100,-86.601500,'12-09-21-4-007','Warranty transferable',
  213000,'Builder relationship','Pair with 1041 for the Kavadoo bundle pitch.');

-- Publication + brand pricing. KAVADOO carries a concierge markup on the
-- subset it lists. Same rows, different lens.
INSERT INTO core.property_brand (property_id, brand_code, published, brand_price) VALUES
 ('aaaaaaa1-0000-0000-0000-000000000001','BRAND_A',true, NULL),
 ('aaaaaaa1-0000-0000-0000-000000000002','BRAND_A',true, NULL),
 ('aaaaaaa1-0000-0000-0000-000000000003','BRAND_A',true, NULL),
 ('aaaaaaa1-0000-0000-0000-000000000004','BRAND_A',true, NULL),
 ('aaaaaaa1-0000-0000-0000-000000000005','BRAND_A',true, NULL),
 ('aaaaaaa1-0000-0000-0000-000000000006','BRAND_A',true, NULL),
 ('aaaaaaa1-0000-0000-0000-000000000008','BRAND_A',true, NULL),
 ('aaaaaaa1-0000-0000-0000-000000000007','BRAND_A',false,NULL),
 -- Kavadoo lists three of the same properties at a concierge premium
 ('aaaaaaa1-0000-0000-0000-000000000001','KAVADOO',true, 241000),
 ('aaaaaaa1-0000-0000-0000-000000000004','KAVADOO',true, 329000),
 ('aaaaaaa1-0000-0000-0000-000000000008','KAVADOO',true, 259000);

INSERT INTO core.property_assignment (property_id, person_id, assign_role) VALUES
 ('aaaaaaa1-0000-0000-0000-000000000001','44444444-4444-4444-4444-444444444444','agent'),
 ('aaaaaaa1-0000-0000-0000-000000000002','44444444-4444-4444-4444-444444444444','agent'),
 ('aaaaaaa1-0000-0000-0000-000000000005','44444444-4444-4444-4444-444444444444','agent'),
 ('aaaaaaa1-0000-0000-0000-000000000007','44444444-4444-4444-4444-444444444444','agent'),
 ('aaaaaaa1-0000-0000-0000-000000000003','55555555-5555-5555-5555-555555555555','agent'),
 ('aaaaaaa1-0000-0000-0000-000000000004','55555555-5555-5555-5555-555555555555','agent'),
 ('aaaaaaa1-0000-0000-0000-000000000006','55555555-5555-5555-5555-555555555555','agent'),
 ('aaaaaaa1-0000-0000-0000-000000000005','11111111-1111-1111-1111-111111111111','investor');

INSERT INTO core.saved_property (person_id, property_id) VALUES
 ('11111111-1111-1111-1111-111111111111','aaaaaaa1-0000-0000-0000-000000000001'),
 ('11111111-1111-1111-1111-111111111111','aaaaaaa1-0000-0000-0000-000000000004');
