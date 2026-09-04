# Change log

Release levels for the SDI Investment Property Marketplace. The current level
is in `VERSION`, and every published container image carries the matching tag.

Versions are `0.x` deliberately: nothing here has run against a production
GoHighLevel account or a live MLS feed, so the interfaces are not yet stable
enough to promise compatibility. The first release that has is `1.0.0`.

Format follows [Keep a Changelog](https://keepachangelog.com/). Dates are the
date the work was completed.

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
