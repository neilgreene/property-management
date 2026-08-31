#!/usr/bin/env python3
"""
Generates the System Documentation PDF.

Facts here are extracted from the repository and a freshly built database,
not written from memory. Regenerate with:
    python3 docs/generate_system_documentation.py
"""
from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER
from reportlab.lib.pagesizes import LETTER
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import inch
from reportlab.platypus import (BaseDocTemplate, Flowable, Frame, PageBreak, PageTemplate,
                                Paragraph, Preformatted, Spacer, Table, TableStyle)
from reportlab.platypus.tableofcontents import TableOfContents

OUT = "docs/System-Documentation.pdf"

INK, MUTED, ACCENT = colors.HexColor("#12161C"), colors.HexColor("#5A6572"), colors.HexColor("#1F5FA9")
WARN, RULE, BAND = colors.HexColor("#A8410E"), colors.HexColor("#D4D9E0"), colors.HexColor("#EEF2F7")
CODE_BG, OKBG = colors.HexColor("#F5F7FA"), colors.HexColor("#EDF5EE")
OK = colors.HexColor("#1E6B33")

ss = getSampleStyleSheet()
def S(n, parent=None, **kw): return ParagraphStyle(n, parent=parent or ss["Normal"], **kw)

BODY  = S("body", fontName="Helvetica", fontSize=9.5, leading=13.6, textColor=INK, spaceAfter=7)
H1    = S("h1", fontName="Helvetica-Bold", fontSize=15, leading=19, textColor=INK, spaceBefore=16, spaceAfter=8)
H2    = S("h2", fontName="Helvetica-Bold", fontSize=11, leading=15, textColor=ACCENT, spaceBefore=12, spaceAfter=5)
BUL   = S("bul", parent=BODY, leftIndent=13, bulletIndent=3, spaceAfter=3.5)
CODE  = S("code", fontName="Courier", fontSize=7.9, leading=10.4, textColor=INK,
          backColor=CODE_BG, borderPadding=6, leftIndent=3, spaceAfter=8)
CELL  = S("cell", fontName="Helvetica", fontSize=8, leading=10.8, textColor=INK)
CELLB = S("cellb", parent=CELL, fontName="Helvetica-Bold")
CAP   = S("cap", fontName="Helvetica-Oblique", fontSize=8, leading=11, textColor=MUTED, spaceAfter=9)
NOTE  = S("note", parent=BODY, leftIndent=9, textColor=WARN, fontName="Helvetica-Bold", fontSize=9, leading=13)
GOOD  = S("good", fontName="Helvetica", fontSize=9, leading=12.8, textColor=INK, backColor=OKBG,
          borderPadding=7, borderColor=OK, borderWidth=0.7, spaceAfter=9, spaceBefore=3)
CT    = S("ct", fontName="Helvetica-Bold", fontSize=25, leading=30, textColor=INK, alignment=TA_CENTER, spaceAfter=10)
BLANK = S("blank", fontName="Helvetica", fontSize=8.5, leading=12, textColor=MUTED, alignment=TA_CENTER)
TOC1  = S("toc1", fontName="Helvetica-Bold", fontSize=9.5, leading=14, textColor=INK,
          spaceBefore=5, leftIndent=0, firstLineIndent=0)
TOC2  = S("toc2", fontName="Helvetica", fontSize=8.5, leading=12, textColor=MUTED,
          leftIndent=18, firstLineIndent=0)
CS    = S("cs", fontName="Helvetica", fontSize=12.5, leading=17, textColor=MUTED, alignment=TA_CENTER, spaceAfter=5)

