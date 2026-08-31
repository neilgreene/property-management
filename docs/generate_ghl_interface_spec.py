#!/usr/bin/env python3
"""
Generates the GoHighLevel Interface Specification PDF.

Every endpoint, scope, header, object field and webhook event name in this
document was extracted from GoHighLevel's official OpenAPI source repository:
    https://github.com/GoHighLevel/highlevel-api-docs
Regenerate with:  python3 docs/generate_ghl_interface_spec.py
"""

from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER
from reportlab.lib.pagesizes import LETTER
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import inch
from reportlab.platypus import (
    BaseDocTemplate, Frame, PageBreak, PageTemplate, Paragraph, Preformatted,
    Spacer, Table, TableStyle,
)

OUT = "docs/GHL-Interface-Specification.pdf"

INK     = colors.HexColor("#12161C")
MUTED   = colors.HexColor("#5A6572")
ACCENT  = colors.HexColor("#1F5FA9")
WARN    = colors.HexColor("#A8410E")
RULE    = colors.HexColor("#D4D9E0")
BAND    = colors.HexColor("#EEF2F7")
CODE_BG = colors.HexColor("#F5F7FA")
RISK_BG = colors.HexColor("#FDF3EC")

ss = getSampleStyleSheet()
def S(n, parent=None, **kw): return ParagraphStyle(n, parent=parent or ss["Normal"], **kw)

BODY   = S("body", fontName="Helvetica", fontSize=9.5, leading=13.6, textColor=INK, spaceAfter=7)
H1     = S("h1", fontName="Helvetica-Bold", fontSize=15, leading=19, textColor=INK, spaceBefore=16, spaceAfter=8)
H2     = S("h2", fontName="Helvetica-Bold", fontSize=11, leading=15, textColor=ACCENT, spaceBefore=12, spaceAfter=5)
BULLET = S("bullet", parent=BODY, leftIndent=13, bulletIndent=3, spaceAfter=3.5)
CODE   = S("code", fontName="Courier", fontSize=7.9, leading=10.4, textColor=INK,
           backColor=CODE_BG, borderPadding=6, leftIndent=3, spaceAfter=8)
CELL   = S("cell", fontName="Helvetica", fontSize=8, leading=10.8, textColor=INK)
CELLB  = S("cellb", parent=CELL, fontName="Helvetica-Bold")
CELLC  = S("cellc", parent=CELL, fontName="Courier", fontSize=7.6, leading=10.2)
CAP    = S("cap", fontName="Helvetica-Oblique", fontSize=8, leading=11, textColor=MUTED, spaceAfter=9)
NOTE   = S("note", parent=BODY, leftIndent=9, textColor=WARN, fontName="Helvetica-Bold",
           fontSize=9, leading=13)
RISK   = S("risk", fontName="Helvetica", fontSize=9, leading=12.8, textColor=INK,
           backColor=RISK_BG, borderPadding=7, borderColor=WARN, borderWidth=0.7,
           spaceAfter=9, spaceBefore=3)
COVER_T = S("ct", fontName="Helvetica-Bold", fontSize=25, leading=30, textColor=INK,
            alignment=TA_CENTER, spaceAfter=10)
COVER_S = S("cs", fontName="Helvetica", fontSize=12.5, leading=17, textColor=MUTED,
            alignment=TA_CENTER, spaceAfter=5)


def para(t, s=BODY): return Paragraph(t, s)
def mono(t):         return f"<font face='Courier'>{t}</font>"
def hdr(cells):      return [Paragraph(c, CELLB) for c in cells]
def bullets(items):  return [Paragraph(f"•&nbsp;&nbsp;{i}", BULLET) for i in items]


def table(rows, widths, header=True, zebra=True):
    data = [[c if hasattr(c, "wrap") else Paragraph(str(c), CELL) for c in r] for r in rows]
    t = Table(data, colWidths=widths, repeatRows=1 if header else 0, hAlign="LEFT")
    cmds = [("VALIGN", (0, 0), (-1, -1), "TOP"),
            ("TOPPADDING", (0, 0), (-1, -1), 4.5),
            ("BOTTOMPADDING", (0, 0), (-1, -1), 4.5),
            ("LEFTPADDING", (0, 0), (-1, -1), 6),
            ("RIGHTPADDING", (0, 0), (-1, -1), 6),
            ("LINEBELOW", (0, 0), (-1, -2), 0.4, RULE),
            ("BOX", (0, 0), (-1, -1), 0.6, RULE)]
    if header:
        cmds += [("BACKGROUND", (0, 0), (-1, 0), BAND),
                 ("LINEBELOW", (0, 0), (-1, 0), 0.9, ACCENT)]
    if zebra:
        st = 1 if header else 0
        for i in range(st, len(data)):
            if (i - st) % 2 == 1:
                cmds.append(("BACKGROUND", (0, i), (-1, i), colors.HexColor("#FAFBFC")))
    t.setStyle(TableStyle(cmds))
    return t


def decorate(canvas, doc):
    canvas.saveState()
    w, h = LETTER
    if doc.page > 1:
        canvas.setFont("Helvetica", 7.5); canvas.setFillColor(MUTED)
        canvas.drawString(0.9 * inch, h - 0.62 * inch, "GoHighLevel Interface Specification")
        canvas.drawRightString(w - 0.9 * inch, h - 0.62 * inch, "Investment Property Marketplace")
        canvas.setStrokeColor(RULE); canvas.setLineWidth(0.5)
        canvas.line(0.9 * inch, h - 0.72 * inch, w - 0.9 * inch, h - 0.72 * inch)
        canvas.line(0.9 * inch, 0.72 * inch, w - 0.9 * inch, 0.72 * inch)
        canvas.setFont("Helvetica", 7.5)
        canvas.drawCentredString(w / 2.0, 0.55 * inch, f"Page {doc.page}")
        canvas.drawString(0.9 * inch, 0.55 * inch, "GHL API v2  |  Version: 2021-07-28")
        canvas.drawRightString(w - 0.9 * inch, 0.55 * inch, "Internal engineering document")
    canvas.restoreState()


