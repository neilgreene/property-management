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
                fees: null, notes: [], flag: null, isAdmin: false, patch: {},
                q: '', listFlag: 'all' };

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
  // A listing with no photograph shows no frame rather than a broken one:
  // an empty box in the header reads as a failure, and "no photographs
  // yet" is already said in the line underneath.
  $('shot').hidden = !d.property.primary_image;
  if (d.property.primary_image) $('shot').src = d.property.primary_image;
  $('addr').textContent = d.property.street_address
    ? `${d.property.street_address}${d.property.unit ? ' ' + d.property.unit : ''}, `
      + `${d.property.city}, ${d.property.state} ${d.property.zip || ''}`
    : `${d.property.city}, ${d.property.state}`;
  $('sub').textContent = `${d.property.listing_ref} · ${d.property.status} · `
    + `${d.property.published_photos} published photo(s), ${d.property.pending_photos} pending`;
  renderFields();
  renderMetro();
  renderNotes(d.notes || [], d.flag);
  renderHistory(d.history);
  redraw();
  document.querySelectorAll('.prow').forEach((el) =>
    el.classList.toggle('on', el.dataset.id === id));
}

// ---------------------------------------------------------------------
// notes
//
// Rows, not a field. The description above is one piece of prose somebody
// edits until it reads well; a note is an observation made at a moment by
// a person, and the second person to write one must not destroy the first.
// ---------------------------------------------------------------------
// A face beside a name. The initials stand in until the photograph loads
// and if it never does -- an author with no photograph is the normal case,
// not a failure.
function avatar(personId, name) {
  const ini = String(name || '?').trim().split(/\s+/).slice(0, 2)
    .map((w) => w[0]).join('').toUpperCase();
  return personId
    ? `<span class="nav2"><img alt="" src="/media/avatar/${esc(personId)}"
         onerror="this.replaceWith(document.createTextNode('${esc(ini)}'))">
       </span>`
    : `<span class="nav2">${esc(ini)}</span>`;
}

function when(ts) {
  const d = new Date(ts);
  return d.toLocaleString(undefined, { year: 'numeric', month: 'short', day: 'numeric',
                                       hour: '2-digit', minute: '2-digit' });
}

// A flag is a claim about the property right now, and it is computed from
// the notes that are still open -- so it can only ever say what somebody
// has written down and not since closed. Green is "nothing outstanding",
// which is why it is worth showing at all.
const FLAGS = {
  critical:  { word: 'Critical',  said: 'the deal is in trouble' },
  attention: { word: 'Attention', said: 'something needs doing' },
  ok:        { word: 'Clear',     said: 'nothing outstanding' },
};

function flagChip(flag, counts) {
  const f = FLAGS[flag] || FLAGS.ok;
  const n = [];
  if (counts && counts.open_critical) n.push(`${counts.open_critical} critical`);
  if (counts && counts.open_attention) n.push(`${counts.open_attention} to chase`);
  return `<span class="fchip ${esc(flag || 'ok')}" title="${esc(f.said)}">
    <i class="flag"></i>${esc(f.word)}${n.length ? ' · ' + esc(n.join(', ')) : ''}</span>`;
}

function renderFlag(flag) {
  state.flag = flag || null;
  const el = $('shflag');
  el.hidden = false;
  el.innerHTML = flagChip(flag ? flag.flag : 'ok', flag);
}

