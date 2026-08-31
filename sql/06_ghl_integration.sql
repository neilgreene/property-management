-- =====================================================================
-- 06_ghl_integration.sql  |  GoHighLevel bridge
-- =====================================================================
-- Everything that touches GoHighLevel lives in its own schema, for the
-- same reason core is sealed: the web personas must never be able to
-- name these tables. The integration worker is the only role with USAGE.
--
-- The API contract these tables mirror is documented in
-- docs/GHL-Interface-Specification.pdf. Three facts from it shape the
-- design here:
--   1. GHL exposes no endpoint that creates a transaction. This schema
--      is a mirror, never a source -- hence ghl.transaction is read-only
--      downstream and carries the raw payload for reconciliation.
--   2. Webhook delivery is neither exactly-once nor ordered, so every
--      side effect is gated on ghl.webhook_event.
--   3. There is no transactional import, so outbound writes are staged
--      in ghl.outbox and dispatched with a deterministic idempotency key.
-- =====================================================================

DROP SCHEMA IF EXISTS ghl CASCADE;
CREATE SCHEMA ghl;

-- The worker that syncs with GoHighLevel. Deliberately NOT granted to
-- sdi_app: the web tier has no reason to read CRM plumbing, and keeping
-- it out means a compromised web session cannot enumerate contacts,
-- invoices or transactions.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sdi_integration') THEN
    CREATE ROLE sdi_integration NOLOGIN;
  END IF;
END $$;

GRANT USAGE ON SCHEMA ghl TO sdi_integration;

-- ---------------------------------------------------------------------
-- Identity bridge
-- ---------------------------------------------------------------------
-- Written during the EspoCRM -> GHL load, read forever after. Without
-- this map the association pass cannot be built, and a load that fails
-- half way cannot resume without creating duplicates in GHL.
CREATE TYPE ghl.object_kind AS ENUM ('contact', 'record', 'opportunity');

CREATE TABLE ghl.id_map (
    entity_type text            NOT NULL,   -- 'property' | 'person'
    local_id    uuid            NOT NULL,
    ghl_id      text            NOT NULL,
    ghl_object  ghl.object_kind NOT NULL,
    location_id text            NOT NULL,
    synced_at   timestamptz     NOT NULL DEFAULT now(),
    PRIMARY KEY (entity_type, local_id, location_id),
    UNIQUE (ghl_id, location_id)
);
CREATE INDEX ix_ghl_id_map_reverse ON ghl.id_map (ghl_id);

-- ---------------------------------------------------------------------
-- Event intake
-- ---------------------------------------------------------------------
-- Append-only. Insert before acting; a duplicate webhook_id is an
-- idempotent no-op. Rows failing signature verification are kept for
-- audit and never processed.
CREATE TABLE ghl.webhook_event (
    webhook_id   text        PRIMARY KEY,   -- payload webhookId
    event_type   text        NOT NULL,
    occurred_at  timestamptz NOT NULL,      -- payload timestamp
    received_at  timestamptz NOT NULL DEFAULT now(),
    processed_at timestamptz,
    attempts     integer     NOT NULL DEFAULT 0,
    last_error   text,
    signature_ok boolean     NOT NULL,
    payload      jsonb       NOT NULL
);
CREATE INDEX ix_ghl_event_type    ON ghl.webhook_event (event_type, occurred_at DESC);
CREATE INDEX ix_ghl_event_pending ON ghl.webhook_event (received_at)
    WHERE processed_at IS NULL;
CREATE INDEX ix_ghl_event_bad_sig ON ghl.webhook_event (received_at)
    WHERE NOT signature_ok;

-- ---------------------------------------------------------------------
-- Transaction mirror
-- ---------------------------------------------------------------------
-- Money amounts follow core.property's numeric(12,2) rather than minor
-- units, so joins against list_price and platform_fee need no scaling.
CREATE TABLE ghl.transaction (
    ghl_id           text          PRIMARY KEY,   -- transaction _id
    location_id      text          NOT NULL,
    contact_id       text,
    invoice_id       text,
    subscription_id  text,
    amount           numeric(12,2) NOT NULL,
    currency         char(3)       NOT NULL,
    amount_refunded  numeric(12,2) NOT NULL DEFAULT 0,
    status           text          NOT NULL,
    live_mode        boolean       NOT NULL,
    payment_provider text,
    entity_type      text,
    entity_id        text,
    ghl_created_at   timestamptz   NOT NULL,
    ghl_updated_at   timestamptz   NOT NULL,
    synced_at        timestamptz   NOT NULL DEFAULT now(),
    raw              jsonb         NOT NULL,
    CONSTRAINT ghl_txn_amount_nonneg CHECK (amount >= 0),
    CONSTRAINT ghl_txn_refund_bounded
        CHECK (amount_refunded >= 0 AND amount_refunded <= amount)
);
CREATE INDEX ix_ghl_txn_invoice ON ghl.transaction (invoice_id);
CREATE INDEX ix_ghl_txn_contact ON ghl.transaction (contact_id);
CREATE INDEX ix_ghl_txn_live    ON ghl.transaction (ghl_created_at DESC)
    WHERE live_mode;

COMMENT ON COLUMN ghl.transaction.live_mode IS
    'Always filter on this. GHL test-mode traffic must never settle a real gate.';

