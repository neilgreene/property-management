-- =====================================================================
-- 48_mfa.sql  |  a phone number, and a second factor
-- =====================================================================
-- THE PHONE NUMBER IS OPTIONAL AND IS NOT A FACTOR. It is here so an
-- agent can be reached about a property, and that is all it is for. It
-- is deliberately NOT what the second factor is delivered to: a number
-- is transferable by anyone who can talk a carrier into a SIM swap, and
-- a factor that moves with a phone call is not a factor. Saying so here
-- because "we have their number, why not text them a code" is the most
-- natural next thought anybody will have about this column.
--
-- THE SECOND FACTOR IS TOTP (RFC 6238). Verified by arithmetic against
-- a shared secret, needing no provider, no delivery and no network.
--
-- WHAT THIS FILE DOES NOT DO: it never sees a code, a secret in the
-- clear, or a recovery code. The application computes and compares; the
-- database stores, counts and refuses. That split is the same one used
-- for passwords in 15_auth.sql, and for the same reason -- the plaintext
-- never reaches a query log, a plan, or an error message.
--
-- THE THREE THINGS THAT MAKE THIS ACTUALLY WORK, none of which are the
-- arithmetic:
--
--   A SESSION IS NOT ISSUED UNTIL BOTH FACTORS PASS. Password success
--   produces a CHALLENGE, which is not a session: it authenticates
--   nothing, expires in minutes, is single-use, and its only power is to
--   name which person is halfway in. Issuing a session first and
--   "requiring" the code afterwards is the classic way to build MFA that
--   an attacker skips by ignoring the second page.
--
--   THE CODE SPACE IS TINY. Six digits is a million, which a script
--   exhausts in minutes if nothing counts. Attempts are counted on the
--   challenge and the challenge dies.
--
--   A USED STEP IS BURNED. A code is live for thirty seconds, so without
--   this it is reusable by anyone who read it over a shoulder or through
--   a phishing proxy.

BEGIN;

-- ---------------------------------------------------------------------
-- The phone number
-- ---------------------------------------------------------------------
ALTER TABLE core.person ADD COLUMN phone text;

COMMENT ON COLUMN core.person.phone IS
    'Optional contact number. NOT an authentication factor and not a '
    'delivery channel for one -- see the header of 48_mfa.sql.';

