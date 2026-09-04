// =====================================================================
// ingest.js  |  files dropped on the share become pending media rows
// =====================================================================
// Staff copy photographs into inbox/<listing folder>/ from a PC. Nothing
// about the file carries meaning: not its name, not its position in the
// folder. The folder says which property; everything else is decided
// later, by a person, in the panel.
//
// THE STEP THAT IS NOT OPTIONAL: re-encoding. A photograph taken on a
// phone carries GPS coordinates in its EXIF block, accurate to a few
// metres. Copy one to the share untouched and the exact location of the
// property is inside the file, readable by anything, for the one thing
// this platform exists to withhold. The gate would be intact in the
// database and bypassed in fact.
//
// So this runs on the share path as well as any browser upload, because a
// file copied from a PC never passed through a browser. sharp re-encodes
// from pixels and does not carry metadata across unless asked to.
'use strict';

const fs   = require('fs/promises');
const path = require('path');
const crypto = require('crypto');

// Deliberately generous on input, strict on output: anything sharp can
// decode is accepted, and everything is written as JPEG.
const MAX_BYTES  = 40 * 1024 * 1024;
const THUMB_EDGE = 720;
const FULL_EDGE  = 2048;
const QUALITY    = 82;

// A listing folder is named for its reference, optionally followed by a
// human label: "SDI-1009" or "SDI-1009 - Columbus OH - Single Family".
// The reference is what matters; the rest is there so somebody browsing
// the share recognises the property.
const REF = /^(SDI-\d+)/i;

function listingRefFromFolder(name) {
  const m = REF.exec(name.trim());
  return m ? m[1].toUpperCase() : null;
}

async function listFiles(dir) {
  let entries;
  try { entries = await fs.readdir(dir, { withFileTypes: true }); }
  catch { return []; }
  return entries.filter((e) => e.isFile() && !e.name.startsWith('.'))
                .map((e) => path.join(dir, e.name));
}

// Still being copied? A file whose size changes between two looks is not
// finished arriving, and ingesting half a JPEG produces a corrupt store
// entry plus a confusing quarantine record.
async function isSettled(file, waitMs = 400) {
  const a = await fs.stat(file);
  await new Promise((r) => setTimeout(r, waitMs));
  const b = await fs.stat(file);
  return a.size === b.size && a.size > 0;
}

async function quarantine(root, file, reason) {
  const dest = path.join(root, 'quarantine', `${Date.now()}-${path.basename(file)}`);
  await fs.mkdir(path.dirname(dest), { recursive: true });
  await fs.rename(file, dest).catch(() => {});
  await fs.writeFile(dest + '.reason.txt', reason + '\n').catch(() => {});
  return dest;
}

