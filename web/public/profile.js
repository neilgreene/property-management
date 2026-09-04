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

function msg(text, bad) {
  $('pmsg').hidden = false;
  $('pmsg').className = 'msg ' + (bad ? 'bad' : 'good');
  $('pmsg').textContent = text;
}

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
$('file') && $('file').addEventListener('change', async () => {
  const f = $('file').files[0];
  if (!f) return;
  if (f.size > 8 * 1024 * 1024) return msg('That image is over 8 MB.', true);
  const dataUrl = await new Promise((res, rej) => {
    const fr = new FileReader();
    fr.onload = () => res(fr.result); fr.onerror = rej;
    fr.readAsDataURL(f);
  });
  const r = await fetch('/api/profile/photo', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ image: dataUrl }),
  });
  const d = await r.json();
  if (!r.ok) return msg(d.error || 'That could not be used.', true);
  me.avatar_path = d.avatar;
  me.avatar_updated_at = new Date().toISOString();
  paintAvatar();
  msg(`Saved — stored at ${(d.bytes / 1024).toFixed(0)} kB, metadata removed.`);
  $('file').value = '';
});

$('rmphoto') && $('rmphoto').addEventListener('click', async () => {
  const r = await fetch('/api/profile/photo', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ remove: true }),
  });
  if (!r.ok) return msg('That could not be removed.', true);
  me.avatar_path = null;
  paintAvatar();
  msg('Photograph removed.');
});

$('full_name') && $('full_name').addEventListener('input', () => {
  $('psave').disabled = $('full_name').value.trim() === (me.full_name || '');
});

$('psave') && $('psave').addEventListener('click', async () => {
  const r = await fetch('/api/profile', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ full_name: $('full_name').value.trim() }),
  });
  const d = await r.json();
  if (!r.ok) return msg(d.error || 'That could not be saved.', true);
  me = d;
  paintAvatar();
  $('psave').disabled = true;
  msg('Saved.');
});

load();
