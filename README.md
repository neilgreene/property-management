# SDI — property visibility enforced in the database

A working model of the three-band visibility problem: one property row, three
audiences, and a `$750` gate that has to hold even when the caller writes their
own SQL. Built on PostgreSQL 16, verified end to end.

## Requirements

**Route A — Docker.** One thing installed.

| Requirement | Version | Notes |
|---|---|---|
| Docker Engine | 20.10+ | Linux, macOS, Windows/WSL2, or a VM |
| Docker Compose | v2 (`docker compose`) | Not the standalone `docker-compose` binary — this file uses v2 profiles |
| Disk | ~1.5 GB | Chiefly the two base images |
| Memory | 1 GB free | Postgres plus two small Node processes |

What the Compose file actually runs:

| Service | Image | Resolves to | Port |
|---|---|---|---|
| `db` | `postgres:16` | PostgreSQL 16.x — tested on **16.13** | 5432 |
| `web` | `node:22-alpine` | Node 22.x — tested on **22.22.2** | 3000 |
| `worker` | `node:22-alpine` | Node 22.x — tested on **22.22.2** | 3001 |

Both tags float within their major version, so a pull next month may bring a
newer patch. That is the right default here — it picks up security fixes — but
pin to a digest for production so a rebuild produces the image that was tested.

**Route B — local install.**

| Requirement | Version | Why that floor |
|---|---|---|
| PostgreSQL | 16+ | `security_invoker` views need 15+. Below 15, a view over an RLS table silently runs as its *owner* and bypasses the caller's policies — which defeats the entire model |
| Node.js | 18+ | Built-in test runner and global `fetch`. Tested on 22 |
| npm | 9+ | Ships with Node 18+ |

**Optional, only to rebuild the PDFs in `docs/`:** Python 3.9+ (tested 3.11) and
`reportlab` 4+ (tested 5.0.1). Nothing in the running system needs Python.

**One runtime dependency**: `pg` (8.23.x under the declared `^8.13.1`). No web
framework, no ORM, no build step, no bundler. Worth preserving — it keeps the
dependency audit trivial.

### Network

| When | Needs |
|---|---|
| Build | Outbound HTTPS to Docker Hub and `registry.npmjs.org` |
| Runtime, core | **None.** Database, demo and tests run air-gapped |
| Runtime, worker | Outbound HTTPS to `services.leadconnectorhq.com` |
| Runtime, webhooks | Inbound HTTPS on a public address — *only* for receiving GHL deliveries |

Everything except webhook receipt works with no inbound access at all, which is
why a VM with no port forwarding is a perfectly good staging environment.

## Run it

### Docker — nothing installed but Docker

```bash
cp .env.example .env      # then set POSTGRES_PASSWORD
docker compose up --build
```

Serves the demo on <http://localhost:3000>. `docker compose down -v` discards
the database, which is what you want before rebuilding the schema from scratch.

Every service is **built**, not bind-mounted — the schema is baked into the
database image. That is what makes it deployable through Portainer, where a
relative bind mount on CE resolves to an empty directory and the database
initialises with no schema at all, silently.

PostgreSQL is deliberately **not published**. Nothing outside the stack needs
it. To inspect it, uncomment the loopback binding in `docker-compose.yml`.

**Deploying anywhere that is not a laptop:** use the published images rather
than building. Every push to `main` publishes `db`, `web` and `worker` to
`ghcr.io/neilgreene/property-management/…`, and `docker-compose.release.yml`
pulls them — no build on the target host, which also makes it work on Swarm.
Full runbook, including Portainer step by step:
[docs/DEPLOYMENT.md](docs/DEPLOYMENT.md).

The integration worker is **not** started by that, because it needs real GHL
credentials and there is no point running it without them:

```bash
GHL_TOKEN=... GHL_LOCATION_ID=... docker compose --profile worker up
```

`GHL_TOKEN` is a Private Integration Token (GHL: Settings → Private
Integrations). It is scoped to an entire sub-account, so it comes from your
environment and is never written into a file here.

### Local Postgres 16+ and Node 18+

```bash
./run.sh
```

Loads every schema file, runs all four walkthroughs, runs the 63 worker tests,
then starts the demo. It assumes `psql` and `createdb` work as your own user,
which is the default for Postgres.app and Homebrew.

Individual pieces:

