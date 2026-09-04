-- =====================================================================
-- 46_note_severity.sql  |  a flag on the property, from its open notes
-- =====================================================================
-- Not every note is the same weight. "Called the agent, waiting on the
-- roof quote" and "failed inspection, falling out of escrow" both sit in
-- the same list and only one of them should stop somebody's morning.
--
-- Three levels, and the middle one earns its place: without it everything
-- that is not a disaster is ordinary, so people mark things critical to
-- get them noticed and the red flag stops meaning anything.
--
--   note       the ordinary record of what happened.
--   attention  somebody has to do something. Chase the agent, get the
--              second quote, confirm the rental restrictions.
--   critical   the deal is in trouble. Failed inspection, falling out of
--              escrow, a title problem.
--
-- SEVERITY WITHOUT RESOLUTION IS A RATCHET. A critical note written in
-- March is still critical in June unless somebody can say it was dealt
-- with -- so every note above `note` can be resolved, by whom and when is
-- recorded, and the property's flag is computed from what is still OPEN.
-- A green flag then means "nothing outstanding", which is a claim somebody
-- has actually made, rather than "nobody has written anything alarming
-- lately", which is not.
--
-- The flag is derived from the notes THE CALLER CAN SEE, which falls out
-- of the row policy rather than being decided again. In practice critical
-- notes are internal, so a buyer's flag is computed over public notes and
-- is almost always green -- which is why the UI shows it on staff screens
-- only. A green flag on a listing page reads as an assurance, and this
-- system is not in a position to give one.

BEGIN;

ALTER TABLE core.property_note
    ADD COLUMN severity text NOT NULL DEFAULT 'note'
        CHECK (severity IN ('note', 'attention', 'critical')),
    ADD COLUMN resolved_at timestamptz,
    ADD COLUMN resolved_by uuid REFERENCES core.person(person_id),
    ADD COLUMN resolution  text,
    -- Resolving something that was never raised is a contradiction, and
    -- storing one produces a flag nobody can explain.
    ADD CONSTRAINT note_resolvable CHECK (
        resolved_at IS NULL OR severity <> 'note');

CREATE INDEX ix_note_open ON core.property_note (property_id, severity)
  WHERE deleted_at IS NULL AND resolved_at IS NULL AND severity <> 'note';

COMMENT ON COLUMN core.property_note.severity IS
    'note | attention | critical. The middle level exists so that critical '
    'keeps its meaning: with only two, everything that is not ordinary '
    'gets marked critical to be noticed.';

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
       (n.severity <> 'note' AND n.resolved_at IS NULL) AS is_open
FROM core.property_note n
ORDER BY n.created_at DESC;

-- ---------------------------------------------------------------------
-- Writing, with a level
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.add_note(p_property_id uuid, p_body text,
                                        p_visibility text DEFAULT 'internal',
                                        p_severity text DEFAULT 'note')
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
  IF p_severity NOT IN ('note', 'attention', 'critical') THEN
    RAISE EXCEPTION 'a note is note, attention or critical, not %', p_severity;
  END IF;
  IF length(btrim(COALESCE(p_body, ''))) = 0 THEN
    RAISE EXCEPTION 'an empty note is not a note';
  END IF;

  INSERT INTO core.property_note
    (property_id, visibility, body, severity, author_id)
  VALUES (p_property_id, p_visibility, btrim(p_body), p_severity, sec.actor_id())
  RETURNING note_id INTO v_id;
  RETURN v_id;
END;
$fn$;

CREATE FUNCTION api.resolve_note(p_note_id uuid, p_resolution text DEFAULT NULL)
RETURNS boolean
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $fn$
DECLARE v_prop uuid; v_sev text;
BEGIN
  SELECT property_id, severity INTO v_prop, v_sev
    FROM core.property_note
   WHERE note_id = p_note_id AND deleted_at IS NULL;
  IF v_prop IS NULL THEN RETURN false; END IF;
  IF NOT sec.can_manage_media(v_prop) THEN
    RAISE EXCEPTION 'not authorised' USING ERRCODE = '42501';
  END IF;
  IF v_sev = 'note' THEN
    RAISE EXCEPTION 'an ordinary note has nothing to resolve';
  END IF;

  -- Anyone who can manage the property may resolve, not only the author:
  -- the person who spots a problem is often not the person who fixes it,
  -- and requiring the author to close it means flags outliving the fix.
  UPDATE core.property_note
     SET resolved_at = now(), resolved_by = sec.actor_id(),
         resolution = NULLIF(btrim(COALESCE(p_resolution, '')), '')
   WHERE note_id = p_note_id;
  RETURN true;
END;
$fn$;

