# SDI — property visibility enforced in the database

A working model of the three-band visibility problem: one property row, three
audiences, and a `$750` gate that has to hold even when the caller writes their
own SQL. Built on PostgreSQL 16, verified end to end.

## Run it

```bash
docker compose up          # then open http://localhost:3000
```

Or against a local Postgres 16+:

```bash
./run.sh                   # loads schema, runs the walkthrough, starts the web demo
```

The psql walkthrough on its own:

```bash
psql -d sdi -f sql/05_tests.sql
```

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
web/server.js                demo web tier
web/public/index.html        demo UI
docs/GHL-Interface-Specification.pdf   the GHL API contract, 17pp
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

## What this does not cover yet

Deal pipeline and stage history, document storage and the signed-PDF artifact,
messaging and the unified-inbox thread model, audit trail on band-2 and band-3
reads, and the co-investment matching engine. The visibility model is the
foundation those sit on, which is why it went first.
