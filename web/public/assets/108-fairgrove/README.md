# 108 Fairgrove — listing photography

`front.jpg` goes here.

This directory is referenced by `core.property_media` for `SDI-2001`, inserted
by `sql/26_fairgrove_media.sql`, with `reveals_location = true` — so the image
is released on the same predicate as the street address. An investor who has
not signed the fee agreement is never told it exists.

**Known limitation.** Files under `web/public/` are reachable by anyone who
guesses the path, so the database gate controls who is *told* the url, not who
can fetch it. That is fine for the generated illustrations in `web/media.js`.
It is not fine for a genuinely location-revealing photograph, and before this
is exposed publicly the gated media needs to move behind an authorising route
or signed, expiring urls. Logged in section 11 of the system documentation.

**Provenance.** Recorded as `OPERATOR-SUPPLIED` in `gov.data_right`, marked
`unreviewed`. Who holds copyright in the photograph is not established — for a
listing photo that is usually the photographer or the listing broker, and a
seller's permission does not transfer it. `public_display` is `unclear`, which
`gov.may_use()` treats as refused.