```bash
psql -d sdi -f sql/05_tests.sql          # security walkthrough
psql -d sdi -f sql/14_pipeline_tests.sql # deal visibility
cd worker && npm test                    # 63 checks
```

### Capturing a live webhook

The one thing that cannot be verified without a GHL account. Run the capture
tool somewhere GHL can reach — any host with a public address, or behind
`cloudflared tunnel --url http://localhost:3999`, which needs no account:

```bash
node worker/tools/capture-webhook.js
```

Point a GHL webhook at it, push **a test contact, not a real one** (the payload
is written to disk), and it saves the raw bytes and headers untouched. That
settles the signature algorithm, which GHL does not document.

### Demo credentials

`sql/99_local_logins.sql` gives the application roles passwords so the stack is
connectable. The roles are otherwise created `NOLOGIN` and passwordless on
purpose — in a real deployment they are assumed via `SET ROLE`, or given
credentials by the deployment, never by a file in the repository. Both
`docker compose` and `run.sh` load that same file, so the two paths cannot
drift apart.

## Why Postgres and not MySQL

MySQL Community has no row-level security — no policy engine, no VPD analogue.
MySQL Enterprise ships data-masking functions, but those are value redaction you
call explicitly from a query, not a declarative predicate the optimizer enforces.
Everything below would have to be rebuilt in application code, which is the thing
worth avoiding.

| Oracle | Postgres |
|---|---|
| VPD row predicates | RLS policies (`USING` / `WITH CHECK`) |
| `SYS_CONTEXT`, application context | `current_setting()` / `set_config(..., true)` |
| VPD column masking | No native equivalent — `CASE` in a `security_invoker` view |
| Label Security | No equivalent — labels as columns, enforced by policy |
| Database Vault realms | Schema separation + `REVOKE` + definer-rights functions |
| Definer-rights procedures | `SECURITY DEFINER` functions |

The one behavioural difference worth knowing: Postgres column `GRANT`s raise
`permission denied for column` on `SELECT *` rather than returning NULL. The
`api` views restore the Oracle habit — every column is always present in the
result, unauthorised ones come back NULL.

## Layout

```
sql/01_schema.sql            core/sec/api schemas, roles, base tables
sql/02_policies.sql          RLS policies
sql/03_views.sql             masking views and the write path
sql/04_seed.sql              demo data
sql/05_tests.sql             eleven-check security walkthrough
sql/06_ghl_integration.sql   GoHighLevel bridge (ghl schema)
sql/07_ghl_tests.sql         seven-check GHL bridge walkthrough
sql/08_review_queue.sql      inbound CRM edits awaiting a human
sql/09_review_actions.sql    deciding them: admin-only, allowlisted
sql/10_review_tests.sql      seven-check review action walkthrough
sql/11_pipeline.sql          deals, stages, append-only stage history
sql/12_pipeline_policies.sql who sees which deals
sql/13_pipeline_seed.sql     demo pipelines and deals
sql/14_pipeline_tests.sql    nine-check pipeline walkthrough
web/server.js                demo web tier
web/public/index.html        demo UI
worker/src/                  GoHighLevel integration worker
worker/src/migrate/          EspoCRM -> GHL load passes
worker/src/index.js          the worker daemon: HTTP surface + loops
worker/test/                 63 tests (unit + end-to-end against the database)
docs/GHL-Interface-Specification.pdf   the GHL API contract, 17pp
docs/System-Documentation.pdf          what was built + next steps, 27pp
docs/schema-snapshot.json              the schema, read from a live database
docs/DEPLOYMENT.md                     Portainer and Docker deployment runbook
```

## The model

One `core.property` row carries three visibility bands. They are separated by
policy, not by copying rows into three tables.

| Band | Contents | Enforced by |
|---|---|---|
| 1 — public | city, price, cap rate, NOI, beds/baths | RLS policy per role |
| 2 — gated | street address, unit, parcel, disclosure, true lat/lng | `CASE` masking in the view, keyed on a data predicate |
| 3 — internal | acquisition cost, source channel, staff notes, margin | column-level `GRANT` (hard ACL) |

Three schemas, and the split is load-bearing:

- `core` — tables. No app role holds `USAGE`. Name resolution fails before any
  ACL or policy is consulted, so there is no path around the views.
- `sec` — security predicates. `SECURITY DEFINER`, `USAGE` granted. They live
  here because a `security_invoker` view resolves the *functions* it calls as the
  caller too, not just the tables — so predicates could not live in `core`
  without granting `USAGE` on `core`, which is exactly what seals band 2.
