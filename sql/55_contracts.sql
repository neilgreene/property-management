-- =====================================================================
-- 55_contracts.sql  |  agents, customers, opportunities and contracts
-- =====================================================================
-- MOCK DATA THAT WILL LATER ARRIVE FROM GOHIGHLEVEL. Customers, agents
-- and opportunities are GHL's records in the real system; contracts are
-- ours. Every table here therefore carries `external_ref`, unique and
-- nullable, so a GHL id can be written against a row that already exists
-- rather than requiring a schema change and a migration on the day the
-- integration lands. Rows created in this panel simply have it NULL.
--
-- What is genuinely new here is the LAST clause of the address gate.
-- Until now a property's address opened for an investor who had signed
-- the fee agreement -- ALL properties, on one signature, recorded once on
-- the person. A contract unlocks only the properties named on it, only
-- for the customer who holds it, and only once TWO things have happened:
-- they signed the agreement, and they paid the fee.
--
-- APPROVAL IS NOT A DECISION SOMEBODY MAKES. It is what those two facts
-- add up to. So `approved` is not a status an administrator can simply
-- select: the CHECK constraints below make an approved contract without
-- both a signature and a payment unrepresentable, and api.sign_contract()
-- and api.record_payment() are what move it -- whichever of them happens
-- second. A gate that can be opened by setting a dropdown is not a gate.
--
-- The old blanket rule still applies alongside this one. That is
-- deliberate and reversible: nothing that worked before stops working,
-- and the seeded investors keep the behaviour the existing tests assert.
-- To make contracts the only route, delete the marked line from
-- sec.can_see_address() at the foot of this file.

BEGIN;

