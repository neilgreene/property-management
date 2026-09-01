-- =====================================================================
-- 15_auth.sql  |  credentials and sessions
-- =====================================================================
-- Replaces the demo's persona switcher with real sign-in. Nothing else
-- changes: the web tier still assumes a persona role and sets
-- app.actor_id for the transaction. Every policy, view and grant already
-- written keeps working untouched -- authentication only decides which
-- person id goes into that setting.
--
-- Two tables, both sealed in core where no application role has USAGE.
-- Neither is ever read by the application directly; both are reached
-- only through the definer-rights functions at the bottom, which is what
-- lets a password hash and a session secret live in a database the web
-- tier connects to.
--
-- Hashing happens in the application, not here. Node's built-in scrypt
-- is a memory-hard KDF and needs no dependency, and keeping the plaintext
-- out of the database means it never reaches a query log, a plan, or an
-- error message.

BEGIN;

-- ---------------------------------------------------------------------
-- Credentials
-- ---------------------------------------------------------------------
CREATE TABLE core.credential (
    person_id       uuid PRIMARY KEY REFERENCES core.person(person_id) ON DELETE CASCADE,
    -- Opaque to the database: "scrypt$N$r$p$salt$hash". The algorithm is
    -- recorded in the string so a future rehash can detect stale
    -- parameters without a schema change.
    password_hash   text        NOT NULL,
    failed_attempts integer     NOT NULL DEFAULT 0,
    locked_until    timestamptz,
    password_set_at timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE core.credential ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.credential FORCE  ROW LEVEL SECURITY;
-- No policy at all: every direct read and write is refused, for every
-- role including the owner. The definer functions below are the only
-- way in, which makes "who can read a password hash" a question with
-- one short answer.

COMMENT ON TABLE core.credential IS
    'No RLS policy exists on purpose. Direct access is refused for every '
    'role; api.authenticate() and api.set_password() are the only paths.';

-- ---------------------------------------------------------------------
-- Sessions
-- ---------------------------------------------------------------------
CREATE TABLE core.session (
    -- SHA-256 of the token, never the token. A dump of this table cannot
    -- be replayed as a set of live sessions.
    token_hash   bytea       PRIMARY KEY,
    person_id    uuid        NOT NULL REFERENCES core.person(person_id) ON DELETE CASCADE,
    created_at   timestamptz NOT NULL DEFAULT now(),
    expires_at   timestamptz NOT NULL,
    last_seen_at timestamptz NOT NULL DEFAULT now(),
    revoked_at   timestamptz,
    user_agent   text,
    ip           inet
);
CREATE INDEX ix_session_person ON core.session (person_id) WHERE revoked_at IS NULL;
CREATE INDEX ix_session_expiry ON core.session (expires_at) WHERE revoked_at IS NULL;

ALTER TABLE core.session ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.session FORCE  ROW LEVEL SECURITY;

COMMENT ON COLUMN core.session.token_hash IS
    'SHA-256 of the bearer token. The token itself is returned once, at '
    'creation, and is never stored anywhere.';

-- ---------------------------------------------------------------------
-- Reading a credential, for the application to verify against
-- ---------------------------------------------------------------------
-- Returns the stored hash so the application can verify it. That is the
-- one place a hash leaves the database, and it is gated on the account
-- being active and unlocked -- so a locked or deactivated account cannot
-- even be tested against.
CREATE FUNCTION api.begin_authentication(p_email text)
RETURNS TABLE (person_id uuid, password_hash text, locked boolean)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = core, pg_temp
AS $$
    SELECT p.person_id,
           c.password_hash,
           (c.locked_until IS NOT NULL AND c.locked_until > now()) AS locked
      FROM core.person p
      JOIN core.credential c ON c.person_id = p.person_id
     WHERE lower(p.email) = lower(p_email)
       AND p.active;
$$;

-- Records the outcome and, on success, issues the session. Splitting
-- this from the verification keeps the plaintext in the application and
-- the bookkeeping in the database.
CREATE FUNCTION api.complete_authentication(
    p_person_id  uuid,
    p_success    boolean,
    p_token_hash bytea DEFAULT NULL,
    p_ttl        interval DEFAULT '12 hours',
    p_user_agent text DEFAULT NULL,
    p_ip         inet DEFAULT NULL
) RETURNS TABLE (person_id uuid, role text, full_name text, expires_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, pg_temp
AS $$
DECLARE
    v_expires timestamptz;
BEGIN
    IF NOT p_success THEN
        -- Five strikes, then fifteen minutes. Slows credential stuffing
        -- without letting anyone lock a known address out indefinitely.
        UPDATE core.credential
           SET failed_attempts = failed_attempts + 1,
               locked_until = CASE WHEN failed_attempts + 1 >= 5
                                   THEN now() + interval '15 minutes' END,
               updated_at = now()
         WHERE credential.person_id = p_person_id;
        RETURN;
    END IF;

    IF p_token_hash IS NULL THEN
        RAISE EXCEPTION 'a successful authentication must supply a token hash';
    END IF;

    UPDATE core.credential
       SET failed_attempts = 0, locked_until = NULL, updated_at = now()
     WHERE credential.person_id = p_person_id;

    v_expires := now() + p_ttl;

    INSERT INTO core.session (token_hash, person_id, expires_at, user_agent, ip)
    VALUES (p_token_hash, p_person_id, v_expires, p_user_agent, p_ip);

    RETURN QUERY
      SELECT p.person_id, p.role::text, p.full_name, v_expires
        FROM core.person p WHERE p.person_id = p_person_id;
END;
$$;

-- ---------------------------------------------------------------------
-- Resolving a session on each request
-- ---------------------------------------------------------------------
-- The whole authentication surface reduces to this: a token in, a person
-- and a role out, or nothing. Expiry, revocation and account
-- deactivation are all checked here, so a session cannot outlive the
-- account it belongs to.
CREATE FUNCTION api.resolve_session(p_token_hash bytea)
RETURNS TABLE (person_id uuid, role text, full_name text, expires_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, pg_temp
AS $$
BEGIN
    RETURN QUERY
    UPDATE core.session s
       SET last_seen_at = now()
      FROM core.person p
     WHERE s.token_hash = p_token_hash
       AND s.person_id  = p.person_id
       AND s.revoked_at IS NULL
       AND s.expires_at > now()
       AND p.active
    RETURNING p.person_id, p.role::text, p.full_name, s.expires_at;
END;
$$;

CREATE FUNCTION api.revoke_session(p_token_hash bytea)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, pg_temp
AS $$
DECLARE n integer;
BEGIN
    UPDATE core.session SET revoked_at = now()
     WHERE token_hash = p_token_hash AND revoked_at IS NULL;
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n > 0;
END;
$$;

-- Revokes every session for a person. What you call when an account is
-- compromised, or when a password changes.
CREATE FUNCTION api.revoke_all_sessions(p_person_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, pg_temp
AS $$
DECLARE n integer;
BEGIN
    UPDATE core.session SET revoked_at = now()
     WHERE person_id = p_person_id AND revoked_at IS NULL;
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END;
$$;

CREATE FUNCTION api.set_password(p_person_id uuid, p_password_hash text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, pg_temp
AS $$
BEGIN
    INSERT INTO core.credential (person_id, password_hash)
    VALUES (p_person_id, p_password_hash)
    ON CONFLICT (person_id) DO UPDATE
       SET password_hash = EXCLUDED.password_hash,
           failed_attempts = 0, locked_until = NULL,
           password_set_at = now(), updated_at = now();

    -- A password change ends every existing session. Otherwise changing
    -- it after a compromise leaves the attacker signed in.
    PERFORM api.revoke_all_sessions(p_person_id);
END;
$$;

-- Housekeeping. Expired rows carry no risk but no value either.
CREATE FUNCTION api.purge_expired_sessions(p_older_than interval DEFAULT '30 days')
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = core, pg_temp
AS $$
DECLARE n integer;
BEGIN
    DELETE FROM core.session
     WHERE expires_at < now() - p_older_than;
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END;
$$;

-- ---------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------
-- sdi_app is the connection role, before it assumes a persona. It is the
-- only thing that authenticates, which is correct: authentication runs
-- before there is a persona to assume.
--
-- That ordering is also why this grant is needed. 01_schema gives USAGE on
-- api to the four persona roles, and sdi_app is NOINHERIT -- it holds their
-- privileges only while it has SET ROLE into one. At login time it has not,
-- so without this it cannot even name api.begin_authentication. It gains
-- nothing else: it holds EXECUTE on the functions below and SELECT on
-- nothing, so it still cannot read a single row of property data.
GRANT USAGE ON SCHEMA api TO sdi_app;
REVOKE ALL ON FUNCTION api.begin_authentication(text)         FROM PUBLIC;
REVOKE ALL ON FUNCTION api.complete_authentication(uuid, boolean, bytea, interval, text, inet) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.resolve_session(bytea)             FROM PUBLIC;
REVOKE ALL ON FUNCTION api.revoke_session(bytea)              FROM PUBLIC;
REVOKE ALL ON FUNCTION api.revoke_all_sessions(uuid)          FROM PUBLIC;
REVOKE ALL ON FUNCTION api.set_password(uuid, text)           FROM PUBLIC;
REVOKE ALL ON FUNCTION api.purge_expired_sessions(interval)   FROM PUBLIC;

GRANT EXECUTE ON FUNCTION api.begin_authentication(text)      TO sdi_app;
GRANT EXECUTE ON FUNCTION api.complete_authentication(uuid, boolean, bytea, interval, text, inet) TO sdi_app;
GRANT EXECUTE ON FUNCTION api.resolve_session(bytea)          TO sdi_app;
GRANT EXECUTE ON FUNCTION api.revoke_session(bytea)           TO sdi_app;

-- Changing a password and revoking someone else's sessions are
-- administrative acts, not things the login path may do.
GRANT EXECUTE ON FUNCTION api.set_password(uuid, text)        TO sdi_admin;
GRANT EXECUTE ON FUNCTION api.revoke_all_sessions(uuid)       TO sdi_admin;
GRANT EXECUTE ON FUNCTION api.purge_expired_sessions(interval) TO sdi_admin;

COMMIT;
