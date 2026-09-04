// =====================================================================
// app.js  |  the marketplace front end
// =====================================================================
// Worth saying once, because it is the whole argument of this demo: this
// file contains no security logic. It does not decide whose address to
// show, which photographs to display, or which listings to draw. It draws
// what /api/listings hands it. When a card says "address released after
// signing", that is because street_address arrived as null -- the browser
// found out at the same moment you did.
//
// The one thing to watch for when editing: never infer a value the server
// withheld. If street_address is null, do not fall back to city+zip and
// call it an address, and do not treat lat/lng as exact -- for a gated
// listing those coordinates are deliberately fuzzed.

const $ = (id) => document.getElementById(id);

// The filter bar's controls, by element id.
const NUMERIC = ['min_price', 'max_price', 'min_beds', 'min_baths', 'min_sqft', 'max_sqft'];
const TEXTUAL = ['city', 'property_type', 'sort'];
const FIELDS  = [...NUMERIC, ...TEXTUAL];

// Criteria the server understands that the bar has no control for. A
// parsed phrase ("exactly 3 bedrooms") or a saved search can set these,
// and dropping them silently would make a saved search return the wrong
// listings -- so they are carried alongside the form rather than lost.
const CARRIED = ['max_beds', 'max_baths', 'status', 'state', 'q'];

let state = { rows: [], identity: null, favorites: 0, mode: 'search', carried: {} };
let map = null, layer = null, markers = new Map();

const usd  = (n) => n == null ? '—' : '$' + Math.round(Number(n)).toLocaleString();
const usd0 = (n) => n == null ? '—' : '$' + Number(n).toLocaleString(undefined, { maximumFractionDigits: 0 });
const pct  = (n) => n == null ? '—' : (Number(n) * 100).toFixed(2) + '%';
const bps  = (n) => n == null ? '—' : (Number(n) / 100).toFixed(1) + '%';
const esc  = (s) => String(s == null ? '' : s).replace(/[<>&"]/g,
  (c) => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;', '"': '&quot;' }[c]));

// ---------------------------------------------------------------------
// criteria <-> form
// ---------------------------------------------------------------------
function readForm() {
  const c = { ...state.carried };
  for (const f of FIELDS) {
    const v = $(f).value;
    if (v === '' || v == null) continue;
    c[f] = NUMERIC.includes(f) ? Number(v) : v;
  }
  if (c.sort === 'ref') delete c.sort;
  return c;
}

function writeForm(c) {
  for (const f of FIELDS) $(f).value = c[f] == null ? '' : c[f];
  if (!c.sort) $('sort').value = 'ref';
  state.carried = {};
  for (const k of CARRIED) if (c[k] != null) state.carried[k] = c[k];
}

function query(c) {
  const p = new URLSearchParams();
  for (const [k, v] of Object.entries(c)) p.set(k, v);
  return p.toString();
}

// ---------------------------------------------------------------------
// map
// ---------------------------------------------------------------------
function initMap() {
  if (typeof L === 'undefined') return false;      // CDN blocked; fall back
  map = L.map('map', { zoomControl: true, scrollWheelZoom: true })
        .setView([39.5, -86.5], 5);
  L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', {
    maxZoom: 18, attribution: '© OpenStreetMap contributors',
  }).addTo(map);
  layer = L.layerGroup().addTo(map);
  return true;
}

function drawMap(rows) {
  markers.clear();
  if (!map) return drawFallback(rows);
  layer.clearLayers();
  if (!rows.length) return;

  for (const r of rows) {
    if (r.lat == null || r.lng == null) continue;
    const gated = !r.address_unlocked;
    const price = '$' + Math.round(Number(r.list_price) / 1000) + 'k';

    // A gated listing gets a circle, not a point. The coordinate the
    // server sent is fuzzed by roughly a mile, so drawing a sharp pin
    // would claim a precision the data does not have.
    if (gated) {
      L.circle([r.lat, r.lng], {
        radius: 1300, color: '#4d6785', weight: 1, dashArray: '4 3',
        fillColor: '#7f9dbe', fillOpacity: .1,
      }).addTo(layer);
    }
    const mk = L.marker([r.lat, r.lng], {
      icon: L.divIcon({
        className: '', iconSize: null,
        html: `<div class="pin${gated ? ' gated' : ''}">${price}</div>`,
      }),
    }).addTo(layer);
    mk.on('click', () => openDetail(r.property_id));
    mk.on('mouseover', () => highlight(r.property_id, true));
    mk.on('mouseout',  () => highlight(r.property_id, false));
    markers.set(r.property_id, mk);
  }
  const pts = rows.filter((r) => r.lat != null).map((r) => [Number(r.lat), Number(r.lng)]);
  if (pts.length) map.fitBounds(L.latLngBounds(pts).pad(0.25), { maxZoom: 12 });
}

