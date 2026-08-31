# The database, with the schema baked in.
#
# Built rather than bind-mounted so the image is self-contained. A stack
# deployed from Git in Portainer CE has no access to the repository on the
# host: relative-path volumes are a Business Edition feature, so a bind mount
# of ./sql resolves to an empty directory and PostgreSQL initialises with no
# schema at all -- silently, because an empty init directory is legal.
#
# Build context is the repository root.
FROM postgres:16

# Order matters. PostgreSQL runs /docker-entrypoint-initdb.d/*.sql in
# alphabetical order, which is why these are numbered rather than named.
# The gaps (05, 07, 10, 14) are the test walkthroughs: they mutate data and
# must never run at initialisation.
COPY sql/01_schema.sql           /docker-entrypoint-initdb.d/01_schema.sql
COPY sql/02_policies.sql         /docker-entrypoint-initdb.d/02_policies.sql
COPY sql/03_views.sql            /docker-entrypoint-initdb.d/03_views.sql
COPY sql/04_seed.sql             /docker-entrypoint-initdb.d/04_seed.sql
COPY sql/06_ghl_integration.sql  /docker-entrypoint-initdb.d/06_ghl_integration.sql
COPY sql/08_review_queue.sql     /docker-entrypoint-initdb.d/08_review_queue.sql
COPY sql/09_review_actions.sql   /docker-entrypoint-initdb.d/09_review_actions.sql
COPY sql/11_pipeline.sql         /docker-entrypoint-initdb.d/11_pipeline.sql
COPY sql/12_pipeline_policies.sql /docker-entrypoint-initdb.d/12_pipeline_policies.sql
COPY sql/13_pipeline_seed.sql    /docker-entrypoint-initdb.d/13_pipeline_seed.sql

# Demo logins. Loaded last, and only because DEMO_LOGINS=1 is set at build
# time -- a production image is built without it and the application roles
# keep no password of their own.
ARG DEMO_LOGINS=1
COPY sql/99_local_logins.sql     /tmp/99_local_logins.sql
RUN if [ "$DEMO_LOGINS" = "1" ]; then \
      cp /tmp/99_local_logins.sql /docker-entrypoint-initdb.d/99_local_logins.sql; \
    fi; rm -f /tmp/99_local_logins.sql

# The test-fixture role carries BYPASSRLS and is never baked in. It is applied
# by hand against a test database only. See worker/test/bootstrap.sql.
