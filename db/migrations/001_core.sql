-- 001_core.sql
-- Core domain: properties as the primary entity, parties, deals.
-- Money is stored as bigint minor units (cents). Never float, never numeric
-- for values that cross a JSON boundary.

BEGIN;

CREATE TYPE property_status AS ENUM (
    'draft', 'active', 'pending', 'sold', 'withdrawn'
);

CREATE TYPE party_role AS ENUM (
    'investor', 'agent', 'lender', 'staff'
);

CREATE TYPE entitlement_state AS ENUM (
    'none',        -- registered, no agreement
    'pending',     -- agreement sent, not signed
    'granted',     -- agreement signed and fee settled
    'revoked'
);

-- ---------------------------------------------------------------- parties
CREATE TABLE party (
    id              bigserial PRIMARY KEY,
    external_ref    text UNIQUE,              -- EspoCRM primary key, for migration
    role            party_role  NOT NULL,
    full_name       text        NOT NULL,
    email           text,
    phone           text,
    entitlement     entitlement_state NOT NULL DEFAULT 'none',
    entitled_at     timestamptz,
    active          boolean     NOT NULL DEFAULT true,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX party_email_key ON party (lower(email)) WHERE email IS NOT NULL;
CREATE INDEX party_role_idx ON party (role) WHERE active;

COMMENT ON COLUMN party.entitlement IS
    'Server-side authorisation state. The only thing that may unlock restricted '
    'property fields. Never derive access from a client-supplied value.';

-- -------------------------------------------------------------- properties
-- Columns are split into two groups by disclosure class:
--   PUBLIC     - safe to serve to an unauthenticated visitor
--   RESTRICTED - only for a party whose entitlement = 'granted'
-- The split is enforced by the property_public view in 003, not by convention.
CREATE TABLE property (
    id                     bigserial PRIMARY KEY,
    external_ref           text UNIQUE,        -- EspoCRM primary key
    status                 property_status NOT NULL DEFAULT 'draft',
    public_visible         boolean     NOT NULL DEFAULT false,

    -- PUBLIC ------------------------------------------------------------
    headline               text        NOT NULL,
    display_region         text        NOT NULL,   -- 'Cleveland, OH' - coarse only
    property_type          text,
    beds                   smallint,
    baths                  numeric(3,1),
    sqft                   integer,
    year_built             smallint,
    asking_price_minor     bigint,
    currency               char(3)     NOT NULL DEFAULT 'USD',
    cap_rate_bps           integer,                -- basis points, avoids float
    day1_cashflow_minor    bigint,
    five_year_net_minor    bigint,
    hoa_monthly_minor      bigint,
    hero_image_url         text,
    analysis                jsonb      NOT NULL DEFAULT '{}'::jsonb,

    -- RESTRICTED --------------------------------------------------------
    street_address         text,
    unit_number            text,
    postal_code            text,
    latitude               numeric(9,6),
    longitude              numeric(9,6),
    parcel_id              text,
    seller_notes           text,
    restricted_analysis    jsonb       NOT NULL DEFAULT '{}'::jsonb,

    listed_at              timestamptz,
    created_at             timestamptz NOT NULL DEFAULT now(),
    updated_at             timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT property_price_nonneg
        CHECK (asking_price_minor IS NULL OR asking_price_minor >= 0),
    CONSTRAINT property_public_needs_region
        CHECK (NOT public_visible OR display_region IS NOT NULL)
);
CREATE INDEX property_browse_idx
    ON property (status, public_visible, asking_price_minor)
    WHERE public_visible AND status = 'active';
CREATE INDEX property_analysis_gin ON property USING gin (analysis);

COMMENT ON COLUMN property.display_region IS
    'Coarse location shown publicly. Must never contain street-level detail.';
COMMENT ON COLUMN property.street_address IS
    'RESTRICTED. Never selected into an unauthenticated response.';

-- ------------------------------------------------- property/party linkage
CREATE TYPE property_link_kind AS ENUM (
    'assigned_agent', 'assigned_lender', 'owner_investor', 'saved_by', 'interested'
);

CREATE TABLE property_party (
    property_id  bigint NOT NULL REFERENCES property(id) ON DELETE CASCADE,
    party_id     bigint NOT NULL REFERENCES party(id)    ON DELETE CASCADE,
    kind         property_link_kind NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (property_id, party_id, kind)
);
CREATE INDEX property_party_by_party ON property_party (party_id, kind);

-- -------------------------------------------------------------------- deals
CREATE TABLE deal (
    id             bigserial PRIMARY KEY,
    external_ref   text UNIQUE,
    property_id    bigint      REFERENCES property(id) ON DELETE SET NULL,
    investor_id    bigint      REFERENCES party(id)    ON DELETE SET NULL,
    agent_id       bigint      REFERENCES party(id)    ON DELETE SET NULL,
    pipeline       text        NOT NULL,
    stage          text        NOT NULL,
    value_minor    bigint,
    status         text        NOT NULL DEFAULT 'open',
    opened_at      timestamptz NOT NULL DEFAULT now(),
    closed_at      timestamptz,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX deal_property_idx ON deal (property_id);
CREATE INDEX deal_investor_idx ON deal (investor_id);
CREATE INDEX deal_open_idx     ON deal (pipeline, stage) WHERE status = 'open';

-- ------------------------------------------------------ updated_at trigger
CREATE OR REPLACE FUNCTION touch_updated_at() RETURNS trigger AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER property_touch BEFORE UPDATE ON property
    FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER party_touch    BEFORE UPDATE ON party
    FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER deal_touch     BEFORE UPDATE ON deal
    FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

COMMIT;
