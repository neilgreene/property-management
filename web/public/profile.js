'use strict';
const $ = (id) => document.getElementById(id);
const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g,
  (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

let me = null;

function initials(n) {
  return String(n || '?').trim().split(/\s+/).slice(0, 2).map((w) => w[0]).join('').toUpperCase();
}

function paintAvatar() {
  $('av').innerHTML = me.avatar_path
    ? `<img src="/media/avatar/${encodeURIComponent(me.person_id)}`
      + `?v=${encodeURIComponent(me.avatar_updated_at || '')}" alt="">`
    : esc(initials(me.full_name));
  $('rmphoto').hidden = !me.avatar_path;
}

// Two message lines, not one. The photograph and the details are separate
// cards and a person watching the avatar will not see a result reported
// three inches below the fold in the other one -- which reads, exactly, as
// nothing having happened.
function msg(text, bad, where = 'pmsg') {
  const el = $(where);
  el.hidden = false;
  el.className = 'msg ' + (bad ? 'bad' : 'good');
  el.textContent = text;
}

function avmsg(text, bad) { msg(text, bad, 'avmsg'); }

async function load() {
  const r = await fetch('/api/profile');
  if (!r.ok) { $('denied').hidden = false; return false; }
  me = await r.json();
  if (!me) { $('denied').hidden = false; return false; }
  $('app').hidden = false;
  $('full_name').value = me.full_name || '';
  $('email').value = me.email || '';
  $('role').value = (me.role || '').replace('sdi_', '');
  paintAvatar();
  return true;
}

// The file is read in the browser and sent as a data url, so this server
// needs no multipart parser. The size is checked here for a quick answer
// and again on the server, which is the one that counts.
// EVERY PATH THROUGH HERE HAS TO SAY SOMETHING. This ran without a
// try/catch, so a request that failed before producing a response -- which
// is what an over-length body did -- threw into nothing and the page sat
// there. Silence is the one outcome a person cannot act on: they cannot
// tell a rejected file from a broken server from a click that missed.
$('file') && $('file').addEventListener('change', async () => {
  const f = $('file').files[0];
  if (!f) return;
  if (!/^image\//.test(f.type)) {
    $('file').value = '';
    return avmsg('That is not an image file.', true);
  }
  if (f.size > 8 * 1024 * 1024) {
    $('file').value = '';
    return avmsg(`That image is ${(f.size / 1048576).toFixed(1)} MB. The limit is 8 MB.`, true);
  }
  avmsg('Uploading…');
  try {
    const dataUrl = await new Promise((res, rej) => {
      const fr = new FileReader();
      fr.onload = () => res(fr.result);
      fr.onerror = () => rej(new Error('that file could not be read'));
      fr.readAsDataURL(f);
    });
    const r = await fetch('/api/profile/photo', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ image: dataUrl }),
    });
    // A failing route may answer with something that is not JSON at all --
    // a proxy error page, or nothing. Parsing it must not become the error.
    const d = await r.json().catch(() => ({}));
    if (!r.ok) return avmsg(d.error || `That could not be used (${r.status}).`, true);
    me.avatar_path = d.avatar;
    me.avatar_updated_at = new Date().toISOString();
    paintAvatar();
    avmsg(`Saved — stored at ${(d.bytes / 1024).toFixed(0)} kB, metadata removed.`);
  } catch (e) {
    avmsg('The upload did not reach the server. ' + (e.message || ''), true);
  } finally {
    $('file').value = '';
  }
});

$('rmphoto') && $('rmphoto').addEventListener('click', async () => {
  try {
    const r = await fetch('/api/profile/photo', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ remove: true }),
    });
    if (!r.ok) return avmsg('That could not be removed.', true);
    me.avatar_path = null;
    paintAvatar();
    avmsg('Photograph removed.');
  } catch {
    avmsg('That did not reach the server.', true);
  }
});

$('full_name') && $('full_name').addEventListener('input', () => {
  $('psave').disabled = $('full_name').value.trim() === (me.full_name || '');
});

$('psave') && $('psave').addEventListener('click', async () => {
  let r, d;
  try {
    r = await fetch('/api/profile', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ full_name: $('full_name').value.trim() }),
    });
    d = await r.json().catch(() => ({}));
  } catch {
    return msg('That did not reach the server.', true);
  }
  if (!r.ok) return msg(d.error || 'That could not be saved.', true);
  me = d;
  paintAvatar();
  $('psave').disabled = true;
  msg('Saved.');
});

load();
