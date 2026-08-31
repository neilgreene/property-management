-- =====================================================================
-- 99_local_logins.sql  |  DEMO AND LOCAL DEVELOPMENT ONLY
-- =====================================================================
-- The application roles are created NOLOGIN and without passwords,
-- which is correct: in a real deployment they are assumed via SET ROLE
-- from a connection that authenticated some other way, or given
-- credentials by the deployment, never by a file in the repository.
--
-- This script exists so `docker compose up` and `./run.sh` produce a
-- stack you can actually connect to. The passwords below are published
-- in a public repository and are worth exactly nothing. Do not load this
-- file anywhere that matters.

ALTER ROLE sdi_app         WITH LOGIN PASSWORD 'demo_app_pw';
ALTER ROLE sdi_integration WITH LOGIN PASSWORD 'demo_int_pw';

GRANT CONNECT ON DATABASE sdi TO sdi_app, sdi_integration;
