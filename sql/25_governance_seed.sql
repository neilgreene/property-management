-- =====================================================================
-- 25_governance_seed.sql  |  the register, as it actually stands today
-- =====================================================================
-- Read the status columns. Almost everything here is 'identified', which
-- means: somebody has worked out that this regime probably applies and
-- what it would constrain. It does not mean a lawyer has looked at it,
-- and several of these turn on facts about the business that only the
-- business can supply -- whether it holds a brokerage licence, whether
-- the platform fee is a referral fee, which MLS markets it has signed
-- with.
--
-- Three of these are load-bearing enough to name here rather than leave
-- buried in a table:
--
--   RESPA section 8. The business model is a $750 fee that unlocks
--   property information and connects investors to agents and lenders.
--   Whether that is a permitted fee for services actually rendered or an
--   unlawful referral fee is a question about the fee's substance, not
--   its label, and it is the single largest legal question in this
--   product. It needs counsel before launch, not after.
--
--   Real estate licensing. Whether operating this marketplace is
--   brokerage activity is state by state and turns on what the platform
--   does beyond publishing -- negotiating, holding funds, being
--   compensated for bringing parties together.
--
--   Fair housing. Not a launch question but a design one, and the design
--   decisions are already being made. See gov.prohibited_dimension.

BEGIN;

-- ---------------------------------------------------------------------
-- Territories. Only what the portfolio actually touches.
-- ---------------------------------------------------------------------
INSERT INTO gov.territory (territory_id, kind, name, country, state, parent_id, notes) VALUES
 ('US','country','United States','US',NULL,NULL,NULL),
 ('US-AL','state','Alabama','US','AL','US',NULL),
 ('US-CA','state','California','US','CA','US','CCPA/CPRA applies to consumers resident here'),
 ('US-FL','state','Florida','US','FL','US',NULL),
 ('US-IN','state','Indiana','US','IN','US',NULL),
 ('US-MO','state','Missouri','US','MO','US',NULL),
 ('US-OH','state','Ohio','US','OH','US',NULL),
 ('US-TN','state','Tennessee','US','TN','US',NULL),
 -- A market-level territory, to show the shape a real MLS footprint takes.
 -- Placeholder name: the actual MLS and its member towns come from the
 -- participation agreement, not from here.
 ('MLS-NEOH','mls_market','Northeast Ohio MLS (placeholder)','US','OH','US-OH',
  'Illustrative. Replace with the real MLS identifier and its actual footprint '
  'when a participation agreement exists.')
ON CONFLICT (territory_id) DO NOTHING;

INSERT INTO gov.territory_place (territory_id, city, state) VALUES
 ('MLS-NEOH','Cleveland','OH'),
 ('MLS-NEOH','Toledo','OH')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------
-- Rights held today. There are two, and one of them is 'none'.
-- ---------------------------------------------------------------------
INSERT INTO gov.data_right
 (right_id, name, grantor, instrument, source_code, reference,
  effective_from, effective_to, survives_termination,
  review_status, reviewed_by, reviewed_on, notes) VALUES

 ('DEMO-SYNTH','Synthetic demonstration data','SDI (authored in-house)','owner_consent',
  NULL,'sql/04_seed.sql, sql/16_demo_dataset.sql, sql/20_demo_detail_seed.sql',
  NULL, NULL, true,
  'counsel_confirmed','n/a — data authored in-house', current_date,
  'The 24 demo listings, their financials, market figures and illustrations are '
  'invented. Nobody else has a claim in them, which is why this is the one right '
  'in the register that needs no external instrument. It covers the demo and '
  'nothing else: the moment a real listing arrives it needs a real right.'),

 ('NONE-EXTERNAL','No instrument — externally sourced, tracked only','n/a','none',
  'PORTAL_SCRAPE','—',
  NULL, NULL, false,
  'unreviewed', NULL, NULL,
  'Records the honest position for a property identified from a public listing '
  'page with no agreement behind it: we know the address exists, we hold nothing '
  'we may publish. NO use is granted below, which is what keeps the property '
  'unpublishable rather than relying on somebody remembering.')
ON CONFLICT (right_id) DO NOTHING;

INSERT INTO gov.data_right_territory (right_id, territory_id) VALUES
 ('DEMO-SYNTH','US'),
 ('NONE-EXTERNAL','US')
ON CONFLICT DO NOTHING;

