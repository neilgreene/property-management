-- =====================================================================
-- 16_demo_dataset.sql  |  a dataset large enough to filter
-- =====================================================================
-- The original eight properties prove the visibility model but are too
-- uniform to demonstrate search: three or four bedrooms, one narrow price
-- band. Filtering across them shows nothing. These sixteen widen every
-- axis the demo filters on -- price, bedrooms, bathrooms and floor area --
-- so a filter visibly changes the result rather than appearing to do
-- nothing.
--
-- Invented data. The financials are internally consistent (rent roughly
-- tracks price and size, opex tracks age) so the derived cap rate lands in
-- a believable range rather than reading as noise.

BEGIN;

INSERT INTO core.property
 (property_id, listing_ref, status, city, state, zip, property_type, beds, baths, sqft, year_built,
  list_price, gross_rent_annual, opex_annual, hoa_annual,
  street_address, unit, lat, lng, parcel_number, seller_disclosure,
  acquisition_cost, source_channel, internal_notes) VALUES
 ('aaaaaaa1-0000-0000-0000-000000000009','SDI-1009','active','Columbus','OH','43206','Single Family',5,2.0,3350,1970,
  505500,51400,13200,0,'4227 Cedar Dr',NULL,39.915678,-82.971094,
  '70-10-870','Standard disclosure on file.',
  429000,'Wholesaler','Demo record.'),
 ('aaaaaaa1-0000-0000-0000-000000000010','SDI-1010','pending','Memphis','TN','38111','Triplex',6,1.0,4200,1957,
  491000,62500,21700,0,'1380 Bramble Rd',NULL,35.097566,-89.948590,
  '43-96-524','Standard disclosure on file.',
  450000,'Direct mail','Demo record.'),
 ('aaaaaaa1-0000-0000-0000-000000000011','SDI-1011','active','Indianapolis','IN','46203','Duplex',2,3.0,1024,1950,
  158000,14600,5400,0,'6548 Kingsley Dr',NULL,39.777159,-86.131011,
  '58-39-667','Standard disclosure on file.',
  143500,'Direct mail','Demo record.'),
 ('aaaaaaa1-0000-0000-0000-000000000012','SDI-1012','active','Columbus','OH','43206','Townhouse',3,2.5,2311,2004,
  364000,48600,17000,0,'4987 Prospect Rd',NULL,39.953958,-82.978338,
  '51-59-771','Standard disclosure on file.',
  329500,'MLS','Demo record.'),
 ('aaaaaaa1-0000-0000-0000-000000000013','SDI-1013','active','Tampa','FL','33604','Condo',6,1.5,3958,1971,
  525500,57100,19400,2400,'8663 Bramble Ln',NULL,27.968926,-82.451338,
  '21-53-597','Standard disclosure on file.',
  487500,'Wholesaler','Demo record.'),
 ('aaaaaaa1-0000-0000-0000-000000000014','SDI-1014','coming_soon','Cleveland','OH','44109','Condo',2,3.5,1699,2005,
  188500,18500,7400,1200,'7623 Winslow Rd',NULL,41.411848,-81.709068,
  '26-79-148','Standard disclosure on file.',
  167000,'Auction','Demo record.'),
 ('aaaaaaa1-0000-0000-0000-000000000015','SDI-1015','active','Cleveland','OH','44109','Duplex',1,2.0,910,1980,
  87000,9100,2700,0,'1625 Chestnut Ave',NULL,41.421598,-81.664060,
  '63-36-495','Standard disclosure on file.',
  80500,'Agent referral','Demo record.'),
 ('aaaaaaa1-0000-0000-0000-000000000016','SDI-1016','active','Indianapolis','IN','46203','Condo',3,1.0,2417,2005,
  206500,24100,9700,1800,'5189 Chestnut Ln',NULL,39.723913,-86.173387,
  '18-19-636','Standard disclosure on file.',
  180500,'Auction','Demo record.'),
 ('aaaaaaa1-0000-0000-0000-000000000017','SDI-1017','sold','Toledo','OH','43613','Triplex',2,1.0,1463,1967,
  130000,12500,3300,0,'4461 Ashland Rd',NULL,41.738959,-83.580457,
  '57-59-262','Standard disclosure on file.',
  107500,'Auction','Demo record.'),
 ('aaaaaaa1-0000-0000-0000-000000000018','SDI-1018','active','Indianapolis','IN','46203','Triplex',6,2.5,4030,1991,
  482500,62000,19600,0,'3894 Fairview St',NULL,39.782480,-86.114999,
  '90-35-568','Standard disclosure on file.',
  446500,'Direct mail','Demo record.'),
 ('aaaaaaa1-0000-0000-0000-000000000019','SDI-1019','active','Kansas City','MO','64131','Single Family',4,1.0,2393,1980,
  385000,43600,11500,0,'4650 Fairview Rd',NULL,39.037799,-94.576748,
  '98-76-886','Standard disclosure on file.',
  325000,'Direct mail','Demo record.'),
 ('aaaaaaa1-0000-0000-0000-000000000020','SDI-1020','active','Tampa','FL','33604','Triplex',2,1.0,1526,2011,
  225000,26100,7900,0,'5316 Cedar Rd',NULL,27.955413,-82.457195,
  '10-61-297','Standard disclosure on file.',
  190000,'Auction','Demo record.'),
 ('aaaaaaa1-0000-0000-0000-000000000021','SDI-1021','sold','Cleveland','OH','44109','Townhouse',3,2.0,2434,2010,
  214000,18300,6100,0,'6477 Belmont Ave',NULL,41.437303,-81.662399,
  '38-28-656','Standard disclosure on file.',
  198000,'Auction','Demo record.'),
 ('aaaaaaa1-0000-0000-0000-000000000022','SDI-1022','coming_soon','Cleveland','OH','44109','Condo',5,1.0,3618,1956,
  581000,66300,16700,2400,'3464 Oakridge St',NULL,41.478386,-81.664526,
  '67-18-317','Standard disclosure on file.',
  518000,'Auction','Demo record.'),
 ('aaaaaaa1-0000-0000-0000-000000000023','SDI-1023','sold','Memphis','TN','38111','Condo',1,1.0,813,1953,
  94500,9700,3300,2400,'7499 Winslow Dr',NULL,35.097168,-89.920347,
  '80-75-861','Standard disclosure on file.',
  79500,'Agent referral','Demo record.'),
 ('aaaaaaa1-0000-0000-0000-000000000024','SDI-1024','active','Columbus','OH','43206','Triplex',3,2.0,2171,2016,
  293500,37800,10300,0,'7221 Harlow Ln',NULL,39.978144,-82.988876,
  '64-88-958','Standard disclosure on file.',
  236000,'Agent referral','Demo record.');

