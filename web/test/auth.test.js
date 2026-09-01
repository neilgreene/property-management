'use strict';
// Authentication. The interesting cases are the failures: a wrong password,
// an expired session, a revoked one, and a session belonging to someone whose
// account has since been deactivated.
const test = require('node:test');
const assert = require('node:assert');
const crypto = require('node:crypto');
const { Pool } = require('pg');
const auth = require('../auth');

const RUTH = '11111111-1111-1111-1111-111111111111';
const JESS = '77777777-7777-7777-7777-777777777777';

let pool, available = true;
async function db() {
  if (pool) return pool;
  pool = new Pool({
    host: process.env.PGHOST || '127.0.0.1',
    database: process.env.PGDATABASE || 'sdi',
    user: 'sdi_test_admin', password: 'demo_test_pw', max: 4,
  });
  await pool.query('SELECT 1');
  return pool;
}

test('database reachable', async (t) => {
  try { await db(); } catch (e) { available = false; t.skip(`no database: ${e.message}`); }
});

// ---- hashing, no database needed ----------------------------------------
test('a password verifies against its own hash', async () => {
  const h = await auth.hashPassword('correct horse battery staple');
  assert.equal(await auth.verifyPassword('correct horse battery staple', h), true);
});

test('a wrong password does not', async () => {
  const h = await auth.hashPassword('correct horse battery staple');
  assert.equal(await auth.verifyPassword('Correct horse battery staple', h), false);
});

test('the same password hashes differently every time', async () => {
  const a = await auth.hashPassword('same');
  const b = await auth.hashPassword('same');
  assert.notEqual(a, b, 'a per-password salt is what stops a rainbow table');
  assert.equal(await auth.verifyPassword('same', a), true);
  assert.equal(await auth.verifyPassword('same', b), true);
});

test('a malformed or empty stored hash is rejected, never accepted', async () => {
  for (const bad of ['', 'garbage', 'scrypt$only$three', null, undefined, 42]) {
    assert.equal(await auth.verifyPassword('anything', bad), false, `accepted ${bad}`);
  }
});

test('the stored hash contains neither the password nor a bare digest', async () => {
  const h = await auth.hashPassword('hunter2');
  assert.ok(!h.includes('hunter2'));
  assert.ok(h.startsWith('scrypt$32768$8$1$'), 'parameters are recorded for future rehashing');
});

test('a session token is never stored, only its digest', () => {
  const { token, hash } = auth.newToken();
  assert.equal(hash.length, 32);
  assert.deepEqual(hash, crypto.createHash('sha256').update(token, 'utf8').digest());
  assert.ok(!hash.toString('base64').includes(token));
});

// ---- against the database ------------------------------------------------
async function setPassword(d, personId, password) {
  const h = await auth.hashPassword(password);
  await d.query('SELECT api.set_password($1, $2)', [personId, h]);
}

test('setup: give Ruth and Jessica passwords', async (t) => {
  if (!available) return t.skip('no database');
  const d = await db();
  await d.query('DELETE FROM core.session');
  await setPassword(d, RUTH, 'ruth-correct-password');
  await setPassword(d, JESS, 'jessica-correct-password');
});

test('correct credentials return the person and their role', async (t) => {
  if (!available) return t.skip('no database');
  const d = await db();
  const r = await auth.authenticate(d, 'ruth@example.com', 'ruth-correct-password');
  assert.equal(r.ok, true);
  assert.equal(r.person_id, RUTH);
  assert.equal(r.role, 'investor');
  assert.ok(r.token && r.token.length > 30);
  assert.equal(auth.dbRoleFor(r.role), 'sdi_investor');
});

test('email match is case-insensitive', async (t) => {
  if (!available) return t.skip('no database');
  const d = await db();
  const r = await auth.authenticate(d, 'RUTH@Example.COM', 'ruth-correct-password');
  assert.equal(r.ok, true);
});

test('a wrong password is refused', async (t) => {
  if (!available) return t.skip('no database');
  const d = await db();
  const r = await auth.authenticate(d, 'ruth@example.com', 'wrong');
  assert.equal(r.ok, false);
  assert.equal(r.token, undefined, 'no token is issued on failure');
});

test('an unknown email is refused, and says the same thing', async (t) => {
  if (!available) return t.skip('no database');
  const d = await db();
  const a = await auth.authenticate(d, 'nobody@example.com', 'x');
  const b = await auth.authenticate(d, 'ruth@example.com', 'wrong');
  assert.equal(a.ok, false);
  assert.equal(a.reason, b.reason,
    'a distinct message for an unknown address is an account enumeration oracle');
});

test('a valid token resolves to the person', async (t) => {
  if (!available) return t.skip('no database');
  const d = await db();
  const { token } = await auth.authenticate(d, 'ruth@example.com', 'ruth-correct-password');
  const s = await auth.resolveSession(d, token);
  assert.equal(s.person_id, RUTH);
  assert.equal(s.role, 'investor');
});

test('a made-up token resolves to nothing', async (t) => {
  if (!available) return t.skip('no database');
  const d = await db();
  assert.equal(await auth.resolveSession(d, 'not-a-real-token'), null);
  assert.equal(await auth.resolveSession(d, ''), null);
  assert.equal(await auth.resolveSession(d, null), null);
});

