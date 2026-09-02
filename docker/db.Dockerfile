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
COPY sql/15_auth.sql             /docker-entrypoint-initdb.d/15_auth.sql

# Demo dataset and demo credentials. Both are demonstration data: every
# seeded person's password is `demo1234`, which is published in a public
# repository. Fine for a demo whose purpose is to be signed into; strip both
# for anything real.
COPY sql/16_demo_dataset.sql     /docker-entrypoint-initdb.d/16_demo_dataset.sql
COPY sql/17_demo_passwords.sql   /docker-entrypoint-initdb.d/17_demo_passwords.sql
COPY sql/18_property_detail.sql  /docker-entrypoint-initdb.d/18_property_detail.sql
COPY sql/19_saved_search.sql     /docker-entrypoint-initdb.d/19_saved_search.sql
COPY sql/20_demo_detail_seed.sql /docker-entrypoint-initdb.d/20_demo_detail_seed.sql
COPY sql/21_listing_sync.sql     /docker-entrypoint-initdb.d/21_listing_sync.sql
COPY sql/22_listing_sync_seed.sql /docker-entrypoint-initdb.d/22_listing_sync_seed.sql
COPY sql/24_data_governance.sql  /docker-entrypoint-initdb.d/24_data_governance.sql
COPY sql/25_governance_seed.sql  /docker-entrypoint-initdb.d/25_governance_seed.sql
COPY sql/26_fairgrove_media.sql  /docker-entrypoint-initdb.d/26_fairgrove_media.sql

# Application roles take their credentials from the environment at first
# start, not from anything baked in. See the script for why a build-time flag
# cannot work for an image people pull by tag.
COPY docker/98_role_logins.sh    /docker-entrypoint-initdb.d/98_role_logins.sh

# sql/99_local_logins.sql is deliberately NOT copied. Its passwords are
# published in a public repository; it exists only for `./run.sh` on a laptop.

# The test-fixture role carries BYPASSRLS and is never baked in. It is applied
# by hand against a test database only. See worker/test/bootstrap.sql.