INSERT INTO core.property_brand (property_id, brand_code, published, brand_price) VALUES
 ('aaaaaaa1-0000-0000-0000-000000000009','BRAND_A',true,NULL),
 ('aaaaaaa1-0000-0000-0000-000000000010','BRAND_A',false,NULL),
 ('aaaaaaa1-0000-0000-0000-000000000010','KAVADOO',false,520000),
 ('aaaaaaa1-0000-0000-0000-000000000011','BRAND_A',true,NULL),
 ('aaaaaaa1-0000-0000-0000-000000000011','KAVADOO',true,167000),
 ('aaaaaaa1-0000-0000-0000-000000000012','BRAND_A',true,NULL),
 ('aaaaaaa1-0000-0000-0000-000000000013','BRAND_A',true,NULL),
 ('aaaaaaa1-0000-0000-0000-000000000014','BRAND_A',true,NULL),
 ('aaaaaaa1-0000-0000-0000-000000000015','BRAND_A',true,NULL),
 ('aaaaaaa1-0000-0000-0000-000000000016','BRAND_A',true,NULL),
 ('aaaaaaa1-0000-0000-0000-000000000017','BRAND_A',false,NULL),
 ('aaaaaaa1-0000-0000-0000-000000000017','KAVADOO',false,137500),
 ('aaaaaaa1-0000-0000-0000-000000000018','BRAND_A',true,NULL),
 ('aaaaaaa1-0000-0000-0000-000000000019','BRAND_A',true,NULL),
 ('aaaaaaa1-0000-0000-0000-000000000020','BRAND_A',true,NULL),
 ('aaaaaaa1-0000-0000-0000-000000000021','BRAND_A',false,NULL),
 ('aaaaaaa1-0000-0000-0000-000000000022','BRAND_A',true,NULL),
 ('aaaaaaa1-0000-0000-0000-000000000023','BRAND_A',false,NULL),
 ('aaaaaaa1-0000-0000-0000-000000000024','BRAND_A',true,NULL),
 ('aaaaaaa1-0000-0000-0000-000000000024','KAVADOO',true,311000);

INSERT INTO core.property_assignment (property_id, person_id, assign_role) VALUES
 ('aaaaaaa1-0000-0000-0000-000000000009','44444444-4444-4444-4444-444444444444','agent'),
 ('aaaaaaa1-0000-0000-0000-000000000010','55555555-5555-5555-5555-555555555555','agent'),
 ('aaaaaaa1-0000-0000-0000-000000000011','44444444-4444-4444-4444-444444444444','agent'),
 ('aaaaaaa1-0000-0000-0000-000000000012','55555555-5555-5555-5555-555555555555','agent'),
 ('aaaaaaa1-0000-0000-0000-000000000013','44444444-4444-4444-4444-444444444444','agent'),
 ('aaaaaaa1-0000-0000-0000-000000000014','55555555-5555-5555-5555-555555555555','agent'),
 ('aaaaaaa1-0000-0000-0000-000000000015','44444444-4444-4444-4444-444444444444','agent'),
 ('aaaaaaa1-0000-0000-0000-000000000016','55555555-5555-5555-5555-555555555555','agent'),
 ('aaaaaaa1-0000-0000-0000-000000000017','44444444-4444-4444-4444-444444444444','agent'),
 ('aaaaaaa1-0000-0000-0000-000000000018','55555555-5555-5555-5555-555555555555','agent'),
 ('aaaaaaa1-0000-0000-0000-000000000019','44444444-4444-4444-4444-444444444444','agent'),
 ('aaaaaaa1-0000-0000-0000-000000000020','55555555-5555-5555-5555-555555555555','agent'),
 ('aaaaaaa1-0000-0000-0000-000000000021','44444444-4444-4444-4444-444444444444','agent'),
 ('aaaaaaa1-0000-0000-0000-000000000022','55555555-5555-5555-5555-555555555555','agent'),
 ('aaaaaaa1-0000-0000-0000-000000000023','44444444-4444-4444-4444-444444444444','agent'),
 ('aaaaaaa1-0000-0000-0000-000000000024','55555555-5555-5555-5555-555555555555','agent');

COMMIT;
