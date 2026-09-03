#!/usr/bin/env python3
"""
Generates the Deployment Runbook PDF.

    python3 docs/generate_runbook.py

Written to be followed at a prompt, not read in an armchair: a step, the
command, the expected output, and only then the reason. Paths and values
are the real ones for the current deployment rather than placeholders --
a runbook with <your-host> in it gets typed literally at least once.
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from _style import (BODY, H1, H2, CODE, CAP, NOTE, GOOD, CT, CS, BLANK, TOC1, TOC2,
                    CELL, CELLB, para, mono, hdr, table, build_doc, S,
                    INK, MUTED, ACCENT, OK, WARN, CODE_BG, RULE)
from reportlab.lib.units import inch
from reportlab.platypus import PageBreak, Preformatted, Spacer
from reportlab.platypus.tableofcontents import TableOfContents

OUT = "docs/Deployment-Runbook.pdf"

with open(os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                       "VERSION")) as _fh:
    VERSION = _fh.read().strip()

STEP = S("step", fontName="Helvetica-Bold", fontSize=10.5, leading=14, textColor=ACCENT,
         spaceBefore=13, spaceAfter=4)
EXP  = S("exp", fontName="Helvetica-Bold", fontSize=8.5, leading=11, textColor=MUTED,
         spaceBefore=4, spaceAfter=2)
OUTB = S("outb", fontName="Courier", fontSize=8, leading=10.6, textColor=INK,
         backColor="#EDF5EE", borderPadding=6, borderColor=OK, borderWidth=0.6,
         leftIndent=3, spaceAfter=8)

doc = build_doc(OUT, "Deployment Runbook",
                "SDI Investment Property Marketplace — Deployment Runbook",
                "Numbered deployment, upgrade and intake procedures with expected output")
E = []; A = E.append

def cmd(t):    A(Preformatted(t, CODE))
def expect(t): A(para("Expected", EXP)); A(Preformatted(t, OUTB))

# ------------------------------------------------------------------ cover
A(Spacer(1, 1.6*inch))
A(para("SDI Investment Property Marketplace", CT))
A(Spacer(1, 0.06*inch))
A(para("Deployment Runbook", CS))
A(para("Every step, in order, with the output you should see", CS))
A(Spacer(1, 0.5*inch))
A(table([
    ["Release", mono("v" + VERSION)],
    ["Verified against", "The live host, 2026-09-03"],
    ["Deployment folder", mono("/opt/sdi")],
    ["Source clone", mono("/root/property-management")],
    ["Web port", mono("3099")],
    ["Repository", mono("github.com/neilgreene/property-management")],
], [1.35*inch, 4.05*inch], header=False, zebra=False))
A(PageBreak())

A(Spacer(1, 3.4*inch))
A(para("This page is intentionally blank.", BLANK))
A(PageBreak())

A(para("Contents", H1))
A(Spacer(1, 3))
toc = TableOfContents(); toc.levelStyles = [TOC1, TOC2]; toc.dotsMinLevel = 0
A(toc)
A(Spacer(1, 14))
A(para("<b>Two folders, and they are not the same thing.</b> " + mono("/opt/sdi") +
       " is the running system: a compose file and the database volume, nothing "
       "else. It is <b>not</b> a git clone. " + mono("/root/property-management") +
       " is a copy of the source, needed only for the scripts in section C. "
       "Nothing done in one folder affects the other.", GOOD))
A(PageBreak())

# ================================================================== A
A(para("A.  Upgrade To A New Release", H1))
A(para("Ten minutes. Do this whenever a new release is published.", BODY))

A(para("A1.  Pull and restart", H2))
cmd("cd /opt/sdi\ndocker compose pull\ndocker compose up -d")
expect("[+] pull 3/3\n  Image ...  /db:latest      Pulled\n"
       "  Image ...  /web:latest     Pulled\n  Image ...  /worker:latest  Pulled\n"
       "[+] up 3/3\n  Container sdi-db-1      Healthy\n"
       "  Container sdi-web-1     Running\n  Container sdi-worker-1  Started")
A(para("<b>When you also need </b>" + mono("docker compose down -v") + "<b>.</b> The "
       "schema files are baked into the " + mono("db") + " image, and PostgreSQL runs "
       "them <b>only when the data volume is empty</b>. Pulling a newer image onto an "
       "existing volume gives you the new image and the old schema, with no error and "
       "no warning — the web tier then queries tables that do not exist. If the "
       "release added schema files, put " + mono("docker compose down -v") + " between "
       "the two commands above.", NOTE))
A(para(mono("down -v") + " <b>deletes the database.</b> That is correct while it holds "
       "demonstration data and wrong the moment it does not.", NOTE))

A(para("A2.  Confirm the schemas", H2))
cmd('docker compose exec db psql -U postgres -d sdi -c "\\dn"')
expect("  Name   |      Owner\n---------+-------------------\n"
       " api     | postgres\n core    | postgres\n feed    | postgres\n"
       " ghl     | postgres\n gov     | postgres\n intake  | postgres\n"
       " public  | pg_database_owner\n sec     | postgres\n(8 rows)")
A(para("Eight rows at release " + mono("0.9.0") + ". A missing schema means step A1 "
       "needed " + mono("down -v") + ".", BODY))

A(para("A3.  Confirm the web tier", H2))
cmd("docker compose logs web | grep fair-housing")
expect("web-1  | fair-housing register: 17 dimensions, none exposed as filters")
A(para("A " + mono("FATAL: could not reach the database") + " line <i>before</i> that "
       "one is the web container losing a start-up race with a cold database and being "
       "restarted. Harmless when the good line follows. Widened to a two-minute retry "
       "budget in 0.9.0; on older images it is expected.", BODY))

A(para("A4.  Open it", H2))
cmd("http://<host>:3099/")
A(para("Type " + mono("http://") + " explicitly. Browsers upgrade a bare hostname to "
       "HTTPS, this does not serve TLS, and the result is "
       + mono("ERR_SSL_PROTOCOL_ERROR") + " — which looks like a network fault and "
       "is not.", NOTE))
A(table([
    hdr(["Sign in as", "Password", "Shows"]),
    [mono("jpool2@yahoo.com"), mono("demo1234"), "Staff. Everything, plus the review screen"],
    [mono("ruth@example.com"), mono("demo1234"), "Investor, fee agreement signed. Addresses shown"],
    [mono("marcus@example.com"), mono("demo1234"), "Investor, not signed. Addresses withheld"],
], [1.55*inch, 0.95*inch, 3.4*inch]))
A(Spacer(1, 4))
A(para("Ruth and Marcus hold the same role and match the same listings. One timestamp "
       "in one data column is the entire difference — open them side by side.", GOOD))

# ================================================================== B
A(PageBreak())
A(para("B.  One-Time Setup For Spreadsheet Intake", H1))
A(para("Once per host. Skip if " + mono("docker compose config --services") +
       " already lists " + mono("worker") + ".", BODY))

A(para("B1.  Clone the source", H2))
A(para("The workbook reader is a repository script and is not part of any image.", BODY))
cmd("cd /root\ngit clone https://github.com/neilgreene/property-management.git")
expect("Cloning into 'property-management'...\nReceiving objects: 100% ... done.\n"
       "Resolving deltas: 100% ... done.")

A(para("B2.  Add the worker service", H2))
A(para(mono("docker compose run --rm worker") + " needs the service defined. Back the "
       "file up first, then add this block after the " + mono("web:") + " service and "
       "before the top-level " + mono("volumes:") + " key.", BODY))
cmd("cd /opt/sdi\ncp docker-compose.yml docker-compose.yml.bak")
cmd("""  worker:
    image: ghcr.io/neilgreene/property-management/worker:latest
    depends_on:
      db:
        condition: service_healthy
    environment:
      PGHOST: db
      PGDATABASE: sdi
      PGUSER: sdi_integration
      PGPASSWORD: sdi_int_pw
    volumes:
      - ./intake:/intake
    restart: "no\"""")
