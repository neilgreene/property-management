-- =====================================================================
-- 43_property_notes.sql  |  notes, with a name and a time on them
-- =====================================================================
-- core.property.internal_notes and property_detail.description already
-- exist, and they are FIELDS: one blob each, overwritten on every save,
-- with no author and no date. That is right for listing copy -- the
-- description is a single piece of prose somebody edits until it reads
-- well -- and wrong for everything else people actually write down.
--
-- A note is a different thing. "Seller will not budge below 295" and
-- "roof quoted at 8k, waiting on the second quote" are observations made
-- at a moment by a person, and they accumulate. Keeping them in a field
-- means the second person to write one destroys the first, and nobody can
-- tell who said what or when. So notes are rows.
--
-- TWO VISIBILITIES, and the difference is who can read them:
--
--   public    band 1. Shown on the listing to anyone who can see it,
--             including a visitor who has signed nothing. This is the
--             "General Notes About This Property" the workbook prints.
--   internal  band 3. Staff only, on the same predicate as the offer and
--             the acquisition cost.
--
-- A PUBLIC NOTE IS A PUBLICATION. It is as visible as the description, so
-- an address typed into one is an address disclosed -- the gate protects
-- the street_address column, not prose that happens to mention it. The
-- panel says so at the point of writing, which is the only place a warning
-- is any use.
--
-- Notes are never hard-deleted. Removing one sets deleted_at: the note
-- leaves the listing and the record of it having existed does not, because
-- "who deleted the note saying the roof was failing" is a question that
-- gets asked exactly when the answer matters.

BEGIN;

CREATE TABLE core.property_note (
    note_id     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    property_id uuid NOT NULL REFERENCES core.property(property_id) ON DELETE CASCADE,
    visibility  text NOT NULL CHECK (visibility IN ('public', 'internal')),
    body        text NOT NULL CHECK (length(btrim(body)) > 0),
    author_id   uuid REFERENCES core.person(person_id),
    created_at  timestamptz NOT NULL DEFAULT now(),
    edited_at   timestamptz,
    deleted_at  timestamptz,
    deleted_by  uuid REFERENCES core.person(person_id)
);

CREATE INDEX ix_note_property ON core.property_note (property_id, created_at DESC)
  WHERE deleted_at IS NULL;

COMMENT ON COLUMN core.property_note.visibility IS
    'public: shown on the listing to everyone who can see it, signed in or '
    'not. internal: staff only, band 3 with the offer and the acquisition '
    'cost. There is no middle setting on purpose -- a note that is "sort of '
    'public" is a note somebody will be surprised by.';

ALTER TABLE core.property_note ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.property_note FORCE  ROW LEVEL SECURITY;

CREATE POLICY note_read ON core.property_note FOR SELECT USING (
  deleted_at IS NULL
  AND EXISTS (SELECT 1 FROM api.property v
               WHERE v.property_id = core.property_note.property_id)
  AND (visibility = 'public'
       OR sec.can_manage_media(core.property_note.property_id))
);

GRANT SELECT ON core.property_note
    TO sdi_public, sdi_investor, sdi_agent, sdi_admin;

-- ---------------------------------------------------------------------
-- The view the application reads
-- ---------------------------------------------------------------------
CREATE VIEW api.property_note
WITH (security_invoker = true, security_barrier = true) AS
SELECT n.note_id, n.property_id, n.visibility, n.body,
       n.created_at, n.edited_at,
       sec.actor_name(n.author_id) AS author,
       n.author_id = sec.actor_id() AS is_mine
FROM core.property_note n
ORDER BY n.created_at DESC;

GRANT SELECT ON api.property_note
    TO sdi_public, sdi_investor, sdi_agent, sdi_admin;

-- sec.actor_name is granted to staff only; a public reader needs it to see
-- who wrote a public note, which is the point of attributing them.
GRANT EXECUTE ON FUNCTION sec.actor_name(uuid)
    TO sdi_public, sdi_investor;

-- ---------------------------------------------------------------------
-- Writing
--
-- Staff only, both visibilities. An investor commenting on a listing is a
-- different feature with different rules -- moderation, notification, who
-- else can see it -- and quietly allowing it here would create it by
-- accident.
-- ---------------------------------------------------------------------
CREATE FUNCTION api.add_note(p_property_id uuid, p_body text,
                             p_visibility text DEFAULT 'internal')
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
  IF p_visibility NOT IN ('public', 'internal') THEN
    RAISE EXCEPTION 'a note is public or internal, not %', p_visibility;
  END IF;
  IF length(btrim(COALESCE(p_body, ''))) = 0 THEN
    RAISE EXCEPTION 'an empty note is not a note';
  END IF;

  INSERT INTO core.property_note (property_id, visibility, body, author_id)
  VALUES (p_property_id, p_visibility, btrim(p_body), sec.actor_id())
  RETURNING note_id INTO v_id;
  RETURN v_id;
END;
$fn$;

-- Editing is the author's, or an admin's. Not any staff member's: a note
-- is somebody's statement, and quietly rewriting one under their name is
-- worse than leaving it and adding a correction underneath.
CREATE FUNCTION api.edit_note(p_note_id uuid, p_body text)
RETURNS boolean
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $fn$
DECLARE v_author uuid; v_prop uuid;
BEGIN
  SELECT author_id, property_id INTO v_author, v_prop
    FROM core.property_note WHERE note_id = p_note_id AND deleted_at IS NULL;
  IF v_prop IS NULL THEN RETURN false; END IF;
  IF NOT (v_author = sec.actor_id() OR sec.is_internal()) THEN
    RAISE EXCEPTION 'only the author or an admin may edit a note'
      USING ERRCODE = '42501';
  END IF;
  IF length(btrim(COALESCE(p_body, ''))) = 0 THEN
    RAISE EXCEPTION 'an empty note is not a note';
  END IF;

  UPDATE core.property_note
     SET body = btrim(p_body), edited_at = now()
   WHERE note_id = p_note_id;
  RETURN true;
END;
$fn$;

CREATE FUNCTION api.delete_note(p_note_id uuid)
RETURNS boolean
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $fn$
DECLARE v_author uuid; v_prop uuid;
BEGIN
  SELECT author_id, property_id INTO v_author, v_prop
    FROM core.property_note WHERE note_id = p_note_id AND deleted_at IS NULL;
  IF v_prop IS NULL THEN RETURN false; END IF;
  IF NOT (v_author = sec.actor_id() OR sec.is_internal()) THEN
    RAISE EXCEPTION 'only the author or an admin may remove a note'
      USING ERRCODE = '42501';
  END IF;
  -- Soft. The note leaves the listing; the fact that it was written and
  -- by whom does not.
  UPDATE core.property_note
     SET deleted_at = now(), deleted_by = sec.actor_id()
   WHERE note_id = p_note_id;
  RETURN true;
END;
$fn$;

REVOKE ALL ON FUNCTION api.add_note(uuid, text, text),
                       api.edit_note(uuid, text),
                       api.delete_note(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.add_note(uuid, text, text),
                          api.edit_note(uuid, text),
                          api.delete_note(uuid) TO sdi_agent, sdi_admin;

COMMIT;
