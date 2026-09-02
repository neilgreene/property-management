// =====================================================================
// admin.js  |  the intake review screen
// =====================================================================
// Jessica's view of what a spreadsheet actually contained, before any of
// it becomes a listing.
//
// The screen is deliberately not clever. Its whole job is to make three
// things impossible to miss: what the file said, what we made of it, and
// which rows a person has actually agreed to publish. Every action here
// is one of the four api functions -- review, approve-batch, release
// rows, release batch -- and the database refuses all of them for any
// role but staff, so this file contains no permission logic to get wrong.

const $ = (id) => document.getElementById(id);
const esc = (s) => String(s == null ? '' : s).replace(/[<>&"]/g,
  (c) => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;', '"': '&quot;' }[c]));
const usd = (n) => n == null ? '—' : '$' + Math.round(Number(n)).toLocaleString();
const pct = (n) => n == null ? '—' : (Number(n) * 100).toFixed(2) + '%';

let state = { batches: [], batchId: null, rows: [], selected: new Set() };

// A row can only be released once a person has approved it, so those are
// the only two states worth offering a tick box for.
const selectable = (r) => r.status === 'pending' || r.status === 'approved';

// ---------------------------------------------------------------------
async function call(path, opts) {
  const res = await fetch(path, opts);
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(body.error || `HTTP ${res.status}`);
  return body;
}

// ---------------------------------------------------------------------
function drawBatches() {
  $('batchlist').innerHTML = state.batches.length
    ? state.batches.map((b) => {
        const pills = [
          ['pending', b.rows_pending], ['invalid', b.rows_invalid],
          ['approved', b.rows_approved], ['rejected', b.rows_rejected],
          ['released', b.rows_released],
        ].filter(([, n]) => Number(n) > 0)
         .map(([k, n]) => `<span class="pill ${k}">${n} ${k}</span>`).join('');
        return `<div class="batch${b.batch_id === state.batchId ? ' on' : ''}"
                     data-id="${b.batch_id}">
          <div class="file">${esc(b.source_file)}</div>
          <div class="when">${new Date(b.uploaded_at).toLocaleString()}
            · ${b.rows_total} row${b.rows_total === '1' ? '' : 's'}
            ${b.note ? '· ' + esc(b.note) : ''}</div>
          <div class="pills">${pills}</div>
        </div>`;
      }).join('')
    : '<div class="empty">No batches loaded.</div>';

  document.querySelectorAll('.batch').forEach((el) =>
    el.addEventListener('click', () => selectBatch(el.dataset.id)));
}

function drawRows() {
  const b = state.batches.find((x) => x.batch_id === state.batchId);
  $('queuehead').innerHTML = b
    ? `<h1>${esc(b.source_file)}</h1><span class="muted">${b.rows_total} rows · ${esc(b.status)}</span>`
    : '';
  $('bulk').hidden = !state.rows.length;

  $('rows').innerHTML = state.rows.length
    ? state.rows.map((r) => {
        const probs = (r.problems || []).map((p) =>
          `<div class="prob ${esc(p.level)}"><b>${esc(p.level)}</b> ${esc(p.field)}: ${esc(p.message)}</div>`
        ).join('');
        const blocked = r.status === 'invalid';
        const tick = selectable(r)
          ? `<input type="checkbox" data-pick="${r.row_id}"
                    ${state.selected.has(r.row_id) ? 'checked' : ''}>` : '';
        return `<article class="irow${blocked ? ' blocked' : ''}">
          <div class="tick">${tick}</div>
          <div class="main">
            <div class="top">
              <span class="addr">${esc(r.street_address || '(no address)')}</span>
              <span class="loc">${esc(r.city || '')}${r.state ? ', ' + esc(r.state) : ''} ${esc(r.zip || '')}</span>
              <span class="pill ${esc(r.status)}">${esc(r.status)}</span>
            </div>
            <div class="facts">
              <div>price<b>${usd(r.list_price)}</b></div>
              <div>rent/mo<b>${usd(r.market_rent_monthly)}</b></div>
              <div>NOI<b>${usd(r.noi_annual)}</b></div>
              <div>cap rate<b>${pct(r.cap_rate)}</b></div>
              <div>beds/baths<b>${r.beds ?? '—'} / ${r.baths == null ? '—' : Number(r.baths)}</b></div>
              <div>sq ft<b>${r.sqft == null ? '—' : Number(r.sqft).toLocaleString()}</b></div>
              <div>built<b>${r.year_built ?? '—'}</b></div>
            </div>
            ${probs ? `<div class="probs">${probs}</div>` : ''}
            <div class="acts">
              <button class="linkish" data-raw="${r.row_id}">what the file said</button>
              ${r.status === 'released'
                ? `<span class="muted">→ ${esc(r.property_id || '')}</span>` : ''}
              ${r.review_note ? `<span class="muted">“${esc(r.review_note)}”</span>` : ''}
            </div>
          </div>
        </article>`;
      }).join('')
    : '<div class="empty">Select a batch.</div>';

  document.querySelectorAll('[data-pick]').forEach((el) =>
    el.addEventListener('change', () => {
      el.checked ? state.selected.add(el.dataset.pick) : state.selected.delete(el.dataset.pick);
      drawSelCount();
    }));
  document.querySelectorAll('[data-raw]').forEach((el) =>
    el.addEventListener('click', () => showRaw(el.dataset.raw)));
  drawSelCount();
}

function drawSelCount() {
  $('selcount').textContent = `${state.selected.size} selected`;
  // Keep the header box honest. Every action clears the selection and
  // redraws, and a "select all" box left ticked over an empty selection
  // makes the next click UNSELECT everything -- which looks like the
  // button being broken rather than the box being stale.
  const pickable = state.rows.filter(selectable);
  const all = pickable.length > 0 && pickable.every((r) => state.selected.has(r.row_id));
  $('selall').checked = all;
  $('selall').indeterminate = !all && state.selected.size > 0;
  const approved = state.rows.filter(
    (r) => state.selected.has(r.row_id) && r.status === 'approved').length;
  // Release only ever acts on approved rows, so saying so on the button
  // is more honest than letting somebody press it and read a list of
  // "skipped" lines afterwards.
  $('release').textContent = approved
    ? `Release ${approved} approved` : 'Release selected';
  $('release').disabled = approved === 0;
}

// ---------------------------------------------------------------------
async function showRaw(rowId) {
  const r = state.rows.find((x) => x.row_id === rowId);
  const d = await call('/api/intake/raw?row_id=' + encodeURIComponent(rowId));
  $('rawbody').innerHTML = `<div class="rawwrap">
    <h2>${esc(r ? r.street_address : '')}</h2>
    <p class="muted">Exactly what the spreadsheet contained, stored unedited.
      When a released listing says something surprising, this is what
      answers whether the file said it or we mistranslated it.</p>
    <pre>${esc(JSON.stringify(d.raw, null, 2))}</pre>
  </div>`;
  $('raw').hidden = false; $('scrim').hidden = false; $('raw').scrollTop = 0;
}

function closeRaw() { $('raw').hidden = true; $('scrim').hidden = true; }

// ---------------------------------------------------------------------
async function selectBatch(id) {
  state.batchId = id; state.selected.clear();
  drawBatches();
  state.rows = (await call('/api/intake/rows?batch_id=' + encodeURIComponent(id))).rows;
  drawRows();
}

async function refresh() {
  state.batches = (await call('/api/intake/batches')).rows;
  if (!state.batchId && state.batches.length) state.batchId = state.batches[0].batch_id;
  drawBatches();
  if (state.batchId) {
    state.rows = (await call('/api/intake/rows?batch_id='
      + encodeURIComponent(state.batchId))).rows;
    drawRows();
  }
}

function note(msg, kind = 'ok') {
  const el = document.createElement('div');
  el.className = 'banner ' + kind;
  el.innerHTML = msg;
  $('rows').prepend(el);
  setTimeout(() => el.remove(), 12000);
}

// ---------------------------------------------------------------------
$('selall').addEventListener('change', (e) => {
  state.selected.clear();
  if (e.target.checked) state.rows.filter(selectable).forEach((r) => state.selected.add(r.row_id));
  drawRows();
});

for (const [id, decision] of [['approve', 'approved'], ['reject', 'rejected']]) {
  $(id).addEventListener('click', async () => {
    if (!state.selected.size) return;
    const noteText = decision === 'rejected' ? prompt('Why rejected? (optional)') : null;
    try {
      const d = await call('/api/intake/review', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ row_ids: [...state.selected], decision, note: noteText }),
      });
      const asked = state.selected.size;
      state.selected.clear();
      await refresh();
      // An invalid row cannot be approved, so the count can legitimately
      // come back lower than the number ticked. Say so rather than
      // letting the reviewer think it worked.
      note(d.changed < asked
        ? `${d.changed} of ${asked} changed. Rows with a blocking error cannot be approved.`
        : `${d.changed} row${d.changed === 1 ? '' : 's'} ${decision}.`,
        d.changed < asked ? 'warn' : 'ok');
    } catch (e) { note(`Refused: ${esc(e.message)}`, 'warn'); }
  });
}