cmd("docker compose config --services\ndocker compose up -d")
expect("db\nweb\nworker")
A(para("<b>Role passwords are applied at first start only.</b> " + mono("PGPASSWORD") +
       " here must match " + mono("SDI_INTEGRATION_PASSWORD") + " on the " + mono("db") +
       " service. A role given no password stays " + mono("NOLOGIN") + " and cannot be "
       "given one later without re-initialising the volume — so if the first-start "
       "log said " + mono("no password for sdi_integration") + ", set it and re-run A1 "
       "<i>with</i> " + mono("down -v") + ".", NOTE))

A(para("B3.  Install the spreadsheet reader", H2))
cmd("apt-get install -y python3-openpyxl")
A(para("Reading .xlsm needs a spreadsheet library, and the worker image carries no "
       "dependency beyond the Postgres driver. The conversion therefore happens on the "
       "host, and what crosses into the database is plain JSON.", BODY))

# ================================================================== C
A(para("C.  Load A Batch Of Workbooks", H1))

A(para("C1.  Put the files where the container can read them", H2))
cmd("mkdir -p /opt/sdi/intake\ncp /path/to/*.xlsm /opt/sdi/intake/")

A(para("C2.  Convert to JSON", H2))
cmd("cd /root/property-management\npython3 tools/workbook-to-json.py \\\n"
    "    /opt/sdi/intake/*.xlsm > /opt/sdi/intake/batch.json")
A(para("Nothing has touched the database yet. <b>Open </b>" + mono("batch.json") +
       "<b> and read it.</b> That is the point of the middle format: when a released "
       "listing later says something surprising, this is what answers whether the "
       "spreadsheet said it or whether we mistranslated it.", GOOD))

A(para("C3.  Load into the review queue", H2))
cmd('cd /opt/sdi\ndocker compose run --rm worker node tools/load-intake.js \\\n'
    '    /intake/batch.json --note "August sourcing"')
