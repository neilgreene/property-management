'use strict';
// =====================================================================
// crm.js  |  agents, customers, opportunities, contracts
// =====================================================================
// Seven screens, one script. They differ in which endpoint fills the list,
// what a row says, and what the detail panel offers -- so those three
// things are a table and everything else is written once.
//
// NOTHING HERE DECIDES WHAT ANYBODY MAY SEE. Each endpoint calls a
// SECURITY DEFINER function that checks for itself, so a view reached by
// typing its name in the address bar returns the same rows as one reached
// from the menu, or an error. The rail hides what you cannot use; it does
// not enforce it.
(function () {
  const $ = (id) => document.getElementById(id);
  const esc = (s) => String(s == null ? '' : s)
    .replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;',
                                   '"': '&quot;', "'": '&#39;' }[c]));

  const money = (n) => n == null || n === ''
    ? '—' : '$' + Number(n).toLocaleString('en-US', { maximumFractionDigits: 0 });
  const pct = (n) => n == null ? '—' : (Number(n) * 100).toFixed(2) + '%';
  const day = (t) => !t ? '—'
    : new Date(t).toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' });

  const state = { view: null, rows: [], sel: null, who: null, lookups: {}, q: '' };

  // Every word has to appear somewhere in the row. Typed against what is
  // already loaded rather than a round trip: these lists are tens of rows,
  // not thousands, and a request per keystroke for that is waste.
  function matches(row, q) {
    if (!q) return true;
    const hay = Object.values(row)
      .filter((v) => v != null && typeof v !== 'object')
      .join(' ').toLowerCase();
    return q.toLowerCase().split(/\s+/).filter(Boolean).every((w) => hay.includes(w));
  }

  // ------------------------------------------------------------------
  async function api(path, body) {
    const r = await fetch('/api/crm/' + path, body
      ? { method: 'POST', headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(body) }
      : undefined);
    const j = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(j.error || 'that did not work');
    return j;
  }

  function say(text, bad) {
    const m = $('msg');
    m.textContent = text;
    m.className = 'msg ' + (bad ? 'bad' : 'good');
    m.hidden = false;
    clearTimeout(say._t);
    say._t = setTimeout(() => { m.hidden = true; }, 4000);
  }

  // The stage word decides the colour, so the two cannot disagree.
  function stageChip(stage) {
    const k = stage === 'approved' ? 'approved'
      : stage === 'draft' ? 'draft'
        : /declined|withdrawn/.test(stage) ? 'ended' : 'awaiting';
    return `<span class="stage ${k}">${esc(stage)}</span>`;
  }

  // ------------------------------------------------------------------
  // The seven screens
  // ------------------------------------------------------------------
  const VIEWS = {
    agents: {
      title: 'Agents',
      load: () => api('agents'),
      row: (a) => `<div class="ctop"><span class="cname">${esc(a.full_name)}</span>
          ${a.brokerage ? `<span class="pill">${esc(a.brokerage)}</span>` : ''}
          ${a.active ? '' : '<span class="stage ended">inactive</span>'}</div>
        <div class="cmeta"><span>${esc(a.email)}</span>
          ${a.phone ? `<span>${esc(a.phone)}</span>` : ''}
          <span><b>${a.customer_count}</b> customers</span>
          <span><b>${a.open_opportunities}</b> open</span></div>`,
      detail: agentDetail,
    },

    customers: {
      title: 'Customers',
      load: () => api('customers'),
      // "Ruiz, Dana" -- a list of customers is looked up by surname, so the
      // database sorts on it and the row leads with it.
      row: (c) => `<div class="ctop"><span class="cname">${esc(c.sort_name || c.full_name)}</span>
          ${c.approved_contracts > 0
            ? `<span class="stage approved">${c.unlocked_properties} unlocked</span>` : ''}
          ${c.signed ? '<span class="pill">fee agreement signed</span>' : ''}</div>
        <div class="cmeta"><span>${esc(c.email)}</span>
          ${c.agent_name ? `<span>agent <b>${esc(c.agent_name)}</b></span>` : ''}
          <span><b>${c.opportunity_count}</b> opportunities</span>
          <span><b>${c.contract_count}</b> contracts</span></div>`,
      detail: customerDetail,
    },

    'my-customers': {
      title: 'My customers',
      load: () => api('my-customers'),
      row: (c) => `<div class="ctop"><span class="cname">${esc(c.sort_name || c.full_name)}</span>
          ${c.contracts_awaiting_payment > 0
            ? `<span class="stage awaiting">${c.contracts_awaiting_payment} awaiting payment</span>` : ''}
          ${c.contracts_awaiting_signature > 0
            ? `<span class="stage awaiting">${c.contracts_awaiting_signature} awaiting signature</span>` : ''}
          ${c.contracts_approved > 0
            ? `<span class="stage approved">${c.contracts_approved} approved</span>` : ''}</div>
        <div class="cmeta"><span>${esc(c.email)}</span>
          ${c.phone ? `<span>${esc(c.phone)}</span>` : ''}
          <span><b>${c.properties_unlocked}</b> properties open to them</span>
          <span>last activity ${day(c.last_activity)}</span></div>`,
      detail: myCustomerDetail,
    },

    opportunities: {
      title: 'Opportunities',
      load: () => api('opportunities'),
      head: () => `<button class="primary" id="newopp">New opportunity</button>`,
      row: (o) => `<div class="ctop"><span class="cname">${esc(o.title)}</span>
          <span class="stage ${o.status === 'open' ? 'awaiting' : o.status === 'won' ? 'approved' : 'ended'}"
            >${esc(o.status)}</span></div>
        <div class="cmeta"><span>${esc(o.customer_name)}</span>
          ${o.agent_name ? `<span>agent <b>${esc(o.agent_name)}</b></span>` : ''}
          <span><b>${o.property_count}</b> properties</span>
          <span>opened ${day(o.created_at)}</span></div>`,
      detail: opportunityDetail,
    },

    contracts: {
      title: 'Contracts',
      load: () => api('contracts'),
      head: () => `<button class="primary" id="newcontract">New contract</button>`,
      row: (k) => `<div class="ctop"><span class="cref">${esc(k.reference)}</span>
          <span class="cname">${esc(k.customer_name)}</span>${stageChip(k.stage)}</div>
        <div class="cmeta"><span><b>${k.property_count}</b> properties</span>
          <span>fee <b>${money(k.fee_amount)}</b></span>
          ${k.opportunity_title ? `<span>${esc(k.opportunity_title)}</span>` : ''}
          <span>${k.approved_at ? 'approved ' + day(k.approved_at)
            : k.sent_at ? 'sent ' + day(k.sent_at) : 'not sent'}</span></div>`,
      detail: contractDetail,
    },

    'my-contracts': {
      title: 'My contracts',
      load: () => api('my-contracts'),
      row: (k) => `<div class="ctop"><span class="cref">${esc(k.reference)}</span>
          ${stageChip(k.stage)}</div>
        <div class="cmeta"><span><b>${k.property_count}</b> properties</span>
          <span>fee <b>${money(k.fee_amount)}</b></span>
          <span>${k.approved_at ? 'approved ' + day(k.approved_at)
            : 'sent ' + day(k.sent_at)}</span></div>`,
      detail: myContractDetail,
    },

    'my-properties': {
      title: 'My properties',
      load: () => api('my-properties'),
      // A grid of cards rather than a list: these are houses, and the
      // photograph is the point of having them unlocked at all.
      grid: true,
      card: (p) => `<article class="pcard">
          ${p.primary_image ? `<img src="${esc(p.primary_image)}" alt="">` : ''}
          <div class="pb">
            <div class="price">${money(p.list_price)}</div>
            <div class="addr">${esc(p.street_address || (p.city + ', ' + p.state))}</div>
            <div class="nums"><span>cap <b>${pct(p.cap_rate)}</b></span>
              <span>NOI <b>${money(p.noi_annual)}</b></span>
              <span>${esc(p.listing_ref)}</span></div>
            <div class="nums"><span>under <b>${esc(p.contract_reference)}</b></span></div>
          </div>
        </article>`,
    },
  };

  // ------------------------------------------------------------------
  // Detail panels
  // ------------------------------------------------------------------
  function facts(pairs) {
    return `<dl class="dfacts">${pairs
      .filter(([, v]) => v != null && v !== '')
      .map(([k, v]) => `<dt>${esc(k)}</dt><dd>${v}</dd>`).join('')}</dl>`;
  }

  function agentDetail(a) {
    return {
      head: a.full_name,
      sub: a.email + (a.phone ? ' · ' + a.phone : ''),
      body: `
        <div class="dsec">Details</div>
        <div class="dfields">
          <label>Licence number<input id="f_licence" value="${esc(a.licence_no || '')}"></label>
          <label>Brokerage<input id="f_brokerage" value="${esc(a.brokerage || '')}"></label>
          <label>Fee schedule<select id="f_metro"></select></label>
          <label>Notes<textarea id="f_notes">${esc(a.notes || '')}</textarea></label>
        </div>
        <div class="dact"><button class="primary" id="save">Save</button></div>
        ${facts([['Customers', a.customer_count], ['Open opportunities', a.open_opportunities],
                 ['GHL reference', a.external_ref ? esc(a.external_ref) : null]])}`,
      wire: async () => {
        await fillMetro('f_metro', a.metro_code);
        $('save').addEventListener('click', () => saveAgent(a));
      },
    };
  }

  function customerDetail(c) {
    return {
      head: c.full_name,
      sub: c.email + (c.phone ? ' · ' + c.phone : ''),
      body: `
        <div class="dsec">Details</div>
        <div class="dfields">
          <label>Agent<select id="f_agent"></select></label>
          <label>Target fee schedule<select id="f_metro"></select></label>
          <div class="dpair">
            <label>Budget from<input id="f_lo" type="number" step="1000"
              value="${c.budget_low == null ? '' : c.budget_low}"></label>
            <label>Budget to<input id="f_hi" type="number" step="1000"
              value="${c.budget_high == null ? '' : c.budget_high}"></label>
          </div>
        </div>

        <div class="dsec">Contact</div>
        <div class="dfields">
          <div class="dpair">
            <label>Mobile<input id="f_mobile" value="${esc(c.phone_mobile || '')}"></label>
            <label>Home<input id="f_phome" value="${esc(c.phone_home || '')}"></label>
          </div>
          <label>Work<input id="f_pwork" value="${esc(c.phone_work || '')}"></label>
          <label>Home address<textarea id="f_haddr">${esc(c.home_address || '')}</textarea></label>
          <label>Work address<textarea id="f_waddr">${esc(c.work_address || '')}</textarea></label>
          <label>Notes<textarea id="f_notes">${esc(c.notes || '')}</textarea></label>
        </div>
        <div class="dact"><button class="primary" id="save">Save</button></div>
        <div class="dsec">Access</div>
        ${facts([
          ['Fee agreement', c.signed ? 'signed' : 'not signed'],
          ['Contracts', c.contract_count],
          ['Approved', c.approved_contracts],
          ['Properties open to them', c.unlocked_properties],
          ['GHL reference', c.external_ref ? esc(c.external_ref) : null]])}`,
      wire: async () => {
        await fillAgents('f_agent', c.agent_id);
        await fillMetro('f_metro', c.target_metro);
        $('save').addEventListener('click', () => saveCustomer(c));
      },
    };
  }

  function myCustomerDetail(c) {
    return {
      head: c.full_name,
      sub: c.email + (c.phone ? ' · ' + c.phone : ''),
      body: `${facts([
          ['Mobile', c.phone_mobile ? esc(c.phone_mobile) : null],
          ['Home', c.phone_home ? esc(c.phone_home) : null],
          ['Work', c.phone_work ? esc(c.phone_work) : null],
          ['Home address', c.home_address ? esc(c.home_address) : null],
          ['Work address', c.work_address ? esc(c.work_address) : null],
          ['Target', c.target_metro],
          ['Budget', c.budget_low || c.budget_high
            ? money(c.budget_low) + ' – ' + money(c.budget_high) : null],
          ['Opportunities', c.opportunity_count],
          ['Properties open to them', c.properties_unlocked]])}
        ${c.notes ? `<p class="dsub" style="margin-top:12px">${esc(c.notes)}</p>` : ''}
        <div class="dsec">Contracts</div>
        <div id="kc" class="hist">…</div>`,
      wire: async () => {
        const rows = await api('my-customer-contracts?person=' + encodeURIComponent(c.person_id));
        $('kc').innerHTML = rows.length ? rows.map((k) => `
          <div class="hrow"><span class="hev">${esc(k.reference)}</span>
            ${stageChip(k.stage)}
            <span class="hwhen">${k.property_count} props · ${money(k.fee_amount)}</span></div>`).join('')
          : '<span class="cempty">No contracts yet.</span>';
      },
    };
  }

  function opportunityDetail(o) {
    return {
      head: o.title,
      sub: o.customer_name + (o.agent_name ? ' · agent ' + o.agent_name : ''),
      body: `${facts([['Status', esc(o.status)], ['Opened', day(o.created_at)],
                      ['Closed', o.closed_at ? day(o.closed_at) : null],
                      ['GHL reference', o.external_ref ? esc(o.external_ref) : null]])}
        ${o.notes ? `<p class="dsub" style="margin-top:12px">${esc(o.notes)}</p>` : ''}
        <div class="dsec">Properties</div>
        <div class="plist" id="props">…</div>
        <div class="dfields" style="margin-top:10px">
          <label>Add a property<select id="addprop"></select></label>
        </div>
        <div class="dact">
          ${o.status === 'open'
            ? `<button class="ghost" id="won">Mark won</button>
               <button class="ghost" id="lost">Mark lost</button>`
            : `<button class="ghost" id="reopen">Re-open</button>`}
        </div>`,
      wire: async () => {
        await drawOppProps(o);
        await fillProperties('addprop');
        $('addprop').addEventListener('change', async (e) => {
          if (!e.target.value) return;
          await act(() => api('opportunity-add',
            { opportunity_id: o.opportunity_id, property_id: e.target.value }),
            'Added to the opportunity.');
          e.target.value = '';
          await drawOppProps(o);
          refreshRow();
        });
        for (const [id, st] of [['won', 'won'], ['lost', 'lost'], ['reopen', 'open']]) {
          const b = $(id);
          if (b) b.addEventListener('click', () => act(
            () => api('close-opportunity', { opportunity_id: o.opportunity_id, status: st }),
            'Opportunity marked ' + st + '.', true));
        }
      },
    };
  }

  async function drawOppProps(o) {
    const rows = await api('opportunity-properties?id=' + encodeURIComponent(o.opportunity_id));
    $('props').innerHTML = rows.length ? rows.map((p) => `
      <div class="pitem"><span class="ref">${esc(p.listing_ref)}</span>
        <span>${esc(p.city)}, ${esc(p.state)}</span>
        <span>${money(p.list_price)}</span>
        ${p.unlocked ? '<span class="lock">unlocked</span>'
          : `<button class="rm" data-p="${esc(p.property_id)}" title="Remove">×</button>`}
      </div>`).join('') : '<span class="cempty">Nothing on this opportunity yet.</span>';
    $('props').querySelectorAll('.rm').forEach((b) => b.addEventListener('click', async () => {
      await act(() => api('opportunity-remove',
        { opportunity_id: o.opportunity_id, property_id: b.dataset.p }), 'Removed.');
      await drawOppProps(o);
      refreshRow();
    }));
  }

  function contractDetail(k) {
    const editable = k.status === 'draft';
    return {
      head: k.reference + ' · ' + k.customer_name,
      sub: '',
      body: `<div style="margin:-6px 0 12px">${stageChip(k.stage)}</div>
        ${facts([
          ['Fee', money(k.fee_amount)],
          ['Sent', k.sent_at ? day(k.sent_at) : null],
          ['Signed', k.signed_at ? day(k.signed_at) : null],
          ['Paid', k.paid_at ? day(k.paid_at) : null],
          ['Approved', k.approved_at ? day(k.approved_at) : null],
          ['Opportunity', k.opportunity_title ? esc(k.opportunity_title) : null]])}
        ${k.notes ? `<p class="dsub" style="margin-top:12px">${esc(k.notes)}</p>` : ''}

        <div class="dsec">Properties</div>
        <div class="plist" id="props">…</div>
        ${editable ? `<div class="dfields" style="margin-top:10px">
            <label>Add a property<select id="addprop"></select></label>
          </div>` : ''}

        <div class="dact">
          ${k.status === 'draft' ? '<button class="primary" id="send">Send to customer</button>' : ''}
          ${k.status === 'sent' && !k.signed_at
            ? '<button class="ghost" id="sign">Record signature</button>' : ''}
          ${k.status === 'sent' && !k.paid_at
            ? '<button class="ghost" id="pay">Record payment</button>' : ''}
          ${k.status === 'draft' || k.status === 'sent'
            ? '<button class="ghost" id="withdraw">Withdraw</button>' : ''}
        </div>

        <div class="dsec">History</div>
        <div class="hist" id="hist">…</div>`,
      wire: async () => {
        await drawContractProps(k);
        if (editable) {
          await fillProperties('addprop');
          $('addprop').addEventListener('change', async (e) => {
            if (!e.target.value) return;
            await act(() => api('contract-add',
              { contract_id: k.contract_id, property_id: e.target.value }), 'Added.');
            e.target.value = '';
            await drawContractProps(k);
            refreshRow();
          });
        }
        const on = (id, fn, msg) => { const b = $(id); if (b) b.addEventListener('click', () => act(fn, msg, true)); };
        on('send', () => api('send-contract', { contract_id: k.contract_id }), 'Sent to the customer.');
        on('sign', () => api('sign-contract', { contract_id: k.contract_id }), 'Signature recorded.');
        on('pay', () => api('record-payment', { contract_id: k.contract_id }), 'Payment recorded.');
        on('withdraw', () => api('end-contract',
          { contract_id: k.contract_id, status: 'withdrawn', reason: 'withdrawn from the panel' }),
          'Contract withdrawn.');

        const h = await api('contract-history?id=' + encodeURIComponent(k.contract_id));
        $('hist').innerHTML = h.length ? h.map((e) => `
          <div class="hrow"><span class="hev">${esc(e.event)}</span>
            <span>${esc(e.changed_by || '')}${e.detail ? ' · ' + esc(e.detail) : ''}</span>
            <span class="hwhen">${day(e.changed_at)}</span></div>`).join('')
          : '<span class="cempty">Nothing recorded.</span>';
      },
    };
  }

  async function drawContractProps(k) {
    const rows = await api('contract-properties?id=' + encodeURIComponent(k.contract_id));
    const editable = k.status === 'draft';
    $('props').innerHTML = rows.length ? rows.map((p) => `
      <div class="pitem"><span class="ref">${esc(p.listing_ref)}</span>
        <span>${esc(p.city)}, ${esc(p.state)}</span>
        <span>${money(p.list_price)}</span>
        ${p.unlocked ? '<span class="lock">open to them</span>'
          : editable ? `<button class="rm" data-p="${esc(p.property_id)}" title="Remove">×</button>` : ''}
      </div>`).join('') : '<span class="cempty">No properties. A contract with none unlocks nothing.</span>';
    $('props').querySelectorAll('.rm').forEach((b) => b.addEventListener('click', async () => {
      await act(() => api('contract-remove',
        { contract_id: k.contract_id, property_id: b.dataset.p }), 'Removed.');
      await drawContractProps(k);
      refreshRow();
    }));
  }

  // The customer's own view of a contract: the two things they can do.
  function myContractDetail(k) {
    return {
      head: k.reference,
      sub: '',
      body: `<div style="margin:-6px 0 12px">${stageChip(k.stage)}</div>
        ${facts([['Fee', money(k.fee_amount)],
                 ['Sent to you', day(k.sent_at)],
                 ['You signed', k.signed_at ? day(k.signed_at) : null],
                 ['You paid', k.paid_at ? day(k.paid_at) : null],
                 ['Approved', k.approved_at ? day(k.approved_at) : null]])}
        ${k.notes ? `<p class="dsub" style="margin-top:12px">${esc(k.notes)}</p>` : ''}
        <div class="dsec">Properties</div>
        <div class="plist" id="props">…</div>
        <div class="dact">
          ${k.status === 'sent' && !k.signed_at
            ? '<button class="primary" id="sign">Sign the agreement</button>' : ''}
          ${k.status === 'sent' && !k.paid_at
            ? `<button class="${k.signed_at ? 'primary' : 'ghost'}" id="pay">Pay the fee</button>` : ''}
        </div>`,
      wire: async () => {
        await drawContractProps(k);
        const on = (id, fn, msg) => { const b = $(id); if (b) b.addEventListener('click', () => act(fn, msg, true)); };
        on('sign', () => api('sign-contract', { contract_id: k.contract_id }), 'Signed.');
        on('pay', () => api('record-payment', { contract_id: k.contract_id }), 'Paid.');
      },
    };
  }

  // ------------------------------------------------------------------
  // Shared machinery
  // ------------------------------------------------------------------
  async function act(fn, msg, reload) {
    try {
      await fn();
      say(msg);
      if (reload) await load(state.view, state.sel);
    } catch (e) { say(e.message, true); }
  }

  function refreshRow() { load(state.view, state.sel); }

  async function saveAgent(a) {
    await act(() => api('save-agent', {
      person_id: a.person_id,
      licence_no: $('f_licence').value.trim(),
      brokerage: $('f_brokerage').value.trim(),
      metro_code: $('f_metro').value || null,
      notes: $('f_notes').value.trim(),
    }), 'Saved.', true);
  }

  async function saveCustomer(c) {
    const v = (id) => $(id).value.trim();
    await act(() => api('save-customer', {
      person_id: c.person_id,
      agent_id: $('f_agent').value || null,
      target_metro: $('f_metro').value || null,
      budget_low: $('f_lo').value,
      budget_high: $('f_hi').value,
      notes: v('f_notes'),
      home_address: v('f_haddr'),
      work_address: v('f_waddr'),
      phone_home: v('f_phome'),
      phone_work: v('f_pwork'),
      phone_mobile: v('f_mobile'),
    }), 'Saved.', true);
  }

  // Lookups, fetched once each. A select rebuilt on every detail open is
  // a request per click for a list that does not change.
  async function lookup(key, fn) {
    if (!state.lookups[key]) state.lookups[key] = fn();
    return state.lookups[key];
  }

  async function fillAgents(id, chosen) {
    const rows = await lookup('agents', () => api('agents'));
    $(id).innerHTML = '<option value="">— none —</option>'
      + rows.map((a) => `<option value="${esc(a.person_id)}"${a.person_id === chosen ? ' selected' : ''}
        >${esc(a.full_name)}</option>`).join('');
  }

  // One request for both. /api/admin/properties returns the list AND the
  // fee schedules in the same payload, and asking for it twice for two
  // selects on one panel is two round trips for one answer.
  const propertyPayload = () => lookup('props', async () => {
    const r = await fetch('/api/admin/properties');
    if (!r.ok) return { rows: [], metros: [] };
    const j = await r.json();
    return { rows: j.rows || [], metros: j.metros || [] };
  });

  async function fillProperties(id) {
    const { rows } = await propertyPayload();
    $(id).innerHTML = '<option value="">— choose —</option>'
      + rows.map((p) => `<option value="${esc(p.property_id)}"
        >${esc(p.listing_ref)} · ${esc(p.city)}, ${esc(p.state)}</option>`).join('');
  }

  async function fillMetro(id, chosen) {
    const { metros: rows } = await propertyPayload();
    $(id).innerHTML = '<option value="">— not set —</option>'
      + rows.map((m) => `<option value="${esc(m.metro_code)}"${m.metro_code === chosen ? ' selected' : ''}
        >${esc(m.display_name || m.metro_code)}</option>`).join('');
  }

  // ------------------------------------------------------------------
  function openDetail(row, key) {
    const v = VIEWS[state.view];
    if (!v.detail) return;
    state.sel = key;
    const d = v.detail(row);
    $('detailbody').innerHTML =
      `<div class="dhead">${esc(d.head)}</div>`
      + (d.sub ? `<p class="dsub">${esc(d.sub)}</p>` : '')
      + d.body;
    $('detail').hidden = false;
    $('wrap').classList.add('open');
    document.querySelectorAll('.crow').forEach((el) =>
      el.classList.toggle('on', el.dataset.k === String(key)));
    if (d.wire) d.wire();
  }

  function closeDetail() {
    state.sel = null;
    $('detail').hidden = true;
    $('wrap').classList.remove('open');
    document.querySelectorAll('.crow').forEach((el) => el.classList.remove('on'));
  }

  const keyOf = (r) => r.contract_id || r.opportunity_id || r.person_id || r.property_id;

  async function load(view, keep) {
    const v = VIEWS[view];
    state.view = view;
    $('title').textContent = v.title;
    $('viewname').textContent = v.title;
    document.title = 'SDI — ' + v.title;
    $('headact').innerHTML = v.head ? v.head() : '';

    let rows = [];
    try { rows = await v.load(); } catch (e) { say(e.message, true); }
    state.rows = rows;

    if (v.grid) {
      $('list').className = 'pgrid';
      draw();
      return;
    }

    $('list').className = 'crmlist';
    draw();

    // Re-open what was open, so an action that reloads the list does not
    // shut the panel the reader was working in.
    if (keep != null) {
      const i = rows.findIndex((r) => String(keyOf(r)) === String(keep));
      if (i >= 0) openDetail(rows[i], keep); else closeDetail();
    }
    wireHead();
  }

  // Draws whatever survives the search box. Separate from load() so typing
  // re-renders without re-fetching.
  function draw() {
    const v = VIEWS[state.view];
    const shown = state.rows.filter((r) => matches(r, state.q));
    $('count').textContent = state.q
      ? `${shown.length} of ${state.rows.length}`
      : (state.rows.length === 1 ? '1 row' : `${state.rows.length} rows`);

    if (v.grid) {
      $('list').innerHTML = shown.length ? shown.map(v.card).join('')
        : `<p class="cempty">${state.q ? 'Nothing matches \u201c' + esc(state.q) + '\u201d.'
          : 'Nothing yet. A property appears here once a contract naming it has '
            + 'been signed and paid.'}</p>`;
      return;
    }

    $('list').innerHTML = shown.length
      ? shown.map((r) => `<button class="crow" data-k="${esc(keyOf(r))}">${v.row(r)}</button>`).join('')
      : `<p class="cempty">${state.q ? 'Nothing matches \u201c' + esc(state.q) + '\u201d.'
        : 'Nothing here yet.'}</p>`;

    $('list').querySelectorAll('.crow').forEach((el, i) =>
      el.addEventListener('click', () => openDetail(shown[i], keyOf(shown[i]))));
    if (state.sel != null) {
      $('list').querySelectorAll('.crow').forEach((el) =>
        el.classList.toggle('on', el.dataset.k === String(state.sel)));
    }
  }

  function wireHead() {
    const n = $('newopp');
    if (n) n.addEventListener('click', newOpportunity);
    const c = $('newcontract');
    if (c) c.addEventListener('click', newContract);
  }

  async function newOpportunity() {
    const rows = await lookup('customers', () => api('customers'));
    const who = prompt('Customer (type part of the name):\n'
      + rows.map((r) => '· ' + r.full_name).join('\n'));
    if (!who) return;
    const m = rows.find((r) => r.full_name.toLowerCase().includes(who.toLowerCase()));
    if (!m) return say('No customer matched "' + who + '".', true);
    const title = prompt('Title for the opportunity:', m.full_name + ' — ');
    if (!title) return;
    await act(() => api('create-opportunity',
      { person_id: m.person_id, title, agent_id: m.agent_id || null }),
      'Opportunity created.', true);
  }

  async function newContract() {
    const rows = await lookup('customers', () => api('customers'));
    const who = prompt('Customer (type part of the name):\n'
      + rows.map((r) => '· ' + r.full_name).join('\n'));
    if (!who) return;
    const m = rows.find((r) => r.full_name.toLowerCase().includes(who.toLowerCase()));
    if (!m) return say('No customer matched "' + who + '".', true);
    const fee = prompt('Fee for this contract:', '750');
    if (fee === null) return;
    await act(() => api('create-contract',
      { person_id: m.person_id, fee_amount: fee || null }),
      'Contract created as a draft. Add properties, then send it.', true);
  }

  // ------------------------------------------------------------------
  async function start() {
    const view = new URLSearchParams(location.search).get('view') || 'contracts';
    if (!Object.prototype.hasOwnProperty.call(VIEWS, view)) {
      $('deniedwhy').textContent = 'There is no "' + view + '" screen.';
      $('denied').hidden = false;
      return;
    }

    state.who = await (await fetch('/api/whoami')).json();
    $('whoami').textContent = state.who.signedIn ? state.who.label : 'Not signed in';
    $('signin').hidden = state.who.signedIn;
    $('signout').hidden = !state.who.signedIn;
    $('signout').textContent = 'Sign out';
    $('signout').addEventListener('click', async () => {
      await fetch('/api/logout', { method: 'POST' });
      location.href = '/login.html';
    });

    if (!state.who.signedIn) {
      $('deniedwhy').textContent = 'Sign in to see this.';
      $('denied').hidden = false;
      return;
    }

    $('app').hidden = false;
    $('closedetail').addEventListener('click', closeDetail);
    $('q').addEventListener('input', () => { state.q = $('q').value.trim(); draw(); });
    await load(view);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', start);
  } else start();
})();