doc = BaseDocTemplate(OUT, pagesize=LETTER,
                      leftMargin=0.9 * inch, rightMargin=0.9 * inch,
                      topMargin=0.92 * inch, bottomMargin=0.92 * inch,
                      title="GoHighLevel Interface Specification",
                      author="Investment Property Marketplace",
                      subject="Integration interface to GoHighLevel CRM API v2")
doc.addPageTemplates([PageTemplate(id="main", onPage=decorate, frames=[
    Frame(doc.leftMargin, doc.bottomMargin, doc.width, doc.height, id="f")])])

E = []; A = E.append

# ------------------------------------------------------------------ cover
A(Spacer(1, 1.3 * inch))
A(para("GoHighLevel Interface Specification", COVER_T))
A(para("API, Data Exchange and Integration Architecture", COVER_S))
A(para("Investment Property Marketplace &mdash; EspoCRM Replacement Programme", COVER_S))
A(Spacer(1, 0.26 * inch))
A(table([
    ["Document type", "Integration interface specification"],
    ["Target system", "GoHighLevel (HighLevel) CRM &mdash; Public API v2"],
    ["API base URL", mono("https://services.leadconnectorhq.com")],
    ["Required version header", mono("Version: 2021-07-28")],
    ["Companion system", "PostgreSQL 16 (migration staging and system of record)"],
    ["Deployment scope", "Local development and testing only; no internet exposure"],
    ["Status", "Draft for review"],
], [1.85 * inch, 4.05 * inch], header=False))
A(Spacer(1, 0.26 * inch))
A(para(
    "Every endpoint path, HTTP method, OAuth scope, request header, object field and "
    "webhook event name in this document was read directly from GoHighLevel's official "
    "OpenAPI source specifications at <b>github.com/GoHighLevel/highlevel-api-docs</b>. "
    "Nothing here is reproduced from marketing material or recollection. Where a "
    "behaviour could not be verified against those specifications it is explicitly "
    "flagged as unverified rather than asserted.", CAP))
A(PageBreak())

# --------------------------------------------------------------- 1 purpose
A(para("1.  Purpose and Scope", H1))
A(para(
    "This document defines the programmatic interface between GoHighLevel and the "
    "systems around it for a private investment property marketplace: properties as the "
    "core entity, linked to investors, agents and lenders, with a gated portal behind a "
    "platform fee agreement.", BODY))
A(para(
    "It is written to answer three questions precisely: what GHL's API can and cannot "
    "do, how transactional and relational data moves in each direction, and which parts "
    "of the intended design are constrained by the platform.", BODY))

A(para("1.1  In scope", H2))
A(table([
    hdr(["Area", "Covered"]),
    ["Authentication", "OAuth 2.0 authorization code flow and Private Integration Tokens"],
    ["Transport", "Base URL, required headers, content types, pagination, rate limits"],
    ["Data model", "Custom objects, associations, contacts, opportunities"],
    ["Transactional", "Invoices, payments, orders, subscriptions, transactions"],
    ["Events", "Webhook catalogue, signature verification, replay defence"],
    ["Migration", "EspoCRM to GHL relational load ordering and staging schema"],
    ["Constraints", "Platform limits that materially affect the intended architecture"],
], [1.35 * inch, 4.55 * inch]))

A(para("1.2  Out of scope", H2))
A(table([
    hdr(["Area", "Reason"]),
    ["Internet exposure, tunnels, TLS termination", "Explicitly deferred; local-only in this phase"],
    ["Second brand rollout", "Separate future phase, not part of this project"],
    ["GHL v1 (API-key) endpoints", "Legacy; absent from the current v2 specification"],
    ["Marketplace app listing and billing", "Not required for a single-tenant integration"],
], [2.55 * inch, 3.35 * inch]))

# --------------------------------------------------------------- 2 model
A(para("2.  Domain Model Mapping", H1))
A(para(
    "GHL is contact-centric by design. An entity-centric marketplace, where the primary "
    "object is a property rather than a person, is achievable through Custom Objects, "
    "but the mapping is not free of friction and should be understood before build.", BODY))
A(table([
    hdr(["Domain entity", "GHL representation", "API surface"]),
    ["Property / listing", "Custom Object record", mono("/objects/{schemaKey}/records")],
    ["Investor", "Contact", mono("/contacts/upsert")],
    ["Agent", "User, or Contact with role tag", mono("/users/") + ", <font face='Courier'>/contacts/</font>"],
    ["Lender", "Contact with role tag", mono("/contacts/upsert")],
    ["Deal / transaction pipeline", "Opportunity in a Pipeline", mono("/opportunities/upsert")],
    ["Property &rarr; Investor link", "Association / Relation", mono("/associations/relations")],
    ["Platform fee agreement", "Invoice plus e-signature document", mono("/invoices/")],
    ["Fee payment", "Transaction (read-only)", mono("/payments/transactions")],
    ["Saved property", "Association or contact custom field", mono("/associations/relations")],
], [1.55 * inch, 2.25 * inch, 2.1 * inch]))

A(para("2.1  Custom Objects and Associations", H2))
A(table([
    hdr(["Method", "Path", "Purpose"]),
    ["GET/POST", mono("/objects/"), "List or create object schemas"],
    ["GET/PUT", mono("/objects/{key}"), "Read or update a schema"],
    ["POST", mono("/objects/{schemaKey}/records"), "Create a record"],
    ["GET/PUT/DELETE", mono("/objects/{schemaKey}/records/{id}"), "Read, update, delete a record"],
    ["POST", mono("/objects/{schemaKey}/records/search"), "Search records &mdash; the marketplace query primitive"],
    ["POST/GET", mono("/associations/"), "Define association types between objects"],
    ["POST", mono("/associations/relations"), "Create a relation between two records"],
    ["GET", mono("/associations/relations/{recordId}"), "List relations for a record"],
    ["DELETE", mono("/associations/relations/{relationId}"), "Remove a relation"],
], [1.15 * inch, 2.75 * inch, 2.0 * inch]))
A(Spacer(1, 5))
A(para(
    "Associations are the mechanism that preserves the relational integrity of an "
    "EspoCRM migration. They are created as a discrete second pass after both sides of "
    "the relationship exist, which dictates the load ordering in section 8.", BODY))

