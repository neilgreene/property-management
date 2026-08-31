#!/usr/bin/env bash
# Local run without Docker. Requires PostgreSQL 16+ and Node 18+.
set -euo pipefail
DB=${DB:-sdi}
createdb "$DB" 2>/dev/null || true
for f in sql/01_schema.sql sql/02_policies.sql sql/03_views.sql sql/04_seed.sql; do
  echo "loading $f"; psql -d "$DB" -v ON_ERROR_STOP=1 -q -f "$f"
done
psql -d "$DB" -q -c "ALTER ROLE sdi_app WITH LOGIN PASSWORD 'demo_app_pw';" \
                -c "GRANT CONNECT ON DATABASE $DB TO sdi_app;"
echo; echo "--- security walkthrough ---"
psql -d "$DB" -f sql/05_tests.sql
echo; echo "--- starting web demo on http://localhost:3000 ---"
cd web && npm install --silent && PGDATABASE="$DB" node server.js
