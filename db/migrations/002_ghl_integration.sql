-- 002_ghl_integration.sql
-- Everything that touches GoHighLevel. Kept separate from the core domain so
-- the domain does not depend on the CRM staying in the architecture.
--
-- Reference: docs/GHL-Interface-Specification.pdf

BEGIN;

-- --------------------------------------------------------------- id bridge
-- Written during the EspoCRM -> GHL migration, read forever after.
-- Without this map, association passes cannot be built and a failed load
-- cannot be resumed without duplicating records in GHL.
CREATE TYPE ghl_object_kind AS ENUM ('contact', 'record', 'opportunity');

CREATE TABLE ghl_id_map (
    entity_type   text            NOT NULL,   -- 'property' | 'party' | 'deal'
    local_id      bigint          NOT NULL,
    ghl_id        text            NOT NULL,
    ghl_object    ghl_object_kind NOT NULL,
    location_id   text            NOT NULL,
    synced_at     timestamptz     NOT NULL DEFAULT now(),
    PRIMARY KEY (entity_type, local_id, location_id),
    UNIQUE (ghl_id, location_id)
);
CREATE INDEX ghl_id_map_reverse ON ghl_id_map (ghl_id);

-- ------------------------------------------------------------ event intake
-- Append-only. The dedupe and audit backbone. Webhook delivery from GHL is
-- neither exactly-once nor ordered, so every side effect is gated on this.
CREATE TABLE ghl_webhook_event (
    webhook_id    text        PRIMARY KEY,    -- payload webhookId
    event_type    text        NOT NULL,
    occurred_at   timestamptz NOT NULL,       -- payload timestamp
    received_at   timestamptz NOT NULL DEFAULT now(),
    processed_at  timestamptz,
    attempts      integer     NOT NULL DEFAULT 0,
    last_error    text,
    signature_ok  boolean     NOT NULL,
    payload       jsonb       NOT NULL
);
CREATE INDEX ghl_event_type_idx    ON ghl_webhook_event (event_type, occurred_at DESC);
CREATE INDEX ghl_event_pending_idx ON ghl_webhook_event (received_at)
    WHERE processed_at IS NULL;
CREATE INDEX ghl_event_bad_sig_idx ON ghl_webhook_event (received_at)
    WHERE NOT signature_ok;

COMMENT ON TABLE ghl_webhook_event IS
    'Insert before acting. A duplicate webhook_id is an idempotent no-op. '
    'Rows with signature_ok = false are recorded for audit and never processed.';

-- ------------------------------------------------------------- transactions
-- Mirror of GHL transactions. Read-only upstream: the GHL API exposes no
-- endpoint that creates a transaction, so this table is never the source.
CREATE TABLE ghl_transaction (
    ghl_id                text        PRIMARY KEY,   -- transaction _id
    location_id           text        NOT NULL,
    contact_id            text,
    invoice_id            text,
    subscription_id       text,
    amount_minor          bigint      NOT NULL,
    currency              char(3)     NOT NULL,
    amount_refunded_minor bigint      NOT NULL DEFAULT 0,
    status                text        NOT NULL,
    live_mode             boolean     NOT NULL,
    payment_provider      text,
    entity_type           text,
    entity_id             text,
    ghl_created_at        timestamptz NOT NULL,
    ghl_updated_at        timestamptz NOT NULL,
    synced_at             timestamptz NOT NULL DEFAULT now(),
    raw                   jsonb       NOT NULL,
    CONSTRAINT ghl_txn_amount_nonneg CHECK (amount_minor >= 0),
    CONSTRAINT ghl_txn_refund_bounded
        CHECK (amount_refunded_minor >= 0 AND amount_refunded_minor <= amount_minor)
);
CREATE INDEX ghl_txn_invoice_idx ON ghl_transaction (invoice_id);
CREATE INDEX ghl_txn_contact_idx ON ghl_transaction (contact_id);
CREATE INDEX ghl_txn_updated_idx ON ghl_transaction (ghl_updated_at DESC);
CREATE INDEX ghl_txn_live_idx    ON ghl_transaction (ghl_created_at DESC)
    WHERE live_mode;

COMMENT ON COLUMN ghl_transaction.live_mode IS
    'Always filter on this. Test-mode traffic must never reach production ledgers.';

-- --------------------------------------------------------------- sync state
-- Cursors for incremental polling and the nightly reconciliation sweep.
CREATE TABLE ghl_sync_state (
    resource        text        PRIMARY KEY,  -- 'transactions' | 'records:property' | ...
    location_id     text        NOT NULL,
    cursor_at       timestamptz,              -- high-water mark on ghl_updated_at
    last_run_at     timestamptz,
    last_ok_at      timestamptz,
    last_error      text,
    records_seen    bigint      NOT NULL DEFAULT 0
);

-- ------------------------------------------------------------------ outbox
-- Reliable outbound writes. GHL has no transactional import, so a write is
-- staged here in the same transaction as the local change and dispatched by
-- a worker with retry. This is what makes a failed migration pass resumable.
CREATE TYPE outbox_state AS ENUM ('pending', 'sent', 'failed', 'abandoned');

CREATE TABLE ghl_outbox (
    id            bigserial   PRIMARY KEY,
    idempotency_key text      NOT NULL UNIQUE,
    operation     text        NOT NULL,    -- 'contact.upsert' | 'record.create' | ...
    entity_type   text,
    local_id      bigint,
    payload       jsonb       NOT NULL,
    state         outbox_state NOT NULL DEFAULT 'pending',
    attempts      integer     NOT NULL DEFAULT 0,
    next_attempt_at timestamptz NOT NULL DEFAULT now(),
    last_error    text,
    ghl_id        text,                    -- populated on success
    created_at    timestamptz NOT NULL DEFAULT now(),
    sent_at       timestamptz
);
CREATE INDEX ghl_outbox_due_idx ON ghl_outbox (next_attempt_at)
    WHERE state = 'pending';
CREATE INDEX ghl_outbox_failed_idx ON ghl_outbox (created_at)
    WHERE state IN ('failed', 'abandoned');

COMMENT ON COLUMN ghl_outbox.idempotency_key IS
    'Deterministic per logical operation, so a retry after an ambiguous '
    'failure cannot create a duplicate record in GHL.';

COMMIT;