// One file, all the way through. Returns a result object rather than
// throwing, because one bad file must not stop the batch.
async function ingestFile({ db, sharp, root, file, propertyId, listingRef, settleMs }) {
  const base = path.basename(file);
  try {
    const st = await fs.stat(file);
    if (st.size > MAX_BYTES) {
      return { file: base, outcome: 'quarantined',
               reason: `${st.size} bytes exceeds the ${MAX_BYTES} limit`,
               at: await quarantine(root, file, 'too large') };
    }
    if (!await isSettled(file, settleMs)) {
      return { file: base, outcome: 'skipped', reason: 'still being copied' };
    }

    const input = await fs.readFile(file);

    // Sniff, do not trust the extension. A .jpg that is not an image is
    // either a mistake or an attack, and both belong in quarantine.
    let meta;
    try { meta = await sharp(input).metadata(); }
    catch (e) {
      return { file: base, outcome: 'quarantined', reason: `not an image: ${e.message}`,
               at: await quarantine(root, file, `not an image: ${e.message}`) };
    }
    if (!meta.width || !meta.height) {
      return { file: base, outcome: 'quarantined', reason: 'no dimensions',
               at: await quarantine(root, file, 'no dimensions') };
    }

    // rotate() with no argument applies the EXIF orientation and then
    // drops it -- without this, stripping metadata silently turns every
    // portrait photograph on its side.
    const pipeline = () => sharp(input).rotate();

    const fullBuf = await pipeline()
      .resize({ width: FULL_EDGE, height: FULL_EDGE,
                fit: 'inside', withoutEnlargement: true })
      .jpeg({ quality: QUALITY, progressive: true, mozjpeg: true })
      .toBuffer();
    const thumbBuf = await pipeline()
      .resize({ width: THUMB_EDGE, height: THUMB_EDGE,
                fit: 'inside', withoutEnlargement: true })
      .jpeg({ quality: 78, progressive: true, mozjpeg: true })
      .toBuffer();

    // Hash the OUTPUT, not the input. Two copies of one photograph that
    // differ only in metadata are the same picture, and should dedupe.
    const sha = crypto.createHash('sha256').update(fullBuf).digest();
    const out = await sharp(fullBuf).metadata();

    // The row is created before the bytes are written, and it hands back
    // the paths: the filename is the media_id, and the database owns that
    // convention so a second ingest route cannot invent a different one.
    // A crash between row and bytes leaves a row with no file, which
    // reconciliation reports; the reverse would leave an unowned file that
    // nothing can identify.
    const { rows } = await db.query(
      'SELECT * FROM api.media_register($1,$2,$3,$4,$5,$6)',
      [propertyId, sha, fullBuf.length, out.width, out.height, base]);
    const { out_media_id: mediaId,
            out_storage_path: relFull,
            out_thumb_path: relThumb } = rows[0];

    // A duplicate returns the existing row, whose files are already there.
    // Writing them again would be harmless but pointless.
    await fs.mkdir(path.join(root, path.dirname(relFull)), { recursive: true });
    await fs.writeFile(path.join(root, relFull),  fullBuf);
    await fs.writeFile(path.join(root, relThumb), thumbBuf);

    // Only now is the inbox copy redundant. An inbox that stays full is a
    // queue that stopped, and should be visible as one.
    await fs.unlink(file).catch(() => {});

    return { file: base, outcome: 'ingested', mediaId,
             bytes: fullBuf.length, width: out.width, height: out.height,
             strippedExif: Boolean(meta.exif) };
  } catch (e) {
    return { file: base, outcome: 'error', reason: e.message };
  }
}

// Walks inbox/, one folder per listing. Unknown folders are left alone
// rather than guessed at -- a photograph attached to the wrong property
// shows an investor a house that is not the one they are buying.
// The media ingest service account from 31_media_store.sql. Overridable
// so a person can run a scan under their own name and have the audit say
// so, but never blank: every authorisation predicate in this system keys
// on the actor, and an unset one is the 'public' role, which can do
// nothing.
const SERVICE_ACTOR = '00000000-0000-0000-0000-0000000000ff';

async function scan({ db, sharp, root, settleMs, actorId }) {
  await db.query("SELECT set_config('app.actor_id', $1, false)",
                 [actorId || process.env.SDI_SCANNER_ACTOR || SERVICE_ACTOR]);
  const inbox = path.join(root, 'inbox');
  let folders;
  try {
    folders = (await fs.readdir(inbox, { withFileTypes: true }))
      .filter((e) => e.isDirectory()).map((e) => e.name);
  } catch { return { folders: [], results: [] }; }

  const out = [];
  for (const folder of folders) {
    const ref = listingRefFromFolder(folder);
    if (!ref) {
      // _unsorted and anything else unnamed. Left for the panel to triage.
      const n = (await listFiles(path.join(inbox, folder))).length;
      if (n) out.push({ folder, outcome: 'unsorted', files: n });
      continue;
    }
    // Through api.listing_id, not core.property: the policies on that
    // table are scoped to the application roles, and the scanner is not
    // one of them -- a direct read returns zero rows and every folder
    // looks like an unknown listing.
    const { rows } = await db.query('SELECT api.listing_id($1) AS property_id', [ref]);
    if (!rows[0].property_id) {
      out.push({ folder, outcome: 'unknown-listing', listingRef: ref });
      continue;
    }
    for (const file of await listFiles(path.join(inbox, folder))) {
      out.push({ folder, listingRef: ref,
                 ...await ingestFile({ db, sharp, root, file, settleMs,
                                       propertyId: rows[0].property_id,
                                       listingRef: ref }) });
    }
  }
  return { folders, results: out };
}

module.exports = { scan, ingestFile, listingRefFromFolder, isSettled, SERVICE_ACTOR,
                   MAX_BYTES, THUMB_EDGE, FULL_EDGE };
