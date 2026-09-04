'use strict';
// =====================================================================
// property-admin.js  |  the properties panel
// =====================================================================
// Laid out like the workbook -- the same A/B/C/D/E blocks in the same
// order, with the same field names -- so somebody who has worked the sheet
// for years does not have to learn where anything went.
//
// THE DERIVED FIGURES ARE COMPUTED TWICE, ON PURPOSE. The database owns
// them: api.property_admin defines total cost, day-one equity, the
// mortgage payment and cash outlay, and those are what get reported and
// published. This file recomputes them as somebody types, because a figure
// that only updates on save is a figure nobody trusts while they are
// working. On every save the server's numbers replace the local ones, so
// any disagreement surfaces immediately rather than living on screen.
const $ = (id) => document.getElementById(id);

const state = { list: [], metros: [], property: null, original: null,
                fees: null, patch: {} };

const usd  = (n) => n == null || n === '' ? '—'
  : '$' + Math.round(Number(n)).toLocaleString();
const usd2 = (n) => n == null || n === '' ? '—'
  : '$' + Number(n).toLocaleString(undefined, { minimumFractionDigits: 2,
                                                maximumFractionDigits: 2 });
const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g,
  (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

// ---------------------------------------------------------------------
// the fields, block by block, exactly as the workbook orders them
//
// `kind` decides how a value is shown and parsed. pct and rate are stored
// as fractions and bps respectively and shown as percentages, because
// "0.0649" in a rate box is how somebody enters 6.49% by mistake.
// ---------------------------------------------------------------------
const BLOCKS = {
  blockA: [
    ['beds', 'Bedrooms', 'int'],
    ['baths', 'Bathrooms', 'num'],
    ['sqft', 'Square feet', 'int'],
    ['year_built', 'Year built', 'int'],
    ['garage_spaces', 'Garage size', 'int'],
    ['lot_sqft', 'Lot size (sq ft)', 'int'],
    ['property_type', 'Type', 'text'],
  ],
  blockB: [
    ['offer_used', 'Offer used for analysis', 'money'],
    ['suggested_offer_low', 'Suggested offer (low)', 'money'],
    ['suggested_offer_high', 'Suggested offer (high)', 'money'],
    ['asking_price', 'Asking', 'money'],
    ['market_value_after', 'Market value (after improvements)', 'money'],
    ['improvements_low', 'Estimated improvements (lower)', 'money'],
    ['improvements_high', 'Estimated improvements (upper)', 'money'],
    ['closing_costs', 'Estimated closing costs', 'money'],
    ['mortgage_costs', 'Estimated mortgage costs', 'money'],
    ['other_fees', 'Other fees', 'money'],
    ['original_listed_on', 'Original listing date', 'date'],
  ],
  blockC: [
    ['down_payment_pct', 'Down payment (%)', 'pct'],
    ['interest_rate', 'Interest rate', 'pct'],
    ['mortgage_term_years', 'Mortgage term (years)', 'int'],
  ],
  blockD: [
    ['rent_upper_monthly', 'Rent (upper)', 'money'],
    ['rent_lower_monthly', 'Rent (lower)', 'money'],
    ['market_rent_monthly', 'Rent used for analysis', 'money'],
    ['property_tax_annual', 'Property taxes (year)', 'money'],
    ['insurance_annual', 'Insurance (year)', 'money'],
    ['maintenance_annual', 'Repairs (year)', 'money'],
    ['management_fee_bps', 'Property management (%)', 'bps'],
    ['leasing_fee_monthly', 'Leasing fee (month)', 'money'],
    ['hoa_annual', 'HOA or fixed costs (year)', 'money'],
    ['vacancy_allowance_bps', 'Vacancy rate', 'bps'],
    ['utilities_monthly', 'Utilities (month)', 'money'],
    ['utilities_paid_by', 'Utilities paid by', 'choice', ['owner', 'tenant', 'split']],
  ],
  blockE: [
    ['headline', 'Headline', 'text'],
    ['description', 'Description (public)', 'longtext'],
    ['internal_notes', 'Internal notes (never published)', 'longtext'],
  ],
};

// A percentage in the box, a fraction or basis points in the database.
//
// `trim` is +Number(...).toFixed(4) and not a regex, because the regex it
// replaced -- /\.?0+$/ -- stripped trailing zeros whether or not there was
// a decimal point, so a 30% down payment rendered as "3". Converting back
// to a number drops "30.0000" to 30 and leaves 6.49 alone.
const trim = (x) => String(+Number(x).toFixed(4));

function toInput(kind, v) {
  if (v == null || v === '') return '';
  if (kind === 'pct') return trim(Number(v) * 100);
  if (kind === 'bps') return trim(Number(v) / 100);
  if (kind === 'money' || kind === 'num') return trim(v);
  if (kind === 'date') return String(v).slice(0, 10);
  return String(v);
}
function fromInput(kind, s) {
  if (s === '' || s == null) return null;
  if (kind === 'pct') return String(Number(s) / 100);
  if (kind === 'bps') return String(Math.round(Number(s) * 100));
  return String(s);
}

function field(key, label, kind, choices) {
  const v = toInput(kind, state.property[key]);
  const suffix = kind === 'pct' || kind === 'bps' ? '<span class="unit">%</span>'
               : kind === 'money' ? '<span class="unit pre">$</span>' : '';
  const input = kind === 'longtext'
    ? `<textarea id="f_${key}" rows="4">${esc(v)}</textarea>`
    : kind === 'choice'
    ? `<select id="f_${key}"><option value=""></option>${choices.map((c) =>
        `<option${c === v ? ' selected' : ''}>${esc(c)}</option>`).join('')}</select>`
    : `<input id="f_${key}" type="${kind === 'date' ? 'date' : 'text'}"
              inputmode="${kind === 'text' ? 'text' : 'decimal'}" value="${esc(v)}">`;
  return `<label class="f f-${kind}"><span class="lbl">${esc(label)}</span>
            <span class="ctl">${suffix}${input}</span></label>`;
}

function renderFields() {
  for (const [id, defs] of Object.entries(BLOCKS)) {
    $(id).innerHTML = defs.map(([k, l, kind, ch]) => field(k, l, kind, ch)).join('');
    for (const [k, , kind] of defs) {
      $('f_' + k).addEventListener('input', () => onEdit(k, kind));
      $('f_' + k).addEventListener('change', () => onEdit(k, kind));
    }
  }
}

function onEdit(key, kind) {
  const raw = $('f_' + key).value;
  const val = fromInput(kind, raw);
  const was = state.original[key] == null ? null : String(state.original[key]);
  // Compared against the value the page loaded with, not the last
  // keystroke: typing a figure and typing it back should leave nothing to
  // save, and a patch full of unchanged fields is a change log full of
  // noise.
  if (val === was || (val == null && (was == null || was === ''))) delete state.patch[key];
  else state.patch[key] = val;

  state.property[key] = val;
  $('f_' + key).closest('.f').classList.toggle('changed', key in state.patch);
  redraw();
}

// ---------------------------------------------------------------------
// the same arithmetic the view does, for the moment between keystrokes
// ---------------------------------------------------------------------
const n = (v) => Number(v || 0);

function improvementEstimate(p) {
  const lo = p.improvements_low, hi = p.improvements_high;
  if (lo != null && lo !== '' && hi != null && hi !== '') return (n(lo) + n(hi)) / 2;
  return n(hi != null && hi !== '' ? hi : lo);
}

function derive(p) {
  const impr = improvementEstimate(p);
  const totalCost = n(p.offer_used) + impr + n(p.closing_costs)
                  + n(p.mortgage_costs) + n(p.other_fees);
  const down = n(p.offer_used) * n(p.down_payment_pct);
  const financed = n(p.offer_used) - down;
  const years = n(p.mortgage_term_years);
  const r = n(p.interest_rate) / 12;
  const months = years * 12;
  const payment = !years ? null
    : r === 0 ? financed / months
    : financed * r / (1 - Math.pow(1 + r, -months));

  const gross = n(p.market_rent_monthly) * 12;
  const vac = gross * n(p.vacancy_allowance_bps) / 10000;
  const mgmt = gross * n(p.management_fee_bps) / 10000;
  const util = p.utilities_paid_by === 'owner' ? n(p.utilities_monthly) * 12 : 0;
  const opex = n(p.property_tax_annual) + n(p.insurance_annual)
             + n(p.maintenance_annual) + util;
  const leasing = n(p.leasing_fee_monthly) * 12;
  const noi = gross - vac - mgmt - opex - n(p.hoa_annual) - leasing;

  return {
    impr, totalCost, down, financed, payment,
    equity: n(p.market_value_after) - totalCost,
    outlay: down + impr + n(p.closing_costs) + n(p.mortgage_costs) + n(p.other_fees),
    gross, vac, mgmt, opex, leasing, noi,
    annualDebt: payment == null ? null : payment * 12,
    cashFlow: payment == null ? null : noi - payment * 12,
    capRate: n(p.offer_used) ? noi / n(p.offer_used) : null,
  };
}

function row(label, value, cls) {
  return `<div class="d ${cls || ''}"><span>${esc(label)}</span><b>${value}</b></div>`;
}

function redraw() {
  const p = state.property, d = derive(p);
  $('derivedB').innerHTML =
      row('Estimated improvements (used)', usd(d.impr))
    + row('Total cost (estimated)', usd(d.totalCost))
    + row('Day-1 equity', usd(d.equity), d.equity < 0 ? 'bad' : 'good')
    + row('Days on market', p.days_on_market == null ? '—' : p.days_on_market);
  $('derivedC').innerHTML =
      row('Down payment amount', usd(d.down))
    + row('Financed amount', usd(d.financed))
    + row('Monthly mortgage payment', d.payment == null ? '—' : usd2(d.payment))
    + row('Cash outlay (total out of pocket)', usd(d.outlay), 'strong');
  $('derivedD').innerHTML =
      row('Gross scheduled rent (year)', usd(d.gross))
    + row('Vacancy allowance', '−' + usd(d.vac))
    + row('Management', '−' + usd(d.mgmt))
    + row('Leasing fee (year)', '−' + usd(d.leasing))
    + row('Operating expenses', '−' + usd(d.opex))
    + row('HOA', '−' + usd(n(p.hoa_annual)))
    + row('Net operating income', usd(d.noi), 'strong')
    + row('Annual debt service', d.annualDebt == null ? '—' : '−' + usd(d.annualDebt))
    + row('Cash flow after debt', d.cashFlow == null ? '—' : usd(d.cashFlow),
          d.cashFlow != null && d.cashFlow < 0 ? 'bad' : 'good')
    + row('Cap rate (on offer)', d.capRate == null ? '—'
          : (d.capRate * 100).toFixed(2) + '%');

  const dirty = Object.keys(state.patch).length;
  $('dirty').hidden = !dirty;
  $('dirty').textContent = `${dirty} unsaved change${dirty === 1 ? '' : 's'}`;
  $('save').disabled = !dirty;
  $('revert').disabled = !dirty;
}

// ---------------------------------------------------------------------
// the metro dropdown is a fee schedule
// ---------------------------------------------------------------------
function renderMetro() {
  const p = state.property;
  $('metro_code').innerHTML = '<option value="">— not set —</option>'
    + state.metros.map((m) =>
        `<option value="${esc(m.metro_code)}"${m.metro_code === p.metro_code ? ' selected' : ''}
         >${esc(m.label)}${m.kind === 'arrangement' ? '  (arrangement)' : ''}</option>`).join('');
  showFees();
}

const pct1 = (bps) => bps == null ? null : (bps / 100).toFixed(1) + '%';

// The programme's current fees are OFFERED. They are never applied
// silently, and a property already on an older schedule keeps it: a fee
// raised in March must not restate a deal agreed in January, or the
// projection stops matching the sheet somebody signed off from. So this
// states three things -- what the manager charges now, what this property
// is charged, and whether those are the same -- and leaves the decision to
// a person.
function showFees() {
  const code = $('metro_code').value;
  const m = state.metros.find((x) => x.metro_code === code);
  const f = state.fees;
  if (!m) { $('fees').hidden = true; return; }
  $('fees').hidden = false;
  $('fees').className = 'fees';

  if (!m.manager_name) {
    $('fees').innerHTML = `No property manager is recorded for <b>${esc(m.label)}</b>, so
      there is no fee schedule to apply. Management and leasing fees stay as typed.`;
    return;
  }

  const mgmt = pct1(m.management_fee_bps);
  const lease = m.leasing_fee_monthly == null ? null : usd2(m.leasing_fee_monthly) + '/mo';
  const current = `<b>${esc(m.manager_name)}</b> currently charges
    ${mgmt ? `<b>${mgmt}</b>` : '<i>an unrecorded management fee</i>'}
    and ${lease ? `<b>${lease}</b>` : '<i>an unrecorded leasing fee</i>'}${
      m.current_effective_from ? `, from ${esc(String(m.current_effective_from).slice(0, 10))}` : ''}.`;

  if (f && f.schedule_superseded) {
    // The interesting case, and the one worth spelling out.
    $('fees').className = 'fees feewarn';
    $('fees').innerHTML = `${current}
      This property is on the schedule from
      <b>${esc(String(f.applied_effective_from || '').slice(0, 10) || 'an earlier date')}</b>
      — ${pct1(f.property_management_fee_bps) || '—'} management,
      ${f.property_leasing_fee_monthly == null ? '—' : usd2(f.property_leasing_fee_monthly) + '/mo'}
      leasing — and keeps it until somebody moves it.
      <button id="applyfees" class="ghost sm">Move to the current schedule</button>`;
  } else if (mgmt || lease) {
    $('fees').innerHTML = `${current}
      <button id="applyfees" class="ghost sm">Apply to this property</button>`;
  } else {
    $('fees').innerHTML = `${current} Nothing to apply until a schedule is recorded.`;
  }

  const b = $('applyfees');
  if (b) b.addEventListener('click', applyFees);
}

async function applyFees() {
  const r = await fetch('/api/admin/apply-fees', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ property_id: state.property.property_id }),
  });
  const d = await r.json();
  $('msg').hidden = false;
  if (!r.ok) {
    $('msg').className = 'msg bad';
    $('msg').textContent = d.error || 'The schedule could not be applied.';
    return;
  }
  state.property = { ...d.property };
  state.original = { ...d.property };
  state.fees = d.fees;
  state.patch = {};
  renderFields(); renderMetro(); redraw();
  $('msg').className = 'msg good';
  $('msg').textContent = d.changed.length
    ? 'Moved to the current schedule: ' + d.changed.map((c) => c.field).join(', ') + '.'
    : 'This property was already on the current schedule.';
}

