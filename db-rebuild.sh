#!/usr/bin/env bash
# Rebuilds the development database from scratch, in the right order.
#
# This exists because the order is easy to get wrong by hand, and one step
# in particular is easy to forget: worker/test/bootstrap.sql grants a
# SNAPSHOT, not a standing rule, so a rebuild that skips it leaves the test
# fixture role with no access to anything -- which surfaces as a dozen
# confusing "permission denied for schema api" failures rather than as an
# obvious missing step. That has cost time three separate times.
#
#   ./db-rebuild.sh          # rebuild 'sdi'
#   DB=scratch ./db-rebuild.sh
set -euo pipefail
DB="${DB:-sdi}"
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

echo "==> recreating $DB"
dropdb --if-exists "$DB"
createdb "$DB"

# Schema, then data, then demo credentials. The gaps in the numbering are
# the test walkthroughs, which mutate and must not run at build time.
for f in 01_schema 02_policies 03_views 04_seed \
         06_ghl_integration 08_review_queue 09_review_actions \
         11_pipeline 12_pipeline_policies 13_pipeline_seed \
         15_auth 16_demo_dataset 17_demo_passwords \
         18_property_detail 19_saved_search 20_demo_detail_seed \
         21_listing_sync 22_listing_sync_seed \
         24_data_governance 25_governance_seed 26_fairgrove_media \
         28_intake 30_stock_media 31_media_store 32_media_api 33_interior_media \
         34_property_card 35_map_disclosure 36_media_masking 37_metro 38_mask_pool \
         39_underwriting 40_property_admin 41_property_manager 42_underwriting_seed \
         43_property_notes 44_profile 45_note_summary 46_note_severity \
         47_share 48_mfa 49_projection 50_search_criteria \
         99_local_logins; do
    printf '    %s\n' "$f"
    psql -d "$DB" -q -v ON_ERROR_STOP=1 -f "sql/$f.sql"
done

echo "==> test fixture role"
psql -d "$DB" -q -v ON_ERROR_STOP=1 -f worker/test/bootstrap.sql
psql -d "$DB" -q -c "GRANT CONNECT ON DATABASE \"$DB\" TO sdi_test_admin;"

echo "==> ready"
psql -d "$DB" -tAc "SELECT count(*) || ' properties, ' ||
                           (SELECT count(*) FROM core.person) || ' people, ' ||
                           (SELECT count(*) FROM core.credential) || ' with passwords'
                    FROM core.property" | sed 's/^/    /'
