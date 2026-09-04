#!/usr/bin/env python3
"""
Generates the Property Media Lifecycle PDF.

    python3 docs/generate_media_lifecycle.py

The operational requirements for listing photography: how a file gets in,
how it acquires meaning, how it is maintained, and when it is destroyed.

This is a REQUIREMENTS document. Much of it is now built, and section 9 is
the table that says which parts -- kept current, because a requirements
document read as a status report is how a team comes to believe it has a
feature it does not have, and a stale status table is worse than none.
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from _style import (BODY, H1, H2, CODE, CAP, NOTE, GOOD, CT, CS, BLANK, TOC1, TOC2,
                    CELL, CELLB, para, mono, hdr, table, buls, build_doc, S,
                    INK, MUTED, ACCENT, OK, WARN, RULE)
from reportlab.lib.units import inch
from reportlab.platypus import PageBreak, Spacer, Preformatted
from reportlab.platypus.tableofcontents import TableOfContents

OUT = "docs/Property-Media-Lifecycle.pdf"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
with open(os.path.join(ROOT, "VERSION")) as _fh:
    VERSION = _fh.read().strip()

REQ = S("req", fontName="Helvetica-Bold", fontSize=10.5, leading=14, textColor=ACCENT,
        spaceBefore=15, spaceAfter=5)
STAT = S("stat", fontName="Helvetica-Bold", fontSize=8, leading=11, textColor=WARN,
         spaceAfter=4)

doc = build_doc(OUT, "Property Media Lifecycle",
                "SDI — Property Media Lifecycle",
                "How listing photography gets in, acquires meaning, is maintained, and is destroyed")
E = []; A = E.append
def cmd(t): A(Preformatted(t, CODE))


def req(rid, title, need, why):
    A(para(f"{rid} &nbsp;&nbsp;{title}", REQ))
    A(table([
        ["The need", need],
        ["Why it bites", why],
    ], [0.95*inch, 4.95*inch], header=False, zebra=False))


# ------------------------------------------------------------------ cover
A(Spacer(1, 1.5*inch))
A(para("SDI Investment Property Marketplace", CT))
A(Spacer(1, 0.06*inch))
A(para("Property Media Lifecycle", CS))
A(para("Upload, assignment, maintenance and purge", CS))
A(Spacer(1, 0.45*inch))
A(table([
    ["Document type", "Operational requirements. What is built, and what is not, is section 9."],
    ["Build at", mono("v" + VERSION) + ", github.com/neilgreene/property-management"],
    ["Covers", "Photographs and other listing media, from arrival to destruction"],
    ["Does not cover", "Documents (fee agreements, inspection reports) — a different retention regime"],
], [1.15*inch, 4.35*inch], header=False, zebra=False))
A(Spacer(1, 2.6*inch))
A(para("This page is intentionally blank.", BLANK))
A(PageBreak())

A(para("Contents", H1))
A(Spacer(1, 3))
toc = TableOfContents(); toc.levelStyles = [TOC1, TOC2]; toc.dotsMinLevel = 0
A(toc)
A(Spacer(1, 16))
A(para("<b>Photography is not an attachment. It is a publication.</b> A photograph "
       "of the front of a house identifies the property as surely as its street "
       "address, so putting one on a listing is the same act as disclosing the "
       "address — and the platform's entire commercial model is that the address is "
       "withheld until a fee agreement is signed. Every requirement in this document "
       "follows from that.", GOOD))
A(PageBreak())

# ================================================================== 1
A(para("1.  The problem this document exists to solve", H1))
A(para("A photograph lives in two places at once: as bytes on a filesystem, and as a "
       "row in " + mono("core.property_media") + " that says what those bytes mean. "
       "Neither is useful alone. The bytes without the row are an orphan nobody can "
       "find; the row without the bytes is a broken image on a live listing.", BODY))
A(para("Almost every operational failure in a media system is these two drifting "
       "apart. A file is copied in and never registered. A row is deleted and the file "
       "is left behind, quietly consuming storage for years. A database is restored "
       "from Tuesday and a filesystem from Wednesday. Somebody clears space by hand and "
       "removes the wrong thing, because nothing on disk said what it was for.", BODY))
A(para("So the requirements below are mostly about keeping the two in agreement, and "
       "about being able to answer two questions at three in the morning:", BODY))
A(table([
    hdr(["The question", "Who asks it"]),
    ["<b>I am looking at this file. What is it, and may it be deleted?</b>",
     "Whoever is clearing disk, restoring a backup, or responding to a takedown demand"],
    ["<b>I am looking at this listing. Where are its files?</b>",
     "Whoever is fixing a broken image, re-encoding a set, or archiving a sold property"],
], [3.1*inch, 2.8*inch]))
A(Spacer(1, 6))
A(para("A layout that cannot answer both, quickly and without a running application, "
       "will be worked around — by hand, badly, under time pressure.", BODY))

# ================================================================== 2
A(para("2.  Where a file lives, and how to find it", H1))
A(para("2.1  The layout", H2))
A(para("Four zones on the shared mount, each with one job. The mount is storage, not "
       "a web root: nothing here is served by path.", BODY))
cmd("""/srv/media/
  inbox/
    SDI-1009 - Columbus OH - Single Family 5bd 2ba/
        README.txt          <- what this property is, written by the system
        IMG_4471.jpg        <- dropped from a PC. Any filename.
    _unsorted/              <- photographs whose property is not yet known
  store/
    SDI-1009/
        7f3a91c4e8b2....-orig.jpg     <- media_id, then variant
        7f3a91c4e8b2....-720.jpg
  quarantine/               <- failed ingest, kept for diagnosis
  purged/                   <- deleted, awaiting retention expiry""")
A(para("2.2  Why the filename is the media_id", H2))
A(para("This is the answer to the maintenance question, and it is worth being explicit "
       "about. In " + mono("store/") + ", the filename <b>is</b> the primary key of the "
       "database row. Not a slug, not a sequence, not the original camera filename — "
       "the " + mono("media_id") + " itself.", BODY))
A(para("That means anybody holding a file can identify it with one query and no "
       "guesswork, and the answer includes everything needed to decide its fate:", BODY))
cmd("""$ psql -d sdi -c "SELECT listing_ref, caption, position, is_primary,
                        reveals_location, published_at, deleted_at
                   FROM core.property_media m
                   JOIN core.property p USING (property_id)
                  WHERE media_id = '7f3a91c4-e8b2-...'" """)
