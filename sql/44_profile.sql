-- =====================================================================
-- 44_profile.sql  |  a person's own record, editable by them
-- =====================================================================
-- Everything about a person has so far been seeded or set by staff. This
-- lets somebody change their own display name and photograph, and nothing
-- else -- not their email, which is the login identifier, and not their
-- role, which is the whole authorisation model.
--
-- WHY NOT EMAIL. Changing it changes who you are to the system: sessions
-- key on person_id so nothing would break immediately, but the address a
-- password reset goes to would have changed without anyone confirming the
-- new one is reachable. That is an account takeover with extra steps. It
-- needs a verification round trip, which is a feature and not a field.
--
-- The photograph is stored on the media mount, not in the database, for
-- the same reason listing photographs are: bytes belong on a filesystem
-- and a path belongs in a row. It is re-encoded on upload, which strips
-- EXIF -- a phone selfie carries the coordinates of wherever it was taken,
-- and staff take photographs at home.

BEGIN;

ALTER TABLE core.person
    ADD COLUMN avatar_path      text,
    ADD COLUMN avatar_updated_at timestamptz;

COMMENT ON COLUMN core.person.avatar_path IS
    'Relative to the media root, e.g. avatars/<person_id>.jpg. Served '
    'through an authorising route like every other stored file, never by '
    'path.';

-- ---------------------------------------------------------------------
-- Your own record
--
-- SECURITY DEFINER and keyed on sec.actor_id() rather than taking an id:
-- a function that accepts "whose profile" is a function somebody will
-- eventually call with somebody else's id.
-- ---------------------------------------------------------------------
CREATE FUNCTION api.my_profile()
RETURNS TABLE (person_id uuid, full_name text, email text, role text,
               avatar_path text, avatar_updated_at timestamptz,
               fee_agreement_signed_at timestamptz, home_brand text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $$
  SELECT p.person_id, p.full_name, p.email, p.role::text,
         p.avatar_path, p.avatar_updated_at,
         p.fee_agreement_signed_at, p.home_brand
    FROM core.person p
   WHERE p.person_id = sec.actor_id();
$$;

CREATE FUNCTION api.update_profile(p_full_name text)
RETURNS boolean
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $fn$
DECLARE v_actor uuid := sec.actor_id();
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'not signed in' USING ERRCODE = '28000';
  END IF;
  IF length(btrim(COALESCE(p_full_name, ''))) < 2 THEN
    RAISE EXCEPTION 'a name is at least two characters';
  END IF;
  UPDATE core.person SET full_name = btrim(p_full_name) WHERE person_id = v_actor;
  RETURN true;
END;
$fn$;

-- The path is recorded by the web tier once the bytes are safely written.
-- Separate from update_profile so a failed image write cannot leave a row
-- pointing at a file that is not there.
CREATE FUNCTION api.set_avatar(p_path text)
RETURNS boolean
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $fn$
DECLARE v_actor uuid := sec.actor_id();
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'not signed in' USING ERRCODE = '28000';
  END IF;
  -- The path is built by the server from the person's own id, but it
  -- arrives as text and text that becomes a filesystem path gets checked.
  IF p_path IS NOT NULL AND p_path !~ ('^avatars/' || v_actor::text || '\.(jpg|png|webp)$') THEN
    RAISE EXCEPTION 'an avatar path is avatars/<your id>.<ext>, not %', p_path;
  END IF;
  UPDATE core.person
     SET avatar_path = p_path,
         avatar_updated_at = CASE WHEN p_path IS NULL THEN NULL ELSE now() END
   WHERE person_id = v_actor;
  RETURN true;
END;
$fn$;

REVOKE ALL ON FUNCTION api.my_profile(), api.update_profile(text),
                       api.set_avatar(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.my_profile(), api.update_profile(text),
                          api.set_avatar(text)
    TO sdi_investor, sdi_agent, sdi_admin;

-- Where an avatar is, for the route that serves it. Any signed-in caller
-- may see a colleague's photograph -- it is a face beside a note they
-- wrote, not a protected attribute.
CREATE FUNCTION api.avatar_path(p_person_id uuid) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = core, pg_temp
AS $$ SELECT avatar_path FROM core.person WHERE person_id = p_person_id AND active $$;

REVOKE ALL ON FUNCTION api.avatar_path(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.avatar_path(uuid)
    TO sdi_investor, sdi_agent, sdi_admin;

COMMIT;
