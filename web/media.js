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

// A cool, daylight palette. The earlier one leaned on rust, tan and warm
// timber, which at card size read as muddy rather than warm -- twenty of
// them in a grid looked tired. These are the blues, slates and soft
// whites of a bright day, with one saturated accent per interior so the
// rooms are not monochrome.
const SKIES  = [['#bcd9f2', '#eaf4fc'], ['#a9cfee', '#e4f0fa'], ['#c6e0f5', '#f0f7fd'],
                ['#b3d4f0', '#e8f3fb'], ['#cbe3f6', '#f2f8fd']];
// Siding. Cool greys, soft blues, and white, which is what most of the
// housing stock in these markets actually looks like.
const WALLS  = [['#e8edf2', '#cdd8e2'], ['#93b0c9', '#7998b4'], ['#f2f4f6', '#dbe2e9'],
                ['#5f7f96', '#4e6b81'], ['#c3d2de', '#a6b9c9'], ['#8fa6b8', '#77909f']];
const ROOFS  = ['#3d4b58', '#46545f', '#334049', '#4f5c68'];
const TRIM   = '#ffffff';
// Interiors: pale, cool, and light-filled.
const INSIDE = [['#eef3f8', '#dbe4ed'], ['#f4f7fa', '#e3eaf1'], ['#e9eff5', '#d5dfe9'],
                ['#f1f4f7', '#dee6ee']];
const ACCENT = ['#3f6f8f', '#4d7f9e', '#5b7f9c', '#2f5f7f', '#6a8fa8'];
// Flooring in cool light oak and grey wash rather than dark walnut.
const FLOOR  = ['#c9cfd6', '#bcc6cf', '#d3d8dd', '#aeb9c3'];

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
  const bodyH = storeys === 1 ? 200 : 272;
  const top = 500 - bodyH;
  const gableTop = top - 92;

  // Windows, skipping the door bay on the ground floor.
  const win = [];
  for (let row = 0; row < storeys; row++) {
    for (let col = 0; col < 3; col++) {
      if (row === 0 && col === 1) continue;
      win.push(windowPane(256 + col * 104, top + 44 + row * 116, 60, 76, r));
    }
  }
  // A dormer on some two-storey houses, and a chimney on some houses.
  const dormer = storeys === 2 && r(2)
    ? `<path d="M352 ${gableTop + 34} L400 ${gableTop + 4} L448 ${gableTop + 34} Z" fill="${roof}"/>
       <rect x="366" y="${gableTop + 34}" width="68" height="42" fill="url(#wall)"/>
       ${windowPane(384, gableTop + 44, 32, 26, r)}` : '';
  const chimney = r(3) ? `<rect x="${300 + r(180)}" y="${gableTop - 30}" width="30" height="60" fill="#6b7580"/>` : '';

  return frame(`<defs>
<linearGradient id="sky" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${s1}"/><stop offset="1" stop-color="${s2}"/></linearGradient>
<linearGradient id="wall" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${w1}"/><stop offset="1" stop-color="${w2}"/></linearGradient>
<linearGradient id="lawn" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#a9c49a"/><stop offset="1" stop-color="#8fae82"/></linearGradient>
</defs>
<rect width="800" height="600" fill="url(#sky)"/>
<circle cx="${640 + r(80)}" cy="${74 + r(30)}" r="40" fill="#ffffff" opacity=".55"/>
<ellipse cx="${140 + r(80)}" cy="${104 + r(30)}" rx="86" ry="30" fill="#ffffff" opacity=".62"/>
<ellipse cx="${300 + r(120)}" cy="${78 + r(24)}" rx="62" ry="22" fill="#ffffff" opacity=".45"/>

<rect y="452" width="800" height="148" fill="url(#lawn)"/>
<path d="M0 548 L800 534 L800 600 L0 600 Z" fill="#c2c8ce"/>
<path d="M330 548 L470 548 L442 500 L358 500 Z" fill="#d5dade"/>

${chimney}
<path d="M216 ${top + 6} L400 ${gableTop} L584 ${top + 6} Z" fill="${roof}"/>
<path d="M216 ${top + 6} L400 ${gableTop} L584 ${top + 6} Z" fill="#ffffff" opacity=".08"/>
<rect x="208" y="${top}" width="384" height="14" fill="${TRIM}"/>
${dormer}
<rect x="238" y="${top + 12}" width="324" height="${bodyH - 12}" fill="url(#wall)"/>
${[...Array(Math.floor((bodyH - 12) / 22))].map((_, i) =>
   `<line x1="238" y1="${top + 24 + i * 22}" x2="562" y2="${top + 24 + i * 22}" stroke="rgba(255,255,255,.35)" stroke-width="1"/>`).join('')}
<rect x="238" y="${top + 12}" width="324" height="${bodyH - 12}" fill="none" stroke="rgba(30,45,60,.16)" stroke-width="2"/>
${win.join('\n')}

<rect x="330" y="${500 - 130}" width="140" height="130" fill="${TRIM}" opacity=".95"/>
<rect x="356" y="${500 - 118}" width="88" height="118" fill="#31465a" rx="3"/>
<rect x="364" y="${500 - 108}" width="72" height="42" fill="#8fb6d4" opacity=".5" rx="2"/>
<circle cx="${430}" cy="${500 - 56}" r="5" fill="#e8eef4"/>
<rect x="318" y="${500 - 138}" width="164" height="12" fill="${TRIM}"/>
<rect x="322" y="${500 - 126}" width="10" height="126" fill="${TRIM}"/>
<rect x="468" y="${500 - 126}" width="10" height="126" fill="${TRIM}"/>
<rect x="316" y="494" width="168" height="14" fill="#dfe4e8"/>

<ellipse cx="${646 + r(50)}" cy="440" rx="66" ry="80" fill="#7d9c72"/>
<rect x="${676 + r(50)}" y="440" width="14" height="56" fill="#6b7566"/>
<ellipse cx="132" cy="462" rx="52" ry="58" fill="#88a87c"/>
<ellipse cx="212" cy="486" rx="34" ry="26" fill="#93b287"/>
<ellipse cx="596" cy="490" rx="38" ry="24" fill="#93b287"/>`, caption, '#e6eef6');
}