- `api` — the masking views and the write path. The only surface apps read.

### The gate is a predicate, not a role

`sec.can_see_address()` checks the caller's own `fee_agreement_signed_at`, not
their role. That is what makes Phase 4 cheap: the KAVADOO concierge tier is the
same mechanism with a different predicate, not a second schema.

Brand works the same way. `core.property_brand` decides publication and price per
brand; brand is a *lens over* properties plus an attribute on the investor, never
an attribute of the property. Adding KAVADOO is `INSERT`s into one table.

### Address masking that actually masks

Ungated callers never receive the address — it is dropped server-side, inside the
view, before the row leaves the database. Coordinates degrade rather than
disappear: `sec.jitter()` applies a deterministic ~1 km offset seeded on the
property id, so the map still renders a neighbourhood and repeated loads cannot be
averaged to recover the true point.

Client-side masking cannot do this. If the browser fetches the row, the address is
in the payload regardless of what the UI draws.

## Two traps this schema is built around

**`security_invoker` requires PG 15+.** Before that, views were definer-rights: a
view over an RLS table ran as the view *owner* and silently bypassed the caller's
policies. Every view here sets it explicitly, and `api.security_invariants()`
fails the build if one ever doesn't.

**`security_barrier` is not optional.** Postgres costs user-defined functions
cheaply, so without the barrier a caller can attach a `VOLATILE` function to a
`WHERE` clause that the planner evaluates *before* the RLS filter, leaking rows
through `RAISE NOTICE`. Test 10 in the walkthrough is that attack; it returns only
the five rows the caller was already allowed to see.

A third trap, found while building this: a `SECURITY DEFINER` write function runs
as its *owner*, so checking visibility by re-selecting from the view inside it
passes for every row. `api.save_property()` calls the same shared predicate the
RLS policy uses instead — one source of truth, no drift.

## Walkthrough

`sql/05_tests.sql` runs eleven checks. Six are the roles; five are attacks.

| | Check | Result |
|---|---|---|
| 1 | Anonymous, no `WHERE` clause | 5 of 8 rows — draft, pending and sold drop out by policy |
| 2 | Investor, agreement unsigned | 6 rows, address withheld, coordinates offset |
| 3 | Same role and SQL, agreement signed | address and true coordinates released |
| 4 | Agent | only his 4 assigned properties, including an unpublished draft |
| 5 | Admin | 8 rows, all three bands, derived margin |
| 6 | Brand switched to KAVADOO | 3 rows at concierge pricing, same base rows |
| 7 | Attack — read `core.property` directly | `permission denied for schema core` |
| 8 | Attack — read another investor's saved list | 0 rows |
| 9 | Attack — save a property the caller can't see | rejected by shared predicate |
| 10 | Attack — `VOLATILE` predicate side-channel | barrier holds, 5 rows |
| 11 | Standing invariants | 0 violations |

## Operational notes

`api.security_invariants()` must always return zero rows — wire it into CI and a
nightly check. It catches the four changes that quietly dismantle the model:
`USAGE` granted on `core`, an internal column exposed to a non-admin, RLS turned
off on a protected table, or a view created without `security_invoker`.

`noi_annual` and `cap_rate` are `GENERATED ALWAYS` columns, not stored inputs. If
an assumption changes the metric moves with it and there is no second copy to
drift. Worth confirming which of the 30+ SDI metrics are genuinely inputs — the
rest should be derived the same way.

Per-row predicate functions (`sec.is_assigned`) are indexed by
`ix_assignment_person`. At 50–200 properties a week this is irrelevant; at a few
hundred thousand rows, check the plan before assuming it still is.

The demo maps personas to roles in `web/server.js` for convenience. In production
that mapping comes out of the session after authentication — the database contract
is identical either way. Passwords in `docker-compose.yml` are demo values.

## Deals and stage history

A deal is where a property and an investor meet, so it inherits the visibility
problem rather than escaping it. `sec.can_see_deal()` reuses `sec.actor()`:
investors see their own, agents see the ones they are the agent on, admins see
all, and the public role is not granted the view at all — a deal is never
public, at any stage.

**History is a trigger, not a convention.** `core.deal_stage_history` is
append-only and written by `core.log_stage_change()`. "When did this go under
contract" is the question the business actually asks, and an application that
forgets to log once makes the answer permanently wrong. `seconds_in_from` is
computed on write for the same reason.

