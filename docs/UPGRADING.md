# Upgrading a running deployment

## The thing that catches everyone

The database image bakes the SQL into `/docker-entrypoint-initdb.d/`, and
PostgreSQL runs that directory **only when the data volume is empty**. Pulling
a newer `db` image onto an existing `db-data` volume gives you the new image
and the old schema — no error, no warning, just a marketplace missing every
table added since the volume was created.

So there are two upgrade paths, and which one you want depends entirely on
whether the data in that volume matters.

---

## Before you run anything: role passwords are set once

`98_role_logins.sh` gives the application roles their passwords **at first
start only**, from the environment. A role with no password supplied stays
`NOLOGIN` — which fails loudly at connect time rather than quietly granting
access, but also means you cannot add it later without re-initialising.

If the first deploy's log said:

```
98_role_logins: no password for sdi_integration; leaving it NOLOGIN
```

…then the worker cannot connect, and **workbook loading will not work**. Since
the upgrade below destroys the volume anyway, this is the moment to fix it: set
`SDI_INTEGRATION_PASSWORD` in the environment *before* `up -d`.

```bash
# in /opt/sdi/.env, alongside POSTGRES_PASSWORD and SDI_APP_PASSWORD
SDI_INTEGRATION_PASSWORD=<pick something>
```

## Path A — demo data, nothing to keep (what you want today)

Everything in the deployment is seeded. Destroy the volume and let it
re-initialise.

```bash
cd /srv/sdi                       # wherever the compose file lives
docker compose -f docker-compose.release.yml pull
docker compose -f docker-compose.release.yml down -v      # -v drops db-data
docker compose -f docker-compose.release.yml up -d
docker compose -f docker-compose.release.yml logs -f db   # watch it re-seed
```

`down -v` **deletes the database volume.** That is the point here, and it is
the wrong command the moment there is anything real in it.

Healthy startup ends with the role-login script and the seed counts. Then:

```bash
curl -s localhost:3000/api/listings | head -c 300
```

## Path B — there is data worth keeping

Apply the new files by hand, in order, against the running database. They are
written to be run once and are not idempotent, so run only the ones added
since your volume was built:

```bash
docker compose -f docker-compose.release.yml exec -T db \
  psql -U postgres -d sdi -v ON_ERROR_STOP=1 < sql/18_property_detail.sql
# ...and so on for 19, 20, 21, 22, 24, 25, 26
```

Check what is already there before you start:

```bash
docker compose -f docker-compose.release.yml exec db \
  psql -U postgres -d sdi -c "\dn"     # which schemas exist: core, ghl, feed, gov
```

`feed` present means 21–22 are applied. `gov` present means 24–26 are.

---

## Verifying the upgrade

```bash
# the marketplace answers, with the new fields
curl -s 'localhost:3000/api/listings?min_beds=3&max_price=300000' | head -c 400

# the fair-housing assertion ran at startup
docker compose -f docker-compose.release.yml logs web | grep fair-housing

# governance and the standing invariants
docker compose -f docker-compose.release.yml exec db psql -U postgres -d sdi \
  -c "SELECT * FROM api.governance_status" \
  -c "SELECT * FROM api.security_invariants()"
```

`api.security_invariants()` returning **zero rows** is the pass.

## Adding the worker service

A compose file with only `db` and `web` runs the marketplace and the intake
review screen, but has nowhere to run the nightly listing sweep or the workbook
loader. Paste this into your compose file alongside the other services:

```yaml
  worker:
    image: ghcr.io/neilgreene/property-management/worker:latest
    depends_on:
      db:
        condition: service_healthy
    environment:
      PGHOST: db
      PGDATABASE: ${POSTGRES_DB:-sdi}
      PGUSER: sdi_integration
      PGPASSWORD: ${SDI_INTEGRATION_PASSWORD}
      PORT: "3001"
    volumes:
      # So the loader can reach a batch.json written on the host.
      - ./intake:/intake
    restart: unless-stopped
```

`docker-compose.release.yml` in the repository already has it, behind a profile
so it does not start with the rest of the stack.

## Loading a workbook

Two steps, because reading .xlsm needs a spreadsheet library the worker image
deliberately does not carry. The conversion happens on the host:

```bash
# once, on the host
apt-get install -y python3-openpyxl     # or: pip install openpyxl

mkdir -p /opt/sdi/intake
python3 tools/workbook-to-json.py /path/to/*.xlsm > /opt/sdi/intake/batch.json
docker compose run --rm worker node tools/load-intake.js /intake/batch.json \
  --note "August sourcing"
```

Then review and release at `/admin.html`, signed in as staff. Nothing reaches
the marketplace until somebody releases it.

The middle JSON file is the point: open it and read it before anything touches
the database.

## The nightly listing sweep

Not wired to a scheduler — run it from cron on the host:

```
0 7 * * *  cd /srv/sdi && docker compose -f docker-compose.release.yml \
             run --rm worker node tools/check-listings.js >> /var/log/sdi-sweep.log 2>&1
```

The `worker` service sits behind a Compose profile, so it does not start with
the rest of the stack. `run --rm` starts it for the one command and removes it.

## Listing photography

`web/public/assets/` is baked into the `web` image at build time. A photograph
dropped onto the host after the image was built will not appear — commit it and
let the image rebuild, or bind-mount the directory:

```yaml
web:
  volumes:
    - ./assets:/app/public/assets:ro
```

Bear in mind the limitation in `web/public/assets/108-fairgrove/README.md`:
files under `public/` are fetchable by anyone who guesses the path, so the
database controls who is *told* a gated image's url, not who can retrieve it.