A(para("And the reverse direction needs no query at all — " + mono("ls store/SDI-1009/")
       + " is the complete set of files for a listing. That redundancy is deliberate: "
       "the listing reference in the path is there so a human can navigate, and the "
       "database is authoritative if the two ever disagree.", BODY))
A(para("<b>Requirement.</b> The row stores its own relative path in a "
       + mono("storage_path") + " column rather than reconstructing it from the "
       "listing reference. A listing reference can be corrected; a path that is "
       "derived from one silently stops resolving when it is, and the failure appears "
       "weeks later as a broken image nobody can explain.", NOTE))
A(para("2.3  Why the inbox is separate from the store", H2))
A(para("Because a human drop zone and a machine-managed store have opposite "
       "requirements. The inbox must tolerate anything — a phone filename, a "
       "duplicate, a HEIC, a screenshot, a file that is still copying. The store must "
       "contain only files that have been validated, re-encoded, stripped of metadata "
       "and registered. Mixing them means the store contains unvalidated bytes, and "
       "the whole guarantee collapses.", BODY))
A(para("A file is removed from the inbox once it is in the store. An inbox that stays "
       "full is a queue that stopped, and it should be visible as one.", BODY))
A(PageBreak())

# ================================================================== 3
A(para("3.  Getting photographs in", H1))
A(para("Two routes, because they serve different moments. Both converge on one "
       "processing pipeline — if they do not, the weaker one becomes the way "
       "everything gets in.", BODY))
A(table([
    hdr(["", "Drop on the share", "Upload in the panel"]),
    ["Suits", "Forty photographs from a shoot", "One photograph, right now"],
    ["Who", "Anyone with the share mounted", "Signed-in staff"],
    ["Knows the property?", "By folder", "By being on its page"],
    ["Attribution", "Filesystem owner — weak", "Authenticated person — exact"],
], [1.15*inch, 2.4*inch, 2.35*inch]))
A(Spacer(1, 6))
A(para("3.1  What both routes must do", H2))
A(para("Every arriving file, by either route, passes through the same steps in the "
       "same order:", BODY))
