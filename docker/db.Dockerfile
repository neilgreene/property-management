# The database, with the schema baked in.
#
# Built rather than bind-mounted so the image is self-contained. A stack
# deployed from Git in Portainer CE has no access to the repository on the
# host: relative-path volumes are a Business Edition feature, so a bind mount
# of ./sql resolves to an empty directory and PostgreSQL initialises with no
# schema at all -- silently, because an empty init directory is legal.
#
# Build context is the repository root.
FROM postgres:16

# Order matters. PostgreSQL runs /docker-entrypoint-initdb.d/*.sql in
# alphabetical order, which is why these are numbered rather than named.
# The gaps (05, 07, 10, 14) are the test walkthroughs: they mutate data and
# must never run at initialisation.
COPY sql/01_schema.sql           /docker-entrypoint-initdb.d/01_schema.sql
COPY sql/02_policies.sql         /docker-entrypoint-initdb.d/02_policies.sql
COPY sql/03_views.sql            /docker-entrypoint-initdb.d/03_views.sql
COPY sql/04_seed.sql             /docker-entrypoint-initdb.d/04_seed.sql
COPY sql/06_ghl_integration.sql  /docker-entrypoint-initdb.d/06_ghl_integration.sql
COPY sql/08_review_queue.sql     /docker-entrypoint-initdb.d/08_review_queue.sql
COPY sql/09_review_actions.sql   /docker-entrypoint-initdb.d/09_review_actions.sql
COPY sql/11_pipeline.sql         /docker-entrypoint-initdb.d/11_pipeline.sql
COPY sql/12_pipeline_policies.sql /docker-entrypoint-initdb.d/12_pipeline_policies.sql
COPY sql/13_pipeline_seed.sql    /docker-entrypoint-initdb.d/13_pipeline_seed.sql
COPY sql/15_auth.sql             /docker-entrypoint-initdb.d/15_auth.sql

# Demo dataset and demo credentials. Both are demonstration data: every
# seeded person's password is `demo1234`, which is published in a public
# repository. Fine for a demo whose purpose is to be signed into; strip both
# for anything real.
COPY sql/16_demo_dataset.sql     /docker-entrypoint-initdb.d/16_demo_dataset.sql
COPY sql/17_demo_passwords.sql   /docker-entrypoint-initdb.d/17_demo_passwords.sql
COPY sql/18_property_detail.sql  /docker-entrypoint-initdb.d/18_property_detail.sql
COPY sql/19_saved_search.sql     /docker-entrypoint-initdb.d/19_saved_search.sql
COPY sql/20_demo_detail_seed.sql /docker-entrypoint-initdb.d/20_demo_detail_seed.sql
COPY sql/21_listing_sync.sql     /docker-entrypoint-initdb.d/21_listing_sync.sql
COPY sql/22_listing_sync_seed.sql /docker-entrypoint-initdb.d/22_listing_sync_seed.sql
COPY sql/24_data_governance.sql  /docker-entrypoint-initdb.d/24_data_governance.sql
COPY sql/25_governance_seed.sql  /docker-entrypoint-initdb.d/25_governance_seed.sql
COPY sql/26_fairgrove_media.sql  /docker-entrypoint-initdb.d/26_fairgrove_media.sql
COPY sql/28_intake.sql           /docker-entrypoint-initdb.d/28_intake.sql
COPY sql/30_stock_media.sql      /docker-entrypoint-initdb.d/30_stock_media.sql
COPY sql/31_media_store.sql      /docker-entrypoint-initdb.d/31_media_store.sql
COPY sql/32_media_api.sql        /docker-entrypoint-initdb.d/32_media_api.sql
COPY sql/33_interior_media.sql   /docker-entrypoint-initdb.d/33_interior_media.sql
COPY sql/34_property_card.sql    /docker-entrypoint-initdb.d/34_property_card.sql
COPY sql/35_map_disclosure.sql   /docker-entrypoint-initdb.d/35_map_disclosure.sql
COPY sql/36_media_masking.sql    /docker-entrypoint-initdb.d/36_media_masking.sql
COPY sql/37_metro.sql            /docker-entrypoint-initdb.d/37_metro.sql
COPY sql/38_mask_pool.sql        /docker-entrypoint-initdb.d/38_mask_pool.sql
COPY sql/39_underwriting.sql     /docker-entrypoint-initdb.d/39_underwriting.sql
COPY sql/40_property_admin.sql   /docker-entrypoint-initdb.d/40_property_admin.sql
COPY sql/41_property_manager.sql /docker-entrypoint-initdb.d/41_property_manager.sql
COPY sql/42_underwriting_seed.sql /docker-entrypoint-initdb.d/42_underwriting_seed.sql
COPY sql/43_property_notes.sql   /docker-entrypoint-initdb.d/43_property_notes.sql
COPY sql/44_profile.sql          /docker-entrypoint-initdb.d/44_profile.sql
COPY sql/45_note_summary.sql     /docker-entrypoint-initdb.d/45_note_summary.sql
COPY sql/46_note_severity.sql    /docker-entrypoint-initdb.d/46_note_severity.sql
COPY sql/47_share.sql            /docker-entrypoint-initdb.d/47_share.sql
COPY sql/48_mfa.sql              /docker-entrypoint-initdb.d/48_mfa.sql
COPY sql/49_projection.sql       /docker-entrypoint-initdb.d/49_projection.sql
COPY sql/50_search_criteria.sql  /docker-entrypoint-initdb.d/50_search_criteria.sql
COPY sql/51_customer_workflow.sql /docker-entrypoint-initdb.d/51_customer_workflow.sql
COPY sql/52_search_screening.sql /docker-entrypoint-initdb.d/52_search_screening.sql
COPY sql/53_workbook_extras.sql  /docker-entrypoint-initdb.d/53_workbook_extras.sql
COPY sql/54_manager_contact.sql  /docker-entrypoint-initdb.d/54_manager_contact.sql
COPY sql/55_contracts.sql        /docker-entrypoint-initdb.d/55_contracts.sql
COPY sql/56_contract_api.sql     /docker-entrypoint-initdb.d/56_contract_api.sql
COPY sql/57_contract_actions.sql /docker-entrypoint-initdb.d/57_contract_actions.sql
COPY sql/58_contract_seed.sql    /docker-entrypoint-initdb.d/58_contract_seed.sql

# Application roles take their credentials from the environment at first
# start, not from anything baked in. See the script for why a build-time flag
# cannot work for an image people pull by tag.
COPY docker/98_role_logins.sh    /docker-entrypoint-initdb.d/98_role_logins.sh

# sql/99_local_logins.sql is deliberately NOT copied. Its passwords are
# published in a public repository; it exists only for `./run.sh` on a laptop.

# The test-fixture role carries BYPASSRLS and is never baked in. It is applied
# by hand against a test database only. See worker/test/bootstrap.sql.
