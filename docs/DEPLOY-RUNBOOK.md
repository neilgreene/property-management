# Deployment runbook

Numbered, in order, with the expected output at each step. Verified against
the live host on 2026-09-03 at release **0.9.0**.

Paths and values below are the real ones for the current deployment:

| | |
|---|---|
| Deployment folder | `/opt/sdi` |
| Source clone | `/root/property-management` |
| Web port | `3099` |
| Repository | `https://github.com/neilgreene/property-management.git` |

`/opt/sdi` is **not** a git clone. It holds the compose file and the database
volume, nothing else. The source clone is separate and never touches it.

---

## A. Upgrade to a new release

### A1. Pull and restart

```bash
cd /opt/sdi
docker compose pull
docker compose up -d
```

Expected: each image reports `Pulled`, then `db` `Healthy`, `web` `Running`.

> **When you also need `down -v`.** The schema files are baked into the `db`
> image and PostgreSQL runs them **only when the data volume is empty**.
> Pulling a newer `db` image onto an existing volume gives you the new image
> and the old schema, with no error and no warning. If the release added
> schema files, insert `docker compose down -v` between the two commands
> above. That **deletes the database** — correct while it holds demo data,
> wrong the moment it does not.

### A2. Confirm the schemas

```bash
docker compose exec db psql -U postgres -d sdi -c "\dn"
```

Expected at 0.9.0 — **8 rows**:

```
api  core  feed  ghl  gov  intake  public  sec
```

A missing schema means step A1 needed `down -v`.

### A3. Confirm the web tier

```bash
docker compose logs web | grep fair-housing
```

Expected:

```
fair-housing register: 17 dimensions, none exposed as filters
```

A `FATAL: could not reach the database` line **before** that line is the web
container losing a start-up race with a cold database and being restarted. It
is harmless when the good line follows. Fixed in 0.9.0 by widening the retry
budget to ~2 minutes; on older images it is expected.

### A4. Open it

`http://<host>:3099/` — type `http://` explicitly. Browsers upgrade bare
hostnames to HTTPS and this does not serve TLS, so omitting it gives
`ERR_SSL_PROTOCOL_ERROR`, which looks like a network fault and is not.

Sign in as `jpool2@yahoo.com` / `demo1234` (staff) or `marcus@example.com` /
`demo1234` (investor, gate shut).

---

## B. One-time setup for spreadsheet intake

Needed once per host. Skip if `docker compose config --services` already lists
`worker` and `python3 -c "import openpyxl"` is silent.

### B1. Clone the source

The workbook reader is a repository script, not part of any image.

```bash
cd /root
git clone https://github.com/neilgreene/property-management.git
```

### B2. Add the worker service

`docker compose run --rm worker …` needs the service defined. Rewriting the
whole file avoids YAML indentation mistakes:

```bash
cd /opt/sdi
cp docker-compose.yml docker-compose.yml.bak
```

…then add this block after the `web:` service and before the top-level
`volumes:` key:

```yaml
  worker:
    image: ghcr.io/neilgreene/property-management/worker:latest
    depends_on:
      db:
        condition: service_healthy
    environment:
      PGHOST: db
      PGDATABASE: sdi
      PGUSER: sdi_integration
      PGPASSWORD: sdi_int_pw
    volumes:
      - ./intake:/intake
    restart: "no"
```

Verify and start:

```bash
docker compose config --services     # expect: db web worker
docker compose up -d
```

> `PGPASSWORD` must match `SDI_INTEGRATION_PASSWORD` in the `db` service.
> Role passwords are applied **at first start only** — a role with no password
> stays `NOLOGIN` and cannot be given one later without re-initialising the
> volume. If the first-start log said `no password for sdi_integration`, set it
> and re-run A1 **with** `down -v`.

### B3. Install the spreadsheet reader

```bash
apt-get install -y python3-openpyxl
```

---

## C. Load a batch of workbooks

### C1. Put the files where the container can read them

```bash
mkdir -p /opt/sdi/intake
cp /path/to/*.xlsm /opt/sdi/intake/
```

### C2. Convert to JSON

```bash
cd /root/property-management
python3 tools/workbook-to-json.py /opt/sdi/intake/*.xlsm > /opt/sdi/intake/batch.json
```

Nothing touches the database yet. Open `batch.json` and read it — that is the
point of the middle format.

### C3. Load into the review queue

```bash
cd /opt/sdi
docker compose run --rm worker node tools/load-intake.js /intake/batch.json \
  --note "August sourcing"
```

Expected: a batch id, one line per property with price and cap rate, and any
validation problems. **No listing is created.**

### C4. Review and release

`http://<host>:3099/admin.html`, signed in as staff.

1. Tick the rows, or **Select all releasable**
2. **Approve selected**
3. Tick again, then **Release selected**

An amber banner naming listings **published with no confirmed data right** is
expected: the workbook right is recorded unreviewed because the property
descriptions are verbatim MLS copy whose republication right is not
established. See section 9 of the System Documentation.

---

## D. Nightly listing status sweep

Not wired to a scheduler. Add to the host's crontab:

```
0 7 * * *  cd /opt/sdi && docker compose run --rm worker node tools/check-listings.js >> /var/log/sdi-sweep.log 2>&1
```

With no MLS feed connected this does nothing but record that it looked, which
is the correct behaviour rather than a failure.

---

## E. Health checks

```bash
# must return ZERO rows
docker compose exec db psql -U postgres -d sdi -c "SELECT * FROM api.security_invariants()"

# where the data-rights register stands
docker compose exec db psql -U postgres -d sdi -c "SELECT * FROM api.governance_status"

# listings published under no confirmed right
docker compose exec db psql -U postgres -d sdi -c "SELECT * FROM gov.uncovered_publication"
```

`api.security_invariants()` returning zero rows is the single most valuable
check here. Run it after every upgrade.