function room(r, caption, kind) {
  const [wall, wall2] = INSIDE[r(INSIDE.length)];
  const acc = ACCENT[r(ACCENT.length)];
  const flr = FLOOR[r(FLOOR.length)];
  let furniture = '';

  if (kind === 'kitchen') {
    furniture = `<rect x="52" y="322" width="696" height="24" fill="#eef1f4"/>
<rect x="52" y="346" width="336" height="128" fill="#e2e8ee"/>
<rect x="412" y="346" width="336" height="128" fill="#e2e8ee"/>
${[0,1,2,3].map(i => `<rect x="${68 + i * 82}" y="360" width="66" height="100" fill="#f4f7f9" stroke="#cfd8e0"/>`).join('')}
<rect x="428" y="360" width="140" height="100" fill="#cfd8e0" stroke="#b9c4ce"/>
<rect x="588" y="360" width="146" height="100" fill="#f4f7f9" stroke="#cfd8e0"/>
${[0,1,2].map(i => `<rect x="${112 + i * 96}" y="140" width="88" height="112" fill="#f4f7f9" stroke="#cfd8e0"/>`).join('')}
<rect x="112" y="252" width="280" height="8" fill="#dde4ea"/>
<rect x="150" y="286" width="96" height="36" fill="${acc}" rx="5"/>
<circle cx="560" cy="292" r="17" fill="none" stroke="#aab6c0" stroke-width="6"/>
<rect x="556" y="232" width="8" height="60" fill="#aab6c0"/>
<rect x="470" y="470" width="240" height="10" fill="#dde4ea"/>`;
  } else if (kind === 'bed') {
    furniture = `<rect x="236" y="238" width="328" height="128" fill="${acc}" rx="8"/>
<rect x="236" y="238" width="328" height="128" fill="#ffffff" opacity=".08" rx="8"/>
<rect x="196" y="360" width="408" height="146" fill="#f5f8fa" rx="10"/>
<rect x="196" y="360" width="408" height="52" fill="#ffffff" rx="10"/>
<rect x="238" y="316" width="142" height="54" fill="#ffffff" rx="9"/>
<rect x="420" y="316" width="142" height="54" fill="#ffffff" rx="9"/>
<rect x="216" y="430" width="368" height="46" fill="${acc}" opacity=".5" rx="4"/>
<rect x="116" y="398" width="76" height="94" fill="#dde4ea" rx="5"/>
<rect x="608" y="398" width="76" height="94" fill="#dde4ea" rx="5"/>
<circle cx="154" cy="376" r="19" fill="#eef2f6"/>
<circle cx="646" cy="376" r="19" fill="#eef2f6"/>`;
  } else {
    furniture = `<rect x="132" y="352" width="344" height="116" fill="${acc}" rx="16"/>
<rect x="132" y="352" width="344" height="116" fill="#ffffff" opacity=".07" rx="16"/>
${[0,1,2].map(i => `<rect x="${150 + i * 108}" y="326" width="98" height="44" fill="${acc}" rx="11" opacity=".8"/>`).join('')}
<rect x="176" y="336" width="46" height="30" fill="#ffffff" opacity=".45" rx="7"/>
<rect x="392" y="336" width="46" height="30" fill="#ffffff" opacity=".45" rx="7"/>
<ellipse cx="330" cy="514" rx="252" ry="40" fill="#dfe6ec" opacity=".85"/>
<rect x="520" y="386" width="158" height="82" fill="#dde4ea" rx="6"/>
<rect x="556" y="346" width="82" height="42" fill="#eef2f6" rx="4"/>
<rect x="596" y="146" width="136" height="98" fill="#ffffff" stroke="#d3dae1" stroke-width="6"/>
<rect x="612" y="162" width="104" height="66" fill="${acc}" opacity=".4"/>`;
  }

  return frame(`<defs>
<linearGradient id="w" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${wall}"/><stop offset="1" stop-color="${wall2}"/></linearGradient>
</defs>
<rect width="800" height="600" fill="url(#w)"/>
<rect y="478" width="800" height="122" fill="${flr}"/>
${[0,1,2,3,4,5].map(i => `<line x1="${i * 150 - 40}" y1="478" x2="${i * 150 + 44}" y2="600" stroke="rgba(60,80,100,.10)" stroke-width="3"/>`).join('')}
<rect y="462" width="800" height="18" fill="#ffffff"/>
${windowPane(56, 112, 176, 218, r)}
<polygon points="56,112 232,112 312,462 56,462" fill="#ffffff" opacity=".3"/>
${furniture}`, caption, '#e6eef6');
}