CREATE FUNCTION api.reopen_note(p_note_id uuid)
RETURNS boolean
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $fn$
DECLARE v_prop uuid;
BEGIN
  SELECT property_id INTO v_prop FROM core.property_note
   WHERE note_id = p_note_id AND deleted_at IS NULL;
  IF v_prop IS NULL THEN RETURN false; END IF;
  IF NOT sec.can_manage_media(v_prop) THEN
    RAISE EXCEPTION 'not authorised' USING ERRCODE = '42501';
  END IF;
  UPDATE core.property_note
     SET resolved_at = NULL, resolved_by = NULL, resolution = NULL
   WHERE note_id = p_note_id;
  RETURN true;
END;
$fn$;

REVOKE ALL ON FUNCTION api.add_note(uuid, text, text, text),
                       api.resolve_note(uuid, text),
                       api.reopen_note(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.add_note(uuid, text, text, text),
                          api.resolve_note(uuid, text),
                          api.reopen_note(uuid) TO sdi_agent, sdi_admin;

-- ---------------------------------------------------------------------
-- The flag
-- ---------------------------------------------------------------------
CREATE VIEW api.property_flag
WITH (security_invoker = true, security_barrier = true) AS
SELECT p.property_id,
       CASE WHEN count(*) FILTER (WHERE n.severity = 'critical') > 0 THEN 'critical'
            WHEN count(*) FILTER (WHERE n.severity = 'attention') > 0 THEN 'attention'
            ELSE 'ok' END                                        AS flag,
       count(*) FILTER (WHERE n.severity = 'critical')::int       AS open_critical,
       count(*) FILTER (WHERE n.severity = 'attention')::int      AS open_attention
FROM api.property p
LEFT JOIN api.property_note n
       ON n.property_id = p.property_id AND n.is_open
GROUP BY p.property_id;

GRANT SELECT ON api.property_flag
    TO sdi_public, sdi_investor, sdi_agent, sdi_admin;

CREATE OR REPLACE VIEW api.property_card
WITH (security_invoker = true, security_barrier = true) AS
SELECT p.*,
       (SELECT COALESCE(mm.thumb_url, mm.url)
          FROM api.property_media mm
         WHERE mm.property_id = p.property_id
         ORDER BY mm.is_primary DESC, mm.position
         LIMIT 1) AS primary_image,
       ln.last_note_body, ln.last_note_author, ln.last_note_author_id,
       ln.last_note_at, ln.last_note_visibility,
       f.flag, f.open_critical, f.open_attention
FROM api.property p
LEFT JOIN api.property_last_note ln ON ln.property_id = p.property_id
LEFT JOIN api.property_flag       f ON f.property_id  = p.property_id;

-- ---------------------------------------------------------------------
-- Demo notes
--
-- A feature nobody can see is a feature nobody reviews. These exist so a
-- freshly built demo shows one property flying red, one amber, and one
-- with a flag that was raised and taken back down -- which is the case
-- that is easiest to get wrong and hardest to notice missing.
--
-- Not SDI-1011 to SDI-1013: the test suite writes its own notes there and
-- asserts on the flags it gets back, and seed data underneath would make
-- those assertions pass or fail for reasons nobody could see.
-- ---------------------------------------------------------------------
INSERT INTO core.property_note (property_id, visibility, body, severity, author_id,
                                created_at, resolved_at, resolved_by, resolution)
SELECT p.property_id, v.visibility, v.body, v.severity, v.author,
       now() - v.age, v.res_at, v.res_by, v.res
FROM (VALUES
  ('SDI-1010', 'internal', 'Inspection turned up an active roof leak over the '
     || 'back bedroom. Seller has been told. Do not release to a buyer until '
     || 'this is settled.', 'critical', '77777777-7777-7777-7777-777777777777'::uuid,
     interval '2 days', NULL::timestamptz, NULL::uuid, NULL::text),
  ('SDI-1010', 'internal', 'Second roof quote requested from Kelleher; first '
     || 'came back at 8,400.', 'attention', '44444444-4444-4444-4444-444444444444'::uuid,
     interval '1 day', NULL, NULL, NULL),
  ('SDI-1016', 'internal', 'HOA has not confirmed the rental cap. Chasing.',
     'attention', '55555555-5555-5555-5555-555555555555'::uuid,
     interval '5 days', NULL, NULL, NULL),
  ('SDI-1019', 'internal', 'Title search came back with an old lien on the '
     || 'property.', 'critical', '66666666-6666-6666-6666-666666666666'::uuid,
     interval '20 days', now() - interval '12 days',
     '77777777-7777-7777-7777-777777777777'::uuid,
     'Released at closing on the seller''s prior sale; title company has the '
     || 'satisfaction on file.'),
  ('SDI-1019', 'public', 'Roof replaced in 2024; the receipts are with the '
     || 'listing.', 'note', '55555555-5555-5555-5555-555555555555'::uuid,
     interval '9 days', NULL, NULL, NULL)
) AS v(ref, visibility, body, severity, author, age, res_at, res_by, res)
JOIN core.property p ON p.listing_ref = v.ref
ON CONFLICT DO NOTHING;

COMMIT;