-- ---------------------------------------------------------------------
-- Agents and customers are PEOPLE, not new entities
-- ---------------------------------------------------------------------
-- core.person already holds both: role 'agent' and role 'investor'. A
-- separate core.agent table would be a second answer to "who is this",
-- and the first thing to rot. These carry only what a person row does
-- not already have.
CREATE TABLE core.agent_profile (
    person_id    uuid PRIMARY KEY REFERENCES core.person(person_id) ON DELETE CASCADE,
    external_ref text UNIQUE,
    licence_no   text,
    brokerage    text,
    metro_code   text REFERENCES core.metro(metro_code),
    notes        text,
    updated_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE core.customer_profile (
    person_id     uuid PRIMARY KEY REFERENCES core.person(person_id) ON DELETE CASCADE,
    external_ref  text UNIQUE,
    -- The agent who looks after them. Nullable: a customer can arrive
    -- before anybody is assigned to them.
    agent_id      uuid REFERENCES core.person(person_id),
    target_metro  text REFERENCES core.metro(metro_code),
    budget_low    numeric(12,2),
    budget_high   numeric(12,2),
    notes         text,
    updated_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT budget_ordered CHECK (
        budget_low IS NULL OR budget_high IS NULL OR budget_high >= budget_low
    )
);

-- ---------------------------------------------------------------------
-- Opportunities: one customer, many properties
-- ---------------------------------------------------------------------
-- Distinct from core.deal, which is one property in one pipeline stage.
-- An opportunity is the shortlist a customer and their agent are working
-- through; deals are what individual properties on it become. Keeping
-- them apart means closing one property does not close the conversation.
CREATE TABLE core.opportunity (
    opportunity_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    external_ref   text UNIQUE,
    person_id      uuid NOT NULL REFERENCES core.person(person_id) ON DELETE RESTRICT,
    agent_id       uuid REFERENCES core.person(person_id),
    title          text NOT NULL,
    status         text NOT NULL DEFAULT 'open'
                   CHECK (status IN ('open','won','lost')),
    notes          text,
    created_at     timestamptz NOT NULL DEFAULT now(),
    created_by     uuid REFERENCES core.person(person_id),
    closed_at      timestamptz,
    CONSTRAINT opportunity_closed_consistent CHECK (
        (status = 'open') = (closed_at IS NULL)
    )
);
CREATE INDEX ix_opportunity_person ON core.opportunity (person_id);
CREATE INDEX ix_opportunity_agent  ON core.opportunity (agent_id);

CREATE TABLE core.opportunity_property (
    opportunity_id uuid NOT NULL REFERENCES core.opportunity(opportunity_id) ON DELETE CASCADE,
    property_id    uuid NOT NULL REFERENCES core.property(property_id) ON DELETE RESTRICT,
    added_at       timestamptz NOT NULL DEFAULT now(),
    added_by       uuid REFERENCES core.person(person_id),
    PRIMARY KEY (opportunity_id, property_id)
);
CREATE INDEX ix_opp_property ON core.opportunity_property (property_id);

-- ---------------------------------------------------------------------
-- Contracts: what actually unlocks a property
-- ---------------------------------------------------------------------
-- A customer may hold many. Each covers one or more properties. Only
-- 'approved' opens anything, and only for the person named on it.
CREATE TABLE core.contract (
    contract_id    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    external_ref   text UNIQUE,
    reference      text NOT NULL UNIQUE,
    person_id      uuid NOT NULL REFERENCES core.person(person_id) ON DELETE RESTRICT,
    -- The opportunity it came out of, when it came out of one.
    opportunity_id uuid REFERENCES core.opportunity(opportunity_id) ON DELETE SET NULL,
    status         text NOT NULL DEFAULT 'draft'
                   CHECK (status IN ('draft','sent','approved','declined','withdrawn')),
    -- The fee for THIS contract. The $750 on core.person was one payment
    -- for the whole platform; this is per contract, which is what lets a
    -- customer hold several at different stages.
    fee_amount     numeric(12,2),
    notes          text,
    created_at     timestamptz NOT NULL DEFAULT now(),
    created_by     uuid REFERENCES core.person(person_id),

    -- THE TWO FACTS. Everything about access follows from these.
    sent_at        timestamptz,
    signed_at      timestamptz,
    paid_at        timestamptz,
    payment_ref    text,

    -- Bookkeeping for the moment they were both true.
    approved_at    timestamptz,
    decided_by     uuid REFERENCES core.person(person_id),
    decided_reason text,

    -- An approved contract MUST have both. Not a rule the application
    -- remembers to apply -- a row that says otherwise cannot be written,
    -- by this panel, by a migration, or by anybody at a psql prompt.
    CONSTRAINT contract_approved_needs_both CHECK (
        status <> 'approved'
        OR (signed_at IS NOT NULL AND paid_at IS NOT NULL AND approved_at IS NOT NULL)
    ),
    -- And the converse: having both is what approved MEANS. Without this
    -- a signed, paid contract could sit in 'sent' and the two states
    -- would disagree about whether the customer is in.
    CONSTRAINT contract_both_means_approved CHECK (
        NOT (signed_at IS NOT NULL AND paid_at IS NOT NULL
             AND status NOT IN ('approved','declined','withdrawn'))
    ),
    -- You cannot sign or pay for something never sent to you.
    CONSTRAINT contract_signed_after_sent CHECK (
        signed_at IS NULL OR sent_at IS NOT NULL
    ),
    CONSTRAINT contract_paid_after_sent CHECK (
        paid_at IS NULL OR sent_at IS NOT NULL
    )
);
CREATE INDEX ix_contract_person ON core.contract (person_id);
CREATE INDEX ix_contract_status ON core.contract (status);

CREATE TABLE core.contract_property (
    contract_id uuid NOT NULL REFERENCES core.contract(contract_id) ON DELETE CASCADE,
    property_id uuid NOT NULL REFERENCES core.property(property_id) ON DELETE RESTRICT,
    added_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (contract_id, property_id)
);
CREATE INDEX ix_contract_property_prop ON core.contract_property (property_id);

-- Append-only: what a contract's status was, when, and who moved it.
-- Approval is the event that opens protected data, so it is the one
-- thing on this table that must not be quietly editable afterwards.
CREATE TABLE core.contract_history (
    id          bigserial PRIMARY KEY,
    contract_id uuid NOT NULL REFERENCES core.contract(contract_id) ON DELETE CASCADE,
    event       text NOT NULL
                CHECK (event IN ('created','sent','signed','paid','approved',
                                 'declined','withdrawn','property_added',
                                 'property_removed')),
    from_status text,
    to_status   text,
    changed_at  timestamptz NOT NULL DEFAULT now(),
    changed_by  uuid REFERENCES core.person(person_id),
    detail      text
);
CREATE INDEX ix_contract_history ON core.contract_history (contract_id, changed_at);

-- ---------------------------------------------------------------------
-- RLS. Same posture as everything else in core: forced, and reachable
-- only through api definer functions. No application role holds USAGE on
-- this schema, so these are belt and braces -- which is the point.
-- ---------------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['agent_profile','customer_profile','opportunity',
                           'opportunity_property','contract','contract_property',
                           'contract_history']
  LOOP
    EXECUTE format('ALTER TABLE core.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE core.%I FORCE  ROW LEVEL SECURITY', t);
  END LOOP;
END $$;

-- ---------------------------------------------------------------------
-- THE GATE
-- ---------------------------------------------------------------------
-- An approved contract naming this property, held by the caller.
-- SECURITY DEFINER because no application role can read core.
CREATE FUNCTION sec.has_approved_contract(p_property_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1
      FROM core.contract c
      JOIN core.contract_property cp ON cp.contract_id = c.contract_id
     WHERE cp.property_id = p_property_id
       AND c.person_id    = sec.actor_id()
       AND c.status       = 'approved'
  );
$$;

-- Replaced, not redefined: the signature is unchanged, so the views in
-- 03_views.sql that call it keep working untouched.
CREATE OR REPLACE FUNCTION sec.can_see_address(p_property_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $$
  SELECT sec.is_internal()
      OR sec.is_assigned(p_property_id)
      -- THE BLANKET UNLOCK. Delete this one line to make an approved
      -- contract the only route to an address for a customer.
      OR (sec.actor_role() = 'investor' AND sec.fee_agreement_signed())
      OR sec.has_approved_contract(p_property_id);
$$;

REVOKE ALL ON FUNCTION sec.has_approved_contract(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sec.has_approved_contract(uuid)
  TO sdi_public, sdi_investor, sdi_agent, sdi_admin;

COMMIT;
