-- =====================================================================
-- 52_search_screening.sql  |  refusing a search that is really steering
-- =====================================================================
-- Step two of three toward a search box with a model behind it. This is
-- the step that has to exist FIRST, and the reason is worth stating
-- plainly because it is not obvious.
--
-- THE EXISTING VALIDATOR DOES NOT COVER THIS. nlq.interpret() guards the
-- SHAPE of what comes out -- a key not on the allowlist is dropped, so a
-- model cannot invent a column to filter on. That is a real protection
-- and it is the wrong one for this problem.
--
-- Ask any parser, rules or model, for "a good school district" or "a
-- nice family neighbourhood" and it will return { city: 'X', min_beds: 4 }
-- -- entirely legal keys, passing every check, and a proxy filter all the
-- same. THE STEERING IS IN THE REQUEST, upstream of anything the output
-- validator can see. A model makes this worse rather than better: it is
-- far more willing than a regex to translate a vibe into a location.
--
-- The Fair Housing Act does not require that anyone intended it. A
-- system that answers "somewhere family-friendly" by narrowing to
-- particular neighbourhoods is steering whether or not a person meant it
-- that way, and whether a rules parser or a language model did the
-- narrowing.
--
-- SO THE CHECK IS ON THE TEXT, BEFORE THE PARSE, AND IT REFUSES OUT LOUD.
-- Not a silent drop: somebody who asks for a good school district is
-- usually asking in good faith and deserves to be told what this system
-- will and will not rank on, and what it offers instead.
--
-- THE PHRASES LIVE BESIDE THE REGISTER, not in the application. Adding a
-- dimension to gov.prohibited_dimension and its phrasings here extends
-- the guard everywhere at once -- the search box today, whatever asks
-- tomorrow. A lexicon compiled into JavaScript would be a second list to
-- forget.

BEGIN;

CREATE TABLE gov.prohibited_phrase (
    phrase     text PRIMARY KEY,
    dimension  text NOT NULL REFERENCES gov.prohibited_dimension(dimension),
    -- Whole word, or substring. "safe" must not fire on "safety deposit",
    -- but "african-american" should fire wherever it appears.
    whole_word boolean NOT NULL DEFAULT true
);

CREATE INDEX ix_prohibited_phrase_dim ON gov.prohibited_phrase (dimension);

COMMENT ON TABLE gov.prohibited_phrase IS
    'Natural-language phrasings that map to a registered dimension. The '
    'register says what may not be a ranking axis; this says how people '
    'actually ask for it.';

