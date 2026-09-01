// =====================================================================
// media.js  |  deterministic placeholder photography
// =====================================================================
// The demo needs pictures. Real listing photographs are somebody's
// copyright and a stock service is a dependency and an account, so this
// module draws them instead: flat vector illustrations, generated from
// the property id so the same listing always looks the same.
//
// They are deliberately stylised rather than photo-imitations. A viewer
// should be able to tell at a glance that these are placeholders, not be
// misled into thinking they are looking at the house.
//
// Replacing this with real media is a one-line change: core.property_media
// stores a url, and nothing outside this file assumes that url is served
// from here. The gate (`reveals_location`) lives in the database and is
// unaffected by where the bytes come from.

const crypto = require('crypto');

function rng(seed) {
  let h = crypto.createHash('sha256').update(seed).digest();
  let i = 0;
  return function next(n) {
    if (i >= h.length - 4) { h = crypto.createHash('sha256').update(h).digest(); i = 0; }
    const v = h.readUInt32BE(i); i += 4;
    return v % n;
  };
}

const SKIES  = [['#cfe4f5', '#eef6fc'], ['#dbe7f2', '#f5f1e8'], ['#c9dced', '#f2f6f8'],
                ['#e6dfe9', '#f7f2ef'], ['#d3e2e0', '#f3f7f4']];
const WALLS  = [['#c8683f', '#a9542f'], ['#5f7f8c', '#4c6874'], ['#8a8f7a', '#6f7462'],
                ['#a8a29b', '#8c867f'], ['#7a6a63', '#63554f'], ['#c9b48f', '#ad9977']];
const ROOFS  = ['#3f4650', '#4a4340', '#374049', '#54473f'];
const INSIDE = [['#efe9e0', '#d9cfc2'], ['#e9eef1', '#cfd9df'], ['#f1ece4', '#ded3c4'],
                ['#eae7f0', '#d3cede']];
const ACCENT = ['#3f6f8f', '#7d5a4f', '#4f7a5e', '#8a5a72', '#6b6f8f'];
const FLOOR  = ['#b98a5b', '#a97b52', '#c9a077', '#8f6f56'];

