#!/usr/bin/env python3
"""
Generates the Feature Test Plan PDF.

    python3 docs/generate_test_plan.py

Written to be executed by somebody who did not build the system. Every test
says what to do, what should happen, and -- the part that makes it worth
running rather than skimming -- what it proves. A test whose purpose is
opaque gets marked "pass" by a tired person.
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from _style import (BODY, H1, H2, CODE, CAP, NOTE, GOOD, CT, CS, BLANK, TOC1, TOC2,
                    CELL, CELLB, para, mono, hdr, buls, table, build_doc, S,
                    INK, MUTED, ACCENT, RULE, OK, WARN)
from reportlab.lib import colors
from reportlab.lib.units import inch
from reportlab.platypus import PageBreak, Paragraph, Preformatted, Spacer, Table, TableStyle
from reportlab.platypus.tableofcontents import TableOfContents

OUT = "docs/Feature-Test-Plan.pdf"

with open(os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                       "VERSION")) as _fh:
    VERSION = _fh.read().strip()

TID  = S("tid", fontName="Helvetica-Bold", fontSize=9.5, leading=13, textColor=ACCENT,
         spaceBefore=11, spaceAfter=3)
PROV = S("prov", fontName="Helvetica-Oblique", fontSize=8.5, leading=11.5,
         textColor=MUTED, spaceBefore=3, spaceAfter=8, leftIndent=4)

doc = build_doc(OUT, "Feature Test Plan",
                "SDI Investment Property Marketplace — Feature Test Plan",
                "Step-by-step acceptance tests for the marketplace, the gate, and the controls")
E = []; A = E.append


def case(tid, title, steps, expected, proves=None, warn=False):
    """One test. Steps on the left, what should happen on the right."""
    A(para(f"{tid} &nbsp;&nbsp;{title}", TID))
    rows = [hdr(["Do this", "This should happen"])]
    for s, e in zip(steps, expected):
        rows.append([s, e])
    A(table(rows, [2.7*inch, 3.2*inch]))
    if proves:
        A(para(f"<b>What it proves.</b> {proves}", NOTE if warn else PROV))


# ------------------------------------------------------------------ cover
A(Spacer(1, 1.6*inch))
A(para("SDI Investment Property Marketplace", CT))
A(Spacer(1, 0.06*inch))
A(para("Feature Test Plan", CS))
A(para("What to click, what should happen, and what each result proves", CS))
A(Spacer(1, 0.5*inch))
A(table([
    ["Release", mono("v" + VERSION) + " \u2014 record this on the results sheet"],
    ["Scope", "The marketplace, the address gate, and the controls behind them"],
    ["Audience", "Anyone with a browser. No development experience assumed"],
    ["Duration", "About an hour for the browser tests; 15 more for the database checks"],
    ["Prerequisite", "A deployed stack with the demo dataset loaded"],
], [1.1*inch, 4.3*inch], header=False, zebra=False))
A(PageBreak())

# --------------------------------------------------------- page 2, blank
A(Spacer(1, 3.4*inch))
A(para("This page is intentionally blank.", BLANK))
A(PageBreak())

# ------------------------------------------------------- page 3, contents
A(para("Contents", H1))
A(Spacer(1, 3))
toc = TableOfContents()
toc.levelStyles = [TOC1, TOC2]
toc.dotsMinLevel = 0
A(toc)
A(PageBreak())

# ================================================================== 1
A(para("1.  Before You Start", H1))

A(para("1.1  What you need", H2))
A(table([
    hdr(["Item", "Value"]),
    ["The address", mono("http://&lt;host&gt;:3000/") + " &mdash; type " + mono("http://") +
     " explicitly. Browsers now upgrade bare hostnames to HTTPS, and the demo does not serve TLS, so omitting it produces " + mono("ERR_SSL_PROTOCOL_ERROR") + " and looks like a network fault"],
    ["A browser", "Anything current. Two windows, or one plus a private window, so two people can be signed in at once"],
    ["Optional", "Shell access to the host, for section 13 onward"],
], [1.0*inch, 4.9*inch]))

A(para("1.2  The accounts", H2))
A(para("Every one of these has the password " + mono("demo1234") + ". They exist to be "
       "signed into and they are published in a public repository, so they are worth "
       "exactly nothing outside a demonstration.", BODY))
A(table([
    hdr(["Sign in as", "Role", "Fee agreement", "Exists to show"]),
    [mono("marcus@example.com"), "Investor", "NOT signed", "The gate shut"],
    [mono("ruth@example.com"), "Investor", "Signed", "The gate open &mdash; the comparison that matters"],
    [mono("ines@example.com"), "Investor", "Signed", "The second brand (KAVADOO), at concierge pricing"],
    [mono("tom@example.com"), "Agent", "n/a", "An agent sees only their own assignments"],
    [mono("priya@example.com"), "Agent", "n/a", "A second agent, to prove the two are isolated"],
    [mono("dan@example.com"), "Staff", "n/a", "Everything, including internal costs"],
    [mono("jpool2@yahoo.com"), "Staff", "n/a", "Administrator"],
], [1.55*inch, 0.65*inch, 0.85*inch, 2.85*inch]))
A(Spacer(1, 4))
A(para("<b>Marcus and Ruth are the pair to keep in mind throughout.</b> Same role, same "
       "permissions, same query. The only difference between them is one timestamp in one "
       "data column. Wherever this document asks you to compare two windows, it is asking "
       "you to look at the consequence of that timestamp.", GOOD))

A(para("1.3  Resetting between runs", H2))
A(para("Some tests change data &mdash; a favourite, a saved search. To start clean:", BODY))
A(Preformatted("cd /opt/sdi\n"
               "docker compose down -v      # -v destroys the database volume\n"
               "docker compose up -d\n"
               "docker compose logs -f db   # wait for 'ready to accept connections'", CODE))
A(para("The " + mono("-v") + " deletes the database. That is correct while everything in it "
       "is demonstration data and wrong the moment it is not.", NOTE))

# ================================================================== 2
A(para("2.  How To Use This Document", H1))
A(para("Each test is numbered, states what to do and what should happen, and then says what "
       "it proves. Read that last line. A test whose purpose is opaque gets marked "
       "&ldquo;pass&rdquo; by a tired person at four in the afternoon, and the whole exercise "
       "is then worth nothing.", BODY))
A(table([
    hdr(["Result", "Means", "Do this"]),
    ["Pass", "Observed exactly what the right-hand column says", "Move on"],
    ["Fail", "Observed something else", "Record what you saw, and the URL. Keep going &mdash; later tests may explain it"],
    ["Blocked", "Could not run it", "Say what stopped you"],
], [0.7*inch, 2.6*inch, 2.6*inch]))
A(Spacer(1, 5))
A(para("Section 11 is different from every other section. <b>Those tests are expected to be "
       "refused</b>, and a refusal is the pass. If any of them succeeds, stop and report it "
       "before doing anything else.", NOTE))
A(para("Record results on the sheet in section 14.", BODY))

# ================================================================== 3
A(PageBreak())
A(para("3.  The Anonymous Visitor", H1))
A(para("Start signed out. This is what a stranger who found the link sees.", BODY))

case("T3.1", "The marketplace loads",
     ["Open the address in a fresh window or a private window.",
      "Look at the top-right of the page."],
     ["Filters across the top, a map on the left, listing cards on the right.",
      "It says <b>Not signed in</b>, with a <b>Sign in</b> link."],
     "Nothing requires an account to browse. That is the product: the listings are the "
     "advertisement.")

case("T3.2", "Addresses are withheld",
     ["Read the banner under the filter bar.",
      "Read the grey line on any card.",
      "Count the cards."],
     ["It explains that street addresses and exterior photographs are withheld until the "
      "$750 platform fee agreement is signed, and that everything else is shown in full.",
      "A padlock, then city and state only &mdash; <i>address released after signing</i>. Never a street number.",
      "<b>17 properties.</b>"],
     "The gate is stated in plain words before the visitor runs into it. A gate somebody "
     "discovers by surprise reads as a bait-and-switch; one explained up front reads as terms.")

case("T3.3", "Every map pin is approximate",
     ["Look at the map.",
      "Read the legend, bottom-left.",
      "Hover a bubble."],
     ["Every price bubble sits inside a soft dashed ring.",
      "Two entries: <i>exact location</i> and <i>approximate &mdash; address gated</i>.",
      "The tooltip says <i>approximate location</i>."],
     "The coordinates sent to this visitor are deliberately offset by roughly a kilometre. "
     "Drawing them as sharp pins would claim a precision the data does not have. Reloading "
     "does not move them, so repeated loads cannot be averaged to recover the true point.")

case("T3.4", "Some listings are absent entirely",
     ["Note the count from T3.2.",
      "Compare with T4.1 later."],
     ["17.",
      "Marcus, signed in, will see 18."],
     "Draft and pending listings are not merely hidden from the page &mdash; they are never "
     "sent. The database refuses the rows; the browser is never in a position to leak them.")

# ================================================================== 4
A(PageBreak())
A(para("4.  Signing In", H1))

case("T4.1", "Marcus signs in &mdash; the gate stays shut",
     ["Click <b>Sign in</b>.",
      "Enter " + mono("marcus@example.com") + " and " + mono("demo1234") + ".",
      "Look at the count and at the cards."],
     ["A sign-in form.",
      "You land back on the marketplace. Top-right shows <b>Marcus Pell</b>.",
      "<b>18 properties</b> &mdash; one more than anonymous. Addresses still withheld; pins still rings."],
     "Signing in is not the same as being entitled. Marcus now sees a pending listing an "
     "anonymous visitor cannot, and still cannot see a single address. Identity and "
     "entitlement are separate questions, answered separately.")

case("T4.2", "A wrong password says nothing useful",
     ["Sign out. Sign in with " + mono("marcus@example.com") + " and " + mono("wrong") + ".",
      "Now try " + mono("nobody@example.com") + " and " + mono("wrong") + ".",
      "Compare the two messages, and roughly how long each took."],
     ["A single generic failure message.",
      "The same message.",
      "Identical wording, and no obvious difference in speed."],
     "A faster answer for an address that does not exist is an enumeration oracle: it lets "
     "somebody discover who has an account. The failure path deliberately does the same "
     "hashing work as the success path.")

case("T4.3", "Five wrong passwords lock the account",
     ["Enter the wrong password for " + mono("ines@example.com") + " five times.",
      "Now enter the correct password, " + mono("demo1234") + "."],
     ["Five failures.",
      "Still refused, and the message mentions the account being locked."],
     "Guessing is bounded. Staff can clear it by setting a new password.",
     warn=False)
A(para("This test leaves Ines locked. Nothing later needs her; a reset (1.3) clears it.", CAP))

case("T4.4", "Ruth signs in &mdash; the gate opens",
     ["Sign out. Sign in as " + mono("ruth@example.com") + " / " + mono("demo1234") + ".",
      "Look at the banner.",
      "Look at the cards and the map."],
     ["Top-right shows <b>Ruth Okonkwo</b>. Still <b>18 properties</b>.",
      "It now says addresses and exact locations are shown, because the fee agreement is on file.",
      "Full street addresses. Sharp pins, no rings."],
     "<b>This is the whole product.</b> Ruth and Marcus hold the same role and match the "
     "same 18 rows. One settled agreement is the entire difference, and no application code "
     "is involved in producing it.", warn=True)

case("T4.5", "Side by side",
     ["Open a second window in private mode. Sign in as Marcus there, leaving Ruth signed "
      "in in the first.",
      "Put them next to each other and compare the same listing."],
     ["Two sessions, two identities.",
      "Same price, same beds, same cap rate, same NOI. One shows a street address and a "
      "sharp pin; the other shows a padlock and a ring."],
     "Everything an investor underwrites on is public. Only the thing that identifies the "
     "parcel is held back. Nothing on the page is a teaser.")

case("T4.6", "An agent sees only their own book",
     ["Sign in as " + mono("tom@example.com") + ".",
      "Note the count.",
      "Sign in as " + mono("priya@example.com") + " and compare."],
     ["<b>Tom Bradbury</b>.",
      "Around 12 &mdash; far fewer, including a draft nobody else can see.",
      "A different, smaller set."],
     "Agents are isolated from each other by row policy, not by a filter in the page. "
     "Tom cannot reach one of Priya's listings even by guessing its identifier &mdash; "
     "see T11.3.")

case("T4.7", "Staff see everything",
     ["Sign in as " + mono("jpool2@yahoo.com") + ".",
      "Note the count."],
     ["<b>Jessica Pool</b>.",
      "<b>25 properties</b> &mdash; every status, including drafts."],
     "Staff see all three bands: the public figures, the addresses, and the internal "
     "acquisition cost and margin that never leave the organisation.")

case("T4.8", "Signing out ends the session",
     ["As Jessica, click <b>Sign out</b>.",
      "Press the browser Back button."],
     ["Back to <b>Not signed in</b>.",
      "The page may redraw from cache, but the listings return to the anonymous 17 and "
      "addresses are gone."],
     "The session is revoked at the server, not merely forgotten by the browser. A copied "
     "cookie is dead the moment sign-out happens.")

# ================================================================== 5
A(PageBreak())
A(para("5.  Filtering", H1))
A(para("Sign in as Marcus for this section.", BODY))

case("T5.1", "Each filter narrows",
     ["Set <b>Beds</b> to 3+.",
      "Add a maximum price of 250,000.",
      "Add a minimum of 1,500 sq ft.",
      "Press <b>Reset</b>."],
     ["The count drops; every card shows 3 or more bedrooms.",
      "Drops again; no card is above $250,000.",
      "Drops again; nothing under 1,500 sq ft.",
      "Back to 18."],
     "Filters are applied by the database inside what you were already allowed to see. "
     "There is no filter value that widens the result &mdash; the policy runs first, always.")

case("T5.2", "Sorting",
     ["Set <b>Sort</b> to <i>Price: low to high</i>.",
      "Set it to <i>Cap rate</i>."],
     ["Cards reorder, cheapest first.",
      "Reorders by cap rate, highest first."],
     "Sort options come from a fixed list. A value that is not on the list is ignored "
     "rather than passed through to the database.")

case("T5.3", "The dropdowns only offer what you can see",
     ["Open the <b>City</b> dropdown as Marcus and note the cities.",
      "Sign in as Tom and open it again."],
     ["Nine or so cities.",
      "Noticeably fewer."],
     "Even the filter bar is bounded by policy. If it offered every city, its contents "
     "would leak the existence of listings the viewer cannot open.")

case("T5.4", "Filters survive a reload",
     ["Apply two filters. Copy the URL.",
      "Paste it into a new tab in the same session."],
     ["The URL carries the filter values.",
      "The same filtered result."],
     "A search can be shared or bookmarked. It is still evaluated against whoever opens "
     "it &mdash; sending Ruth's URL to Marcus gives Marcus <i>his</i> results, not hers. "
     "Worth actually trying.")

# ================================================================== 6
A(para("6.  The Map", H1))

case("T6.1", "Map and list are linked",
     ["Hover a card.",
      "Hover a map bubble.",
      "Click a bubble."],
     ["Its bubble highlights.",
      "Its card highlights.",
      "The detail panel opens for that property."],
     "The two halves are one view of one result set, not two independent queries.")

case("T6.2", "Clusters stay clickable",
     ["Find a city with several listings, e.g. Cleveland.",
      "Click each bubble in the cluster."],
     ["The bubbles are spread apart rather than stacked.",
      "Each opens a different property."],
     "Listings in one city sit within a pixel of each other at this scale. They are nudged "
     "apart so each is reachable &mdash; honest here because for most viewers these "
     "positions are approximate anyway.")

case("T6.3", "The map works without the internet",
     ["Note whether the map shows roads and place names.",
      "If instead you see a plain grid with priced bubbles, read the caption."],
     ["A real basemap, if the host can reach the tile CDN.",
      "<i>No basemap available &mdash; listings plotted to scale.</i> Bubbles still "
      "priced, clickable and hover-linked."],
     "The map library is progressive enhancement. On a restricted network the geography is "
     "still legible, and the page says so rather than showing a grey rectangle.")

# ================================================================== 7
A(PageBreak())
A(para("7.  Property Detail", H1))

case("T7.1", "Opening a listing",
     ["As Marcus, click any card.",
      "Read the top of the panel.",
      "Press Escape."],
     ["A panel slides in from the right with photographs at the top.",
      "Price, beds, baths, square feet, year built, and a padlocked city-and-state line.",
      "It closes."],
     None)

case("T7.2", "The expense breakdown adds up",
     ["Find the <b>Income and operating expenses</b> table.",
      "Add up property tax, insurance, maintenance, and utilities if the row says "
      "<i>paid by owner</i>.",
      "Compare with the operating expenses figure on the card, or ask staff for "
      + mono("opex_annual") + "."],
     ["Gross rent, vacancy, management, tax, insurance, maintenance, utilities, HOA, and a "
      "net figure.",
      "A number.",
      "<b>They match exactly.</b>"],
     "The breakdown is generated from the published figure rather than typed alongside it. "
     "A detail page whose arithmetic does not close is a page nobody underwrites on twice.",
     warn=True)

case("T7.3", "Area context",
     ["Read the section named for the city.",
      "Find <i>This rent as a share of local income</i>."],
     ["Median household income, median home price, median rent, rent growth, vacancy, "
      "price-to-income.",
      "A percentage."],
     "Regional figures live once per city rather than being copied onto every listing, so "
     "there is one place to update when a figure moves. Note the caveat: these are "
     "plausible demonstration figures, not an ACS extract, and nothing should be "
     "underwritten on them.")

case("T7.4", "The gate, in the detail panel",
     ["As Marcus, read the coloured note in the middle of the panel.",
      "Open the same listing as Ruth.",
      "Compare the financial sections."],
     ["It says the address, exact pin and exterior photograph are released on signing, and "
      "that the financial detail below is complete.",
      "The note is green and says the agreement is on file. The address is shown.",
      "<b>Identical.</b>"],
     "The gate withholds identity, not analysis. Confirming that the numbers are the same "
     "for both is the point of this test.")

# ================================================================== 8
A(para("8.  Photographs", H1))

case("T8.1", "Marcus sees four, Ruth sees five",
     ["As Marcus, open any listing and count the photographs.",
      "As Ruth, open the same listing and count again.",
      "Look at what the extra one is."],
     ["<b>Four</b> &mdash; the card photograph, living area, kitchen, bedroom.",
      "<b>Five.</b>",
      "A front elevation."],
     "A photograph of the front of a house identifies it as surely as its street number. "
     "So exterior shots are gated on the same rule as the address, and interiors are not. "
     "Without this the gate would be reopened through the picture gallery.",
     warn=True)

case("T8.2", "Every caption says the photograph is representative",
     ["Read the caption under any interior.",
      "Read the caption on the card photograph."],
     ["<i>&mdash; representative photo, not the actual property</i>.",
      "The same qualification."],
     "These are supplied stock photographs, not pictures of these houses. A stock exterior "
     "shown without qualification reads as a picture of the property, and an investor who "
     "walks the house and finds a different kitchen stops trusting the numbers too.")

case("T8.3", "Full screen",
     ["Open a listing and click the <b>&#10530;</b> button beside the close button.",
      "Look at the layout.",
      "Close the listing, open another one.",
      "Click the button again."],
     ["The panel fills the window.",
      "Photographs on the left, figures on the right &mdash; not one very wide column of text.",
      "<b>Still full screen.</b>",
      "Back to the side panel, and it stays that way."],
     "The choice is remembered. Somebody who wants the big view wants it for every listing, "
     "not once. It is stored per browser, so a private window simply starts in the side "
     "panel.")

case("T8.4", "See all photographs",
     ["Click <b>See all N photos</b> on the lead image.",
      "Count the tiles.",
      "Click any tile.",
      "Press the right arrow key, then the left twice.",
      "Press Escape once.",
      "Press Escape again."],
     ["A full-window page of every photograph, each captioned.",
      "The same N as the button said.",
      "It opens large, with a counter reading <i>n of N</i>.",
      "It moves forward, then back past the first to the last &mdash; it wraps.",
      "The large view closes and the grid is still there.",
      "The grid closes and the listing is still open."],
     "Escape unwinds one layer at a time. Closing everything at once loses both the "
     "photograph being looked at and the listing it was opened from.")

case("T8.5", "Headings appear only when they group something",
     ["With a listing that has one photograph per room, look for headings.",
      "Ask staff to add a second kitchen photograph, then look again."],
     ["<b>None</b> &mdash; a plain grid, four across.",
      "Headings appear: FEATURED, LIVING AREA, KITCHEN, PRIMARY BEDROOM."],
     "A heading above a single photograph is a full-width divider that forces one tile per "
     "row and says nothing the caption underneath does not. The headings come back the "
     "moment they group more than one image. They are built from the caption, which is the "
     "same field staff will edit, so a photograph labelled in the properties panel appears "
     "under that heading here with nothing else changing.")

case("T8.6", "A gated photograph is marked as such",
     ["As Ruth, open the photograph page and find the front elevation."],
     ["A <i>shows the street</i> badge beside its caption."],
     "Ruth can see it because her fee agreement is on file. The badge says why it is a "
     "photograph not everybody gets, which is worth stating on the screen where somebody "
     "might otherwise copy the link to a person for whom it will 404.")

# ================================================================== 9
A(PageBreak())
A(para("9.  Favourites and Saved Searches", H1))
A(para("Sign in as Marcus.", BODY))

case("T9.1", "Marking a favourite",
     ["Click the heart on a card.",
      "Look at the top-right counter.",
      "Open the same listing and check the button in the panel.",
      "Reload the page."],
     ["It fills in.",
      "It increments.",
      "It reads <i>Saved to favourites</i>.",
      "Still filled."],
     "Stored against the person, not the browser.")

case("T9.2", "The favourites list",
     ["Click <b>Favourites</b>.",
      "Check the address line on the cards.",
      "Click it again."],
     ["Only your favourites; the filter bar dims.",
      "Still padlocked, exactly as in the grid.",
      "Back to the full result."],
     "The favourites list is built from the same masked view as the grid. An address hidden "
     "in search must not reappear because the listing was favourited &mdash; the mask is "
     "inherited rather than reimplemented, so the two cannot drift apart.")

case("T9.3", "Favourites are private",
     ["Note which listings Marcus has favourited.",
      "In the other window, as Ruth, open her Favourites."],
     ["A list.",
      "Hers, not his."],
     "One investor cannot see another's saved list &mdash; see T11.2 for the version of "
     "this test that tries to force it.")

case("T9.4", "Saving a search",
     ["Set beds to 3+ and a maximum price of 300,000.",
      "Click <b>Save search</b> and name it " + mono("Cheap 3-beds") + ".",
      "Press <b>Reset</b>.",
      "Choose the saved search from the dropdown.",
      "Open the dropdown again."],
     ["The result narrows.",
      "It appears in the <i>Saved searches</i> dropdown.",
      "Back to everything.",
      "The filters repopulate and the same result returns.",
      "It now shows a run count."],
     "The criteria are stored, not the results, so a saved search re-run next month reflects "
     "the market next month. The storable fields are constrained by the database: a saved "
     "search is replayed later, possibly by different code, and what cannot be stored "
     "cannot be replayed.")

case("T9.5", "Saved searches are private too",
     ["As Ruth, open the Saved searches dropdown."],
     ["Marcus's saved search is not there."],
     "What an investor is hunting for is their own business. Unlike favourites, staff have "
     "no override here either.")

# ================================================================== 10
A(para("10.  Plain-English Search", H1))

case("T10.1", "It says what it understood",
     ["Type " + mono("3 bed duplex in Cleveland under 250k best yield") + " into the top box "
      "and press Search.",
      "Look at the filter bar.",
      "Look at the results."],
     ["A bar appears: <i>Reading that as duplexes, 3+ bed, in Cleveland, under $250,000, "
      "best cap rate first</i>.",
      "The controls have been set to match.",
      "Filtered and sorted accordingly."],
     "The box is never opaque about what it did, and its output is the same criteria the "
     "controls produce &mdash; not a separate path into the database.")

case("T10.2", "More phrasings",
     ["Try " + mono("cheapest condos over 1500 sqft") + ".",
      "Try " + mono("single family in Tampa between 200k and 400k") + ".",
      "Try " + mono("exactly 3 bedrooms in Memphis") + "."],
     ["Condo, 1,500+ sq ft, cheapest first. <b>Not</b> a $1.5m price floor.",
      "A price range, a type and a city.",
      "Beds pinned at exactly 3, not 3 or more."],
     "The second bullet is a real trap: <i>over 1500 sqft</i> and <i>over 1500</i> match the "
     "same shape, and only the unit tells them apart.")

case("T10.3", "Nonsense is refused, not guessed",
     ["Type " + mono("something something nonsense") + " and search."],
     ["It says nothing was recognised and suggests an example. The filters do not change."],
     "It does not invent a filter to look useful.")
A(para("This is a rules parser, not a language model, and it does not call one. It is here "
       "because the shape of the feature &mdash; free text in, a bounded set of criteria out "
       "&mdash; is the part that must be right before a model goes behind it.", NOTE))

# ================================================================== 11
A(PageBreak())
A(para("11.  Tests That Must Be Refused", H1))
A(para("<b>Every test in this section is expected to fail.</b> A refusal is the pass. If any "
       "of them succeeds, stop and report it before running anything else.", NOTE))

case("11.1" if False else "T11.1", "Reading the base table directly",
     ["Sign in as Marcus.",
      "Open " + mono("http://&lt;host&gt;:3000/api/probe") + " in the address bar."],
     ["&mdash;",
      "A refusal: <i>permission denied for schema core</i>."],
     "The application is not what withholds the address. This request goes around the "
     "marketplace entirely and asks the database directly, and the database refuses. "
     "Somebody who found an unguarded query, an API bug, or a direct connection would hit "
     "the same wall.", warn=True)

case("T11.2", "Reaching another investor's favourites",
     ["Ask staff to run:",
      Preformatted("SET ROLE sdi_investor;\n"
                   "BEGIN;\n"
                   "SELECT set_config('app.actor_id',\n"
                   "  '22222222-2222-2222-2222-222222222222', true);\n"
                   "SELECT * FROM core.saved_property;\n"
                   "COMMIT;", CODE)],
     ["Only Marcus's own rows &mdash; never Ruth's, even though the query names no person "
      "and has no WHERE clause."],
     "The restriction is in the table, not in the query. There is no query that returns "
     "somebody else's saved list.", warn=True)

case("T11.3", "Guessing another agent's listing",
     ["As Tom, open a listing and copy its id from the URL or the detail request.",
      "Sign in as Priya and request the same id:",
      Preformatted("http://<host>:3000/api/property?id=<that id>", CODE)],
     ["An id.",
      "&mdash;",
      "<b>404 Not found</b> &mdash; not <i>403 Forbidden</i>."],
     "Two things. The refusal comes from the row policy rather than a check in the page. "
     "And it says <i>not found</i> deliberately: answering <i>forbidden</i> would confirm "
     "the listing exists to anyone who guessed an id.", warn=True)

case("T11.4", "Reaching a draft listing",
     ["As Jessica, find the Irvine listing (108 Fairgrove) and copy its id.",
      "Sign out and request the same id as an anonymous visitor."],
     ["Jessica can see it; it is a draft.",
      "<b>404.</b>"],
     "Draft listings are invisible to everyone but staff, by policy.", warn=True)

case("T11.5", "The persona switcher is off",
     ["While signed out, open "
      + mono("http://&lt;host&gt;:3000/?persona=jessica") + "."],
     ["Still <b>Not signed in</b>, and still 17 listings. Not administrator."],
     "The demo persona switcher is genuinely useful for showing Marcus and Ruth side by "
     "side, but a dropdown that hands out an admin session must not be reachable by "
     "accident. It requires " + mono("DEMO_PERSONAS=1") + " and is off by default.",
     warn=True)

case("T11.6", "Internal figures stay internal",
     ["As Jessica, open " + mono("/api/view") + " and find acquisition cost and margin.",
      "As Marcus, open the same URL and look for them."],
     ["Present.",
      "Absent, with a permission error recorded against that part of the payload."],
     "Acquisition cost and margin are refused by a column grant &mdash; a hard access "
     "control list, not a masking rule. Marcus cannot read that column under any query.",
     warn=True)

# ================================================================== 12
A(PageBreak())

# ================================================================== 12
A(PageBreak())
A(para("12.  The Intake Review Screen", H1))
A(para("Staff only. Open " + mono("/admin.html") + " signed in as "
       + mono("jpool2@yahoo.com") + " or " + mono("dan@example.com") + ".", BODY))
A(para("Tests 12.4 onward need a batch loaded. If the queue is empty, ask whoever runs the "
       "host for:", BODY))
A(Preformatted("python3 tools/workbook-to-json.py *.xlsm > batch.json\n"
               "node worker/tools/load-intake.js batch.json --note \"test run\"", CODE))

case("T12.1", "It is refused when signed out",
     ["Sign out. Open " + mono("/admin.html") + "."],
     ["A <b>Staff only</b> panel. No batches, no rows."],
     "The page settles this by asking the server for the queue rather than reading a role "
     "name out of the session, so a tampered cookie changes nothing.")

case("T12.2", "It is refused for an investor",
     ["Sign in as " + mono("ruth@example.com") + ", who has the fee agreement on file.",
      "Open " + mono("/admin.html") + "."],
     ["The marketplace, with addresses.",
      "<b>Staff only.</b> Still refused."],
     "Being entitled to see addresses is not being entitled to decide what gets published. "
     "The functions behind this screen are granted to staff alone.", warn=True)

case("T12.3", "Staff get the queue",
     ["Sign in as " + mono("jpool2@yahoo.com") + " and open " + mono("/admin.html") + "."],
     ["Batches down the left, rows on the right."],
     None)

case("T12.4", "What the file said",
     ["Click <b>what the file said</b> on any row.",
      "Compare a figure in it with the row above it."],
     ["The verbatim spreadsheet payload.",
      "They agree."],
     "The payload is stored unedited beside our reading of it. When a released listing later "
     "says something surprising, this is what answers whether the file said it or whether we "
     "mistranslated it \u2014 and that question has no answer if the import overwrote its own "
     "input.")

case("T12.5", "Release is refused before approval",
     ["Tick <b>Select all releasable</b> without approving anything.",
      "Look at the Release button."],
     ["Rows are selected.",
      "<b>Disabled.</b>"],
     "Review is not advisory. Nothing reaches the marketplace without a person agreeing to "
     "it.", warn=True)

case("T12.6", "Approve, then release",
     ["With rows selected, click <b>Approve selected</b>.",
      "Tick <b>Select all releasable</b> again.",
      "Click Release and confirm.",
      "Open the marketplace and search for one of the addresses."],
     ["The rows turn <i>approved</i>, and the count of changed rows is reported.",
      "The button now reads <b>Release N approved</b>.",
      "The rows turn <i>released</i> and are given listing references.",
      "It is there, priced as the workbook said."],
     None)

case("T12.7", "The governance warning appears at the moment of release",
     ["Read the banners immediately after releasing."],
     ["One says how many were released. Another, in amber, says <b>published with no "
      "confirmed data right</b> and names the reason."],
     "The workbook right is recorded unreviewed because the property description is verbatim "
     "MLS copy whose republication right is unestablished. The reviewer is told at the moment "
     "it matters rather than finding it in a report weeks later.", warn=True)

case("T12.8", "An invalid row cannot be approved",
     ["Load a batch containing a row with no price, or ask staff to run "
      + mono("sql/29_intake_tests.sql") + ".",
      "Select it and click Approve."],
     ["It shows as <i>invalid</i> with a red problem line naming the field.",
      "The screen reports fewer rows changed than were selected, and says rows with a "
      "blocking error cannot be approved."],
     "Approving past a blocking error is how validation stops meaning anything.", warn=True)

case("T12.9", "Select all means all the releasable ones",
     ["In a batch mixing valid and invalid rows, tick <b>Select all releasable</b>.",
      "Approve, then release."],
     ["Only the rows that can move are ticked.",
      "The blocked rows are exactly where they were."],
     "\u201cRelease everything\u201d is a narrower promise than it sounds, deliberately.")

A(para("13.  Notes and Flags", H1))
A(para("Sign in as Jessica (admin) and open <b>Properties</b> in the left rail. The seeded "
       "demo has SDI-1010 flying red, SDI-1016 amber, and SDI-1019 carrying a critical note "
       "that was raised and resolved.", BODY))

case("T13.1", "The flag says what is outstanding, not what has ever been wrong",
     ["Look at the picker list without opening anything.",
      "Open SDI-1010 and read the chip under the address.",
      "Open SDI-1019 and read its chip, then read its notes."],
     ["<b>Two</b> pennants: red on SDI-1010, amber on SDI-1016. No green dots anywhere.",
      "<b>Critical &middot; 1 critical, 1 to chase.</b> The worst open note decides the "
      "colour; the count says there is more than one thing open.",
      "<b>Clear</b> &mdash; even though it carries a critical note. The note was resolved, "
      "and the resolution line names who said so and what settled it."],
     "A flag computed from every note ever written is a ratchet: nothing could ever come "
     "back down and the colour would stop carrying information. Green here means somebody "
     "closed something out, not that nobody has written anything alarming lately.")

case("T13.2", "Raising and dropping a flag",
     ["On any clear property, write a note, choose <b>Critical</b>, and add it.",
      "Watch the chip under the address and the row in the picker.",
      "Click <b>Resolve</b> on the note and type what settled it.",
      "Look at the note and the chip again."],
     ["The chip turns red immediately and the picker row grows a red pennant &mdash; without "
      "a page reload.",
      "Both change together; they are computed from the same rows.",
      "The tag reads <b>Critical &middot; resolved</b> and a green line underneath names you "
      "and the time.",
      "The chip is back to <b>Clear</b>, and <b>Reopen</b> is offered in place of Resolve."],
     "Resolution is what stops severity being a one-way ratchet, and it is recorded rather "
     "than implied &mdash; who closed it and why is the part somebody needs three months on.")

case("T13.3", "The level resets after each note",
     ["Add a note marked Critical.",
      "Look at the <b>How urgent</b> row without touching it.",
      "Type a second, ordinary note and add it."],
     ["Added, flagged red.",
      "It has snapped back to <b>Note</b>.",
      "It is added unflagged; the flag count does not go up."],
     "A composer left on Critical turns the next three ordinary notes into emergencies by "
     "inattention, and the red flag stops meaning anything within a week.")

case("T13.4", "A buyer cannot infer an internal note from a flag",
     ["Note that SDI-1010 carries an open <b>internal</b> critical note.",
      "Sign out entirely and find SDI-1010 in the listings.",
      "Sign in as Marcus (investor, unsigned) and look again.",
      "Sign back in as Jessica and look at the same card."],
     ["Confirmed &mdash; the roof-leak note is marked Internal.",
      "<b>No flag of any kind</b> on the card.",
      "Still none.",
      "<b>1 critical &middot; 1 to chase</b> appears on the card."],
     "The flag is derived from the notes the caller can see, so this falls out of the row "
     "policy rather than being decided again in the browser. A visible-but-green flag would "
     "have been worse than none: it reads as this system vouching for the house.",
     warn=True)

case("T13.5", "A public note is as public as the price",
     ["In the composer, choose <b>Public</b> and read the warning that appears.",
      "Add a public note.",
      "Sign out and open that listing as an anonymous visitor."],
     ["It says a public note is as visible as the listing itself, to visitors who have "
      "signed nothing.",
      "Added, tagged <b>PUBLIC</b> in blue.",
      "The note is there, on a gated listing, above the locked address."],
     "The gate protects the address <i>column</i>. It cannot protect prose that mentions "
     "the address, and the composer says so at the moment the choice is made rather than in "
     "a policy document nobody opens.",
     warn=True)

A(para("14.  Sharing a Listing", H1))
A(para("Open any listing and use the <b>share</b> control at the top of the panel.", BODY))

case("T14.1", "Masked is the default, for everybody",
     ["As Jessica (admin), open the share dialog and look at what is preselected.",
      "Type a recipient and create the PDF.",
      "Open it and look at the photograph and the address."],
     ["<b>Masked</b>. Not \u201cunmasked because you are staff\u201d.",
      "It downloads; the listing stays on screen behind it.",
      "A branded stand-in image, and the city and state without the street address. "
      "The cash flow figures are all present."],
     "The common case is sending a property to somebody who has signed nothing. A default "
     "that leaks on the common case is not a default, it is a trap.")

case("T14.2", "The gate is in the database, not the checkbox",
     ["As Jessica, tick <b>unmask</b> and create the PDF.",
      "Sign out. Request the same url with <code>?unmask=1</code> appended.",
      "Open what comes back."],
     ["The address and the real photograph are in the document.",
      "It is refused, or a masked document is returned.",
      "<b>Masked.</b> Asking is not permission."],
     "The browser hides the control from anyone who may not use it, but hiding it protects "
     "nothing. The refusal is the boundary.",
     warn=True)

case("T14.3", "Every document is logged",
     ["Create two documents for the same property, one masked and one not.",
      "Read the <b>Shared with</b> section on that property.",
      "Try to create one without naming a recipient."],
     ["Both succeed.",
      "Two rows: who made each, who they said it was for, when, and which carried the "
      "address. The released one is tinted.",
      "Refused, with a message. The button says so rather than sitting inert."],
     "A PDF leaves this system permanently. The moment of generation is the only moment it "
     "can be recorded, and \u201cwho has this\u201d is the question the log exists to answer.")

case("T14.4", "The numbers are never the thing withheld",
     ["Compare the masked and unmasked documents side by side.",
      "Look at price, rent, expenses, NOI and cap rate in each."],
     ["They differ in the address, the photograph and the map only.",
      "<b>Identical.</b>"],
     "An investor decides on the cash flow and only then signs for the identity of the "
     "house. A masked document that also hid the yield would be a brochure for nothing.")

# ================================================================== 15
A(para("15.  Showing a Property to a Customer", H1))
A(para("As Jessica, open any property and use the <b>Shown to</b> section. The demo carries "
       "customers on both sides of the fee agreement: Alan and Carl have signed, Bev and "
       "Dana have not.", BODY))

case("T15.1", "An assignment does not release the address",
     ["Show the property to <b>Bev</b>, who has not signed.",
      "Read the tag on her row.",
      "Sign in as Bev and open her list.",
      "Now do the same for <b>Alan</b>, who has signed."],
     ["A deal opens at <b>Inquiry</b>.",
      "<b>Address withheld.</b>",
      "She sees the property, the city, and every financial figure \u2014 and the street "
      "address is blank.",
      "<b>Address released</b>, and Alan sees the street address."],
     "Being shown a property is not being told where it is. This is the test that would have "
     "caught the gate opening on every customer assignment.",
     warn=True)

case("T15.2", "Withdrawing keeps the record",
     ["Move Bev\u2019s deal to <b>Under Contract</b>, then withdraw it.",
      "Look at the staff list.",
      "Sign in as Bev and look at hers."],
     ["It moves through the stages.",
      "The row is still there, marked closed and lost.",
      "<b>Gone.</b> The property was taken back; continuing to list it would be confusing "
      "and clicking it would be worse."],
     "The stage history is the record of what was shown to whom, so deleting the deal would "
     "delete that. Staff and the customer want different answers, which is why they are two "
     "views.")

case("T15.3", "Assigning twice is a double click",
     ["Show the same property to Alan twice."],
     ["One open deal, not two."],
     "A second row would look like a second interest in the same house.")

# ================================================================== 16
A(para("16.  Searches That Are Refused", H1))
A(para("Type these into the plain-English box on the marketplace. Signed in or not \u2014 the "
       "answer is the same.", BODY))

case("T16.1", "A request that would steer is refused, with a reason",
     ["Search <b>houses in a good school district</b>.",
      "Read the message.",
      "Try <b>nice family friendly neighborhood</b>, <b>somewhere safe with low crime</b>, "
      "and <b>up and coming area</b>."],
     ["No results are returned and nothing is filtered.",
      "It names what it matched and which protected basis it protects, and suggests what to "
      "search on instead.",
      "All refused, each naming a different basis."],
     "The steering is in the request. \u201cA good school district\u201d parses to a city and a "
     "bedroom count \u2014 entirely legal keys \u2014 so the only place to catch it is before "
     "anything has been turned into a filter.",
     warn=True)

case("T16.2", "Ordinary searches are not refused",
     ["Search <b>3 bed duplex in Cleveland under 200k best yield</b>.",
      "Search <b>a safety deposit box</b>.",
      "Search <b>section 8 tenant in place</b>."],
     ["Understood and applied; the box says what it read.",
      "Not refused \u2014 \u201csafe\u201d inside another word is not a request about crime.",
      "Not refused. A tenanted voucher property has a government-backed rent stream, which "
      "is a real underwriting fact."],
     "A screening layer that over-refuses gets switched off. Both directions have to hold.")

case("T16.3", "The exclusionary direction is still refused",
     ["Search <b>no section 8</b>.",
      "Then <b>no vouchers</b>."],
     ["Refused, naming source of income.",
      "Refused."],
     "In a growing number of states source-of-income discrimination is unlawful on its own "
     "account, quite apart from the federal position.",
     warn=True)

A(para("17.  Checks From the Command Line", H1))
A(para("These need shell access to the host. They take about fifteen minutes and cover the "
       "parts a browser cannot show.", BODY))

A(para("17.1  The standing invariants", H2))
A(Preformatted("docker compose exec db psql -U postgres -d sdi \\\n"
               "  -c \"SELECT * FROM api.security_invariants()\"", CODE))
A(para("<b>Zero rows is the pass.</b> This is the single most valuable check in the "
       "document. It catches the handful of changes that quietly dismantle the model: "
       "granting access to the internal schema, exposing an internal column, switching row "
       "security off, creating a view that runs with the wrong privileges, or exposing a "
       "dimension the fair-housing register forbids. Run it after every deployment, and "
       "wire it into whatever runs nightly.", GOOD))

A(para("17.2  The fair-housing assertion", H2))
A(Preformatted("docker compose logs web | grep fair-housing", CODE))
A(table([
    hdr(["What you see", "Means"]),
    ["<font face='Courier'>fair-housing register: 17 dimensions, none exposed as filters</font>",
     "Pass. The check ran and the filter list is clean"],
    ["Nothing at all",
     "The container did not get that far. Check whether it is running"],
    ["A <font face='Courier'>WARNING</font> about not reading the register",
     "The check did not run. On an older build this could happen transiently at startup; "
     "it should now retry and refuse to start rather than serve unchecked"],
], [2.7*inch, 3.2*inch]))
A(Spacer(1, 4))
A(para("A protected characteristic, or a proxy for one, offered as a filter or a sort is "
       "steering, and the law does not require that anyone intended it. The web tier checks "
       "its own filter list against the register in the database and refuses to start on a "
       "collision, because serving unchecked filters is worse than being down.", BODY))

A(para("17.3  Where the data-rights register stands", H2))
A(Preformatted("docker compose exec db psql -U postgres -d sdi \\\n"
               "  -c \"SELECT * FROM api.governance_status\" \\\n"
               "  -c \"SELECT * FROM gov.uncovered_publication\"", CODE))
A(table([
    hdr(["Column", "Expected today", "Means"]),
    [mono("enforcement_mode"), mono("advisory"),
     "Publication is not blocked; gaps are reported. Flipping to " + mono("blocking") + " is the go-live gate"],
    [mono("rights_recorded"), "3", "Synthetic demo data, the empty instrument for the tracked Irvine address, and the operator-supplied photograph"],
    [mono("rights_confirmed"), "1", "Only the synthetic data, which needs no external agreement"],
    [mono("uncovered_published"), "0", "Nothing is on public display without a right covering it"],
    [mono("published_total"), "24", "25 properties, of which the Irvine draft is unpublished"],
    [mono("regulations_without_control"), "8", "Regimes with no enforcement here. Honest, not an error &mdash; see the compliance register"],
], [1.55*inch, 0.85*inch, 3.5*inch]))
A(Spacer(1, 4))
A(para(mono("gov.uncovered_publication") + " should return no rows. Any row names a "
       "published listing and the reason no right covers it &mdash; missing, expired, "
       "unreviewed, or out of territory.", BODY))

A(para("17.4  The listing-status walkthrough", H2))
A(Preformatted("docker compose exec -T db psql -U postgres -d sdi \\\n"
               "  < sql/23_listing_sync_tests.sql", CODE))
A(para("Ten steps, printing what happens at each: a listing goes under contract, escrow "
       "fails and it returns to market, the feed goes down, the listing is genuinely "
       "delisted, an advisory source disagrees, and a status term nobody has mapped arrives. "
       "Two results are worth watching for specifically.", BODY))
A(table([
    hdr(["Step", "What to look for", "Why it matters"]),
    ["3", "<i>pending &rarr; active</i> on the <b>first</b> sighting",
     "Escrow fails perhaps one deal in five. A saleable house shown as unavailable costs "
     "enquiries every night it waits, so this direction is acted on immediately"],
    ["4", "Three errors in a row change <b>nothing</b>",
     "A feed being down must never look like a market that emptied. An adapter in doubt "
     "reports an error, never an absence"],
], [0.5*inch, 2.3*inch, 3.1*inch]))
A(Spacer(1, 4))
A(para("Step 7 prints an " + mono("ERROR") + " and that is the pass &mdash; it is "
       "demonstrating that blocking mode refuses an uncovered publication. The file "
       "restores everything it changes.", NOTE))

A(para("17.5  The governance walkthrough", H2))
A(Preformatted("docker compose exec -T db psql -U postgres -d sdi \\\n"
               "  < sql/27_governance_tests.sql", CODE))
A(para("Builds a data right one failing condition at a time &mdash; unreviewed, no "
       "territory, use not granted &mdash; and shows it granting nothing until all four "
       "conditions hold. Then shows the same confirmed right refusing to cover a property "
       "one state away. That is the licensing breach the schema exists to prevent, and the "
       "one where the software would otherwise work perfectly.", BODY))

# ================================================================== 13
A(PageBreak())
A(para("18.  Known Gaps", H1))
A(para("Do not raise these as defects. They are recorded, and the reasons are in section 12 "
       "of the System Documentation.", BODY))
A(table([
    hdr(["You will notice", "Why"]),
    ["108 Fairgrove has no photograph", "The image file is not committed to the repository, and that directory is built into the web image. Only staff can see the listing anyway &mdash; it is a draft"],
    ["The Irvine listing has no price or room counts", "Deliberate. The facts held are the ones in the source listing URL; the rest is licensed content that has not been obtained. Inventing plausible numbers would produce exactly the confident wrong record the schema exists to prevent"],
    ["No listing status ever changes on its own", "No MLS feed is connected, and the worker is not deployed in the current compose file"],
    ["No password reset", "Authentication works; recovery is not built. Staff set a new password"],
    ["The map has no non-visual equivalent", "An accessibility gap, recorded and unaddressed"],
    ["Gated photographs are ordinary files", "The database controls who is told an image's address, not who can fetch it. Adequate for generated illustrations, not for real location-revealing photography"],
    ["A workbook cannot be uploaded through the browser", "The review screen reviews and releases; loading is two commands at a shell"],
    ["A staged row cannot be edited before release", "Deliberate. An edited row would no longer match the payload it is stored beside. Correct the workbook and reload"],
], [1.85*inch, 4.05*inch]))

# ================================================================== 14
A(para("19.  Recording Results", H1))
A(table([
    hdr(["Section", "Tests", "Pass", "Fail", "Blocked", "Notes"]),
    ["3. Anonymous visitor", "T3.1&ndash;T3.4", "", "", "", ""],
    ["4. Signing in", "T4.1&ndash;T4.8", "", "", "", ""],
    ["5. Filtering", "T5.1&ndash;T5.4", "", "", "", ""],
    ["6. The map", "T6.1&ndash;T6.3", "", "", "", ""],
    ["7. Property detail", "T7.1&ndash;T7.4", "", "", "", ""],
    ["8. Photographs", "T8.1&ndash;T8.2", "", "", "", ""],
    ["9. Favourites and saved searches", "T9.1&ndash;T9.5", "", "", "", ""],
    ["10. Plain-English search", "T10.1&ndash;T10.3", "", "", "", ""],
    ["11. Must be refused", "T11.1&ndash;T11.6", "", "", "", ""],
    ["12. Intake review", "T12.1&ndash;T12.9", "", "", "", ""],
    ["13. Notes and flags", "T13.1&ndash;T13.5", "", "", "", ""],
    ["14. Sharing a listing", "T14.1&ndash;T14.4", "", "", "", ""],
    ["15. Showing to a customer", "T15.1&ndash;T15.3", "", "", "", ""],
    ["16. Searches that are refused", "T16.1&ndash;T16.3", "", "", "", ""],
    ["17. Command line", "17.1&ndash;17.5", "", "", "", ""],
], [1.85*inch, 1.0*inch, 0.45*inch, 0.45*inch, 0.55*inch, 1.6*inch]))
A(Spacer(1, 14))
A(table([
    ["Tested by", "", "Date", ""],
    ["Build / image tag", "", "Host", ""],
], [0.95*inch, 2.1*inch, 0.55*inch, 2.3*inch], header=False, zebra=False))
A(Spacer(1, 12))
A(para("Any failure in section 11 is a stop-work item. Everything else can be triaged.", NOTE))

doc.multiBuild(E)
print("wrote", OUT)
