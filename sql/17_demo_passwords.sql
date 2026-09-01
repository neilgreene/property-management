-- =====================================================================
-- 17_demo_passwords.sql  |  DEMO CREDENTIALS -- NOT FOR PRODUCTION
-- =====================================================================
-- Every seeded person gets the password `demo1234`, so the demo can be
-- driven by signing in as each of them and comparing what comes back.
-- That comparison is the point: the same page, the same query, different
-- results, decided entirely by who is asking.
--
-- These are scrypt hashes of a password published in a public repository.
-- They are worth nothing. Do not load this file anywhere real -- and note
-- that api.set_password() is the supported path for genuine credentials,
-- which is why this writes through it rather than touching core.credential.

BEGIN;

DO $$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT * FROM (VALUES
          -- Ruth Okonkwo — investor, agreement SIGNED
          ('11111111-1111-1111-1111-111111111111', 'scrypt$32768$8$1$N0DMv84ZHp0oQBQmMlwfPA==$Rw4WoNPhFmILh3ZD7gQ4lLkGL9W3NVFH84NchID7ubc='),
          -- Marcus Pell — investor, agreement NOT signed
          ('22222222-2222-2222-2222-222222222222', 'scrypt$32768$8$1$z8KBUk/AcmnNiMHJ/NGitw==$v+0pBLPByslbPt2ylCmvhrH7OqnzJAwlSQBpN3VfrvE='),
          -- Ines Duarte — investor, KAVADOO brand
          ('33333333-3333-3333-3333-333333333333', 'scrypt$32768$8$1$v3QSdNOk5l7XH7C3znSnqQ==$k2eMB5LqvaXn6Y4F+h/QSfwCsGjNguH5beiu/LLL1xo='),
          -- Tom Bradbury — agent
          ('44444444-4444-4444-4444-444444444444', 'scrypt$32768$8$1$S+IUM3iErFVLgYqC2ameAw==$PjN35G9fhedMWyfNOY/46Tby6GZ1Ym7+X61PGYB9JtY='),
          -- Priya Raman — agent
          ('55555555-5555-5555-5555-555555555555', 'scrypt$32768$8$1$kJk/G2Ivji6CHjSAc028LQ==$NOFOAUoxWIavaIwQ1/ptjO0rhFk5AYCixCMGPgJs8Ho='),
          -- Dan Beitor — admin
          ('66666666-6666-6666-6666-666666666666', 'scrypt$32768$8$1$iVorLWPsYRFrDLZEC64gXg==$+q8NOuLZJj9bD0RVrh8oeG/MsvI6+VoMvftdrp3bDAQ='),
          -- Jessica Pool — admin
          ('77777777-7777-7777-7777-777777777777', 'scrypt$32768$8$1$fXhIddxURKjgJhE0JCQ4CQ==$sHveDOmnlRUqGfOrJGZB+BZhemE6jekve+RikGdGljI=')
        ) AS t(person_id, hash)
    LOOP
        PERFORM api.set_password(r.person_id::uuid, r.hash);
    END LOOP;
END $$;

COMMIT;