Two triggers, not one: a `BEFORE INSERT` cannot write the history row because
the deal does not exist yet and the foreign key fails. So `BEFORE` keeps
`closed_at` consistent with `stage_code` — entering a terminal stage closes the
deal, leaving one reopens it — and `AFTER` writes the log once the row is real.

### Two findings worth keeping

**`LEFT JOIN core.property`, not inner.** `core.property` has its own RLS, so an
inner join silently *drops* a deal whose property the caller cannot see. An
agent would lose a deal they are party to, with no error and no clue why. Being
party to a deal makes the deal visible; the property columns then fill in only
as far as the property's own policy allows — check 3 shows Tom seeing both his
deals, one of them reading `(property not visible)`.

**Names come from `sec.deal_party_name()`, not a join.** An agent legitimately
needs the investor's name on their own deal, but `core.person` is RLS'd to self,
so a plain join returns NULL — and loosening that policy would expose the whole
directory. The function releases exactly one field, and only to someone who
already shares a deal with that person.

## The GoHighLevel bridge

`sql/06_ghl_integration.sql` adds a `ghl` schema and an `sdi_integration` role.
The web tier is deliberately not granted `USAGE` on it: `sdi_app` has no reason
to read CRM plumbing, and keeping it out means a compromised web session cannot
enumerate contacts, invoices or transactions.

Three facts from the API shape it, all documented in
`docs/GHL-Interface-Specification.pdf`:

- **GHL has no endpoint that creates a transaction.** `ghl.transaction` is a
  mirror, never a source, and keeps the raw payload for reconciliation.
- **Webhook delivery is neither exactly-once nor ordered.** Every side effect is
  gated on `ghl.webhook_event`, keyed on the payload's `webhookId`.
- **There is no transactional import.** Outbound writes stage in `ghl.outbox`
  with a deterministic `idempotency_key`, so a retry after an ambiguous failure
  cannot duplicate a record in GHL.

### The fee gate has two conditions, not one

GHL's Documents & Contracts API (the `proposals` module) reports document status
and payment status *independently*: `draft|sent|viewed|completed|accepted` and
`waiting_for_payment|paid|no_payment`. A document can be signed and unpaid.

`ghl.apply_fee_agreement()` is the only thing in the system that writes
`core.person.fee_agreement_signed_at`, and it requires both — completed or
accepted, *and* paid. Test 2 in `sql/07_ghl_tests.sql` is the signed-but-unpaid
case, which a tag-based unlock gets wrong. It is also idempotent: replaying an
event never moves an existing signature timestamp.

Note there is no document-signed event in GHL's 58-event webhook catalogue, so
`ghl.fee_agreement` is kept current either by polling `GET /proposals/document`
or by a GHL workflow posting to a custom webhook. The state lands here either way.

### GHL bridge walkthrough

`sql/07_ghl_tests.sql` runs seven checks.

| | Check | Result |
|---|---|---|
| 1 | Marcus, no agreement | address withheld |
| 2 | Document completed but **unpaid** | gate stays shut |
| 3 | Payment settles | band 2 opens, address released |
| 4 | Replay the same event | signature timestamp unchanged |
| 5 | Attack — web persona reads `ghl.transaction` | `permission denied for schema ghl` |
| 6 | Attack — web persona opens its own gate | `permission denied for schema core` |
| 7 | Standing invariants after adding `ghl` | 0 violations |

## The integration worker

`worker/` is the Node service that talks to GoHighLevel. `npm test` runs 31
checks; the database-backed ones skip cleanly if no database is reachable.

**Signature verification is asymmetric.** GHL signs with an RSA private key and
publishes the public key, so `worker/src/signature.js` verifies rather than
recomputes an HMAC. Two rules it enforces, both easy to get wrong: verify the
*raw* body bytes — parse-then-stringify changes whitespace and key order and the
signature will never match, which is its own test — and reject deliveries
outside a five-minute window or with a `webhookId` already seen.

The exact algorithm and padding are not stated in GHL's published documentation.
PKCS#1 v1.5 with SHA-256 is the conventional pairing for this key format and is
what the code tries. **Confirm it against a captured live delivery before
trusting it in production.**

