-- =====================================================================
-- 54_manager_contact.sql  |  who to call, and a task to call them
-- =====================================================================
-- core.property_manager held a name and nothing else, so the panel could
-- say WHO manages a property and not how to reach them. This adds the
-- contact record, and turns "chase the manager" from a thing somebody
-- remembers into a note with an owner and a due date.
--
-- THE FOLLOW-UP IS A NOTE, NOT A NEW KIND OF THING. Notes already carry
-- an author, a timestamp, a severity, a visibility and a resolution.
-- A task is a note with somebody's name on it and a date -- so it gets
-- two columns rather than a parallel table with its own lifecycle to
-- keep in step. One stream on the property, in the order things
-- happened, which is how anybody reading it actually wants it.
--
-- EMAIL AND TEXT ARE HANDOFFS, NOT SENDS. The buttons open the
-- operator's own mail or messaging client with the property already in
-- the subject line. This system does not send anything: it has no mail
-- transport, no SMS provider, and -- more to the point -- no consent
-- record. TCPA consent for a text message is neither captured nor
-- evidenced anywhere here, and a platform that starts texting people
-- because a button existed is a platform with a problem it cannot prove
-- its way out of. A mailto: hands the message to a human who is
-- accountable for sending it.

BEGIN;

ALTER TABLE core.property_manager
    ADD COLUMN contact_name text,
    ADD COLUMN email        text,
    ADD COLUMN phone        text,
    ADD COLUMN website      text,
    -- Free text on purpose. "Mon-Thu, prefers text" is more useful than
    -- any set of columns modelling office hours, and does not go stale
    -- into a lie the way structured hours do.
    ADD COLUMN reach_note   text;

COMMENT ON COLUMN core.property_manager.email IS
    'For a mailto: handoff to a human. Nothing here sends mail.';

-- Demo contacts, so the panel has something to show. Marked unconfirmed
-- for the same reason the managers themselves are: nobody has verified
-- these and the column says so rather than letting them pass as fact.
UPDATE core.property_manager SET
    contact_name = CASE manager_id WHEN 'OS' THEN 'Dana Whitlock'
                                   WHEN 'SH' THEN 'Ray Sandoval' END,
    email        = CASE manager_id WHEN 'OS' THEN 'dana@example-os.com'
                                   WHEN 'SH' THEN 'ray@example-sh.com' END,
    phone        = CASE manager_id WHEN 'OS' THEN '+1 816 555 0142'
                                   WHEN 'SH' THEN '+1 816 555 0177' END,
    reach_note   = CASE manager_id WHEN 'OS' THEN 'Weekdays, prefers email'
                                   WHEN 'SH' THEN 'Prefers a text first' END
WHERE manager_id IN ('OS', 'SH');

-- ---------------------------------------------------------------------
-- A note that is also a task
-- ---------------------------------------------------------------------
ALTER TABLE core.property_note
    ADD COLUMN assigned_to uuid REFERENCES core.person(person_id),
    ADD COLUMN due_on      date,
    -- Who it concerns, when the follow-up is with a manager rather than
    -- a colleague. Recorded so "we chased OS about this" survives the
    -- person who chased them.
    ADD COLUMN about_manager text REFERENCES core.property_manager(manager_id);

CREATE INDEX ix_note_assigned ON core.property_note (assigned_to, due_on)
  WHERE deleted_at IS NULL AND resolved_at IS NULL;

COMMENT ON COLUMN core.property_note.assigned_to IS
    'A note with somebody''s name on it is a task. Same stream, same '
    'resolution, same audit -- not a parallel table with its own lifecycle.';

-- ---------------------------------------------------------------------
-- Reading the manager behind a metro
-- ---------------------------------------------------------------------
-- The existing view, with the contact columns appended. Rebuilt from
-- 41_property_manager.sql rather than rewritten from memory -- and the
-- fee join is keyed on METRO_CODE, not manager_id: the same manager may
-- charge differently in two metros, which is the entire reason the model
-- is metro x manager rather than one or the other.
CREATE OR REPLACE VIEW api.metro
WITH (security_invoker = true, security_barrier = true) AS
SELECT m.metro_code, m.label, m.kind, m.metro_name, m.state, m.arrangement,
       m.sort_order, m.active, m.classified, m.note,
       m.manager_id, pm.name AS manager_name,
       f.schedule_id       AS current_schedule_id,
       f.effective_from    AS current_effective_from,
       f.management_fee_bps, f.leasing_fee_monthly, f.monthly_flat_fee,
       -- Appended at the END. CREATE OR REPLACE VIEW may only add columns
       -- there, and every consumer of the existing ones keeps working.
       pm.contact_name AS manager_contact,
       pm.email        AS manager_email,
       pm.phone        AS manager_phone,
       pm.website      AS manager_website,
       pm.reach_note   AS manager_reach_note,
       pm.established  AS manager_established