-- The synthetic data may be used freely except for the two things that
-- would be misleading rather than unlawful.
INSERT INTO gov.data_right_use (right_id, use_code, posture, condition) VALUES
 ('DEMO-SYNTH','internal_analysis','granted',NULL),
 ('DEMO-SYNTH','gated_display','granted',NULL),
 ('DEMO-SYNTH','public_display','granted','Must remain identifiable as demonstration data'),
 ('DEMO-SYNTH','derive','granted',NULL),
 ('DEMO-SYNTH','export','granted','Marked as synthetic'),
 ('DEMO-SYNTH','redistribute','refused','Synthetic data passed onward stops looking synthetic'),
 ('DEMO-SYNTH','marketing','refused','Advertising invented properties is a different problem entirely'),
 ('DEMO-SYNTH','model_training','granted','Synthetic; no third-party interest'),

 -- Every use explicitly refused rather than merely absent. A blank row
 -- and a refusal read the same to gov.may_use(), but only one of them
 -- reads the same to a person.
 ('NONE-EXTERNAL','internal_analysis','unclear','Tracking a public address for status is not obviously a licensed use, but it is the weakest one'),
 ('NONE-EXTERNAL','gated_display','refused',NULL),
 ('NONE-EXTERNAL','public_display','refused',NULL),
 ('NONE-EXTERNAL','derive','refused',NULL),
 ('NONE-EXTERNAL','redistribute','refused',NULL),
 ('NONE-EXTERNAL','export','refused',NULL),
 ('NONE-EXTERNAL','marketing','refused',NULL),
 ('NONE-EXTERNAL','model_training','refused',NULL)
ON CONFLICT DO NOTHING;

INSERT INTO gov.obligation (right_id, kind, interval_hours, text_required, detail, enforcement) VALUES
 ('DEMO-SYNTH','display_restriction',NULL,NULL,
  'Demonstration listings must be visibly identifiable as such wherever they are shown.',
  'procedural'),
 ('NONE-EXTERNAL','deletion_on_termination',NULL,NULL,
  'Nothing beyond the address and the source key may be retained, and no part of it may be displayed.',
  'automatic');

-- ---------------------------------------------------------------------
-- Provenance for everything currently in the database
-- ---------------------------------------------------------------------
INSERT INTO gov.property_provenance (property_id, right_id, scope)
SELECT property_id, 'DEMO-SYNTH', s.scope
FROM core.property, unnest(ARRAY['listing_facts','media','valuation','market_data']) AS s(scope)
WHERE listing_ref <> 'SDI-2001'
ON CONFLICT DO NOTHING;