for p in buls([
    "<b>Sniff the content, do not trust the extension.</b> A " + mono(".jpg") +
    " that is not a JPEG is either a mistake or an attack, and both end in quarantine.",
    "<b>Reject what is not an image</b>, and cap the size. A 60 MB RAW file is a "
    "mistake, not a listing photo.",
    "<b>Re-encode.</b> This is what strips metadata, and it is not optional here — "
    "see 3.2.",
    "<b>Generate the thumbnail</b> that " + mono("thumb_url") + " points at. Twenty-five "
    "full-size photographs on one page is 9.4 MB against 2.1 MB of thumbnails.",
    "<b>Hash the content</b> and refuse an exact duplicate already on the listing. "
    "The same photo arriving twice is the normal case, not the rare one.",
    "<b>Register the row</b> — pending, unpublished, and " + mono("reveals_location") +
    " defaulted to <b>true</b>.",
]): A(p)
A(Spacer(1, 4))
A(para("3.2  Metadata stripping is not housekeeping", H2))
A(para("A photograph taken on a phone carries GPS coordinates in its EXIF block. "
       "Accurate to a few metres. Upload one untouched and the exact location of the "
       "property is sitting inside the file, readable by anything, for the one thing "
       "the entire platform exists to withhold.", BODY))
A(para("The gate would still be intact in the database and completely bypassed in "
       "practice. It also carries the camera serial, and often the photographer's "
       "name — which is a data protection question on top of a commercial one. "
       "<b>Re-encoding on ingest is the control.</b> It has to sit in the pipeline, "
       "not in a checklist, and it has to be on the share path as well as the upload "
       "path, because a file copied from a PC never passed through a browser.", NOTE))
A(para("3.3  Fail closed on arrival", H2))
A(para("A newly arrived photograph is assumed to reveal the location until a human "
       "says otherwise. The alternative — assume it is safe, publish, and correct "
       "later — means the window between arrival and review is a window in which the "
       "gate is open. Corrections do not un-disclose anything.", BODY))
A(para("The cost of failing closed is that somebody has to click. That is the "
       "intended cost.", BODY))
A(PageBreak())

# ================================================================== 4
A(para("4.  Assigning meaning", H1))
A(para("A file in the store is inert. It becomes part of a listing when somebody "
       "decides what it is. That decision is the publication act, and it is where the "
       "interface earns its keep.", BODY))
A(para("4.1  What has to be decided per photograph", H2))
A(table([
    hdr(["Decision", "Effect", "Default"]),
    ["<b>Which property</b>", "Everything else. Wrong here and a photo of one house sells another", "Folder, or unset"],
    ["<b>KEY image</b>", "The card thumbnail — the one image most people ever see", "None until chosen"],
    ["<b>Order</b>", "Gallery sequence", "Arrival order"],
    ["<b>Shows the street</b>", "The gate. True means investors behind the fee only", "<b>True</b>"],
    ["<b>Caption</b>", "What the viewer is told it is", "Empty"],
    ["<b>Published</b>", "Whether it appears at all", "No"],
], [1.35*inch, 3.0*inch, 1.55*inch]))
A(Spacer(1, 6))
A(para("4.2  The gate, exposed as a checkbox", H2))
A(para("&#8220;Shows the street&#8221; is " + mono("reveals_location") + ", and it "
       "deserves to be phrased in those words rather than as a technical flag. The "
       "person ticking it is deciding who may see the photograph, and they should be "
       "able to tell that from the label alone.", BODY))
A(para("The flag means <b>identifying</b>, not <b>exterior</b>. A photograph of a "
       "different house — the representative stock images currently on every listing — "
       "identifies nothing and is not gated. A photograph of this house's front door, "
       "with a number on it, is gated whether or not the street is in frame. The "
       "interface should say which test is being applied, because the obvious reading "
       "of the words is the wrong one.", NOTE))
A(para("4.3  Requirements on the panel", H2))
for p in buls([
    "<b>Every photograph on one screen</b>, thumbnails, with pending ones visually "
    "distinct from published ones. Somebody must be able to see at a glance that six "
    "photos arrived and none are live.",
    "<b>Setting the KEY image is one click</b>, and moves the flag off whatever held "
    "it. There is exactly one, enforced by a unique index, so the interface must make "
    "that visible rather than let a save fail.",
    "<b>Reordering is dragging.</b> Typing position numbers is how galleries end up "
    "with two photos at position 3.",
    "<b>Publish is deliberate and plural.</b> Review six, publish six, one action, one "
    "audit entry.",
    "<b>Unassigned photographs are surfaced, not hidden.</b> The " + mono("_unsorted/") +
    " queue is the normal result of a bulk download, and it needs a screen that shows "
    "them and asks which property.",
    "<b>Staff authorisation is checked in the database</b> on every call. A hidden "
    "button is not a permission.",
]): A(p)
A(PageBreak())