expect("batch 9fda21c3-095e-4739-a9c6-2bf63759b98b\n  2 row(s) from 2 workbooks\n\n"
       "   1. [pending ] 401 NW 71st St    Kansas City   $295,000  cap 5.74%\n"
       "   2. [pending ] 405 SE Onyx Cir   Lees Summit   $300,000  cap 5.46%\n\n"
       "  2 ready for review, 0 blocked.")
A(para("<b>No listing has been created.</b> Rows marked " + mono("invalid") + " carry a "
       "blocking problem — no price, no coordinate, an address already listed — and "
       "cannot be approved until the workbook is corrected and reloaded.", BODY))

A(para("C4.  Review and release", H2))
cmd("http://<host>:3099/admin.html")
A(para("Signed in as staff. Then:", BODY))
A(table([
    hdr(["", "Do", "Result"]),
    ["1", "Tick rows, or <b>Select all releasable</b>", "Only rows that can move are ticked"],
    ["2", "<b>Approve selected</b>", "Rows turn <i>approved</i>. Invalid rows are refused, and the screen says how many actually changed"],
    ["3", "Tick again, then <b>Release selected</b>", "Listings are created and given references"],
], [0.3*inch, 2.1*inch, 3.5*inch]))
A(Spacer(1, 5))
A(para("An amber banner reading <b>published with no confirmed data right</b> is "
       "<b>expected</b>. The workbook right is recorded unreviewed because the property "
       "descriptions are verbatim MLS listing copy whose republication right has not "
       "been established. See section 9 of the System Documentation.", NOTE))
A(para("Click <b>what the file said</b> on any row to see the verbatim payload.", BODY))

# ================================================================== D
A(para("D.  Nightly Listing Status Sweep", H1))
A(para("Not wired to a scheduler. Add to the host's crontab:", BODY))
cmd("0 7 * * *  cd /opt/sdi && docker compose run --rm worker \\\n"
    "             node tools/check-listings.js >> /var/log/sdi-sweep.log 2>&1")
A(para("With no MLS feed connected this records that it looked and changes nothing, "
       "which is the correct behaviour rather than a failure. See section 8 of the "
       "System Documentation for what it does once a feed exists.", BODY))

# ================================================================== E
A(para("E.  Health Checks", H1))
A(para("E1.  The standing invariants", H2))
cmd('docker compose exec db psql -U postgres -d sdi \\\n'
    '  -c "SELECT * FROM api.security_invariants()"')
expect(" violation | detail\n-----------+--------\n(0 rows)")
A(para("<b>Zero rows is the pass, and this is the most valuable check here.</b> It "
       "catches the handful of changes that quietly dismantle the visibility model: "
       "access granted on the internal schema, an internal column exposed, row security "
       "switched off, a view created with the wrong privileges, or a dimension the "
       "fair-housing register forbids becoming readable. Run it after every upgrade.", GOOD))

A(para("E2.  Where the data-rights register stands", H2))
cmd('docker compose exec db psql -U postgres -d sdi \\\n'
    '  -c "SELECT * FROM api.governance_status" \\\n'
    '  -c "SELECT * FROM gov.uncovered_publication"')
A(table([
    hdr(["Column", "Means"]),
    [mono("enforcement_mode"), mono("advisory") + " — gaps are reported, publication is not blocked. Flipping to " + mono("blocking") + " is the go-live gate"],
    [mono("rights_confirmed"), "How many instruments a lawyer has actually signed off"],
    [mono("uncovered_published"), "Listings on public display that no confirmed right covers"],
], [1.55*inch, 4.35*inch]))
A(Spacer(1, 4))
A(para(mono("gov.uncovered_publication") + " names each such listing and the reason: "
       "missing, expired, unreviewed, or out of territory.", BODY))

# ================================================================== F
A(PageBreak())
A(para("F.  When Something Goes Wrong", H1))
A(table([
    hdr(["Symptom", "Cause", "Fix"]),
    [mono("ERR_SSL_PROTOCOL_ERROR"), "The browser upgraded a bare hostname to HTTPS; this does not serve TLS", "Type " + mono("http://") + " explicitly"],
    ["The marketplace loads but errors on data", "A newer " + mono("db") + " image on an old volume: new image, old schema", "A1 again, with " + mono("down -v")],
    [mono("permission denied for schema intake"), "The worker's " + mono("PGPASSWORD") + " does not match, or " + mono("sdi_integration") + " never got a password", "See the note under B2"],
    [mono("no such service: worker"), "The worker block is not in the compose file", "B2"],
    [mono("FATAL") + " then a good fair-housing line", "Start-up race with a cold database; the restart policy recovered it", "Nothing. Pull 0.9.0 or later to stop it happening"],
    ["A row will not approve", "It has a blocking validation error", "Read the red line on the row. Correct the workbook and reload"],
    ["No listing status ever changes", "No MLS feed is connected", "Expected. See section 8 of the System Documentation"],
], [1.55*inch, 2.05*inch, 2.3*inch]))
A(Spacer(1, 8))
A(para("Anything not listed here: capture the command, its full output, and "
       + mono("docker compose logs --tail=50") + " for the service that misbehaved.", CAP))

doc.multiBuild(E)
print("wrote", OUT)
