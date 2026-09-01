// Authentication for the web tier.
//
// Deliberately a thin seam. Everything below reduces a request to one
// question -- which person is this, and what role do they hold -- and hands
// that to the database exactly as the persona switcher used to. No policy,
// view or grant changes. If an external identity provider replaces password
// login later, only `authenticate` is rewritten; `sessionFromRequest` and
// everything downstream stay as they are.
//
// No new dependencies: scrypt and randomBytes are in Node's standard library.
// scrypt is memory-hard, which is the property that matters against an
// attacker with a GPU and a stolen hash table.
'use strict';

const crypto = require('crypto');

// Deliberately above Node's defaults. N=2^15 costs ~50ms per hash here,
// which is unnoticeable on a login and expensive across a leaked table.
//
// maxmem must be set explicitly: scrypt needs 128*N*r bytes, which at these
// parameters is exactly 32 MiB -- precisely Node's default ceiling, so it
// fails at the boundary with "memory limit exceeded". Giving it headroom is
// the fix; raising it does not weaken anything.
const SCRYPT = { N: 32768, r: 8, p: 1, keylen: 32, maxmem: 64 * 1024 * 1024 };
const SESSION_TTL_HOURS = 12;
const COOKIE = 'sdi_session';

function hashPassword(password) {
  return new Promise((resolve, reject) => {
    const salt = crypto.randomBytes(16);
    crypto.scrypt(password, salt, SCRYPT.keylen, SCRYPT, (err, key) => {
      if (err) return reject(err);
      resolve(`scrypt$${SCRYPT.N}$${SCRYPT.r}$${SCRYPT.p}$` +
              `${salt.toString('base64')}$${key.toString('base64')}`);
    });
  });
}

function verifyPassword(password, stored) {
  return new Promise((resolve) => {
    if (typeof stored !== 'string') return resolve(false);
    const parts = stored.split('$');
    if (parts.length !== 6 || parts[0] !== 'scrypt') return resolve(false);
    const [, N, r, p, saltB64, keyB64] = parts;
    let salt, expected;
    try {
      salt = Buffer.from(saltB64, 'base64');
      expected = Buffer.from(keyB64, 'base64');
    } catch { return resolve(false); }

    crypto.scrypt(password, salt, expected.length,
      { N: Number(N), r: Number(r), p: Number(p), maxmem: 256 * 1024 * 1024 },
      (err, key) => {
        if (err) return resolve(false);
        // Constant time: a length-varying or short-circuiting compare leaks
        // how much of the hash matched.
        if (key.length !== expected.length) return resolve(false);
        resolve(crypto.timingSafeEqual(key, expected));
      });
  });
}

// The token goes to the browser; only its SHA-256 is ever stored, so a dump
// of core.session cannot be replayed as a set of live sessions.
function newToken() {
  const token = crypto.randomBytes(32).toString('base64url');
  return { token, hash: sha256(token) };
}

function sha256(token) {
  return crypto.createHash('sha256').update(token, 'utf8').digest();
}

async function authenticate(db, email, password, { userAgent, ip } = {}) {
  const { rows } = await db.query(
    'SELECT * FROM api.begin_authentication($1)', [email]);

  // No such account, or no credential set. Verify against a dummy hash
  // anyway: returning early here makes "does this email exist" measurable
  // from the response time alone.
  if (rows.length === 0) {
    await verifyPassword(password, DUMMY_HASH);
    return { ok: false, reason: 'invalid credentials' };
  }

  const { person_id, password_hash, locked } = rows[0];
  if (locked) {
    await verifyPassword(password, DUMMY_HASH);
    return { ok: false, reason: 'account temporarily locked' };
  }

  const good = await verifyPassword(password, password_hash);
  if (!good) {
    await db.query('SELECT * FROM api.complete_authentication($1, false)', [person_id]);
    return { ok: false, reason: 'invalid credentials' };
  }

  const { token, hash } = newToken();
  const { rows: out } = await db.query(
    `SELECT * FROM api.complete_authentication($1, true, $2, $3::interval, $4, $5)`,
    [person_id, hash, `${SESSION_TTL_HOURS} hours`, userAgent || null, ip || null]);

  if (out.length === 0) return { ok: false, reason: 'invalid credentials' };
  return { ok: true, token, ...out[0] };
}

// A precomputed hash of a value nobody will ever submit, so the failure path
// costs the same as the success path.
const DUMMY_HASH =
  'scrypt$32768$8$1$AAAAAAAAAAAAAAAAAAAAAA==$' +
  'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';

async function resolveSession(db, token) {
  if (!token) return null;
  const { rows } = await db.query(
    'SELECT * FROM api.resolve_session($1)', [sha256(token)]);
  return rows[0] || null;
}

async function logout(db, token) {
  if (!token) return false;
  const { rows } = await db.query('SELECT api.revoke_session($1) AS revoked',
                                  [sha256(token)]);
  return rows[0].revoked;
}

// --- cookie plumbing ------------------------------------------------------
function parseCookies(header) {
  const out = {};
  for (const part of (header || '').split(';')) {
    const i = part.indexOf('=');
    if (i < 0) continue;
    out[part.slice(0, i).trim()] = decodeURIComponent(part.slice(i + 1).trim());
  }
  return out;
}

function sessionCookie(token, { secure = true } = {}) {
  // HttpOnly so script cannot read it; SameSite=Lax so it does not ride
  // along on a cross-site form post; Secure unless explicitly running over
  // plain HTTP in development.
  const bits = [
    `${COOKIE}=${encodeURIComponent(token)}`,
    'HttpOnly', 'Path=/', 'SameSite=Lax',
    `Max-Age=${SESSION_TTL_HOURS * 3600}`,
  ];
  if (secure) bits.push('Secure');
  return bits.join('; ');
}

function clearCookie({ secure = true } = {}) {
  const bits = [`${COOKIE}=`, 'HttpOnly', 'Path=/', 'SameSite=Lax', 'Max-Age=0'];
  if (secure) bits.push('Secure');
  return bits.join('; ');
}

function tokenFromRequest(req) {
  return parseCookies(req.headers && req.headers.cookie)[COOKIE] || null;
}

// Maps a person's role to the database role the web tier assumes for them.
// The one place the two vocabularies meet.
const ROLE_TO_DB = {
  investor: 'sdi_investor',
  agent:    'sdi_agent',
  admin:    'sdi_admin',
  staff:    'sdi_admin',
};

function dbRoleFor(personRole) {
  return ROLE_TO_DB[personRole] || null;
}

module.exports = {
  hashPassword, verifyPassword, authenticate, resolveSession, logout,
  sessionCookie, clearCookie, tokenFromRequest, parseCookies, dbRoleFor,
  sha256, newToken, COOKIE, SESSION_TTL_HOURS, ROLE_TO_DB,
};