# ================================================================== 5
A(para("5.  Managing what is already there", H1))
A(para("5.1  The ordinary operations", H2))
A(table([
    hdr(["Operation", "What it must not do"]),
    ["Recaption", "Nothing subtle. Free text, audited"],
    ["Reorder", "Leave two photographs claiming one position"],
    ["Change the KEY image", "Leave the listing with none, even for an instant"],
    ["Replace a photograph", "Silently keep serving the old bytes from a cache"],
    ["Move to another listing", "Leave the file in the old listing's folder"],
    ["Re-gate (tick or untick)", "Take effect only on the next deploy"],
], [1.7*inch, 4.2*inch]))
A(Spacer(1, 6))
A(para("5.2  The two that are harder than they look", H2))
A(para("<b>Moving a photograph between listings</b> changes its "
       + mono("storage_path") + ", which means a file move and a row update that must "
       "not half-happen. If the move succeeds and the update fails, the listing has a "
       "broken image and the file is an orphan in a folder it does not belong to. It "
       "is one transaction, with the filesystem move last and reversible.", BODY))
A(para("<b>Un-gating a photograph</b> — ticking a gated photo as safe — is a "
       "disclosure that cannot be withdrawn. Anyone who was shown it has it. This is "
       "the one operation that deserves a confirmation naming what is about to become "
       "public, and it is the one most likely to be done by accident while tidying.", BODY))
A(para("5.3  Correcting a mistake", H2))
A(para("The likeliest serious error is a photograph attached to the wrong property: an "
       "investor is looking at a house that is not the one they are buying. The system "
       "should make this cheap to fix and hard to do — which means the assignment step "
       "shows the property's city, type and size next to the photograph, so an obvious "
       "mismatch is obvious.", BODY))

# ================================================================== 6
A(para("6.  Purge: when photographs are destroyed", H1))
A(para("6.1  What triggers it", H2))
A(table([
    hdr(["Trigger", "Urgency", "Scope"]),
    ["Staff removes a photograph", "Routine", "One file"],
    ["Listing sold or withdrawn", "Scheduled", "The listing's set"],
    ["Licence expired or revoked", "Dated in advance", "Everything under that right"],
    ["Takedown demand from a copyright holder", "<b>Hours</b>", "Named files, everywhere"],
    ["Location metadata found after publication", "<b>Immediate</b>", "One file plus its derivatives"],
    ["Duplicate or superseded", "Housekeeping", "One file"],
], [2.35*inch, 1.35*inch, 2.2*inch]))
A(Spacer(1, 6))
A(para("The middle two are the ones that make a purge mechanism worth building. "
       + mono("gov.data_right") + " already records expiry dates and termination "
       "terms; a right that expires with photographs still published is a licence "
       "breach the system created by doing nothing.", BODY))
A(para("6.2  Deletion happens twice", H2))
A(para("<b>Unpublish</b> is immediate and reversible: the row is marked, the "
       "photograph leaves every listing, the authorising route stops serving it. "
       "<b>Destruction</b> is later and final: the file moves to " + mono("purged/")
       + ", waits out a retention window, and then the bytes are removed.", BODY))
A(para("A single-step delete is wrong in both directions. It makes the routine case "
       "unrecoverable — the wrong tick removes a photograph nobody can get back — "
       "while making the urgent case no faster, because the urgent part is stopping "
       "publication, not reclaiming disk.", BODY))
A(para("6.3  A purge is not complete when the file is gone", H2))
A(para("A takedown demand names an image, not a file. Satisfying it means every copy: "
       "the original, the thumbnail, any cache, any CDN edge, and any browser holding "
       "it under a " + mono("Cache-Control") + " header the system set itself. A "
       "one-day cache means a one-day tail, and that has to be a known number rather "
       "than a surprise.", BODY))