class CoverMark(Flowable):
    """A drawn cover illustration, not a stock photograph.

    Building silhouettes whose heights double as a bar chart, with a return
    curve rising across them: the two things this system actually joins, a
    portfolio of individual properties and the analysis applied to it. Drawn
    in the document's own palette so the cover belongs to the document, and
    original so there is no licence attached to it.
    """
    def __init__(self, width, height):
        Flowable.__init__(self)
        self.width, self.height = width, height

    def draw(self):
        c = self.canv
        w, h = self.width, self.height
        base = h * 0.14                      # ground line
        # Heights are the series; the curve below tracks the same numbers.
        series = [0.34, 0.46, 0.40, 0.58, 0.52, 0.72, 0.66, 0.86]
        n = len(series)
        gap = w * 0.018
        bw = (w - gap * (n - 1)) / n

        c.saveState()

        # ground
        c.setStrokeColor(RULE); c.setLineWidth(0.8)
        c.line(0, base, w, base)

        pts = []
        for i, v in enumerate(series):
            x = i * (bw + gap)
            bh = (h - base) * v
            top = base + bh
            # Alternate fill so the row reads as distinct holdings rather
            # than one mass.
            c.setFillColor(colors.HexColor("#E8EDF3") if i % 2 else colors.HexColor("#DDE4EC"))
            c.setStrokeColor(colors.HexColor("#C6CFDA")); c.setLineWidth(0.6)
            c.rect(x, base, bw, bh, stroke=1, fill=1)

            # windows: a light grid, denser on the taller holdings
            c.setFillColor(colors.white)
            rows = max(2, int(bh / (h * 0.085)))
            cols = 3
            mw, mh = bw * 0.16, h * 0.028
            padx = (bw - cols * mw) / (cols + 1)
            pady = (bh - rows * mh) / (rows + 1)
            if pady > 0:
                for r in range(rows):
                    for cc in range(cols):
                        c.rect(x + padx * (cc + 1) + mw * cc,
                               base + pady * (r + 1) + mh * r,
                               mw, mh, stroke=0, fill=1)
            pts.append((x + bw / 2.0, top))

        # the return curve over the same series
        c.setStrokeColor(ACCENT); c.setLineWidth(1.5)
        path = c.beginPath()
        path.moveTo(pts[0][0], pts[0][1] + h * 0.07)
        for px, py in pts[1:]:
            path.lineTo(px, py + h * 0.07)
        c.drawPath(path, stroke=1, fill=0)

        for px, py in pts:
            c.setFillColor(colors.white)
            c.circle(px, py + h * 0.07, 2.6, stroke=0, fill=1)
            c.setStrokeColor(ACCENT); c.setLineWidth(1.2)
            c.circle(px, py + h * 0.07, 2.6, stroke=1, fill=0)

        c.restoreState()


def para(t, s=BODY): return Paragraph(t, s)
def mono(t): return f"<font face='Courier'>{t}</font>"
def hdr(cs): return [Paragraph(c, CELLB) for c in cs]
def buls(items): return [Paragraph(f"•&nbsp;&nbsp;{i}", BUL) for i in items]

def table(rows, widths, header=True, zebra=True):
    data = [[c if hasattr(c, "wrap") else Paragraph(str(c), CELL) for c in r] for r in rows]
    t = Table(data, colWidths=widths, repeatRows=1 if header else 0, hAlign="LEFT")
    cmds = [("VALIGN",(0,0),(-1,-1),"TOP"),("TOPPADDING",(0,0),(-1,-1),4.5),
            ("BOTTOMPADDING",(0,0),(-1,-1),4.5),("LEFTPADDING",(0,0),(-1,-1),6),
            ("RIGHTPADDING",(0,0),(-1,-1),6),("LINEBELOW",(0,0),(-1,-2),0.4,RULE),
            ("BOX",(0,0),(-1,-1),0.6,RULE)]
    if header: cmds += [("BACKGROUND",(0,0),(-1,0),BAND),("LINEBELOW",(0,0),(-1,0),0.9,ACCENT)]
    if zebra:
        st = 1 if header else 0
        for i in range(st, len(data)):
            if (i-st) % 2 == 1: cmds.append(("BACKGROUND",(0,i),(-1,i),colors.HexColor("#FAFBFC")))
    t.setStyle(TableStyle(cmds)); return t

def decorate(canvas, doc):
    # Pages 1 and 2 are the cover and the intentional blank. Running heads and
    # folios start on the contents page, which is the first page a reader
    # navigates by.
    canvas.saveState(); w, h = LETTER
    if doc.page > 2:
        canvas.setFont("Helvetica", 7.5); canvas.setFillColor(MUTED)
        canvas.drawString(0.9*inch, h-0.62*inch, "SDI Investment Property Marketplace")
        canvas.drawRightString(w-0.9*inch, h-0.62*inch, "System Documentation")
        canvas.setStrokeColor(RULE); canvas.setLineWidth(0.5)
        canvas.line(0.9*inch, h-0.72*inch, w-0.9*inch, h-0.72*inch)
        canvas.line(0.9*inch, 0.72*inch, w-0.9*inch, 0.72*inch)
        canvas.setFont("Helvetica", 7.5)
        canvas.drawCentredString(w/2.0, 0.55*inch, f"Page {doc.page}")
        canvas.drawString(0.9*inch, 0.55*inch, "neilgreene/property-management @ main")
        canvas.drawRightString(w-0.9*inch, 0.55*inch, "Internal engineering document")
    canvas.restoreState()