// ---------------------------------------------------------------------
// loading and saving
// ---------------------------------------------------------------------
async function openProperty(id) {
  const r = await fetch('/api/admin/property?id=' + encodeURIComponent(id));
  if (!r.ok) return;
  const d = await r.json();
  state.property = { ...d.property };
  state.original = { ...d.property };
  state.metros = d.metros;
  state.fees = d.fees;
  state.patch = {};

  $('sheet').hidden = false;
  $('addr').textContent = d.property.street_address
    ? `${d.property.street_address}${d.property.unit ? ' ' + d.property.unit : ''}, `
      + `${d.property.city}, ${d.property.state} ${d.property.zip || ''}`
    : `${d.property.city}, ${d.property.state}`;
  $('sub').textContent = `${d.property.listing_ref} · ${d.property.status} · `
    + `${d.property.published_photos} published photo(s), ${d.property.pending_photos} pending`;
  renderFields();
  renderMetro();
  renderHistory(d.history);
  redraw();
  document.querySelectorAll('.prow').forEach((el) =>
    el.classList.toggle('on', el.dataset.id === id));
}

function renderHistory(rows) {
  $('history').innerHTML = rows.length
    ? rows.map((h) => `<div class="h">
        <span class="hf">${esc(h.field)}</span>
        <span class="hv">${esc(h.old_value ?? '—')} → <b>${esc(h.new_value ?? '—')}</b></span>
        <span class="hw">${esc(h.actor)} · ${new Date(h.at).toLocaleString()}</span>
      </div>`).join('')
    : '<div class="muted">Nothing has been changed through this panel yet.</div>';
}