A(para("2.2  Opportunities (deal pipelines)", H2))
A(table([
    hdr(["Method", "Path", "Purpose"]),
    ["POST", mono("/opportunities/"), "Create opportunity"],
    ["POST", mono("/opportunities/upsert"), "Idempotent create-or-update; preferred for sync"],
    ["GET/PUT/DELETE", mono("/opportunities/{id}"), "Read, update, delete"],
    ["PUT", mono("/opportunities/{id}/status"), "Advance or close a deal"],
    ["GET/POST", mono("/opportunities/search"), "Query across pipelines"],
    ["GET", mono("/opportunities/pipelines"), "List pipelines and stages"],
    ["GET", mono("/opportunities/lost-reason"), "Loss reason taxonomy"],
    ["POST/DELETE", mono("/opportunities/{id}/followers"), "Assign watchers, e.g. agent or lender"],
], [1.15 * inch, 2.55 * inch, 2.2 * inch]))
A(PageBreak())

# --------------------------------------------------------------- 3 transport
A(para("3.  Transport and Versioning", H1))
A(table([
    hdr(["Property", "Value"]),
    ["Base URL", mono("https://services.leadconnectorhq.com")],
    ["Protocol", "REST over HTTPS, JSON request and response bodies"],
    ["Version header", mono("Version: 2021-07-28")],
    ["Authorization header", mono("Authorization: Bearer &lt;token&gt;")],
    ["Token format", "JWT bearer"],
    ["Token endpoint content type", mono("application/x-www-form-urlencoded")],
    ["Pagination", mono("limit") + " and <font face='Courier'>offset</font> query parameters"],
], [1.85 * inch, 4.05 * inch]))
A(Spacer(1, 5))
A(para(
    "The Version header is not advisory. In the OpenAPI specification it is a required "
    "header parameter with a single-value enum of "
    "<font face='Courier'>2021-07-28</font>; requests omitting it are rejected. Set it "
    "once in a shared HTTP client rather than at each call site.", NOTE))
A(Preformatted(
    "GET /payments/transactions?altId=<locationId>&altType=location&limit=100&offset=0\n"
    "Host: services.leadconnectorhq.com\n"
    "Authorization: Bearer <access_token>\n"
    "Version: 2021-07-28\n"
    "Accept: application/json",
    CODE))

# --------------------------------------------------------------- 4 auth
A(para("4.  Authentication", H1))
A(para("Two credential types are accepted. Both are presented as a bearer token; they "
       "differ in acquisition and maintenance.", BODY))

A(para("4.1  Option A &mdash; Private Integration Token (recommended for this phase)", H2))
A(para(
    "A static, long-lived token issued per sub-account from the GHL interface. The "
    "OpenAPI security schemes accept it wherever a sub-account OAuth token is accepted: "
    "<i>&ldquo;Use the Access Token generated with user type as Sub-Account (OR) Private "
    "Integration Token of Sub-Account.&rdquo;</i>", BODY))
for b in bullets([
    "No authorization redirect and no callback URL, therefore no inbound HTTP requirement.",
    "No refresh loop and no token rotation state to persist.",
    "Scoped to a single sub-account, which matches a single-brand deployment.",
    "Directly compatible with local-only development, since nothing must be reachable from the internet.",
]): A(b)
A(Spacer(1, 3))
A(para(
    "This is the correct choice for the current phase. Moving to OAuth later changes "
    "credential acquisition only; every downstream request is unchanged.", NOTE))

A(para("4.2  Option B &mdash; OAuth 2.0 Authorization Code", H2))
A(para("Required only if the integration is distributed as a Marketplace app serving "
       "multiple agencies or sub-accounts.", BODY))
A(table([
    hdr(["Step", "Endpoint"]),
    ["1. Authorize", mono("https://marketplace.gohighlevel.com/v2/oauth/chooselocation")
     + "<br/>Alternate host: <font face='Courier'>marketplace.leadconnectorhq.com</font>"],
    ["2. Exchange code", mono("POST /oauth/token") + " &mdash; form-encoded body"],
    ["3. Refresh", mono("POST /oauth/token") + " with <font face='Courier'>grant_type=refresh_token</font>"],
    ["4. Agency to location", mono("POST /oauth/locationToken")],
    ["5. Discover installs", mono("GET /oauth/installedLocations")],
], [1.35 * inch, 4.55 * inch]))
A(Spacer(1, 5))
A(para("Token request fields", H2))
A(table([
    hdr(["Field", "Required", "Notes"]),
    [mono("client_id"), "Yes", "Issued by GHL"],
    [mono("client_secret"), "Yes", "Issued by GHL"],
    [mono("grant_type"), "Yes", mono("authorization_code") + " | <font face='Courier'>refresh_token</font> | <font face='Courier'>client_credentials</font>"],
    [mono("code"), "Conditional", "Authorization code exchange"],
    [mono("refresh_token"), "Conditional", "Refresh calls"],
    [mono("user_type"), "Conditional", mono("Company") + " (agency) or <font face='Courier'>Location</font> (sub-account)"],
    [mono("redirect_uri"), "Conditional", "Must match the registered callback"],
], [1.3 * inch, 0.85 * inch, 3.75 * inch]))
A(Spacer(1, 5))
A(para(
    "Access tokens are valid for approximately 24 hours. Refresh tokens rotate: each "
    "refresh returns a new access token and a new refresh token, and the previous "
    "refresh token is spent. Persist both atomically or the integration will lock "
    "itself out.", NOTE))

