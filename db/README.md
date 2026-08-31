# Database layer

PostgreSQL 16. Local development only — nothing here is exposed to the network.

## Layout

| File | Purpose |
|---|---|
| `migrations/001_core.sql` | Domain: `property`, `party`, `deal`, `property_party` |
| `migrations/002_ghl_integration.sql` | GoHighLevel bridge: id map, webhook intake, transactions, sync cursors, outbox |
| `migrations/003_disclosure_control.sql` | `property_public` view, `property_detail_for()`, roles and grants |
| `apply.sh` | Drops and rebuilds the database from migrations |
| `verify_disclosure.sh` | Asserts restricted data is unreachable by the public role |

## Usage

```bash
./db/apply.sh              # rebuild 'pmp' from scratch
./db/verify_disclosure.sh  # assert the disclosure boundary holds
```

## Design decisions

**Money is `bigint` minor units.** Never float, and not `numeric` for values that
cross a JSON boundary. `cap_rate_bps` is basis points for the same reason.

**Disclosure is a database boundary, not a convention.** The public read path
connects as `pmp_public`, which has `SELECT` on the `property_public` view and
nothing else — not the `property` table. Restricted columns (street address,
coordinates, parcel id, seller notes, restricted analysis) are not present in
that view, so there is no filter to forget. Restricted fields are released only
through `property_detail_for(party_id, property_id)`, which reads entitlement
from the `party` table; a caller cannot pass the answer in. `verify_disclosure.sh`
asserts all of this.

**The GHL bridge is isolated in 002.** The domain does not depend on the CRM
remaining in the architecture.

**`ghl_webhook_event` is append-only and gates every side effect.** GHL webhook
delivery is neither exactly-once nor ordered, so handlers dedupe on `webhook_id`
before acting. Rows failing signature verification are recorded for audit and
never processed.

**`ghl_outbox` exists because GHL has no transactional import.** Outbound writes
are staged in the same transaction as the local change and dispatched by a worker
with a deterministic `idempotency_key`, so a retry after an ambiguous failure
cannot duplicate a record in GHL. This is what makes a failed migration pass
resumable.

See `docs/GHL-Interface-Specification.pdf` for the API contract these tables mirror.
