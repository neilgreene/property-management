'use strict';
// The block grid, asserted from the source.
//
// The sheet is meant to read like the workbook: A above B on the left, C
// above D on the right. It has broken that way twice, both times because
// the arrangement was inferred from CSS rather than measured, and both
// times silently -- a layout does not throw.
//
// WHAT THIS CAN AND CANNOT DO. It cannot lay out a page; there is no
// browser here and adding one is a heavy dependency for a project with no
// build step. What it can do is hold the three decisions the breakages
// turned on, so that undoing one is a failing test rather than a screenshot
// somebody sends back weeks later. The rendered geometry was verified in
// Chromium at 700/1100/1320/1400/1500/1700/1920px, with the manager card
// both shown and hidden; the numbers below come from that.
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const pub = path.join(__dirname, '..', 'public');
const css = fs.readFileSync(path.join(pub, 'property-admin.css'), 'utf8');
const html = fs.readFileSync(path.join(pub, 'property-admin.html'), 'utf8');

test('the blocks appear in workbook order in the markup', () => {
  const at = (cls) => html.indexOf(`class="block ${cls}"`);
  const [a, c, b, d] = [at('bA'), at('bC'), at('bB'), at('bD')];
  assert.ok(a >= 0 && b >= 0 && c >= 0 && d >= 0, 'a block lost its placement class');
  assert.ok(a < c && c < b && b < d,
    'source order is not A, C, B, D — the two-column fallback pairs by source '
    + 'order, so this order is what puts A above B and C above D');

  // The card last, and no longer wedged between C and B. It sat there so
  // that it would land beside A and C, which held only while it was
  // showing; hidden, the grid pulled B into the gap and the sheet read
  // A C B / D.
  assert.ok(html.indexOf('id="mgr"') > d,
    'the manager card is back in the middle of the blocks, where its own '
    + 'visibility decides where B goes');
});

test('each block is placed explicitly in the three-column arrangement', () => {
  for (const [cls, col, row] of [['bA', 1, 1], ['bC', 2, 1], ['bB', 1, 2], ['bD', 2, 2]]) {
    const re = new RegExp(`\\.${cls}\\{grid-column:${col};grid-row:${row}\\}`);
    assert.match(css, re,
      `.${cls} is not pinned to column ${col} row ${row} — auto-placement puts a `
      + 'block in the first free cell, and which cell is free depends on whether '
      + 'the manager card is showing');
  }
  assert.match(css, /\.mgrcard\{grid-column:3;grid-row:1/,
    'the manager card is not pinned to the third column');
});

test('the third column appears only when there is a manager to put in it', () => {
  assert.match(css, /\.blocks:has\(> \.mgrcard:not\(\[hidden\]\)\)/,
    'the three-column rule is not guarded on the card being visible — a bare '
    + 'third column is what let B come up beside A and C');
});

test('the three-column breakpoint measures the sheet, not the window', () => {
  // The sheet begins about 516px in, behind the rail and the property
  // list. Measured in Chromium: a 1320px window leaves the sheet 804px
  // while the three columns ask for 1110, so the manager card was pushed
  // past the right edge and `.sheet`'s overflow-x hid it behind a sideways
  // scroll -- invisible, from roughly 1320px to 1650px.
  assert.match(css, /@container sheet \(min-width:1110px\)/,
    'the breakpoint is not a container query on the sheet');
  assert.match(css, /\.sheet\{[^}]*container-type:inline-size[^}]*container-name:sheet/,
    'the sheet is not declared as a query container, so the @container rule '
    + 'above it can never match');
  assert.ok(!/@media \(min-width:1320px\)/.test(css),
    'the old viewport breakpoint is back — viewport width is not the width '
    + 'this grid gets');

  // 390 + 390 + 262 + 28 gap + 40 padding = 1110. If the columns change,
  // the breakpoint has to change with them or the card is clipped again.
  const m = /@container sheet \(min-width:1110px\)\{[\s\S]*?grid-template-columns:\s*minmax\((\d+)px,1fr\) minmax\((\d+)px,1fr\) (\d+)px/.exec(css);
  assert.ok(m, 'could not read the three-column track list');
  const [, c1, c2, c3] = m.map(Number);
  const gap = 14 * 2, pad = 20 * 2;
  assert.equal(c1 + c2 + c3 + gap + pad, 1110,
    'the columns no longer add up to the breakpoint — the manager card will be '
    + 'clipped in the range where the sheet is narrower than the tracks');
});

test('every section standing alone in the sheet has the same side margin', () => {
  // `wide` is the only thing that gives a top-level section its 20px side
  // margin. Two sections were missing it and ran flush to the sheet edges,
  // 20px proud of everything else on the page. Measured in Chromium at
  // 1920px: every other section, and the block grid, spans 536..1900; those
  // two spanned 516..1920.
  //
  // The invariant is that a bare `class="block"` never appears. A block is
  // either inside the grid -- where it carries its placement class (bA, bB,
  // bC, bD) or is the manager card -- or it stands alone in the sheet, where
  // it must be `wide`. Nothing is legitimately neither.
  const bare = [...html.matchAll(/class="block"/g)];
  assert.equal(bare.length, 0,
    `${bare.length} section(s) use class="block" with nothing after it. Inside `
    + 'the grid a block carries a placement class; standing alone in the sheet '
    + 'it needs `wide`, or it runs 20px wider than every other section.');

  // And the sections that should be standing alone still are, so the rule
  // above cannot be satisfied by deleting them.
  for (const h of ['Deciding about using points', 'Mortgage acceleration',
                   'Property ratings', 'Shown to', 'Shared with', 'History']) {
    const at = html.indexOf(h);
    assert.ok(at > 0, `the "${h}" section is gone`);
    const before = html.lastIndexOf('<div class=', at);
    assert.match(html.slice(before, at), /class="block wide"/,
      `"${h}" is no longer a full-width section`);
  }
});