const esc = (s) => String(s).replace(/[<>&"]/g, (c) =>
  ({ '<': '&lt;', '>': '&gt;', '&': '&amp;', '"': '&quot;' }[c]));

function frame(inner, caption, tint) {
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 800 600" width="800" height="600" role="img" aria-label="${esc(caption)}">
${inner}
<rect x="0" y="556" width="800" height="44" fill="rgba(17,20,24,.62)"/>
<text x="20" y="584" font-family="system-ui,-apple-system,Segoe UI,sans-serif" font-size="19" fill="#f2f4f6">${esc(caption)}</text>
<text x="780" y="584" text-anchor="end" font-family="system-ui,-apple-system,Segoe UI,sans-serif" font-size="13" fill="${tint}" letter-spacing="1.4">ILLUSTRATION</text>
</svg>`;
}

function windowPane(x, y, w, h, r) {
  const mull = `<line x1="${x + w / 2}" y1="${y}" x2="${x + w / 2}" y2="${y + h}" stroke="#f6f8fa" stroke-width="4"/>
<line x1="${x}" y1="${y + h / 2}" x2="${x + w}" y2="${y + h / 2}" stroke="#f6f8fa" stroke-width="4"/>`;
  return `<rect x="${x}" y="${y}" width="${w}" height="${h}" fill="#31465a" opacity=".85" rx="2"/>
<rect x="${x}" y="${y}" width="${w}" height="${h / 2.4}" fill="#8fb6d4" opacity=".55"/>
${r(2) ? mull : ''}
<rect x="${x - 5}" y="${y - 5}" width="${w + 10}" height="${h + 10}" fill="none" stroke="#f2f0ec" stroke-width="7" rx="3"/>`;
}

function exterior(r, caption) {
  const [s1, s2] = SKIES[r(SKIES.length)];
  const [w1, w2] = WALLS[r(WALLS.length)];
  const roof = ROOFS[r(ROOFS.length)];
  const storeys = 1 + r(2);
  const bodyH = storeys === 1 ? 210 : 280;
  const top = 500 - bodyH;
  const win = [];
  for (let row = 0; row < storeys; row++) {
    for (let col = 0; col < 3; col++) {
      if (row === 0 && col === 1) continue;              // door bay
      win.push(windowPane(255 + col * 105, top + 46 + row * 118, 62, 78, r));
    }
  }
  return frame(`<defs>
<linearGradient id="sky" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${s1}"/><stop offset="1" stop-color="${s2}"/></linearGradient>
<linearGradient id="wall" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${w1}"/><stop offset="1" stop-color="${w2}"/></linearGradient>
</defs>
<rect width="800" height="600" fill="url(#sky)"/>
<circle cx="${120 + r(60)}" cy="${90 + r(40)}" r="46" fill="#ffffff" opacity=".5"/>
<rect y="470" width="800" height="130" fill="#8ea479"/>
<rect y="500" width="800" height="100" fill="#7d9469"/>
<path d="M0 540 L800 528 L800 600 L0 600 Z" fill="#9a9a94"/>
<path d="M225 ${top} L400 ${top - 96} L575 ${top} Z" fill="${roof}"/>
<rect x="238" y="${top}" width="324" height="${bodyH}" fill="url(#wall)"/>
<rect x="238" y="${top}" width="324" height="${bodyH}" fill="none" stroke="rgba(0,0,0,.18)" stroke-width="2"/>
${win.join('\n')}
<rect x="358" y="${500 - 118}" width="84" height="118" fill="#3c3129" rx="3"/>
<circle cx="428" cy="${500 - 58}" r="5" fill="#e3c98a"/>
<rect x="340" y="494" width="120" height="12" fill="#c8c2b6"/>
<ellipse cx="${640 + r(60)}" cy="452" rx="72" ry="86" fill="#5f7f52"/>
<rect x="${672 + r(60)}" y="452" width="16" height="60" fill="#6b5642"/>
<ellipse cx="118" cy="470" rx="54" ry="62" fill="#6b8a5c"/>`, caption, '#dfe6ec');
}

function room(r, caption, kind) {
  const [wall, wall2] = INSIDE[r(INSIDE.length)];
  const acc = ACCENT[r(ACCENT.length)];
  const flr = FLOOR[r(FLOOR.length)];
  let furniture = '';

  if (kind === 'kitchen') {
    furniture = `<rect x="60" y="330" width="680" height="26" fill="#e8e6e2"/>
<rect x="60" y="356" width="330" height="130" fill="#cfc7bb"/>
<rect x="410" y="356" width="330" height="130" fill="#cfc7bb"/>
${[0, 1, 2, 3].map(i => `<rect x="${76 + i * 82}" y="372" width="66" height="98" fill="#ddd6cb" stroke="#c2b9ac"/>`).join('')}
<rect x="430" y="372" width="140" height="98" fill="#b9b2a8" stroke="#a49c92"/>
<rect x="600" y="372" width="120" height="98" fill="#d6d0c6" stroke="#c2b9ac"/>
<rect x="120" y="150" width="240" height="120" fill="#ddd6cb" stroke="#c2b9ac"/>
<rect x="150" y="292" width="90" height="34" fill="${acc}" rx="4"/>
<circle cx="560" cy="300" r="18" fill="none" stroke="#9aa0a6" stroke-width="6"/>
<rect x="556" y="240" width="8" height="60" fill="#9aa0a6"/>`;
  } else if (kind === 'bed') {
    furniture = `<rect x="230" y="250" width="340" height="120" fill="${acc}" rx="6"/>
<rect x="200" y="360" width="400" height="140" fill="#efeae2" rx="8"/>
<rect x="200" y="360" width="400" height="46" fill="#ffffff" rx="8"/>
<rect x="238" y="318" width="140" height="52" fill="#ffffff" rx="8"/>
<rect x="422" y="318" width="140" height="52" fill="#ffffff" rx="8"/>
<rect x="120" y="400" width="72" height="90" fill="#9a8873" rx="4"/>
<rect x="608" y="400" width="72" height="90" fill="#9a8873" rx="4"/>
<circle cx="156" cy="378" r="20" fill="#e8dcc0"/>
<circle cx="644" cy="378" r="20" fill="#e8dcc0"/>`;
  } else {
    furniture = `<rect x="140" y="360" width="330" height="110" fill="${acc}" rx="14"/>
<rect x="156" y="336" width="96" height="42" fill="${acc}" rx="10" opacity=".85"/>
<rect x="262" y="336" width="96" height="42" fill="${acc}" rx="10" opacity=".85"/>
<rect x="368" y="336" width="96" height="42" fill="${acc}" rx="10" opacity=".85"/>
<ellipse cx="330" cy="512" rx="250" ry="42" fill="#c3b49c" opacity=".7"/>
<rect x="520" y="392" width="150" height="80" fill="#8b7660" rx="5"/>
<rect x="556" y="352" width="78" height="42" fill="#dfd8cd" rx="3"/>
<rect x="600" y="150" width="130" height="96" fill="#f2efe9" stroke="#c9c1b4" stroke-width="6"/>
<rect x="616" y="166" width="98" height="64" fill="${acc}" opacity=".5"/>`;
  }

  return frame(`<defs>
<linearGradient id="w" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${wall}"/><stop offset="1" stop-color="${wall2}"/></linearGradient>
</defs>
<rect width="800" height="600" fill="url(#w)"/>
<rect y="486" width="800" height="114" fill="${flr}"/>
${[0, 1, 2, 3, 4, 5].map(i => `<line x1="${i * 150 - 40}" y1="486" x2="${i * 150 + 40}" y2="600" stroke="rgba(0,0,0,.12)" stroke-width="3"/>`).join('')}
<rect y="470" width="800" height="18" fill="#f4f1ea"/>
${windowPane(60, 120, 170, 210, r)}
<polygon points="60,120 230,120 300,470 60,470" fill="#fff8e6" opacity=".22"/>
${furniture}`, caption, '#e7e2d9');
}

const KINDS = {
  front:   (r) => exterior(r, 'Front elevation'),
  living:  (r) => room(r, 'Living area', 'living'),
  kitchen: (r) => room(r, 'Kitchen', 'kitchen'),
  bed:     (r) => room(r, 'Primary bedroom', 'bed'),
  unit:    (r) => room(r, 'Second unit', 'living'),
};

// propertyId is used only as a seed. It is already public to anyone who
// can see the listing, and the image reveals nothing about the property
// -- but the DATABASE still decides which of these urls a caller is told
// about, and the exterior is gated there.
function render(propertyId, kind) {
  const fn = KINDS[kind];
  if (!fn) return null;
  return fn(rng(propertyId + ':' + kind));
}

module.exports = { render, KINDS: Object.keys(KINDS) };
