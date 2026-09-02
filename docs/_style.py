"""
Shared look for the generated PDFs.

Pulled out when the second document needed the same styles as the first.
Duplicating sixty lines of ParagraphStyle across generators is how two
documents that are meant to look like one product slowly stop doing so.

Nothing here knows what any document says -- only how it looks.
"""
from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER
from reportlab.lib.pagesizes import LETTER
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import inch
from reportlab.platypus import (BaseDocTemplate, Frame, PageTemplate, Paragraph,
                                Table, TableStyle)

INK, MUTED, ACCENT = colors.HexColor("#12161C"), colors.HexColor("#5A6572"), colors.HexColor("#1F5FA9")
WARN, RULE, BAND = colors.HexColor("#A8410E"), colors.HexColor("#D4D9E0"), colors.HexColor("#EEF2F7")
CODE_BG, OKBG = colors.HexColor("#F5F7FA"), colors.HexColor("#EDF5EE")
OK = colors.HexColor("#1E6B33")

ss = getSampleStyleSheet()
def S(n, parent=None, **kw): return ParagraphStyle(n, parent=parent or ss["Normal"], **kw)

BODY  = S("body", fontName="Helvetica", fontSize=12.5, leading=13.6, textColor=INK, spaceAfter=7)
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
SCELL = S("scell", fontName="Helvetica", fontSize=7.4, leading=12.4, textColor=INK)
SCELB = S("scelb", parent=None, fontName="Helvetica-Bold", fontSize=7.4, leading=12.4, textColor=INK)
TNAME = S("tname", fontName="Courier-Bold", fontSize=10, leading=13, textColor=INK,
          spaceBefore=13, spaceAfter=2)
TDESC = S("tdesc", fontName="Helvetica-Oblique", fontSize=8, leading=11, textColor=MUTED, spaceAfter=4)
BLANK = S("blank", fontName="Helvetica", fontSize=8.5, leading=12, textColor=MUTED, alignment=TA_CENTER)
TOC1  = S("toc1", fontName="Helvetica-Bold", fontSize=9, leading=12.5, textColor=INK,
          spaceBefore=3.5, leftIndent=0, firstLineIndent=0)
TOC2  = S("toc2", fontName="Helvetica", fontSize=8.2, leading=10.8, textColor=MUTED,
          leftIndent=18, firstLineIndent=0)
CS    = S("cs", fontName="Helvetica", fontSize=12.5, leading=17, textColor=MUTED, alignment=TA_CENTER, spaceAfter=5)


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


def make_decorate(right_header, footer_left="neilgreene/property-management",
                  footer_right="Internal engineering document"):
    """Running heads and folios, from page 3 on.

    Pages 1 and 2 are the cover and the intentional blank; numbering starts
    at the contents page, which is the first page a reader navigates by.
    """
    def decorate(canvas, doc):
        canvas.saveState(); w, h = LETTER
        if doc.page > 2:
            canvas.setFont("Helvetica", 7.5); canvas.setFillColor(MUTED)
            canvas.drawString(0.9*inch, h-0.62*inch, "SDI Investment Property Marketplace")
            canvas.drawRightString(w-0.9*inch, h-0.62*inch, right_header)
            canvas.setStrokeColor(RULE); canvas.setLineWidth(0.5)
            canvas.line(0.9*inch, h-0.72*inch, w-0.9*inch, h-0.72*inch)
            canvas.line(0.9*inch, 0.72*inch, w-0.9*inch, 0.72*inch)
            canvas.setFont("Helvetica", 7.5)
            canvas.drawCentredString(w/2.0, 0.55*inch, f"Page {doc.page}")
            canvas.drawString(0.9*inch, 0.55*inch, footer_left)
            canvas.drawRightString(w-0.9*inch, 0.55*inch, footer_right)
        canvas.restoreState()
    return decorate


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
            return
        if name == "h1":
            self.notify("TOCEntry", (0, text, self.page))
        elif name == "h2":
            self.notify("TOCEntry", (1, text, self.page))


def build_doc(out, right_header, title, subject, footer_left="neilgreene/property-management"):
    doc = Doc(out, pagesize=LETTER, leftMargin=0.9*inch, rightMargin=0.9*inch,
              topMargin=0.92*inch, bottomMargin=0.92*inch,
              title=title, author="SDI Investment Property Marketplace", subject=subject)
    doc.addPageTemplates([PageTemplate(id="m", onPage=make_decorate(right_header, footer_left),
        frames=[Frame(doc.leftMargin, doc.bottomMargin, doc.width, doc.height, id="f")])])
    return doc