FROM core.metro m
LEFT JOIN core.property_manager pm ON pm.manager_id = m.manager_id
LEFT JOIN LATERAL (
  SELECT * FROM core.fee_schedule s
   WHERE s.metro_code = m.metro_code AND s.effective_from <= current_date
   ORDER BY s.effective_from DESC LIMIT 1) f ON true
ORDER BY m.sort_order;

GRANT SELECT ON api.metro TO sdi_agent, sdi_admin;

-- ---------------------------------------------------------------------
-- Raising a follow-up
-- ---------------------------------------------------------------------
-- A thin wrapper over the note machinery rather than a second write
-- path: it exists so the panel does not have to know that a task is a
-- note with two more columns.
CREATE FUNCTION api.add_task(p_property_id uuid, p_body text,
                             p_assigned_to uuid DEFAULT NULL,
                             p_due_on date DEFAULT NULL,
                             p_about_manager text DEFAULT NULL,
                             p_severity text DEFAULT 'attention')
RETURNS uuid
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $fn$
DECLARE v_id uuid;
BEGIN
  IF NOT sec.can_manage_media(p_property_id) THEN
    RAISE EXCEPTION 'not authorised to add notes to this property'
      USING ERRCODE = '42501';
  END IF;
  IF length(btrim(COALESCE(p_body, ''))) = 0 THEN
    RAISE EXCEPTION 'an empty note is not a note';
  END IF;
  IF p_severity NOT IN ('note', 'attention', 'critical') THEN
    RAISE EXCEPTION 'a note is note, attention or critical, not %', p_severity;
  END IF;
  -- A task nobody owns is a wish. Defaulting the assignee to whoever
  -- raised it is better than allowing an ownerless one: they can hand it
  -- on, and meanwhile it is somebody's.
  INSERT INTO core.property_note
    (property_id, visibility, body, severity, author_id,
     assigned_to, due_on, about_manager)
  VALUES (p_property_id, 'internal', btrim(p_body), p_severity, sec.actor_id(),
          COALESCE(p_assigned_to, sec.actor_id()), p_due_on,
          NULLIF(btrim(COALESCE(p_about_manager, '')), ''))
  RETURNING note_id INTO v_id;
  RETURN v_id;
END;
$fn$;

CREATE OR REPLACE VIEW api.property_note
WITH (security_invoker = true, security_barrier = true) AS
SELECT n.note_id, n.property_id, n.visibility, n.body,
       n.created_at, n.edited_at,
       sec.actor_name(n.author_id) AS author,
       n.author_id = sec.actor_id() AS is_mine,
       n.author_id,
       n.severity,
       n.resolved_at, n.resolution,
       CASE WHEN n.resolved_by IS NULL THEN NULL
            ELSE sec.actor_name(n.resolved_by) END AS resolved_by_name,
       (n.severity <> 'note' AND n.resolved_at IS NULL) AS is_open,
       n.assigned_to,
       CASE WHEN n.assigned_to IS NULL THEN NULL
            ELSE sec.actor_name(n.assigned_to) END AS assigned_to_name,
       n.due_on,
       n.about_manager,
       -- Overdue is derived, never stored. A stored flag is wrong from
       -- the moment the clock passes it until something updates it.
       (n.due_on IS NOT NULL AND n.resolved_at IS NULL
        AND n.deleted_at IS NULL AND n.due_on < current_date) AS overdue
FROM core.property_note n
ORDER BY n.created_at DESC;

REVOKE ALL ON FUNCTION api.add_task(uuid, text, uuid, date, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.add_task(uuid, text, uuid, date, text, text)
    TO sdi_agent, sdi_admin;

-- Who a task can be given to: internal people only. A follow-up assigned
-- to a customer is not a follow-up.
CREATE FUNCTION api.colleagues()
RETURNS TABLE (person_id uuid, full_name text, role text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $$
  SELECT p.person_id, p.full_name, p.role::text
    FROM core.person p
   WHERE p.role IN ('agent', 'admin') AND p.active
     AND sec.is_internal()
   ORDER BY p.full_name;
$$;

REVOKE ALL ON FUNCTION api.colleagues() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.colleagues() TO sdi_agent, sdi_admin;

COMMIT;