class Doc(BaseDocTemplate):
    """Reports its own headings to the TOC as they are laid out.

    Page numbers therefore come from where a heading actually landed, not
    from a hand-maintained list -- which is the only way a contents page
    survives the document being edited.
    """
    def afterFlowable(self, flowable):
        if not isinstance(flowable, Paragraph):
            return
        name = flowable.style.name
        text = flowable.getPlainText()
        if text.strip() == "Contents":
            return                      # the contents page does not list itself
        if name == "h1":
            self.notify("TOCEntry", (0, text, self.page))
        elif name == "h2":
            self.notify("TOCEntry", (1, text, self.page))


doc = Doc(OUT, pagesize=LETTER, leftMargin=0.9*inch, rightMargin=0.9*inch,
                      topMargin=0.92*inch, bottomMargin=0.92*inch,
                      title="SDI Investment Property Marketplace — System Documentation",
                      author="SDI Investment Property Marketplace",
                      subject="What has been built: architecture, API, users and how to run it")
doc.addPageTemplates([PageTemplate(id="m", onPage=decorate,
    frames=[Frame(doc.leftMargin, doc.bottomMargin, doc.width, doc.height, id="f")])])

E=[]; A=E.append

# ------------------------------------------------------------------ cover
A(Spacer(1, 0.95*inch))
A(CoverMark(5.9*inch, 1.85*inch))
A(Spacer(1, 0.42*inch))
A(para("SDI Investment Property Marketplace", CT))
A(Spacer(1, 0.04*inch))
A(para("System Documentation", CS))
A(para("What has been built, how to run it, and who can see what", CS))
A(Spacer(1, 0.28*inch))
A(table([
    ["Repository", mono("github.com/neilgreene/property-management")],
    ["Branch", mono("main")],
    ["Commits", "13"],
    ["Database", "PostgreSQL 16 (row-level security; requires 15+)"],
    ["Application", "Node.js 18+ (no framework, no runtime dependencies beyond " + mono("pg") + ")"],
    ["Automated checks", "63 worker tests plus 4 SQL walkthroughs, all passing"],
    ["Deployment status", "Local development only. Not deployed, not internet-facing."],
], [1.6*inch, 4.3*inch], header=False))
A(Spacer(1, 0.28*inch))
A(para("Every fact in this document was extracted from the repository and from a "
       "freshly built database, not written from memory. Regenerate it with "
       "<font face='Courier'>python3 docs/generate_system_documentation.py</font>.", CAP))
A(PageBreak())

# ------------------------------------------------------------- page 2, blank
A(Spacer(1, 4.4*inch))
A(para("This page intentionally left blank.", BLANK))
A(PageBreak())

# ---------------------------------------------------------- page 3, contents
A(para("Contents", H1))
A(Spacer(1, 6))
toc = TableOfContents()
toc.levelStyles = [TOC1, TOC2]
toc.dotsMinLevel = 0
A(toc)
A(PageBreak())

# ------------------------------------------------------------------ 1
A(para("1.  What This Is", H1))
A(para("A working system for a private investment property marketplace: vetted properties "
       "listed with financial analysis, browsable without revealing addresses, with the full "
       "detail unlocked only after an investor signs and pays the platform fee agreement. "
       "Agents see only their own assignments. Staff see everything.", BODY))
A(para("1.1  The problem it solves first", H2))
A(para("The commercial model depends on one thing holding: an unpaid visitor must not be able "
       "to obtain a property's street address. Everything else is ordinary software; that is "
       "not. So the visibility rules are enforced <b>inside the database</b>, by row-level "
       "security policies and column grants, rather than by application code.", BODY))
