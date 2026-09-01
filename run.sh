#!/usr/bin/env bash
# Local run without Docker. Requires PostgreSQL 16+ and Node 18+.
set -euo pipefail
DB=${DB:-sdi}
createdb "$DB" 2>/dev/null || true
for f in sql/01_schema.sql sql/02_policies.sql sql/03_views.sql \
         sql/04_seed.sql sql/06_ghl_integration.sql \
         sql/08_review_queue.sql sql/09_review_actions.sql \
         sql/11_pipeline.sql sql/12_pipeline_policies.sql sql/13_pipeline_seed.sql \
         sql/15_auth.sql; do
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
