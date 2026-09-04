// Time-based one-time passwords (RFC 6238), and the encryption that keeps
// the shared secret from being useful in a database dump.
//
// WHY TOTP AND NOT SMS OR EMAIL. SMS needs a provider this system does not
// have, and a phone number is transferable by anyone who can convince a
// carrier -- the SIM-swap attack is not theoretical and it defeats the
// factor entirely. Email needs mail delivery, which is a documented gap
// here, and a second factor delivered to an inbox protected by a password
// is not a second factor. An authenticator app needs neither, works
// offline, and the verification is arithmetic.
//
// THE UNCOMFORTABLE PART, STATED PLAINLY. A password can be stored as a
// one-way hash because the server only ever has to answer "did this match".
// A TOTP secret cannot: the server must recompute the code, so it needs the
// secret itself. Somebody who reads core.mfa reads working second factors.
//
// So the secret is encrypted with AES-256-GCM under a key that lives in the
// application's environment and NOT in the database. A dump is then inert
// on its own. This is real but it is not magic: an attacker who has both the
// dump and the application host has both halves. THE KEY MUST NOT BE STORED
// IN THE SAME BACKUP AS THE DATABASE, or the encryption buys nothing.
'use strict';

const crypto = require('crypto');

const DIGITS = 6;
const STEP = 30;          // seconds per code, the near-universal default
// One step either side, and no more. Every extra step of tolerance is
// another 30 seconds in which a shoulder-surfed code still works, and
// multiplies the odds for somebody guessing.
const SKEW = 1;

// --- base32, because that is what authenticator apps read ----------------
const B32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

function base32Encode(buf) {
  let bits = 0, value = 0, out = '';
  for (const byte of buf) {
    value = (value << 8) | byte; bits += 8;
    while (bits >= 5) { out += B32[(value >>> (bits - 5)) & 31]; bits -= 5; }
  }
  if (bits > 0) out += B32[(value << (5 - bits)) & 31];
  return out;
}

function base32Decode(str) {
  let bits = 0, value = 0;
  const out = [];
  for (const ch of String(str).toUpperCase().replace(/[\s=]/g, '')) {
    const i = B32.indexOf(ch);
    if (i < 0) throw new Error('not base32');
    value = (value << 5) | i; bits += 5;
    if (bits >= 8) { out.push((value >>> (bits - 8)) & 255); bits -= 8; }
  }
  return Buffer.from(out);
}

// --- the code itself ------------------------------------------------------
// HMAC-SHA1 is what RFC 6238 specifies and what every authenticator
// implements. Its weakness is collision resistance, which HMAC does not
// depend on; using SHA-256 here would be stronger on paper and unreadable
// by half the apps people already have installed.
function codeForStep(secret, step) {
  const counter = Buffer.alloc(8);
  counter.writeUInt32BE(Math.floor(step / 0x100000000), 0);
  counter.writeUInt32BE(step >>> 0, 4);
  const mac = crypto.createHmac('sha1', secret).update(counter).digest();
  const offset = mac[mac.length - 1] & 0x0f;
  const bin = ((mac[offset] & 0x7f) << 24) | (mac[offset + 1] << 16)
            | (mac[offset + 2] << 8) | mac[offset + 3];
  return String(bin % 10 ** DIGITS).padStart(DIGITS, '0');
}

function stepNow(at = Date.now()) {
  return Math.floor(at / 1000 / STEP);
}

// Returns the step the code matched, or null. The STEP IS RETURNED RATHER
// THAN A BOOLEAN on purpose: the caller stores it and refuses anything at or
// below it next time. Without that, a code is reusable for its whole
// thirty-second life by anyone who saw it -- over a shoulder, in a phishing
// proxy, in a screen share.
function verify(secret, code, { at = Date.now(), after = null } = {}) {
  const given = String(code || '').replace(/\s/g, '');
  if (!/^\d{6}$/.test(given)) return null;
  const now = stepNow(at);
  for (let d = -SKEW; d <= SKEW; d++) {
    const step = now + d;
    if (after !== null && step <= after) continue;
    const expected = codeForStep(secret, step);
    // Constant time. The compare is on six digits, so the leak is small,
    // but "small enough not to bother" is how timing oracles get shipped.
    if (crypto.timingSafeEqual(Buffer.from(expected), Buffer.from(given))) {
      return step;
    }
  }
  return null;
}

