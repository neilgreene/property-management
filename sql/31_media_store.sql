-- =====================================================================
-- 31_media_store.sql  |  photographs as managed files, not baked assets
-- =====================================================================
-- Until now every photograph was a file inside the container image,
-- committed to git and served straight off disk by path. That has two
-- problems, and only one of them is inconvenience.
--
--   The inconvenient one: adding a photograph meant a commit, a build and
--   a deploy. Staff cannot do that, so staff could not add photographs.
--
--   The serious one: a file under web/public/ is fetchable by ANYONE who
--   guesses its path. The database decided who was TOLD a photograph
--   existed; it never decided who could fetch it. That was survivable
--   only because every image in the system is a representative stock
--   photo with nothing to leak. The first real listing photograph would
--   have ended it.
--
-- So: bytes live on a shared mount outside the image, and they are served
-- through a route that re-asks the database, as the caller, whether this
-- caller may see this row. Same predicate as the address gate, because a
-- photograph of a front door IS the address.
--
-- WHAT THIS FILE DOES NOT DO. It does not delete anything, and it does not
-- move the existing seeded images. Rows that already carry a url keep it
-- and keep being served statically; rows created from here carry a
-- storage_path instead and are served through the route. api.property_media
-- computes one url from whichever is present, so nothing downstream has to
-- know which kind it is looking at.

BEGIN;

-- ---------------------------------------------------------------------
-- Lifecycle state
--
-- Four states, and the ordering matters: a photograph that arrives is NOT
-- visible. It becomes visible when a person decides what it is. Assuming
-- the reverse -- publish on arrival, correct later -- means the window
-- between arrival and review is a window with the gate open, and no
-- correction un-discloses anything.
-- ---------------------------------------------------------------------
CREATE TYPE core.media_state AS ENUM
    ('pending', 'published', 'unpublished', 'purged');

ALTER TABLE core.property_media
    -- Relative to the media root (/srv/media in the container). Null for
    -- the seeded images, which are static assets in the image.
    ADD COLUMN storage_path   text,
    ADD COLUMN thumb_path     text,
    -- Dedupe. The same photograph arriving twice is the normal case.
    ADD COLUMN content_sha256 bytea,
    ADD COLUMN byte_size      integer,
    ADD COLUMN width          integer,
    ADD COLUMN height         integer,
    -- What the file was called when it arrived. Kept only so a person can
    -- recognise it; nothing keys on it.
    ADD COLUMN original_name  text,
    -- Existing rows are already live, so they default to published. New
    -- rows are inserted explicitly as pending; see api.media_register.
    ADD COLUMN state          core.media_state NOT NULL DEFAULT 'published',
    ADD COLUMN published_at   timestamptz,
    ADD COLUMN deleted_at     timestamptz,
    -- Bytes are destroyed no sooner than this. Set when the row is
    -- unpublished, cleared if it is restored.
    ADD COLUMN purge_after    date,
    -- Suspends destruction regardless of retention. A property in dispute
    -- has photographs that are evidence, and a well-behaved retention job
    -- would otherwise destroy exactly what somebody later needs.
    ADD COLUMN legal_hold     boolean NOT NULL DEFAULT false,
    ADD COLUMN created_by     uuid REFERENCES core.person(person_id),
    ADD COLUMN created_at     timestamptz NOT NULL DEFAULT now();

-- url was NOT NULL when a static path was the only way to have a picture.
-- A stored row has no static url, so the guarantee moves from the column to
-- a constraint over both: a row is served from a file or from a url, and
-- never from neither. Dropping the NOT NULL without adding the CHECK would
-- have quietly allowed a media row that points at nothing.
ALTER TABLE core.property_media ALTER COLUMN url DROP NOT NULL;
ALTER TABLE core.property_media
    ADD CONSTRAINT media_has_bytes CHECK (url IS NOT NULL OR storage_path IS NOT NULL);

-- Dedupe is per property, not global: the same stock photograph legitimately
-- appears on several listings, but twice on one listing is always a mistake.
CREATE UNIQUE INDEX ux_media_content ON core.property_media (property_id, content_sha256)
    WHERE content_sha256 IS NOT NULL AND state <> 'purged';