**The receiver is a plain function over `(rawBody, headers)`**, not an HTTP
route. Live deliveries need an inbound public URL, which local development does
not have, so it is driven from fixtures today and mounted on a route later
without changing a line.

**The client sets `Version: 2021-07-28` once.** It is a required header with a
single-value enum in the spec, so omitting it is a deterministic failure — it
belongs in the client, not at each call site. The client also paces itself well
under the 100-request/10-second burst ceiling, retries 429 and 5xx with jittered
backoff, and does not retry 403, since a missing scope will never succeed and
retrying it just burns rate budget.

### One thing the tests caught

`core.person` is `FORCE ROW LEVEL SECURITY`, which applies to the table owner as
well. A `SECURITY DEFINER` function therefore gets no free pass unless its owner
is a superuser — true on a laptop, not something to rely on in production. The
gate write is now authorised by an explicit `person_gate_write` policy keyed on a
transaction-local flag that only `ghl.apply_fee_agreement()` sets, and
`sdi_integration` holds no grants on `core` at all. It does not need any: it
resolves identity through `ghl.id_map` and opens the gate only through that
function.

The integration test uses two connections for the same reason — the worker
writes the gate as `sdi_integration`, and reading back what the investor now
sees has to go through the web tier's own role, because the worker cannot
`SET ROLE` into a persona. That separation is the point, so the test respects it
rather than granting itself a shortcut.

## Running the worker

```bash
cd worker
GHL_TOKEN=... GHL_LOCATION_ID=... PGUSER=sdi_integration npm start
```

It refuses to start without credentials rather than failing later on the first
call. Two routes and four loops:

| | |
|---|---|
| `POST /webhooks/ghl` | receive a delivery; acknowledge fast, work happens in the loops |
| `GET /healthz` | liveness plus queue depth — pending events, bad signatures, outbox backlog, stuck rows, open reviews |
| loop `events` | 5s — dispatch received events |
| loop `outbox` | 10s — drain outbound writes |
| loop `documents` | 5m — fee agreement state |
| loop `transactions` | 15m — reconciliation sweep |

**There is no web framework here, deliberately.** GHL signs the exact bytes it
sent, so the request is buffered and that Buffer reaches the verifier untouched.
Any JSON body-parsing middleware in front of this endpoint would parse and
discard those bytes, and every signature would fail. `test/server.test.js` posts
a body with deliberately odd whitespace over a real socket to prove the bytes
survive transport.

### Direction decides the handlers

`core.property` and `core.person` are the system of record; GHL is downstream of
them for listings. So an inbound `RecordUpdate` means somebody edited a property
*inside the CRM*, against the grain of the architecture.

Applying it would let the CRM silently overwrite the authoritative row — the
failure mode that makes two-way sync notorious. Dropping it loses a real edit
somebody made. So it is neither: it goes to `ghl.review_queue` for a person.
Events that genuinely originate in GHL — a signed document, a settled payment, a
contact created by staff — are applied directly, because for those GHL *is* the
source.

The nightly external status check (Zillow/MLS) lands in the same queue for the
same reason: a scraped "Pending" is evidence, not fact.

### Accepting a CRM edit applies an allowlist, never the payload

`api.review_decide()` is how a human answers a queued item, and two things
constrain it.

Only an admin decides. That decision is what lets a CRM edit reach the
authoritative row, so it is exactly as privileged as editing `core.property`
directly. It is checked against `sec.actor()`, not against a caller-supplied id.

Accepting writes only the columns in `ghl.reviewable_field` — currently
`status`, `list_price`, `gross_rent_annual`, `opex_annual`, `hoa_annual`. The
CRM payload is external input; letting it name its own target columns would mean
a status change was a route to rewriting `street_address` or `acquisition_cost`,
which is band 2 and band 3 data. Test 4 in `sql/10_review_tests.sql` sends
exactly that payload — a legitimate status change with an address and a cost
basis smuggled alongside — and asserts that only the allowlisted two move.

Note the non-admin cases pass a literal item id rather than a subquery. Reading
`ghl.review_queue` in a subquery fails on the schema grant *before* reaching
`review_decide`, so the test would have gone green while proving nothing about
the function's own check.

`ux_review_open_object` allows one *open* item per object, so a property edited
five times in the CRM is one decision for a human rather than five — but any
number of decided rows, because a plain `UNIQUE (object, id, state)` would have
capped each object at one rejected row for all time. That would only have
surfaced the first time somebody rejected a second change, months later.

