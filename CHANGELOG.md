# Change log

Release levels for the SDI Investment Property Marketplace. The current level
is in `VERSION`, and every published container image carries the matching tag.

Versions are `0.x` deliberately: nothing here has run against a production
GoHighLevel account or a live MLS feed, so the interfaces are not yet stable
enough to promise compatibility. The first release that has is `1.0.0`.

Format follows [Keep a Changelog](https://keepachangelog.com/). Dates are the
date the work was completed.

---

## 0.9.49 — 2026-09-05

**Less disclaimer.**

The manager card carried four lines explaining that a mailto: link opens a mail
client. It now says *"Opens your own email or text client."* — which is the only
part anybody needed.

Five other blocks of caution came down with it, all of them saying the point and
then arguing it:

- The flag note dropped *"That is the point — but it means the flag is a job for
  a person, not a mood."*
- The public-note warning keeps the warning, loses the second sentence.
- Projection assumptions lose *"and a second copy is a second answer."*
- The school-ratings note goes from 372 characters to 175. It still says schools
  are not scored and that catchment ranking is steering under the Fair Housing
  Act — the fact and the reason. The three clauses restating that it is never a
  column, never in the verdict and never sortable are gone; that is enforced in
  the schema and asserted at start-up, which is where it belongs.
- The showing note loses its trailing clause.

Left alone: the points break-even and mortgage-acceleration notes, and the guest
line on the landing page. Those explain how to read a number or what an option
gets you. They are not disclaimers, and shortening them would cost the reader
something.

Appropriate disclaimers are a question for after the proof of concept, not
during it.

---

## 0.9.48 — 2026-09-05

**Two sections were 20px wider than the rest of the sheet.**

`Deciding about using points` and `Mortgage acceleration` were `class="block"`
where every other standalone section is `class="block wide"` — and `wide` is the
only thing that supplies the 20px side margin. Without it they ran flush to the
sheet's edges, so their borders sat outside the line every other card holds.

Measured in Chromium at 1920px rather than inferred: every other section, and
the block grid above them, spans 536..1900. Those two spanned 516..1920. Now all
thirteen land on 536..1900.

The regression test asserts the invariant rather than the two section names: a
bare `class="block"` must never appear. A block is either inside the grid, where
it carries its placement class or is the manager card, or it stands alone in the
sheet, where it must be `wide`. Nothing is legitimately neither — which is why
this was possible to get wrong quietly.

---

## 0.9.47 — 2026-09-05

**The manager card is dark blue, because it is not property data.**

A, B, C and D are facts about the house, all typed into the same white card. The
manager is a person you contact, and the card's buttons *do* something rather
than record something. Styled like the blocks, it read as a fifth panel of
figures — and the one control on the sheet that reaches outside the building sat
in the same visual register as a bedroom count.

It is now `#13395c` with white text. Contrast was measured rather than eyeballed:
white 11.9:1, field labels 6.7:1, the caveat under the buttons 5.4:1, button text
9.6:1 — all past the 4.5:1 body text needs — and the button outline 3.4:1, past
the 3:1 a control needs. The first border colour tried came out at 2.1:1 and was
replaced.

Two things the dark ground broke, both fixed rather than left:

The shared `.ghost` button is white-on-white by design, so the action buttons
vanished. The card restates them with a light outline and its own hover.

The **unconfirmed** chip stays amber, because it means the same thing here as
everywhere else on the sheet — but it now uses a solid warm fill instead of a
translucent one. Translucent, the blue underneath mixed in and the chip came out
olive, which is not a warning colour. Opaque it stays amber, and reads at 7.1:1.

Rendered in Chromium and looked at, not inferred from the stylesheet.

---

## 0.9.46 — 2026-09-05

**Five settings the app reads were never passed to the container.**

Compose reads `.env` to *interpolate* a compose file. That is not the same as
putting a variable into the container: a name only reaches the process if the
service lists it under `environment:`. The two are indistinguishable from
outside, and the failure is silent — an option that never arrives behaves
exactly like an option deliberately left off.

`SDI_MEDIA_SENTINEL` landed in that state the day it shipped, which is how this
was found: the guard added in 0.9.45 reported *"no sentinel configured"* on a
host whose `.env` plainly configured one.

It was not alone. **`COOKIE_INSECURE` and `TRUST_PROXY` were both instructed by
the deployment guide as lines to add to `.env`, and neither had ever done
anything.** `COOKIE_INSECURE` is the only reason sign-in works over plain HTTP,
so path B of that guide could not have worked as written. `DEMO_PERSONAS` was
documented in the README the same way. `ANTHROPIC_AUTH_TOKEN` completes the set.

All five now pass through, in both compose files.

**`SDI_VERSION` and `SDI_COMMIT` deliberately do not.** They are baked into the
image by the Dockerfile's `ARG`/`ENV` at build time. Adding them to a compose
`environment:` with a `:-` default would overwrite the real stamp with an empty
string on every deployment without an `.env` entry — reporting the build as
`dev` precisely where knowing the build matters most. There is a test that
fails if anybody adds them.

**And a gap the new test found on its first run:** `docker-compose.yml` mounted
no media store at all. The container fell back to `/srv/media` with nothing
mounted there, so uploaded photographs went into the container's own writable
layer and died on the next recreate — which `docker compose up --build` does
routinely. Both the web and worker services now mount the store, as the release
file always did.

`web/test/compose-env.test.js` reads every `process.env` name the web tier
touches and checks each against the `web` service in both compose files.
Anything neither passed through nor listed in the test's `NOT_PASSED` map —
each entry carrying its reason — is a failure. This is the same class as the
Dockerfile `COPY` test: code and packaging drifting apart, where the code is
right, the packaging is wrong, and nothing fails loudly enough to notice.

---

## 0.9.45 — 2026-09-05

**The web tier refuses to start on a media store that is not mounted.**

Putting the photographs on a separate filesystem introduced a failure mode with
no symptom. The fstab entry carries `nofail`, and it should: without it a volume
that fails to attach makes the machine fail to boot and takes SSH with it, which
is far worse than missing photographs. But `nofail` means an absent volume stops
being an error. The host boots, the mount point stays an empty directory on the
OS disk, Docker bind-mounts that without complaint, and there is no failed
container and no warning anywhere to look at. New uploads land on the wrong
disk. Every photograph already taken is missing from the application while the
database still lists every one of them.

It looks like data loss, and nothing about it points at a mount.

`SDI_MEDIA_SENTINEL` names a file that exists only on the volume. Missing, the
server prints what is wrong and what is probably causing it, and exits. The
container then restart-loops, which is the intent: a stopped service is a
smaller harm than one quietly writing to the wrong disk, and it is the same
trade the fair-housing check has always made. The check runs *before* the
database check, which retries for about two minutes — there is no reason to
spend two minutes on the database before reporting a fault that is visible
immediately.

Opt-in, because it is a deployment fact rather than a code fact: a developer
running against `./media` has nothing mounted and nothing to assert. But where
it is not set, start-up **says so** rather than staying quiet, since the failure
being guarded against is precisely one that stays quiet.

A sentinel that resolves outside the media root is refused rather than accepted,
because a file elsewhere on the OS disk would satisfy the check while the store
was absent — which is the exact condition being tested for.

`web/test/media-mount.test.js` spawns the real server and reads its exit code
for all four cases. The behaviour under test is refusing to start, which no unit
test of a function can demonstrate.

---

## 0.9.44 — 2026-09-05

**The media path is per-host, and the documentation now says so.**

A second deployment put its media on a separate filesystem at a different path
from the first, and the obvious-looking fix was to symlink one to match the
other. Nothing needs to match. The container always sees `/srv/media`, the
database stores paths relative to that, and `SDI_MEDIA_DIR` is the one line
that differs between machines — which is what the variable is for. A symlink
would make two hosts look identical while adding a resolution step that can
break, and hide the fact that the store had moved at all.

`SDI_MEDIA_DIR` was not in `.env.example`, so the only mention of it was a
comment inside a compose file and one hard-coded path in the deployment guide,
written as though it were the answer everywhere. Both now say it is per-host.

Two operational facts recorded with it, because neither is discoverable from a
failure:

**Ownership.** The web container runs as `node`, uid 1000. A fresh filesystem
owned by root gives a write failure with nothing in it about which uid was
being refused.

**fstab.** If a separate filesystem is not mounted at boot, Docker bind-mounts
the empty mountpoint directory underneath it instead — silently, with no error
and no failed container — and every photograph appears to have vanished while
the database still lists them. Nothing about that failure points at the mount,
which is exactly why it is worth a line in `.env.example` next to the setting
that causes it.

---

## 0.9.43 — 2026-09-05

**A front door, and a block grid that holds its shape.**

**`/` is a landing page.** It used to serve the listings grid to anyone who
typed the address, so the product had no front: the first thing a visitor saw
was a wall of houses, with no statement of what this is, who it is for, or why
half the details were missing. Discovering the withholding by walking into it
reads as the site being broken.

The page says what the marketplace is, what is withheld before access is
granted and what is not, and offers the two ways in — sign in, or browse as a
guest. It uses the app's own palette rather than the second one it had been
carrying, so signing in no longer changes the look of the product halfway
through the first interaction anybody has with it.

Recognised visitors never see it: a session goes straight through, and so does
a demo persona when `DEMO_PERSONAS=1`. That includes `?persona=anon`, which
exists so the gated view can be looked at deliberately — testing the resulting
identity alone would have sent it back to the door and taken the anonymous view
out of the demo, so the door tests the choice, and tests it against the real
persona list. `/index.html` goes through the same check; one entrance and a
side gap is not an entrance.

**The guest cookie is a record of a click, not a credential.** `POST /api/guest`
sets it, and authorisation is entirely untouched: every request still resolves
through `identityFor()`, a guest is still `ANON` on `sdi_public`, and forging it
buys what typing `/index.html` bought before — the public band with addresses,
pins and photographs gated. A test asserts exactly that, with a hand-written
cookie, because the day that assertion fails the door has stopped being a front
page and become an authentication bypass. Signing out clears both cookies:
clearing only the session would drop the visitor back to the listings as a
guest and make signing out look as though it had not worked. `/` answers
`Vary: Cookie` so no shared cache can hand one visitor's answer to the next.
It is a POST answered with a 303 rather than a link, so it works with no
JavaScript and a reload does not re-post.

**The sheet reads A C / B D again.** The manager card sat third in the markup
so that it would land beside A and C — which held only while it was showing.
Hidden, the three-column grid pulled **B** up into the gap and the sheet read
`A C B / D`. Source order no longer decides anything: the blocks are placed
explicitly, A and C hold row 1 and B and D hold row 2 whatever else is on the
page, and the third column exists only when there is a card to put in it.

**And a second bug the measuring found.** The three-column rule was a viewport
breakpoint, but viewport width is not the width this grid gets: the rail and
the property list take about 516px before the sheet begins. At a 1320px window
the sheet is 804px while the columns ask for 1110, so the manager card was
pushed past the right edge and `.sheet`'s `overflow-x` hid it behind a sideways
scroll — invisible, from roughly 1320px to 1650px, with no overflow anywhere
for anyone to notice. It is now a container query against the sheet itself.

Verified in Chromium at 700, 1100, 1320, 1400, 1500, 1700 and 1920px, with the
card shown and hidden: the pairing holds at every width and nothing is clipped
at any of them. `web/test/layout.test.js` holds the three decisions those
breakages turned on, and says plainly that it checks the source rather than the
render — twice now the arrangement has been inferred from CSS rather than
measured, and both times it was wrong.

---

## 0.9.42 — 2026-09-05

**The deployment guide now matches what the deployment actually did.**

Three things in `deploy/README.md` were wrong in the way documentation is
usually wrong -- true when written, disproved the first time somebody followed
it on a real machine.

`raw.githubusercontent.com` caches for roughly five minutes. Fetching a file
moments after pushing a fix to it returns the OLD content, with no error and
no warning, so a fix that is verifiably in the repository appears not to be.
The guide now fetches with a cache-buster, and -- because a cache-buster is
not a guarantee -- states the two `grep`/`file` checks that prove which file
you got, and gives the `sed` that patches it in place when it is stale. Never
re-fetch to escape a cache.

`ufw` is not installed on a minimal image. The old text ran it unconditionally.
It now installs it first, opens 22 before enabling (the classic way to lock
yourself out of a remote host), and prefers a cloud firewall where there is
one. It also records the limit that makes host firewalls misleading here:
**Docker bypasses ufw for published ports**, writing its own iptables rules
ahead of ufw's. A published port is reachable whether or not ufw has a rule.
Not publishing it is the control; `ports: !override []` is why path A is safe.

`SDI_INTEGRATION_PASSWORD is not set` looks like a failure and is not. It is
the worker's login, the worker is behind an unstarted profile, and Compose
interpolates the whole file whatever the profiles say. Documented as expected,
along with the trap behind it: role passwords are issued by an init script
that runs **once**, on an empty volume, so adding the variable later leaves
the role NOLOGIN until it is altered by hand.

Also recorded: the three Caddy log lines that read as errors during a
successful first issuance, so nobody stops a working deployment to chase them.

---

## 0.9.41 — 2026-09-05

**Fixed the Caddyfile bind path in the public overlay.**

The overlay mounted `./Caddyfile`. With several `-f` files, Compose resolves
relative paths against the **first** file's directory -- `/opt/sdi`, not
`deploy/` where the file lives. So it looked one level too high, found
nothing, and Docker did what Docker does with a missing bind source: created a
**directory** at that path. A directory will not mount over a file, and the
error that surfaces is `mount ... not a directory`, which describes the
symptom and hides the cause.

Now `./deploy/Caddyfile`, with the reasoning in a comment beside it so the
next person moving this file does not re-derive it from a mount error.

---

## 0.9.40 — 2026-09-05

**Set the Caddy hostname and contact address for the sdi-prod deployment.**

`172-235-60-70.sslip.io` and `neilgreene0102@gmail.com`. sslip.io resolves the
IP-shaped name to that IP with nothing to register, which is what makes a
certificate possible at all: Let's Encrypt will not issue for a bare IP. The
contact address is not a login and is published nowhere -- it is the only
channel by which anyone learns a certificate is about to lapse.

---

## 0.9.39 — 2026-09-05

**An internet-facing deployment overlay, and a proxy-aware client address.**

`deploy/docker-compose.public.yml` layers Caddy over the release stack: TLS
terminated at the proxy with automatic issuance and renewal, http redirected
to https, HSTS, `nosniff`, `DENY` framing, and a referrer policy strict enough
that a gated address cannot leak through a `Referer` header to whatever a
shared PDF points at. Certificates live in a named volume, because re-issuing
on every restart hits a Let's Encrypt rate limit that locks you out for a week.

The web container **stops publishing a port** (`ports: !override []`). A
plaintext door beside a locked one is the door that gets used, and without the
`!override` tag Compose merges the two port lists and leaves it open.

`TRUST_PROXY` makes the sign-in log record the visitor's address rather than
the proxy's, reading the **last** `X-Forwarded-For` entry -- the one the proxy
appended, not the ones a caller can invent. Opt-in on purpose: believing that
header on a directly-exposed server lets anyone claim any address they like.

A bare `:80` vhost answers 404 to anything addressing the IP rather than the
hostname, because a vhost that answers to any `Host` answers to every scanner.

---

## 0.9.38 — 2026-09-05

**The manager card is a grid item, not a floating panel.**

It was a flex box sitting above the sheet, which put it alone in the top-right
corner and left a hole in the block grid beneath — the layout had to work
around it rather than containing it.

It is now the third item in `.blocks`, so it lands in the first row beside
**A** and **C**, shares their top edge and their card styling, and takes its
turn in the flow when the window is too narrow for three columns. Verified: A,
C and the card all start at the same y, and the card wraps below A at 1100px
instead of staying pinned.

---

## 0.9.37 — 2026-09-05

**The property manager, beside the property — and a bug that meant changing
the metro did nothing at all.**

### Fixed — changing the metro was inert
`onEdit('metro_code')` looked up an element called `f_metro_code`. The
dropdown's id is `metro_code` — no prefix, because it sits in the sheet header
rather than in a lettered block. So it read `.value` off `null` and **threw**,
which killed the change listener before `showFees()` ever ran.

Two consequences, neither visible as an error: **the fee line never refreshed
when you picked a different metro**, and the metro never entered the patch —
quietly making it unsaveable. A second throw hid behind the first: the changed
marker calls `.closest('.f')`, and the dropdown has no such wrapper.

This predates today's work. I described the behaviour from reading the code and
told the operator the fee line updates on selection; it did not, and the
correction is the reason this release exists.

### Added — the manager card
Beside the fee line: the manager, the contact, the current management and
leasing fees, and how they prefer to be reached. Driven by the **dropdown**
rather than the saved metro, so switching shows who you would be dealing with
before you commit. Records nobody has verified are marked **unconfirmed**
rather than passing as fact.

`core.property_manager` held a name and nothing else, so contact columns are
new. Fees stay keyed on **metro**, not manager — the same manager may charge
differently in two metros, which is the whole reason the model is metro ×
manager.

### Added — Email, Text, Call, and Follow-up
**They hand off; nothing is sent from here.** The buttons open your own mail or
messaging client with the listing in the subject line. There is no mail
transport, no SMS provider, and — more to the point — **no consent record**.
TCPA consent for a text is neither captured nor evidenced anywhere in this
system, and a platform that starts texting people because a button existed is a
platform with a problem it cannot prove its way out of. A `mailto:` hands the
message to a human who is accountable for sending it.

**A follow-up is a note with somebody's name on it and a date** — not a new
kind of thing. Notes already carry an author, timestamp, severity, visibility
and resolution, so a task is two more columns rather than a parallel table with
its own lifecycle. It lands in the same stream, drives the same flag, and
resolves the same way. Overdue is **derived, never stored**: a stored flag is
wrong from the moment the clock passes it. A task raised with no owner goes to
whoever raised it, because a task nobody owns is a wish.

---

## 0.9.36 — 2026-09-05

**Fixed: a placeholder in `.env` was treated as a working API key.**

`ANTHROPIC_API_KEY=sk-ant-...` — the literal placeholder, copied out of setup
instructions — is a non-empty string, so the truthiness check called it
configured. Every search the rules parser could not handle then made a doomed
API call and **waited out the full 8-second timeout** before falling back, for
as long as the placeholder stayed in the file.

The check is now a shape check: `sk-ant-` prefix, long enough, and no `...` in
it. Deliberately nothing more — whether a well-formed key is *valid* is the
API's business, and guessing at that here means rejecting a working key by a
regex somebody wrote from memory.

`.env.example` now says it outright: empty, or a real key. Nothing in between.

My own instructions created this trap by using `sk-ant-...` as the placeholder,
so the fix is in the code rather than in a warning nobody reads at the moment
they need it.

---

## 0.9.35 — 2026-09-05

**Documentation caught up with fourteen releases — including two places where
it had become factually wrong.**

The generated documents were last regenerated at 0.9.20. Everything from the
share feature onward was undocumented, and two statements had gone from
accurate to false.

### Corrected — claims that were no longer true
**§7.5 said the search box "is a rules parser today. It is not a language model
and it does not call one."** That was true when written and false as of 0.9.33.
Rewritten to describe what is actually there: rules first, Claude second, rules
again as the fallback, with the model returning criteria under strict tool use
and passing the same validator.

**§12 "What Is Not Built" listed "a language model behind the search box."**
Replaced with what genuinely is not built — legal review of the fair-housing
position, which no lawyer has looked at.

A document that is merely incomplete costs a reader time. One that is confidently
wrong costs them a decision.

### Added
- **§7.5.1** — refusing a search that would steer, and why the output validator
  cannot catch it
- **§7.9** — sharing a listing as a document: masked by default for everyone,
  the gate in the database rather than the checkbox, and the log
- **§7.10** — showing a property to a customer, and the `is_assigned()`
  correction
- **§10.7–10.9** — the property panel, the projection and its assumptions, and
  ratings/points/acceleration, with the reconciliation table against the
  operator's sheet
- **Test plan §14–16** — ten new manual cases across sharing, customer
  assignment and refused searches, four marked stop-work
- **Design Conflict Register C13** — the assignment/address conflict, recorded
  as **resolved** with what it would have cost and the naming lesson: one column
  called `assign_role` described two relationships wanting opposite answers, and
  the predicate reading it never looked at which one it had

### Fixed
- The suite counts in §11 were two releases stale (50 → 97). A document that
  states a number a reader can check in one command should not be wrong about it.
- §10.8 cited "the fee schedules in 10.9", which the new sections had renumbered
  into something else.

---

## 0.9.34 — 2026-09-05

**The rest of the workbook: section 3, points, and mortgage acceleration.**

### Added — section 3, ratings
Square feet, bedrooms, bathrooms, year built and year-5 cash flow against the
suggested minimums, each marked favorable or insufficient. Thresholds are held
per property so changing what "favorable" means for one deal does not restate
every other.

**The schools row is deliberately not there.** `gov.prohibited_dimension`
registers `school_rating` as a fair-housing proxy — ratings track the
demographics of a catchment, so a sortable score is steering, and a composite
verdict partly derived from one is the same thing laundered.

Anything the intake sheet carried is read back out of the **raw payload**, shown
to staff as prose beside a note saying why it is not scored, and is never a
column, never in the verdict, and never something anyone can sort on. A test
asserts the row is absent and the invariant is still clean.

### Added — deciding about using points
Financed amount, point cost, both rates, both payments, the monthly gap and the
break-even in months and years. Reconciles to your sheet: **$206,500 financed,
$2,065 for one point, 6.490% against 6.87%, $1,304 against $1,355** — all exact
or within a dollar. Break-even lands at 39.7 months against the sheet's 40.2;
the sheet divides by a rounded gap, so the daylight is arithmetic rather than
disagreement.

The rate without the point is an **argument with a default**, not a constant
buried in the maths — it is an assumption about the market, and the default
happens to land exactly on your 6.87%.

### Added — mortgage acceleration
Extra payment, years to payoff, interest over the full term against interest
paid accelerated, and the saving. **The schedule is walked month by month
rather than solved**: an extra payment made once a year is not a level annuity,
and every closed form that looks like it applies quietly assumes it is.

The extra payment defaults to the property's own five-year average cash flow
from section 1 — the money the house throws off, put back into the house — so
it moves when the assumptions do rather than being entered twice.

### Changed — "section 8" is no longer refused outright
Wrong for an investor audience. A tenanted voucher property has a
government-backed rent stream, which is a real underwriting fact somebody may
legitimately search for. What is prohibited is the **exclusionary** direction —
and in a growing number of states source-of-income discrimination is illegal on
its own account.

*"section 8 tenant in place"* now searches. *"no section 8"*, *"no vouchers"*,
*"not section 8"* and *"excluding section 8"* are refused. Tested both ways.

### Fixed
`FM999.9` leaves a bare trailing point on a whole number, so 2 bathrooms
rendered as `2.`. Stripped, rather than forcing a decimal nobody wrote — 2
reads as 2, 2.5 reads as 2.5.

---

## 0.9.33 — 2026-09-05

**A model behind the search box — step three of three.**

Steps one and two were the work. This step is small precisely because they
exist.

### The model returns criteria, never SQL
Text-to-SQL is the tempting version and the wrong one. The model fills in a
**fixed schema whose keys are the same allowlist** the rules parser produces
and the database constrains. `nlq.interpret()` validates the result exactly as
it validates a rules parse, and the query builder binds every value. A model
that hallucinates a key produces an ignored key.

**Strict tool use**, not "return me some JSON" — `strict: true` with
`additionalProperties: false` means the API itself guarantees the argument
object matches the schema. Asking for JSON in a prompt and parsing the reply is
the same idea with the guarantee removed. A test asserts the schema and the
allowlist agree in both directions.

### Rules first, model second, rules again as the fallback
*"3 bed duplex in Cleveland under 200k"* is handled by regexes: instantly,
free, identically every time. The model is asked only when the rules came back
with **nothing** — a partial parse is still a parse, and a model
second-guessing the regexes would make the same phrase behave differently on
different days.

That ordering also means the search box keeps working with no API key, no
network, or a slow request. **A search that depends on a third party being up
is a search that is down whenever they are.** No key is an ordinary state, not
a degraded one, and there is a test asserting it.

### Screening runs before the model is ever consulted
The order is not an accident. A model asked for *"a good school district"* is
far more willing than a regex to answer with a city — so it must never be
asked. 0.9.32's refusal fires first; a test asserts nothing is parsed, by
either path, once a request is refused.

### Model choice is yours
Defaults to `claude-opus-5`. `SDI_LLM_MODEL` overrides it — `claude-haiku-4-5`
is considerably cheaper per search and this is a classification task, but which
model runs is an operator decision, not one this code should make quietly.

`ANTHROPIC_API_KEY`, `SDI_LLM_MODEL` and `SDI_LLM_TIMEOUT_MS` are wired through
both compose files and documented in `.env.example`. The search box reports
`source: "rules"` or `"model"` so it is always clear which answered.

---

## 0.9.32 — 2026-09-05

**A search that would steer is refused, with a reason.**

Step two of three toward a search box with a model behind it — and the step
that has to exist first.

### Why the existing validator does not cover this
`nlq.interpret()` guards the **shape** of the criteria: a key not on the
allowlist is dropped, so a parser cannot invent a column to filter on. That is
a real protection and it is the wrong one for this problem.

Ask any parser — rules or model — for *"a good school district"* or *"a nice
family neighbourhood"* and it returns `{ city: 'X', min_beds: 4 }`: entirely
legal keys, passing every check, and a proxy filter all the same. **The
steering is in the request**, upstream of anything an output validator can
see. A model makes this worse rather than better; it is far more willing than
a regex to turn a vibe into a location.

The Fair Housing Act does not require that anyone intended it.

### What was built
`gov.prohibited_phrase` — natural-language phrasings mapped to the dimensions
already in `gov.prohibited_dimension`. The register stays the single source, so
adding a dimension and its phrasings extends the guard everywhere at once. A
lexicon compiled into JavaScript would be a second list to forget.

`api.screen_search_text()` runs **before** the parse. A match refuses with
**422** — the request was understood perfectly well, it is being declined —
and names what was matched and which basis it protects. Not a silent drop:
somebody asking for a good school district is usually asking in good faith and
deserves to be told what this system will not rank on, and what it offers
instead.

Coverage spans schools, composite desirability, crime indices, familial status,
source of income, religion, race, national origin, language and area income.

Tests assert both directions — eight steering phrasings refused, and five
ordinary searches **not** refused. A screening layer that over-refuses gets
switched off, so *"a safety deposit box"* must not trip on "safe".

### Fixed — a class-name collision that predates this
`.note` is the detail panel's gate **notice**: a bordered, padded block with its
own background and a 14px margin. `.parsed .note` only ever overrode the
colour — so the trailing half of every parse explanation has been rendering as
a floating block inside the search banner since that box was written. With a
one-line message it read as an odd inline chip and nobody looked twice; the
longer refusal made it unmissable. Reset explicitly, because two unrelated
things sharing a name is the actual fault.

### Fixed — a withdrawn deal stayed in the customer's list
`api.my_deal` returned closed deals, so a property withdrawn from a customer
kept appearing to them. Staff still see it in `api.property_interest`, which is
the audit record of what was shown to whom — the two views want different
answers here, which is the point of them being two views.

---

## 0.9.31 — 2026-09-05

**Showing a property to a customer — and the gate that nearly opened.**

### Fixed — a latent hole that this feature would have made real
`sec.is_assigned()` **ignored `assign_role` entirely**. A row with
`assign_role = 'investor'` opened the address gate exactly as an agent's did.
Nobody had noticed because there was exactly one such row in the whole demo.

The moment staff start assigning properties to customers — which is the entire
point of this release — **every assignment would have released the street
address, the exact map pin and the exterior photograph, silently**, and the fee
agreement would have stopped meaning anything.

`is_assigned()` now means *assigned to work this property*: an agent or a
lender, who need the address to do the job. A customer being shown a property
is a different relationship with a different answer. There is a test that
assigns to an unsigned customer and asserts the address is still `null`.

### Added — the workflow
Staff can show a property to a customer from the panel, move it through the
pipeline, and withdraw it. **It reuses `core.deal`** — which already links a
property, an investor, an agent and a stage with append-only history written by
trigger — rather than inventing a second concept beside it. "Assign this
property to this customer" is a deal at Inquiry.

- Assigning twice is somebody clicking twice, not a second interest.
- Withdrawing marks the deal lost; it does not delete it. The stage history is
  the record of what was shown to whom.
- Each row says **address released** or **address withheld**, because staff
  assign expecting a buyer to act, and "they cannot see where it is yet" is the
  fact that changes what happens next.
- Four more demo customers, deliberately mixed: two past the fee agreement and
  two not, so the same assignment can be watched behaving differently either
  side of that line.

### Not done, and worth saying
Agents cannot assign — internal staff only. That was your call for now, and the
function refuses rather than assuming.

---

## 0.9.30 — 2026-09-05

**The criteria vocabulary, so a search can ask an operational question.**

Step one of three toward an AI search. The model call is the small part; the
vocabulary it speaks is the work, and it is independently useful without any
model at all.

### Added — six operational criteria
`flag`, `min_roi`, `max_roi`, `no_photos`, `not_shared_days`, `fees_stale`.
Questions staff actually have and could not previously ask:

- *"properties flagged critical"*
- *"anything needing attention in Cleveland"*
- *"everything under 15% ROI"*
- *"listings with no photographs"*
- *"not been shared in 30 days"*
- *"houses on a stale fee schedule"*

The rules parser understands all of these today. When a model goes in behind
`parse()`, these are the keys it will speak — and it cannot invent others,
because `interpret()` drops what is not on the list.

### Staff only, enforced twice
Five-year ROI is derived from the offer and the underwriting — band 3. **A
filter on a hidden number is an oracle**: narrow it repeatedly and the result
set gives up the value one bisection at a time. Same attack the map viewport
had to be designed against.

So they are dropped in `interpret()` for a caller who is not staff, **and**
refused underneath: `api.property_return` and `api.share_log` return nothing to
a caller who may not read them. The second layer is the one that matters, being
the one that survives somebody deleting the first by mistake.

Dropped criteria are **reported**, not silently discarded — a saved search made
by an admin and later opened by an investor must not quietly return different
results with no explanation. Saved searches are re-interpreted against the
*current* caller, so saving is not a way to keep a filter you would be refused
if you asked for it.

### Fixed — a rate parsed as a price
*"under 15% roi"* matched both the rate rule and the price rule, and the money
heuristic that reads a bare "under 15" as $15,000 turned it into a filter
matching nothing — so the **ROI filter looked broken when the price one was
wrong.**

My first fix was a lookahead, and it was worse: it also killed the legitimate
price in *"over 300k best yield"*, where the rate word belongs to the sort and
has nothing to do with the number. Rates are now matched first and **consume
their own text** before the price rules read the string. One number, consumed
once, by whichever rule recognised it.

### Added — a test that the two allowlists agree
The criteria keys are constrained in two places: `KEYS` in `web/nlq.js` and the
`CHECK` on `core.saved_search`. They disagreed once already — the map viewport
keys were produced and then violated the constraint the moment somebody saved.
A test now reads the SQL file and asserts the two lists match, because that
failure only surfaces on save, long after the code that caused it was written.

---

## 0.9.29 — 2026-09-05

**The workbook's projection, sections 1, 2, I and II.**

### Added — the twenty-year projection
The panel now carries the deal-attractiveness table across five, ten, fifteen
and twenty years: net cash flow, equity increase, total gain, the averages, and
annual ROI, with projected property value underneath.

**It is reconciled against the sheet, not inferred from the labels.** Projected
value matches to the cent on all four horizons; equity increase matches to
within $20 (my rounded payment); ROI lands within 0.1pt. Three things it would
have been easy to get wrong, each worth more than a rounding:

- **Appreciation compounds on the after-improvement value**, not the offer and
  not total cost. A property bought under market shows that uplift on day one,
  not smeared across twenty years.
- **ROI is against cash out of pocket**, not total cost. Measuring against the
  financed total quietly divides by three and still reads plausibly.
- **Vacancy and management are percentages of rent**, so they grow with revenue
  rather than expenses. Treating them as flat costs understates them every year
  after the first by exactly the amount rent has risen.

Revenue and expenses drift apart on purpose — 3% against 2% — and that gap is
most of why year twenty differs from year one.

### Added — benchmark indicators, and the assumptions behind everything
Price, rent and cash flow per square foot, on **year one** as the workbook
heads them. Both formulas verified exactly against your sheet's own square
footage: $295,000 ÷ 1,632 = **$180.76**, and $2,175 ÷ 1,632 = **$1.33**.

That second one settled a question: **rent is taken at the middle of the
range**, exactly as improvements are costed at the middle of theirs. $1.33/sqft
is the midpoint of $2,100–$2,250, and neither end of it.

Sections I and II are editable per property and take effect immediately —
revenue and expense growth, appreciation, land value, selling costs and the
three tax rates. Held per property so revising the house view does not restate
a deal already agreed under the old one. Vacancy and the management fee are
deliberately *not* there: the property already carries them, and a second copy
is a second answer.

### Not built, deliberately — the schools row of section 3
`gov.prohibited_dimension` registers **school_rating** as a fair-housing proxy:
ratings track the demographics of a catchment, so offering one as a ranking
axis is steering, and the Act does not require that anyone intended it. The
same register covers composite FAVORABLE/INSUFFICIENT scores derived from it.
`api.security_invariants()` fails the build if either becomes a column in
`core` or `api`.

Jessica considering schools while underwriting is legitimate; offering it to a
buyer as something to sort on is not — and these figures are headed for
customer-facing screens. When section 3 is built it will read the figure from
the raw intake payload rather than promoting it to a column, so it can never
become a filter by accident.

### Fixed
`pct` does not exist in the panel — it has `pct1` for basis points and `pctIn`
for editable rates. ROI arrives as a fraction and needed its own helper;
overloading either would have produced a hundredfold error that still looked
like a percentage.

---

## 0.9.28 — 2026-09-05

**Three bugs a signed-in user hits immediately.**

### Fixed — the lead photograph was a line drawing
Opening a listing showed the generated illustration as the main image, with
the real photograph demoted into the thumbnail strip beneath it.

The detail query had **no `ORDER BY` at all**, and `api.property_media` is a
`UNION` (real rows plus the synthetic mask row), so the order it returns is
arbitrary and moves with the query plan. The browser uses `media[0]` as the
lead, so the panel showed whichever row came back first. It now orders the
same way `api.property_card` picks the card image — those two disagreeing is
how a listing shows one picture on the card and a different one when opened.

### Fixed — Favourites in the rail showed every property
The rail's Favourites entry navigates to `/?fav=1`, and **nothing read that
parameter**. The mode lived only in a variable set by a toggle button, so
clicking Favourites produced the full listing page with Favourites highlighted
in the menu — which reads as the filter being broken rather than absent.

The parameter is read before the first load, so the initial query is the right
one rather than being corrected a moment later. Toggling also keeps the address
bar honest now, since the rail decides its active entry by comparing path *and*
query.

### Fixed — no heart buttons on the favourites page
A consequence of the above, and invisible until it wasn't. Favourites could
previously only be reached by toggling, so a listings load had always happened
first and the browser still had an identity in hand. The moment `/?fav=1`
became a link people arrive on directly, that first reply carried no identity,
`canFavorite` was false, and the hearts were not drawn on the one page where
every row is a favourite.

Both payloads now build that block with one function, so they cannot drift.

---

## 0.9.27 — 2026-09-04

**Share, reachable from the top — and a Create PDF button that answers.**

### Fixed — the button that did nothing
Create PDF was **disabled** until the recipient field held three characters,
and said nothing about why. A greyed-out control with no stated reason is
indistinguishable from a broken one: you press it, nothing happens, and there
is nowhere to look.

It stays live now and refuses out loud — *"Say who this is going to first."* —
putting the cursor in the field that fixes it. The server's rule has not
changed and there is a test holding it: asking politely from a browser was
never the boundary.

### Fixed — a failed share used to take the page with it
The download was triggered by navigating the tab to the PDF url. That works
until the server answers with an error instead of a file, and then the listing
is replaced by raw JSON. It goes through a hidden iframe now, which takes the
attachment and stays out of the way either way.

### Added — a share control in the panel header
Beside close and full-screen, so sharing does not require reading to the bottom
of the listing first. Sharing is a decision people make at the top of a page,
having recognised the property — not after scrolling past the roof year. The
button at the foot stays; both open the same dialog.

---

## 0.9.26 — 2026-09-04

**Fixed: 0.9.25's web container would not start.**

### Fixed
`server.js` gained `require('./share')` and the Dockerfile's `COPY` line — which
names each module explicitly — did not gain `share.js`. The image built, pushed,
passed all 71 tests, and then crashed on its first require. The container
reported *Started* and the port refused connections.

That COPY line has now gone stale twice: once when `media.js` and `nlq.js` were
added, and again here. The comment above it described the first occurrence as a
warning; a warning is not a mechanism. **It is a glob now** — `COPY *.js ./` —
which covers exactly the server's modules, since tests live in `./test` and
browser code in `./public`.

Two guards, because this class of break lands as far from the mistake as it is
possible to get:

- The image **resolves every local import at build time**, so a missing module
  fails the build in CI rather than the first request against a deployed
  container.
- A test reads the Dockerfile and asserts every module `server.js` imports
  would actually be copied. Nothing that runs against a source tree can
  otherwise see a file the *image* is missing. It fails against the old COPY
  line and passes against the glob.

---

## 0.9.25 — 2026-09-04

**Share a listing as a PDF — masked by default, for everybody, and logged.**

### Added — the document
A **Share as PDF** button on every listing produces a one-page summary: the
full financial detail, the property's specifications, and a provenance line
naming who prepared it, for whom, and when.

**Masked is the default for every caller, including staff.** Not "masked for
people who cannot see the address" — masked for everyone unless the person
generating it deliberately says otherwise for that one document. The common
case is sending a property to a prospect who has signed nothing, and a default
that leaks on the common case is not a default, it is a trap.

**The numbers are never withheld.** Price, rent, expenses, NOI and cap rate go
on every document, masked or not. An investor decides on the cash flow and only
then signs for the identity of the house; a masked document that also hid the
yield would be a brochure for nothing.

What masking removes: street address, unit, parcel number, coordinates, and
the photograph — replaced by a branded stand-in of a *different* house, not a
watermark over the real one. The parcel number travels with the address or not
at all: it is one search away from an owner name and a plat map.

Each document states its own kind at the top — *ADDRESS AND PHOTOGRAPH
WITHHELD* or *CONTAINS RELEASED PROPERTY DETAILS* — because the person who
receives it has no idea this system has two modes.

### Added — the gate, in the database
`unmask=1` is a **request**. `api.share_context()` answers it against
`sec.can_see_address()`, and where the two disagree the database wins and the
document is masked. Written as `requested AND permitted` in one expression, so
no path consults only one of them. The browser hides the control from anyone
who may not use it, but hiding it is a courtesy — the refusal is the boundary,
and there is a test that asks for `unmask=1` anonymously and gets a masked
document back.

### Added — the log
Every generated document writes a row: which property, who made it, **who they
said it was going to**, whether it carried the address, and when. The recipient
is required and must be more than a placeholder — the question the log exists
to answer is "who has this", so a document that cannot answer it is not
generated at all. It is self-reported, and honestly so: this system hands a
file to a browser and has no idea what happens next.

The log is recorded *before* the bytes are produced. If the write fails, no
document is made — an unlogged share is the thing the feature exists to
prevent. Staff see it as a **Shared with** section on the property panel, with
released rows tinted; an audit screen nobody passes is an audit log nobody
reads.

### Fixed
- The masking test was passing vacuously. pdfkit compresses its content
  streams, so searching the raw bytes for an address finds nothing whether the
  address is on the page or not. The test now inflates the streams and decodes
  pdfkit's hex-encoded text, and the companion assertion — that a *permitted*
  unmask does put the address on the page — is what proves the masked case
  isn't passing by accident.
- A policy is not a grant. `core.share_event` had its row policy but no
  `GRANT SELECT`, and `api.share_log` is `security_invoker`, so the privilege
  is checked as the caller. The panel failed with *permission denied* while
  having every policy it needed.

---

## 0.9.24 — 2026-09-04

**The build says which build it is, and static files stop going stale.**

### Added — the build number, in the rail
`v0.9.24 · 0ac71a4` sits under Sign out on every screen, signed in or not. A
deployed change that is not visible looks exactly like a change that was never
deployed, and telling those two apart used to mean going and reading a
registry.

The commit is shown as well as the version, because two builds can carry the
same version — a fix pushed without a bump is the normal case — and the
version alone would say they are the same when they are not.

**Single source.** The version lives in the repository's `VERSION` file and
nowhere else; CI reads it at build time and bakes it in with the commit SHA.
An image built any other way honestly reports `dev` rather than inventing a
number: a wrong version is worse than no version, being the thing somebody
trusts while chasing the wrong bug. There is a test asserting the reported
version equals the file on disk.

### Fixed — static files were served with no freshness information at all
No `Cache-Control`, no `ETag`, no `Last-Modified`. That does **not** mean "do
not cache" — with nothing to go on, a browser falls back to heuristic caching
and reuses a `.js` or `.css` for as long as it likes without asking. A
deployed change to the rail, a stylesheet or a page script could sit there
invisible behind a stale copy, and the only cure anybody knew was a hard
refresh.

Static responses now carry `Cache-Control: no-cache` with an ETag and
Last-Modified. `no-cache` is the confusing name for the right behaviour:
**store it, and ask before every use.** The ask is conditional, so an
unchanged file costs a 304 with no body rather than a re-download, and a
changed one arrives immediately without anybody being told to clear anything.

The ETag combines size and mtime — mtime alone has one-second resolution, and
two edits inside the same second during a deploy would look identical.

### Fixed
`buildLine()` was originally called `build()`, which is already the name of the
function that constructs the rail. The template called the rail builder
instead, which returns a Promise and re-entered the whole thing.

---

## 0.9.23 — 2026-09-04

**Removed: the Profile entry in the rail.**

### Changed
The footer already carries the signed-in person's photograph, name and role
and links to the same page. A second door to one room made the rail longer
without making anything reachable, so the **You → Profile** group is gone.

The footer now shows an active state when you are on the profile page. It is
the only way in, so it has to be able to say when that is where you are —
otherwise the rail goes blank on arrival, which reads as having navigated out
of the application. The initials circle inverts on the active row, since it
was otherwise the same accent colour as the row highlight and disappeared
into it.

### Fixed
`run.sh` — the local, no-Docker path — was still loading schema files up to
`45_note_summary.sql` and stopped there, so a local install had no note
severity, no flags and no filter. The Docker image and `db-rebuild.sh` were
both current; this third hand-maintained list of the same files had fallen
behind. The three lists now agree on every schema file.

---

## 0.9.22 — 2026-09-04

**Filter the properties panel by flag.**

### Added
Four chips under the search box in **Admin → Properties**: All, Critical,
Attention, Clear. Each carries a count, and the counts are computed over the
**whole** list rather than the filtered one — a tally that collapses to the
current filter makes it impossible to see there is anything else worth
looking at.

- **Clear is a real choice, not the absence of one.** "Show me the properties
  with nothing outstanding" is a different question from "show me all".
- Clicking the active chip clears it. Otherwise the only way back to
  everything is to find All, and people reach for the thing they just pressed.
- A chip that can only return nothing is **dimmed, not hidden**. "No critical
  properties" is itself worth being able to see, and a chip that vanishes takes
  its own answer with it.
- The empty result says *None flagged critical* rather than *0 properties*,
  which reads as an empty database rather than as a filter doing its job.
- Adding or resolving a note refreshes the counts, but deliberately does
  **not** re-filter the list: pulling the open property out from under
  somebody because the note they just wrote moved it out of the current
  filter is a worse surprise than a count catching up a moment later.

### Fixed
The search clause was three ORs with no parentheses around it. Appending a
flag filter would have produced `ref OR city OR address AND flag` — binding
the flag to the address alone and silently returning the wrong rows. Bracketed,
with a test that asserts search and flag **intersect** rather than union.

---

## 0.9.21 — 2026-09-04

**Fixed: uploading a profile photograph did nothing at all.**

### Fixed
Choosing a photograph opened the file dialog, and then nothing happened — no
avatar, no error, no sign the click had registered.

The upload route read the request body under the **default 8,192-byte cap**
that every other JSON endpoint here wants and no photograph on earth fits
inside. A 29 KB avatar was rejected by the transport before a single rule
about images got to judge it. The route now passes its own limit, sized to
clear base64 of the largest image it claims to accept — setting the transport
limit equal to the image limit is how an upload that passes every stated check
dies in the plumbing.

**Why it was silent rather than merely broken**, which is the more useful half:
an over-length body destroyed the socket immediately, so no response was ever
written. The browser saw a network failure with no status code, and the page
had nothing to react to. Over-length now drains and answers **413**; past a
hard ceiling it is a flood rather than a large upload, and only then does the
socket go.

And the page had no error handling on that path at all, so anything thrown
went nowhere. Every path through the uploader now says something — wrong file
type, too large (with the actual size), the server's own message, or a request
that never arrived. Silence is the one outcome a person cannot act on: they
cannot tell a rejected file from a broken server from a click that missed.

The result is reported **beside the photograph** rather than in the details
card below it. A message three inches out of view reads, exactly, as nothing
having happened.

### Added — tests
The old test posted a few hundred bytes of synthetic flat colour and passed
throughout. Two new ones: a photograph-sized photograph (noise, so it cannot
compress under the very limit being held down) uploads, re-encodes and serves
back; and an oversized body is **answered** rather than dropped.

---

## 0.9.20 — 2026-09-04

**Notes with a name on them, a rail to get around by, and a flag when
something is wrong.**

### Added — notes
Notes on a property are rows, not a text box. Each one records who wrote it
and when, is public or internal, and cannot be destroyed by the next person
to write one. Removing is soft: the note leaves the listing, the record that
it was written stays.

Public notes travel with the listing, which is a sharper edge than it looks:
they are band 1, as visible as the price, to a visitor who has signed nothing.
The gate protects the `street_address` column, not prose that mentions the
address — so the composer says so, in the moment somebody picks "public".

### Added — severity, and the flag it drives
A note can be an ordinary **Note**, need **Attention**, or be **Critical**.
Three levels, and the middle one earns its place: with only two, everything
that is not a disaster is ordinary, so people mark things critical to get them
noticed and the red flag stops meaning anything.

**Severity without resolution is a ratchet.** A critical note written in March
is still critical in June unless somebody can say it was dealt with — so every
flagged note can be resolved, with who said so, when, and what settled it, and
the property's flag is computed from what is still open. A green *Clear* chip
therefore means "nothing outstanding", which is a claim a person has made,
rather than "nobody has written anything alarming lately", which is not.

Where it shows: a chip under the address in the panel, a coloured pennant on
the picker row (red and amber only — twenty-five green dots hide the two that
are not), and on marketplace cards **for staff only**. The flag is derived
from the notes the caller can see, so a buyer's is green whenever no public
note is open, and green on a listing page reads as this system vouching for
the house. It is not in a position to. There is a test asserting an anonymous
caller gets `ok` on a property carrying an open internal critical.

### Added — the application rail
The flat *Properties* button is now a left rail on every page: Browse and
Favourites, an Admin group with Properties and Intake review, You with Profile,
and the signed-in person's photograph and name above Sign out. Active state is
matched on path *and* query, so two entries pointing at the same page under
different filters do not both light up.

### Added — profiles and avatars
`/profile.html` edits your display name and photograph; email and role are
read-only, because they are what the database makes authorisation decisions
with. Photographs are re-encoded on the way in, which strips EXIF — a staff
portrait taken on a phone otherwise arrives carrying the GPS coordinates of
wherever it was taken.

Avatars appear beside the name in the rail and on every note. Initials stand
in until the photograph loads, and stay if there is none: an author without a
photograph is the normal case, not a failure.

### Added — the last note, where the question gets asked
Whose note, and when, now shows on the picker row and on marketplace cards,
so an internal user can see a property has been touched without opening the
panel. *Which* note is "last" is decided by the row policy rather than by the
query: staff see internal notes so theirs may be an internal one, everyone
else gets the latest public.

### Fixed
- `.note.open` in the panel collided with an unrelated `.note.open` in
  `app.css` — a gate notice that has been opened — and painted critical note
  text green on a red card. The panel's class is `unresolved` now, which says
  what it means anyway.
- The severity picker resets to *Note* after each note is added. A composer
  left on *Critical* turns the next three ordinary notes into emergencies by
  inattention.
- Writing a note repaints its own picker row rather than reloading the list,
  which used to lose the scroll position and the selection.

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