function newSecret() {
  // 20 bytes is the RFC 4226 recommendation and what every app expects.
  return crypto.randomBytes(20);
}

// The URI an authenticator app reads out of the QR code. The issuer appears
// twice by convention: in the label so older apps show it, and as a
// parameter so newer ones group by it.
function otpauthUri(secret, email, issuer = 'SDI') {
  const label = encodeURIComponent(`${issuer}:${email}`);
  return `otpauth://totp/${label}?secret=${base32Encode(secret)}`
       + `&issuer=${encodeURIComponent(issuer)}&algorithm=SHA1`
       + `&digits=${DIGITS}&period=${STEP}`;
}

// --- encryption at rest ---------------------------------------------------
function key() {
  const raw = process.env.SDI_MFA_KEY;
  if (!raw) {
    // Loud, not silent. A default key would mean every deployment shares
    // one, which is the same as no encryption while looking like some.
    const e = new Error(
      'SDI_MFA_KEY is not set. Generate one with '
      + '`node -e "console.log(require(\'crypto\').randomBytes(32).toString(\'base64\'))"` '
      + 'and set it in the environment. It must not be stored in the same '
      + 'backup as the database.');
    e.code = 'NO_MFA_KEY';
    throw e;
  }
  const k = Buffer.from(raw, 'base64');
  if (k.length !== 32) throw new Error('SDI_MFA_KEY must be 32 bytes, base64 encoded');
  return k;
}

function seal(secret) {
  const iv = crypto.randomBytes(12);
  const c = crypto.createCipheriv('aes-256-gcm', key(), iv);
  const body = Buffer.concat([c.update(secret), c.final()]);
  // v1$iv$tag$ciphertext. The version prefix is so a future key rotation or
  // algorithm change can be detected rather than guessed at.
  return `v1$${iv.toString('base64')}$${c.getAuthTag().toString('base64')}`
       + `$${body.toString('base64')}`;
}

function open(sealed) {
  const parts = String(sealed || '').split('$');
  if (parts.length !== 4 || parts[0] !== 'v1') throw new Error('unreadable mfa secret');
  const [, iv, tag, body] = parts;
  const d = crypto.createDecipheriv('aes-256-gcm', key(), Buffer.from(iv, 'base64'));
  d.setAuthTag(Buffer.from(tag, 'base64'));
  return Buffer.concat([d.update(Buffer.from(body, 'base64')), d.final()]);
}

function keyConfigured() {
  try { key(); return true; } catch { return false; }
}

// --- recovery codes -------------------------------------------------------
// These CAN be hashed, unlike the TOTP secret: the server only ever has to
// answer "did this match", never to reproduce one. So a dump of the recovery
// table is worth nothing on its own even without the key.
//
// Ten of them. Grouped in fours because people transcribe them by hand, and
// drawn from an alphabet with no 0/O or 1/I/l for the same reason.
const RC = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

function newRecoveryCodes(n = 10) {
  const out = [];
  for (let i = 0; i < n; i++) {
    let s = '';
    for (let j = 0; j < 12; j++) s += RC[crypto.randomBytes(1)[0] % RC.length];
    out.push(`${s.slice(0, 4)}-${s.slice(4, 8)}-${s.slice(8)}`);
  }
  return out;
}

function normaliseRecovery(code) {
  return String(code || '').toUpperCase().replace(/[^A-Z0-9]/g, '');
}

module.exports = {
  base32Encode, base32Decode, codeForStep, stepNow, verify, newSecret,
  otpauthUri, seal, open, keyConfigured, newRecoveryCodes, normaliseRecovery,
  DIGITS, STEP, SKEW,
};