function renderNotes(rows, flag) {
  state.notes = rows;
  if (flag !== undefined) renderFlag(flag);
  $('notes').innerHTML = rows.length ? rows.map((n2) => `
    <article class="note ${n2.visibility} sev-${esc(n2.severity || 'note')}${
      n2.is_open ? ' unresolved' : ''}" data-id="${esc(n2.note_id)}">
      <header>
        ${avatar(n2.author_id, n2.author)}
        <span class="ntag">${n2.visibility === 'public' ? 'Public' : 'Internal'}</span>
        ${n2.severity && n2.severity !== 'note'
          ? `<span class="sevtag ${esc(n2.severity)}${n2.is_open ? '' : ' done'}">
               <i class="flag"></i>${esc(FLAGS[n2.severity].word)}${
                 n2.is_open ? '' : ' · resolved'}</span>` : ''}
        <span class="nwho">${esc(n2.author)}</span>
        <span class="nwhen">${esc(when(n2.created_at))}${
          n2.edited_at ? ' · edited ' + esc(when(n2.edited_at)) : ''}</span>
        <span class="nact">
          ${n2.severity !== 'note' && n2.is_open
            ? `<button class="link ok" data-resolve="${esc(n2.note_id)}">Resolve</button>` : ''}
          ${n2.severity !== 'note' && !n2.is_open
            ? `<button class="link" data-reopen="${esc(n2.note_id)}">Reopen</button>` : ''}
          ${n2.is_mine || state.isAdmin ? `
          <button class="link" data-edit="${esc(n2.note_id)}">Edit</button>
          <button class="link" data-del="${esc(n2.note_id)}">Remove</button>` : ''}
        </span>
      </header>
      <div class="nbody">${esc(n2.body)}</div>
      ${n2.resolved_at ? `<div class="nres">Resolved by
        ${esc(n2.resolved_by_name || 'someone')} · ${esc(when(n2.resolved_at))}${
          n2.resolution ? ' — ' + esc(n2.resolution) : ''}</div>` : ''}
    </article>`).join('')
    : '<div class="muted">No notes yet.</div>';

  $('notes').querySelectorAll('[data-del]').forEach((b) =>
    b.addEventListener('click', () => noteAction({ note_id: b.dataset.del, remove: true })));
  // Why it was resolved matters more than that it was: "roof re-quoted at
  // 4k, seller credit agreed" is the whole reason the flag came down.
  $('notes').querySelectorAll('[data-resolve]').forEach((b) =>
    b.addEventListener('click', () => {
      const r = prompt('What settled it? (optional)');
      if (r === null) return;
      noteAction({ note_id: b.dataset.resolve, resolve: true, resolution: r.trim() });
    }));
  $('notes').querySelectorAll('[data-reopen]').forEach((b) =>
    b.addEventListener('click', () => noteAction({ note_id: b.dataset.reopen, reopen: true })));
  $('notes').querySelectorAll('[data-edit]').forEach((b) =>
    b.addEventListener('click', () => {
      const n2 = state.notes.find((x) => x.note_id === b.dataset.edit);
      const body = prompt('Edit the note', n2.body);
      if (body != null && body.trim()) noteAction({ note_id: n2.note_id, body });
    }));
}

async function noteAction(payload) {
  const r = await fetch('/api/admin/note', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ property_id: state.property.property_id, ...payload }),
  });
  const d = await r.json();
  $('msg').hidden = false;
  if (!r.ok) {
    $('msg').className = 'msg bad';
    $('msg').textContent = d.error || 'The note could not be saved.';
    return;
  }
  $('msg').hidden = true;
  renderNotes(d.notes, d.flag);
  // The picker row is now stale in two ways -- last note and flag -- and
  // the panel is the only place either can change, so it repaints its own
  // row rather than making the user reload to see what they just wrote.
  const row = state.list.find((x) => x.property_id === state.property.property_id);
  if (row && d.flag) Object.assign(row, d.flag);
  if (row && d.notes && d.notes.length) {
    const last = d.notes[0];
    Object.assign(row, { last_note_author: last.author, last_note_author_id: last.author_id,
                         last_note_at: last.created_at, last_note_body: last.body,
                         last_note_visibility: last.visibility });
  }
  paintRow(state.property.property_id);
  refreshCounts();
}

// A note just changed this property's flag, so the tallies on the chips are
// stale. The rows are deliberately NOT replaced: pulling the open property
// out from under somebody because the note they just wrote moved it out of
// the current filter is a worse surprise than a count catching up a moment
// later.
async function refreshCounts() {
  const p = new URLSearchParams();
  if (state.q) p.set('q', state.q);
  try {
    const r = await fetch('/api/admin/properties' + (p.toString() ? '?' + p : ''));
    if (!r.ok) return;
    paintFlagFilter((await r.json()).counts, state.listFlag);
  } catch { /* the counts are a convenience; a failure here is not worth a banner */ }
}

