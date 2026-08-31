-- =====================================================================
-- 01_schema.sql  |  SDI property marketplace - base schema and roles
-- PostgreSQL 16+ (security_invoker views require 15+)
-- =====================================================================
-- Oracle mapping cheat sheet:
--   VPD row predicate        -> RLS POLICY ... USING (...)
--   SYS_CONTEXT app context  -> current_setting('app.*', true) / set_config()
--   VPD column masking       -> CASE in a security_invoker view (no native equiv)
--   Definer-rights procedure -> FUNCTION ... SECURITY DEFINER
--   Database Vault realm     -> schema separation + REVOKE + definer-rights fns
-- =====================================================================

DROP SCHEMA IF EXISTS core CASCADE;
DROP SCHEMA IF EXISTS sec  CASCADE;
DROP SCHEMA IF EXISTS api  CASCADE;

CREATE SCHEMA core;   -- base tables. App roles never get USAGE here.
CREATE SCHEMA sec;    -- security predicates. Definer-rights, USAGE granted.
CREATE SCHEMA api;    -- masking views. The only surface apps read.

-- Why three schemas and not two: a security_invoker view resolves the
-- FUNCTIONS it calls as the caller too, not just the tables. So the
-- predicate functions cannot live in core -- the app roles would need
-- USAGE on core to call them, and that USAGE is precisely what stops
-- them reading core.property directly and skipping the column masking.
-- Splitting predicates into sec keeps the table schema sealed.

-- ---------------------------------------------------------------------
-- Roles
-- ---------------------------------------------------------------------
-- sdi_app is the single role the web tier connects as. It is NOINHERIT,
-- so it holds no privileges of its own -- it must SET ROLE into exactly
-- one persona role per transaction. This is the choke point: the app
-- cannot "forget" to assume a role and accidentally run as a superuser.

DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['sdi_app','sdi_public','sdi_investor','sdi_agent','sdi_admin']
  LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('CREATE ROLE %I NOLOGIN', r);
    END IF;
  END LOOP;
END $$;

ALTER ROLE sdi_app WITH LOGIN PASSWORD 'demo_app_pw' NOINHERIT;

GRANT sdi_public, sdi_investor, sdi_agent, sdi_admin TO sdi_app;

GRANT USAGE ON SCHEMA api, sec TO sdi_public, sdi_investor, sdi_agent, sdi_admin;
-- Deliberately NOT granting USAGE on core. Even holding a column-level
-- SELECT grant, an app role cannot name a base table without schema
-- USAGE -- name resolution fails before any ACL or policy is consulted.

-- ---------------------------------------------------------------------
-- Reference data
-- ---------------------------------------------------------------------
CREATE TABLE core.brand (
    brand_code      text PRIMARY KEY,
    display_name    text NOT NULL,
    -- Brand is a *lens*, not a property attribute. Both brands read the
    -- same core.property rows; what differs is publication, pricing and
    -- which fields the lens exposes.
    service_tier    text NOT NULL CHECK (service_tier IN ('self_service','concierge')),
    platform_fee    numeric(10,2) NOT NULL
);

CREATE TYPE sec.actor_role AS ENUM ('public','investor','agent','admin');

CREATE TABLE core.person (
    person_id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    role                    sec.actor_role NOT NULL,
    full_name               text NOT NULL,
    email                   text NOT NULL UNIQUE,
    -- The $750 gate. Note this is a *data* predicate, not a role grant --
    -- which is what lets the same mechanism serve the KAVADOO tier later.
    fee_agreement_signed_at timestamptz,
    home_brand              text REFERENCES core.brand(brand_code),
    active                  boolean NOT NULL DEFAULT true
);

-- ---------------------------------------------------------------------
-- The core entity
-- ---------------------------------------------------------------------
-- One row per property. Three visibility bands live side by side in this
-- table and are separated by policy, not by copying rows into three tables.
--   band 1 PUBLIC   - marketing-safe, address suppressed
--   band 2 GATED    - unlocked by signed fee agreement (or assignment)
--   band 3 INTERNAL - never leaves staff
CREATE TABLE core.property (
    property_id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    listing_ref       text NOT NULL UNIQUE,

    -- band 1: public
    status            text NOT NULL CHECK (status IN
                        ('draft','active','coming_soon','pending','sold','withdrawn')),
    city              text NOT NULL,
    state             char(2) NOT NULL,
    zip               text NOT NULL,
    property_type     text NOT NULL,
    beds              smallint,
    baths             numeric(3,1),
    sqft              integer,
    year_built        smallint,
    list_price        numeric(12,2) NOT NULL,
    gross_rent_annual numeric(12,2) NOT NULL,
    opex_annual       numeric(12,2) NOT NULL,
    hoa_annual        numeric(12,2) NOT NULL DEFAULT 0,

    -- Derived, never stored as an independent input. If an assumption
    -- changes the metric moves with it; there is no second copy to drift.
    noi_annual        numeric(12,2)
                        GENERATED ALWAYS AS
                        (gross_rent_annual - opex_annual - hoa_annual) STORED,
    cap_rate          numeric(6,4)
                        GENERATED ALWAYS AS
                        ((gross_rent_annual - opex_annual - hoa_annual)
                         / NULLIF(list_price,0)) STORED,

    -- band 2: gated behind the fee agreement
    street_address    text NOT NULL,
    unit              text,
    lat               numeric(9,6) NOT NULL,
    lng               numeric(9,6) NOT NULL,
    parcel_number     text,
    seller_disclosure text,

    -- band 3: internal only
    acquisition_cost  numeric(12,2),
    source_channel    text,
    internal_notes    text,

    created_at        timestamptz NOT NULL DEFAULT now()
);

-- Which brands a property is published on, and at what price/tier.
-- This table is the entire dual-brand mechanism. Adding KAVADOO is
-- INSERTs here plus one policy predicate -- not a schema refactor.
CREATE TABLE core.property_brand (
    property_id   uuid NOT NULL REFERENCES core.property(property_id) ON DELETE CASCADE,
    brand_code    text NOT NULL REFERENCES core.brand(brand_code),
    published     boolean NOT NULL DEFAULT false,
    brand_price   numeric(12,2),   -- premium markup for the concierge brand
    PRIMARY KEY (property_id, brand_code)
);

CREATE TABLE core.property_assignment (
    property_id uuid NOT NULL REFERENCES core.property(property_id) ON DELETE CASCADE,
    person_id   uuid NOT NULL REFERENCES core.person(person_id),
    assign_role text NOT NULL CHECK (assign_role IN ('agent','lender','investor')),
    PRIMARY KEY (property_id, person_id, assign_role)
);

-- Supports the per-row agent predicate without a sequential scan.
CREATE INDEX ix_assignment_person ON core.property_assignment (person_id, property_id);

CREATE TABLE core.saved_property (
    person_id   uuid NOT NULL REFERENCES core.person(person_id),
    property_id uuid NOT NULL REFERENCES core.property(property_id) ON DELETE CASCADE,
    saved_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (person_id, property_id)
);