// The map without a map library.
//
// Leaflet and its tiles come from a CDN, and a CDN is not always
// reachable -- an air-gapped host, a locked-down network, a proxy that
// does not allow it. When it is not, this draws the same information
// with no dependencies: every listing plotted to scale, priced, clickable,
// and hover-linked to its card, with gated listings drawn as a soft ring
// rather than a point because their coordinates are deliberately fuzzed.
//
// It is not a substitute for a basemap -- there are no roads on it, and
// it says so. It is a substitute for a blank grey rectangle.
function drawFallback(rows) {
  const el = $('mapfallback');
  const m = $('map'); if (m) m.hidden = true;
  el.hidden = false;
  const pts = rows.filter((r) => r.lat != null && r.lng != null);
  if (!pts.length) { el.innerHTML = '<div class="empty">No listings to plot.</div>'; return; }

  const lat = pts.map((r) => +r.lat), lng = pts.map((r) => +r.lng);
  // Pad the extent so nothing sits on the edge, and keep a floor so a
  // single listing does not zoom to a meaningless scale.
  const padY = Math.max((Math.max(...lat) - Math.min(...lat)) * 0.18, 0.35);
  const padX = Math.max((Math.max(...lng) - Math.min(...lng)) * 0.18, 0.45);
  const n = Math.max(...lat) + padY, so = Math.min(...lat) - padY;
  const w = Math.min(...lng) - padX, e = Math.max(...lng) + padX;
  const X = (v) => ((v - w) / (e - w)) * 1000;
  const Y = (v) => ((n - v) / (n - so)) * 1000;

  // Group by city so the labels do not repeat once per listing.
  const cities = {};
  for (const r of pts) {
    const k = r.city + ', ' + r.state;
    (cities[k] = cities[k] || { lat: 0, lng: 0, n: 0 });
    cities[k].lat += +r.lat; cities[k].lng += +r.lng; cities[k].n++;
  }

  // Listings in one city land within a few hundred metres of each other,
  // which at this scale is one pixel. Nudge collisions apart along a
  // widening spiral so every listing is clickable -- the same thing a
  // real map client does, and the reason it is honest here is that these
  // positions are already approximate for most viewers.
  const placed = [];
  const spread = (x, y) => {
    const R = 24;
    for (let k = 0; k < 40; k++) {
      const a = k * 2.399, rad = k === 0 ? 0 : R * Math.sqrt(k) * 0.9;
      const px = x + Math.cos(a) * rad, py = y + Math.sin(a) * rad;
      if (!placed.some((q) => Math.hypot(q[0] - px, q[1] - py) < R * 1.7)) {
        placed.push([px, py]); return [px, py];
      }
    }
    placed.push([x, y]); return [x, y];
  };

  const bubbles = pts.map((r) => {
    const gated = !r.address_unlocked;
    const [x, y] = spread(X(+r.lng), Y(+r.lat));
    const price = '$' + Math.round(Number(r.list_price) / 1000) + 'k';
    const wpx = 13 + price.length * 6.4;
    return `<g class="fb" data-id="${r.property_id}" style="cursor:pointer">
      ${gated ? `<circle cx="${x.toFixed(1)}" cy="${y.toFixed(1)}" r="26"
            fill="#7f9dbe" fill-opacity=".16" stroke="#4d6785" stroke-width="1"
            stroke-dasharray="4 3"/>` : ''}
      <rect x="${(x - wpx / 2).toFixed(1)}" y="${(y - 10).toFixed(1)}"
            width="${wpx.toFixed(1)}" height="20" rx="10"
            fill="${gated ? '#ffffff' : '#1d6fa8'}"
            stroke="${gated ? '#8fadc9' : '#ffffff'}" stroke-width="1.6"/>
      <text x="${x.toFixed(1)}" y="${(y + 4).toFixed(1)}" text-anchor="middle"
            font-size="12" font-weight="700" font-family="system-ui,sans-serif"
            fill="${gated ? '#4d6785' : '#ffffff'}">${price}</text>
      <title>${esc(r.listing_ref)} — ${esc(r.city)}, ${esc(r.state)} · ${usd(r.list_price)}${
        gated ? ' · approximate location' : ''}</title></g>`;
  }).join('');

  const labels = Object.entries(cities).map(([name, c]) =>
    `<text x="${X(c.lng / c.n).toFixed(1)}" y="${(Y(c.lat / c.n) - 26).toFixed(1)}"
       text-anchor="middle" font-size="13" font-weight="600" font-family="system-ui,sans-serif"
       fill="#5c7a96" opacity=".85">${esc(name)}</text>`).join('');

  el.innerHTML = `<svg viewBox="0 0 1000 1000" preserveAspectRatio="xMidYMid meet"
      style="width:100%;height:100%;display:block">
    <rect width="1000" height="1000" fill="#eaf1f8"/>
    ${[...Array(11)].map((_, i) => `<line x1="${i * 100}" y1="0" x2="${i * 100}" y2="1000" stroke="#dce7f1" stroke-width="1"/>
      <line x1="0" y1="${i * 100}" x2="1000" y2="${i * 100}" stroke="#dce7f1" stroke-width="1"/>`).join('')}
    ${labels}${bubbles}
  </svg>
  <div class="nobase">No basemap available — listings plotted to scale</div>`;

  el.querySelectorAll('.fb').forEach((g) => {
    g.addEventListener('click', () => openDetail(g.dataset.id));
    g.addEventListener('mouseenter', () => highlight(g.dataset.id, true));
    g.addEventListener('mouseleave', () => highlight(g.dataset.id, false));
  });
}