test('logging out kills the token immediately', async (t) => {
  if (!available) return t.skip('no database');
  const d = await db();
  const { token } = await auth.authenticate(d, 'ruth@example.com', 'ruth-correct-password');
  assert.ok(await auth.resolveSession(d, token));
  assert.equal(await auth.logout(d, token), true);
  assert.equal(await auth.resolveSession(d, token), null);
});

test('an expired session does not resolve', async (t) => {
  if (!available) return t.skip('no database');
  const d = await db();
  const { token } = await auth.authenticate(d, 'ruth@example.com', 'ruth-correct-password');
  await d.query("UPDATE core.session SET expires_at = now() - interval '1 second' WHERE token_hash = $1",
                [auth.sha256(token)]);
  assert.equal(await auth.resolveSession(d, token), null);
});

test('deactivating a person kills their live sessions', async (t) => {
  if (!available) return t.skip('no database');
  const d = await db();
  const { token } = await auth.authenticate(d, 'ruth@example.com', 'ruth-correct-password');
  assert.ok(await auth.resolveSession(d, token), 'live before');
  await d.query('UPDATE core.person SET active = false WHERE person_id = $1', [RUTH]);
  try {
    assert.equal(await auth.resolveSession(d, token), null,
      'a session must not outlive the account it belongs to');
  } finally {
    await d.query('UPDATE core.person SET active = true WHERE person_id = $1', [RUTH]);
  }
});

test('a deactivated person cannot sign in at all', async (t) => {
  if (!available) return t.skip('no database');
  const d = await db();
  await d.query('UPDATE core.person SET active = false WHERE person_id = $1', [RUTH]);
  try {
    const r = await auth.authenticate(d, 'ruth@example.com', 'ruth-correct-password');
    assert.equal(r.ok, false);
  } finally {
    await d.query('UPDATE core.person SET active = true WHERE person_id = $1', [RUTH]);
  }
});

test('changing a password ends every existing session', async (t) => {
  if (!available) return t.skip('no database');
  const d = await db();
  const a = await auth.authenticate(d, 'jessica@x', 'x'); // wrong email on purpose
  const s1 = await auth.authenticate(d, 'jpool@yahoo.com', 'jessica-correct-password');
  const s2 = await auth.authenticate(d, 'jpool@yahoo.com', 'jessica-correct-password');
  assert.ok(await auth.resolveSession(d, s1.token));
  assert.ok(await auth.resolveSession(d, s2.token));
  await setPassword(d, JESS, 'jessica-new-password');
  assert.equal(await auth.resolveSession(d, s1.token), null,
    'changing a password after a compromise must not leave the attacker signed in');
  assert.equal(await auth.resolveSession(d, s2.token), null);
});

test('five wrong passwords lock the account, and the right one then fails too', async (t) => {
  if (!available) return t.skip('no database');
  const d = await db();
  await setPassword(d, RUTH, 'ruth-correct-password');   // resets the counter
  for (let i = 0; i < 5; i++) await auth.authenticate(d, 'ruth@example.com', 'wrong');
  const r = await auth.authenticate(d, 'ruth@example.com', 'ruth-correct-password');
  assert.equal(r.ok, false);
  assert.match(r.reason, /locked/);
  await setPassword(d, RUTH, 'ruth-correct-password');   // clears the lock
  assert.equal((await auth.authenticate(d, 'ruth@example.com', 'ruth-correct-password')).ok, true);
});

test('no application role can read a password hash directly', async (t) => {
  if (!available) return t.skip('no database');
  const web = new Pool({
    host: process.env.PGHOST || '127.0.0.1',
    database: process.env.PGDATABASE || 'sdi',
    user: 'sdi_app', password: 'demo_app_pw', max: 1,
  });
  try {
    await assert.rejects(
      () => web.query('SELECT password_hash FROM core.credential'),
      /permission denied|does not exist/,
      'a hash must not be readable by the role the web tier connects as');
    await assert.rejects(
      () => web.query('SELECT token_hash FROM core.session'),
      /permission denied|does not exist/);
  } finally { await web.end(); }
});

test('cookies are HttpOnly, SameSite and Secure', () => {
  const c = auth.sessionCookie('tok');
  assert.match(c, /HttpOnly/);
  assert.match(c, /SameSite=Lax/);
  assert.match(c, /Secure/);
  assert.match(auth.clearCookie(), /Max-Age=0/);
  assert.equal(auth.tokenFromRequest({ headers: { cookie: 'sdi_session=abc; other=1' } }), 'abc');
  assert.equal(auth.tokenFromRequest({ headers: {} }), null);
});

// Put the demo credentials back. These tests necessarily change passwords,
// and leaving them changed means every demo login stops working the moment
// anyone runs the suite -- which is exactly what happened once.
test('teardown: restore the demo password for every seeded person', async (t) => {
  if (!available) return t.skip('no database');
  const d = await db();
  const { rows } = await d.query('SELECT person_id FROM core.person');
  for (const r of rows) {
    await d.query('SELECT api.set_password($1, $2)',
                  [r.person_id, await auth.hashPassword('demo1234')]);
  }
  await d.query('DELETE FROM core.session');
});

test.after(async () => { if (pool) await pool.end(); });