INSERT INTO gov.property_provenance (property_id, right_id, scope)
SELECT property_id, 'NONE-EXTERNAL', s.scope
FROM core.property, unnest(ARRAY['listing_facts','media','valuation']) AS s(scope)
WHERE listing_ref = 'SDI-2001'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------
-- The regulation register
-- ---------------------------------------------------------------------
INSERT INTO gov.regulation
 (reg_code, name, citation, regime, applies_when, constrains, our_posture, status) VALUES

 ('FHA','Fair Housing Act','42 U.S.C. 3601-3631; 24 CFR Part 100','fair_housing',
  'Always. Any dwelling advertised, sold or rented in the US.',
  'Advertising, filtering, ranking and recommendation may not discriminate or steer '
  'on race, colour, religion, national origin, sex (incl. gender identity and sexual '
  'orientation per HUD guidance), familial status or disability. Intent is not required.',
  'No protected characteristic or identified proxy is available as a filter, sort or '
  'audience dimension. The prohibited list is a table, checked by a standing invariant '
  'and asserted by the web tier at startup, so a future feature cannot add one quietly.',
  'identified'),

 ('FHA-STATE','State and local fair housing statutes','Varies by state and municipality','fair_housing',
  'Per jurisdiction in gov.territory. Several add source of income, age, marital status.',
  'As FHA, over a wider set of protected characteristics.',
  'The prohibited-dimension table carries the union, not the federal minimum.',
  'identified'),

 ('RESPA-8','RESPA section 8 — referral fees','12 U.S.C. 2607; 12 CFR 1024.14','lending',
  'If the platform is compensated in connection with a federally related mortgage loan, '
  'including by referring business to agents, lenders or settlement providers.',
  'Prohibits giving or accepting a fee for the referral of settlement service business. '
  'Payments for services actually performed, at reasonable value, are permitted.',
  'UNRESOLVED AND MATERIAL. The $750 platform fee unlocks property information and '
  'connects investors to agents and lenders. Whether that is compensation for services '
  'rendered or a referral fee turns on substance, not labelling. Needs counsel before '
  'launch.',
  'identified'),

 ('ECOA','Equal Credit Opportunity Act / Regulation B','15 U.S.C. 1691; 12 CFR Part 1002','lending',
  'If the platform takes credit applications, refers to credit, or influences who is offered credit.',
  'Prohibits discrimination in any aspect of a credit transaction; adverse action notices.',
  'Not currently applicable: no credit application is taken. Becomes applicable the day '
  'lender matching is built, which is on the roadmap.',
  'deferred'),

 ('MLS-IDX','MLS participation, IDX and VOW rules','Contractual; per-MLS rules, NAR policy','data_licensing',
  'From the moment any MLS feed is connected. Currently none is.',
  'Attribution to the listing broker, refresh cadence, removal of delisted properties '
  'within a stated period, no commingling with other sources, restrictions on what may '
  'be shown publicly versus to a registered user.',
  'The machinery exists and is unused: gov.obligation records attribution text, refresh '
  'interval and removal SLA per right; gov.removal_due computes the deadline and '
  'gov.enforce_removals() unpublishes past it. The clauses themselves come from the '
  'agreement when there is one.',
  'deferred'),

 ('COPYRIGHT','Copyright in listing photographs and descriptions','17 U.S.C. 106','intellectual_property',
  'Always, for any media or text not authored in-house.',
  'Reproduction and display of photographs and listing copy require a licence from the '
  'rights holder, usually the photographer or the listing broker rather than the seller.',
  'All current imagery is generated in-house. Media provenance is tracked separately from '
  'listing facts (gov.property_provenance.scope) precisely because photographs are '
  'routinely licensed more narrowly than the data.',
  'identified'),

 ('DMCA','DMCA safe harbour and takedown','17 U.S.C. 512','intellectual_property',
  'If third parties can upload content.',
  'Registered agent, notice-and-takedown, repeat infringer policy.',
  'Not applicable: no third-party upload exists. Becomes applicable with seller or agent '
  'photo upload.',
  'deferred'),

 ('SCRAPE-TOS','Site terms of service and unauthorised access','18 U.S.C. 1030; contract','data_licensing',
  'If any consumer portal is read programmatically.',
  'Portal terms prohibit automated collection. Scope of the CFAA over terms-of-service '
  'breaches is narrow after Van Buren but the contractual exposure is not.',
  'No scraper is implemented. The source is registered, advisory, barred from retiring a '
  'listing, and returns "not implemented" -- see section 8 of the system documentation '
  'for why the engineering argument against it is stronger than the legal one.',
  'identified'),

 ('CCPA','California Consumer Privacy Act, as amended by CPRA','Cal. Civ. Code 1798.100 et seq.','privacy',
  'Once thresholds are met and any consumer is a California resident. The portfolio '
  'already includes a California property and will attract California investors.',
  'Notice at collection, right to know, delete, correct and opt out of sale or sharing; '
  'contractual terms with service providers; limits on sensitive personal information.',
  'Investor PII is minimal (name, email, phone) and is shared with GoHighLevel, which '
  'makes GHL a service provider requiring the contractual terms. No deletion or export '
  'mechanism is built. This is a gap.',
  'identified'),

 ('STATE-PRIVACY','State comprehensive privacy statutes','VCDPA, CPA, CTDPA, UCPA, TDPSA and others','privacy',
  'Per consumer residency and per-statute thresholds.',
  'Broadly similar to CCPA: access, deletion, correction, opt-out of targeted advertising.',
  'Same gap as CCPA. Building one subject-request mechanism satisfies most of them.',
  'identified'),

 ('GDPR','General Data Protection Regulation','Regulation (EU) 2016/679','privacy',
  'Only if personal data of people in the EU or UK is processed.',
  'Lawful basis, data subject rights, transfer mechanism, DPA with processors.',
  'Not applicable today: no EU marketing, no EU investors. Becomes applicable on the '
  'first EU investor, so it is registered rather than omitted.',
  'not_applicable'),

 ('GLBA','Gramm-Leach-Bliley Act and the Safeguards Rule','15 U.S.C. 6801-6809; 16 CFR Part 314','privacy',
  'If the business is a "financial institution" -- which reaches further than banks and '
  'can include parties significantly engaged in financial activities.',
  'Privacy notice, limits on sharing non-public personal information, and a written '
  'information security programme.',
  'Turns on the same facts as RESPA. Both should go to counsel together.',
  'identified'),

 ('CAN-SPAM','CAN-SPAM Act','15 U.S.C. 7701-7713; 16 CFR Part 316','marketing',
  'Any commercial email. GoHighLevel is the sending platform.',
  'Accurate headers and subject lines, physical postal address, working opt-out honoured '
  'within 10 business days.',
  'Delegated to GoHighLevel, which provides the mechanics. Suppression state lives in GHL '
  'and is not currently mirrored here, so this system cannot independently prove an '
  'opt-out was honoured.',
  'identified'),

 ('TCPA','Telephone Consumer Protection Act','47 U.S.C. 227; 47 CFR 64.1200','marketing',
  'Any SMS or call to a mobile number, including via GoHighLevel.',
  'Prior express written consent for marketing texts and autodialled calls; per-violation '
  'statutory damages; consent must be provable.',
  'The highest-frequency legal risk in the whole product, because it is the one a routine '
  'marketing decision can breach. Consent capture and its evidence are not modelled here '
  'at all. This is a gap.',
  'identified'),

 ('RE-LICENSE','State real estate licensing and advertising rules','e.g. Ohio R.C. 4735; Cal. B&P 10130','licensing_conduct',
  'Per state where property is marketed or brokerage activity occurs.',
  'Whether the platform''s activity constitutes brokerage; advertising must identify the '
  'licensed broker; unlicensed practice carries penalties.',
  'Unresolved, and state by state. The dual-brand structure and the fee model both bear on '
  'it. Needs counsel alongside RESPA.',
  'identified'),

 ('PCI','PCI DSS','PCI DSS v4.0','payments',
  'Any handling of cardholder data. The platform fee is a card payment.',
  'Scope depends entirely on integration style: a fully redirected or iframed processor '
  'keeps the site out of scope for almost everything.',
  'No payment integration is built. When it is, use a redirect or hosted-fields '
  'integration so no card data touches this system.',
  'deferred'),

 ('ADA','ADA Title III / web accessibility','42 U.S.C. 12181; WCAG 2.1 AA as the practical standard','licensing_conduct',
  'Public-facing web content.',
  'Accessible to users with disabilities. Litigation risk is real regardless of how the '
  'legal question is ultimately settled.',
  'Not assessed. The marketplace uses semantic markup and labelled controls but has not '
  'been audited, and the map has no non-visual equivalent.',
  'identified')
