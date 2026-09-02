-- Test-only fixture role. NOT part of the application schema.
--
-- The integration test has to set up and inspect core.person directly (reset
-- the gate, read back the signature timestamp). No application role can do
-- that by design: core.person is FORCE RLS with policies keyed on
-- sec.actor_id(), and the worker deliberately holds no grants on core.
-- Test fixtures need privileges the application does not, which is normal --
-- what matters is that this role never exists outside a test database.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sdi_test_admin') THEN
    CREATE ROLE sdi_test_admin LOGIN PASSWORD 'demo_test_pw' BYPASSRLS;
  END IF;
END $$;

GRANT USAGE ON SCHEMA core, ghl, api, sec, feed, gov TO sdi_test_admin;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA core TO sdi_test_admin;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA ghl  TO sdi_test_admin;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA feed TO sdi_test_admin;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA gov  TO sdi_test_admin;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA core, ghl, feed, gov TO sdi_test_admin;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA feed, gov TO sdi_test_admin;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA api, sec TO sdi_test_admin;

-- Re-run this after adding tables or functions: the grants above are a
-- snapshot, not a standing rule, so anything created later is not covered.
-- That is why the auth suite failed the first time it ran.