function highlight(id, on) {
  const card = document.querySelector(`.card[data-id="${id}"]`);
  if (card) card.classList.toggle('hi', on);
  const mk = markers.get(id);
  const el = mk && mk.getElement() && mk.getElement().firstChild;
  if (el) el.classList.toggle('hi', on);
  const g = document.querySelector(`#mapfallback .fb[data-id="${id}"]`);
  if (g) g.classList.toggle('hi', on);
}

// ---------------------------------------------------------------------
// cards
// ---------------------------------------------------------------------
function card(r) {
  const gated = !r.address_unlocked;
  const addr = gated
    ? `🔒 ${esc(r.city)}, ${esc(r.state)} — address released after signing`
    : `${esc(r.street_address)}${r.unit ? ' ' + esc(r.unit) : ''}, ${esc(r.city)}, ${esc(r.state)} ${esc(r.zip || '')}`;
  const heart = state.identity && state.identity.canFavorite
    ? `<button class="heart${r.is_favorite ? ' on' : ''}" data-fav="${r.property_id}"
         aria-label="${r.is_favorite ? 'Remove from favourites' : 'Add to favourites'}"
         aria-pressed="${!!r.is_favorite}">${r.is_favorite ? '♥' : '♡'}</button>` : '';

  return `<article class="card" data-id="${r.property_id}">
    <div class="shot">
      <img loading="lazy" alt=""
           data-fallback="/media/${r.property_id}/hero.svg"
           src="${esc(r.primary_image || '/media/' + r.property_id + '/hero.svg')}">
      <span class="badge">${esc(r.status.replace('_', ' '))}</span>${heart}
    </div>
    <div class="body">
      <div class="price">${usd(r.list_price)}</div>
      <div class="specs"><b>${r.beds}</b> bd · <b>${Number(r.baths)}</b> ba ·
        <b>${Number(r.sqft).toLocaleString()}</b> sqft · ${esc(r.property_type)}</div>
      <div class="addr${gated ? ' locked' : ''}">${addr}</div>
      <div class="metrics">
        <div>cap rate<b>${pct(r.cap_rate)}</b></div>
        <div>NOI<b>${usd(r.noi_annual)}</b></div>
        <div>ref<b>${esc(r.listing_ref)}</b></div>
      </div>
    </div>
  </article>`;
}