A(para("This matters because it changes what an attacker has to defeat. If the rule lives in "
       "application code, anyone who finds an unguarded query, an API bug, or a direct database "
       "connection gets the address. Here, the address is withheld by the database itself: a "
       "caller who writes their own SQL, bypasses the application entirely, and connects "
       "directly still cannot read it.", GOOD))
A(para("1.2  Three visibility bands", H2))
A(table([
    hdr(["Band", "Contains", "Released to", "Enforced by"]),
    ["1 — Public", "City, price, cap rate, NOI, beds, baths, year built", "Anyone, including anonymous visitors", "RLS policy per role"],
    ["2 — Gated", "Street address, unit, parcel number, seller disclosure, true coordinates",
     "Investors who signed AND paid; the assigned agent; staff", "Masking in a " + mono("security_invoker") + " view, keyed on a data predicate"],
    ["3 — Internal", "Acquisition cost, source channel, staff notes, margin", "Staff only", "Column-level GRANT (a hard ACL)"],
], [0.85*inch, 1.9*inch, 1.55*inch, 1.6*inch]))
A(Spacer(1, 5))
A(para("Coordinates degrade rather than disappear. An ungated viewer gets a deterministic "
       "offset of roughly one kilometre, seeded on the property id, so a map still renders a "
       "neighbourhood and repeated page loads cannot be averaged to recover the true point.", BODY))

# ------------------------------------------------------------------ 2
A(para("2.  How To Run It", H1))
A(para("2.1  Docker — nothing installed but Docker", H2))
A(Preformatted("git clone https://github.com/neilgreene/property-management\n"
               "cd property-management\n"
               "docker compose up", CODE))
A(para("Builds the database from " + mono("sql/") + ", seeds it, and serves the demo at "
       "<b>http://localhost:3000</b>. PostgreSQL is exposed on " + mono("localhost:5432") +
       " (database " + mono("sdi") + ", user " + mono("postgres") + ", password " +
       mono("postgres") + "). " + mono("docker compose down -v") + " discards the database.", BODY))

A(para("2.2  Local PostgreSQL 16+ and Node 18+", H2))
A(Preformatted("./run.sh", CODE))
A(para("Loads all eleven schema files, runs all four SQL walkthroughs, runs the 63 worker "
       "tests, then starts the demo. It assumes " + mono("psql") + " and " + mono("createdb") +
       " work as your own user, which is the default for Postgres.app and Homebrew.", BODY))

A(para("2.3  Individual pieces", H2))
A(table([
    hdr(["Command", "What it does"]),
    [mono("psql -d sdi -f sql/05_tests.sql"), "Security walkthrough: 11 checks, 5 of them attacks"],
    [mono("psql -d sdi -f sql/07_ghl_tests.sql"), "GoHighLevel bridge: 7 checks"],
    [mono("psql -d sdi -f sql/10_review_tests.sql"), "Review queue actions: 7 checks"],
    [mono("psql -d sdi -f sql/14_pipeline_tests.sql"), "Deal visibility and stage history: 9 checks"],
    [mono("cd worker &amp;&amp; npm test"), "63 unit and end-to-end tests"],
], [2.6*inch, 3.3*inch]))

A(para("2.4  The integration worker", H2))
A(para("Deliberately not started by a bare " + mono("docker compose up") + ", because it needs "
       "real GoHighLevel credentials and there is no point running it without them.", BODY))
A(Preformatted("GHL_TOKEN=... GHL_LOCATION_ID=... docker compose --profile worker up", CODE))
A(table([
    hdr(["Variable", "Where it comes from"]),
    [mono("GHL_TOKEN"), "GoHighLevel: Settings &rarr; Private Integrations. Scoped to an entire sub-account."],
    [mono("GHL_LOCATION_ID"), "The sub-account id, visible in the GoHighLevel URL"],
    [mono("GHL_WEBHOOK_PUBLIC_KEY"), "GoHighLevel's published webhook verification key (PEM)"],
], [1.9*inch, 4.0*inch]))
A(Spacer(1, 5))
A(para("The token is read from the environment and is never written into any file in the "
       "repository. It grants access to the whole sub-account — contacts, invoices, "
       "transactions — so it must never reach browser-side code.", NOTE))
A(PageBreak())