## The EspoCRM migration

GHL has no transactional import, so ordering is the whole game. An association
can only be created once both endpoints exist and carry GHL ids, and those ids
only exist after the pass that created them. Hence:

| Pass | Does | Reads |
|---|---|---|
| 1 | custom object schemas | — |
| 2 | association types | — |
| 3 | people to contacts | source |
| 4 | properties to object records | source |
| 5 | links to relations | `ghl.id_map` from 3 and 4 |
| 6 | deals to opportunities | source |
| 7 | reconcile counts and spot checks | both |

`ghl.id_map` is written *as the load runs*, not at the end. That is what makes
pass 5 possible and what makes a crash survivable.

**Every pass is restartable.** Passes 3, 4 and 6 stage work in `ghl.outbox` and
let the drainer do the talking, so a crash mid-pass loses nothing: re-running
re-enqueues, the idempotency key collapses the repeat, and the drainer's
`id_map` check stops an ambiguous create from twinning a record. There is a test
for each of those three.

**Unresolved links are reported, never dropped.** A link whose endpoints have no
GHL id is the failure mode that matters, because a missing relation is invisible
in the destination and looks like clean data.

The field-level mapping is deliberately not written. It needs the live EspoCRM
schema — entity names, custom field keys, and which of the 30+ SDI metrics are
genuine inputs rather than derived. `worker/src/migrate/source.js` defines the
adapter contract and ships a JSON implementation, so rehearsing the load against
a snapshot is one module away from the real thing. Rehearse against a snapshot
rather than a live read: a snapshot is repeatable.

## The outbox drain

`worker/src/outbox.js`. GHL accepts no `Idempotency-Key` header, so after a
timeout "did my write land?" is genuinely ambiguous. Three things together make
retry safe:

1. Prefer upsert endpoints (`/contacts/upsert`, `/opportunities/upsert`).
   Replaying one is inert by construction.
2. For endpoints with no upsert (`/objects/{key}/records`), consult
   `ghl.id_map` **before** creating. If the local id already has a GHL id, the
   previous attempt did land, so adopt it rather than create a twin.
3. Claim rows `FOR UPDATE SKIP LOCKED` so two drainers cannot race a row.

A 403 fails immediately rather than retrying — a missing scope will never
succeed and retrying only burns rate budget. Retries back off to a one-hour cap
and then abandon, so nothing loops forever.

## Regenerating the documents

Both PDFs in `docs/` are produced by committed generators rather than written by
hand, so they can be rebuilt instead of drifting.

`System-Documentation.pdf` carries an appendix defining every column of every
table. That appendix is not transcribed — it is read from a live database, so it
cannot describe a schema the system does not actually have. After a schema
change:

```bash
./run.sh                                    # or docker compose up
python3 docs/extract_schema.py              # -> docs/schema-snapshot.json
python3 docs/generate_system_documentation.py
```

The generator reads the snapshot rather than the database, so the PDF rebuilds
on a machine with no PostgreSQL running. Its contents page is built in two
passes: the first records where each heading lands, the second lays out the page
with those numbers.

## What this does not cover yet

Deal pipeline and stage history, document storage and the signed-PDF artifact,
messaging and the unified-inbox thread model, audit trail on band-2 and band-3
reads, and the co-investment matching engine. The visibility model is the
foundation those sit on, which is why it went first.

### Nothing here has ever spoken to GoHighLevel

The most important caveat, and the easiest to miss behind a passing test count.
The integration is written and tested, but **no line of it has made a request to
GoHighLevel**. Every test supplies a double — an injected `fetch`, a locally
generated RSA keypair, a fake client. Zero of the 63 tests reach the network.

What that buys is the logic: retry, deduplication, the two-condition fee gate,
outbox resumability, migration ordering, every privilege boundary. What it does
not buy is any assumption about how the real API behaves — response shapes,
field names, error bodies, or the signature algorithm.

Section 6.4 of `docs/System-Documentation.pdf` carries the full assumption
register: nine specific guesses, where each lives, and what breaks if it is
wrong. Most fail loudly. **Assumption 2 fails quietly** — if the transaction list
does not return rows under `data` or `transactions`, the sync reports success,
the cursor advances, and the ledger never fills.

Closing it needs no code: one captured webhook delivery, and one saved response
from each of `GET /payments/transactions` and `GET /proposals/document`.