function draw(data) {
  state.rows = data.rows;
  state.identity = data.identity;
  $('grid').innerHTML = data.rows.length
    ? data.rows.map(card).join('')
    : '<div class="empty">No listings match these filters.</div>';
  $('count').textContent = `${data.count} ${data.count === 1 ? 'property' : 'properties'}`;
  $('scope').textContent = state.mode === 'favorites'
    ? 'your favourites'
    : (data.facets && data.facets.total != null ? `of ${data.facets.total} visible to you` : '');
  drawMap(data.rows);

  document.querySelectorAll('.card').forEach((c) => {
    c.addEventListener('click', (e) => {
      if (e.target.closest('[data-fav]')) return;
      openDetail(c.dataset.id);
    });
    c.addEventListener('mouseenter', () => highlight(c.dataset.id, true));
    c.addEventListener('mouseleave', () => highlight(c.dataset.id, false));
  });
  document.querySelectorAll('[data-fav]').forEach((b) =>
    b.addEventListener('click', (e) => { e.stopPropagation(); toggleFavorite(b.dataset.fav); }));
}

function fillSelects(data) {
  const keep = (el, vals, fmt) => {
    const cur = el.value;
    el.innerHTML = '<option value="">Any</option>' +
      vals.map((v) => `<option value="${esc(v)}">${esc(fmt ? fmt(v) : v)}</option>`).join('');
    el.value = cur;
  };
  if (data.cities) keep($('city'), data.cities);
  if (data.types)  keep($('property_type'), data.types);
  const f = data.facets || {};
  if ($('min_beds').options.length <= 1 && f.max_beds) {
    keep($('min_beds'),  Array.from({ length: f.max_beds }, (_, i) => i + 1), (v) => v + '+');
    keep($('min_baths'), [1, 1.5, 2, 2.5, 3, 3.5, 4], (v) => v + '+');
  }
}

// ---------------------------------------------------------------------
// the gate banner -- states the rule in words, from data, never guessed
// ---------------------------------------------------------------------
function banner(data) {
  const el = $('gate');
  const anyLocked = data.rows.some((r) => !r.address_unlocked);
  const anyOpen   = data.rows.some((r) => r.address_unlocked);
  el.classList.toggle('open', !anyLocked && anyOpen);
  if (!data.rows.length) { el.textContent = ''; return; }
  if (!anyLocked) {
    el.textContent = 'Addresses and exact map locations are shown: your platform fee agreement is on file.';
  } else if (anyOpen) {
    el.textContent = 'Addresses are shown for the properties you are assigned to. For the rest, the map shows an approximate area until the fee agreement is signed.';
  } else {
    el.textContent = 'Street addresses and exterior photographs are withheld until the $750 platform fee agreement is signed. Everything else — the numbers you underwrite on — is shown in full.';
  }
}

// ---------------------------------------------------------------------
// loading
// ---------------------------------------------------------------------
async function load(push = true) {
  const c = readForm();
  const url = state.mode === 'favorites' ? '/api/favorites' : '/api/listings?' + query(c);
  const data = await (await fetch(url)).json();
  if (state.mode === 'favorites') {
    data.count = data.rows.length;
    data.identity = state.identity;
    state.favorites = data.rows.length;
    $('favcount').textContent = data.rows.length;
  } else {
    fillSelects(data);
  }
  draw(data);
  banner(data);
  if (push && state.mode === 'search') {
    const q = query(c);
    history.replaceState(null, '', q ? '?' + q : location.pathname);
  }
}