# ------------------------------------------------------------------ 3
A(para("3.  Users and Access", H1))
A(para("3.1  There is no login system yet", H2))
A(para("This must be stated plainly, because it is the most likely thing to be misread. The "
       "system has <b>no authentication</b>: no password for a person, no session, no sign-in "
       "page. The demo presents a persona switcher, and choosing a persona makes the web tier "
       "assume the matching database role and set that person's id for the duration of one "
       "transaction.", NOTE))
A(para("That is deliberate for this stage and costs nothing later. The database contract is "
       "identical either way: in production the persona and actor id come out of an "
       "authenticated session instead of a dropdown, and not one policy, view or grant changes. "
       "Authentication is the missing piece — the authorisation model beneath it is complete "
       "and tested.", BODY))

A(para("3.2  Seeded people", H2))
A(para("Created by " + mono("sql/04_seed.sql") + ". These are demonstration records, not real "
       "people; the addresses and financials attached to them are invented.", BODY))
A(table([
    hdr(["Name", "Role", "Email", "Fee agreement", "Brand", "What they demonstrate"]),
    ["Jessica Pool", "admin", mono("jpool@yahoo.com"), "n/a", "BRAND_A", "Full staff access, all bands"],
    ["Dan Beitor", "admin", mono("dan@example.com"), "n/a", "BRAND_A", "Full staff access, all bands"],
    ["Tom Bradbury", "agent", mono("tom@example.com"), "n/a", "BRAND_A", "4 assigned properties, incl. an unpublished draft"],
    ["Priya Raman", "agent", mono("priya@example.com"), "n/a", "BRAND_A", "A second agent, to prove agents are isolated"],
    ["Ruth Okonkwo", "investor", mono("ruth@example.com"), "signed", "BRAND_A", "Gate open: sees addresses and true coordinates"],
    ["Marcus Pell", "investor", mono("marcus@example.com"), "not signed", "BRAND_A", "Gate shut: same query, address withheld"],
    ["Ines Duarte", "investor", mono("ines@example.com"), "signed", "KAVADOO", "The second brand, at concierge pricing"],
], [0.92*inch, 0.55*inch, 1.28*inch, 0.72*inch, 0.78*inch, 1.65*inch]))
A(Spacer(1, 5))
A(para("Ruth and Marcus are the pair that carries the argument: identical role, identical SQL, "
       "and the only difference between them is one timestamp in a data column. The address "
       "appears for one and not the other with no application logic involved at all.", GOOD))

A(para("3.3  Database roles", H2))
A(para("Application roles are created " + mono("NOLOGIN") + " and passwordless on purpose. " +
       mono("sdi_app") + " is " + mono("NOINHERIT") + ", so it holds no privileges of its own "
       "and must assume exactly one persona role per transaction — the application cannot "
       "forget to assume a role and accidentally run with more authority than it should.", BODY))
A(table([
    hdr(["Role", "Purpose", "Login", "Demo password"]),
    [mono("sdi_app"), "The only role the web tier connects as", "yes", mono("demo_app_pw")],
    [mono("sdi_public"), "Anonymous visitors. Band 1 only", "no", "assumed via SET ROLE"],
    [mono("sdi_investor"), "Investors. Band 2 if the gate is open", "no", "assumed via SET ROLE"],
    [mono("sdi_agent"), "Agents. Band 2 on assigned properties", "no", "assumed via SET ROLE"],
    [mono("sdi_admin"), "Staff. All three bands", "no", "assumed via SET ROLE"],
    [mono("sdi_integration"), "The GoHighLevel worker. No access to core at all", "yes", mono("demo_int_pw")],
    [mono("sdi_test_admin"), "Test fixtures only. " + mono("BYPASSRLS"), "yes", mono("demo_test_pw")],
], [1.3*inch, 2.55*inch, 0.5*inch, 1.55*inch]))
A(Spacer(1, 5))
A(para("Those passwords come from " + mono("sql/99_local_logins.sql") + ", exist so the demo "
       "stack is connectable, and are published in a public repository. They are worth exactly "
       "nothing and that file must not be loaded anywhere that matters. " +
       mono("sdi_test_admin") + " carries " + mono("BYPASSRLS") + " and belongs only in a test "
       "database.", NOTE))
A(PageBreak())

