#!/bin/bash
# Gives the application roles their credentials, from the environment.
#
# This replaces the build-time DEMO_LOGINS flag, which could not work for a
# published image: built without it, sdi_app stays NOLOGIN and the web tier
# cannot connect at all; built with it, every deployment in the world shares a
# password committed to a public repository. Neither is acceptable in something
# people pull by tag.
#
# So the image ships with no credentials and takes them at first start. Roles
# whose password is not supplied simply stay NOLOGIN, which fails loudly at
# connect time rather than quietly granting access.
#
# Runs as 98 so it lands after the schema (01) that creates the roles.
set -euo pipefail

DB="${POSTGRES_DB:-sdi}"

set_login() {
    local role="$1" pw="$2"
    if [ -z "$pw" ]; then
        echo "98_role_logins: no password for ${role}; leaving it NOLOGIN"
        return
    fi
    # Passed as a parameter, never interpolated into the SQL text, so a
    # password containing a quote cannot break out of the statement.
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$DB" \
         -v role="$role" -v pw="$pw" <<'SQL'
SELECT format('ALTER ROLE %I WITH LOGIN PASSWORD %L', :'role', :'pw')
\gexec
SQL
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$DB" \
         -c "GRANT CONNECT ON DATABASE \"${DB}\" TO \"${role}\""
    echo "98_role_logins: ${role} can now log in"
}

set_login sdi_app         "${SDI_APP_PASSWORD:-}"
set_login sdi_integration "${SDI_INTEGRATION_PASSWORD:-}"
