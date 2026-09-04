-- =====================================================================
-- 47_share.sql  |  sharing a listing as a document
-- =====================================================================
-- A shared PDF is different in kind from a screen, and the difference is
-- the whole reason this file is careful.
--
-- A SCREEN IS REVOCABLE AND A DOCUMENT IS NOT. Everything else in this
-- system decides, per request, whether this caller may see an address --
-- and if the answer changes tomorrow, tomorrow's answer is the one that
-- applies. A PDF is a copy taken once and kept forever. It is forwarded,
-- printed, attached to an email, and dropped in a shared drive. Nothing
-- in this database can reach it again. So the decision made at the moment
-- of generation is permanent, and it is made conservatively.
--
-- MASKED BY DEFAULT, ALWAYS. Not "masked for people who cannot see the
-- address" -- masked for EVERYONE, including staff, unless the person
-- generating it deliberately says otherwise for that one document. The
-- common case is sending a property to somebody who has signed nothing,
-- and a default that leaks on the common case is not a default, it is a
-- trap. Somebody who wants to send the real thing has to say so.
--
-- TWO LAYERS, AND THEY ARE NOT THE SAME LAYER.
--
--   The floor is the gate. A caller who cannot see the address cannot
--   obtain an unmasked document by asking for one. The checkbox is a
--   REQUEST; sec.can_see_address() is the answer. If the two disagree,
--   the database wins and the document is masked.
--
--   The ceiling is the default. A caller who CAN see the address still
--   gets a masked document unless they asked for otherwise.
--
-- Written as `requested AND permitted` in one place, so there is no path
-- that consults only one of them.

BEGIN;

-- ---------------------------------------------------------------------
-- The record
-- ---------------------------------------------------------------------
-- Every generated document, and whether it carried the address. This is
-- the only trace an exported PDF leaves; without it, "who sent that
-- address out" has no answer at all, and the question gets asked exactly
-- once, under pressure, months later.
CREATE TABLE core.share_event (
    share_id     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    property_id  uuid NOT NULL REFERENCES core.property(property_id) ON DELETE CASCADE,
    shared_by    uuid REFERENCES core.person(person_id),
    unmasked     boolean     NOT NULL,
    -- WHO IT WENT TO. Required, and self-reported -- this system hands the
    -- file to a browser and has no idea what happens next, so the honest
    -- description is "who the sender says they sent it to". That is still
    -- the difference between a log that can answer the question and one
    -- that cannot. A minimum length, because a required field that accepts
    -- "." is an optional field wearing a costume.
    recipient    text        NOT NULL CHECK (length(btrim(recipient)) >= 3),
    created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_share_property ON core.share_event (property_id, created_at DESC);
CREATE INDEX ix_share_unmasked ON core.share_event (created_at DESC) WHERE unmasked;

ALTER TABLE core.share_event ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.share_event FORCE  ROW LEVEL SECURITY;

-- Staff read the log; nobody writes it directly. The definer function
-- below is the only way a row appears, so a share cannot be generated
-- without one -- which is the point of having it.
CREATE POLICY share_read ON core.share_event FOR SELECT
    TO sdi_agent, sdi_admin
    USING (sec.is_internal() OR sec.is_assigned(property_id));

-- A policy is not a grant. The policy above says WHICH rows, and without a
-- GRANT there are no rows to filter -- api.share_log is security_invoker, so
-- the privilege is checked as the caller, not as the view's owner. Missing
-- this produced "permission denied for table share_event" from a screen that
-- had every policy it needed.
GRANT SELECT ON core.share_event TO sdi_agent, sdi_admin;

COMMENT ON TABLE core.share_event IS
    'One row per generated document. A PDF leaves this system permanently, '
    'so the moment of generation is the only moment it can be recorded.';

-- ---------------------------------------------------------------------
-- What may this document say?
-- ---------------------------------------------------------------------
-- One function, one answer, consulted once. The web tier does not get to
-- assemble this decision from parts.
CREATE FUNCTION api.share_context(p_property_id uuid, p_unmask boolean DEFAULT false)
RETURNS TABLE (
    may_unmask   boolean,   -- is this caller allowed to, at all
    unmasked     boolean,   -- and did they ask, and are they therefore getting it
    mask_url     text,      -- the stand-in image, when masked
    mask_thumb   text
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $fn$
DECLARE v_may boolean;
BEGIN
  -- A property the caller cannot see at all is not a property they can
  -- share. Checked before anything else so a bad id and a forbidden id
  -- are the same answer -- otherwise this becomes a way to test whether
  -- a listing exists.
  IF NOT EXISTS (SELECT 1 FROM api.property WHERE property_id = p_property_id) THEN
    RETURN;
  END IF;

  v_may := sec.can_see_address(p_property_id);

  RETURN QUERY
  SELECT v_may,
         -- The whole rule, in one expression. `requested AND permitted`:
         -- a checkbox cannot open the gate and the gate does not open
         -- itself.
         COALESCE(p_unmask, false) AND v_may,
         m.url, m.thumb_url
    FROM sec.mask_for(p_property_id) m;
END;
$fn$;

-- ---------------------------------------------------------------------
-- Recording it
-- ---------------------------------------------------------------------
-- Takes the EFFECTIVE decision, not the requested one, because what
-- matters afterwards is what the document actually contained.
CREATE FUNCTION api.record_share(p_property_id uuid, p_unmasked boolean,
                                 p_recipient text)
RETURNS uuid
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $fn$
DECLARE v_id uuid;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM api.property WHERE property_id = p_property_id) THEN
    RAISE EXCEPTION 'no such property' USING ERRCODE = '42501';
  END IF;
  IF length(btrim(COALESCE(p_recipient, ''))) < 3 THEN
    RAISE EXCEPTION 'say who this is going to';
  END IF;
  -- Belt and braces: this function is what writes the record, so it
  -- refuses to record an unmasked share the caller could not have had.
  -- If that ever fires, the web tier has a bug worth stopping for.
  IF p_unmasked AND NOT sec.can_see_address(p_property_id) THEN
    RAISE EXCEPTION 'an unmasked document cannot be recorded for a caller '
                    'who may not see the address' USING ERRCODE = '42501';
  END IF;

  INSERT INTO core.share_event (property_id, shared_by, unmasked, recipient)
  VALUES (p_property_id, sec.actor_id(), p_unmasked, btrim(p_recipient))
  RETURNING share_id INTO v_id;
  RETURN v_id;
END;
$fn$;

-- The log, for staff. Read through a view so the underlying table keeps
-- no grants of its own.
CREATE VIEW api.share_log
WITH (security_invoker = true, security_barrier = true) AS
SELECT s.share_id, s.property_id, p.listing_ref,
       sec.actor_name(s.shared_by) AS shared_by,
       s.shared_by AS shared_by_id,
       s.unmasked, s.recipient, s.created_at
FROM core.share_event s
JOIN api.property p ON p.property_id = s.property_id
ORDER BY s.created_at DESC;

REVOKE ALL ON FUNCTION api.share_context(uuid, boolean),
                       api.record_share(uuid, boolean, text) FROM PUBLIC;
-- Sharing is not a staff-only act: an investor past the fee gate sending a
-- listing to their own accountant is the ordinary case. What differs by
-- role is whether the document may carry the address, and that is decided
-- inside, not by who holds EXECUTE.
GRANT EXECUTE ON FUNCTION api.share_context(uuid, boolean),
                          api.record_share(uuid, boolean, text)
    TO sdi_public, sdi_investor, sdi_agent, sdi_admin;
GRANT SELECT ON api.share_log TO sdi_agent, sdi_admin;

COMMIT;