-- ---------------------------------------------------------------------
-- Fee agreement tracking
-- ---------------------------------------------------------------------
-- GHL Documents & Contracts are the `proposals` module. Its document
-- status enum is draft|sent|viewed|completed|accepted and paymentStatus
-- is waiting_for_payment|paid|no_payment. There is NO document-signed
-- webhook event in GHL's catalogue, so this table is kept current either
-- by polling GET /proposals/document or by a GHL workflow posting to a
-- custom webhook. Either way the state lands here first.
CREATE TABLE ghl.fee_agreement (
    document_id    text        PRIMARY KEY,
    location_id    text        NOT NULL,
    person_id      uuid        REFERENCES core.person(person_id),
    ghl_contact_id text,
    status         text        NOT NULL,
    payment_status text        NOT NULL,
    grand_total    numeric(12,2),
    ghl_updated_at timestamptz NOT NULL,
    observed_at    timestamptz NOT NULL DEFAULT now(),
    raw            jsonb       NOT NULL
);
CREATE INDEX ix_ghl_fee_person ON ghl.fee_agreement (person_id);

-- The single place the $750 gate is opened. Nothing else in the system
-- should write core.person.fee_agreement_signed_at -- routing it through
-- one definer-rights function means the condition for unlocking band 2
-- is stated exactly once and is auditable.
-- core.person is FORCE ROW LEVEL SECURITY, which applies to the table owner as
-- well. A SECURITY DEFINER function therefore does NOT get a free pass unless
-- its owner is a superuser -- true on a laptop, not something to rely on in
-- production. So the gate write is authorised by an explicit policy keyed on a
-- transaction-local flag that only the function below sets. sdi_integration
-- holds no UPDATE grant on core.person, so it cannot reach this path directly.
CREATE POLICY person_gate_write ON core.person
  FOR UPDATE
  USING      (current_setting('app.gate_write', true) = '1')
  WITH CHECK (current_setting('app.gate_write', true) = '1');

CREATE FUNCTION ghl.apply_fee_agreement(p_document_id text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ghl, core, pg_temp
AS $$
DECLARE
    fa ghl.fee_agreement%ROWTYPE;
BEGIN
    SELECT * INTO fa FROM ghl.fee_agreement WHERE document_id = p_document_id;
    IF NOT FOUND OR fa.person_id IS NULL THEN
        RETURN false;
    END IF;

    -- Signed is not enough: the fee must also have settled. GHL reports
    -- these independently, and a completed-but-unpaid document is exactly
    -- the case a tag-based unlock gets wrong.
    IF fa.status NOT IN ('completed','accepted') OR fa.payment_status <> 'paid' THEN
        RETURN false;
    END IF;

    PERFORM set_config('app.gate_write', '1', true);   -- transaction-local
    UPDATE core.person
       SET fee_agreement_signed_at = COALESCE(fee_agreement_signed_at, fa.ghl_updated_at)
     WHERE person_id = fa.person_id
       AND fee_agreement_signed_at IS NULL;
    PERFORM set_config('app.gate_write', '0', true);

    RETURN true;
END;
$$;

COMMENT ON FUNCTION ghl.apply_fee_agreement(text) IS
    'Opens band 2 for a person. Requires the document to be completed or '
    'accepted AND the payment to have settled. Idempotent: never moves an '
    'already-set signature timestamp.';

-- ---------------------------------------------------------------------
-- Sync cursors and outbox
-- ---------------------------------------------------------------------
CREATE TABLE ghl.sync_state (
    resource     text PRIMARY KEY,   -- 'transactions' | 'documents' | 'records:property'
    location_id  text        NOT NULL,
    cursor_at    timestamptz,        -- high-water mark on the remote updatedAt
    last_run_at  timestamptz,
    last_ok_at   timestamptz,
    last_error   text,
    records_seen bigint      NOT NULL DEFAULT 0
);

CREATE TYPE ghl.outbox_state AS ENUM ('pending','sent','failed','abandoned');

CREATE TABLE ghl.outbox (
    id              bigserial        PRIMARY KEY,
    idempotency_key text             NOT NULL UNIQUE,
    operation       text             NOT NULL,  -- 'contact.upsert' | 'record.create' | ...
    entity_type     text,
    local_id        uuid,
    payload         jsonb            NOT NULL,
    state           ghl.outbox_state NOT NULL DEFAULT 'pending',
    attempts        integer          NOT NULL DEFAULT 0,
    next_attempt_at timestamptz      NOT NULL DEFAULT now(),
    last_error      text,
    ghl_id          text,
    created_at      timestamptz      NOT NULL DEFAULT now(),
    sent_at         timestamptz
);
CREATE INDEX ix_ghl_outbox_due ON ghl.outbox (next_attempt_at) WHERE state = 'pending';

COMMENT ON COLUMN ghl.outbox.idempotency_key IS
    'Deterministic per logical operation, so a retry after an ambiguous '
    'failure cannot create a duplicate record in GHL.';

-- ---------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA ghl TO sdi_integration;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA ghl TO sdi_integration;
GRANT EXECUTE ON FUNCTION ghl.apply_fee_agreement(text) TO sdi_integration;

-- Deliberately no grants on core. The worker resolves identity through
-- ghl.id_map and opens the gate only via ghl.apply_fee_agreement(), so it needs
-- neither USAGE on core nor any privilege on core.person. Granting them would
-- have been theatre in any case: core.person is FORCE RLS with policies keyed
-- on sec.actor_id(), so a direct SELECT from this role returns zero rows.
