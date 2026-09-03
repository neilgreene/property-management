#!/usr/bin/env python3
"""
Generates the Design Conflict Register PDF.

    python3 docs/generate_conflicts.py

Compares the KAVADOO Vetted Property Marketplace design document
(v1.0, April 2026) against what is actually built at the release named
in VERSION.

Only CONFLICTS go in Part 1 -- places where the document and the build
specify different things, so somebody has to choose. Work that is simply
not done yet is a gap, not a conflict, and lives in Part 2; a gap needs
scheduling, a conflict needs a decision, and mixing them buries the
decisions.
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from _style import (BODY, H1, H2, CODE, CAP, NOTE, GOOD, CT, CS, BLANK, TOC1, TOC2,
                    CELL, CELLB, para, mono, hdr, table, build_doc, S,
                    INK, MUTED, ACCENT, OK, WARN, RULE)
from reportlab.lib.units import inch
from reportlab.platypus import PageBreak, Spacer, Preformatted
from reportlab.platypus.tableofcontents import TableOfContents

OUT = "docs/Design-Conflict-Register.pdf"

with open(os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                       "VERSION")) as _fh:
    VERSION = _fh.read().strip()

CID = S("cid", fontName="Helvetica-Bold", fontSize=10.5, leading=14, textColor=ACCENT,
        spaceBefore=15, spaceAfter=5)
SEV = S("sev", fontName="Helvetica-Bold", fontSize=8, leading=11, textColor=WARN,
        spaceAfter=4)

doc = build_doc(OUT, "Design Conflict Register",
                "SDI / KAVADOO — Design Conflict Register",
                "Where the KAVADOO design document and the built system specify different things")
E = []; A = E.append


def conflict(cid, title, severity, doc_says, built_is, decision):
    A(para(f"{cid} &nbsp;&nbsp;{title}", CID))
    A(para(severity.upper(), SEV))
    A(table([
        ["The document specifies", doc_says],
        ["What is built", built_is],
    ], [1.25*inch, 4.65*inch], header=False, zebra=False))
    A(Spacer(1, 4))
    A(para(f"<b>The decision.</b> {decision}", BODY))


# ------------------------------------------------------------------ cover
A(Spacer(1, 1.5*inch))
A(para("SDI Investment Property Marketplace", CT))
A(Spacer(1, 0.06*inch))
A(para("Design Conflict Register", CS))
A(para("Where the KAVADOO design document and the built system disagree", CS))
A(Spacer(1, 0.45*inch))
A(table([
    ["Design document", "KAVADOO Vetted Property Marketplace, Product Design &amp; Requirements, v1.0, April 2026"],
    ["Built system", mono("v" + VERSION) + ", github.com/neilgreene/property-management"],
    ["Conflicts", "12 — each needs a decision, not a schedule"],
    ["Gaps", "16 — specified, not built, no contradiction"],
    ["Unspecified", "8 — built, not mentioned in the document"],
], [1.25*inch, 4.15*inch], header=False, zebra=False))
A(PageBreak())

A(Spacer(1, 3.4*inch))
A(para("This page is intentionally blank.", BLANK))
A(PageBreak())

A(para("Contents", H1))
A(Spacer(1, 3))
toc = TableOfContents(); toc.levelStyles = [TOC1, TOC2]; toc.dotsMinLevel = 0
A(toc)
A(Spacer(1, 16))
A(para("<b>A conflict is not a gap.</b> A gap is work that has not been done — it "
       "needs scheduling. A conflict is the document and the build specifying "
       "different things, so somebody has to choose, and building further on either "
       "side makes the choice more expensive. Mixing the two buries the decisions in "
       "a backlog, which is why they are separated here.", GOOD))
A(para("Nothing in Part 1 is a defect. Each entry is a place where a reasonable "
       "reading of the document and a reasonable reading of the code point in "
       "different directions.", BODY))
A(PageBreak())

# ================================================================== 1
A(para("1.  Conflicts", H1))
A(para("Ordered by what it costs to reverse, not by size. The first two change the "
       "commercial model, not the code.", BODY))

A(para("1.1  The disclosure model", H2))
conflict("C1", "Who is ever shown the street address", "Highest — the commercial model differs",
    "Section 4.2 and page 8: the address is revealed <b>only to the assigned agent</b>, "
    "and only when a registered user submits a pre-offer or clicks Connect with Agent. "
    "The investor never sees it on the platform.",
    "The address is released <b>to the investor</b> once their fee agreement is signed "
    "and paid — " + mono("sec.can_see_address()") + " grants it to internal staff, the "
    "assigned agent or lender, and any investor whose gate is open.",
    "These are opposite models. In the document the platform never discloses to the "
    "buyer and the fee buys an introduction; in the build the fee buys the address. "
    "Both are coherent products and they price differently, market differently, and "
    "carry different risk. Everything downstream — the gate, the map, the photographs, "
    "the whole visibility model — follows from this one answer, so it should be settled "
    "before anything else on this list.")

conflict("C2", "When the fee is paid, and what payment unlocks", "Highest — nothing unlocks today",
    "Section 3.2: at sign-up the user reviews the agreement, ticks an acknowledgement, "
    "and e-signs. The $750 is <b>collected at closing</b>.",
    mono("ghl.apply_fee_agreement()") + " opens the gate only when the document is "
    "completed <b>and</b> " + mono("payment_status = 'paid'") + ". A signed-but-unpaid "
    "agreement deliberately does not unlock anything — there is a test asserting it.",
    "If the document is right, no money changes hands at sign-up and the gate as built "
    "never opens for anyone. Either the gate keys on acknowledgement rather than "
    "payment, or the fee moves to sign-up. Note that the two-condition check was a "
    "deliberate safeguard against a document being marked complete without payment; "
    "relaxing it to acknowledgement-only is a decision, not a bug fix.")

A(para("1.2  What the public sees", H2))
conflict("C3", "Location granularity", "High — visible on every listing",
    "Section 4.2: metro area only. <b>Never</b> city, zip, neighbourhood, or address. "
    "Public references read like “Atlanta Metro Area”.",
    "City and state are public on every card and in the detail panel. The city is a "
    "search filter and a dropdown. The map plots a point offset by roughly a kilometre.",
    "The build is looser than the specification. Tightening it means a metro layer above "
    "the city, replacing the city filter with a metro filter, and coarsening the map to a "
    "metro boundary rather than a fuzzed point. The workbook import also stores city and "
    "ZIP, which would remain internal.")

conflict("C4", "Schools Rating as a search filter", "High — currently prevented by design",
    "Section 4.1 displays Schools Rating (3–30). Section 4.3 lists it as a search filter "
    "with a <b>minimum threshold</b>.",
    "Registered in " + mono("gov.prohibited_dimension") + " as a fair-housing proxy. The "
    "standing invariant fails if it becomes a readable column, and the web tier "
    "<b>refuses to start</b> if it appears in the filter allowlist. The workbook carries "
    "the value; it is kept in the raw payload and never promoted.",
    "This is not unbuilt — it is actively blocked, and deliberately. School ratings track "
    "the demographics of a catchment, so offering one as a ranking axis is steering, and "
    "the Fair Housing Act does not require intent. <b>Displaying</b> the rating is "
    "defensible. <b>Filtering or sorting</b> on it is the part to put to counsel before "
    "building, and until then the system will not let it be built.")

conflict("C5", "Photograph treatment", "Medium",
    "Section 4.2: all listing photos must be <b>blurred and watermarked</b> before "
    "publishing. Admin uploads originals; the system processes and stores both versions. "
    "Section 13.1 suggests Cloudinary.",
    "Originals are stored unmodified. " + mono("property_media.reveals_location") +
    " marks exterior and street views, which are released on the same predicate as the "
    "address; interiors are public. No blurring or watermarking exists.",
    "Different mechanisms for the same worry. The document degrades every image for "
    "everyone; the build shows interiors intact and withholds the identifying ones "
    "entirely. If C1 resolves toward the document, blurring becomes necessary because "
    "the investor is never entitled to the clear exterior at all.")

A(para("1.3  Identity and structure", H2))
conflict("C6", "Brand separation from SDI", "Medium — affects naming everywhere",
    "Section 2.2: the platform is <b>not affiliated with Simply Do It Investing in any "
    "way</b> from a branding, naming, or website perspective.",
    "SDI naming runs through the build: database roles (" + mono("sdi_app") + ", " +
    mono("sdi_admin") + "), listing references (" + mono("SDI-2609-001") + "), container "
    "images, page titles, and the data right " + mono("SDI-WORKBOOK") + ". " +
    mono("core.brand") + " holds two lenses on the same rows — " + mono("BRAND_A") +
    " (“SDI Marketplace”, $750, self-service) and " + mono("KAVADOO") + " (“Kavadoo "
    "Advisory”, $2,500, concierge).",
    "The two-lens design already anticipates a separate brand reading the same listings, "
    "which is most of the work. What remains is naming: whether SDI identifiers "
    "internal to the database and the container registry count as “affiliation”. If "
    "public-facing separation is enough, this is nearly done. If the separation must go "
    "all the way down, it is a rename across every layer.")

conflict("C7", "Technology platform", "Medium — the document argues against what exists",
    "Section 9 rates ten options. WordPress is <b>strongly recommended as primary</b>; "
    "Bubble.io is <b>highly recommended as second</b>. Custom React/Node/PostgreSQL is "
    "rated <b>1 out of 5 for DIY friendliness</b>, estimated at $40,000–$150,000+, and "
    "described as “not suitable for DIY management”.",
    "Exactly that custom stack: PostgreSQL 16, Node with a single runtime dependency, "
    "no framework.",
    "Worth stating plainly rather than leaving implicit: the document’s own "
    "recommendation argues against the thing that now exists. The build was chosen "
    "because the address gate is enforced inside the database, which none of the "
    "recommended platforms can do — a WordPress or Bubble implementation puts the rule "
    "in application code, where an unguarded query or a plugin bug discloses the "
    "address. That is a real trade against the document’s DIY-maintainability goal, and "
    "it should be an explicit choice rather than a drift.")

conflict("C8", "Listing status vocabulary", "Low — but it feeds the scraper",
    "Section 13.1: Active, Pending, <b>Contingent</b>, Sold, <b>Archived</b>, Draft.",
    mono("draft") + ", " + mono("active") + ", " + mono("coming_soon") + ", " +
    mono("pending") + ", " + mono("sold") + ", " + mono("withdrawn") + ". No "
    + mono("contingent") + " and no " + mono("archived") + "; two extra states the "
    "document does not name.",
    "Small but load-bearing, because " + mono("feed.status_map") + " translates external "
    "feeds into this vocabulary. Contingent currently maps to " + mono("pending") +
    ", which is a reasonable reading but loses a distinction the document wants shown. "
    "Adding two states is a migration and a policy review, not a rename.")

A(para("1.4  Sourcing and configuration", H2))
conflict("C9", "The status scraper", "Medium — behaviour agrees, source does not",
    "Sections 8.2 and 13.5: a <b>daily scraper</b> checking Zillow, Realtor.com and "
    "Redfin. Flags changes; admin confirms manually. Detects properties returning to For "
    "Sale.",
    "The whole framework exists and the <b>behaviour matches the document exactly</b> — "
    "flags rather than auto-changes, admin review queue, relisting detected and acted on "
    "immediately. The scraper <b>adapter itself is deliberately unimplemented</b> and the "
    "portal source is registered advisory and barred from retiring a listing.",
    "The disagreement is only about the data source. A scraper cannot distinguish “this "
    "listing is gone” from “the page changed shape” — both are a missing selector — so "
    "its most common failure mode is identical to its most destructive signal. That is "
    "the engineering argument; the portals’ terms of service are a second one. A licensed "
    "MLS feed via RESO satisfies the same requirement, and the RESO adapter is written. "
    "The decision is whether to accept the scraper’s failure mode, pay for a feed, or "
    "keep checking by hand.")

conflict("C10", "Fee configurability", "Low",
    "Section 8.1: the platform fee is adjustable <b>platform-wide or per property type, "
    "metro, or deal</b>.",
    "One fee per brand, in " + mono("core.brand.platform_fee") + ". No per-property, "
    "per-metro or per-deal override.",
    "A schema addition rather than a redesign, but it interacts with C1 and C2: what the "
    "fee is <i>for</i> determines where the override belongs.")

conflict("C11", "Metro as the organising unit", "Medium",
    "Sections 2.3 and 13.6: 12 metros, each with <b>one</b> assigned agent, property "
    "manager and lender. Metros are added and edited through the admin panel without "
    "developer involvement.",
    mono("core.market_area") + " is keyed on city and state, not metro. Assignments are "
    "<b>per property</b> (" + mono("core.property_assignment") + "), not per metro. There "
    "is no property manager or lender role and no metro admin screen.",
    "The document makes the metro the unit that carries the professional team; the build "
    "makes the property the unit. Per-property assignment is strictly more flexible and "
    "strictly more work to administer — 200 listings means 200 assignments instead of 12. "
    "Metro-level defaults with per-property override would satisfy both, and this is "
    "entangled with C3.")

conflict("C12", "GDPR applicability", "Low — but it is registered as not applicable",
    "Section 13.2: GDPR/privacy-compliant user data handling, <b>especially for "
    "international users</b>. Section 11.1(D) makes the international investor a named "
    "target audience.",
    "GDPR is registered in " + mono("gov.regulation") + " with status "
    + mono("not_applicable") + ", on the basis that there is no EU marketing and no EU "
    "investors today.",
    "The register is right about today and wrong about the document’s intent. A named "
    "international audience makes it applicable on the first EU or UK data subject. The "
    "row already records the trigger condition; the status needs revisiting alongside "
    "the CCPA and state-privacy gaps, which have no control at all.")

# ================================================================== 2
A(PageBreak())
A(para("2.  Gaps", H1))
A(para("Specified in the document, not built, and not in conflict with anything. These "
       "need scheduling, not deciding.", BODY))
A(table([
    hdr(["Area", "What the document specifies", "Section"]),
    ["Roles", "Property Manager, Lender, VA and Partner roles, each with a scoped portal. Four of eight roles exist", "3"],
    ["Sign-up", "Country of residence; inline DocuSign-style e-signature; confirmation email with the signed agreement", "3.2"],
    ["Q&amp;A", "Threaded per-property comments, anonymised usernames, agent badges, private questions", "5.2"],
    ["Moderation", "Profanity filter and PII scrubbing covering emails, phone formats, spelled-out numbers, addresses and URLs", "5.3"],
    ["Engagement", "Express Interest button creating a lead record", "5.4"],
    ["Messaging", "Internal threaded messaging to agent, property manager and lender. No content in outbound email", "5.5–5.7"],
    ["Pre-offer", "Non-binding letter of intent with price, financing type, timeline, contingencies and attachments", "5.8"],
    ["Documents", "Personal document portal; access scoped to the user, admin, and any agent or lender they contacted", "5.9"],
    ["Co-investment", "Waitlist of two per property, vetting flags, admin match trigger, liability release, template download", "6"],
    ["Projections", "Cash flow, ROI and projected value at years 1, 5, 10, 15 and 20 at 2% rent growth and 4% vacancy", "4.1"],
    ["Filters", "Down payment, monthly cash flow, annual ROI, cap rate, total cash required, metro multi-select", "4.3"],
    ["Categories", "Investment type (LTR, MTR, STR, Hybrid); Quadplex and Townhome property types", "4.3"],
    ["Import", "Post-import steps: assign agent, PM and lender; process photos; set type tags; confirm description", "4.4"],
    ["Notifications", "In-app and email alerts for registrations, pre-offers, co-op signups, vetting, status flags, uploads", "8.3"],
    ["Analytics", "Signups, property engagement, contact conversions, co-investment activity", "8.1"],
    ["Admin", "Metro management; full property CRUD through the interface rather than SQL", "13.6"],
], [0.95*inch, 4.15*inch, 0.55*inch]))

# ================================================================== 3
A(para("3.  Built, Not Specified", H1))
A(para("The document does not mention these. They are not conflicts, but nobody has "
       "agreed to them either, and two of them constrain what can be built next.", BODY))
A(table([
    hdr(["What exists", "Why it matters here"]),
    ["<b>GoHighLevel integration</b> — schema " + mono("ghl") + ", webhook intake with signature verification, outbox, transaction and document sync, EspoCRM migration",
     "The document never mentions a CRM. This is the largest unspecified subsystem, and the fee gate depends on it"],
    ["<b>Data rights and compliance register</b> — schema " + mono("gov") + ", 17 regimes, per-instrument territory and permitted use",
     "Constrains publication. It is what reports the workbook listings as published under an unreviewed right"],
    ["<b>Fair-housing enforcement</b> — prohibited dimensions as data, checked by a standing invariant and asserted by the web tier at startup",
     "<b>Actively prevents C4.</b> Any filter work must satisfy it"],
    ["<b>Row-level security as the enforcement mechanism</b>",
     "The document is silent on <i>how</i> privacy is enforced. This choice is why C7 went the way it did"],
    ["<b>Deal pipeline</b> — " + mono("core.deal") + ", stage history, per-party visibility",
     "Closest existing thing to the sales-cycle management now being asked for"],
    ["<b>Staged intake review</b> — load, validate, approve, release",
     "The document asks for bulk import; the staging and review model is an addition"],
    ["<b>Plain-English search</b> — free text to a bounded criteria object",
     "The document lists AI matching as a Phase 2 item. The validator is the part that makes a model safe to add"],
    ["<b>Generated placeholder photography</b>",
     "Avoids stock licensing during development. Replaced by a URL change"],
], [2.4*inch, 3.5*inch]))

# ================================================================== 4
A(PageBreak())
A(para("4.  What To Decide First", H1))
A(para("C1 and C2 are not independent of the rest — they are upstream of most of it.", BODY))
A(table([
    hdr(["Decide", "Because it settles"]),
    ["<b>C1</b> — who ever sees the address", "C3 (how coarse the location must be), C5 (whether blurring is required at all), and what the fee is for"],
    ["<b>C2</b> — what payment unlocks, and when", "Whether the gate as built functions at all, and C10"],
    ["<b>C4</b> — schools rating as a filter", "Whether a filter the system currently refuses to build gets built. Needs counsel, not engineering"],
    ["<b>C7</b> — platform", "Whether this build continues. Deciding it late is the expensive version"],
    ["<b>C9</b> — how listing status is sourced", "Whether to accept a scraper's failure mode, license a feed, or check by hand"],
], [0.85*inch, 5.05*inch]))
A(Spacer(1, 8))
A(para("C6, C8, C10, C11 and C12 are ordinary work once the five above are settled. "
       "Everything in Part 2 can be scheduled independently, except the filter and "
       "import items, which wait on C3 and C4.", BODY))
A(Spacer(1, 10))
A(para("This register compares a document dated April 2026 against the build at "
       + mono("v" + VERSION) + ". Regenerate it after either changes: "
       + mono("python3 docs/generate_conflicts.py") + ".", CAP))

doc.multiBuild(E)
print("wrote", OUT)
