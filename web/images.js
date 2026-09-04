'use strict';
// =====================================================================
// images.js  |  turning an uploaded image into something safe to store
// =====================================================================
// One function, used by every browser upload. It exists so the rule lives
// in one place rather than being re-implemented per feature: an avatar and
// a listing photograph get the same treatment, because the reason for the
// treatment is the same in both cases.
//
// RE-ENCODING IS THE POINT, not the resizing. A photograph taken on a
// phone carries GPS coordinates in its EXIF block. Staff take photographs
// at home. sharp decodes to pixels and writes a new file, so nothing but
// the picture survives -- and rotate() is applied first because stripping
// the orientation tag without acting on it turns every portrait image on
// its side.
const sharp = require('sharp');

const MAX_INPUT = 8 * 1024 * 1024;

// A data: url, which is how the browser sends a file without this server
// needing a multipart parser. The prefix is checked but not trusted --
// what the bytes actually are is decided by sharp.
function decodeDataUrl(s) {
  const m = /^data:image\/(png|jpe?g|webp|gif|avif);base64,([A-Za-z0-9+/=]+)$/.exec(s || '');
  if (!m) return null;
  const buf = Buffer.from(m[2], 'base64');
  return buf.length && buf.length <= MAX_INPUT ? buf : null;
}

async function toSquareJpeg(buf, edge = 384) {
  const meta = await sharp(buf).metadata();
  if (!meta.width || !meta.height) throw new Error('not an image');
  return sharp(buf)
    .rotate()                                   // apply, then drop, the orientation
    .resize({ width: edge, height: edge, fit: 'cover', position: 'attention' })
    .jpeg({ quality: 82, progressive: true, mozjpeg: true })
    .toBuffer();
}

module.exports = { decodeDataUrl, toSquareJpeg, MAX_INPUT };