CREATE INDEX ix_media_state ON core.property_media (state)
    WHERE state <> 'published';
CREATE INDEX ix_media_purge ON core.property_media (purge_after)
    WHERE purge_after IS NOT NULL AND NOT legal_hold;

COMMENT ON COLUMN core.property_media.storage_path IS
    'Path under the media root. The FILENAME IS THE media_id: anyone '
    'holding a file identifies it with one query and no lookup table, and '
    'ls store/<listing_ref>/ is the complete set for a listing. Stored '
    'rather than derived, because a listing reference can be corrected and '
    'a derived path silently stops resolving when it is.';

-- ---------------------------------------------------------------------
-- Who may manage media
--
-- An agent manages their own listings' photographs. Only an admin may
-- un-gate one: releasing a location-revealing photograph is a decision
-- about the platform's disclosure model, not a listing-level edit.
-- ---------------------------------------------------------------------
CREATE FUNCTION sec.can_manage_media(p_property_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $$
  SELECT sec.is_internal() OR sec.is_assigned(p_property_id);
$$;

-- ---------------------------------------------------------------------
-- The read policy, extended by one clause
--
-- Everything the old policy said still holds. What is added: an
-- unpublished photograph is visible only to somebody who could act on it.
-- ---------------------------------------------------------------------
DROP POLICY property_media_read ON core.property_media;
CREATE POLICY property_media_read ON core.property_media
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM api.property v
             WHERE v.property_id = core.property_media.property_id)
    AND (NOT reveals_location OR sec.can_see_address(core.property_media.property_id))
    AND (state = 'published' OR sec.can_manage_media(core.property_media.property_id))
  );

-- ---------------------------------------------------------------------
-- Audit
--
-- A photograph appearing on a listing is a publication. A publication
-- with no record of who authorised it cannot be defended when somebody
-- asks, and somebody asks precisely in the cases that matter.
-- ---------------------------------------------------------------------
CREATE TABLE core.media_event (
    event_id    bigserial PRIMARY KEY,
    media_id    uuid NOT NULL,          -- deliberately NOT a foreign key:
                                        -- the audit outlives the row
    property_id uuid,
    action      text NOT NULL CHECK (action IN
                  ('registered','assigned','published','ungated','gated',
                   'unpublished','restored','purged','held','released')),
    actor_id    uuid,
    detail      jsonb NOT NULL DEFAULT '{}'::jsonb,
    at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_media_event_media ON core.media_event (media_id, at DESC);

ALTER TABLE core.media_event ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.media_event FORCE  ROW LEVEL SECURITY;
CREATE POLICY media_event_read ON core.media_event
  FOR SELECT USING (sec.is_internal());
GRANT SELECT ON core.media_event TO sdi_admin;

-- ---------------------------------------------------------------------
-- The scanner's identity
--
-- The ingest scanner runs unattended, so it has no signed-in person --
-- but every authorisation predicate and every audit row in this system
-- keys on sec.actor_id(). Giving the scanner a real person row rather
-- than special-casing a database role means it authorises through the
-- same path as everybody else, and the audit trail names it instead of
-- showing a blank.
--
-- It cannot sign in: no password is ever set for it, and 17_demo_passwords
-- does not touch it. Its ceiling is not this row anyway -- the connection
-- role sdi_integration is not granted EXECUTE on media_publish, so even
-- holding an admin actor it can only create pending rows.
INSERT INTO core.person (person_id, role, full_name, email, active)
VALUES ('00000000-0000-0000-0000-0000000000ff', 'admin',
        'Media ingest service', 'media-ingest@localhost', true)
ON CONFLICT (person_id) DO NOTHING;

CREATE FUNCTION core.log_media(p_media uuid, p_property uuid, p_action text,
                               p_detail jsonb DEFAULT '{}'::jsonb)
RETURNS void
LANGUAGE sql VOLATILE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $$
  INSERT INTO core.media_event (media_id, property_id, action, actor_id, detail)
  VALUES (p_media, p_property, p_action, sec.actor_id(), p_detail);
$$;

COMMIT;
