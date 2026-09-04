-- =====================================================================
-- 45_note_summary.sql  |  the last note, without opening the panel
-- =====================================================================
-- "Who said something about this property, and when" is a question asked
-- while looking at a list, not while looking at one record. Answering it
-- only in the admin panel means opening twenty-five properties to find the
-- one somebody touched this morning.
--
-- So the latest visible note travels with the listing. WHICH note is
-- latest depends on who is asking, and that falls out of the row policy
-- rather than being decided again here: staff see internal notes so their
-- latest may be an internal one; everybody else sees only public notes and
-- gets the latest of those. Nothing is filtered twice.

BEGIN;

-- The author's id joins the name and the date already there, so a face can
-- be drawn beside a note.
--
-- Appended rather than slotted next to `author`: CREATE OR REPLACE VIEW may
-- only add columns at the END, and inserting one in the middle renames
-- every column after it, which Postgres refuses outright. Column order in
-- a view is part of its contract.
CREATE OR REPLACE VIEW api.property_note
WITH (security_invoker = true, security_barrier = true) AS
SELECT n.note_id, n.property_id, n.visibility, n.body,
       n.created_at, n.edited_at,
       sec.actor_name(n.author_id) AS author,
       n.author_id = sec.actor_id() AS is_mine,
       n.author_id
FROM core.property_note n
ORDER BY n.created_at DESC;

-- ---------------------------------------------------------------------
-- The summary, defined once
-- ---------------------------------------------------------------------
CREATE VIEW api.property_last_note
WITH (security_invoker = true, security_barrier = true) AS
SELECT DISTINCT ON (n.property_id)
       n.property_id,
       n.note_id       AS last_note_id,
       n.visibility    AS last_note_visibility,
       n.body          AS last_note_body,
       n.author        AS last_note_author,
       n.author_id     AS last_note_author_id,
       n.created_at    AS last_note_at
FROM api.property_note n
ORDER BY n.property_id, n.created_at DESC;

GRANT SELECT ON api.property_last_note
    TO sdi_public, sdi_investor, sdi_agent, sdi_admin;

-- The card view carries it, so a grid of listings can show it without a
-- second round trip per row.
CREATE OR REPLACE VIEW api.property_card
WITH (security_invoker = true, security_barrier = true) AS
SELECT p.*,
       (SELECT COALESCE(mm.thumb_url, mm.url)
          FROM api.property_media mm
         WHERE mm.property_id = p.property_id
         ORDER BY mm.is_primary DESC, mm.position
         LIMIT 1) AS primary_image,
       ln.last_note_body, ln.last_note_author, ln.last_note_author_id,
       ln.last_note_at, ln.last_note_visibility
FROM api.property p
LEFT JOIN api.property_last_note ln ON ln.property_id = p.property_id;

COMMIT;