A(para("4.3  Scopes relevant to this build", H2))
A(table([
    hdr(["Scope", "Grants"]),
    [mono("payments/transactions.readonly"), "List and read transactions"],
    [mono("payments/orders.readonly"), "List and read orders and fulfillments"],
    [mono("payments/orders.collectPayment"), "Record a payment against an order"],
    [mono("payments/subscriptions.readonly"), "List and read subscriptions"],
    [mono("payments/custom-provider.write"), "Register and configure a custom payment provider"],
    [mono("invoices.readonly") + " / " + mono("invoices.write"), "Read; create, update, send, void, record payment"],
    [mono("invoices/schedule.write"), "Create and manage recurring schedules"],
    [mono("invoices/estimate.write"), "Manage estimates and convert to invoice"],
], [2.6 * inch, 3.3 * inch]))
A(PageBreak())

# --------------------------------------------------------------- 5 limits
A(para("5.  Rate Limits", H1))
A(table([
    hdr(["Limit", "Value", "Granularity"]),
    ["Burst", "100 requests / 10 seconds", "Per app (client), per Location or Company"],
    ["Daily", "200,000 requests / day", "Per app (client), per Location or Company"],
], [1.0 * inch, 1.9 * inch, 3.0 * inch]))
A(Spacer(1, 5))
A(table([
    hdr(["Response header", "Meaning"]),
    [mono("X-RateLimit-Max"), "Maximum requests in the burst interval"],
    [mono("X-RateLimit-Interval-Milliseconds"), "Burst interval width"],
    [mono("X-RateLimit-Limit-Daily"), "Daily ceiling"],
    [mono("X-RateLimit-Daily-Remaining"), "Requests remaining today"],
], [2.6 * inch, 3.3 * inch]))
A(Spacer(1, 6))
A(para(
    "These limits are comfortable for back-office automation and hostile to a "
    "browser-driven public marketplace. A listing page that queries GHL once per visitor "
    "shares a single 100-request / 10-second budget across <i>all</i> concurrent "
    "visitors, because the limit is per application per location, not per user. Thirty "
    "simultaneous visitors each triggering four calls will exhaust the burst window.", BODY))
A(para(
    "The mitigation is architectural, not incidental: property data must be cached in a "
    "datastore the front end can query freely, with GHL as the source that populates "
    "that cache through webhooks and periodic sync. This is the primary technical reason "
    "the PostgreSQL layer in section 8 exists.", NOTE))

# --------------------------------------------------------------- 6 payments
A(para("6.  Transactional Endpoints", H1))
A(para(
    "The single most important structural fact about this API is asymmetry: "
    "<b>transactions and subscriptions are read-only</b>. No endpoint creates a "
    "transaction. Money enters GHL only through an invoice, an order payment record, or "
    "a registered custom payment provider.", NOTE))

A(para("6.1  Payments", H2))
A(table([
    hdr(["Method", "Path", "Scope"]),
    ["GET", mono("/payments/transactions"), mono("payments/transactions.readonly")],
    ["GET", mono("/payments/transactions/{transactionId}"), mono("payments/transactions.readonly")],
    ["GET", mono("/payments/orders"), mono("payments/orders.readonly")],
    ["GET", mono("/payments/orders/{orderId}"), mono("payments/orders.readonly")],
    ["POST", mono("/payments/orders/{orderId}/record-payment"), mono("payments/orders.collectPayment")],
    ["GET/POST", mono("/payments/orders/{orderId}/fulfillments"), mono("payments/orders.*")],
    ["GET", mono("/payments/subscriptions"), mono("payments/subscriptions.readonly")],
    ["GET", mono("/payments/subscriptions/{subscriptionId}"), mono("payments/subscriptions.readonly")],
    ["POST", mono("/payments/custom-provider/provider"), mono("payments/custom-provider.write")],
], [0.68 * inch, 3.02 * inch, 2.2 * inch]))

A(para("6.2  Invoices &mdash; the platform fee mechanism", H2))
A(para("The platform fee agreement is billed here. Estimates and recurring schedules "
       "cover advisory and premium service tiers if those are introduced later.", BODY))
A(table([
    hdr(["Method", "Path", "Purpose"]),
    ["POST / GET", mono("/invoices/"), "Create invoice; list invoices"],
    ["GET/PUT/DELETE", mono("/invoices/{invoiceId}"), "Read, update, delete"],
    ["POST", mono("/invoices/{invoiceId}/send"), "Deliver invoice to the investor"],
    ["POST", mono("/invoices/{invoiceId}/void"), "Void invoice"],
    ["POST", mono("/invoices/{invoiceId}/record-payment"), "Record an offline payment"],
    ["POST", mono("/invoices/text2pay"), "Create and send a pay-by-link invoice"],
    ["GET", mono("/invoices/generate-invoice-number"), "Reserve the next invoice number"],
    ["POST/GET/PUT/DELETE", mono("/invoices/schedule/..."), "Recurring schedules, auto-payment, cancel"],
    ["POST/GET/PUT/DELETE", mono("/invoices/estimate/..."), "Estimates; convert estimate to invoice"],
    ["POST/GET/PUT/DELETE", mono("/invoices/template/..."), "Invoice templates and fee configuration"],
], [1.4 * inch, 2.6 * inch, 1.9 * inch]))

# --------------------------------------------------------------- 7 txn obj
A(para("7.  The Transaction Object", H1))
A(para("Returned by <font face='Courier'>GET /payments/transactions/{transactionId}</font> "
       "and in list form by <font face='Courier'>GET /payments/transactions</font>.", BODY))