// ---------------------------------------------------------------------
// the drill-down
// ---------------------------------------------------------------------
async function openDetail(id) {
  const res = await fetch('/api/property?id=' + encodeURIComponent(id));
  if (!res.ok) return;
  const { property: p, media, is_favorite } = await res.json();
  const gated = !p.address_unlocked;

  const rentM  = Number(p.market_rent_monthly || 0);
  const gross  = rentM * 12;
  const vac    = gross * (Number(p.vacancy_allowance_bps || 0) / 10000);
  const mgmt   = gross * (Number(p.management_fee_bps || 0) / 10000);
  const ownerU = p.utilities_paid_by === 'owner' ? Number(p.utilities_monthly || 0) * 12 : 0;
  const opex   = Number(p.property_tax_annual || 0) + Number(p.insurance_annual || 0)
               + Number(p.maintenance_annual || 0) + ownerU;
  const hoa    = Number(p.hoa_annual || 0);
  const net    = gross - vac - mgmt - opex - hoa;

  const lead = media[0], rest = media.slice(1, 3);
  const gallery = media.length ? `<div class="gallery">
      <img class="lead" data-fallback="/media/${p.property_id}/hero.svg"
           src="${esc(lead.url)}" alt="${esc(lead.caption)}">
      ${rest.map((m) => `<img class="thumb" loading="lazy" data-fallback="/media/${p.property_id}/hero.svg" src="${esc(m.thumb_url || m.url)}" alt="${esc(m.caption)}">`).join('')}
    </div>` : '';

  const feats = Array.isArray(p.features) ? p.features : [];

  $('detailbody').innerHTML = `${gallery}
  <div class="dwrap">
    <div class="dhead">
      <div>
        <div class="dprice">${usd(p.list_price)}</div>
        <div class="dspec"><b>${p.beds}</b> bd · <b>${Number(p.baths)}</b> ba ·
          <b>${Number(p.sqft).toLocaleString()}</b> sqft · ${esc(p.property_type)} · built ${p.year_built}</div>
        <div class="dspec">${gated
          ? `<span style="color:var(--gate)">🔒 ${esc(p.city)}, ${esc(p.state)} ${esc(p.zip || '')} — street address withheld</span>`
          : `${esc(p.street_address)}${p.unit ? ' ' + esc(p.unit) : ''}, ${esc(p.city)}, ${esc(p.state)} ${esc(p.zip || '')}`}
        </div>
      </div>
      <div class="muted">${esc(p.listing_ref)}<br>${esc(p.status.replace('_', ' '))}</div>
    </div>

    ${p.headline ? `<div class="dhl">${esc(p.headline)}</div>` : ''}
    ${p.description ? `<p class="ddesc">${esc(p.description)}</p>` : ''}

    <div class="kpis">
      <div class="kpi"><span>Cap rate</span><b>${pct(p.cap_rate)}</b></div>
      <div class="kpi"><span>Rent / month</span><b>${usd(p.market_rent_monthly)}</b></div>
      <div class="kpi"><span>NOI / year</span><b>${usd(p.noi_annual)}</b></div>
      <div class="kpi"><span>Price / sqft</span><b>${usd(Number(p.list_price) / Number(p.sqft))}</b></div>
    </div>

    <div class="note${gated ? '' : ' open'}">${gated
      ? 'The street address, the exact map pin and the exterior photograph are released once the $750 platform fee agreement is signed. The financial detail below is complete — nothing on this page is a teaser.'
      : 'Your fee agreement is on file, so the address, the exact location and the exterior photograph are shown.'}</div>

    <h2 class="sec">Income and operating expenses</h2>
    <table class="fin">
      <tr><td>Gross scheduled rent <span class="sub">${usd(p.market_rent_monthly)}/mo · ${esc((p.rent_basis || '').replace('_', ' '))}</span></td><td>${usd(gross)}</td></tr>
      <tr><td>Vacancy allowance <span class="sub">${bps(p.vacancy_allowance_bps)}</span></td><td>−${usd(vac)}</td></tr>
      <tr><td>Management <span class="sub">${bps(p.management_fee_bps)} of gross</span></td><td>−${usd(mgmt)}</td></tr>
      <tr><td>Property tax</td><td>−${usd(p.property_tax_annual)}</td></tr>
      <tr><td>Insurance</td><td>−${usd(p.insurance_annual)}</td></tr>
      <tr><td>Maintenance</td><td>−${usd(p.maintenance_annual)}</td></tr>
      <tr><td>Utilities <span class="sub">${usd(p.utilities_monthly)}/mo · paid by ${esc(p.utilities_paid_by || '—')}</span></td>
          <td>${ownerU ? '−' + usd(ownerU) : '<span class="sub">tenant</span>'}</td></tr>
      <tr><td>HOA</td><td>${hoa ? '−' + usd(hoa) : '<span class="sub">none</span>'}</td></tr>
      <tr class="total"><td>Net operating income</td><td>${usd(net)}</td></tr>
    </table>

    <h2 class="sec">${esc(p.city)}, ${esc(p.state)} — area</h2>
    <table class="fin">
      <tr><td>Median household income</td><td>${usd0(p.median_household_income)}</td></tr>
      <tr><td>Median home price</td><td>${usd0(p.area_median_price)}</td></tr>
      <tr><td>Median rent</td><td>${usd0(p.area_median_rent)}<span class="sub">/mo</span></td></tr>
      <tr><td>Rent growth, 1 yr</td><td>${bps(p.rent_growth_1y_bps)}</td></tr>
      <tr><td>Rental vacancy</td><td>${bps(p.area_vacancy_bps)}</td></tr>
      <tr><td>Price to income</td><td>${p.price_to_income == null ? '—' : Number(p.price_to_income).toFixed(1) + '×'}</td></tr>
      <tr class="total"><td>This rent as a share of local income
          <span class="sub">annual rent ÷ median household income</span></td>
        <td>${p.rent_to_area_income == null ? '—' : (Number(p.rent_to_area_income) * 100).toFixed(1) + '%'}</td></tr>
    </table>

    <h2 class="sec">The building</h2>
    <table class="fin">
      <tr><td>Lot size</td><td>${p.lot_sqft ? Number(p.lot_sqft).toLocaleString() + ' sqft' : '—'}</td></tr>
      <tr><td>Stories</td><td>${p.stories ?? '—'}</td></tr>
      <tr><td>Garage</td><td>${p.garage_spaces ? p.garage_spaces + ' space(s)' : 'none'}</td></tr>
      <tr><td>Parking</td><td>${esc(p.parking || '—')}</td></tr>
      <tr><td>Heating</td><td>${esc(p.heating || '—')}</td></tr>
      <tr><td>Cooling</td><td>${esc(p.cooling || '—')}</td></tr>
      <tr><td>Roof</td><td>${p.roof_year || '—'}</td></tr>
      <tr><td>Last renovated</td><td>${p.last_renovated || '—'}</td></tr>
    </table>
    ${feats.length ? `<h2 class="sec">Features</h2>
      <div class="tags">${feats.map((f) => `<span class="tag">${esc(f)}</span>`).join('')}</div>` : ''}

    ${state.identity && state.identity.canFavorite ? `<div class="dact">
      <button id="dfav" class="${is_favorite ? 'ghost' : 'primary'}" data-fav="${p.property_id}"
        aria-pressed="${!!is_favorite}">${is_favorite ? '♥ Saved to favourites' : '♡ Save to favourites'}</button>
    </div>` : ''}
  </div>`;

  $('detail').hidden = false; $('scrim').hidden = false;
  $('detail').scrollTop = 0;
  const b = $('dfav');
  if (b) b.addEventListener('click', () => toggleFavorite(b.dataset.fav, b));
}