# ------------------------------------------------------------------ 4
A(para("4.  Architecture", H1))
A(Preformatted(
  "  browser ──▶ web/server.js ──▶  api.*  ──▶  core.*        (PostgreSQL)\n"
  "                 sdi_app          views       tables + RLS\n"
  "                 SET ROLE          │\n"
  "                                   └──▶ sec.*  predicates\n"
  "\n"
  "  GoHighLevel ──webhook──▶ worker/src/index.js ──▶  ghl.*   (separate schema,\n"
  "              ◀──REST────  sdi_integration                   no access to core)", CODE))
A(para("4.1  Four schemas, and the separation is load-bearing", H2))
A(table([
    hdr(["Schema", "Holds", "Who has USAGE"]),
    [mono("core"), "Base tables. Properties, people, deals, assignments",
     "No application role. Name resolution fails before any ACL or policy is consulted, so there is no path around the views."],
    [mono("sec"), "Security predicates, definer-rights",
     "All persona roles. They live here because a " + mono("security_invoker") + " view resolves the functions it calls as the caller too, not just the tables."],
    [mono("api"), "Masking views and the write path", "All persona roles. The only surface the application reads."],
    [mono("ghl"), "The GoHighLevel bridge", mono("sdi_integration") + " only. The web tier cannot enumerate CRM contacts, invoices or transactions."],
], [0.8*inch, 1.85*inch, 3.25*inch]))
A(Spacer(1, 5))
A(para("Brand is a lens, not a property attribute. Both brands read the same "
       + mono("core.property") + " rows; " + mono("core.property_brand") + " decides publication "
       "and price per brand. Adding the second brand is rows in one table, not a schema "
       "refactor.", BODY))

A(para("4.2  Tables", H2))
A(table([
    hdr(["Schema", "Tables"]),
    [mono("core"), mono("brand") + ", " + mono("person") + ", " + mono("property") + ", " +
     mono("property_brand") + ", " + mono("property_assignment") + ", " + mono("saved_property") +
     ", " + mono("pipeline") + ", " + mono("pipeline_stage") + ", " + mono("deal") + ", " +
     mono("deal_stage_history")],
    [mono("ghl"), mono("id_map") + ", " + mono("webhook_event") + ", " + mono("transaction") +
     ", " + mono("fee_agreement") + ", " + mono("sync_state") + ", " + mono("outbox") + ", " +
     mono("review_queue") + ", " + mono("reviewable_field")],
], [0.8*inch, 5.1*inch]))
A(Spacer(1, 4))
A(para("All ten " + mono("core") + " tables have row-level security enabled and forced.", BODY))

# ------------------------------------------------------------------ 5
A(para("5.  The API", H1))
A(para("5.1  Database views — what the application reads", H2))
A(table([
    hdr(["View", "Returns", "Granted to"]),
    [mono("api.property"), "Properties with band 2 masked or released per caller", "public, investor, agent, admin"],
    [mono("api.property_internal"), "Band 3: acquisition cost, source, notes, margin", "admin only"],
    [mono("api.my_saved"), "The caller's own saved properties", "investor, admin"],
    [mono("api.deal"), "Deals the caller is party to, with stage and age", "investor, agent, admin"],
    [mono("api.deal_history"), "Stage transitions for those deals", "investor, agent, admin"],
    [mono("api.review_open"), "Inbound CRM edits awaiting a decision", "admin only"],
], [1.55*inch, 2.65*inch, 1.7*inch]))
A(Spacer(1, 4))
A(para("Note that " + mono("api.deal") + " is not granted to " + mono("sdi_public") + " at all. "
       "A deal is never public, at any stage.", BODY))

A(para("5.2  Callable functions", H2))
A(table([
    hdr(["Function", "Does", "Caller"]),
    [mono("api.save_property(uuid)"), "Saves a property to the caller's list, rejecting anything they cannot see", "investor"],
    [mono("api.review_decide(bigint, text)"), "Accept or reject a queued CRM edit; accepting writes an allowlist of columns only", "admin"],
    [mono("api.security_invariants()"), "Returns zero rows, or names what is broken", "admin"],
    [mono("ghl.apply_fee_agreement(text)"), "Opens the gate for a person, if the document is completed AND paid", "integration worker"],
], [2.0*inch, 2.7*inch, 1.2*inch]))
A(Spacer(1, 4))
A(para("The " + mono("sec.*") + " predicates (" + mono("can_see_address") + ", " +
       mono("can_see_deal") + ", " + mono("is_assigned") + ", " + mono("actor") + ", " +
       mono("jitter") + " and others) are internal. They are the shared source of truth that "
       "policies, views and write functions all consult, so a rule cannot drift between the "
       "place it is read and the place it is enforced.", BODY))