async function save() {
  $('msg').hidden = true;
  const r = await fetch('/api/admin/property', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ property_id: state.property.property_id, patch: state.patch }),
  });
  const d = await r.json();
  if (!r.ok) {
    $('msg').hidden = false;
    $('msg').className = 'msg bad';
    $('msg').textContent = d.error || 'The save was refused.';
    return;
  }
  // The server's figures replace the local ones. If the two ever disagree
  // the difference appears here, on save, rather than being discovered in
  // a report months later.
  state.property = { ...d.property };
  state.original = { ...d.property };
  state.patch = {};
  renderFields(); renderMetro(); redraw();
  document.querySelectorAll('.f').forEach((f) => f.classList.remove('changed'));
  $('msg').hidden = false;
  $('msg').className = 'msg good';
  $('msg').textContent = d.changed.length
    ? `Saved. ${d.changed.length} field${d.changed.length === 1 ? '' : 's'} changed: `
      + d.changed.map((c) => c.field).join(', ') + '.'
    : 'Nothing had changed, so nothing was written.';
  const h = await fetch('/api/admin/property?id=' + encodeURIComponent(state.property.property_id));
  if (h.ok) renderHistory((await h.json()).history);
}

function revert() {
  state.property = { ...state.original };
  state.patch = {};
  renderFields(); renderMetro(); redraw();
  document.querySelectorAll('.f').forEach((f) => f.classList.remove('changed'));
}