A(table([
    hdr(["Field", "Notes"]),
    [mono("_id"), "GHL transaction identifier; natural primary key for the landing table"],
    [mono("altId") + " / " + mono("altType"), "Scope; " + "<font face='Courier'>altType</font> is normally <font face='Courier'>location</font>"],
    [mono("contactId") + " / " + mono("contactSnapshot"), "Links the payment to an investor, with denormalised state"],
    [mono("amount") + " / " + mono("currency"), "Settlement amount; store as integer minor units"],
    [mono("amountRefunded"), "Non-zero indicates partial or full refund"],
    [mono("status"), "Settlement state"],
    [mono("liveMode") + " / " + mono("markAsTest"), "Separates live money from test traffic; always filter on this"],
    [mono("entityType") + " / " + mono("entityId") + " / " + mono("entitySource"), "What produced the transaction (invoice, order, funnel)"],
    [mono("invoiceId"), "Set when the transaction settles an invoice; primary join key"],
    [mono("subscriptionId"), "Set for recurring charges"],
    [mono("chargeId") + " / " + mono("chargeSnapshot") + " / " + mono("paymentProvider"), "Processor reference and identity"],
    [mono("receiptId"), "Receipt reference for investor-facing records"],
    [mono("qboSynced") + " / " + mono("qboResponse"), "QuickBooks sync state already modelled by GHL"],
    [mono("createdAt") + " / " + mono("updatedAt"), "Timestamps; drive incremental polling from these"],
    [mono("ipAddress") + ", " + mono("meta") + ", " + mono("traceId") + ", " + mono("createdBy"), "Provenance, metadata and audit lineage"],
], [2.0 * inch, 3.9 * inch]))
A(Spacer(1, 5))
A(para("List endpoint filters", H2))
A(table([
    hdr(["Parameter", "Required", "Notes"]),
    [mono("altId") + " / " + mono("altType"), "Yes", "Location id; " + "<font face='Courier'>location</font>"],
    [mono("contactId"), "No", "Filter to one investor"],
    [mono("subscriptionId") + " / " + mono("entityId"), "No", "Filter to a recurring agreement or source entity"],
    [mono("entitySourceType") + " / " + mono("entitySourceSubType"), "No", "e.g. funnel, two_step_order_form"],
    [mono("paymentMode"), "No", mono("live") + " or test"],
    [mono("startAt") + " / " + mono("endAt"), "No", "Date range, e.g. " + "<font face='Courier'>2026-02-01</font>"],
    [mono("search"), "No", "Free-text match"],
    [mono("limit") + " / " + mono("offset"), "No", "Defaults 10 / 0; use 100 for backfill"],
], [2.0 * inch, 0.7 * inch, 3.2 * inch]))
A(PageBreak())

# --------------------------------------------------------------- 8 webhooks
A(para("8.  Webhooks", H1))
A(para("GHL publishes <b>58 event types</b>. Events are the primary mechanism for keeping "
       "an external datastore current; polling exists for backfill and reconciliation.", BODY))

A(para("8.1  Events relevant to this build", H2))
A(table([
    hdr(["Event", "Use"]),
    [mono("InvoicePaid"), "Platform fee settled; unlock gated portal access"],
    [mono("InvoicePartiallyPaid"), "Partial settlement; hold the gate and flag for follow-up"],
    [mono("InvoiceSent") + " / " + mono("InvoiceVoid"), "Fee agreement delivered; obligation reversed"],
    [mono("InvoiceCreate/Update/Delete"), "Keep the invoice mirror in step"],
    [mono("OrderCreate") + " / " + mono("OrderStatusUpdate"), "Non-invoice purchases"],
    [mono("RecordCreate/Update/Delete"), "Property custom object changes; refresh the listing cache"],
    [mono("AssociationCreate/Update/Delete"), "Property to investor, agent or lender links change"],
    [mono("RelationCreate/Delete"), "Individual relation changes"],
    [mono("ContactCreate/Update/Delete"), "Investor identity changes"],
    [mono("ContactTagUpdate"), "Gate state changes, e.g. Fee_Agreement_Signed"],
    [mono("Opportunity*"), "Deal stage, status, owner and value changes"],
    [mono("InboundMessage") + " / " + mono("OutboundMessage"), "Unified conversation timeline"],
], [2.5 * inch, 3.4 * inch]))
A(Spacer(1, 4))
A(para(
    "Remaining events cover appointments, tasks, notes, products, prices, object schema "
    "changes, email statistics, users, locations and app lifecycle "
    "(<font face='Courier'>AppInstall</font>, <font face='Courier'>AppUninstall</font>, "
    "<font face='Courier'>PlanChange</font>).", BODY))

A(para("8.2  Signature verification &mdash; asymmetric, not a shared secret", H2))
A(para(
    "This is the detail most integrations get wrong. GHL does not sign webhooks with an "
    "HMAC shared secret. It signs with an RSA private key and publishes the "
    "corresponding public key. The receiver verifies the "
    "<font face='Courier'>x-wh-signature</font> header against the raw request body "
    "using that public key.", NOTE))
A(table([
    hdr(["Element", "Detail"]),
    ["Header", mono("x-wh-signature")],
    ["Verification input", "The raw, unparsed request body. Never re-serialise the JSON first."],
    ["Key", "GHL-published RSA public key (PEM, SPKI)"],
    ["Payload fields", mono("timestamp") + ", " + mono("webhookId") + ", plus event data"],
    ["Replay window", "Reject if " + "<font face='Courier'>timestamp</font> is outside roughly 5 minutes"],
    ["Idempotency", "Reject duplicate " + "<font face='Courier'>webhookId</font> values"],
    ["Key rotation", "GHL rotates the key on notice; keep it configurable, never hard-coded"],
], [1.4 * inch, 4.5 * inch]))
A(Spacer(1, 5))
A(Preformatted(
    "from cryptography.hazmat.primitives import hashes, serialization\n"
    "from cryptography.hazmat.primitives.asymmetric import padding\n"
    "from cryptography.exceptions import InvalidSignature\n"
    "import base64, json, datetime\n\n"
    "PUBLIC_KEY = serialization.load_pem_public_key(GHL_WEBHOOK_PUBLIC_KEY_PEM)\n\n"
    "def verify(raw_body: bytes, signature_b64: str) -> bool:\n"
    "    try:\n"
    "        PUBLIC_KEY.verify(\n"
    "            base64.b64decode(signature_b64),\n"
    "            raw_body,                     # RAW bytes, never json.dumps(parsed)\n"
    "            padding.PKCS1v15(),\n"
    "            hashes.SHA256(),\n"
    "        )\n"
    "        return True\n"
    "    except InvalidSignature:\n"
    "        return False\n\n"
    "def handle(raw_body, headers):\n"
    "    if not verify(raw_body, headers['x-wh-signature']):\n"
    "        return 401\n"
    "    evt = json.loads(raw_body)\n"
    "    if abs((now_utc() - parse(evt['timestamp'])).total_seconds()) > 300:\n"
    "        return 400                        # replay window exceeded\n"
    "    if already_seen(evt['webhookId']):\n"
    "        return 200                        # idempotent no-op\n"
    "    enqueue(evt)                          # ack fast, process asynchronously\n"
    "    return 200",
    CODE))
