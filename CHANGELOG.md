# Change log

Release levels for the SDI Investment Property Marketplace. The current level
is in `VERSION`, and every published container image carries the matching tag.

Versions are `0.x` deliberately: nothing here has run against a production
GoHighLevel account or a live MLS feed, so the interfaces are not yet stable
enough to promise compatibility. The first release that has is `1.0.0`.

Format follows [Keep a Changelog](https://keepachangelog.com/). Dates are the
date the work was completed.

---

## 0.9.19 — 2026-09-04

**A picture of the property, in the panel.**

### Added
- A thumbnail on every row of the property picker and beside the address in
  the sheet header, so somebody editing the numbers can see which house they
  are editing without opening another screen.
- Read through `api.property_media` rather than named directly, so it obeys the
  same rules as everywhere else. Staff are past the gate, so this is the real
  photograph — and if that ever stopped being true, the panel would show the
  mask rather than silently bypassing the gate for an internal screen.
- A listing with no photograph shows no frame rather than an empty one: a blank
  box in the header reads as a failure, and the line underneath already says
  how many photographs there are.

---

## 0.9.18 — 2026-09-04

**The properties panel, and the fee model behind it.**

### Added — the panel
An internal screen at `/property-admin.html`, laid out like the workbook:
the same A/B/C/D/E blocks in the same order with the same field names, so
somebody who has worked the sheet for years does not have to learn where
anything went. Derived figures sit under the inputs they come from and update
as you type. Edited fields are marked until saved; every save reports which
fields changed and writes them to a history strip.

**It reconciles to your sheet exactly.** Against 401 NW 71st St: total cost
$307,084, day-one equity −$7,084, down payment $88,500, financed $206,500,
monthly payment $1,304, cash outlay $100,584, 18 days on market. There is a
test asserting all of it.

One figure did not reconcile at first and the difference was informative:
**improvements are costed at the middle of the range, not the top.** Costing at
the high end — the obvious guess — came out exactly $1,250 heavy, being half
the $2,500–$5,000 range.

### Added — property managers and versioned fees
The metro dropdown is (metro × property manager), and the manager sets the
management and leasing fees. Two Kansas City entries differ only by manager.

**Fee schedules are append-only and dated.** A fee change is a new row with a
later `effective_from`, never an `UPDATE` — there is no `UPDATE` policy on the
table for anyone, so the rule is enforced by the absence of a way to break it.
A property copies fees once, deliberately, and records which schedule version
they came from. Raising a fee in March does not restate a deal agreed in
January, and the panel says plainly when a property is on an older schedule.

### Added — the underwriting layer
`core.property_underwriting` holds what the workbook holds and the listing
never did: offer, suggested range, asking, market value after improvements,
improvement range, closing and mortgage costs, other fees, financing terms,
rent range, leasing fee. **Band 3 throughout** — an offer and a day-one equity
figure tell a buyer the operator's margin.

### Deliberately not included
- The workbook's **Schools Rating**. `gov.prohibited_dimension` lists
  `school_rating` as a proxy for race and national origin, and the standing
  invariant fails the build if it appears in the `api` schema. Storing it as a
  sortable number is one careless view away from being a filter. It belongs in
  internal notes as prose.

### Fixed
- `api.property_save` compared **text renderings**, so `numeric(12,2)` rendering
  1234 as "1234.00" made every re-save of an unchanged form look like a change.
  Open the panel, press Save, and the history gained "1234.00 → 1234". The
  comparison now happens in the column's own type, inside the `UPDATE`.
- `toInput` trimmed trailing zeros with `/\.?0+$/`, which strips them whether or
  not there is a decimal point — a 30% down payment rendered as **3%**.
- A `SECURITY INVOKER` function reading `core` fails for every reader role, none
  of which holds `USAGE` on that schema. Third occurrence in this branch. Views
  resolve references at definition time and survive it; function bodies do not.

---

## 0.9.17 — 2026-09-04

**The markets list, and a pool of masks rather than one.**

### Added — `core.metro`
The workbook's Metro dropdown, all twelve entries, with the exact labels and in
the order it shows them so an import matches without renaming anything.

**Three of them are not places.** *No Monthly Fee*, *Hybrid* and *Resi\** describe
how a property is managed or charged for, and *Kansas City-OS* / *Kansas City-SH*
are one city under two arrangements. Entirely reasonable in a spreadsheet, and a
problem the first time a market filter goes on the public site — it would offer
**Hybrid** as a place to buy a house. So `kind` records whether an entry is a
`market` or an `arrangement`, and `metro_name` carries the geography where there
is one. Nothing is lost and the two jobs can be separated when somebody decides
how.

The classification is **inferred from the labels and unconfirmed** — recorded in
a `classified` column so the guesses are visible rather than passing as fact.

`core.property.metro_code` is backfilled only where the city matches exactly one
market: Birmingham (1) and Tampa (3). Kansas City's two listings stay null
because the city alone does not say which arrangement, and 21 are unassigned
rather than guessed.

### Changed — masking draws from a pool
An unapproved caller now sees a mask that has **nothing to do with the
property**, even when the property has photographs of its own — not its own
exterior under a watermark. That distinction is the point: a watermark over the
real photograph still shows the roofline, the street trees and the neighbour's
fence, anyone who has driven the block recognises it, and a reverse image search
does not read watermarks.

The property is paired with a mask by hashing its id rather than re-rolled per
request. Unpredictable from outside, identical on every load — a card that
changes picture on every load reads as broken and defeats caching — and carrying
no information either way, because whichever is drawn is a photograph of a
different house.

### Note
- The six masks shipped are **numbered placeholders**. Dropping the branded
  images over `web/public/assets/mask/mask_01.jpg` … `mask_06.jpg` (and 720px
  copies under `thumb/mask/`) is the whole change; no rebuild.

---

## 0.9.16 — 2026-09-04

**Photographs are masked until access is granted.**

One rule now covers the address, the map and the pictures: released together on
`sec.can_see_address()` — internal staff, the assigned agent or lender, and an
investor whose agreement is on file. Everyone else sees a single masked image
per listing, and every financial figure in full.

### Changed
- The row policy on `core.property_media`, not the view. Masking only in the
  view would leave the table readable by any reader role. The policy decides
  who gets a row at all; `api.property_media` then supplies one synthetic
  masked row where there is nothing to show, so a listing still has a picture
  and the page still has a shape.
- The old rule gated only images flagged `reveals_location`, on the reasoning
  that a front elevation identifies a house and an interior does not. That was
  always an assumption: interiors identify a property to anyone who has walked
  it, an agent recognises a kitchen, and a reverse image search does not care
  which room it is. Kept as `media_mode = 'exterior_only'` for the record; the
  default is `masked`.
- `sec.disclosure.mask_url` points at the stand-in. Replacing the file at that
  path changes every listing at once, with no rebuild.
- The three gate notices became one. The address, the photographs and the map
  are released together on a single predicate, so three separate banners
  suggested three separate gates.

### Note
- The mask currently shipped is a **generated placeholder** — a flat house
  silhouette with a padlock, deliberately not photographic. The masked image
  from the workbooks replaces it by overwriting
  `web/public/assets/masked.jpg`.

---

## 0.9.15 — 2026-09-04

**No map without access.**

Coordinates are band 2 now, on the same predicate as the address. A point on a
map is an address written differently.

### Changed
- `api.property` withholds `lat` and `lng` entirely unless
  `sec.can_see_address()` is true. **Hiding the map in the browser would not
  have been this** — the coordinates travelled in the listings payload, so a
  hidden map would have left them one View Source away: protection that looks
  real on screen and is not there at all.
- The map panel is not rendered for a caller with no positions; the listings
  take the full width, the *Search this area* toggle goes with it, and a note
  says the map is part of the address and what unlocks it.
- Who gets a map: internal staff, the assigned agent or lender, and an investor
  whose fee agreement is on file. An agent gets a map of their own book.

### The setting
- `sec.disclosure.map_mode` names the three positions and selects one:
  **`none`** (now), `approximate` (the ~1km fuzzed pin this system used to
  show), `exact`. This question has already moved once and the design conflict
  register still has C3 and C5 open, so the alternative is a setting rather
  than a deleted branch. Changing the answer is an `UPDATE`, not a migration.

### Fixed
- `favoriteIds()` runs a query that is *expected* to fail for roles that cannot
  hold favourites — and an expected failure still aborts the transaction, so
  every statement after it fails too. It only worked because it happened to be
  last; adding one query after it broke every listing request. Wrapped in a
  `SAVEPOINT` now.
- A bounding box left in a bookmarked url no longer empties the results for a
  caller who has since lost map access.
- **`[hidden]{display:none !important}`, once, for the whole stylesheet.** Any
  author rule setting `display` beats the browser's own `[hidden]` rule. That
  left `.lightbox{display:flex}` as an invisible full-window layer swallowing
  every click, and `.filters label{display:flex}` showing a control that had
  been hidden.

---

## 0.9.14 — 2026-09-04

**The listings follow the map.**

### Added
- Panning or zooming the map re-runs the search against the visible area.
  Zoom into Florida and you get the Tampa listings and nothing else. A
  **Search this area** toggle in the filter bar turns it off; the scope line
  reads *in this map view* while it is on, and an empty result says the map is
  the reason and offers the way out.
- The viewport is in the address bar, so a copied link reproduces both the
  filters and the region — and reloading one restores the map position before
  the first query, rather than showing a different area than the link asked for.

### The part that matters
- **The filter runs on the coordinate the caller was shown, not the real one.**
  For a gated listing `api.property` publishes a position offset by roughly a
  kilometre. Filtering on the true coordinate would have let anyone shrink a
  box around a listing until it dropped out of the results and read the address
  off the boundary — a binary search around the gate, using the search feature
  itself. It also keeps the list and the pins honest: a listing is in the
  results exactly when the pin you were shown is on screen. There is a test
  asserting a box drawn on the true position does *not* match.

### Fixed while building it
- `readForm()` is also what **Save search** sends, so folding the viewport into
  it meant a saved search carried a bounding box — which `core.saved_search`'s
  known-keys constraint rejects outright, and which would anyway have made a
  saved search quietly remember a map position. The viewport is merged in
  `load()` now; intent alone is what gets saved.
- `drawMap()` refits the map to the results after every draw. With the map as
  the filter that is a feedback loop — fit to what is on screen, the box
  shrinks, fewer results, fit again — and the map zooms itself to nothing while
  you watch. Suppressed while the toggle is on.
- `nlq.interpret()`, the validator every criterion passes through, rejected
  negative numbers. Correct for a price or a bedroom count and wrong for a
  longitude: every listing here is in the western hemisphere, so the filter
  would have been silently dropped. Coordinates now have their own bounds
  rather than the general rule being loosened for everything.

---

## 0.9.13 — 2026-09-04

**Favourites show the same photograph the search grid does.**

### Fixed
- The favourites list showed generated drawings while every other page showed
  photographs. The card image was chosen by a correlated subquery written
  inside the web tier's *search* query, so `api.my_favorite` — a different view
  — had no such column and the page fell back to the generated illustration.
  Nothing failed; one page just quietly showed something else.

  The fix is not a second copy of the subquery. `api.property_card` now defines
  the card image once, and both the search grid and `api.my_favorite` read it.

- A test asserts the two agree, listing by listing. Written against
  `/api/listings` rather than `/api/view` — the latter is the older demo
  endpoint and returns neither `property_id` nor the card image, so a test
  against it would have proved nothing about either page.

### Note
- `primary_image` deliberately lives on `api.property_card` and **not** on
  `api.property`, which would have been simpler. `core.property_media`'s row
  policy is written in terms of `api.property`, so a subquery over
  `api.property_media` inside `api.property` makes the policy depend on the
  view that depends on the policy — a recursion PostgreSQL discovers at query
  time, not at definition time.

---

## 0.9.12 — 2026-09-04

**A property you can actually look at.**

### Added
- **Full screen.** A ⤢ button beside the close button widens the detail panel
  to the whole window. Not simply a wider column: above 1000px the photographs
  take the left and the figures the right, so the space goes to the pictures
  rather than to a 1600px line of text. The choice is remembered per browser —
  somebody who wants the big view wants it for every listing.
- **See all N photos**, on the lead image. A full-window page of every
  photograph, captioned, four across, with a *shows the street* badge on
  anything gated.
- **A large single-photograph view.** Click any tile — or any image in the
  panel — for the full file with a caption and an *n of N* counter. Arrow keys
  move and wrap in both directions.
- Escape unwinds **one layer at a time**: large view → grid → listing. Closing
  everything at once loses both the photograph and the listing it came from.

### Notable
- Photographs are grouped by caption, and the **headings appear only when they
  group more than one image**. With one photograph per room — every listing
  today — a heading above each is a full-width divider that forces one tile per
  row and says nothing the caption does not. They return the moment a listing
  has several kitchen shots. Grouping is by caption rather than filename
  because the caption comes from the database and is the field staff will edit;
  filename sniffing would work for the seeded assets and break for anything
  served from the media store, where the name is a uuid.

### Fixed
- `.lightbox{display:flex}` overrode the `hidden` attribute — an author rule
  setting `display` beats the browser's `[hidden]{display:none}` — leaving a
  transparent full-window layer over the page that swallowed every click. The
  listing cards simply stopped responding and nothing looked wrong. Caught by
  driving the page in a real browser, not by reading it.
- Section 8 of the Feature Test Plan was stale: it still said three photographs
  per listing and told the reader to look for the word ILLUSTRATION, which has
  not been true since the supplied photography landed.

---

## 0.9.11 — 2026-09-04

**The supplied interiors actually reach the listings.**

The 75 interior photographs were committed in 0.9.8 and nothing pointed at
them. Every gallery still showed a real card photograph followed by three
generated drawings, which looked worse than the drawings alone did.

### Added
- `33_interior_media.sql` — each listing's living room, kitchen and bedroom,
  paired by the same deterministic `listing_ref` ordering the exteriors use, so
  a listing's card and its interiors stay together across a rebuild.
- 720px thumbnails for all 75 (15.4 MB → 3.6 MB), used in the gallery strip.

### Changed
- **The gallery showed only three images.** `media.slice(1, 3)` was fine when
  everything after the card was a drawing and stopped being fine the moment
  real interiors arrived — the bedroom never appeared and nothing said so. It
  now renders every photograph, in a strip that wraps to however many there
  are, instead of a two-column grid built around exactly three.
- The generated `hero.svg` at position 0 is removed. It was the card image
  until `30_stock_media.sql` put a photograph in front of it; since then it has
  been a drawing sitting between a real photograph and three real interiors.
  The renderer still draws one on demand, so the client-side fallback for a
  file that will not load is unaffected.
- Captions read *"Living area — representative photo, not the actual
  property"*. Same reason as the exteriors: an investor who walks the house and
  finds a different kitchen stops trusting the numbers too.

### Notable
- These stay **static assets in the image**, not rows in the media store built
  in 0.9.8. The store is for operational photography that staff add and manage;
  seeding a demo into it would make its contents a mixture of things that can
  be purged and things that come back on the next deploy.
- `reveals_location` is false on all of them. The flag means *identifying*, not
  *interior* — a photograph of a different kitchen identifies nothing.

---

## 0.9.10 — 2026-09-04

**Say which CPU feature is missing, instead of a stack trace about `endsWith`.**

### Fixed
- `scan-media.js` reported `Cannot read properties of undefined (reading
  'endsWith')` when `sharp` would not load. That message comes from **sharp's
  own error handler**: it collects the reasons the load failed and then formats
  them with `err.code.endsWith(...)`, and one of the collected errors has no
  `code`, so the formatter throws and takes the real reason with it.

  The loader now re-runs the checks sharp would have reported and names the
  cause. In this deployment the cause was `_isUsingX64V2()` returning false —
  sharp's Linux x64 prebuilds are compiled for the **x86-64-v2**
  microarchitecture, and a hypervisor presenting a generic CPU model does not
  advertise it. Proxmox's default `kvm64` has no SSE4.2, so the binary loads
  and sharp then refuses it.

  The fix is on the host, not in the image: set the VM's processor type to
  `host` or `x86-64-v2-AES`.

### Worth noting
- The build-time assertion added in 0.9.9 did its job and still could not catch
  this. It runs on a GitHub runner with a modern CPU, so sharp loads there. No
  image-side check can see a missing CPU feature on a machine it will never run
  on — which is the argument for the runtime message naming it precisely.

---

## 0.9.9 — 2026-09-04

**A worker image that can actually load its image library.**

### Fixed
- The published worker image installed `sharp` cleanly and then could not load
  it, so `scan-media.js` refused to run. `sharp` ships prebuilt native binaries
  as per-platform optional dependencies, and **musl is a different binary from
  glibc**. The image was built `FROM node:22-alpine` (musl) while the lockfile
  and every test were made on glibc, so `npm ci` resolved a binary the runtime
  could not use. The worker now builds `FROM node:22-slim`, matching the
  platform the lockfile and the tests were made on.
- The Dockerfile now **asserts sharp loads and encodes a JPEG at build time**,
  so an image that cannot do its job fails the build instead of being published.
  This is the same failure mode as the earlier web image that copied two of its
  four modules: passes every test, breaks only in the registry.
- `scan-media.js` printed *"sharp is not installed"* for every failure,
  including a native binary that was present but would not load. It now prints
  the real error and says plainly that this is a broken image rather than a
  configuration problem — the wrong message sent the diagnosis in the wrong
  direction.

---

## 0.9.8 — 2026-09-04

**Photographs stop being part of the build.**

Until now a photograph was a file inside the container image: adding one meant
a commit, a build and a deploy, so staff could not add one at all. Worse, a
file under `web/public/` is fetchable by anyone who guesses its path — the
database decided who was *told* a photograph existed, never who could *fetch*
it. That was survivable only because every image in the system is stock with
nothing to leak.

### Added
- **A media store on a shared mount**, outside the image. A host path rather
  than a Docker named volume, because `down -v` destroys named volumes and the
  schema flow needs `down -v`; photographs must not die with a rebuild. Four
  zones: `inbox/` (staff drop files here), `store/` (machine-managed),
  `quarantine/`, `purged/`.
- **`/media/file/<media_id>`** — the authorising route. It re-asks the database,
  *as the caller*, before any bytes leave. A row the caller cannot see is a
  **404, not a 403**: a 403 would confirm the photograph exists, which is half
  of what the gate withholds.
- **`scan-media.js`** — ingest, reconcile and purge. Ingest re-encodes every
  file, which is what strips EXIF, then thumbnails, stores under an id and
  registers it as pending.
- **`core.media_event`** — who published what, and when.
- **Lifecycle columns** on `core.property_media`: `storage_path`, `state`,
  `published_at`, `purge_after`, `legal_hold`, `content_sha256`.
- 17 tests for the above, including one that builds a JPEG carrying GPS
  coordinates and asserts they are gone from the stored bytes.

### Notable decisions
- **The filename in `store/` is the `media_id`.** Anyone holding a file
  identifies it with one query and no lookup table; `ls store/SDI-1009/` is the
  complete set for a listing. The row still stores its own `storage_path`,
  because a listing reference can be corrected and a derived path silently
  stops resolving when it is.
- **EXIF stripping is not housekeeping.** A phone photograph carries GPS
  accurate to a few metres. Untouched, the exact address sits inside the file —
  the gate intact in the database and bypassed in fact. It runs on the share
  path too, because a file copied from a PC never passed through a browser.
- **Arrival fails closed.** Every photograph lands pending, unpublished, and
  `reveals_location = true`. Publish-and-correct-later leaves the gate open
  between arrival and review, and no correction un-discloses anything.
- **Deletion happens twice.** Unpublish is immediate and reversible; destruction
  waits out a retention window. Legal hold beats a due retention date, or a
  well-behaved cleanup job destroys exactly the evidence somebody needs.
- **Reconcile reports and fixes nothing.** A row with no file may be a restore
  that failed; a file with no row may be the only copy of something.
- **The scanner can register but not publish.** No `EXECUTE` on
  `api.media_publish` for `sdi_integration` — an unattended process that can
  publish defeats the review step entirely.

### Fixed during the build
- The route first read `core.property_media` directly. The reader roles hold
  `SELECT` on that table but **no `USAGE` on schema `core`**, so it would have
  404'd every photograph for everyone except an admin. Now read through
  `api.media_bytes`.
- The scanner first read `core.property` directly. Every policy on that table is
  scoped `TO` a named application role and `sdi_integration` is not one, so the
  read returned **zero rows rather than an error** — every folder reported as an
  unknown listing while the scanner looked like it was working. Now
  `api.listing_id()`.

  Both were invisible to a test suite running as `sdi_test_admin`. There is now
  a test that runs the scan as the role the worker actually connects as.
- Authorisation for the scanner was first a `session_user = 'sdi_integration'`
  special case, which could not be tested without connecting as that exact role.
  Replaced with a service account person, so the scanner authorises through the
  same predicate as everyone else and the audit trail names it.

---

## 0.9.7 — 2026-09-04

**The media lifecycle, written down before it is built.**

### Added
- `docs/Property-Media-Lifecycle.pdf` (13pp) — the operational requirements for
  listing photography: how a file arrives, how it acquires meaning, how it is
  maintained, and when it is destroyed. Section 9 states plainly which parts
  exist today, so a requirements document is not mistaken for a status report.

  The parts worth reading first:

  - **§2.2** — the file's name on disk *is* its `media_id`, so anyone holding a
    file can identify it with one query. That is the answer to "which files do I
    find when I have to do maintenance."
  - **§3.2** — a phone photograph carries GPS coordinates in EXIF. Re-encoding
    on ingest is what stops the exact address sitting inside a file the platform
    exists to gate. It has to be on the share path, not only the browser path.
  - **§6.3** — a purge is not complete when the file is gone: thumbnails, caches
    and backups all outlive it. The policy has to say what it does about backups,
    because "we deleted it" and "it is gone" are different claims.
  - **§6.4** — legal hold beats retention, or a well-behaved cleanup job destroys
    exactly the evidence somebody later needs.

### Fixed
- The document list in `README.md` was stale: it named two of the six documents,
  gave the wrong page count for one, pointed at a renamed runbook, and said 63
  worker tests when there are 70.

---

## 0.9.6 — 2026-09-04

**A hovered map pin you can read.**

### Fixed
- Hovering a listing on the map turned the pin's background dark but left the
  price in the dark slate that `.pin.gated` sets for a white background —
  1.6:1 contrast, effectively invisible. `.pin.hi` now restates the foreground
  as white (9.4:1). It sets `border-color` rather than `border`, so a gated pin
  keeps its dashed edge; that dash is what says the position is approximate.
  The SVG fallback map already did this correctly, which is why it only showed
  on the Leaflet map.
- The web test suite skipped every database test when PostgreSQL was
  unreachable, and reported `34 tests, 0 fail` with twenty-seven of them never
  run. That reads as green. The skip is now opt-in — `SDI_TEST_NO_DB=1` for the
  pure-logic tests on a machine with no database, and a hard failure naming the
  fix otherwise.

---

## 0.9.5 — 2026-09-04

**The photographs, at a weight a page can carry.**

The supplied files are 1280px and average 380 KB. Twenty-five of them on one
listings page is 9.4 MB, which is not a page — it is a download.

### Added
- `core.property_media.thumb_url`: a downscaled copy of the same picture, 720px
  and ~84 KB. Null means there is no smaller version, so every reader coalesces
  rather than assumes. It carries no visibility of its own — it is the same
  photograph, released or withheld with the row that owns it, so a thumbnail is
  never a way around a gated image.
- `web/public/assets/thumb/` — the 25 downscaled copies. 9.4 MB → 2.1 MB.
- An image fallback in `app.js`: a media row can outlive the file it names
  (108 Fairgrove's `front` is seeded before the photograph has been supplied,
  and a mistyped path looks the same), so a failed load falls back to the
  generated illustration instead of a broken-image icon.

### Changed
- `/api/listings` returns `coalesce(thumb_url, url)` as `primary_image`; the
  detail gallery keeps the full file for the lead image and uses thumbnails for
  the strip beneath it.

### Fixed
- The 25 photographs are now committed. They had been placed on the deployment
  host only, and `web/Dockerfile` copies `public/` at build time — so the
  published image would have carried none of them.

---

## 0.9.4 — 2026-09-04

**Supplied photography on the cards.**

### Added
- `30_stock_media.sql` points each of the 25 listings at one of the supplied
  photographs, paired deterministically by listing reference so a rebuild does
  not reshuffle them.
- `/api/listings` now returns `primary_image`, read through
  `api.property_media` rather than naming a file — so a gated photograph can
  never become a card thumbnail by accident. The generated illustration remains
  the fallback for any listing without one.
- `gov.data_right` `STOCK-PHOTOGRAPHY`, recorded **unreviewed**: the source and
  licence of the supplied images are not established, and a stock licence, an
  attribution-required licence and a broker's listing photograph look identical
  on disk.

### Changed
- These images are **not photographs of these properties**, and that one fact
  decides two things. `reveals_location` is false, because the flag means
  *identifying*, not *exterior* — a photograph of a different house identifies
  nothing. And every one is captioned as representative, because a stock
  exterior presented without qualification reads as a picture of the property.

---

## 0.9.3 — 2026-09-04

**A cooler palette, and cards that look like different properties.**

### Changed
- Palette moved from a neutral ground with amber accents to a light blue one.
  At card size the warm accents read as brown, and twenty of them in a grid
  looked tired. The gated state is now a soft steel blue rather than rust —
  kept clearly lighter and greyer than the interactive accent, because if
  "locked" and "clickable" look alike the banner stops meaning anything.
- Listing illustrations redrawn in daylight colours: cool siding, slate roofs,
  pale interiors with one saturated accent each.

### Added
- A card hero keyed to **property type** — a duplex has two doors, a condo is
  a stack — and varied by property id, so a grid of twenty looks like twenty
  properties rather than one repeated image. Deliberately generic: no street,
  no number, no surroundings, so it is not location-revealing and is not
  gated. The real exterior stays behind `reveals_location`.

### Fixed
- `docs/gen_detail.py` crashed on listings with null sizes — the tracked Irvine
  address and any unfilled workbook import. It now skips them rather than
  inventing figures, which is what the rest of the system exists to prevent.

---

## 0.9.2 — 2026-09-03

**A duplicate-listing bug, found by loading the same workbook twice.**

### Fixed
- Loading a workbook twice and releasing both batches created **four listings
  for two addresses**. Validation ran at load time only, so a row that was
  clean when the file arrived stayed "clean" through approval and release even
  after the same address had been released from another batch.

  `api.release_intake_rows()` and `api.approve_batch()` now re-validate
  immediately before acting. Approval of a stale duplicate is refused up
  front, and a row approved before the conflict appeared is skipped at release
  with the reason rather than raising.
- The first attempt at that fix silently did nothing. `SELECT * INTO r FROM
  intake.row WHERE row_id = r.row_id` self-references the record being
  overwritten: `r` is cleared as the assignment begins, the `WHERE` matches
  nothing, `r` comes back NULL, and every test on it is NULL rather than
  false — so the guard never fired and the insert proceeded into a constraint
  violation instead of a clean skip. The row id now goes into its own
  variable first.

### Added
- `docs/Design-Conflict-Register.pdf` — the KAVADOO design document (v1.0, April
  2026) compared against the build. **12 conflicts** where the two specify
  different things, kept separate from **16 gaps** (specified, not built) and
  **8 unspecified** items (built, not mentioned). A gap needs scheduling; a
  conflict needs a decision, and mixing them buries the decisions.

  The two that matter most are upstream of the rest: whether the investor is
  ever shown the address at all, and whether the fee is paid at sign-up or at
  closing. The document and the build answer both differently, and the second
  means the gate as built would never open under the document's model.
- `ux_property_live_address` — a partial unique index on
  `core.property`, so no code path can list the same address twice while it is
  live. Scoped to `draft`, `active`, `coming_soon` and `pending`, because an
  address genuinely recurs across years as it sells and is relisted.
  Re-validating closes the path the intake code owns; the index closes the
  others.
- A regression walkthrough in `29_intake_tests.sql` covering exactly the
  sequence that produced the duplicates.

---

## 0.9.1 — 2026-09-03

**Fixes found deploying 0.9.0.**

### Fixed
- The intake loader failed with `permission denied for schema api`. The role
  it runs as, `sdi_integration`, was granted SELECT on the two views it reads
  but never `USAGE` on the schema holding them, which is a no-op that fails at
  run time. Same for `gov`, one error later.

  It passed every local test because every local test loaded as the test
  fixture role, which already had both. **A grant is only real when the role
  that uses it is the role that was tested** — so the loader is now exercised
  as `sdi_integration` against a freshly rebuilt database.
- The start-up fair-housing check retried for only ~25 seconds. A first boot
  that loads the whole schema takes longer, so the web container hit its FATAL
  path and recovered only because of the restart policy. `depends_on:
  service_healthy` does not help: the postgres entrypoint runs init against a
  unix socket, so the healthcheck passes while TCP is still refused. Budget is
  now ~2 minutes.

### Added
- `docs/Deployment-Runbook.pdf` — the numbered procedure, with the expected
  output at each step and a troubleshooting table built from what actually went
  wrong on the host.

---

## 0.9.0 — 2026-09-02

**Spreadsheet intake, the review queue, and a test plan.**

### Added
- Schema `intake`: staged property loads. `intake.batch` (one file, one upload),
  `intake.row` (one property, holding both the verbatim payload and our reading
  of it), `intake.zip_centroid`.
- `tools/workbook-to-json.py` — reads the SDI analysis workbook's `Import` sheet
  by label and emits intake JSON. Python, because it needs a spreadsheet library
  the worker deliberately does not carry.
- `worker/tools/load-intake.js` — loads that JSON, validates every row, and
  prints what a reviewer has to decide on.
- `/admin.html` — the staff review screen. Approve, reject and release, by row
  or by batch, with the verbatim payload one click away.
- `api.review_intake_rows()`, `api.approve_batch()`, `api.release_intake_rows()`,
  `api.release_batch()`; views `api.intake_batch` and `api.intake_row`.
- `docs/Feature-Test-Plan.pdf` — 23 pages of acceptance tests, including a
  section whose every test is expected to be refused.
- `docs/Deployment-Runbook.pdf` and `docs/DEPLOY-RUNBOOK.md` — the numbered
  deployment procedure, with the expected output at each step, verified against
  the live host rather than written from the compose file. Includes a
  troubleshooting table mapping each symptom seen during deployment to its
  actual cause.
- `VERSION`, `CHANGELOG.md`, and System Documentation section 15,
  *Build and Release*. Both PDFs read the version and change log at generation
  time, so they cannot describe a release history the repository does not have.
- System documentation section 10, *Getting Properties In*.

### Changed
- Validation splits blocking errors from warnings. A reviewer forced to clear
  every oddity before releasing anything stops reading the oddities.
- Release records provenance against `gov.data_right` `SDI-WORKBOOK`, recorded
  **unreviewed**: the financial modelling is SDI's own, but the property
  description in the same file is verbatim MLS listing copy whose republication
  right is not established.

### Fixed
- `api.release_intake_rows()` did not close a batch it had emptied, so a batch
  released row by row read "open" forever.
- The review screen's select-all box kept its checked state across the redraw
  that follows every action while the selection was cleared, so the next click
  unselected everything.
- Worker integration tests proved the fee gate *opens* and never shut it again,
  leaving Marcus's gate open and silently destroying the demo's central contrast
  on every test run. Now restores the fixture and asserts the restore worked.

### Security
- The workbook's "Schools Rating" and its composite deal score are kept in the
  raw payload and never promoted to a column. Both are registered fair-housing
  proxies; `api.security_invariants()` fails if either name appears in `core` or
  `api`.

---

## 0.8.0 — 2026-09-02

**Data rights, territory, and regulatory compliance.**

### Added
- Schema `gov`: `data_right`, `data_right_territory`, `data_right_use`,
  `obligation`, `property_provenance`, `territory`, `regulation`,
  `regulation_control`, `prohibited_dimension`, `policy`.
- `gov.may_use(property_id, use, scope)` — the single question the publication
  path asks. Confirmed, unexpired, in territory, and granting this use: all
  four, not a score.
- Register of 17 regulatory regimes with the trigger condition for each and
  where the constraint is actually enforced. Ten currently have no control and
  say so.
- `docs/data-rights-intake.md` and `worker/tools/record-data-right.js`.
- System documentation section 9, *Data Rights and Compliance*.

### Changed
- Governance ships in **advisory** mode. A control that refused to publish
  without a confirmed right would take a working marketplace off the air over
  paperwork nobody has transcribed yet. Flipping `gov.policy` to `blocking` is
  the go-live gate; the standing invariant then keeps it shut.
- `api.security_invariants()` gained three governance checks.

### Security
- Fair housing enforced three ways: the prohibited-dimension register is a
  table, the standing invariant fails if any listed dimension is exposed as a
  readable column, and the web tier refuses to start if its filter allowlist
  intersects the register.

---

## 0.7.0 — 2026-09-01

**Listing status tracked against an external source.**

### Added
- Schema `feed`: `listing_source`, `property_external`, `observation`,
  `status_change`, `status_map`, `review_flag`, `manual_check`.
- `feed.observe()` and `feed.reconcile()`. An observation never writes a status
  directly; it is recorded, then reconciled.
- Four source adapters behind one interface: manual, RESO Web API, RentCast, and
  a consumer portal left deliberately unimplemented.
- `worker/tools/check-listings.js` — the nightly sweep, oldest check first.
- System documentation section 8, *Where Listing Data Comes From*.

### Changed
- Two deliberate asymmetries: an `error` outcome is never read as an absence,
  and a listing returning to market is acted on the **first** sighting because
  escrow fails.

---

## 0.6.0 — 2026-09-01

**The marketplace.**

### Added
- Map-based browsing: filters across the top, map on the left, cards on the
  right, drill-down panel over it.
- `core.market_area`, `core.property_detail`, `core.property_media`,
  `core.saved_search`; views `api.property_detail`, `api.property_media`,
  `api.my_favorite`, `api.my_saved_search`.
- Favourites, saved searches, and a plain-English search box (a rules parser,
  not a model — the seam and its validator are what had to be right first).
- `web/media.js` — deterministic generated listing illustrations, so no stock
  service and nobody's copyright.
- 16 further demo listings spanning 1–6 beds, $87k–$581k, nine cities.
- System documentation section 7, *The Marketplace*.

### Security
- Photographs inherit the address gate. `property_media.reveals_location` marks
  exterior views, released on the same predicate as the street address —
  without it the gate would reopen through the picture gallery.
- Gated listings are drawn on the map as a fuzzed ring rather than a pin,
  because their coordinates are deliberately offset.

---

## 0.5.0 — 2026-09-01

**Authentication.**

### Added
- `core.credential` and `core.session`, both RLS-forced with no policy at all,
  reachable only through `SECURITY DEFINER` functions.
- `scrypt` password hashing, session cookies, a login page.
- Account lockout after five failures; a password change revokes every session.

### Changed
- Nothing beneath it. Not one policy, view or grant was modified to add
  authentication — the database contract was always "here is a role and an
  actor id", and a session now supplies those instead of a dropdown.
- The demo persona switcher is off unless `DEMO_PERSONAS=1`.

---

## 0.4.0 — 2026-08-31

**Deployable from published images.**

### Added
- `.github/workflows/release.yml` — publishes `db`, `web` and `worker` to GHCR.
- `docker-compose.release.yml` for pulling by tag; Portainer instructions.

### Changed
- Role credentials are taken from the environment at first start rather than
  baked in. A role given no password stays `NOLOGIN`, failing at connect time
  rather than quietly granting access.

---

## 0.3.0 — 2026-08-31

**Review queue, deal pipeline, and the system documentation.**

### Added
- `core.review_queue` and review actions with an allowlist on accepted CRM
  edits.
- Deal pipeline, stage history and per-party visibility.
- `docs/System-Documentation.pdf`, generated from the repository and a freshly
  built database rather than written from memory.

---

## 0.2.0 — 2026-08-31

**The GoHighLevel bridge.**

### Added
- Schema `ghl`: id mapping, webhook events, transactions, fee agreements,
  sync state, outbox.
- Integration worker: webhook intake with signature verification, outbox drain,
  document and transaction sync, EspoCRM migration passes.
- `docs/GHL-Interface-Specification.pdf`.

### Security
- The fee gate requires **both** a completed document and a paid transaction.
  A signed-but-unpaid document does not open it.

---

## 0.1.0 — 2026-08-31

**Foundation: the visibility model.**

### Added
- PostgreSQL schema with three visibility bands enforced by row-level security
  and column grants, not by application code.
- Four-schema separation: `core` (tables, no app-role access), `sec`
  (predicates), `api` (masking views), plus the roles that use them.
- `api.security_invariants()` — must always return zero rows.
- Demo dataset and the Marcus/Ruth pair: same role, same query, one timestamp
  of difference.