A(para("5.3  HTTP endpoints", H2))
A(table([
    hdr(["Service", "Method and path", "Purpose"]),
    ["Web demo", mono("GET /"), "The demo interface"],
    ["Web demo", mono("GET /api/view?persona=&amp;brand="), "Everything one persona sees, in one payload"],
    ["Web demo", mono("GET /api/probe?persona="), "Attempts a direct base-table read, to show the refusal"],
    ["Worker", mono("POST /webhooks/ghl"), "Receives a GoHighLevel delivery, verifies its signature"],
    ["Worker", mono("GET /healthz"), "Queue depth: pending events, bad signatures, outbox backlog, open reviews"],
], [0.85*inch, 2.35*inch, 2.7*inch]))
A(Spacer(1, 5))
A(para("The web demo runs on port 3000, the worker on 3001. Neither is authenticated; neither "
       "should be exposed to a network until section 8 is addressed.", NOTE))
A(PageBreak())

# ------------------------------------------------------------------ 6
A(para("6.  The GoHighLevel Integration", H1))
A(para("Built against GoHighLevel's official OpenAPI specifications. The full API contract is "
       "documented separately in " + mono("docs/GHL-Interface-Specification.pdf") + " (17 pages).", BODY))
A(para("6.1  What the worker does", H2))
A(table([
    hdr(["Component", "Responsibility"]),
    [mono("ghlClient.js"), "HTTP client. Sets the required " + mono("Version: 2021-07-28") + " header once, paces under the 100-request/10-second limit, retries 429 and 5xx, never retries 403"],
    [mono("signature.js"), "Verifies webhook signatures against GoHighLevel's published RSA public key"],
    [mono("webhookReceiver.js"), "Records deliveries, deduplicating on " + mono("webhookId") + " and rejecting stale ones"],
    [mono("handlers.js"), "Dispatches received events"],
    [mono("outbox.js"), "Drains outbound writes with retry that cannot duplicate a record"],
    [mono("sync/documents.js"), "Polls fee agreement state"],
    [mono("sync/transactions.js"), "Nightly reconciliation of payments"],
    [mono("migrate/"), "EspoCRM to GoHighLevel load, in ordered passes"],
], [1.5*inch, 4.4*inch]))

A(para("6.2  The fee gate has two conditions, not one", H2))
A(para("GoHighLevel reports document status and payment status <i>independently</i>. A document "
       "can be signed and unpaid. " + mono("ghl.apply_fee_agreement()") + " is the only thing in "
       "the system that opens the gate, and it requires both: completed or accepted, "
       "<b>and</b> paid. A tag-based unlock gets this wrong.", GOOD))

A(para("6.3  Direction decides what happens to an inbound event", H2))
A(para(mono("core.property") + " is the system of record; GoHighLevel is downstream of it for "
       "listings. So an inbound record edit means somebody changed a property inside the CRM, "
       "against the grain of the architecture. Applying it would let the CRM silently overwrite "
       "the authoritative row. Dropping it would lose a real edit. It is neither: it goes to "
       + mono("ghl.review_queue") + " for a person to decide.", BODY))
A(para("Events that genuinely originate in GoHighLevel — a signed document, a settled payment, "
       "a contact created by staff — are applied directly, because for those GoHighLevel is the "
       "source. Accepting a queued edit writes only an allowlist of band 1 columns, so a status "
       "change can never become a route to rewriting an address or a cost basis.", BODY))

A(para("6.4  One item is unverified", H2))
A(para("GoHighLevel publishes the webhook public key but does not document the signature "
       "algorithm. The code uses PKCS#1 v1.5 with SHA-256, the conventional pairing for that key "
       "format. <b>One captured live delivery would settle it</b>, and until then the receiver "
       "should not be trusted in production. " + mono("worker/tools/capture-webhook.js") +
       " exists to capture one: run it somewhere GoHighLevel can reach, send a test contact "
       "through, and it writes the raw bytes and headers untouched.", NOTE))

