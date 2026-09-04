-- =====================================================================
-- 34_property_card.sql  |  one definition of "the card image"
-- =====================================================================
-- The listing card's photograph was chosen by a correlated subquery
-- written inside the web tier's query string. That worked for the search
-- grid, which was the only thing using it -- and then the favourites list
-- read api.my_favorite instead, did not have the column, and silently fell
-- back to the generated illustration. Nothing failed. The favourites page
-- just quietly showed drawings while every other page showed photographs.
--
-- The fix is not to copy the subquery into the second place. It is to have
-- one place: a view that adds the card image to api.property, and two
-- consumers that read it.
--
-- WHY NOT PUT IT ON api.property ITSELF, which would be simpler: because
-- core.property_media's row policy is defined in terms of api.property --
--   EXISTS (SELECT 1 FROM api.property v WHERE v.property_id = ...)
-- -- so a subquery over api.property_media inside api.property would make
-- the policy depend on the view that depends on the policy. That is a
-- recursion Postgres discovers at query time, not at definition time.

BEGIN;

CREATE VIEW api.property_card
WITH (security_invoker = true, security_barrier = true) AS
SELECT p.*,
       -- Read through api.property_media, not the table: the same rules
       -- that decide which photographs a caller may see at all decide
       -- which one becomes the card image, so a gated photograph can never
       -- become a thumbnail by accident. coalesce, because a row with no
       -- downscaled copy still has a picture.
       (SELECT COALESCE(mm.thumb_url, mm.url)
          FROM api.property_media mm
         WHERE mm.property_id = p.property_id
         ORDER BY mm.is_primary DESC, mm.position
         LIMIT 1) AS primary_image
FROM api.property p;

GRANT SELECT ON api.property_card
    TO sdi_public, sdi_investor, sdi_agent, sdi_admin;

-- Favourites, rebuilt on the card view. p.* now carries primary_image, so
-- the favourites grid and the search grid cannot disagree about which
-- photograph a listing has.
DROP VIEW api.my_favorite;
CREATE VIEW api.my_favorite
WITH (security_invoker = true, security_barrier = true) AS
SELECT p.*, s.saved_at
FROM core.saved_property s
JOIN api.property_card p ON p.property_id = s.property_id;

GRANT SELECT ON api.my_favorite TO sdi_investor, sdi_admin;

COMMIT;
