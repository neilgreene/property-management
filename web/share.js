'use strict';
// =====================================================================
// share.js  |  a listing, as a document that leaves the building
// =====================================================================
// The layout is deliberately dull. What matters here is not typography,
// it is which facts are on the page, and that question is settled before
// this module is called: it receives a context that has already been
// decided by the database and renders exactly what it is given. There is
// no branch in here that consults a permission, because a second opinion
// about permissions is how the two opinions come to differ.
//
// WHAT IS NEVER WITHHELD: the numbers. Price, rent, expenses, NOI, cap
// rate go on every document, masked or not. That is the whole shape of
// this business -- an investor decides on the cash flow and only then
// signs for the identity of the house. A masked document that also hid
// the yield would be a brochure for nothing.
//
// WHAT MASKING ACTUALLY REMOVES: the street address, the unit, the
// parcel number, the coordinates, and the photograph -- replaced with a
// branded stand-in of a different house, not a watermark over the real
// one. A watermark still shows the roofline and the neighbour's fence,
// and anyone who has driven the block recognises it.
const PDFDocument = require('pdfkit');

const PALETTE = {
  ink: '#0f1c2a', mut: '#5f7488', line: '#d8e3ee',
  accent: '#1d6fa8', warn: '#8a5300', crit: '#a8261d', ok: '#1c6b58',
};

const usd = (n) => n == null ? '—'
  : '$' + Number(n).toLocaleString('en-US', { maximumFractionDigits: 0 });
const pct = (n) => n == null ? '—' : (Number(n) * 100).toFixed(2) + '%';
const num = (n) => n == null ? '—' : Number(n).toLocaleString('en-US');

// The document. `ctx.unmasked` has already been decided; this only draws.
function render(ctx) {
  const { property: p, unmasked, image, sharedBy, recipient, build } = ctx;
  const doc = new PDFDocument({ size: 'LETTER', margin: 54,
    info: {
      Title: `${p.listing_ref} — ${p.city}, ${p.state}`,
      Author: 'Simply Do It',
      // Recorded in the file itself as well as in the database. A PDF that
      // has been forwarded three times still says what it is.
      Subject: unmasked
        ? 'Investment property summary — includes released address and photograph'
        : 'Investment property summary — address and photograph withheld',
      Creator: 'SDI Investment Property Marketplace',
    } });

  const W = doc.page.width - doc.page.margins.left - doc.page.margins.right;
  const L = doc.page.margins.left;

  // --- masthead ---------------------------------------------------------
  doc.rect(0, 0, doc.page.width, 74).fill(PALETTE.accent);
  doc.fillColor('#fff').font('Helvetica-Bold').fontSize(17)
     .text('SDI', L, 26, { continued: true })
     .font('Helvetica').fontSize(12)
     .text('   Investment Property Marketplace');
  doc.font('Helvetica').fontSize(9).fillColor('#cfe3f3')
     .text(p.listing_ref, L, 48);
  doc.y = 100;

  // --- the banner, and it is the first thing on the page ----------------
  // A reader has to know which kind of document this is before they read
  // anything on it, not after. Put at the top for the person who receives
  // it, who has no idea this system has two modes.
  banner(doc, L, W, unmasked);

  // --- identity ---------------------------------------------------------
  doc.moveDown(0.8);
  doc.fillColor(PALETTE.ink).font('Helvetica-Bold').fontSize(19);
  if (unmasked) {
    doc.text(`${p.street_address}${p.unit ? ' ' + p.unit : ''}`, L);
    doc.font('Helvetica').fontSize(12).fillColor(PALETTE.mut)
       .text(`${p.city}, ${p.state} ${p.zip || ''}`);
  } else {
    doc.text(`${p.city}, ${p.state}`, L);
    doc.font('Helvetica').fontSize(11).fillColor(PALETTE.mut)
       .text('Street address withheld until the platform fee agreement is signed.');
  }

  // --- the photograph ---------------------------------------------------
  const top = doc.y + 12;
  if (image) {
    try {
      doc.image(image, L, top, { fit: [W, 232], align: 'center' });
    } catch { /* an unreadable image is not worth failing a document over */ }
  }
  doc.y = top + (image ? 240 : 8);
  if (!unmasked) {
    doc.font('Helvetica-Oblique').fontSize(8.5).fillColor(PALETTE.mut)
       .text('Representative image. This is not a photograph of this property.', L,
             doc.y, { width: W });
  }

  // --- the numbers, always ----------------------------------------------
  doc.moveDown(1);
  section(doc, L, W, 'The numbers');
  const money = [
    ['Asking price',            usd(p.list_price)],
    ['Gross rent (annual)',     usd(p.gross_rent_annual)],
    ['Operating expenses',      usd(p.opex_annual)],
    ['HOA (annual)',            usd(p.hoa_annual)],
    ['Net operating income',    usd(p.noi_annual)],
    ['Cap rate',                pct(p.cap_rate)],
  ];
  rows(doc, L, W, money, { emphasiseLast: 2 });

  doc.moveDown(1);
  section(doc, L, W, 'The property');
  rows(doc, L, W, [
    ['Type',        p.property_type || '—'],
    ['Bedrooms',    num(p.beds)],
    ['Bathrooms',   p.baths == null ? '—' : Number(p.baths).toString()],
    ['Living area', p.sqft == null ? '—' : num(p.sqft) + ' sqft'],
    ['Year built',  p.year_built || '—'],
    ['Status',      String(p.status || '').replace('_', ' ')],
    // Parcel number identifies the house as precisely as the address does:
    // it is one search away from an owner name and a plat map. It travels
    // with the address or not at all.
    ...(unmasked && p.parcel_number ? [['Parcel number', p.parcel_number]] : []),
  ]);

  // --- provenance -------------------------------------------------------
  // Who made this, when, and for whom. On the document as well as in the
  // log, because the copy that gets forwarded is the one people ask about
  // and it will not be accompanied by a database.
  doc.moveDown(1.4);
  doc.moveTo(L, doc.y).lineTo(L + W, doc.y).lineWidth(0.5)
     .strokeColor(PALETTE.line).stroke();
  doc.moveDown(0.6);
  doc.font('Helvetica').fontSize(8).fillColor(PALETTE.mut);
  const when = new Date().toLocaleString('en-US',
    { dateStyle: 'long', timeStyle: 'short' });
  doc.text(`Prepared by ${sharedBy || 'SDI'} for ${recipient} on ${when}.`, L,
           doc.y, { width: W });
  doc.text(`${p.listing_ref} · SDI ${build || 'dev'} · Figures are as recorded on `
         + 'the date above and are not an offer, an appraisal, or a guarantee '
         + 'of performance.', L, doc.y + 2, { width: W });

  doc.end();
  return doc;
}

