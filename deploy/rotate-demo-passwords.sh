#!/usr/bin/env bash
# =====================================================================
# rotate-demo-passwords.sh  |  run this BEFORE the thing has an address
# =====================================================================
# The published db image seeds every demo person with the password
# `demo1234`. That is deliberate and correct for a demo on a laptop, and
# catastrophic on a public address: the seeded accounts include admins,
# and admins see every street address, every offer and every margin.
#
# This gives each account a fresh random password and prints them once.
# Nothing stores them -- copy them somewhere before you close the window.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "Rotating every seeded login. These are printed ONCE."
echo

docker compose exec -T db psql -U postgres -d sdi -tAc \
  "SELECT person_id || ' ' || email FROM core.person WHERE active ORDER BY email" |
while read -r id email; do
  [ -z "$id" ] && continue
  pw="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-16)"
  # Hashed by the application, never by the database: the plaintext must
  # not reach a query log, a plan, or an error message.
  hash="$(docker compose exec -T web node -e "
    require('/app/auth').hashPassword(process.argv[1]).then((h) => process.stdout.write(h));
  " "$pw")"
  docker compose exec -T db psql -U postgres -d sdi -qtAc \
    "SELECT api.set_password('$id'::uuid, '$hash')" > /dev/null
  printf '%-34s %s\n' "$email" "$pw"
done

echo
echo "Every previous session was revoked -- api.set_password does that,"
echo "so anyone signed in with the old password is now signed out."
