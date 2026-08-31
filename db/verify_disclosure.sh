#!/usr/bin/env bash
# Asserts that restricted property data cannot be reached by the public role.
# Exits non-zero on any failure. Run after ./db/apply.sh.
set -uo pipefail
DB="${1:-pmp}"
FAIL=0

pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1"; FAIL=1; }

su postgres -c "psql -q -v ON_ERROR_STOP=1 -d '$DB'" <<'SQL' >/dev/null 2>&1
INSERT INTO property (headline, display_region, status, public_visible,
                      asking_price_minor, street_address, postal_code)
VALUES ('fixture listing', 'Cleveland, OH', 'active', true,
        18500000, '1247 W 58th St', '44102')
ON CONFLICT DO NOTHING;
INSERT INTO party (role, full_name, email, entitlement)
VALUES ('investor', 'Entitled', 'fixture-yes@example.com', 'granted'),
       ('investor', 'Visitor',  'fixture-no@example.com',  'none')
ON CONFLICT DO NOTHING;
DROP ROLE IF EXISTS test_public;
CREATE ROLE test_public LOGIN PASSWORD 'x' IN ROLE pmp_public;
SQL

echo "disclosure control:"

# 1. public role must not read the base table
if PGPASSWORD=x psql -h 127.0.0.1 -U test_public -d "$DB" \
     -c "select street_address from property;" >/dev/null 2>&1; then
    fail "public role CAN read property.street_address"
else
    pass "public role denied on base table"
fi

# 2. public role must be able to read the view
if PGPASSWORD=x psql -h 127.0.0.1 -U test_public -d "$DB" \
     -tAc "select headline from property_public;" 2>/dev/null | grep -q .; then
    pass "public role can read property_public"
else
    fail "public role cannot read property_public"
fi

# 3. the view must not expose restricted columns
if PGPASSWORD=x psql -h 127.0.0.1 -U test_public -d "$DB" \
     -c "select street_address from property_public;" >/dev/null 2>&1; then
    fail "property_public EXPOSES street_address"
else
    pass "property_public has no street_address column"
fi

# 4. entitled party gets restricted detail
N=$(su postgres -c "psql -tA -d '$DB' -c \"select count(*) from property_detail_for(
      (select id from party where email='fixture-yes@example.com'),
      (select id from property where headline='fixture listing'))\"" 2>/dev/null)
[ "$N" = "1" ] && pass "entitled party receives restricted detail" \
                || fail "entitled party got $N rows, expected 1"

# 5. non-entitled party gets nothing
N=$(su postgres -c "psql -tA -d '$DB' -c \"select count(*) from property_detail_for(
      (select id from party where email='fixture-no@example.com'),
      (select id from property where headline='fixture listing'))\"" 2>/dev/null)
[ "$N" = "0" ] && pass "non-entitled party receives nothing" \
                || fail "non-entitled party got $N rows, expected 0"

echo
[ $FAIL -eq 0 ] && echo "all checks passed" || echo "FAILURES PRESENT"
exit $FAIL