async function loadList(q) {
  const r = await fetch('/api/admin/properties' + (q ? '?q=' + encodeURIComponent(q) : ''));
  if (!r.ok) { $('denied').hidden = false; $('app').hidden = true; return; }
  const d = await r.json();
  state.list = d.rows; state.metros = d.metros;
  $('pcount').textContent = `${d.count} propert${d.count === 1 ? 'y' : 'ies'}`;
  $('plist').innerHTML = d.rows.map((r2) => `
    <button class="prow" data-id="${esc(r2.property_id)}">
      <span class="pref">${esc(r2.listing_ref)}</span>
      <span class="paddr">${esc(r2.street_address || r2.city)}</span>
      <span class="pmeta">${esc(r2.city)}, ${esc(r2.state)} · ${usd(r2.list_price)}
        ${r2.metro_label ? '· ' + esc(r2.metro_label) : ''}</span>
      ${r2.pending_photos ? `<span class="ppend">${r2.pending_photos} pending</span>` : ''}
    </button>`).join('');
  document.querySelectorAll('.prow').forEach((el) =>
    el.addEventListener('click', () => openProperty(el.dataset.id)));
}

// ---------------------------------------------------------------------
(async function start() {
  const who = await (await fetch('/api/whoami')).json();
  $('whoami').textContent = who.signedIn ? who.label : 'Not signed in';
  $('signout').hidden = !who.signedIn;
  $('signout').addEventListener('click', async () => {
    await fetch('/api/logout', { method: 'POST' }); location.href = '/login.html';
  });

  const probe = await fetch('/api/admin/properties');
  if (!probe.ok) { $('denied').hidden = false; return; }
  $('app').hidden = false;
  await loadList('');

  $('save').addEventListener('click', save);
  $('revert').addEventListener('click', revert);
  $('metro_code').addEventListener('change', () => {
    onEdit('metro_code', 'text');
    showFees();
  });
  let t = null;
  $('search').addEventListener('input', () => {
    clearTimeout(t); t = setTimeout(() => loadList($('search').value.trim()), 250);
  });
  // Leaving with unsaved edits is nearly always an accident.
  window.addEventListener('beforeunload', (e) => {
    if (Object.keys(state.patch).length) { e.preventDefault(); e.returnValue = ''; }
  });

  const id = new URLSearchParams(location.search).get('id');
  if (id) openProperty(id);
})();