function banner(doc, L, W, unmasked) {
  const h = 40;
  const y = doc.y;
  doc.roundedRect(L, y, W, h, 5)
     .fill(unmasked ? '#fbeae8' : '#eaf1f8');
  doc.fillColor(unmasked ? PALETTE.crit : PALETTE.accent)
     .font('Helvetica-Bold').fontSize(9.5)
     .text(unmasked ? 'CONTAINS RELEASED PROPERTY DETAILS'
                    : 'ADDRESS AND PHOTOGRAPH WITHHELD',
           L + 12, y + 9, { width: W - 24 });
  doc.font('Helvetica').fontSize(8).fillColor(unmasked ? '#7a2c25' : '#3c5c78')
     .text(unmasked
       ? 'The address and photograph below identify the property. Do not forward '
         + 'to anyone who has not signed a platform fee agreement.'
       : 'The financial detail below is complete. The address, exact location and '
         + 'photographs are released on signing.',
       L + 12, y + 22, { width: W - 24 });
  doc.y = y + h;
}

function section(doc, L, W, title) {
  doc.fillColor(PALETTE.ink).font('Helvetica-Bold').fontSize(10.5)
     .text(title.toUpperCase(), L, doc.y, { characterSpacing: 0.6 });
  doc.moveDown(0.25);
  doc.moveTo(L, doc.y).lineTo(L + W, doc.y).lineWidth(1)
     .strokeColor(PALETTE.line).stroke();
  doc.moveDown(0.45);
}

function rows(doc, L, W, pairs, { emphasiseLast = 0 } = {}) {
  const lineH = 17;
  pairs.forEach(([k, v], i) => {
    const strong = i >= pairs.length - emphasiseLast;
    const y = doc.y;
    doc.font('Helvetica').fontSize(10).fillColor(PALETTE.mut)
       .text(k, L, y, { width: W * 0.6 });
    doc.font(strong ? 'Helvetica-Bold' : 'Helvetica').fontSize(10)
       .fillColor(PALETTE.ink)
       .text(String(v), L + W * 0.6, y, { width: W * 0.4, align: 'right' });
    doc.y = y + lineH;
  });
}

module.exports = { render, PALETTE };
