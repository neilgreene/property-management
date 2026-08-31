#!/usr/bin/env bash
# Applies all migrations to a local database, in order.
#   ./db/apply.sh [dbname]      (default: pmp)
# Drops and recreates the database: local development only.
set -euo pipefail
DB="${1:-pmp}"
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "==> recreating database '$DB'"
su postgres -c "dropdb --if-exists '$DB'"
su postgres -c "createdb '$DB'"

for f in "$HERE"/migrations/*.sql; do
    echo "==> $(basename "$f")"
    su postgres -c "psql -q -v ON_ERROR_STOP=1 -d '$DB' -f '$f'"
done
echo "==> done"