// One row, redrawn where it stands. Reloading the whole list would lose
// the scroll position and the selection for the sake of one line of text.
function paintRow(id) {
  const el = document.querySelector(`.prow[data-id="${id}"]`);
  const row = state.list.find((x) => x.property_id === id);
  if (!el || !row) return;
  const fresh = document.createElement('div');
  fresh.innerHTML = pickerRow(row);
  const next = fresh.firstElementChild;
  next.classList.toggle('on', el.classList.contains('on'));
  next.addEventListener('click', () => openProperty(id));
  el.replaceWith(next);
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

// The flag rides on the reference, not off on its own: it is a fact about
// this property and reads as one there. Only the two colours that mean
// work are drawn -- a green dot on all twenty-five rows says nothing and
// makes the two red ones harder to find.
function pickerRow(r2) {
  return `<button class="prow" data-id="${esc(r2.property_id)}">
      ${r2.primary_image
        ? `<img class="pthumb" loading="lazy" alt="" src="${esc(r2.primary_image)}">`
        : '<span class="pthumb none"></span>'}
      <span class="ptext">
        <span class="pref">${esc(r2.listing_ref)}${
          r2.flag && r2.flag !== 'ok'
            ? `<i class="fdot ${esc(r2.flag)}" title="${
                 esc(FLAGS[r2.flag].said)}"></i>` : ''}</span>
        <span class="paddr">${esc(r2.street_address || r2.city)}</span>
        <span class="pmeta">${esc(r2.city)}, ${esc(r2.state)} · ${usd(r2.list_price)}
          ${r2.metro_label ? '· ' + esc(r2.metro_label) : ''}</span>
        ${r2.last_note_at ? `<span class="pnote">${esc(r2.last_note_author)}
          · ${esc(when(r2.last_note_at))}</span>` : ''}
      </span>
      ${r2.pending_photos ? `<span class="ppend">${r2.pending_photos} pending</span>` : ''}
    </button>`;
}

// The count on each chip is over the whole list, not the filtered one, so
// a person filtered down to Critical can still see there are three more
// needing attention behind it.
function paintFlagFilter(counts, active) {
  if (!counts) return;
  document.querySelectorAll('#flagfilter .fbtn').forEach((b) => {
    const k = b.dataset.flag;
    b.classList.toggle('on', k === (active || 'all'));
    b.querySelector('span').textContent = counts[k] == null ? '' : counts[k];
    // A filter that can only ever return nothing is worse than absent: it
    // invites a click and answers with an empty list. Dimmed, not hidden --
    // "no critical properties" is itself worth being able to see.
    b.classList.toggle('empty', k !== 'all' && !counts[k]);
  });
}

async function loadList(q, flag) {
  if (q !== undefined) state.q = q;
  if (flag !== undefined) state.listFlag = flag;
  const p = new URLSearchParams();
  if (state.q) p.set('q', state.q);
  if (state.listFlag && state.listFlag !== 'all') p.set('flag', state.listFlag);
  const r = await fetch('/api/admin/properties' + (p.toString() ? '?' + p : ''));
  if (!r.ok) { $('denied').hidden = false; $('app').hidden = true; return; }
  const d = await r.json();
  state.list = d.rows; state.metros = d.metros;
  paintFlagFilter(d.counts, d.flag);
  // Says what was asked for as well as what came back. "0 properties" on its
  // own reads as an empty database rather than as a filter doing its job.
  const scope = state.listFlag && state.listFlag !== 'all'
    ? ` flagged ${FLAGS[state.listFlag].word.toLowerCase()}` : '';
  $('pcount').textContent = d.count === 0 && scope
    ? `None${scope}`
    : `${d.count} propert${d.count === 1 ? 'y' : 'ies'}${scope}`;
  $('plist').innerHTML = d.rows.map(pickerRow).join('');
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

  state.isAdmin = who.role === 'sdi_admin';

  $('notebody').addEventListener('input', () => {
    $('addnote').disabled = !$('notebody').value.trim();
  });
  document.querySelectorAll('input[name=vis]').forEach((r) =>
    r.addEventListener('change', () => {
      $('viswarn').hidden = document.querySelector('input[name=vis]:checked').value !== 'public';
    }));
  document.querySelectorAll('input[name=sev]').forEach((r) =>
    r.addEventListener('change', () => {
      $('sevwarn').hidden = document.querySelector('input[name=sev]:checked').value === 'note';
    }));
  $('addnote').addEventListener('click', async () => {
    const body = $('notebody').value.trim();
    if (!body) return;
    await noteAction({ body,
      visibility: document.querySelector('input[name=vis]:checked').value,
      severity: document.querySelector('input[name=sev]:checked').value });
    $('notebody').value = '';
    $('addnote').disabled = true;
    // The level resets. A composer left on Critical turns the next three
    // ordinary notes into emergencies by inattention.
    document.querySelector('input[name=sev][value=note]').checked = true;
    $('sevwarn').hidden = true;
  });

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
  document.querySelectorAll('#flagfilter .fbtn').forEach((b) =>
    b.addEventListener('click', () => {
      // Clicking the active chip clears it. Otherwise the only way back to
      // everything is to find All, and people reach for the thing they just
      // pressed.
      loadList(undefined, state.listFlag === b.dataset.flag ? 'all' : b.dataset.flag);
    }));
  // Leaving with unsaved edits is nearly always an accident.
  window.addEventListener('beforeunload', (e) => {
    if (Object.keys(state.patch).length) { e.preventDefault(); e.returnValue = ''; }
  });

  const id = new URLSearchParams(location.search).get('id');
  if (id) openProperty(id);
})();
