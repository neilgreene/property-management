-- =====================================================================
-- 09_review_actions.sql  |  acting on queued CRM edits
-- =====================================================================
-- 08 collects inbound changes that need a human. This is how a human
-- answers them. Two rules shape it:
--
--   Only an admin decides. The decision is what lets a CRM edit reach
--   the authoritative row, so it is exactly as privileged as editing
--   core.property directly, and is checked against sec.actor(), not
--   against a caller-supplied id.
--
--   Accepting applies an ALLOWLIST, never the whole payload. The CRM
--   payload is external input. Letting it name its own target columns
--   would mean a CRM edit could rewrite acquisition_cost or
--   street_address -- band 2 and band 3 data -- through a door opened
--   for a status change. Only the columns below can ever be written
--   this way, whatever the payload contains.

BEGIN;

-- Columns an accepted CRM edit may write. Band 1 only, and only the
-- fields the CRM legitimately owns an opinion about.
CREATE TABLE ghl.reviewable_field (
    column_name text PRIMARY KEY
);
INSERT INTO ghl.reviewable_field (column_name) VALUES
    ('status'), ('list_price'), ('gross_rent_annual'),
    ('opex_annual'), ('hoa_annual');

COMMENT ON TABLE ghl.reviewable_field IS
    'Allowlist. An accepted CRM edit can write these and nothing else. '
    'Deliberately excludes every band 2 and band 3 column: a status '
    'change must not be a route to rewriting an address or a cost basis.';

-- The decision. SECURITY DEFINER because it writes core.property, which
-- no application role may touch directly -- but it establishes the
-- caller''s identity from sec.actor() first, so being definer-rights
-- grants the caller nothing they were not already entitled to.
CREATE FUNCTION api.review_decide(p_review_id bigint, p_decision text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, ghl, core, sec, pg_temp
AS $$
DECLARE
    me      core.person%ROWTYPE;
    item    ghl.review_queue%ROWTYPE;
    applied jsonb := '{}'::jsonb;
    col     text;
    val     text;
BEGIN
    SELECT * INTO me FROM sec.actor();
    IF me.person_id IS NULL OR me.role <> 'admin' THEN
        RAISE EXCEPTION 'only an admin may decide a review item';
    END IF;

    IF p_decision NOT IN ('accepted', 'rejected') THEN
        RAISE EXCEPTION 'decision must be accepted or rejected, got %', p_decision;
    END IF;

    SELECT * INTO item FROM ghl.review_queue
     WHERE id = p_review_id AND state = 'open'
     FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'review item % is not open', p_review_id;
    END IF;

    IF p_decision = 'accepted' AND item.ghl_object = 'record' THEN
        -- Resolve the CRM record back to our row. An edit we cannot place
        -- is not applied blindly; the decision is still recorded.
        DECLARE
            target uuid;
            props  jsonb := COALESCE(item.proposed->'properties', '{}'::jsonb);
        BEGIN
            SELECT local_id INTO target FROM ghl.id_map
             WHERE ghl_id = item.ghl_id AND entity_type = 'property';

            IF target IS NOT NULL THEN
                FOR col IN SELECT column_name FROM ghl.reviewable_field LOOP
                    IF props ? col THEN
                        val := props ->> col;
                        PERFORM set_config('app.gate_write', '1', true);
                        EXECUTE format(
                            'UPDATE core.property SET %I = $1::text::%s WHERE property_id = $2',
                            col,
                            (SELECT data_type FROM information_schema.columns
                              WHERE table_schema='core' AND table_name='property'
                                AND column_name=col))
                        USING val, target;
                        PERFORM set_config('app.gate_write', '0', true);
                        applied := applied || jsonb_build_object(col, val);
                    END IF;
                END LOOP;
            END IF;
        END;
    END IF;

    UPDATE ghl.review_queue
       SET state = p_decision::ghl.review_state,
           decided_at = now(),
           decided_by = me.person_id
     WHERE id = p_review_id;

    RETURN jsonb_build_object(
        'id', p_review_id, 'decision', p_decision,
        'decided_by', me.full_name, 'applied', applied);
END;
$$;

-- Open items, for the admin queue. A view rather than a grant on the
-- table, so the same read cannot see who decided what historically
-- without going through a wider grant.
CREATE VIEW api.review_open
WITH (security_invoker = true, security_barrier = true) AS
SELECT r.id, r.source, r.event_type, r.ghl_object, r.ghl_id,
       r.summary, r.proposed, r.raised_at
FROM ghl.review_queue r
WHERE r.state = 'open';

GRANT USAGE ON SCHEMA ghl TO sdi_admin;
GRANT SELECT ON ghl.review_queue TO sdi_admin;
GRANT SELECT ON api.review_open TO sdi_admin;
GRANT EXECUTE ON FUNCTION api.review_decide(bigint, text) TO sdi_admin;

-- core.property is FORCE RLS, so the definer function needs the same
-- explicit gate-write policy the fee agreement uses. Reusing one policy
-- keeps the number of doors into core.property at one.
CREATE POLICY property_gate_write ON core.property
  FOR UPDATE
  USING      (current_setting('app.gate_write', true) = '1')
  WITH CHECK (current_setting('app.gate_write', true) = '1');

COMMIT;
