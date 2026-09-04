#!/usr/bin/env node
// =====================================================================
// scan-media.js  |  the operator entry point for the media store
// =====================================================================
//   docker compose run --rm worker node tools/scan-media.js
//   docker compose run --rm worker node tools/scan-media.js --reconcile
//   docker compose run --rm worker node tools/scan-media.js --purge
//
// SCAN     ingests everything sitting in inbox/. Files are re-encoded
//          (which is what strips EXIF), thumbnailed, stored under an id,
//          and registered as PENDING. Nothing becomes visible here.
//
// RECONCILE reports where the database and the filesystem disagree, and
//          fixes nothing. A row with no file may be a restore that went
//          wrong; a file with no row may be the only copy of something.
//          Deleting either to make a report clean is how real data is
//          lost, so this prints and stops.
//
// PURGE    destroys the bytes of rows that were unpublished long enough
//          ago, are not under legal hold, and are past their retention
//          date. Files first, then the row -- a crash between the two
//          leaves a file to be found again by reconcile, which is the
//          harmless direction.
'use strict';

const fs   = require('fs/promises');
const path = require('path');
const { makePool } = require('../src/db');
const ingest = require('../src/media/ingest');

const ROOT = process.env.SDI_MEDIA_ROOT || '/srv/media';

// sharp's own loader collects the reasons it failed and then formats them
// with `err.code.endsWith(...)`. One of the collected errors has no `code`,
// so the formatter throws and the real reason is lost -- you get
// "Cannot read properties of undefined (reading 'endsWith')" and no clue.
// This re-runs the two checks it would have reported, so the message names
// the actual problem.
function explain() {
  let native;
  try {
    native = require('@img/sharp-linux-x64/sharp.node');
  } catch (e) {
    return `the prebuilt binary would not load: ${e.message}`;
  }
  // The one that bites on a virtual machine. sharp's Linux x64 prebuilds
  // are compiled for the x86-64-v2 microarchitecture, and a hypervisor
  // configured to present a generic CPU model does not advertise it --
  // Proxmox's default kvm64, for instance, has no SSE4.2. The binary loads
  // and sharp then refuses it.
  if (typeof native._isUsingX64V2 === 'function' && !native._isUsingX64V2()) {
    return 'this CPU does not advertise the x86-64-v2 microarchitecture, which '
         + 'the prebuilt binaries require.\n\n'
         + 'On a virtual machine this is usually the hypervisor presenting a '
         + 'generic CPU model rather than the host\'s. In Proxmox, set the '
         + "VM's Processor type to `host` (or `x86-64-v2-AES`) and power-cycle "
         + 'it -- a reboot from inside the guest does not change it.';
  }
  return 'the binary loaded and sharp rejected it for an unreported reason';
}

let sharp;
try {
  sharp = require('sharp');
} catch (e) {
  console.error('cannot load sharp:', explain());
  console.error(`\n(underlying error: ${e.message})`);
  process.exit(2);
}

async function walk(dir, base = dir, out = []) {
  let entries;
  try { entries = await fs.readdir(dir, { withFileTypes: true }); } catch { return out; }
  for (const e of entries) {
    const full = path.join(dir, e.name);
    if (e.isDirectory()) await walk(full, base, out);
    else if (!e.name.startsWith('.')) out.push(path.relative(base, full));
  }
  return out;
}

async function doScan(db) {
  const { results } = await ingest.scan({ db, sharp, root: ROOT });
  if (!results.length) { console.log('inbox is empty'); return; }

  const by = (o) => results.filter((r) => r.outcome === o);
  for (const r of results) {
    if (r.outcome === 'ingested') {
      console.log(`  ${r.listingRef}  ${r.file}  ->  ${r.mediaId}`
                + `  ${(r.bytes / 1024).toFixed(0)}kB ${r.width}x${r.height}`
                + (r.strippedExif ? '  [exif stripped]' : ''));
    } else {
      console.log(`  ${r.folder}  ${r.file || ''}  ${r.outcome}`
                + (r.reason ? `: ${r.reason}` : '')
                + (r.files ? `: ${r.files} file(s)` : ''));
    }
  }
  console.log(`\n${by('ingested').length} ingested, `
            + `${by('quarantined').length} quarantined, `
            + `${by('skipped').length} still copying, `
            + `${by('error').length} errored`);
  const unsorted = by('unsorted').reduce((n, r) => n + r.files, 0);
  const unknown  = results.filter((r) => r.outcome === 'unknown-listing');
  if (unsorted) console.log(`${unsorted} photograph(s) in _unsorted await triage`);
  for (const u of unknown) console.log(`folder names ${u.listingRef}, which is not a listing`);
  if (by('ingested').length) {
    console.log('\nNothing is visible yet. Review and publish in the admin screen.');
  }
}

async function doReconcile(db) {
  const { rows } = await db.query('SELECT * FROM api.media_paths()');
  const known = new Map();
  for (const r of rows) {
    known.set(r.storage_path, r);
    if (r.thumb_path) known.set(r.thumb_path, r);
  }
  const onDisk = new Set(await walk(path.join(ROOT, 'store'), ROOT));

  const missing = [...known.keys()].filter((p) => !onDisk.has(p));
  const orphan  = [...onDisk].filter((p) => !known.has(p));

  console.log(`${known.size} path(s) in the database, ${onDisk.size} file(s) under store/`);
  for (const p of missing) console.log(`  ROW WITH NO FILE   ${p}  (${known.get(p).state})`);
  for (const p of orphan)  console.log(`  FILE WITH NO ROW   ${p}`);

  // Through the same function the purge job uses, so the two can never
  // report different numbers.
  const due = await db.query('SELECT media_id FROM api.media_purge_due()');
  if (due.rows.length) console.log(`  ${due.rows.length} row(s) due for purge`);

  if (!missing.length && !orphan.length) console.log('database and filesystem agree');
  else console.log('\nNothing was changed. A row with no file may be a restore that '
                 + 'failed; a file with no row may be the only copy of something.');
}

async function doPurge(db) {
  const { rows } = await db.query('SELECT * FROM api.media_purge_due()');
  if (!rows.length) { console.log('nothing is due'); return; }
  for (const r of rows) {
    for (const rel of [r.storage_path, r.thumb_path].filter(Boolean)) {
      await fs.rm(path.join(ROOT, rel), { force: true });
    }
    await db.query('SELECT api.media_purged($1)', [r.media_id]);
    console.log(`  purged ${r.media_id}`);
  }
  console.log(`\n${rows.length} destroyed. Note that backups taken before now still `
            + 'hold these files and age out on their own schedule.');
}

(async () => {
  const db = makePool();
  // Everything below acts as somebody. The scanner has its own service
  // account; reconcile and purge are admin operations and take whoever
  // the deployment says is running them.
  const actor = process.env.SDI_SCANNER_ACTOR || ingest.SERVICE_ACTOR;
  await db.query("SELECT set_config('app.actor_id', $1, false)", [actor]);

  try {
    if (process.argv.includes('--reconcile'))   await doReconcile(db);
    else if (process.argv.includes('--purge'))  await doPurge(db);
    else                                        await doScan(db);
  } catch (e) {
    console.error('failed:', e.message);
    process.exitCode = 1;
  } finally {
    await db.end();
  }
})();