$('release').addEventListener('click', async () => {
  const ids = state.rows.filter((r) => state.selected.has(r.row_id) && r.status === 'approved')
                        .map((r) => r.row_id);
  if (!ids.length) return;
  if (!confirm(`Release ${ids.length} propert${ids.length === 1 ? 'y' : 'ies'} to the marketplace?`)) return;
  try {
    const d = await call('/api/intake/release', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ row_ids: ids }),
    });
    state.selected.clear();
    await refresh();
    const refs = d.released.filter((x) => x.outcome === 'released')
                           .map((x) => x.out_listing_ref);
    note(`Released ${refs.length}: ${refs.map(esc).join(', ')}`);
    // Governance is advisory, so a release can succeed and still leave
    // the listing published under no confirmed right. The reviewer is
    // told here rather than discovering it in a report later.
    const mine = (d.uncovered || []).filter((u) => refs.includes(u.listing_ref));
    if (mine.length) {
      note(`<b>${mine.length} published with no confirmed data right.</b> `
        + mine.map((u) => `${esc(u.listing_ref)} — ${esc(u.reason)}`).join('; ')
        + '. See docs/data-rights-intake.md.', 'warn');
    }
  } catch (e) { note(`Refused: ${esc(e.message)}`, 'warn'); }
});

$('closeraw').addEventListener('click', closeRaw);
$('scrim').addEventListener('click', closeRaw);
document.addEventListener('keydown', (e) => { if (e.key === 'Escape') closeRaw(); });
$('signout').addEventListener('click', async () => {
  await fetch('/api/logout', { method: 'POST' }); location.href = '/';
});

// ---------------------------------------------------------------------
(async function start() {
  const who = await (await fetch('/api/whoami')).json();
  $('whoami').textContent = who.signedIn ? who.label : 'Not signed in';
  $('signout').hidden = !who.signedIn;

  // Asking the server rather than trusting the role name in the session:
  // if the queue is refused, this is not a staff account, whatever it
  // calls itself.
  try {
    await call('/api/intake/batches');
  } catch {
    $('denied').hidden = false;
    return;
  }
  $('app').hidden = false;
  await refresh();
})();