ON CONFLICT (reg_code) DO NOTHING;

-- ---------------------------------------------------------------------
-- Where each one is actually enforced. 'absent' is used deliberately and
-- often: a register that claims a control for everything is a register
-- that is lying.
-- ---------------------------------------------------------------------
INSERT INTO gov.regulation_control (reg_code, control, located_in, kind) VALUES
 ('FHA','Protected characteristics and proxies cannot become filters','gov.prohibited_dimension','technical'),
 ('FHA','Standing invariant fails if a prohibited dimension is exposed or filterable','api.security_invariants()','technical'),
 ('FHA','The web tier refuses to start if its filter allowlist intersects the register','web/server.js','technical'),
 ('FHA','No demographic data is stored against a person or a property','core schema','technical'),
 ('FHA-STATE','The prohibited list carries the union of state additions','gov.prohibited_dimension','technical'),

 ('RESPA-8','None','—','absent'),
 ('ECOA','None — no credit function exists yet','—','absent'),

 ('MLS-IDX','Publication requires a confirmed right permitting public display','gov.assert_publishable() trigger','technical'),
 ('MLS-IDX','Removal deadlines computed from the obligation and enforced','gov.removal_due, gov.enforce_removals()','technical'),
 ('MLS-IDX','Attribution text stored per right','gov.obligation','technical'),

 ('COPYRIGHT','Media provenance tracked separately from listing facts','gov.property_provenance.scope','technical'),
 ('COPYRIGHT','All current imagery generated in-house','web/media.js','technical'),
 ('DMCA','None — no third-party upload','—','absent'),

 ('SCRAPE-TOS','Scraper unimplemented; source is advisory and cannot retire a listing','feed.listing_source, worker/src/listings/adapters.js','technical'),

 ('CCPA','None — no subject-request mechanism','—','absent'),
 ('STATE-PRIVACY','None — no subject-request mechanism','—','absent'),
 ('GDPR','Not applicable; registered so the trigger condition is visible','gov.regulation.applies_when','procedural'),
 ('GLBA','None','—','absent'),

 ('CAN-SPAM','Delegated to GoHighLevel','GHL platform','contractual'),
 ('CAN-SPAM','Suppression state not mirrored locally','—','absent'),
 ('TCPA','None — consent is not captured or evidenced in this system','—','absent'),

 ('RE-LICENSE','None','—','absent'),
 ('PCI','No payment integration exists, so no cardholder data is handled','—','procedural'),
 ('ADA','Semantic markup and labelled controls, unaudited','web/public/','procedural'),
 ('ADA','Map has no non-visual equivalent','—','absent')
ON CONFLICT DO NOTHING;

COMMIT;
