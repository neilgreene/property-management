#!/usr/bin/env bash
# Local run without Docker. Requires PostgreSQL 16+ and Node 18+.
set -euo pipefail
DB=${DB:-sdi}
createdb "$DB" 2>/dev/null || true
for f in sql/01_schema.sql sql/02_policies.sql sql/03_views.sql \
         sql/04_seed.sql sql/06_ghl_integration.sql \
         sql/08_review_queue.sql sql/09_review_actions.sql \
         sql/11_pipeline.sql sql/12_pipeline_policies.sql sql/13_pipeline_seed.sql \
         sql/15_auth.sql sql/16_demo_dataset.sql sql/17_demo_passwords.sql \
         sql/18_property_detail.sql sql/19_saved_search.sql \
         sql/20_demo_detail_seed.sql sql/21_listing_sync.sql \
         sql/22_listing_sync_seed.sql sql/24_data_governance.sql \
         sql/25_governance_seed.sql sql/26_fairgrove_media.sql \
         sql/28_intake.sql sql/30_stock_media.sql \
         sql/31_media_store.sql sql/32_media_api.sql sql/33_interior_media.sql \
         sql/34_property_card.sql sql/35_map_disclosure.sql \
         sql/36_media_masking.sql sql/37_metro.sql sql/38_mask_pool.sql \
         sql/39_underwriting.sql sql/40_property_admin.sql \
         sql/41_property_manager.sql sql/42_underwriting_seed.sql \
         sql/43_property_notes.sql sql/44_profile.sql sql/45_note_summary.sql \
         sql/46_note_severity.sql sql/47_share.sql sql/48_mfa.sql sql/49_projection.sql sql/50_search_criteria.sql sql/51_customer_workflow.sql sql/52_search_screening.sql sql/53_workbook_extras.sql sql/54_manager_contact.sql \
         sql/55_contracts.sql sql/56_contract_api.sql sql/57_contract_actions.sql \
         sql/58_contract_seed.sql sql/60_my_properties.sql sql/61_agent_views.sql; do
  echo "loading $f"; psql -d "$DB" -v ON_ERROR_STOP=1 -q -f "$f"
done
# Demo logins for both roles. Same file docker-compose loads, so the two
# paths cannot drift apart. See its header: local development only.
psql -d "$DB" -q -v ON_ERROR_STOP=1 -f sql/99_local_logins.sql
echo; echo "--- security walkthrough ---"
psql -d "$DB" -f sql/05_tests.sql
echo; echo "--- GHL bridge checks ---"
psql -d "$DB" -f sql/07_ghl_tests.sql
echo; echo "--- review action checks ---"
psql -d "$DB" -f sql/10_review_tests.sql
echo; echo "--- pipeline checks ---"
psql -d "$DB" -f sql/14_pipeline_tests.sql
psql -d "$DB" -f sql/23_listing_sync_tests.sql
psql -d "$DB" -f sql/27_governance_tests.sql
psql -d "$DB" -f sql/29_intake_tests.sql
psql -d "$DB" -f sql/59_contract_tests.sql
# --- GHL integration worker -------------------------------------------
# Test-only fixture role; see worker/test/bootstrap.sql for why it exists.
psql -d "$DB" -q -f worker/test/bootstrap.sql
psql -d "$DB" -q -c "GRANT CONNECT ON DATABASE $DB TO sdi_test_admin;"
echo; echo "--- web tests ---"
(cd web && npm install --silent && PGDATABASE="$DB" npm test)
echo; echo "--- worker tests ---"
(cd worker && npm install --silent && PGDATABASE="$DB" npm test)

echo; echo "--- starting web demo on http://localhost:3000 ---"
cd web && npm install --silent && PGDATABASE="$DB" node server.js