A(para(
    "The exact signature algorithm and padding are not stated in the published "
    "documentation. PKCS#1 v1.5 with SHA-256 is the conventional pairing for this key "
    "format and is the recommended first implementation, but it must be confirmed "
    "against a captured live webhook before the receiver is trusted. This is open item 1 "
    "in section 12.", NOTE))
A(PageBreak())

# --------------------------------------------------------------- 9 sync
A(para("9.  Migration and Synchronisation Design", H1))
A(para("9.1  EspoCRM to GHL load ordering", H2))
A(para(
    "GHL has no transactional import. Relational integrity is preserved by ordering the "
    "load and creating associations as a separate pass once both endpoints of each "
    "relationship exist. Staging the extract in PostgreSQL first makes the load "
    "restartable and auditable, which a direct CSV or script-to-API load is not.", BODY))
A(table([
    hdr(["Pass", "Action", "Endpoint"]),
    ["0", "Extract EspoCRM to PostgreSQL staging tables; assign stable external keys", "&mdash;"],
    ["1", "Create custom object schemas (Property, and any others)", mono("POST /objects/")],
    ["2", "Define association types between schemas and contacts", mono("POST /associations/")],
    ["3", "Load investors, agents and lenders as contacts", mono("POST /contacts/upsert")],
    ["4", "Load property records", mono("POST /objects/{schemaKey}/records")],
    ["5", "Create relations linking properties to contacts", mono("POST /associations/relations")],
    ["6", "Load deals into pipelines", mono("POST /opportunities/upsert")],
    ["7", "Reconcile: re-read counts and spot-check relations against staging", mono("/records/search")],
], [0.4 * inch, 3.3 * inch, 2.2 * inch]))
A(Spacer(1, 5))
A(para(
    "Record every GHL id returned in pass 3 to 6 back into the staging tables as the "
    "load proceeds. Without that id map, pass 5 cannot be built and a failed load cannot "
    "be resumed without duplicating records.", NOTE))

A(para("9.2  Ongoing synchronisation", H2))
A(table([
    hdr(["Path", "Mechanism", "Cadence", "Purpose"]),
    ["Primary", "Webhook events", "Real time", "State changes in both directions"],
    ["Backfill", mono("/payments/transactions") + ", <font face='Courier'>/records/search</font>", "One-off", "Historical load at go-live"],
    ["Reconciliation", mono("startAt") + " / <font face='Courier'>endAt</font> sweep", "Nightly", "Catch missed or out-of-order events"],
    ["Repair", mono("/payments/transactions/{id}"), "On demand", "Resolve a specific discrepancy"],
], [1.05 * inch, 2.05 * inch, 0.85 * inch, 1.95 * inch]))
A(Spacer(1, 4))
A(para(
    "Webhook delivery is not exactly-once and not ordered. The nightly reconciliation "
    "sweep is not optional: it is what makes the data trustworthy. Compare a trailing "
    "window against the landing tables and raise a discrepancy report rather than "
    "silently overwriting.", BODY))

A(para("9.3  PostgreSQL staging and landing schema", H2))
A(Preformatted(
    "-- Identity bridge. Written during migration, read forever after.\n"
    "CREATE TABLE ghl_id_map (\n"
    "    entity_type   text NOT NULL,        -- 'property' | 'investor' | 'agent' | 'deal'\n"
    "    source_id     text NOT NULL,        -- EspoCRM primary key\n"
    "    ghl_id        text NOT NULL,\n"
    "    ghl_object    text NOT NULL,        -- 'record' | 'contact' | 'opportunity'\n"
    "    location_id   text NOT NULL,\n"
    "    migrated_at   timestamptz NOT NULL DEFAULT now(),\n"
    "    PRIMARY KEY (entity_type, source_id, location_id),\n"
    "    UNIQUE (ghl_id, location_id)\n"
    ");\n\n"
    "-- Append-only event log: the dedupe and audit backbone.\n"
    "CREATE TABLE ghl_webhook_event (\n"
    "    webhook_id   text PRIMARY KEY,      -- payload webhookId\n"
    "    event_type   text        NOT NULL,\n"
    "    occurred_at  timestamptz NOT NULL,  -- payload timestamp\n"
    "    received_at  timestamptz NOT NULL DEFAULT now(),\n"
    "    processed_at timestamptz,\n"
    "    signature_ok boolean     NOT NULL,\n"
    "    payload      jsonb       NOT NULL\n"
    ");\n"
    "CREATE INDEX ON ghl_webhook_event (event_type, occurred_at DESC);\n"
    "CREATE INDEX ON ghl_webhook_event (processed_at) WHERE processed_at IS NULL;\n\n"
    "-- Read model for the public marketplace. Avoids per-visitor GHL calls (sec. 5).\n"
    "CREATE TABLE property_listing (\n"
    "    ghl_record_id  text PRIMARY KEY,\n"
    "    location_id    text        NOT NULL,\n"
    "    status         text        NOT NULL,   -- active | pending | sold\n"
    "    public_visible boolean     NOT NULL DEFAULT false,\n"
    "    display_region text,                   -- coarse location shown publicly\n"
    "    financials     jsonb       NOT NULL,   -- non-sensitive analysis metrics\n"
    "    restricted     jsonb       NOT NULL,   -- exact address etc; never sent unauthenticated\n"
    "    ghl_updated_at timestamptz NOT NULL,\n"
    "    synced_at      timestamptz NOT NULL DEFAULT now()\n"
    ");\n"
    "CREATE INDEX ON property_listing (status, public_visible);\n\n"
    "-- Mirror of GHL transactions; GHL _id is the natural key.\n"
    "CREATE TABLE ghl_transaction (\n"
    "    ghl_id                text PRIMARY KEY,\n"
    "    location_id           text        NOT NULL,\n"
    "    contact_id            text,\n"
    "    invoice_id            text,\n"
    "    subscription_id       text,\n"
    "    amount_minor          bigint      NOT NULL,   -- integer minor units, never float\n"
    "    currency              char(3)     NOT NULL,\n"
    "    amount_refunded_minor bigint      NOT NULL DEFAULT 0,\n"
    "    status                text        NOT NULL,\n"
    "    live_mode             boolean     NOT NULL,\n"
    "    payment_provider      text,\n"
    "    entity_type           text,\n"
    "    entity_id             text,\n"
    "    ghl_created_at        timestamptz NOT NULL,\n"
    "    ghl_updated_at        timestamptz NOT NULL,\n"
    "    raw                   jsonb       NOT NULL\n"
    ");\n"
    "CREATE INDEX ON ghl_transaction (invoice_id);\n"
    "CREATE INDEX ON ghl_transaction (contact_id);",
    CODE))
