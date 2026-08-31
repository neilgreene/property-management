-- 13_pipeline_seed.sql | demo pipeline, stages and deals
BEGIN;

INSERT INTO core.pipeline (pipeline_code, display_name, brand_code) VALUES
  ('ACQUISITION', 'Investor Acquisition', 'BRAND_A'),
  ('COINVEST',    'Co-Investment Match',  'BRAND_A');

INSERT INTO core.pipeline_stage
  (pipeline_code, stage_code, display_name, position, is_won, is_lost) VALUES
  ('ACQUISITION','INQUIRY',      'Inquiry',            1, false, false),
  ('ACQUISITION','VETTED',       'Investor Vetted',    2, false, false),
  ('ACQUISITION','OFFER',        'Pre-Offer Submitted',3, false, false),
  ('ACQUISITION','CONTRACT',     'Under Contract',     4, false, false),
  ('ACQUISITION','CLOSED_WON',   'Closed',             5, true,  false),
  ('ACQUISITION','CLOSED_LOST',  'Lost',               6, false, true ),
  ('COINVEST',   'WAITLIST',     'Waitlist',           1, false, false),
  ('COINVEST',   'FUNDS_VETTED', 'Proof of Funds Vetted',2,false,false),
  ('COINVEST',   'MATCHED',      'Matched',            3, true,  false),
  ('COINVEST',   'WITHDRAWN',    'Withdrawn',          4, false, true );

-- Ruth (agreement signed) is progressing on 1041 with Tom as agent.
INSERT INTO core.deal (deal_id, external_ref, property_id, investor_id, agent_id,
                       pipeline_code, stage_code, amount, opened_at)
VALUES
  ('dddddddd-0000-0000-0000-000000000001','ESPO-D-1',
   'aaaaaaa1-0000-0000-0000-000000000001',
   '11111111-1111-1111-1111-111111111111',
   '44444444-4444-4444-4444-444444444444',
   'ACQUISITION','INQUIRY', 228000, now() - interval '21 days'),

-- Marcus, unsigned, on a different property with Priya.
  ('dddddddd-0000-0000-0000-000000000002','ESPO-D-2',
   'aaaaaaa1-0000-0000-0000-000000000002',
   '22222222-2222-2222-2222-222222222222',
   '55555555-5555-5555-5555-555555555555',
   'ACQUISITION','INQUIRY', 184000, now() - interval '9 days'),

-- Ines on the KAVADOO side.
  ('dddddddd-0000-0000-0000-000000000003','ESPO-D-3',
   'aaaaaaa1-0000-0000-0000-000000000004',
   '33333333-3333-3333-3333-333333333333',
   '44444444-4444-4444-4444-444444444444',
   'COINVEST','WAITLIST', 329000, now() - interval '4 days');

-- Walk Ruth's deal forward so there is real history to read. Each UPDATE
-- fires the trigger; nothing here writes deal_stage_history directly.
UPDATE core.deal SET stage_code='VETTED'   WHERE external_ref='ESPO-D-1';
UPDATE core.deal SET stage_code='OFFER'    WHERE external_ref='ESPO-D-1';
UPDATE core.deal SET stage_code='CONTRACT' WHERE external_ref='ESPO-D-1';

COMMIT;
