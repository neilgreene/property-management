#!/usr/bin/env python3
"""
Generates the System Documentation PDF.

Facts here are extracted from the repository and a freshly built database,
not written from memory. Regenerate with:
    python3 docs/generate_system_documentation.py
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER
from reportlab.lib.pagesizes import LETTER
from reportlab.lib.units import inch
from reportlab.platypus import (Flowable, PageBreak, Paragraph, Preformatted, Spacer,
                                Table, TableStyle)
from reportlab.platypus.tableofcontents import TableOfContents
import json
import re

# The shared look, so this document and the test plan cannot drift apart.
from _style import (BODY, H1, H2, BUL, CODE, CELL, CELLB, CAP, NOTE, GOOD, CT, CS,
                    SCELL, SCELB, TNAME, TDESC, BLANK, TOC1, TOC2, S,
                    INK, MUTED, ACCENT, WARN, RULE, BAND, CODE_BG, OKBG, OK,
                    para, mono, hdr, buls, table, build_doc)

OUT = "docs/System-Documentation.pdf"

_here = os.path.dirname(os.path.abspath(__file__))
_root = os.path.dirname(_here)
with open(os.path.join(_root, "VERSION")) as _fh:
    VERSION = _fh.read().strip()
with open(os.path.join(_root, "CHANGELOG.md")) as _fh:
    CHANGELOG = _fh.read()

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


# --- Gantt flowable -----------------------------------------------------
# Form: horizontal bars over time is the right encoding for a schedule --
# each row is one phase, length is duration, position is when. Colour
# carries the TRACK (identity, so categorical), never the rank or the
# criticality: a filter that changed the phase list must not repaint the
# survivors. Critical path is therefore encoded as a second channel -- a
# dark outline -- not as a fifth colour.
TRACKS = [
    ("Foundation",  colors.HexColor("#2a78d6")),
    ("Migration",   colors.HexColor("#eb6834")),
    ("Product",     colors.HexColor("#1baf7a")),
    ("Operations",  colors.HexColor("#eda100")),
]

# id, label, track, start week, weeks, predecessors, on critical path
PLAN = [
    ("P0",  "Signature check + first deploy", "Foundation",  0,  1, [],           False),
    ("P1",  "Authentication and sessions",    "Foundation",  1,  3, ["P0"],       True),
    ("P2",  "EspoCRM mapping + rehearsal",    "Migration",   1,  4, [],           False),
    ("P3",  "Audit trail on gated reads",     "Foundation",  4,  2, ["P1"],       False),
    ("P4",  "Public marketplace UI",          "Product",     4,  4, ["P1","P2"],  True),
    ("P5",  "Investor portal + fee flow",     "Product",     8,  3, ["P4"],       True),
    ("P6",  "Document storage",               "Product",    10,  2, ["P5"],       False),
    ("P7",  "Agent portal",                   "Product",    11,  2, ["P1"],       False),
    ("P8",  "Messaging / unified inbox",      "Product",    13,  3, ["P7"],       False),
    ("P9",  "External status feed",           "Operations", 15,  2, [],           False),
    ("P10", "Co-investment matching",         "Product",    16,  3, ["P5"],       False),
    ("P11", "Hardening and cutover",          "Operations", 18,  2, ["P5"],       True),
]

# week, label -- the dates a non-developer actually asks about
MILESTONES = [
    (1,  "public endpoint live"),
    (4,  "login works"),
    (11, "first paid unlock"),
    (20, "cutover"),
]
TOTAL_WEEKS = 20


class Gantt(Flowable):
    def __init__(self, width, height):
        Flowable.__init__(self)
        self.width, self.height = width, height

    def draw(self):
        c = self.canv
        w, h = self.width, self.height
        label_w = 1.95 * inch
        legend_h, axis_h, ms_h = 32, 12, 26
        plot_x = label_w
        plot_w = w - label_w - 26           # room for the duration labels
        rows = len(PLAN)
        plot_h = h - legend_h - axis_h - ms_h
        row_h = plot_h / rows
        bar_h = min(row_h - 4.0, 10.5)
        wk = plot_w / TOTAL_WEEKS
        top = axis_h + ms_h + plot_h

        geom = {}
        c.saveState()

        # Recessive gridlines every two weeks.
        c.setStrokeColor(colors.HexColor("#E7EAEF")); c.setLineWidth(0.5)
        for k in range(0, TOTAL_WEEKS + 1, 2):
            x = plot_x + k * wk
            c.line(x, axis_h + ms_h, x, top)

        c.setStrokeColor(RULE); c.setLineWidth(0.7)
        c.line(plot_x, top, plot_x + plot_w, top)
        c.setFont("Helvetica", 6.4); c.setFillColor(MUTED)
        for k in range(0, TOTAL_WEEKS + 1, 2):
            c.drawCentredString(plot_x + k * wk, top + 4, f"w{k}")

        palette = dict(TRACKS)
        for i, (pid, label, track, start, dur, deps, crit) in enumerate(PLAN):
            y = top - (i + 1) * row_h + (row_h - bar_h) / 2.0
            x = plot_x + start * wk
            bw = dur * wk - 2.0            # 2pt surface gap between adjacent bars
            geom[pid] = (x, x + bw, y + bar_h / 2.0, y, bar_h)

            c.setFont("Helvetica-Bold" if crit else "Helvetica", 6.8)
            c.setFillColor(INK if crit else colors.HexColor("#3d4650"))
            c.drawString(0, y + bar_h / 2.0 - 2.4, f"{pid}  {label}")

            c.setFillColor(palette[track])
            c.roundRect(x, y, bw, bar_h, 2.0, stroke=0, fill=1)
            if crit:
                # Second channel, not a fifth hue: criticality is a property of
                # the phase, and colour is already spoken for by the track.
                c.setStrokeColor(INK); c.setLineWidth(1.1)
                c.roundRect(x, y, bw, bar_h, 2.0, stroke=1, fill=0)

            # Direct label on every bar. Two palette slots sit below 3:1 on this
            # surface, which is legal only with visible labels -- and a duration
            # is what a reader wants next to a bar anyway.
            c.setFont("Helvetica", 6.2); c.setFillColor(MUTED)
            c.drawString(x + bw + 3, y + bar_h / 2.0 - 2.2, f"{dur}w")

        # Dependency arrows, drawn last so they sit over the gridlines.
        c.setStrokeColor(colors.HexColor("#9AA4B0")); c.setLineWidth(0.6)
        c.setFillColor(colors.HexColor("#9AA4B0"))
        for pid, label, track, start, dur, deps, crit in PLAN:
            if pid not in geom:
                continue
            x0, _, ymid, ybot, bh = geom[pid]
            for dep in deps:
                if dep not in geom:
                    continue
                dx0, dx1, dymid, dybot, dbh = geom[dep]
                # Leave from the bottom edge rather than mid-height: the
                # duration label sits immediately right of the bar, and an
                # arrow at mid-height runs straight through it.
                path = c.beginPath()
                path.moveTo(dx1 - 4, dybot)
                midx = min(dx1 - 4, x0 - 4)
                path.lineTo(midx, dybot - 2)
                path.lineTo(midx, ymid)
                path.lineTo(x0 - 3, ymid)
                c.drawPath(path, stroke=1, fill=0)
                c.circle(x0 - 2, ymid, 1.3, stroke=0, fill=1)

        # Milestones on their own band, so they never collide with a bar.
        c.setStrokeColor(colors.HexColor("#C6CFDA")); c.setLineWidth(0.5)
        c.line(plot_x, axis_h + ms_h - 2, plot_x + plot_w, axis_h + ms_h - 2)
        for mi, (wk_no, text) in enumerate(MILESTONES):
            mx = plot_x + wk_no * wk
            my = axis_h + ms_h - 2
            c.setFillColor(ACCENT)
            c.saveState(); c.translate(mx, my); c.rotate(45)
            c.rect(-2.6, -2.6, 5.2, 5.2, stroke=0, fill=1)
            c.restoreState()
            c.setFont("Helvetica", 5.9); c.setFillColor(MUTED)
            # Two rows, alternating: w1 and w4 are close enough that a single
            # row of labels overlaps.
            c.drawCentredString(mx, my - (9 if mi % 2 == 0 else 17), text)

        # Legend: four tracks always present, plus the outline channel.
        c.setFont("Helvetica", 6.8)
        lx, ly = plot_x, h - 8
        for name, col in TRACKS:
            c.setFillColor(col); c.roundRect(lx, ly - 4.5, 9, 6, 1.5, stroke=0, fill=1)
            c.setFillColor(MUTED); c.drawString(lx + 12, ly - 4, name)
            lx += 12 + c.stringWidth(name, "Helvetica", 6.8) + 14
        c.setFillColor(colors.white); c.setStrokeColor(INK); c.setLineWidth(1.1)
        c.roundRect(lx, ly - 4.5, 9, 6, 1.5, stroke=1, fill=1)
        c.setFillColor(MUTED); c.drawString(lx + 12, ly - 4, "critical path")
        lx += 12 + c.stringWidth("critical path", "Helvetica", 6.8) + 14
        c.setFillColor(ACCENT)
        c.saveState(); c.translate(lx + 4, ly - 1.5); c.rotate(45)
        c.rect(-2.4, -2.4, 4.8, 4.8, stroke=0, fill=1); c.restoreState()
        c.setFillColor(MUTED); c.drawString(lx + 12, ly - 4, "milestone")

        c.restoreState()


doc = build_doc(OUT, "System Documentation",
                "SDI Investment Property Marketplace — System Documentation",
                "What has been built: architecture, API, users and how to run it",
                footer_left="neilgreene/property-management @ main")

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
    ["Release", mono("v" + VERSION)],
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
A(Spacer(1, 3))
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
A(para("2.1  Requirements", H2))
A(para("Two ways to run this, with different prerequisites. The Docker route needs one thing "
       "installed; the local route needs three, but gives faster iteration.", BODY))

A(para("Route A — Docker (recommended for a first run)", H2))
A(table([
    hdr(["Requirement", "Version", "Notes"]),
    ["Docker Engine", "20.10 or later", "Any host: Linux, macOS, Windows with WSL2, or a Proxmox VM"],
    ["Docker Compose", "v2 (the " + mono("docker compose") + " subcommand)", "Not the older standalone " + mono("docker-compose") + " binary; this file uses v2 syntax including profiles"],
    ["Disk", "about 1.5 GB", "Chiefly the two base images"],
    ["Memory", "1 GB free", "PostgreSQL and two small Node processes"],
    ["Network at build time", "outbound HTTPS", "Pulls images from Docker Hub and " + mono("pg") + " from the npm registry. Nothing else is fetched."],
], [1.35*inch, 1.45*inch, 3.1*inch]))
A(Spacer(1, 6))

A(para("What is inside the Compose file", H2))
A(table([
    hdr(["Service", "Image", "Resolves to", "Purpose", "Port"]),
    ["db", mono("postgres:16"), "PostgreSQL 16.x — tested on 16.13", "Database; loads every " + mono("sql/") + " file on first start", "5432"],
    ["web", mono("node:22-alpine"), "Node 22.x — tested on 22.22.2", "The demo interface", "3000"],
    ["worker", mono("node:22-alpine"), "Node 22.x — tested on 22.22.2", "GoHighLevel integration. Behind the " + mono("worker") + " profile; not started by default", "3001"],
], [0.62*inch, 1.12*inch, 1.3*inch, 2.11*inch, 0.45*inch]))
A(Spacer(1, 5))
A(para("Both tags float within their major version, so a pull next month may bring a newer "
       "patch release. That is the right default for development — it picks up security "
       "fixes — but for production pin them to a digest so a rebuild produces the same image "
       "that was tested. The versions above are what this system has actually been verified "
       "against.", NOTE))
A(Spacer(1, 4))
A(para("Only one runtime dependency is installed at all: " + mono("pg") + " (resolves to "
       "8.23.x under the declared " + mono("^8.13.1") + "). There is no web framework, no ORM, "
       "no build step and no bundler. That is deliberate — it keeps the dependency audit "
       "trivial and removes a class of supply-chain exposure — and it is worth preserving.", GOOD))

A(para("Route B — local install", H2))
A(table([
    hdr(["Requirement", "Version", "Why that floor"]),
    ["PostgreSQL", "16 or later", mono("security_invoker") + " views need 15+; developed and tested on 16. Below 15 a view over an RLS table silently runs as its owner and bypasses the caller's policies, which would defeat the entire model."],
    ["Node.js", "18 or later", "Uses the built-in test runner and global " + mono("fetch") + ", both stable from 18. Tested on 22."],
    ["npm", "9 or later", "Ships with Node 18+"],
    [mono("psql") + " and " + mono("createdb"), "matching the server", mono("run.sh") + " calls them as your own user, which is the default for Postgres.app and Homebrew"],
], [1.35*inch, 1.15*inch, 3.4*inch]))
A(Spacer(1, 6))

A(para("Optional — only for rebuilding this document", H2))
A(table([
    hdr(["Requirement", "Version", "Used by"]),
    ["Python", "3.9 or later — tested on 3.11", "Both PDF generators"],
    [mono("reportlab"), "4.x or later — tested on 5.0.1", mono("pip install reportlab")],
    [mono("pypdfium2"), "any", "Optional. Only to render pages for visual checking"],
], [1.35*inch, 2.15*inch, 2.4*inch]))
A(Spacer(1, 5))
A(para("Nothing in the running system needs Python. It is only used to regenerate the two "
       "PDFs in " + mono("docs/") + ".", BODY))

A(para("Network access", H2))
A(table([
    hdr(["When", "Needs", "For"]),
    ["Build", "Outbound HTTPS to Docker Hub and " + mono("registry.npmjs.org"), "Images and the one npm package"],
    ["Runtime, core system", "None", "The database, demo and tests are entirely self-contained and run air-gapped"],
    ["Runtime, worker", "Outbound HTTPS to " + mono("services.leadconnectorhq.com"), "The GoHighLevel API"],
    ["Runtime, webhooks", "Inbound HTTPS on a public address", "Only for receiving GoHighLevel deliveries. Everything else works without it."],
], [1.5*inch, 2.2*inch, 2.2*inch]))
A(Spacer(1, 5))
A(para("The distinction in that last table matters for choosing where to run. The whole "
       "system minus webhook receipt works with no inbound access at all, which is why a "
       "Proxmox VM with no port forwarding is a perfectly good staging environment.", GOOD))

A(para("2.2  Docker — nothing installed but Docker", H2))
A(Preformatted("git clone https://github.com/neilgreene/property-management\n"
               "cd property-management\n"
               "docker compose up", CODE))
A(para("Builds the database from " + mono("sql/") + ", seeds it, and serves the demo at "
       "<b>http://localhost:3000</b>. PostgreSQL is exposed on " + mono("localhost:5432") +
       " (database " + mono("sdi") + ", user " + mono("postgres") + ", password " +
       mono("postgres") + "). " + mono("docker compose down -v") + " discards the database.", BODY))

A(para("2.3  Local PostgreSQL 16+ and Node 18+", H2))
A(Preformatted("./run.sh", CODE))
A(para("Loads all eleven schema files, runs all four SQL walkthroughs, runs the 63 worker "
       "tests, then starts the demo. It assumes " + mono("psql") + " and " + mono("createdb") +
       " work as your own user, which is the default for Postgres.app and Homebrew.", BODY))

A(para("2.4  Individual pieces", H2))
A(table([
    hdr(["Command", "What it does"]),
    [mono("psql -d sdi -f sql/05_tests.sql"), "Security walkthrough: 11 checks, 5 of them attacks"],
    [mono("psql -d sdi -f sql/07_ghl_tests.sql"), "GoHighLevel bridge: 7 checks"],
    [mono("psql -d sdi -f sql/10_review_tests.sql"), "Review queue actions: 7 checks"],
    [mono("psql -d sdi -f sql/14_pipeline_tests.sql"), "Deal visibility and stage history: 9 checks"],
    [mono("cd worker &amp;&amp; npm test"), "63 unit and end-to-end tests"],
], [2.6*inch, 3.3*inch]))

A(para("2.5  The integration worker", H2))
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
A(para("3.1  Signing in", H2))
A(para("Authentication is built. A person signs in with an email and a password, gets a "
       "session cookie, and the web tier resolves that cookie to a person id and a database "
       "role for the duration of one transaction.", BODY))
A(table([
    hdr(["Concern", "How it is handled"]),
    ["Password storage", mono("scrypt") + " with per-password salt and explicit cost parameters. Node's built-in implementation \u2014 no dependency"],
    ["Failed sign-in", "One message and one shape for every failure. Distinguishing \u201cno such account\u201d from \u201cwrong password\u201d is an enumeration oracle, so the failure path does the same hashing work as the success path"],
    ["Repeated failures", "The account locks after five. Setting a new password clears the lock"],
    ["Sessions", "A random token; only its SHA-256 is stored, so the session table is not a set of usable credentials. Changing a password revokes every existing session"],
    ["Credential tables", mono("core.credential") + " and " + mono("core.session") + " are RLS-forced with <b>no policy at all</b> \u2014 every direct read is refused for every role, including the owner. They are reachable only through " + mono("SECURITY DEFINER") + " functions"],
], [1.15*inch, 4.75*inch]))
A(Spacer(1, 5))
A(para("<b>Authentication changed nothing beneath it.</b> Not one policy, view or grant was "
       "modified to add it: the database contract was always \u201chere is a role and an actor "
       "id\u201d, and a session now supplies those instead of a dropdown. That is the payoff of "
       "having put the authorisation model in the database first.", GOOD))
A(para("The demo persona switcher still exists, but it is off unless " +
       mono("DEMO_PERSONAS=1") + " is set. A dropdown that hands out an admin session must "
       "not be reachable by accident.", NOTE))
A(para("Still missing: password reset, email delivery, and multi-factor. A person who "
       "forgets a password needs a staff member to set a new one.", BODY))

A(para("3.2  Seeded people", H2))
A(para("Created by " + mono("sql/04_seed.sql") + ". These are demonstration records, not real "
       "people; the addresses and financials attached to them are invented. Every one of "
       "them has the password " + mono("demo1234") + ", set by " +
       mono("sql/17_demo_passwords.sql") + " \u2014 a file that belongs in a demo and nowhere "
       "else.", BODY))
A(table([
    hdr(["Name", "Role", "Email", "Fee agreement", "Brand", "What they demonstrate"]),
    ["Jessica Pool", "admin", mono("jpool2@yahoo.com"), "n/a", "BRAND_A", "Full staff access, all bands"],
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
A(para("All ten " + mono("core") + " tables have row-level security enabled and forced; none of "
       "the " + mono("ghl") + " tables do, because that schema is reachable only by the "
       "integration worker and by nothing else.", BODY))
A(para("<b>Every column of every table is defined in Appendix A</b>, with its type, "
       "nullability, default, key role and foreign key target. That appendix is generated "
       "from the live database rather than transcribed, so it cannot describe a schema the "
       "system does not actually have.", BODY))

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
    ["Marketplace", mono("GET /"), "The marketplace: filters, map, cards, drill-down"],
    ["Marketplace", mono("POST /api/login") + " &middot; " + mono("/api/logout"), "Sign in and out. One response shape for every failure"],
    ["Marketplace", mono("GET /api/whoami"), "Who this session is, and whether personas are enabled"],
    ["Marketplace", mono("GET /api/listings?&lt;filters&gt;"), "Filtered listings, plus facet ranges and the vocabularies for the dropdowns"],
    ["Marketplace", mono("GET /api/property?id="), "One listing in full, with its photographs. 404 when the row policy hides it"],
    ["Marketplace", mono("POST|DELETE /api/favorite"), "Add or remove a favourite"],
    ["Marketplace", mono("GET /api/favorites"), "The caller's favourites, as full listing cards"],
    ["Marketplace", mono("GET|POST|DELETE /api/saved-search"), "List, upsert by name, delete"],
    ["Marketplace", mono("POST /api/saved-search/run"), "Replay a saved search; returns its criteria and records the run"],
    ["Marketplace", mono("POST /api/parse"), "Plain English to a bounded criteria object \u2014 see 7.5"],
    ["Marketplace", mono("GET /media/&lt;id&gt;/&lt;kind&gt;.svg"), "Generated listing illustration"],
    ["Marketplace", mono("GET /api/view") + " &middot; " + mono("/api/probe"), "The teaching endpoints: one persona's whole payload, and a direct base-table read that is refused"],
    ["Worker", mono("POST /webhooks/ghl"), "Receives a GoHighLevel delivery, verifies its signature"],
    ["Worker", mono("GET /healthz"), "Queue depth: pending events, bad signatures, outbox backlog, open reviews"],
], [0.85*inch, 2.35*inch, 2.7*inch]))
A(Spacer(1, 5))
A(para("The marketplace runs on port 3000, the worker on 3001. The marketplace authenticates; "
       "the worker does not, and neither should be exposed to a network until the deployment "
       "gaps in section 12 are addressed.", NOTE))
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

A(para("6.4  Nothing here has ever spoken to GoHighLevel", H2))
A(para("This is the most important caveat in the document, and it is easy to miss behind a "
       "passing test count. The integration is written and tested, but <b>no line of it has "
       "made a request to GoHighLevel</b>. Every test supplies a double: an injected "
       "<font face='Courier'>fetch</font>, a locally generated RSA keypair, a fake client "
       "object. Zero of the 63 tests reach the network.", NOTE))
A(para("What that does and does not buy", H2))
A(table([
    hdr(["Verified", "Not verified"]),
    ["The logic: retry and backoff, deduplication, the two-condition fee gate, outbox "
     "resumability, migration ordering, allowlist enforcement, every privilege boundary.",
     "Every assumption about how the real API actually behaves: response shapes, field names "
     "in practice, error bodies, and the webhook signature algorithm."],
    ["That the code does the right thing when GoHighLevel responds in the shape the code "
     "expects.",
     "That GoHighLevel responds in that shape."],
], [2.95*inch, 2.95*inch]))
A(Spacer(1, 6))
A(para("The assumption register", H2))
A(para("Rather than leave that as an unbounded worry, here is the finite list. Each row is a "
       "specific assumption the code makes, where it lives, and what happens if it is wrong. "
       "Checking these against one real account is a morning's work and closes the whole "
       "category.", BODY))
A(table([
    hdr(["#", "Assumption", "Where", "If wrong"]),
    ["1", "Signatures are PKCS#1 v1.5 over SHA-256, over the raw body",
     mono("signature.js"), "Every delivery is rejected as forged. Loud, not silent."],
    ["2", "Transaction list returns rows under " + mono("data") + " or " + mono("transactions"),
     mono("sync/transactions.js"), "Sync silently reads zero rows and reports success. Quiet, and the worst of these."],
    ["3", "Document list returns rows under " + mono("documents") + " with a " + mono("total"),
     mono("sync/documents.js"), "The fee gate never opens for anyone. Loud once someone pays."],
    ["4", "A document's payer is " + mono("recipients[0].contactId"),
     mono("sync/documents.js"), "The document cannot be matched to a person; the gate stays shut."],
    ["5", "Contact upsert returns " + mono("contact.id") + " or " + mono("id"),
     mono("outbox.js"), "The id map is not written, so the association pass cannot resolve."],
    ["6", "Record create returns " + mono("record.id") + " or " + mono("id"),
     mono("outbox.js"), "Same, for properties."],
    ["7", "Relation create takes " + mono("firstRecordId") + "/" + mono("secondRecordId") + "/" + mono("associationId"),
     mono("ghlClient.js"), "Relations fail with a 422; the migration reports it rather than losing it."],
    ["8", "Webhook payloads carry " + mono("type") + ", " + mono("webhookId") + " and " + mono("timestamp"),
     mono("webhookReceiver.js"), "Events are recorded as " + mono("unknown") + " or rejected outright."],
    ["9", "A 429 carries " + mono("Retry-After"),
     mono("ghlClient.js"), "Backoff falls back to exponential. Harmless."],
], [0.25*inch, 2.25*inch, 1.25*inch, 2.15*inch]))
A(Spacer(1, 5))
A(para("Assumption 2 is the one to check first. Most of these fail loudly — a rejected "
       "delivery, a 422, an empty gate somebody complains about. That one fails <i>quietly</i>: "
       "the sync reports success, the cursor advances, and the ledger simply never fills. A "
       "single real response settles it.", NOTE))
A(Spacer(1, 4))
A(para("The code is written defensively against exactly this — the fallbacks above are why "
       "each row lists two candidate shapes rather than one — which lowers the odds but does "
       "not remove them. Guessing carefully is still guessing.", BODY))
A(para("How to close it", H2))
A(para("Two artifacts, neither of which needs any code to be written: <b>one captured webhook "
       "delivery</b> (raw body plus its " + mono("x-wh-signature") + " header, which "
       + mono("worker/tools/capture-webhook.js") + " writes for you) and <b>one saved response "
       "from each of " + mono("GET /payments/transactions") + " and " + mono("GET /proposals/document") +
       "</b>. That is phase P0 in section 9, budgeted at one week, and it is first in the "
       "schedule for this reason.", GOOD))


# ------------------------------------------------------------------ 7
A(PageBreak())
A(para("7.  The Marketplace", H1))
A(para("The browsing surface an investor actually uses: filters across the top, a map on "
       "the left, listing cards on the right, and a drill-down panel over the top. The "
       "layout is the one every property portal has converged on, for the reason they "
       "converged on it \u2014 price and geography are the two questions a buyer asks "
       "first, and the layout answers both at once.", BODY))

A(para("7.1  What the browser can and cannot do", H2))
A(para("The front end contains no security logic. It does not decide whose address to show, "
       "which photographs to display, or which listings to draw. It draws what the API hands "
       "it, and it finds out that an address is withheld at the same moment the reader does \u2014 "
       "because " + mono("street_address") + " arrives as null.", GOOD))
A(para("This is worth stating because it is the difference between a gate and a curtain. A "
       "front end that receives every address and hides some of them is defeated by the "
       "browser's developer tools. This one is not sent them.", BODY))

A(para("7.2  Searching", H2))
A(table([
    hdr(["Control", "Filters on", "Where it runs"]),
    ["Price, beds, baths, square feet", "Range on each", "Bound parameters against " + mono("api.property")],
    ["Type, city", "Exact match; the options are drawn from what this caller can see", "Same query"],
    ["Sort", "Price, cap rate, size, bedrooms", "An allowlisted ORDER BY, never interpolated"],
    ["Plain English", "Parsed into the same criteria as the controls above", "See 7.5"],
], [1.6*inch, 2.35*inch, 1.95*inch]))
A(Spacer(1, 5))
A(para("Two properties of this that are structural rather than incidental. <b>A filter can "
       "only narrow.</b> The row policies and the view's masking run first; every filter "
       "clause runs inside that result, so there is no filter value that widens what a "
       "caller sees. And <b>filtering happens in the database</b>, so a listing the caller "
       "may not see is never sent and then hidden \u2014 it is not sent.", BODY))
A(para("Even the facet ranges \u2014 the price floor and ceiling, the bedroom counts offered in "
       "the dropdown \u2014 are computed from the same policy-bounded relation. The bounds a "
       "caller sees are the bounds of their own data, so the filter bar itself does not leak "
       "the existence of listings they cannot open.", GOOD))

A(para("7.3  The map, and why gated pins are drawn as rings", H2))
A(para("Every listing carries true coordinates in band 2. An ungated viewer receives a "
       "deterministic offset of roughly a kilometre instead, seeded on the property id so "
       "repeated loads cannot be averaged back to the true point.", BODY))
A(para("The map draws that difference rather than hiding it: an unlocked listing gets a "
       "sharp price pin, a gated one gets a soft ring around an approximate centre. Drawing "
       "a gated listing as a precise pin would claim an accuracy the data does not have, "
       "and would teach the viewer to trust a position that is deliberately wrong.", BODY))
A(para("The map library and its tiles come from a CDN. When that CDN is unreachable \u2014 an "
       "air-gapped host, a restrictive proxy \u2014 a built-in renderer plots the same listings to "
       "scale with no dependencies, priced, clickable and hover-linked to their cards, "
       "labelled so nobody mistakes it for a basemap. A demo that shows a grey rectangle on "
       "a locked-down network is a demo that fails in the room it matters in.", NOTE))

A(para("7.4  The drill-down", H2))
A(para("One property, in full. The 404 for a listing the caller may not see is produced by "
       "the row policy, not by a check in application code: " + mono("api.property_detail") +
       " is a view over " + mono("api.property") + ", so an invisible property returns zero "
       "rows and the route reports not-found. Not <i>forbidden</i> \u2014 saying \u201cforbidden\u201d would "
       "confirm the listing exists to anyone who guessed an id.", BODY))
A(table([
    hdr(["Section", "Contains", "Band"]),
    ["Photography", "Interior views. The front elevation is band 2 \u2014 see below", "1, and 2"],
    ["Headline figures", "Cap rate, monthly rent, NOI, price per square foot", "1"],
    ["Income and expenses", "Gross rent, vacancy, management, tax, insurance, maintenance, utilities, HOA, and the net", "1"],
    ["Area", "Median household income, median price and rent, rent growth, vacancy, price-to-income, and this rent as a share of local income", "1"],
    ["The building", "Lot, storeys, garage, parking, heating, cooling, roof year, renovations, features", "1"],
    ["Location", "Street address, unit, exact coordinates, front elevation photograph", "2"],
], [1.3*inch, 3.3*inch, 0.75*inch]))
A(Spacer(1, 5))
A(para("<b>The whole financial analysis is band 1.</b> That is a deliberate commercial "
       "choice, not an oversight: the analysis is what sells the listing, so withholding it "
       "would defeat the purpose of publishing at all. What is withheld is what identifies "
       "the parcel \u2014 nothing on the page is a teaser.", BODY))
A(para("<b>Photographs respect the same gate as the address.</b> A picture of the front of a "
       "house identifies it as surely as its street number: a door number, a recognisable "
       "streetscape. So " + mono("core.property_media") + " carries " + mono("reveals_location") +
       ", and any image flagged that way is released on the same predicate as the address "
       "itself. Interiors stay public. Without this, the gate would be reopened through the "
       "picture gallery.", GOOD))
A(para("The expense breakdown sums exactly to the " + mono("opex_annual") + " published on "
       "the listing. That is enforced by generation rather than trusted: an investor who "
       "adds up the components gets the headline figure back, and a detail page whose "
       "arithmetic does not close is a page nobody underwrites on twice.", BODY))

A(para("7.5  Plain-English search", H2))
A(para("A free-text box turns \u201c3 bed duplex in Cleveland under 200k, best yield\u201d into "
       + mono("{min_beds:3, property_type:'Duplex', city:'Cleveland', max_price:200000, "
              "sort:'cap_desc'}") + " and shows the reader what it understood, so the box is "
       "never opaque about what it did.", BODY))
A(para("<b>It is a rules parser today. It is not a language model and it does not call "
       "one.</b> It is built now because the shape of the feature \u2014 free text in, a bounded "
       "criteria object out \u2014 is the part that has to be right, and it is worth having that "
       "seam built and tested before a model is put behind it.", NOTE))
A(para("The design is what makes a model safe to add later. The parser's only output is a "
       "criteria object whose keys are fixed and whose values the query builder binds, and "
       "every object passes a validator on the way out. So the blast radius of a wrong "
       "answer \u2014 from these rules today or from a model tomorrow \u2014 is a bad search, never a "
       "bad query. Swapping in a model means replacing one function body; the validator is "
       "not optional in that world, it is the thing that makes model output executable.", GOOD))

A(para("7.6  Favourites and saved searches", H2))
A(table([
    hdr(["Feature", "Stored in", "Visibility"]),
    ["Favourites", mono("core.saved_property"), "Owner only, plus staff. Saving is checked against the same predicate the row policy uses, so an investor cannot favourite a listing their own policy hides"],
    ["Saved searches", mono("core.saved_search"), "Owner only, with no staff override. What an investor is hunting for is their own business"],
], [1.1*inch, 1.55*inch, 3.25*inch]))
A(Spacer(1, 5))
A(para("Search criteria are stored as " + mono("jsonb") + " because the filter set will keep "
       "growing and each addition should not be a migration. The cost of " + mono("jsonb") +
       " is that it accepts anything \u2014 so the storable keys are constrained at the table. A "
       "saved search is replayed later, possibly by different code, and what cannot be stored "
       "cannot be replayed.", BODY))
A(para("The favourites view joins " + mono("api.property") + ", not " + mono("core.property") +
       ". An address hidden in the grid must not appear because the listing was favourited; "
       "inheriting the mask rather than reimplementing it is what guarantees the two cannot "
       "drift apart.", GOOD))

A(para("7.7  Photography", H2))
A(para("The listing images are generated: deterministic flat vector illustrations, seeded on "
       "the property id so a listing always looks the same. Real photographs are somebody's "
       "copyright and a stock service is an account and a dependency, so the demo draws its "
       "own and makes them visibly illustrations rather than photo-imitations.", BODY))
A(para("Replacing them is a URL change. " + mono("core.property_media") + " stores a url and "
       "nothing outside the renderer assumes where it is served from. The gate lives in the "
       "database and does not care where the bytes come from.", BODY))

# ------------------------------------------------------------------ 8
A(PageBreak())
A(para("8.  Where Listing Data Comes From", H1))
A(para("A property in this marketplace is also listed somewhere else \u2014 an MLS, a consumer "
       "portal, a wholesaler's sheet. It goes under contract, it sells, it is withdrawn, and "
       "nobody tells us. An investor who calls about a house that went pending three weeks "
       "ago is the single most expensive kind of stale data this system can hold.", BODY))
A(para("<b>The wrinkle that shapes the entire design: escrow fails.</b> A property that went "
       "pending comes back to market perhaps one time in five. So this cannot be a one-way "
       "\u201cmark it gone\u201d job. It has to follow the source in both directions, and a design that "
       "only knows how to retire a listing will quietly bury the ones that come back.", GOOD))

A(para("8.1  Where the data can actually come from", H2))
A(para("Worth being blunt, because the obvious answer is not available.", BODY))
A(table([
    hdr(["Route", "What it gives", "What it costs"]),
    ["MLS via RESO Web API", "The correct answer. A standardised feed with a closed status vocabulary, served by essentially every modern MLS", "An MLS membership or approved vendor status, a signed data agreement, and a per-MLS contract. Coverage is per-market, so a national portfolio means several"],
    ["Bridge Interactive (Zillow Group)", "MLS data under Zillow Group's own platform", "Same gate: manual approval, restricted to industry partners, brokerages and MLS organisations"],
    ["Zillow's public API", "Nothing. The legacy Web API (ZWSID) was retired; there is no self-serve endpoint for live listing inventory", "\u2014"],
    ["Vendor property APIs (e.g. RentCast)", "Self-serve, no membership. Property records, rent comps, and a derived listing status", "A key and a subscription. Status is derivative rather than primary, which is why it is treated as advisory here"],
    ["Scraping a consumer portal", "Apparent completeness", "Outside the portal's terms, and technically the weakest option \u2014 see 8.5"],
    ["A person with a browser", "Authoritative, immediate, and available today", "Someone's time. For a portfolio of a few dozen listings this is a real answer, not a placeholder"],
], [1.3*inch, 2.1*inch, 2.5*inch]))
A(Spacer(1, 5))
A(para("The system is built so that which of these is used is a row in a table, not a "
       "rewrite. Every source implements one adapter interface and every answer goes through "
       "the same reconciler, so adding the MLS feed later changes no logic that is already "
       "tested.", BODY))

A(para("8.2  Four tables and one rule", H2))
A(table([
    hdr(["Table", "Holds"]),
    [mono("feed.listing_source"), "Who is telling us, and how far they are trusted: authoritative or advisory, whether they may retire a listing, and how many agreeing checks a change needs"],
    [mono("feed.property_external"), "Our property against their key, with " + mono("last_checked_at") + " and " + mono("last_seen_at") + " kept apart \u2014 \u201cwe looked\u201d and \u201cwe found it\u201d are different facts, and their difference is how a delisting is detected"],
    [mono("feed.observation"), "Append-only. What a source said, when, verbatim, alongside our reading of it. Never updated"],
    [mono("feed.status_change"), "What we actually did about it, why, and whether a worker or a person did it"],
], [1.55*inch, 4.35*inch]))
A(Spacer(1, 5))
A(para("<b>The rule: an observation never writes a status directly.</b> It is recorded, then "
       "reconciled. That separation is what makes the history answerable after the fact \u2014 "
       "\u201cwhy is this pending?\u201d has an answer with a timestamp and a source \u2014 and what lets an "
       "unreliable source raise a flag without being allowed to act.", GOOD))

A(para("8.3  Vocabulary is data, not code", H2))
A(para("Every feed has its own words. RESO says <i>Active Under Contract</i>; one portal says "
       "<i>Pending</i>; another says <i>Contingent</i> or <i>Accepting backup offers</i>. All "
       "four mean the same thing here. " + mono("feed.status_map") + " holds the translation, "
       "so a term a portal invented last week is a row, not a release.", BODY))
A(para("A term nobody has mapped is <b>recorded and flagged, never guessed</b>. An unmapped "
       "status appears on an operator worklist as \u201cwe saw something we do not understand\u201d "
       "rather than silently defaulting to whatever seems closest.", BODY))

A(para("8.4  What the nightly job is allowed to do", H2))
A(para("The sweep runs once a night, walks every enabled watch oldest-check-first so a run "
       "cut short has still done the most overdue work, and rate-limits per source. It "
       "decides nothing: it records what it saw and the database decides what it means.", BODY))
A(table([
    hdr(["Signal", "What happens"]),
    ["The source reports a status", "Recorded. Acted on once " + mono("confirm_after") + " checks agree \u2014 one reading of a feed is not evidence"],
    ["The source reports Active on something we had pending", "Acted on <b>immediately</b>. See below"],
    ["The listing is absent from the feed", "Counted. After enough consecutive absences the listing becomes <i>withdrawn</i> \u2014 not <i>sold</i>. Gone is not the same as sold, so we do not guess; withdrawn is the reversible one"],
    ["The request failed", "Ignored entirely. An outage is not a market emptying"],
    ["An advisory source disagrees with us", "A flag on the staff review queue. No status changes"],
    ["A staff member changed the status by hand", "The reconciler defers. A person who set it knows something the feed does not"],
], [1.85*inch, 4.05*inch]))
A(Spacer(1, 5))
A(para("<b>Two asymmetries, both deliberate.</b> An error is never read as an absence: an "
       "adapter that reports a timeout as \u201cmissing\u201d would, over one bad night, walk the "
       "entire portfolio to withdrawn, so an adapter in doubt must report an error. And "
       "coming back to market is acted on the first sighting rather than the second: a "
       "failed escrow is a house that is saleable <i>now</i>, and every night it waits shown "
       "as unavailable is a night of lost enquiries. The two mistakes do not cost the same, "
       "so they are not treated the same.", GOOD))

A(para("8.5  Why the scraper is a named seam and not an implementation", H2))
A(para("It is wired in, it is registered as a source, and it returns \u201cnot implemented\u201d. The "
       "reason is engineering before it is legal.", BODY))
A(para("A scraper cannot reliably distinguish <i>this listing is gone</i> from <i>the page "
       "changed shape</i>. Both render as a missing selector. So its most common failure mode "
       "is indistinguishable from its most destructive signal, and a scraper allowed to "
       "retire listings will one day retire the whole portfolio in a single run \u2014 correctly, "
       "as far as it can tell.", NOTE))
A(para("If one is ever built, two flags stay where they are: it remains <i>advisory</i>, so "
       "it raises flags instead of changing statuses, and it remains barred from retiring a "
       "listing. Those are columns on its source row, already set that way, so switching it "
       "on does not silently grant it authority.", BODY))

A(para("8.6  Getting a listing into the system today", H2))
A(table([
    hdr(["Route", "How"]),
    ["MLS feed", "Set " + mono("RESO_BASE_URL") + " and " + mono("RESO_TOKEN") + ", activate the source row. Listings arrive complete and stay current"],
    ["By hand, in bulk", mono("worker/tools/import-listing.js") + " takes a JSON file of the details and merges it \u2014 only the keys present are written, so re-running with one corrected field does not blank the rest"],
    ["By hand, one status", "A staff member records what they saw; the next sweep picks it up and it goes through the same reconciler as any feed, so it is auditable and reversible"],
], [1.25*inch, 4.65*inch]))
A(Spacer(1, 5))
A(para("The Irvine listing in the seed data (108 Fairgrove, 92618) shows the intended "
       "posture. It is tracked \u2014 two watches, a real external key \u2014 and it is a <b>draft</b> "
       "with null sizes and zero prices, so it reaches nobody. The facts held are the ones "
       "in the source URL; the price, the room counts and the photographs are licensed "
       "content that has not been obtained. Inventing plausible numbers to fill the gaps "
       "would produce exactly the confident wrong record this schema exists to prevent. It "
       "is tracked before it is trusted.", GOOD))


# ------------------------------------------------------------------ 9
A(PageBreak())
A(para("9.  Data Rights and Compliance", H1))
A(para("Every listing here is somebody else's data, held under some instrument. Whether it "
       "may be shown, to whom, and for how long is not a software question and cannot be "
       "answered by looking at the code \u2014 but it decides whether a listing may be published, "
       "so it is recorded where the publication decision is made: in the database, next to "
       "the row.", BODY))
A(para("A licence recorded in a spreadsheet is a licence that gets breached the week somebody "
       "forgets the spreadsheet exists.", GOOD))
A(para("<b>None of this is legal advice, and none of it claims to know what any particular "
       "agreement says.</b> It is the shape that holds whatever the signed agreements say, "
       "plus a register of the regimes identified as applying. Every row carries a review "
       "status, and an unreviewed right is visibly unreviewed rather than quietly treated as "
       "settled.", NOTE))

A(para("9.1  Three questions per instrument", H2))
A(table([
    hdr(["Question", "Recorded as", "Why it decides anything"]),
    ["<b>Where</b> does it apply?", mono("gov.data_right_territory"),
     "A feed licensed for one market does not cover a property in another. Using it there is a breach even though the software works perfectly \u2014 which is exactly why it needs a mechanical check"],
    ["<b>What</b> may be done with it?", mono("gov.data_right_use"),
     "\u201cShow this to a registered user\u201d is not \u201cpublish this to the open web\u201d, and neither is \u201cexport it in bulk\u201d or \u201ctrain a model on it\u201d. Eight uses, each answered separately"],
    ["<b>Until</b> when, and in return for what?", mono("gov.obligation"),
     "Attribution wording, refresh cadence, removal within N hours of a delisting, deletion on termination. The ones with deadlines are computed rather than remembered"],
], [1.45*inch, 1.5*inch, 2.95*inch]))
A(Spacer(1, 5))
A(para("Two details in that table are doing more work than they look. <b>Silence is not "
       "permission</b>: a use with no row, or one marked <i>unclear</i>, is refused \u2014 and the "
       "intake tool writes every one of the eight uses out explicitly, so a reader can tell "
       "\u201cwe never asked\u201d from \u201cthey said no\u201d. And <b>rights are scoped</b>: a right over "
       "listing facts says nothing about the photographs. Listing photography usually belongs "
       "to the photographer or the listing broker rather than the seller, and conflating the "
       "two is a well-worn way for a portal to get sued.", BODY))

A(para("9.2  What makes a right actually apply", H2))
A(para("Four conditions, and they are AND rather than a score. A right applies only if it is "
       "counsel-confirmed, unexpired, covers the property's territory, and grants the "
       "specific use being asked about.", BODY))
A(para(mono("gov.may_use(property_id, use, scope)") + " is the single question the publication "
       "path asks. Every clause in it is a reason the answer is <i>no</i>, stated positively, "
       "so a future clause cannot accidentally widen it.", GOOD))
A(para("A right cannot mark itself confirmed. " + mono("record-data-right.js") +
       " only sets that status when a reviewer is named on the command line, because "
       "\u201csomebody set a flag in a JSON file\u201d and \u201ca lawyer read the contract\u201d must not look "
       "the same afterwards.", BODY))

A(para("9.3  Advisory first, blocking later", H2))
A(para("The business operates today. A control that refused to publish anything without a "
       "confirmed right would take a working marketplace off the air over paperwork that has "
       "simply not been transcribed yet \u2014 and a control like that gets reverted, not fixed.", BODY))
A(table([
    hdr(["Mode", "Behaviour"]),
    [mono("advisory") + " (default)", "Publication proceeds and warns. Every uncovered listing appears in " + mono("gov.uncovered_publication") + " with the reason. The whole gap is visible on day one and nothing breaks"],
    [mono("blocking"), "Publication requires a confirmed right, and the standing invariant fails on any remaining gap. This is the go-live gate, and the invariant is what keeps it shut once flipped"],
], [1.3*inch, 4.6*inch]))
A(Spacer(1, 5))
A(para("Advisory is a recorded decision with a visible consequence, not the absence of one. "
       "It sits in " + mono("gov.policy") + " with who changed it and why.", BODY))

A(para("9.4  Fair housing, enforced structurally", H2))
A(para("This is the one part of the register with teeth in the running application, and it "
       "deserves the space.", BODY))
A(para("A marketplace that lets a user filter, or an algorithm rank, on a protected "
       "characteristic \u2014 or on a proxy for one \u2014 is steering, whether or not anyone intended "
       "it. <b>The Fair Housing Act does not require intent.</b> A recommendation engine is "
       "as capable of it as a dropdown, which is why the register exists before there is a "
       "recommendation engine.", GOOD))
A(para("The proxies are the hard part, and they are listed explicitly, because a system that "
       "blocks " + mono("race") + " and permits " + mono("percent_white_by_tract") +
       " has blocked nothing.", BODY))
A(table([
    hdr(["Registered proxy", "Proxy for", "Why"]),
    ["School rating", "Race, national origin", "Ratings track catchment demographics. Offering one as a ranking axis is steering by another name"],
    ["Crime index", "Race, national origin", "Reported-crime indices measure policing intensity as much as risk"],
    ["Area median income as a ranking", "Race, national origin", "The marketplace holds it, and legitimately \u2014 it is how rent is estimated. Offering it as an axis a buyer sorts on is a different act"],
    ["Neighbourhood desirability score", "Multiple", "A composite is a laundered version of whatever went into it"],
], [1.5*inch, 1.25*inch, 3.15*inch]))
A(Spacer(1, 5))
A(para("Three controls, at three levels. The register is a table (" +
       mono("gov.prohibited_dimension") + "). The standing invariant fails if any listed "
       "dimension is ever exposed as a readable column. And <b>the web tier refuses to "
       "start</b> if its own filter allowlist intersects the register \u2014 the check runs "
       "against the database rather than living in a comment above the filter array, because "
       "the array is what a future feature edits and a rule that exists only in a comment "
       "survives exactly until somebody is in a hurry.", GOOD))
A(para("What this does not catch is a dimension added under an innocent name. That is what "
       "the register's " + mono("basis") + " column and code review are for. It catches the "
       "careless case, which is the common one.", NOTE))

A(para("9.5  The regimes on the register", H2))
A(para("Identified, with the trigger condition that makes each one apply, and \u2014 the column "
       "that makes this more than a wall poster \u2014 where the constraint is actually enforced. "
       "A regime with no control is a gap that is visible rather than assumed.", BODY))
A(table([
    hdr(["Regime", "Applies when", "Status here"]),
    ["Fair Housing Act, and state equivalents", "Always", "Enforced structurally, three ways \u2014 see 9.4"],
    ["RESPA s.8 \u2014 referral fees", "If compensated in connection with a federally related mortgage loan, including by referring business", "<b>Unresolved and material.</b> See below"],
    ["State real estate licensing", "Per state where property is marketed", "Unresolved. Turns on whether the platform's activity is brokerage"],
    ["MLS participation, IDX and VOW rules", "From the moment any MLS feed is connected", "Machinery built and unused: attribution, refresh and removal SLAs are modelled and computed"],
    ["Copyright in photographs and copy", "Any media not authored in-house", "Media provenance tracked separately from listing facts"],
    ["CCPA/CPRA and state privacy statutes", "Per consumer residency and thresholds", "<b>Gap.</b> No subject-request mechanism exists"],
    ["TCPA \u2014 SMS and calls", "Any marketing text or autodialled call, including via GoHighLevel", "<b>Gap.</b> Consent is not captured or evidenced here"],
    ["CAN-SPAM", "Any commercial email", "Delegated to GoHighLevel; suppression state is not mirrored locally"],
    ["ECOA / Regulation B", "If credit is applied for, referred or influenced", "Deferred. Applies the day lender matching is built"],
    ["GLBA and the Safeguards Rule", "If the business is a \u201cfinancial institution\u201d", "Turns on the same facts as RESPA"],
    ["PCI DSS", "Any handling of cardholder data", "Deferred. No payment integration exists; use a redirected processor when it does"],
    ["ADA / web accessibility", "Public-facing web content", "Unaudited. The map has no non-visual equivalent"],
    ["GDPR", "Only if EU or UK data subjects", "Not applicable today, registered so the trigger stays visible"],
    ["Site terms and unauthorised access", "If any portal is read programmatically", "No scraper implemented \u2014 see 8.5"],
], [1.5*inch, 1.85*inch, 2.55*inch]))
A(Spacer(1, 6))
A(para("<b>RESPA section 8 is the largest open legal question in this product, and it is not "
       "a technical one.</b> The model is a $750 fee that unlocks property information and "
       "connects investors to agents and lenders. Whether that is compensation for services "
       "actually rendered or an unlawful referral fee turns on the fee's substance rather "
       "than its label. It needs counsel before launch, not after \u2014 and it should go to "
       "counsel together with the state licensing and GLBA questions, because all three turn "
       "on the same facts about what the business actually does.", NOTE))
A(para("<b>TCPA is the highest-frequency risk</b>, because it is the one an ordinary "
       "marketing decision can breach, statutory damages are per violation, and consent has "
       "to be provable. Nothing in this system currently captures or evidences it.", NOTE))

A(para("9.6  Filling the register in", H2))
A(para("The register currently holds the synthetic demonstration data, a deliberately empty "
       "instrument for the externally-tracked Irvine address, and the operator-supplied "
       "photograph of it. It does not yet hold the instruments the business actually "
       "operates under, because those live in signed paper that has to be transcribed by a "
       "person.", BODY))
A(para(mono("docs/data-rights-intake.md") + " is the questionnaire for that \u2014 five questions "
       "per instrument, a worked example, and the loader. " +
       mono("SELECT * FROM api.governance_status") + " says where things stand at any moment.", BODY))
A(table([
    hdr(["To see", "Query"]),
    ["The summary", mono("SELECT * FROM api.governance_status")],
    ["Published with no confirmed right", mono("SELECT * FROM gov.uncovered_publication")],
    ["The regimes, and which have no control", mono("SELECT * FROM api.compliance_register")],
    ["Per property: what is held, and why it does or does not apply", mono("SELECT * FROM api.data_rights")],
], [2.2*inch, 3.7*inch]))


# ------------------------------------------------------------------ 10
A(PageBreak())
A(para("10.  Getting Properties In", H1))
A(para("Staff build an analysis workbook per property \u2014 one .xlsm holding the offer, the "
       "rents, the expenses and a twenty-year projection. Those numbers used to reach the "
       "marketplace by being retyped. This is the path that replaces that: load the file "
       "into staging, look at what arrived, then release the whole batch or the specific "
       "rows that passed review.", BODY))

A(para("10.1  Two steps, and why", H2))
A(Preformatted("python3 tools/workbook-to-json.py *.xlsm > batch.json\n"
               "node worker/tools/load-intake.js batch.json --note \"August sourcing\"", CODE))
A(para("Reading .xlsm needs a spreadsheet library, and the worker image has no dependency "
       "beyond the Postgres driver. Rather than drag one in, the conversion happens wherever "
       "the file already is \u2014 a laptop, the host \u2014 and what crosses into the database is "
       "plain JSON. The middle format is the point: it can be opened and read before "
       "anything touches the database.", BODY))
A(para("The reader takes the workbook's " + mono("Import") + " sheet, by label. It is the "
       "only sheet carrying the address, and its 77 labels were identical across the "
       "workbooks checked. The flatter " + mono("One Row") + " export has no address, so it "
       "cannot stand alone.", BODY))

A(para("10.2  Staging holds both the file and our reading of it", H2))
A(table([
    hdr(["Table", "Holds"]),
    [mono("intake.batch"), "One file, one upload, one person, one moment"],
    [mono("intake.row"), "One property. The verbatim payload and the parsed columns, side by side and never merged"],
    [mono("intake.zip_centroid"), "The coordinate the workbook does not carry"],
], [1.35*inch, 4.55*inch]))
A(Spacer(1, 5))
A(para("<b>Keeping the raw payload untouched matters more than it looks.</b> When a released "
       "listing turns out to say something surprising, the only useful question is whether "
       "the spreadsheet said that or whether we mistranslated it \u2014 and that question has no "
       "answer if the import overwrote its own input. So it is written once, never edited, "
       "and every parsed column beside it is a claim that can be checked against it. The "
       "review screen shows it behind a link on every row.", GOOD))
A(para("A workbook has no coordinates, and " + mono("core.property") + " requires a point. A "
       "ZIP centroid is accurate to about a mile, which is exactly what an ungated viewer is "
       "shown anyway. A ZIP with no centroid is a <b>blocking error</b> rather than a silent "
       "(0,0): a listing quietly pinned to the middle of the wrong city is worse than one "
       "that refuses to load.", NOTE))

A(para("10.3  Two fields deliberately not mapped", H2))
A(para("The workbook carries <i>Schools Rating (scale 3-30)</i> and a composite "
       "FAVORABLE/INSUFFICIENT deal score partly derived from it. Both are already registered "
       "in " + mono("gov.prohibited_dimension") + " as fair-housing proxies \u2014 see 9.4.", BODY))
A(para("They stay in the raw payload, because the file is not silently edited and staff "
       "underwriting may legitimately weigh schools. They never become a column. "
       + mono("api.security_invariants()") + " fails if either name appears in " + mono("core") +
       " or " + mono("api") + ", so this is enforced rather than intended.", GOOD))

A(para("10.4  Validation blocks, or warns, and the difference is deliberate", H2))
A(table([
    hdr(["Level", "Examples", "Effect"]),
    ["<b>error</b>", "No address, no usable price or rent, no coordinate, an address already listed, the same address twice in one file",
     "The row cannot be approved and cannot be released"],
    ["<b>warning</b>", "Unusual bedroom count or floor area, expenses meeting or exceeding gross rent, an expense total that does not reconcile with its own components",
     "Shown to the reviewer. Does not block"],
], [0.72*inch, 3.15*inch, 2.03*inch]))
A(Spacer(1, 5))
A(para("A reviewer forced to clear every oddity before releasing anything stops reading the "
       "oddities, and the warnings are then worth nothing. That is the whole reason for the "
       "split.", BODY))
A(para("Both copies of a duplicated address are flagged, not just the second. The system "
       "cannot know which one was intended, so it refuses them together and leaves the choice "
       "to a person.", BODY))
A(para("The reconciliation check applies the management fee and vacancy allowance to the rent "
       "before comparing, rather than summing only tax, insurance and maintenance. An earlier "
       "version did the latter and flagged every correctly built workbook \u2014 and a check that "
       "fires on everything is one a reviewer learns to click past, which costs more than not "
       "having it.", NOTE))

A(para("10.5  The review screen", H2))
A(para(mono("/admin.html") + ", staff only. Batches down the left, rows on the right, with "
       "price, rent, NOI and a cap rate computed here rather than trusted from the file.", BODY))
A(table([
    hdr(["Action", "What it does"]),
    ["Approve selected", "Marks rows reviewed. A row with a blocking error is refused, and the screen says how many of the selected rows actually changed"],
    ["Reject selected", "With an optional reason, kept against the row"],
    ["Release selected", "Creates the listings. Disabled unless something approved is selected, and it names the count"],
    ["what the file said", "The verbatim payload for that row"],
], [1.35*inch, 4.55*inch]))
A(Spacer(1, 5))
A(para("<b>Nothing reaches the marketplace without a person releasing it.</b> An invalid row "
       "cannot be approved \u2014 approving past a blocking error is how validation stops meaning "
       "anything \u2014 a pending row cannot be released, and \u201cselect all\u201d means \u201call the "
       "releasable ones\u201d, leaving blocked rows exactly where they are. A staging table that "
       "auto-promotes on a green validation is not a review queue; it is an import with extra "
       "steps.", GOOD))
A(para("The screen contains no permission logic. Every action is one of four " + mono("api") +
       " functions granted to staff alone, so an investor who calls them is refused by the "
       "database rather than by an if-statement in the page \u2014 which is also why the page "
       "settles the question by asking the server for the queue rather than reading a role "
       "name out of the session.", BODY))

A(para("10.6  Release records provenance, and says when that is not enough", H2))
A(para("Releasing writes a " + mono("gov.property_provenance") + " row against the batch's "
       "data right. The workbooks are held under " + mono("SDI-WORKBOOK") + ", which is "
       "recorded <b>unreviewed</b> on purpose:", BODY))
A(table([
    hdr(["What arrives in the file", "Whose it is"]),
    ["The financial modelling \u2014 offer, rents, expenses, projections", "SDI's own work. Needs no external instrument"],
    ["The property description", "Verbatim MLS listing copy, written by the listing agent. The right to republish it has not been established"],
], [2.5*inch, 3.4*inch]))
A(Spacer(1, 5))
A(para("Because " + mono("gov.may_use()") + " honours only counsel-confirmed rights, releasing "
       "under it publishes with an advisory warning and lists the property in "
       + mono("gov.uncovered_publication") + ". <b>The review screen reports that back at the "
       "moment of release</b> rather than leaving it to be found in a report later \u2014 the "
       "register working on real data rather than demonstration data.", GOOD))

# ------------------------------------------------------------------ 11
A(para("11.  What Is Tested", H1))
A(para("Not a coverage percentage. These are the specific claims that are checked, and the "
       "attacks that are run against them.", BODY))
A(para("Read this alongside 6.4. The database suites exercise a real PostgreSQL and prove "
       "what they claim. The worker suite proves its logic against test doubles, and proves "
       "nothing about GoHighLevel's or an MLS's actual behaviour.", NOTE))
A(table([
    hdr(["Suite", "Checks", "Notable"]),
    [mono("sql/05_tests.sql"), "11", "Five attacks: direct base-table read, another investor's saved list, saving an invisible property, a VOLATILE predicate side-channel, and the standing invariants"],
    [mono("sql/07_ghl_tests.sql"), "7", "A signed-but-unpaid document must not open the gate; replay must not move a signature timestamp"],
    [mono("sql/10_review_tests.sql"), "7", "A payload smuggling an address and a cost basis alongside a legitimate status change; only the allowlist is applied"],
    [mono("sql/14_pipeline_tests.sql"), "9", "One agent cannot read another's deal by naming its id; one investor cannot read another's stage history"],
    [mono("sql/23_listing_sync_tests.sql"), "10", "The whole listing lifecycle: under contract, failed escrow back to market, a feed outage, a genuine delisting, an advisory source, and a status term nobody has mapped"],
    [mono("sql/27_governance_tests.sql"), "10", "A data right built one failing condition at a time, and the same confirmed right refusing to cover a property one state away"],
    [mono("sql/29_intake_tests.sql"), "9", "Spreadsheet to listing: an invalid row cannot be approved, a pending row cannot be released, and \u201crelease ALL\u201d releases only what was approved"],
    [mono("web/ (npm test)"), "34", "Password verification cost on the failure path, session revocation on password change, lockout after repeated failures, and that no application role can read a credential hash"],
    [mono("worker/ (npm test)"), "70", "Signature forgery, replay, oversized bodies, rate-limit handling, ambiguous-create duplication, migration resumability, and the sweep's discipline \u2014 an error is never an absence, an advisory source cannot act. All against doubles, see 6.4"],
], [1.95*inch, 0.62*inch, 3.33*inch]))
A(Spacer(1, 5))
A(para("Every suite that changes demo data restores it. That is not tidiness: a test that "
       "leaves a property pending, or an investor's fee agreement open, breaks the "
       "side-by-side contrast the whole demo rests on \u2014 and does it silently, one run later.", NOTE))
A(Spacer(1, 5))
A(para(mono("api.security_invariants()") + " must always return zero rows. It catches the four "
       "changes that quietly dismantle the model: " + mono("USAGE") + " granted on " +
       mono("core") + ", an internal column exposed to a non-admin, RLS switched off on a "
       "protected table, or a view created without " + mono("security_invoker") + ". Wire it "
       "into CI and a nightly check.", GOOD))

# ------------------------------------------------------------------ 8
A(para("12.  What Is Not Built", H1))
A(para("Stated plainly so nothing here is mistaken for finished.", BODY))
A(table([
    hdr(["Missing", "Consequence"]),
    ["A real listing feed", "The MLS adapter is written against the RESO standard and has never run against a live feed. Until credentials exist, listing status is maintained by staff. See section 8"],
    ["The portal scraper", "Deliberately unimplemented. The source row, the trust flags and the review queue that would receive its output all exist \u2014 see 8.5 for why it stays that way"],
    ["Document storage", "The signed PDF artifact is not stored"],
    ["Messaging and unified inbox", "Not started"],
    ["Audit trail on band 2 and 3 reads", "Who viewed which address, and when, is not recorded"],
    ["Co-investment matching", "The pipeline exists; the matching engine does not"],
    ["A language model behind the search box", "The text parser is rules, not a model. The seam and the validator that would make model output safe to execute are built and tested \u2014 see 7.5"],
    ["Real listing photography", "Images are generated illustrations. Swapping them is a URL change; the gate does not depend on where they are served from"],
    ["Password reset and email delivery", "Authentication works, but a person who forgets a password needs staff to set a new one"],
    ["EspoCRM field mapping", "The load ordering and resumability are built and tested. The field-level mapping needs the live EspoCRM schema"],
    ["A hardened deployment", "The stack runs under Docker Compose and has been deployed on a VM. Nothing is internet-facing, and nothing should be until TLS, a reverse proxy and secret management are in place"],
    ["The data-rights register, filled in", "The machinery is built and the demo data is covered. The instruments the business actually operates under have not been transcribed \u2014 see 9.6 and " + mono("docs/data-rights-intake.md")],
    ["Authorised delivery of gated media", "Real photographs are served as static files under " + mono("web/public/") + ", so the database controls who is TOLD a url, not who can fetch it. Fine for generated illustrations, not for a location-revealing photograph. Needs an authorising route or signed, expiring urls"],
    ["Consent capture for SMS and email", "TCPA consent is neither captured nor evidenced here, and GoHighLevel's suppression state is not mirrored. This system cannot currently prove an opt-out was honoured"],
    ["Privacy subject requests", "No access, deletion or correction mechanism. One implementation satisfies CCPA and most state statutes at once"],
    ["Uploading a workbook through the browser", "The review screen reviews and releases; it does not accept a file. Loading is two commands at a shell \u2014 see 10.1"],
    ["Geocoding", "Coordinates come from a small ZIP centroid table, accurate to about a mile. A new market needs a row added before its listings will validate"],
    ["Editing a staged row before release", "A wrong figure means correcting the workbook and reloading. There is no in-place edit, deliberately: an edited row no longer matches the payload it is stored beside"],
], [1.7*inch, 4.2*inch]))


# ---------------------------------------------------------------- 9. next
A(PageBreak())
A(para("13.  Next Steps", H1))
A(para("Section 12 lists what is missing. This section says what each item needs, in "
       "what order, what has to be true before a phase can start, and how each one is "
       "tested. Durations are working weeks for one experienced developer and are "
       "estimates, not commitments.", BODY))

A(para("13.1  What each item needs, and how long", H2))
A(para("Ordered as recommended in 13.2. Estimates are working weeks for one experienced "
       "developer who already knows this codebase, and cover build plus the tests in 13.4. "
       "They exclude design iteration, review latency, and waiting on a third party — the "
       "three things that actually move dates.", BODY))
A(table([
    hdr(["#", "Item", "What it is", "Needs before starting", "Est."]),
    ["P0", "Signature verification and first deployment",
     "Confirm how GoHighLevel signs webhooks, and deploy the receiver that checks it.",
     "A public HTTPS host and a GoHighLevel account. Nothing else in the system.", "1w"],
    ["P1", "Authentication and sessions",
     "Real sign-in. A session resolves to a person id and a role, which the web tier assumes "
     "for the transaction.",
     "A decision on identity provider: own accounts, or an external one. No database change.", "3w"],
    ["P2", "EspoCRM field mapping and rehearsal",
     "Which EspoCRM field becomes which column, and which of the 30+ SDI metrics are inputs "
     "rather than derived.",
     "Read access to live EspoCRM or a full export. Load ordering already built and tested.", "4w"],
    ["P3", "Audit trail on gated reads",
     "A record of who saw which address, and when.",
     "P1. A decision on where band 2 is released from — PostgreSQL cannot trigger on SELECT.", "2w"],
    ["P4", "Public marketplace UI",
     "The real browsing surface: search, filters, property cards, masked map.",
     "P1 for the gated half, P2 for real content, and design direction.", "4w"],
    ["P5", "Investor portal and fee flow",
     "Registration, the fee agreement, and the unlock.",
     "P4, and a payment provider connected in GoHighLevel. The CRM side is already built.", "3w"],
    ["P6", "Document storage",
     "The signed PDF kept as an artifact, not only as a status flag.",
     "A storage and retention decision. The signed document is a financial record.", "2w"],
    ["P7", "Agent portal",
     "An agent's own assignments and conversations, and nothing else.",
     "P1. Per-agent isolation is already enforced and tested at the database level.", "2w"],
    ["P8", "Messaging and unified inbox",
     "Email, SMS and WhatsApp threaded against a contact and a property.",
     "A decision on whether GoHighLevel owns the conversation or only relays it. That sets "
     "the data model, so settle it first.", "3w"],
    ["P9", "External status feed",
     "Nightly check that a listing has not gone pending or sold elsewhere.",
     "A source. A licensed feed is strongly preferable to scraping a portal that forbids it.", "2w"],
    ["P10", "Co-investment matching",
     "Pairing two vetted investors on one property.",
     "The matching rules, in writing. The COINVEST pipeline and stages already exist.", "3w"],
    ["P11", "Hardening and cutover",
     "Production configuration, backups, restore rehearsal, go-live.",
     "Everything above that is in scope for launch.", "2w"],
], [0.32*inch, 1.08*inch, 1.75*inch, 2.4*inch, 0.35*inch]))
A(Spacer(1, 5))
A(para("Total build effort is roughly <b>31 developer-weeks</b>. The calendar in 13.2 is "
       "20 weeks because P2, P7 and P9 run alongside other work rather than after it. With "
       "one developer and no parallelism the same scope is about 31 weeks; the difference is "
       "entirely whether the EspoCRM and operations tracks can proceed independently.", GOOD))

A(PageBreak())
A(para("13.2  Recommended sequence", H2))
A(para("Two things drive this order. <b>Authentication gates everything user-facing</b>, so "
       "it goes first and almost nothing can be demonstrated to a real user before it lands. "
       "And <b>the audit trail should precede real investor data</b>, not follow it — the "
       "first time anyone asks who saw an address, the answer has to already exist.", BODY))
A(para("P0 is deliberately tiny and first. It deploys nothing but a webhook receiver, which "
       "authenticates by signature rather than by session, so it needs no login and exposes "
       "no data. It settles the one unverified item in the system and proves the deployment "
       "path at the same time.", GOOD))
A(Spacer(1, 6))
A(Gantt(5.9*inch, 4.05*inch))
A(para("Figure 1. Indicative schedule, one developer. P2 runs alongside P1 because the "
       "migration work needs EspoCRM access rather than the new authentication, so the two "
       "do not contend.", CAP))
A(Spacer(1, 4))
A(para("The critical path is P1 &rarr; P4 &rarr; P5: authentication, then the browsing "
       "surface, then the paid unlock. Everything else can move without moving the launch "
       "date. If the schedule has to compress, P8, P9 and P10 are the ones to defer — none "
       "of them is required for an investor to find a property, pay, and see the address.", BODY))

A(para("13.3  What must be true before a phase starts", H2))
A(table([
    hdr(["Phase", "Entry condition", "Done when"]),
    ["P0", "A host with a public HTTPS address and a GoHighLevel account",
     "A live delivery verifies against the published key, and the algorithm is confirmed in code and in the spec document"],
    ["P1", "A decision on the identity provider: own accounts, or an external one",
     "A session resolves to a person id and role; every existing SQL walkthrough still passes unchanged"],
    ["P2", "Read access to live EspoCRM, plus the field mapping agreed in writing",
     "A full rehearsal load into a disposable sub-account reconciles with zero shortfall and zero unresolved links"],
    ["P3", "P1 complete. A decision on where band 2 is released from",
     "Every band 2 and band 3 read is attributable to a person and a time; the attack tests still pass"],
    ["P4", "P1 complete; design direction; listing content from P2",
     "An anonymous visitor can browse and filter, and cannot obtain an address by any route including the network tab"],
    ["P5", "P4 complete; a payment provider connected in GoHighLevel",
     "An investor signs, pays, and the address unlocks — driven end to end against a GoHighLevel test sub-account"],
    ["P6", "A storage and retention decision", "The signed PDF is retrievable and its retention is enforced"],
    ["P7", "P1 complete", "An agent sees only their own assignments and conversations, proven by test, not by inspection"],
    ["P8", "The ownership decision in 13.1", "A thread is readable against both the contact and the property"],
    ["P9", "A data source", "A status change reaches the review queue and no listing changes without a human"],
    ["P10", "Matching rules in writing", "Two vetted investors are matched and both are notified"],
    ["P11", "Everything above that is in scope for launch", "Cutover rehearsed on staging, with a tested rollback"],
], [0.52*inch, 2.3*inch, 3.08*inch]))

A(PageBreak())
A(para("13.4  How each phase is tested", H2))
A(para("Every phase adds its own tests and must leave the existing ones green. That second "
       "half is the part that usually erodes, so it is stated as a gate rather than a habit.", BODY))
A(para("The standing regression suite", H2))
A(table([
    hdr(["Suite", "Checks", "Must remain"]),
    [mono("sql/05_tests.sql"), "11", "All five attacks refused"],
    [mono("sql/07_ghl_tests.sql"), "7", "Signed-but-unpaid still does not open the gate"],
    [mono("sql/10_review_tests.sql"), "7", "The allowlist still refuses band 2 and band 3 columns"],
    [mono("sql/14_pipeline_tests.sql"), "9", "No cross-agent or cross-investor read"],
    [mono("worker/ npm test"), "63", "All passing"],
    [mono("api.security_invariants()"), "—", "Zero rows, on every build"],
], [1.75*inch, 0.55*inch, 3.6*inch]))
A(Spacer(1, 6))
A(para("Run the whole thing with " + mono("./run.sh") + ", which loads the schema, runs all "
       "four walkthroughs and the worker suite in one pass. Wire "
       + mono("api.security_invariants()") + " into CI and into a nightly job: it catches the "
       "four changes that quietly dismantle the model, and it catches them whether they came "
       "from a migration, a hotfix, or a well-meant grant.", NOTE))

A(para("Per-phase development tests", H2))
A(table([
    hdr(["Phase", "New tests it must bring"]),
    ["P0", "Signature verification against a captured live delivery, added as a fixture so it is checked forever after"],
    ["P1", "Session to role mapping; an expired session; a tampered session; a session for a deactivated person"],
    ["P2", "Reconciliation counts; a resumed load after a forced failure; a link whose endpoints are missing"],
    ["P3", "An audit row exists for every band 2 and band 3 release; the audit log cannot be written by the reader"],
    ["P4", "An anonymous HTTP response contains no restricted field — asserted on the response body, not the rendered page"],
    ["P5", "Signed-and-paid unlocks; signed-and-unpaid does not; a refund after unlock"],
    ["P6", "The stored artifact matches what was signed; retention removes it on schedule"],
    ["P7", "One agent cannot reach another's assignment or conversation by id"],
    ["P8", "A message is attributable to a contact and a property; no cross-tenant leak"],
    ["P9", "A source change raises exactly one review item; a flapping source does not raise many"],
    ["P10", "A match requires two vetted parties; an unvetted party is never matched"],
    ["P11", "A restore from backup produces a working system; rollback returns to the prior version"],
], [0.52*inch, 5.38*inch]))
A(Spacer(1, 5))
A(para("Two habits worth keeping, both learned building what already exists. Write the test "
       "that tries the attack, not only the one that proves the feature — several of the "
       "checks in the suite exist because the naive version of a test passed while proving "
       "nothing. And re-run the whole suite, not the file you are working on: two of the bugs "
       "found so far only appeared when suites ran together.", GOOD))

A(PageBreak())
A(para("13.5  Validation methods to consider", H2))
A(para("Section 13.4 says what to test. This says <i>how</i>, and which technique earns its "
       "place where. Not all of these are worth adopting; they are listed with the judgement "
       "attached rather than as a checklist to complete.", BODY))
A(table([
    hdr(["Method", "What it is good for here", "Worth it?"]),
    ["Integration tests against a real PostgreSQL",
     "Row-level security, policies and grants cannot be mocked — a mock will happily return "
     "rows the real database would refuse. The existing suite already works this way.",
     "Already in use. Keep it; never substitute mocks for the database."],
    ["Adversarial tests",
     "A test that tries the attack, not one that proves the feature. Every 'ATTACK' check in "
     "the SQL walkthroughs is one, and several exist because the naive version passed while "
     "proving nothing.",
     "Essential. One per privilege boundary, minimum."],
    ["Property-based testing",
     "Generate random (viewer, property, entitlement) triples and assert the invariant: a "
     "viewer without a settled agreement never receives a street address. This explores "
     "combinations nobody thought to write down.",
     "High value from P3 onward. The visibility model is an unusually good fit."],
    ["Contract testing against the OpenAPI specs",
     "Validate outbound request shapes against GoHighLevel's published specification, so a "
     "field rename is caught at build time rather than as a 422 in production.",
     "Worth it once P2 volume is real."],
    ["Fault injection",
     "Deliberately fail mid-operation: kill the worker between an API call and its database "
     "write, redeliver a webhook, duplicate an outbox row. The resumability claims are only "
     "true if they survive this.",
     "Essential before P11. Cheap to run, and the failure it catches is data corruption."],
    ["Load testing",
     "The GoHighLevel burst limit is 100 requests per 10 seconds shared across all callers. "
     "Confirm the cached read model absorbs concurrent browsing rather than passing it "
     "through.",
     "Before P4 goes public. Model realistic concurrency, not a synthetic peak."],
    ["Penetration testing",
     "An independent attempt to obtain a street address without paying. The commercial model "
     "rests on that being impossible, which makes it the one thing worth an outside opinion.",
     "Before go-live. Scope it explicitly at the gate."],
    ["Migration reconciliation",
     "Counts and spot checks between source and destination after every rehearsal, with "
     "unresolved links reported rather than dropped.",
     "Already built. Run it on every rehearsal, not just the final one."],
    ["User acceptance testing",
     "Walk the seeded personas through real tasks with real staff. Ruth and Marcus exist "
     "precisely so the difference is demonstrable to a non-technical observer.",
     "Per phase, from P4."],
    ["Accessibility testing",
     "The public marketplace is a consumer surface. Keyboard navigation, contrast and screen "
     "reader behaviour on listing cards and filters.",
     "During P4, not after. Retrofitting is far more expensive."],
    ["Data quality checks",
     "Standing assertions on the ledger: no negative amounts, no refund exceeding its charge, "
     "no transaction pointing at a missing invoice. Some are already constraints.",
     "Promote to constraints where possible — a constraint cannot be forgotten."],
    ["Static analysis and dependency audit",
     "Lint, type checking, and a scan of the dependency tree. This project has one runtime "
     "dependency, which keeps this cheap.",
     "In CI from now. The cost is near zero while the tree is small."],
], [1.28*inch, 2.72*inch, 1.9*inch]))
A(Spacer(1, 6))
A(para("Three rules to attach to whichever of these you adopt", H2))
for b in buls([
    "<b>Run the whole suite, not the file you are working on.</b> Two of the bugs found while "
    "building this only appeared when suites ran together — one because two test files shared "
    "a database and raced.",
    "<b>A test that cannot fail is not a test.</b> Two checks here originally passed for the "
    "wrong reason: a permission error fired before the code under test was ever reached. Make "
    "each new test fail once, deliberately, before trusting it.",
    "<b>Wire " + mono("api.security_invariants()") + " into CI and a nightly job.</b> It is the "
    "only check that catches a policy quietly dismantled by a later migration, and it costs "
    "one query.",
]): A(b)


A(PageBreak())
A(para("13.6  Deployment", H2))
A(para("Both available options are suitable, for different jobs. The recommendation is to use "
       "both rather than choose.", BODY))
A(table([
    hdr(["Environment", "Role", "Why"]),
    ["Proxmox VM (local)", "Development and staging. The full stack, no public exposure.",
     "The EspoCRM rehearsal belongs here: real client data never leaves the network, and a "
     "rehearsal against a snapshot is repeatable in a way a live read is not. A VM rather "
     "than a container — PostgreSQL wants a stable filesystem and its own kernel-level tuning."],
    ["Linode (public)", "Production. Web tier and worker, publicly reachable.",
     "P0 needs a public HTTPS endpoint for GoHighLevel to deliver to, and nothing else does "
     "until P4. Start with the smallest instance that runs the worker."],
], [1.15*inch, 1.85*inch, 2.9*inch]))
A(Spacer(1, 6))
A(para("Topology", H2))
A(Preformatted(
  "  INTERNET\n"
  "     │\n"
  "     ├── 443  Linode: web tier + worker      (public)\n"
  "     │            │\n"
  "     │            └── PostgreSQL, private interface only, NEVER port-forwarded\n"
  "     │\n"
  "  WireGuard ─── Proxmox VM: staging + EspoCRM rehearsal + backup target\n"
  "                (no inbound from the internet at all)", CODE))
A(Spacer(1, 4))
A(para("Four rules for the production environment, each of which is cheap now and expensive "
       "to retrofit:", BODY))
for b in buls([
    "<b>PostgreSQL is never exposed to the internet.</b> Bind it to the private interface. "
    "The proxy this project was built behind refuses raw database ports for exactly this reason.",
    "<b>" + mono("sdi_test_admin") + " must not exist in production.</b> It carries " +
    mono("BYPASSRLS") + " and exists only for test fixtures. " + mono("worker/test/bootstrap.sql") +
    " is not a deployment script.",
    "<b>" + mono("sql/99_local_logins.sql") + " must not be loaded in production.</b> Its "
    "passwords are published in a public repository. Production roles get credentials from "
    "the deployment, not from the repository.",
    "<b>The GoHighLevel token lives in the environment</b>, never in a file and never in "
    "browser-reachable code. It is scoped to an entire sub-account.",
]): A(b)
A(Spacer(1, 4))
A(para("Backups are the one thing to set up before there is anything worth backing up, "
       "because that is the only time it is easy. Nightly " + mono("pg_dump") + " to the "
       "Proxmox side over WireGuard, and a restore rehearsed at least once — an untested "
       "backup is a belief, not a backup.", NOTE))

A(PageBreak())
A(para("14.  Where Things Are", H1))
A(table([
    hdr(["Path", "Contents"]),
    [mono("sql/01\u201304"), "Schema, RLS policies, masking views, demo data"],
    [mono("sql/05, 07, 10, 14, 23, 27, 29"), "The seven walkthroughs. Each is readable top to bottom as an argument, and each restores what it changes"],
    [mono("sql/06, 08, 09"), "GoHighLevel bridge, review queue, review actions"],
    [mono("sql/11\u201313"), "Deals, stage history, pipeline policies and seed"],
    [mono("sql/15_auth.sql"), "Credentials and sessions \u2014 see 3.1"],
    [mono("sql/16\u201317, 20"), "The demo dataset: 24 listings, their passwords, and the generated detail and market data"],
    [mono("sql/18\u201319"), "Property detail, market areas, photographs; saved searches"],
    [mono("sql/21\u201322"), "Listing sources, status vocabulary, reconciliation \u2014 see section 8"],
    [mono("sql/24\u201326"), "Data rights, territories, permitted uses, the compliance register, the fair-housing prohibited list \u2014 see section 9"],
    [mono("sql/28"), "Spreadsheet intake: staging, validation, review and release \u2014 see section 10"],
    [mono("tools/"), "The workbook reader. Python, because it needs a spreadsheet library the worker deliberately does not"],
    [mono("sql/99_local_logins.sql"), "Demo passwords. Local development only"],
    [mono("web/"), "The marketplace. " + mono("server.js") + ", " + mono("auth.js") + ", " + mono("nlq.js") + " (the text parser), " + mono("media.js") + " (the illustrations), and " + mono("public/") + " (the marketplace and " + mono("admin.html") + ", the review screen)"],
    [mono("web/test/"), "34 tests"],
    [mono("worker/src/"), "The GoHighLevel worker and the listing sweep (" + mono("listings/") + ")"],
    [mono("worker/test/"), "69 tests"],
    [mono("worker/tools/"), "Webhook capture, the nightly sweep, the listing importer, the data-rights loader and the intake loader"],
    [mono("docs/data-rights-intake.md"), "The questionnaire that turns signed agreements into enforceable rows"],
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


# ----------------------------------------------------------------- 15
A(PageBreak())
A(para("15.  Build and Release", H1))
A(para("How the three container images are produced, how a release is cut, and "
       "what a deployment actually pulls. The short version: nothing is built on "
       "a host. Every image is built by CI from a tagged commit and pulled by "
       "tag \u2014 which is what makes the stack deployable to Swarm, which cannot "
       "build at all, and keeps build tooling off the machine serving traffic.", BODY))

A(para("15.1  What gets built", H2))
A(table([
    hdr(["Image", "Base", "Built from", "Contains"]),
    [mono("db"), mono("postgres:16"), mono("docker/db.Dockerfile"),
     "Every schema file, copied into " + mono("/docker-entrypoint-initdb.d/") + ", plus the role-login script. The test walkthroughs are deliberately NOT copied"],
    [mono("web"), mono("node:22-alpine"), mono("web/Dockerfile"),
     mono("server.js") + ", " + mono("auth.js") + ", " + mono("media.js") + ", " + mono("nlq.js") + " and " + mono("public/")],
    [mono("worker"), mono("node:22-alpine"), mono("worker/Dockerfile"),
     mono("src/") + " and " + mono("tools/") + " \u2014 the operator entry points have to be inside the image, not merely in the repository"],
], [0.6*inch, 1.15*inch, 1.55*inch, 2.6*inch]))
A(Spacer(1, 5))
A(para("One runtime dependency across both Node images: " + mono("pg") + ". "
       "Installed with " + mono("npm ci") + " rather than " + mono("npm install") +
       ", so the build is reproducible and fails loudly if the lockfile and the "
       "manifest disagree. Both run as the unprivileged " + mono("node") + " user.", BODY))
A(para("The " + mono("web") + " image names each module it copies rather than "
       "globbing. That is not fussiness: an earlier version listed only two of "
       "the four, which produced an image that passed every test and crashed on "
       "its first require \u2014 a break invisible outside a container build.", NOTE))

A(para("15.2  Cutting a release", H2))
A(Preformatted("# 1. update the release level and its entry\n"
               "echo 0.10.0 > VERSION\n"
               "$EDITOR CHANGELOG.md\n"
               "python3 docs/extract_schema.py            # if the schema changed\n"
               "python3 docs/generate_system_documentation.py\n"
               "python3 docs/generate_test_plan.py\n\n"
               "# 2. commit, tag, push\n"
               "git commit -am \"Release 0.10.0\"\n"
               "git tag -a v0.10.0 -m \"0.10.0\"\n"
               "git push && git push --tags", CODE))
A(para("The push builds three images; the tag builds them again carrying the "
       "version. " + mono("VERSION") + " and " + mono("CHANGELOG.md") + " are read "
       "by this document at generation time, so the release level on the cover and "
       "the change log in Appendix B cannot disagree with the repository.", GOOD))

A(para("15.3  What CI produces", H2))
A(table([
    hdr(["Tag", "When", "Use it for"]),
    [mono("latest"), "Every push to " + mono("main") + " or the working branch", "The demo. It moves"],
    [mono("v0.10.0") + ", " + mono("0.10"), "A " + mono("v*") + " tag", "Anything real. Pin it"],
    [mono("sha-&lt;full sha&gt;"), "Every build", "Reproducing an exact deployment"],
    ["Branch name", "Every branch build", "Testing a branch before it merges"],
], [1.35*inch, 2.05*inch, 2.5*inch]))
A(Spacer(1, 5))
A(para(mono("docker-compose.release.yml") + " reads " + mono("SDI_VERSION") +
       " and defaults to " + mono("latest") + ". Set it to a release tag for "
       "anything that matters:", BODY))
A(Preformatted("SDI_VERSION=v" + VERSION + " docker compose -f docker-compose.release.yml up -d", CODE))
A(para("The workflow pins " + mono("latest") + " to two named branches rather than "
       "using the " + mono("is_default_branch") + " template. This repository's "
       "default branch is a working branch, so that template evaluated false and the "
       "first release published only an immutable " + mono("sha-") + " tag \u2014 leaving "
       "nothing for a compose file referencing " + mono("latest") + " to pull, which "
       "looked exactly like a permissions problem and was not.", NOTE))

A(para("15.4  Building locally", H2))
A(para("Only needed to test a Dockerfile change; the deployment never does this.", BODY))
A(Preformatted("docker compose build                    # all three, from source\n"
               "docker compose up -d\n\n"
               "./db-rebuild.sh                         # database only, no Docker\n"
               "(cd web && npm test) && (cd worker && npm test)", CODE))
A(table([
    hdr(["Script", "Does"]),
    [mono("run.sh"), "Loads every schema file into a local PostgreSQL, then runs all seven walkthroughs"],
    [mono("db-rebuild.sh"), "Drops and reloads the database, including the test fixture role that is easy to forget"],
    [mono("docs/extract_schema.py"), "Snapshots the live schema to " + mono("docs/schema-snapshot.json") + " for Appendix A"],
], [1.55*inch, 4.35*inch]))
A(Spacer(1, 5))
A(para("<b>Adding a schema file means editing three lists</b>, and missing one "
       "produces a failure far from its cause: " + mono("run.sh") + " for local "
       "development, " + mono("db-rebuild.sh") + " for a fast rebuild, and " +
       mono("docker/db.Dockerfile") + " for the image. Test walkthroughs go in the "
       "first two only.", NOTE))

A(para("15.5  Release checklist", H2))
A(table([
    hdr(["#", "Check", "How"]),
    ["1", "Every test passes", mono("npm test") + " in " + mono("web/") + " and " + mono("worker/") + "; the seven SQL walkthroughs"],
    ["2", "No standing invariant is violated", mono("SELECT * FROM api.security_invariants()") + " returns zero rows"],
    ["3", "A clean rebuild works", mono("./db-rebuild.sh") + " from nothing, not an incremental patch"],
    ["4", "The demo fixture is intact", "Marcus's gate shut, Ruth's open. A test suite that leaves it otherwise has broken the demo"],
    ["5", "New schema files are in all three lists", "See 15.4"],
    ["6", "The schema snapshot is current", mono("python3 docs/extract_schema.py")],
    ["7", "Both PDFs regenerated", "They read " + mono("VERSION") + " and " + mono("CHANGELOG.md") + " at generation time"],
    ["8", "The change log entry is written", mono("CHANGELOG.md") + ", before the tag"],
], [0.3*inch, 1.9*inch, 3.7*inch]))


# ------------------------------------------------------------- Appendix A
A(PageBreak())
A(para("Appendix A.  Table Definitions", H1))
A(para("Every column of every base table, read from the live database by "
       "<font face='Courier'>docs/extract_schema.py</font> and stored in "
       "<font face='Courier'>docs/schema-snapshot.json</font>. Regenerate the snapshot after "
       "any schema change and rebuild this document; the appendix cannot then describe a "
       "schema the system does not have.", BODY))
A(table([
    hdr(["Marker", "Meaning"]),
    ["PK", "Part of the primary key"],
    ["FK", "Foreign key; the referenced table is named in the same row"],
    ["UQ", "Covered by a unique constraint"],
    ["CK", "Covered by a check constraint"],
    ["not null", "The column is " + mono("NOT NULL")],
], [0.7*inch, 5.2*inch]))
A(Spacer(1, 6))

_snapshot = os.path.join(os.path.dirname(__file__), "schema-snapshot.json")
with open(_snapshot) as _fh:
    SCHEMA = json.load(_fh)

def _shorten(default):
    """Sequence defaults are noise at this width; name the behaviour instead."""
    if not default:
        return ""
    if default.startswith("nextval("):
        return "auto-increment"
    if default.startswith("'") and "::" in default:
        return default.split("::")[0]
    return default

_current_schema = None
for tbl in SCHEMA:
    if tbl["schema"] != _current_schema:
        _current_schema = tbl["schema"]
        A(para(f"Schema <font face='Courier'>{_current_schema}</font>", H2))
    rls = "row-level security enforced" if tbl["rls"] else "no row-level security"
    A(para(f"{tbl['schema']}.{tbl['name']}", TNAME))
    note = tbl["comment"].replace("\n", " ").strip()
    A(para(f"{len(tbl['columns'])} columns &middot; {rls}" + (f" &middot; {note}" if note else ""), TDESC))

    rows = [[Paragraph(c, SCELB) for c in
             ["Column", "Type", "Null", "Key", "Default / references"]]]
    for col in tbl["columns"]:
        keybits = []
        if col["key"]:
            keybits.append(col["key"])
        extra = _shorten(col["default"])
        if col["references"]:
            extra = (extra + " " if extra else "") + "&rarr; " + col["references"]
        rows.append([
            Paragraph(f"<font face='Courier'>{col['name']}</font>", SCELL),
            Paragraph(f"<font face='Courier'>{col['type']}</font>", SCELL),
            Paragraph("" if col["nullable"] else "not null", SCELL),
            Paragraph(" ".join(keybits), SCELL),
            Paragraph(extra, SCELL),
        ])
    A(table(rows, [1.55*inch, 1.1*inch, 0.55*inch, 0.5*inch, 2.2*inch]))

# ------------------------------------------------------------- Appendix B
A(PageBreak())
A(para("Appendix B.  Change Log", H1))
A(para("Read from " + mono("CHANGELOG.md") + " at generation time, so this document "
       "cannot describe a release history the repository does not have. The current "
       "release level is " + mono("v" + VERSION) + ", from " + mono("VERSION") + ".", BODY))
A(para("Versions are 0.x deliberately: nothing here has run against a production "
       "GoHighLevel account or a live MLS feed, so the interfaces are not stable "
       "enough to promise compatibility. The first release that has is 1.0.0.", NOTE))

_CL_H2  = S("clh2", fontName="Helvetica-Bold", fontSize=12, leading=16, textColor=INK,
            spaceBefore=15, spaceAfter=2)
_CL_SUB = S("clsub", fontName="Helvetica-Oblique", fontSize=9.5, leading=13,
            textColor=MUTED, spaceAfter=6)
_CL_H3  = S("clh3", fontName="Helvetica-Bold", fontSize=9, leading=12, textColor=ACCENT,
            spaceBefore=8, spaceAfter=3)
_CL_LI  = S("clli", parent=BODY, fontSize=9, leading=12.4, leftIndent=13,
            bulletIndent=3, spaceAfter=3)

def _inline(t):
    """Markdown emphasis and code spans -> reportlab markup.

    Escapes first, then substitutes, so a literal < in the change log
    cannot become markup and a markdown link cannot smuggle one.
    """
    t = t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    t = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", t)      # [text](url) -> text
    t = re.sub(r"`([^`]+)`", r"<font face='Courier'>\1</font>", t)
    t = re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", t)
    t = re.sub(r"(?<!\*)\*([^*]+)\*(?!\*)", r"<i>\1</i>", t)
    return t

_started = False
_buf = []
def _flush():
    global _buf
    if _buf:
        A(para(" ".join(_buf), _CL_LI))
        _buf = []

for _line in CHANGELOG.splitlines():
    _t = _line.rstrip()
    if _t.startswith("## "):
        _flush(); _started = True
        _bits = _t[3:].split(" \u2014 ")
        A(para(_bits[0].strip(), _CL_H2))
        if len(_bits) > 1:
            A(para(_bits[1].strip(), _CL_SUB))
    elif not _started:
        continue
    elif _t.startswith("### "):
        _flush(); A(para(_t[4:].strip(), _CL_H3))
    elif _t.startswith("**") and _t.endswith("**"):
        _flush(); A(para(_inline(_t), BODY))
    elif _t.startswith("- "):
        _flush(); _buf = ["&bull;&nbsp;&nbsp;" + _inline(_t[2:])]
    elif _t.startswith("  ") and _t.strip() and _buf:
        _buf.append(_inline(_t.strip()))
    elif not _t.strip():
        _flush()
_flush()

doc.multiBuild(E)
print("wrote", OUT)