A(para("<b>And backups are the honest problem.</b> A photograph purged today is still "
       "in last night's backup, and in the monthly archive, and possibly in an offsite "
       "copy on a different retention schedule. No purge reaches those without "
       "destroying the backup. The policy must state what it does about that — the "
       "usual answer is that backups age out on their own schedule and are not "
       "restored selectively — but it must state it, because &#8220;we deleted it&#8221; "
       "and &#8220;it is gone&#8221; are different claims and only one of them is true.", NOTE))
A(para("6.4  Legal hold beats retention", H2))
A(para("If a property is in dispute, its photographs are evidence and must not be "
       "destroyed on schedule. A hold flag suspends purge and is released deliberately. "
       "Without it, a well-behaved retention job destroys exactly the material somebody "
       "later needs, having done precisely what it was told.", BODY))
A(PageBreak())

# ================================================================== 7
A(para("7.  Maintenance and operations", H1))
A(para("7.1  Reconciliation, nightly", H2))
A(para("The job that keeps the two stores honest. It reports, and does not fix:", BODY))
A(table([
    hdr(["Finding", "Usual cause", "Why not auto-fix"]),
    ["Row with no file", "Interrupted ingest, restore mismatch", "Deleting the row hides a restore that failed"],
    ["File with no row", "Ingest crashed after write", "It may be the only copy of something"],
    ["File in " + mono("purged/") + " past retention", "Normal", "This one <i>is</i> safe to automate"],
    ["Inbox older than a day", "Ingest stopped", "Needs a person to notice"],
    ["Published photo under an expired right", "Licence lapsed", "Unpublishing is a business decision"],
], [1.75*inch, 1.85*inch, 2.3*inch]))
A(Spacer(1, 6))
A(para("A reconciliation report nobody reads is the same as no reconciliation. It "
       "belongs next to the governance banner already on the admin screen, where staff "
       "are looking anyway.", BODY))
A(para("7.2  Backup and restore", H2))
A(para("The filesystem and the database must be restorable to the same moment, or "
       "reconciliation will find hundreds of discrepancies that are really one "
       "mistake. In practice that means the media backup runs immediately after the "
       "database dump, and both are labelled with the same timestamp.", BODY))
A(para("<b>The restore is the thing to rehearse.</b> A media store that has never been "
       "restored is a media store of unknown value, and the moment you find out is the "
       "moment it matters.", NOTE))
A(para("7.3  What clearing disk by hand must look like", H2))
A(para("It will happen. Somebody will be at a full filesystem at an unreasonable hour. "
       "The layout in section 2 is what makes it survivable: " + mono("purged/") +
       " is always safe to empty, " + mono("quarantine/") + " is always safe to empty, "
       + mono("inbox/") + " is a queue and must not be touched, and "
       + mono("store/") + " is never cleared by hand — every file in it is referenced "
       "by a row, and the way to remove one is to purge it.", BODY))
A(para("7.4  Growth", H2))
A(para("Roughly half a megabyte per photograph including its thumbnail, eight "
       "photographs per listing, so about 4 MB per property and 4 GB at a thousand "
       "listings. Not a capacity problem. It becomes one the day somebody uploads "
       "video, which is why the ingest cap and the accepted content types are limits "
       "worth setting deliberately rather than discovering.", BODY))
A(PageBreak())

# ================================================================== 8
A(para("8.  Who may do what", H1))
A(table([
    hdr(["", "Add", "Assign / reorder", "Un-gate", "Unpublish", "Destroy"]),
    ["Admin", "yes", "yes", "yes", "yes", "yes"],
    ["Agent (own listings)", "yes", "yes", "<b>no</b>", "yes", "no"],
    ["Integration / scanner", "yes", "no", "no", "no", "no"],
    ["Investor", "no", "no", "no", "no", "no"],
], [1.75*inch, 0.75*inch, 1.25*inch, 0.75*inch, 0.85*inch, 0.75*inch]))
A(Spacer(1, 6))
A(para("Two deliberate asymmetries. <b>An agent cannot un-gate</b>: releasing a "
       "location-revealing photograph is a disclosure decision about the whole "
       "platform's model, not a listing-level edit. <b>Nobody but an admin destroys "
       "bytes</b>, because destruction is the one action with no undo.", BODY))
A(para("The scanner can create and nothing else. A process that ingests unattended "
       "should not be able to publish, and the fail-closed default in 3.3 is what "
       "makes that true rather than merely intended.", BODY))
