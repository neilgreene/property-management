'use strict';
// =====================================================================
// nav.js  |  one rail, on every page
// =====================================================================
// Written once and injected, rather than pasted into four HTML files.
// Four copies of a navigation menu is four places to add the next item and
// three places to forget.
//
// THE ADMIN SECTION IS A CONVENIENCE, NOT A CONTROL. It is hidden from
// anyone who is not staff, and hiding it protects nothing: every screen it
// links to refuses at the database, so a guessed url gets the same answer
// as a hidden link. The rail is about not showing people doors they cannot
// open, which is a courtesy rather than a security boundary -- worth being
// clear about, because a menu that looks like the permission model is how
// somebody later decides a check is redundant.
(function () {
  const ITEMS = [
    { href: '/',                    label: 'Browse',        icon: '⌕', group: 'main' },
    { href: '/?fav=1',              label: 'Favourites',    icon: '♥', group: 'main',
      id: 'railfav', signedInOnly: true },
    { href: '/property-admin.html', label: 'Properties',    icon: '⌂', group: 'admin' },
    { href: '/admin.html',          label: 'Intake review', icon: '⇥', group: 'admin' },
  ];
  // No Profile entry. The footer already carries the signed-in person's
  // photograph and name and links to the same page, and a second door to
  // one room makes the rail longer without making anything reachable.
  const PROFILE = '/profile.html';

  const esc = (s) => String(s == null ? '' : s)
    .replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;',
                                   '"': '&quot;', "'": '&#39;' }[c]));

  // Which build is running, in the corner of every screen. A deployed change
  // that is not visible looks exactly like a change that was never deployed,
  // and telling those apart used to mean going and reading a registry.
  //
  // The commit is shown as well as the version, because two builds can carry
  // the same version -- a fix pushed without a bump is the normal case -- and
  // the version alone would say they are the same when they are not.
  // Title-attribute, not on the face of it: seven characters of hex in the
  // menu is noise for everyone who is not currently chasing something.
  function buildLine(b) {
    if (!b || !b.version) return '';
    return `<div class="rbuild" title="${esc(b.commit ? 'commit ' + b.commit : 'not a published build')}"
            >v${esc(b.version)}${b.commit ? ` · ${esc(b.commit)}` : ''}</div>`;
  }

  // ------------------------------------------------------------------
  // Collapsed or not
  // ------------------------------------------------------------------
  // Two reasons to be a strip of icons: the reader asked, or the window is
  // too narrow to spend 196px on a menu. Both set the same class, so the
  // stylesheet has one definition of "collapsed" rather than a media query
  // and a near-copy of it for the button.
  //
  // Below NARROW the choice is not offered -- the rail is a strip whatever
  // the stored preference says, because 196px of menu on a phone leaves
  // nothing for the page. The preference is remembered through that and
  // takes effect again on a wider screen, so resizing does not silently
  // discard what somebody chose.
  const NARROW = 820;
  const PREF = 'sdi.rail.collapsed';

  function prefersCollapsed() {
    try { return localStorage.getItem(PREF) === '1'; } catch { return false; }
  }

  function applyRailMode() {
    const forced = window.innerWidth <= NARROW;
    const mini = forced || prefersCollapsed();
    document.body.classList.toggle('railmini', mini);
    const t = document.getElementById('railtoggle');
    if (t) {
      t.hidden = forced;                       // nothing to choose down here
      t.setAttribute('aria-expanded', String(!mini));
      t.title = mini ? 'Expand the menu' : 'Collapse the menu';
    }
  }

  function initials(name) {
    return String(name || '?').trim().split(/\s+/).slice(0, 2)
      .map((w) => w[0]).join('').toUpperCase();
  }

  async function build() {
    let who = { signedIn: false };
    try { who = await (await fetch('/api/whoami')).json(); } catch { /* offline */ }
    const staff = who.signedIn && (who.role === 'sdi_admin' || who.role === 'sdi_agent');
    const here = (location.pathname.replace(/index\.html$/, '') || '/') + location.search;

    // Matched on path AND query, because Browse is "/" and Favourites is
    // "/?fav=1": comparing paths alone lit both at once, which tells the
    // reader nothing about where they are.
    const link = (i) => {
      const active = here === i.href ? ' on' : '';
      return `<a class="ri${active}"${i.id ? ` id="${i.id}"` : ''} href="${i.href}"
              ><span class="ric">${i.icon}</span>
               <span class="rit">${esc(i.label)}</span>
               ${i.id === 'railfav' ? '<b class="rcount" hidden></b>' : ''}</a>`;
    };

    const show = (g) => ITEMS.filter((i) => i.group === g
      && !(i.signedInOnly && !who.signedIn));

    const rail = document.createElement('nav');
    rail.className = 'rail';
    rail.id = 'sdirail';
    rail.innerHTML = `
      <a class="rbrand" href="/"><span class="mark">SDI</span></a>

      <div class="rgroup">${show('main').map(link).join('')}</div>

      ${staff ? `<div class="rsec">Admin</div>
        <div class="rgroup">${show('admin').map(link).join('')}</div>` : ''}

      <div class="rfoot">
        ${who.signedIn ? `
          <a class="rme${here === PROFILE ? ' on' : ''}" href="${PROFILE}"
             title="${esc(who.label || '')}">
            <span class="ravatar" id="ravatar">${esc(initials(who.label))}</span>
            <span class="rmeta">
              <b>${esc(who.label || '')}</b>
              <i>${esc((who.role || '').replace('sdi_', ''))}</i>
            </span>
          </a>
          <button class="ri rout" id="rsignout"><span class="ric">⏻</span>
            <span class="rit">Sign out</span></button>`
        : `<a class="ri" href="/login.html"><span class="ric">→</span>
             <span class="rit">Sign in</span></a>`}
        ${buildLine(who.build)}
        <button class="rtoggle" id="railtoggle" type="button"
                aria-controls="sdirail" aria-expanded="true">
          <span class="ric">‹</span><span class="rit">Collapse</span>
        </button>
      </div>`;
    document.body.insertBefore(rail, document.body.firstChild);
    document.body.classList.add('hasrail');

    const toggle = document.getElementById('railtoggle');
    if (toggle) toggle.addEventListener('click', () => {
      const now = !prefersCollapsed();
      try { localStorage.setItem(PREF, now ? '1' : '0'); } catch { /* private mode */ }
      applyRailMode();
    });
    applyRailMode();
    // Resizing past the breakpoint changes which of the two reasons applies.
    window.addEventListener('resize', applyRailMode);

    const out = document.getElementById('rsignout');
    if (out) out.addEventListener('click', async () => {
      await fetch('/api/logout', { method: 'POST' });
      location.href = '/login.html';
    });

    // The photograph replaces the initials once it is known to exist. Two
    // requests rather than one so the rail renders immediately: a menu that
    // waits on an image is a menu that flickers.
    if (who.signedIn) {
      try {
        const me = await (await fetch('/api/profile')).json();
        if (me && me.avatar_path) {
          const el = document.getElementById('ravatar');
          el.innerHTML = `<img src="/media/avatar/${encodeURIComponent(me.person_id)}`
            + `?v=${encodeURIComponent(me.avatar_updated_at || '')}" alt="">`;
        }
      } catch { /* the initials stand */ }
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', build);
  } else build();
})();