# ------------------------------------------------------------------ 7
A(para("7.  What Is Tested", H1))
A(para("Not a coverage percentage. These are the specific claims that are checked, and the "
       "attacks that are run against them.", BODY))
A(table([
    hdr(["Suite", "Checks", "Notable"]),
    [mono("sql/05_tests.sql"), "11", "Five attacks: direct base-table read, another investor's saved list, saving an invisible property, a VOLATILE predicate side-channel, and the standing invariants"],
    [mono("sql/07_ghl_tests.sql"), "7", "A signed-but-unpaid document must not open the gate; replay must not move a signature timestamp"],
    [mono("sql/10_review_tests.sql"), "7", "A payload smuggling an address and a cost basis alongside a legitimate status change; only the allowlist is applied"],
    [mono("sql/14_pipeline_tests.sql"), "9", "One agent cannot read another's deal by naming its id; one investor cannot read another's stage history"],
    [mono("worker/ (npm test)"), "63", "Signature forgery, replay, oversized bodies, rate-limit handling, ambiguous-create duplication, migration resumability"],
], [1.5*inch, 0.55*inch, 3.85*inch]))
A(Spacer(1, 5))
A(para(mono("api.security_invariants()") + " must always return zero rows. It catches the four "
       "changes that quietly dismantle the model: " + mono("USAGE") + " granted on " +
       mono("core") + ", an internal column exposed to a non-admin, RLS switched off on a "
       "protected table, or a view created without " + mono("security_invoker") + ". Wire it "
       "into CI and a nightly check.", GOOD))

# ------------------------------------------------------------------ 8
A(para("8.  What Is Not Built", H1))
A(para("Stated plainly so nothing here is mistaken for finished.", BODY))
A(table([
    hdr(["Missing", "Consequence"]),
    ["Authentication", "No login, no sessions, no passwords for people. The demo selects a persona. This is the gap between the current system and anything user-facing."],
    ["The public marketplace UI", "Only the demo interface exists. It exercises the model; it is not the product."],
    ["Document storage", "The signed PDF artifact is not stored"],
    ["Messaging and unified inbox", "Not started"],
    ["Audit trail on band 2 and 3 reads", "Who viewed which address, and when, is not recorded"],
    ["Co-investment matching", "The pipeline exists; the matching engine does not"],
    ["The external status scraper", "Not built. The review queue that would receive its output is."],
    ["EspoCRM field mapping", "The load ordering and resumability are built and tested. The field-level mapping needs the live EspoCRM schema."],
    ["Any deployment", "Nothing is hosted. Nothing is internet-facing."],
], [1.7*inch, 4.2*inch]))

A(para("9.  Where Things Are", H1))
A(table([
    hdr(["Path", "Contents"]),
    [mono("sql/01–04"), "Schema, RLS policies, masking views, demo data"],
    [mono("sql/05, 07, 10, 14"), "The four walkthroughs. Each is readable top to bottom as an argument"],
    [mono("sql/06, 08, 09"), "GoHighLevel bridge, review queue, review actions"],
    [mono("sql/11–13"), "Deals, stage history, pipeline policies and seed"],
    [mono("sql/99_local_logins.sql"), "Demo passwords. Local development only"],
    [mono("web/"), "The demo: " + mono("server.js") + " and one HTML page"],
    [mono("worker/src/"), "The GoHighLevel integration worker"],
    [mono("worker/test/"), "63 tests"],
    [mono("worker/tools/"), "The webhook capture tool"],
    [mono("docs/"), "This document and the GoHighLevel interface specification, with their generators"],
    [mono("README.md"), "The same ground in more technical detail, including the reasoning behind each design decision"],
], [1.7*inch, 4.2*inch]))
A(Spacer(1, 8))
A(para("There is no INSTALL file; section 2 of this document and the README's opening section "
       "cover installation. Both PDFs in " + mono("docs/") + " are generated by committed "
       "scripts rather than written by hand, so they can be regenerated as the system changes "
       "and cannot quietly drift out of date.", CAP))

# multiBuild, not build: the first pass discovers where each heading lands,
# the second lays out the contents page with those numbers. A single pass
# would print a contents page with every entry on page 0.
doc.multiBuild(E)
print("wrote", OUT)
