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
      </div>`;
    document.body.insertBefore(rail, document.body.firstChild);
    document.body.classList.add('hasrail');

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
