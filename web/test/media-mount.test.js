'use strict';
// The guard against serving a media store that is not mounted.
//
// A separate filesystem for photographs is mounted `nofail`, which is right
// on a remote host -- a volume that fails to attach must not cost you SSH.
// The cost is that an absent volume is no longer an error: the host boots,
// the mount point stays an empty directory on the OS disk, and Docker
// bind-mounts that without complaint. Uploads land on the wrong disk and
// every existing photograph is missing from the application while the
// database still lists all of them. It looks like data loss, and nothing
// about it points at a mount.
//
// These tests spawn the real server and read its exit code, because the
// behaviour being asserted is refusing to start -- which is not something
// a unit test of a function can show.
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');

const SENTINEL = '.sdi-media-volume';

function tmpStore() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'sdi-media-'));
}

// Runs the server until it either exits or prints `until` on stdout, then
// stops it. Returns whatever it said and how it ended.
function run(env, until) {
  return new Promise((resolve) => {
    const p = spawn(process.execPath, [require.resolve('../server.js')], {
      env: { ...process.env, PORT: '0', COOKIE_INSECURE: '1', ...env },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let out = '', err = '', done = false;
    const finish = (code) => {
      if (done) return; done = true;
      p.kill();
      resolve({ code, out, err });
    };
    p.stdout.on('data', (d) => {
      out += d.toString();
      if (until && out.includes(until)) finish(null);
    });
    p.stderr.on('data', (d) => { err += d.toString(); });
    p.on('exit', (code) => finish(code));
    setTimeout(() => finish(null), 15000);
  });
}

test('an unmounted store stops the server rather than being served', async () => {
  // An empty directory is exactly what a bare mount point looks like.
  const store = tmpStore();
  const r = await run({ SDI_MEDIA_ROOT: store, SDI_MEDIA_SENTINEL: SENTINEL });

  assert.equal(r.code, 1,
    'THE SERVER STARTED ON AN UNMOUNTED STORE — it would write uploads to the '
    + 'OS disk and report every existing photograph as missing');
  assert.match(r.err, /FATAL/);
  assert.match(r.err, new RegExp(SENTINEL.replace('.', '\\.')));
  assert.match(r.err, /not\s+mounted/,
    'the message does not name the likely cause, which is the only thing that '
    + 'makes this failure diagnosable');
  fs.rmSync(store, { recursive: true, force: true });
});

test('a mounted store is recognised and start-up continues', async () => {
  const store = tmpStore();
  fs.writeFileSync(path.join(store, SENTINEL), '');
  // Stop at the line the check prints. Past this point the server goes on to
  // the database, which this test has nothing to say about.
  const r = await run({ SDI_MEDIA_ROOT: store, SDI_MEDIA_SENTINEL: SENTINEL },
                      'carries ' + SENTINEL);

  assert.match(r.out, new RegExp('media store: .* carries ' + SENTINEL.replace('.', '\\.')));
  assert.doesNotMatch(r.err, /FATAL/);
  fs.rmSync(store, { recursive: true, force: true });
});

test('a sentinel outside the store proves nothing and is refused', async () => {
  const store = tmpStore();
  // ../something would be satisfied by a file that has nothing to do with
  // the store, which would make the check pass while the store is absent.
  const r = await run({ SDI_MEDIA_ROOT: store, SDI_MEDIA_SENTINEL: '../etc/hostname' });

  assert.equal(r.code, 1, 'a sentinel outside the media root was accepted');
  assert.match(r.err, /resolves outside the media root/);
  fs.rmSync(store, { recursive: true, force: true });
});

test('with no sentinel set the server starts, and says the check is off', async () => {
  // Opt-in: a developer running against ./media has nothing mounted. But it
  // says so, because the failure this guards against is one that says nothing.
  const store = tmpStore();
  const r = await run({ SDI_MEDIA_ROOT: store, SDI_MEDIA_SENTINEL: '' },
                      'no sentinel configured');

  assert.match(r.out, /no sentinel configured/);
  assert.doesNotMatch(r.err, /FATAL/);
  fs.rmSync(store, { recursive: true, force: true });
});