function closeDetail() { $('detail').hidden = true; $('scrim').hidden = true; }

// ---------------------------------------------------------------------
// favourites
// ---------------------------------------------------------------------
async function toggleFavorite(id, btn) {
  const row = state.rows.find((r) => r.property_id === id);
  const on = btn ? btn.getAttribute('aria-pressed') !== 'true'
                 : !(row && row.is_favorite);
  const res = await fetch('/api/favorite', {
    method: on ? 'POST' : 'DELETE',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ property_id: id }),
  });
  if (!res.ok) return;
  if (row) row.is_favorite = on;

  const card = document.querySelector(`.card[data-id="${id}"] .heart`);
  if (card) { card.classList.toggle('on', on); card.textContent = on ? '♥' : '♡';
              card.setAttribute('aria-pressed', String(on)); }
  if (btn) { btn.setAttribute('aria-pressed', String(on));
             btn.className = on ? 'ghost' : 'primary';
             btn.textContent = on ? '♥ Saved to favourites' : '♡ Save to favourites'; }
  refreshFavCount();
  if (state.mode === 'favorites') load(false);
}

async function refreshFavCount() {
  if (!state.identity || !state.identity.canFavorite) return;
  const d = await (await fetch('/api/favorites')).json();
  state.favorites = d.count;
  $('favcount').textContent = d.count;
}

// ---------------------------------------------------------------------
// saved searches
// ---------------------------------------------------------------------
async function refreshSearches() {
  const sel = $('searchpicker');
  if (!state.identity || !state.identity.signedIn) { sel.hidden = true; return; }
  sel.hidden = false;
  const d = await (await fetch('/api/saved-search')).json();
  sel.innerHTML = '<option value="">Saved searches…</option>' +
    (d.rows || []).map((s) => `<option value="${esc(s.search_id)}">${esc(s.name)}${
      s.run_count ? ` · run ${s.run_count}×` : ''}</option>`).join('') +
    ((d.rows || []).length ? '<option value="__del">Delete a saved search…</option>' : '');
}