A(para(
    "Store money as <font face='Courier'>bigint</font> minor units. Never use floating "
    "point for currency, and prefer an explicit integer column over "
    "<font face='Courier'>numeric</font> for values crossing a JSON boundary.", NOTE))

A(para("9.4  Idempotency rules", H2))
for b in bullets([
    "Deduplicate every webhook on <font face='Courier'>webhookId</font> before any side effect.",
    "Upsert transactions on GHL <font face='Courier'>_id</font> with <font face='Courier'>ON CONFLICT DO UPDATE</font>.",
    "Apply an update only when the incoming <font face='Courier'>updatedAt</font> is newer than the stored value, so a late event cannot overwrite fresher state.",
    "Use <font face='Courier'>/contacts/upsert</font> and <font face='Courier'>/opportunities/upsert</font> rather than create-then-handle-duplicate.",
    "Acknowledge webhooks quickly with HTTP 200 and process asynchronously; slow handlers cause redelivery.",
    "Filter on <font face='Courier'>liveMode</font> so test traffic never reaches production records.",
]): A(b)
A(PageBreak())

# --------------------------------------------------------------- 10 risks
A(para("10.  Platform Constraints Affecting the Intended Design", H1))
A(para(
    "The following are properties of the platform, established from the specifications "
    "above. They are recorded here because each one materially affects the architecture "
    "and each is cheaper to design around now than to discover during build.", BODY))

A(para("10.1  Client-side address masking is presentation, not access control", H2))
A(para(
    "If a public page renders property cards by calling the GHL API from the visitor's "
    "browser and hiding the exact address in the DOM, the address is still delivered to "
    "the browser. Anyone can read it from the network tab. The same applies to any "
    "financial field intended to be revealed only after the fee agreement is signed. "
    "Hiding a value in the client does not gate it.", RISK))
A(para(
    "There is a second, more serious form of this problem. GHL API credentials are "
    "bearer tokens scoped to an entire sub-account. A credential embedded in public "
    "JavaScript to fetch listings is readable by every visitor and grants that visitor "
    "the token's full scope &mdash; contacts, invoices, transactions &mdash; not merely "
    "the listing fields the page displays. Public browser code must never hold a GHL "
    "token.", RISK))
A(para("The sound pattern:", BODY))
for b in bullets([
    "A server-side component holds the GHL credential and is the only thing that talks to GHL.",
    "It projects listings into the <font face='Courier'>property_listing</font> read model, splitting public fields from restricted ones at write time.",
    "The public page is served only the public projection. Restricted fields are never serialised into an unauthenticated response.",
    "Address reveal is a server-side authorisation decision, checked per request against the viewer's verified entitlement, not a CSS class or a JavaScript branch.",
]): A(b)

A(para("10.2  Portal gating is a marketing boundary, not a security boundary", H2))
A(para(
    "Membership gating and tag-based visibility are appropriate for shaping what a "
    "logged-in user is shown. They are not designed as an authorisation boundary for "
    "confidential financial data belonging to a specific investor or agent. Where the "
    "requirement is that an agent can access only their assigned properties and "
    "conversations, that entitlement should be enforced server-side on every request "
    "that returns restricted data.", RISK))

A(para("10.3  Public browsing cannot be served directly from the GHL API", H2))
A(para(
    "As set out in section 5, the 100-request / 10-second burst limit is shared across "
    "all concurrent visitors because it is scoped per application per location. A "
    "marketplace whose search and filter operations hit GHL per visitor will degrade "
    "under modest traffic and cannot be fixed by tuning. Serving the front end from a "
    "cached read model, refreshed by webhooks, is the structural answer.", RISK))

A(para("10.4  Transactional writes are constrained", H2))
A(para(
    "Restated because it shapes the fee flow: no transaction can be created through the "
    "API. The platform fee must be represented as an invoice, an order payment record, "
    "or a charge through a registered custom payment provider. Any design that assumes "
    "arbitrary financial records can be pushed into GHL will need rework.", RISK))

A(para("10.5  External listing status scraping", H2))
A(para(
    "A nightly job that checks third-party listing portals for status changes sits "
    "outside GHL entirely and carries its own considerations: those sites' terms of use, "
    "active anti-automation measures, and the ongoing maintenance burden of selectors "
    "that change without notice. Treat it as a distinct component with its own "
    "reliability expectations, and prefer a licensed data feed where one is available. "
    "Its output reaches GHL as an inbound webhook or a direct record update.", RISK))

A(para("10.6  Summary", H2))
A(table([
    hdr(["Constraint", "Consequence", "Mitigation"]),
    ["Bearer tokens are sub-account scoped", "Cannot be exposed to browsers", "Server-side integration component holds all credentials"],
    ["Burst limit is per app, not per user", "Public browsing will throttle", "Cached read model refreshed by webhooks"],
    ["Client-side hiding is not gating", "Restricted data leaks", "Split public and restricted projections server-side"],
    ["Transactions are read-only", "Fees must be invoices or orders", "Model the fee agreement as an invoice"],
    ["Webhooks are not exactly-once", "Silent data drift", "Dedupe on webhookId plus nightly reconciliation"],
    ["Access tokens expire in ~24h", "Unattended jobs fail", "Private Integration Token, or atomic refresh persistence"],
], [1.55 * inch, 1.85 * inch, 2.5 * inch]))
A(PageBreak())

