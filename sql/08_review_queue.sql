-- =====================================================================
-- 08_review_queue.sql  |  inbound changes that need a human
-- =====================================================================
-- core.property is the system of record. GoHighLevel is downstream of it
-- for listings, so an inbound RecordUpdate means someone edited a
-- property inside the CRM -- against the grain of the architecture.
--
-- Blindly applying that would let the CRM silently overwrite the
-- authoritative row, which is the failure mode that makes two-way sync
-- notorious. Blindly ignoring it loses a real edit somebody made. So it
-- is neither applied nor dropped: it is queued for a person to decide.
--
-- The nightly external status check (Zillow/MLS) lands here too, for the
-- same reason -- a scraped 'Pending' is evidence, not fact.

BEGIN;

CREATE TYPE ghl.review_state AS ENUM ('open', 'accepted', 'rejected');

CREATE TABLE ghl.review_queue (
    id           bigserial        PRIMARY KEY,
    source       text             NOT NULL,   -- 'webhook' | 'status_scraper'
    event_type   text             NOT NULL,
    ghl_object   text,
    ghl_id       text,
    local_id     uuid,
    summary      text             NOT NULL,
    proposed     jsonb            NOT NULL,
    state        ghl.review_state NOT NULL DEFAULT 'open',
    raised_at    timestamptz      NOT NULL DEFAULT now(),
    decided_at   timestamptz,
    decided_by   uuid
);

-- One OPEN item per object: a property edited five times in the CRM is one
-- decision for a human, not five. A partial index rather than a plain UNIQUE
-- on (object, id, state), which would also have capped the object at one
-- rejected row for all time -- wrong, and only visible once someone rejected
-- a second change months later. ON CONFLICT cannot use a deferrable
-- constraint as an arbiter either, so this is the shape that actually works.
CREATE UNIQUE INDEX ux_review_open_object
    ON ghl.review_queue (ghl_object, ghl_id) WHERE state = 'open';
CREATE INDEX ix_review_open ON ghl.review_queue (raised_at) WHERE state = 'open';

GRANT SELECT, INSERT, UPDATE ON ghl.review_queue TO sdi_integration;
GRANT USAGE, SELECT ON SEQUENCE ghl.review_queue_id_seq TO sdi_integration;

COMMIT;