A(para("8.1  What must be audited", H2))
A(para("Every event that changes what the public can see: registered, assigned, "
       "published, un-gated, unpublished, purged. Who, when, and from where. A "
       "photograph appearing on a listing is a publication, and a publication with no "
       "record of who authorised it cannot be defended when somebody asks.", BODY))

# ================================================================== 9
A(para("9.  What exists today", H1))
A(para("So this document is not mistaken for a status report.", BODY))
A(table([
    hdr(["Capability", "Today"]),
    [mono("core.property_media") + " with the gate", "<b>Built.</b> Row policy, " + mono("reveals_location") + ", enforced by RLS"],
    [mono("thumb_url") + " and the thumbnail split", "<b>Built.</b> Cards use the small file, detail uses the full one"],
    ["Photographs on listings", "<b>Built,</b> from files committed to the repository"],
    ["Provenance recorded", "<b>Built,</b> as " + mono("STOCK-PHOTOGRAPHY") + " — and <b>unreviewed</b>, source unestablished"],
    ["Shared mount", "<b>Built.</b> A host path, not a named volume — " + mono("down -v") + " must not destroy photographs"],
    ["Authorising route", "<b>Built.</b> " + mono("/media/file/&lt;media_id&gt;") + " re-asks the database as the caller; not visible is a 404, not a 403"],
    ["Ingest, EXIF stripping, quarantine", "<b>Built.</b> " + mono("scan-media.js") + ", with a test asserting GPS is gone from the stored bytes"],
    ["Pending on arrival, gated by default", "<b>Built.</b> Nothing is published by arriving"],
    ["Unpublish, purge, retention, legal hold", "<b>Built.</b> Two-step deletion; a hold beats a due retention date"],
    ["Reconciliation", "<b>Built.</b> Reports both drift directions, fixes neither"],
    ["Media audit trail", "<b>Built.</b> " + mono("core.media_event")],
    ["The properties panel", "<b>Not built.</b> The operations exist as API functions; there is no screen"],
    ["Self-describing folders, " + mono("_unsorted") + " triage", "<b>Partly.</b> " + mono("_unsorted") + " is counted and reported; nothing creates the folders"],
    ["Browser upload", "<b>Not built.</b> The share is the only way in"],
], [2.3*inch, 3.6*inch]))
A(Spacer(1, 8))
A(para("<b>Note what is still true of the seeded images.</b> The twenty-five "
       "photographs committed to the repository are still served statically from "
       + mono("web/public/assets") + ", by path, to anyone who guesses one. That is "
       "acceptable only because they are representative stock images with nothing to "
       "leak. Anything genuinely location-revealing has to arrive through the store, "
       "where the route decides who gets bytes — and the seeded set should move "
       "there before it is mistaken for a pattern to follow.", NOTE))
A(Spacer(1, 8))
A(para("9.1  Suggested order", H2))
A(table([
    hdr(["Step", "Delivers", "Unblocks"]),
    ["1", "Mount, store layout, authorising route, ingest with EXIF stripping", "<b>Done.</b> Real photography can exist at all"],
    ["4", "Unpublish, purge, retention, legal hold, reconciliation", "<b>Done.</b> The obligations in sections 6 and 7"],
    ["2", "The properties panel: assign, KEY image, gate, publish", "<b>Next.</b> Staff stop needing a developer"],
    ["3", "Self-describing folders, " + mono("_unsorted") + " triage", "Bulk drops from a PC"],
], [0.5*inch, 3.2*inch, 2.2*inch]))
A(Spacer(1, 10))
A(para("Step 4 came early rather than last because its pieces — two-step deletion, "
       "retention, legal hold — are cheap to write alongside the schema and "
       "expensive to retrofit onto a store already holding a year of photographs under "
       "rules it was not built for.", BODY))
A(para("<b>Step 2 is the gap that matters now.</b> Every operation a person needs "
       "exists as a callable function with its authorisation enforced in the database, "
       "and there is no screen that calls them. Until there is, publishing a photograph "
       "means somebody at a psql prompt — which is the situation the store was "
       "built to end.", NOTE))
A(Spacer(1, 10))
A(para("Requirements as of " + mono("v" + VERSION) + ". Regenerate after either the "
       "requirements or the build changes: "
       + mono("python3 docs/generate_media_lifecycle.py") + ".", CAP))

doc.multiBuild(E)
print("wrote", OUT)