# --------------------------------------------------------------- 11 errors
A(para("11.  Error Handling", H1))
A(table([
    hdr(["Condition", "Handling"]),
    ["401 Unauthorized", "Token expired or revoked. Refresh and retry once; if it recurs, alert. Never retry in a loop."],
    ["403 Forbidden", "Missing scope. Not retryable. Log the required scope explicitly."],
    ["404 Not Found", "Object deleted or wrong location scope. Reconcile rather than retry."],
    ["422 Unprocessable", "Payload rejected. Log full request and response; requires a code fix."],
    ["429 Too Many Requests", "Jittered exponential backoff; respect the rate-limit headers."],
    ["5xx", "Retry with backoff and capped attempts, then dead-letter the job."],
    ["Missing Version header", "Deterministic failure. Enforce in the HTTP client, not per call site."],
    ["Signature verification failure", "Return 401 and record the attempt. Never process an unverified payload."],
], [1.55 * inch, 4.35 * inch]))
A(Spacer(1, 5))
A(para(
    "Carry a correlation id on every outbound call and log it alongside the GHL "
    "<font face='Courier'>traceId</font> where one is returned, so a support "
    "conversation with GHL can be grounded in a specific request.", BODY))

# --------------------------------------------------------------- 12 local
A(para("12.  Local Development and Testing", H1))
A(para("This phase is local-only. Nothing in the development environment is exposed to "
       "the internet, and nothing needs to be.", BODY))
A(table([
    hdr(["Concern", "Local approach"]),
    ["Database", "PostgreSQL 16 on " + "<font face='Courier'>localhost:5432</font>, bound to localhost"],
    ["Credentials", "Private Integration Token in an environment variable; never committed"],
    ["Outbound calls to GHL", "Work normally; only inbound delivery is restricted"],
    ["Webhook receipt", "Cannot be delivered to this host. Replay recorded fixtures at the handler"],
    ["Signature testing", "Unit-test verify() with a locally generated RSA keypair, plus one captured real payload"],
    ["Contract testing", "Validate request builders against the vendored OpenAPI specifications"],
    ["Live sandbox", "Use a GHL test sub-account and " + "<font face='Courier'>paymentMode=test</font>"],
    ["Migration rehearsal", "Run the full pass 0&ndash;7 load against a disposable sub-account before production"],
], [1.5 * inch, 4.4 * inch]))
A(Spacer(1, 5))
A(para(
    "The only capability genuinely unavailable locally is receiving live webhook "
    "deliveries, which requires an inbound public URL. Build the receiver as a plain "
    "function over <font face='Courier'>(raw_body, headers)</font> so it can be driven "
    "from fixtures in tests and mounted on an HTTP route later without change. That "
    "keeps the deferred internet work a routing concern rather than a redesign.", BODY))
A(para(
    "Treat the local database as disposable. Schema belongs in committed migrations and "
    "seed data in committed fixtures.", NOTE))

# --------------------------------------------------------------- 13 open
A(para("13.  Open Items and Decisions Required", H1))
A(table([
    hdr(["#", "Item", "Next step"]),
    ["1", "Confirm the webhook signature algorithm and padding against a captured live payload", "Engineering &mdash; blocks trusting the receiver"],
    ["2", "Choose credential type: Private Integration Token or full OAuth app", "Recommendation: Private Integration Token"],
    ["3", "Decide where restricted property fields are authorised and served from", "Architecture &mdash; see section 10.1"],
    ["4", "Confirm which payment provider is connected in GHL", "Operations &mdash; constrains the fee flow"],
    ["5", "Define the refund and partial-payment policy for the platform fee", "Finance and engineering"],
    ["6", "Establish the GHL test sub-account and location id", "Operations"],
    ["7", "Complete the EspoCRM field-level mapping to custom object schemas", "Engineering &mdash; precedes pass 1"],
    ["8", "Decide the source of external listing status data", "Product &mdash; licensed feed preferred over scraping"],
], [0.3 * inch, 3.3 * inch, 2.3 * inch]))

# --------------------------------------------------------------- 14 sources
A(para("14.  Sources and Verification", H1))
A(para(
    "Endpoint paths, HTTP methods, OAuth scopes, the required version header, request "
    "and response field names, rate limits and the webhook event catalogue were read "
    "directly from GoHighLevel's official OpenAPI specification repository rather than "
    "from narrative documentation.", BODY))
A(table([
    hdr(["Source", "Reference"]),
    ["Official OpenAPI specifications", mono("github.com/GoHighLevel/highlevel-api-docs")],
    ["Developer portal", mono("marketplace.gohighlevel.com/docs/")],
    ["Transactions API", mono("marketplace.gohighlevel.com/docs/ghl/payments/transactions/")],
    ["OAuth 2.0 guide", mono("marketplace.gohighlevel.com/docs/Authorization/OAuth2.0/")],
    ["Webhook authentication", mono("docs/oauth/WebhookAuthentication.md") + " in the spec repository"],
    ["Rate limits", mono("docs/oauth/Authorization.md") + " in the spec repository"],
    ["Product site", mono("www.gohighlevel.com")],
], [2.1 * inch, 3.8 * inch]))
A(Spacer(1, 8))
A(para(
    "Verification note. The rendered documentation host "
    "<font face='Courier'>marketplace.gohighlevel.com</font> was unreachable from the "
    "environment in which this document was prepared, so the specification repository "
    "was cloned from GitHub and read at source &mdash; the authoritative origin for the "
    "rendered documentation in any case. Two items are marked unverified rather than "
    "asserted: the webhook signature algorithm and padding (section 8.2), and the formal "
    "deprecation status of the legacy v1 API, which is absent from the current v2 "
    "specification but whose end-of-life date was not confirmed.", CAP))

doc.build(E)
print("wrote", OUT)