// The card hero.
//
// Every card used to show an interior, and twenty pale living rooms in a
// grid look like one repeated image -- which is what "the block images
// take away from the page" meant. This draws a house instead: massing
// keyed to the property TYPE (a duplex has two doors, a condo is a
// stack), colour and detail keyed to the id, so a grid of twenty looks
// like twenty properties.
//
// Deliberately generic, and deliberately NOT `front`. It shows no street,
// no number and no surroundings, so it is not location-revealing and is
// not gated. The real exterior stays behind reveals_location, where it
// belongs, for when actual photographs arrive.
function hero(r, propertyType) {
  const [s1, s2] = SKIES[r(SKIES.length)];
  const [w1, w2] = WALLS[r(WALLS.length)];
  const roof = ROOFS[r(ROOFS.length)];
  const t = (propertyType || '').toLowerCase();
  const units = t.includes('duplex') ? 2 : t.includes('triplex') ? 3 : 1;
  const stacked = t.includes('condo') || t.includes('town');

  let body = '';
  if (stacked) {
    // A stack: floors banded, balconies, flat roof.
    const floors = 3 + r(2);
    const h = 92;
    const top = 500 - floors * h;
    body = `<rect x="250" y="${top}" width="300" height="${floors * h}" fill="url(#hw)"/>
      <rect x="238" y="${top - 16}" width="324" height="16" fill="${roof}"/>
      ${[...Array(floors)].map((_, f) => {
        const y = top + f * h;
        return `<line x1="250" y1="${y}" x2="550" y2="${y}" stroke="rgba(255,255,255,.5)" stroke-width="2"/>
          ${[0,1,2].map(c => windowPane(272 + c * 96, y + 20, 56, 44, r)).join('')}
          <rect x="262" y="${y + 74}" width="276" height="7" fill="#ffffff" opacity=".75"/>`;
      }).join('')}`;
  } else {
    // Pitched roof, one door bay per unit.
    const storeys = units > 1 ? 2 : 1 + r(2);
    const bodyH = storeys === 1 ? 176 : 248;
    const top = 500 - bodyH;
    const bays = units;
    const bayW = 300 / bays;
    body = `<path d="M226 ${top + 6} L400 ${top - 84} L574 ${top + 6} Z" fill="${roof}"/>
      <path d="M226 ${top + 6} L400 ${top - 84} L574 ${top + 6} Z" fill="#fff" opacity=".08"/>
      <rect x="218" y="${top}" width="364" height="12" fill="${TRIM}"/>
      <rect x="250" y="${top + 10}" width="300" height="${bodyH - 10}" fill="url(#hw)"/>
      ${[...Array(Math.floor((bodyH - 10) / 20))].map((_, i) =>
         `<line x1="250" y1="${top + 22 + i * 20}" x2="550" y2="${top + 22 + i * 20}" stroke="rgba(255,255,255,.32)" stroke-width="1"/>`).join('')}
      ${storeys === 2 ? [...Array(bays * 2)].map((_, i) =>
         windowPane(272 + (i % (bays * 2)) * (300 / (bays * 2)) + 6, top + 30, 40, 50, r)).join('') : ''}
      ${[...Array(bays)].map((_, i) => {
        const x = 250 + i * bayW;
        return `<rect x="${x + bayW / 2 - 26}" y="${500 - 96}" width="52" height="96" fill="#31465a" rx="3"/>
          <circle cx="${x + bayW / 2 + 16}" cy="${500 - 48}" r="4" fill="#e8eef4"/>
          ${bayW > 130 ? windowPane(x + 14, 500 - 148, 44, 52, r) : ''}`;
      }).join('')}`;
  }

  return frame(`<defs>
<linearGradient id="hs" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${s1}"/><stop offset="1" stop-color="${s2}"/></linearGradient>
<linearGradient id="hw" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${w1}"/><stop offset="1" stop-color="${w2}"/></linearGradient>
</defs>
<rect width="800" height="600" fill="url(#hs)"/>
<ellipse cx="${150 + r(120)}" cy="${96 + r(40)}" rx="94" ry="32" fill="#fff" opacity=".6"/>
<ellipse cx="${520 + r(160)}" cy="${70 + r(30)}" rx="70" ry="24" fill="#fff" opacity=".45"/>
<rect y="500" width="800" height="100" fill="#a9c49a"/>
<rect y="524" width="800" height="76" fill="#96b489"/>
${body}
<ellipse cx="${132 + r(40)}" cy="482" rx="58" ry="66" fill="#7d9c72"/>
<ellipse cx="${640 + r(50)}" cy="492" rx="48" ry="54" fill="#88a87c"/>
<ellipse cx="400" cy="562" rx="230" ry="26" fill="#8aa87d" opacity=".5"/>`,
  propertyType || 'Property', '#e6eef6');
}

const KINDS = {
  hero:    (r, type) => hero(r, type),
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
function render(propertyId, kind, propertyType) {
  const fn = KINDS[kind];
  if (!fn) return null;
  return fn(rng(propertyId + ':' + kind), propertyType);
}

module.exports = { render, KINDS: Object.keys(KINDS) };