-- ---------------------------------------------------------------------
-- The enrolment
-- ---------------------------------------------------------------------
CREATE TABLE core.mfa (
    person_id    uuid PRIMARY KEY REFERENCES core.person(person_id) ON DELETE CASCADE,
    -- AES-256-GCM, under a key held in the application environment and
    -- not in this database. Unlike a password, a TOTP secret cannot be
    -- hashed: the server has to recompute the code, so it needs the
    -- secret itself. Encrypting it means a database dump alone is inert.
    -- It is not magic -- whoever has the dump AND the application host
    -- has both halves -- so the key must not live in the same backup.
    secret_enc   text        NOT NULL,
    -- Enrolment is not complete until a code has been proved. Somebody
    -- who mis-scans the QR and walks away must not be locked out of
    -- their own account by a secret neither side can compute.
    confirmed_at timestamptz,
    -- The last accepted time step. Anything at or below it is refused.
    last_step    bigint,
    created_at   timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE core.mfa ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.mfa FORCE  ROW LEVEL SECURITY;
-- No policy, exactly like core.credential: every direct read and write is
-- refused for every role including the owner, and the definer functions
-- below are the only way in.

COMMENT ON TABLE core.mfa IS
    'No RLS policy exists on purpose. A TOTP secret is a shared secret, so '
    'the set of ways to read one is kept to a list that fits in a sentence.';

-- Recovery codes CAN be hashed, unlike the secret above: the server only
-- ever has to answer "did this match", never to reproduce one. So a dump
-- of this table is worth nothing even without the encryption key.
--
-- WITHOUT THESE, A LOST PHONE IS A SUPPORT CALL, and a support process
-- that turns off somebody's second factor on request is a second factor
-- an attacker gets past by being persuasive on the telephone.
CREATE TABLE core.mfa_recovery (
    person_id  uuid NOT NULL REFERENCES core.person(person_id) ON DELETE CASCADE,
    code_hash  text NOT NULL,
    used_at    timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (person_id, code_hash)
);
ALTER TABLE core.mfa_recovery ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.mfa_recovery FORCE  ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------
-- The challenge -- halfway in, and nothing more
-- ---------------------------------------------------------------------
CREATE TABLE core.auth_challenge (
    -- SHA-256 of the token, never the token, for the same reason
    -- core.session stores a hash: a dump must not be replayable.
    token_hash bytea PRIMARY KEY,
    person_id  uuid        NOT NULL REFERENCES core.person(person_id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    attempts   integer     NOT NULL DEFAULT 0,
    consumed_at timestamptz
);
CREATE INDEX ix_challenge_expiry ON core.auth_challenge (expires_at);
ALTER TABLE core.auth_challenge ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.auth_challenge FORCE  ROW LEVEL SECURITY;

COMMENT ON TABLE core.auth_challenge IS
    'Issued when a password verifies and a second factor is required. It '
    'authenticates nothing: it names which person is halfway in, for a few '
    'minutes, once.';

-- ---------------------------------------------------------------------
-- Reading state
-- ---------------------------------------------------------------------
CREATE FUNCTION api.mfa_status()
RETURNS TABLE (enrolled boolean, confirmed_at timestamptz, recovery_left integer)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $$
  SELECT m.person_id IS NOT NULL AND m.confirmed_at IS NOT NULL,
         m.confirmed_at,
         (SELECT count(*)::int FROM core.mfa_recovery r
           WHERE r.person_id = sec.actor_id() AND r.used_at IS NULL)
    FROM (SELECT sec.actor_id() AS me) a
    LEFT JOIN core.mfa m ON m.person_id = a.me;
$$;

-- Whether a person must pass a second factor. Called during sign-in, when
-- there is no actor yet, so it takes the id -- and returns only a boolean,
-- which is a fact the caller has already proved a password for.
CREATE FUNCTION api.mfa_required(p_person_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = core, pg_temp
AS $$
  SELECT EXISTS (SELECT 1 FROM core.mfa
                  WHERE person_id = p_person_id AND confirmed_at IS NOT NULL);
$$;

-- The sealed secret, for the application to verify a code against. The one
-- place it leaves the database, and it is still encrypted when it does.
CREATE FUNCTION api.mfa_secret(p_person_id uuid)
RETURNS TABLE (secret_enc text, last_step bigint)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = core, pg_temp
AS $$
  SELECT m.secret_enc, m.last_step FROM core.mfa m WHERE m.person_id = p_person_id;
$$;

-- ---------------------------------------------------------------------
-- Enrolling
-- ---------------------------------------------------------------------
-- Stores an UNCONFIRMED secret. Replacing an existing unconfirmed one is
-- fine -- somebody restarting enrolment is the common case. Replacing a
-- CONFIRMED one is not: that is how an attacker with a live session
-- quietly swaps the factor for their own.
CREATE FUNCTION api.begin_mfa_enrolment(p_secret_enc text)
RETURNS boolean
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $fn$
DECLARE v_actor uuid := sec.actor_id();
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'not signed in' USING ERRCODE = '28000';
  END IF;
  IF EXISTS (SELECT 1 FROM core.mfa
              WHERE person_id = v_actor AND confirmed_at IS NOT NULL) THEN
    RAISE EXCEPTION 'two-step is already on; turn it off first';
  END IF;
  INSERT INTO core.mfa (person_id, secret_enc) VALUES (v_actor, p_secret_enc)
  ON CONFLICT (person_id) DO UPDATE
    SET secret_enc = EXCLUDED.secret_enc, created_at = now(), last_step = NULL;
  RETURN true;
END;
$fn$;

-- The application has verified a code against the pending secret and
-- reports which step it matched. That step is burned in the same statement
-- that confirms, so the code used to enrol cannot also be used to sign in.
CREATE FUNCTION api.confirm_mfa(p_step bigint)
RETURNS boolean
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $fn$
DECLARE v_actor uuid := sec.actor_id(); n integer;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'not signed in' USING ERRCODE = '28000';
  END IF;
  UPDATE core.mfa SET confirmed_at = now(), last_step = p_step
   WHERE person_id = v_actor AND confirmed_at IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n > 0;
END;
$fn$;

-- Turning it off. Requires a current code, proved by the application in
-- exactly the way signing in does -- otherwise a stolen session removes
-- the factor that was supposed to protect the account from a stolen
-- session. The recovery codes go with it: they are for THIS secret.
CREATE FUNCTION api.disable_mfa(p_step bigint)
RETURNS boolean
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $fn$
DECLARE v_actor uuid := sec.actor_id(); n integer;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'not signed in' USING ERRCODE = '28000';
  END IF;
  IF p_step IS NULL THEN
    RAISE EXCEPTION 'a current code is needed to turn two-step off';
  END IF;
  DELETE FROM core.mfa WHERE person_id = v_actor;
  GET DIAGNOSTICS n = ROW_COUNT;
  DELETE FROM core.mfa_recovery WHERE person_id = v_actor;
  RETURN n > 0;
END;
$fn$;

-- Replaces the whole set. Recovery codes are shown once, at enrolment, and
-- regenerating invalidates every previous one -- a code printed last year
-- and still working is a password with a long memory.
CREATE FUNCTION api.set_recovery_codes(p_hashes text[])
RETURNS integer
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $fn$
DECLARE v_actor uuid := sec.actor_id(); n integer;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'not signed in' USING ERRCODE = '28000';
  END IF;
  DELETE FROM core.mfa_recovery WHERE person_id = v_actor;
  INSERT INTO core.mfa_recovery (person_id, code_hash)
  SELECT v_actor, h FROM unnest(p_hashes) AS h;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END;
$fn$;

-- The unused recovery hashes for a person mid-sign-in. The application
-- compares; scrypt hashes cannot be looked up by equality.
CREATE FUNCTION api.recovery_hashes(p_person_id uuid)
RETURNS TABLE (code_hash text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = core, pg_temp
AS $$
  SELECT r.code_hash FROM core.mfa_recovery r
   WHERE r.person_id = p_person_id AND r.used_at IS NULL;
$$;

CREATE FUNCTION api.consume_recovery(p_person_id uuid, p_hash text)
RETURNS boolean
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = core, pg_temp
AS $fn$
DECLARE n integer;
BEGIN
  -- Single use, enforced by the update rather than by the caller checking
  -- first and deleting after. Two simultaneous sign-ins with the same code
  -- must not both succeed.
  UPDATE core.mfa_recovery SET used_at = now()
   WHERE person_id = p_person_id AND code_hash = p_hash AND used_at IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n > 0;
END;
$fn$;

-- ---------------------------------------------------------------------
-- The challenge
-- ---------------------------------------------------------------------
CREATE FUNCTION api.begin_challenge(p_person_id uuid, p_token_hash bytea,
                                    p_ttl interval DEFAULT '5 minutes')
RETURNS timestamptz
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = core, pg_temp
AS $fn$
DECLARE v_exp timestamptz := now() + p_ttl;
BEGIN
  -- Any earlier challenge for this person is spent. A fresh sign-in
  -- attempt should not leave an older half-open door standing.
  UPDATE core.auth_challenge SET consumed_at = now()
   WHERE person_id = p_person_id AND consumed_at IS NULL;
  INSERT INTO core.auth_challenge (token_hash, person_id, expires_at)
  VALUES (p_token_hash, p_person_id, v_exp);
  RETURN v_exp;
END;
$fn$;

-- Counts the attempt as it resolves the challenge, so a caller cannot
-- read it repeatedly without the count moving. Six digits is a million,
-- and a million is minutes of scripting if nothing counts.
CREATE FUNCTION api.claim_challenge(p_token_hash bytea)
RETURNS TABLE (person_id uuid, attempts integer)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = core, pg_temp
AS $fn$
BEGIN
  RETURN QUERY
  UPDATE core.auth_challenge c SET attempts = c.attempts + 1
   WHERE c.token_hash = p_token_hash
     AND c.consumed_at IS NULL
     AND c.expires_at > now()
     AND c.attempts < 5
  RETURNING c.person_id, c.attempts;
END;
$fn$;

CREATE FUNCTION api.consume_challenge(p_token_hash bytea)
RETURNS boolean
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = core, pg_temp
AS $fn$
DECLARE n integer;
BEGIN
  UPDATE core.auth_challenge SET consumed_at = now()
   WHERE token_hash = p_token_hash AND consumed_at IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n > 0;
END;
$fn$;

-- Records the accepted step so the same code cannot be presented twice.
CREATE FUNCTION api.record_mfa_step(p_person_id uuid, p_step bigint)
RETURNS boolean
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = core, pg_temp
AS $fn$
BEGIN
  UPDATE core.mfa SET last_step = p_step WHERE person_id = p_person_id;
  RETURN true;
END;
$fn$;

CREATE FUNCTION api.purge_expired_challenges(p_older_than interval DEFAULT '1 day')
RETURNS integer
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = core, pg_temp
AS $fn$
DECLARE n integer;
BEGIN
  DELETE FROM core.auth_challenge WHERE expires_at < now() - p_older_than;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END;
$fn$;

-- ---------------------------------------------------------------------
-- Profile, extended
-- ---------------------------------------------------------------------
-- Dropped and recreated rather than replaced: CREATE OR REPLACE cannot
-- change the row type a set-returning function declares, and the phone
-- number is a new OUT column.
DROP FUNCTION api.my_profile();

CREATE FUNCTION api.my_profile()
RETURNS TABLE (person_id uuid, full_name text, email text, role text,
               avatar_path text, avatar_updated_at timestamptz,
               fee_agreement_signed_at timestamptz, home_brand text,
               phone text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $$
  SELECT p.person_id, p.full_name, p.email, p.role::text,
         p.avatar_path, p.avatar_updated_at,
         p.fee_agreement_signed_at, p.home_brand, p.phone
    FROM core.person p
   WHERE p.person_id = sec.actor_id();
$$;

-- Two arguments now. The old single-argument form is dropped rather than
-- left beside it: two overloads that both "update the profile" is how one
-- of them silently stops being called and quietly rots.
DROP FUNCTION api.update_profile(text);

CREATE FUNCTION api.update_profile(p_full_name text, p_phone text DEFAULT NULL)
RETURNS boolean
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = core, sec, pg_temp
AS $fn$
DECLARE v_actor uuid := sec.actor_id(); v_phone text;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'not signed in' USING ERRCODE = '28000';
  END IF;
  IF length(btrim(COALESCE(p_full_name, ''))) < 2 THEN
    RAISE EXCEPTION 'a name is at least two characters';
  END IF;

  -- Stored as typed, near enough: punctuation is stripped so two records
  -- of the same number match, but no country is assumed and no format is
  -- imposed. A validator that rejects a legitimate international number
  -- is worse than a column that holds what somebody typed.
  v_phone := NULLIF(btrim(COALESCE(p_phone, '')), '');
  IF v_phone IS NOT NULL THEN
    IF length(regexp_replace(v_phone, '[^0-9]', '', 'g')) < 7 THEN
      RAISE EXCEPTION 'that does not look like a phone number';
    END IF;
    IF length(v_phone) > 32 THEN
      RAISE EXCEPTION 'that phone number is too long';
    END IF;
  END IF;

  UPDATE core.person
     SET full_name = btrim(p_full_name), phone = v_phone
   WHERE person_id = v_actor;
  RETURN true;
END;
$fn$;

REVOKE ALL ON FUNCTION
    api.mfa_status(), api.mfa_required(uuid), api.mfa_secret(uuid),
    api.begin_mfa_enrolment(text), api.confirm_mfa(bigint), api.disable_mfa(bigint),
    api.set_recovery_codes(text[]), api.recovery_hashes(uuid),
    api.consume_recovery(uuid, text), api.begin_challenge(uuid, bytea, interval),
    api.claim_challenge(bytea), api.consume_challenge(bytea),
    api.record_mfa_step(uuid, bigint), api.purge_expired_challenges(interval),
    api.update_profile(text, text) FROM PUBLIC;

-- The sign-in half runs before anybody is signed in, so it is granted to
-- the anonymous role -- as api.begin_authentication already is. Each one
-- returns only what a caller who has passed the previous step needs.
GRANT EXECUTE ON FUNCTION
    api.mfa_required(uuid), api.mfa_secret(uuid), api.recovery_hashes(uuid),
    api.consume_recovery(uuid, text), api.begin_challenge(uuid, bytea, interval),
    api.claim_challenge(bytea), api.consume_challenge(bytea),
    api.record_mfa_step(uuid, bigint)
    TO sdi_public, sdi_investor, sdi_agent, sdi_admin;

-- The management half needs a session.
GRANT EXECUTE ON FUNCTION
    api.mfa_status(), api.begin_mfa_enrolment(text), api.confirm_mfa(bigint),
    api.disable_mfa(bigint), api.set_recovery_codes(text[]),
    api.update_profile(text, text)
    TO sdi_investor, sdi_agent, sdi_admin;

-- my_profile() was dropped above, and a dropped function takes its grants
-- with it. Re-granting is not tidiness: without this every profile page
-- fails with "permission denied for function my_profile" the moment this
-- file loads.
REVOKE ALL ON FUNCTION api.my_profile() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.my_profile()
    TO sdi_investor, sdi_agent, sdi_admin;

GRANT EXECUTE ON FUNCTION api.purge_expired_challenges(interval) TO sdi_admin;

COMMIT;