// ---------------------------------------------------------------------
// plain-English search
// ---------------------------------------------------------------------
$('ask').addEventListener('submit', async (e) => {
  e.preventDefault();
  const text = $('asktext').value.trim();
  const box = $('parsed');
  if (!text) { box.hidden = true; return; }
  const d = await (await fetch('/api/parse', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ text }),
  })).json();
  if (!d.explain) {
    box.hidden = false;
    box.innerHTML = `Nothing recognised in “${esc(text)}”. <span class="note">Try “3 bed duplex in Cleveland under 200k”.</span>`;
    return;
  }
  box.hidden = false;
  box.innerHTML = `Reading that as <b>${esc(d.explain)}</b> — <span class="note">the filters below now reflect it.</span>`;
  state.mode = 'search'; setMode();
  writeForm(d.criteria);
  load();
});

// ---------------------------------------------------------------------
// wiring
// ---------------------------------------------------------------------
function setMode() {
  const fav = state.mode === 'favorites';
  $('favtoggle').setAttribute('aria-pressed', String(fav));
  document.querySelector('.filters').style.opacity = fav ? '.45' : '1';
  document.querySelector('.filters').style.pointerEvents = fav ? 'none' : 'auto';
}

for (const f of FIELDS) {
  const el = $(f);
  el.addEventListener('change', () => { if (state.mode === 'search') load(); });
}

$('reset').addEventListener('click', () => {
  writeForm({}); state.carried = {}; $('asktext').value = ''; $('parsed').hidden = true;
  state.mode = 'search'; setMode(); load();
});

$('favtoggle').addEventListener('click', () => {
  state.mode = state.mode === 'favorites' ? 'search' : 'favorites';
  setMode(); load(false);
});

$('savesearch').addEventListener('click', async () => {
  const name = prompt('Name this search');
  if (!name) return;
  const res = await fetch('/api/saved-search', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ name, criteria: readForm() }),
  });
  if (res.ok) refreshSearches();
});

$('searchpicker').addEventListener('change', async (e) => {
  const v = e.target.value;
  if (!v) return;
  if (v === '__del') {
    e.target.value = '';
    const sel = $('searchpicker');
    const id = prompt('Name of the saved search to delete') || '';
    const opt = [...sel.options].find((o) => o.textContent.split(' · ')[0] === id.trim());
    if (!opt) return;
    await fetch('/api/saved-search', {
      method: 'DELETE', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ search_id: opt.value }),
    });
    return refreshSearches();
  }
  const d = await (await fetch('/api/saved-search/run', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ search_id: v }),
  })).json();
  if (!d.ok) return;
  state.mode = 'search'; setMode();
  $('parsed').hidden = true;
  writeForm(d.criteria);
  await load();
  refreshSearches();                       // run_count moved
});

$('closedetail').addEventListener('click', closeDetail);
$('scrim').addEventListener('click', closeDetail);
document.addEventListener('keydown', (e) => { if (e.key === 'Escape') closeDetail(); });

$('signout').addEventListener('click', async () => {
  await fetch('/api/logout', { method: 'POST' });
  location.reload();
});

// ---------------------------------------------------------------------
async function start() {
  const who = await (await fetch('/api/whoami')).json();
  $('whoami').textContent = who.signedIn ? who.label : 'Not signed in';
  $('whoami').title = who.note || '';
  $('signin').hidden  = who.signedIn;
  $('signout').hidden = !who.signedIn;

  if (!initMap()) $('mapfallback').hidden = false;

  // Deep links and back-button state: the URL is the criteria.
  const p = new URLSearchParams(location.search);
  const c = {};
  for (const f of [...FIELDS, ...CARRIED]) if (p.get(f)) c[f] = p.get(f);
  writeForm(c);

  await load(false);
  // canFavorite arrives with the listings payload, so these come after.
  $('favtoggle').hidden  = !(state.identity && state.identity.canFavorite);
  $('savesearch').hidden = !(state.identity && state.identity.signedIn);
  setMode();
  await refreshSearches();
  await refreshFavCount();
}
// A media row can outlive the file it names -- 108 Fairgrove's `front` is
// seeded before the photograph has been supplied, and a mistyped path looks
// exactly the same. Rather than a broken-image icon, fall back to the
// generated illustration. `error` does not bubble, hence the capture phase,
// and the guard stops a missing fallback from looping.
document.addEventListener('error', (e) => {
  const el = e.target;
  if (!(el instanceof HTMLImageElement) || el.dataset.fellBack) return;
  const alt = el.dataset.fallback;
  if (!alt || el.getAttribute('src') === alt) return;
  el.dataset.fellBack = '1';
  el.src = alt;
}, true);

start();