INSERT INTO gov.prohibited_phrase (phrase, dimension, whole_word) VALUES
  -- Schools. The single most common way this gets asked, and almost
  -- always in good faith.
  ('good schools', 'school_rating', false),
  ('great schools', 'school_rating', false),
  ('best schools', 'school_rating', false),
  ('top schools', 'school_rating', false),
  ('school district', 'school_rating', false),
  ('school rating', 'school_rating', false),
  ('good school', 'school_rating', false),
  ('highly rated school', 'school_rating', false),

  -- Composite desirability. "Nice", "up and coming", "desirable" are
  -- laundered versions of whatever went into them.
  ('nice neighbourhood', 'neighbourhood_desirability', false),
  ('nice neighborhood', 'neighbourhood_desirability', false),
  ('good neighbourhood', 'neighbourhood_desirability', false),
  ('good neighborhood', 'neighbourhood_desirability', false),
  ('nice area', 'neighbourhood_desirability', false),
  ('good area', 'neighbourhood_desirability', false),
  ('bad area', 'neighbourhood_desirability', false),
  ('rough area', 'neighbourhood_desirability', false),
  ('desirable area', 'neighbourhood_desirability', false),
  ('up and coming', 'neighbourhood_desirability', false),
  ('gentrif', 'neighbourhood_desirability', false),
  ('better part of', 'neighbourhood_desirability', false),

  -- Crime. Reported-crime indices track policing intensity as much as
  -- risk, and correlate with race.
  ('low crime', 'crime_index', false),
  ('crime rate', 'crime_index', false),
  ('safe neighbourhood', 'crime_index', false),
  ('safe neighborhood', 'crime_index', false),
  ('safe area', 'crime_index', false),
  ('unsafe', 'crime_index', false),
  ('sketchy', 'crime_index', false),

  -- Familial status is protected. "Family-friendly" as a ranking axis
  -- excludes people without children as surely as it includes people
  -- with them.
  ('family friendly', 'familial_status', false),
  ('family-friendly', 'familial_status', false),
  ('good for families', 'familial_status', false),
  ('no kids', 'familial_status', false),
  ('childless', 'familial_status', false),
  ('adults only', 'familial_status', false),
  ('empty nester', 'familial_status', false),

  -- Direct references to protected classes.
  ('white', 'race', true),
  ('black', 'race', true),
  ('hispanic', 'national_origin', true),
  ('latino', 'national_origin', true),
  ('asian', 'race', true),
  ('african american', 'race', false),
  ('african-american', 'race', false),
  ('christian', 'religion', true),
  ('muslim', 'religion', true),
  ('jewish', 'religion', true),
  ('catholic', 'religion', true),
  ('church nearby', 'religious_institution_proximity', false),
  ('near a church', 'religious_institution_proximity', false),
  ('near a mosque', 'religious_institution_proximity', false),
  ('near a synagogue', 'religious_institution_proximity', false),
  ('english speaking', 'language_spoken', false),
  ('spanish speaking', 'language_spoken', false),
  ('young professional', 'age', false),
  ('retiree', 'age', false),
  ('senior only', 'age', false),
  ('no section 8', 'source_of_income', false),
  ('no vouchers', 'source_of_income', false),
  ('section 8', 'source_of_income', false),
  ('no housing benefit', 'source_of_income', false),

  -- Income as a ranking axis. Held for rent estimation, which is
  -- legitimate; offered as something to sort on, it is not.
  ('affluent', 'area_median_income_as_ranking', false),
  ('wealthy area', 'area_median_income_as_ranking', false),
  ('high income area', 'area_median_income_as_ranking', false),
  ('low income area', 'area_median_income_as_ranking', false),
  ('poor area', 'area_median_income_as_ranking', false)
ON CONFLICT (phrase) DO NOTHING;

-- ---------------------------------------------------------------------
-- The check
-- ---------------------------------------------------------------------
-- Returns one row per dimension the text appears to ask about, with
-- enough to explain the refusal. Nothing here is sensitive -- the whole
-- point is to say clearly what was matched and why -- so it is callable
-- by anybody, including an anonymous visitor typing into the box.
CREATE FUNCTION api.screen_search_text(p_text text)
RETURNS TABLE (dimension text, basis text, kind text, matched text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = gov, pg_temp
AS $$
  WITH t AS (
    -- Padded, so a whole-word match can look for spaces on both sides
    -- without a regex per phrase. Punctuation becomes space so "safe,
    -- quiet" matches "safe" and "family-friendly" survives as written.
    SELECT ' ' || regexp_replace(lower(COALESCE(p_text, '')),
                                 '[^a-z0-9 -]', ' ', 'g') || ' ' AS s
  )
  SELECT DISTINCT ON (d.dimension)
         d.dimension, d.basis, d.kind, p.phrase
    FROM gov.prohibited_phrase p
    JOIN gov.prohibited_dimension d ON d.dimension = p.dimension
   CROSS JOIN t
   WHERE CASE WHEN p.whole_word
              THEN t.s LIKE '% ' || p.phrase || ' %'
              ELSE t.s LIKE '%' || p.phrase || '%'
         END
   ORDER BY d.dimension, length(p.phrase) DESC;
$$;

GRANT EXECUTE ON FUNCTION api.screen_search_text(text)
    TO sdi_public, sdi_investor, sdi_agent, sdi_admin;

COMMENT ON FUNCTION api.screen_search_text(text) IS
    'Screens free text for requests that would steer. Runs BEFORE the '
    'parse: the output validator guards the shape of the criteria, which '
    'is a different problem -- "good schools" produces entirely legal '
    'keys.';

COMMIT;
