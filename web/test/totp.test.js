// The one-time-password engine, on its own. No database and no server: this
// is arithmetic, and arithmetic is worth testing where nothing else can be
// blamed for a failure.
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');
const totp = require('../totp');

// RFC 6238, Appendix B. The published vectors are 8-digit; a 6-digit
// implementation is the same number truncated, which is what the standard
// says and what every authenticator does.
const RFC_SECRET = Buffer.from('12345678901234567890');
const VECTORS = [
  [59, '287082'],
  [1111111109, '081804'],
  [1111111111, '050471'],
  [1234567890, '005924'],
  [2000000000, '279037'],
];

test('matches the RFC 6238 test vectors', () => {
  for (const [t, expected] of VECTORS) {
    assert.equal(totp.codeForStep(RFC_SECRET, Math.floor(t / 30)), expected,
      `RFC 6238 vector at T=${t}`);
  }
});

test('base32 round-trips, and is what an authenticator reads', () => {
  assert.equal(totp.base32Encode(RFC_SECRET), 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ');
  for (let i = 0; i < 40; i++) {
    const b = crypto.randomBytes(1 + (i % 24));
    assert.ok(totp.base32Decode(totp.base32Encode(b)).equals(b), `round trip at ${b.length} bytes`);
  }
  assert.throws(() => totp.base32Decode('not base32!'));
});

test('a code verifies, and the step it matched comes back', () => {
  const at = Date.now();
  const step = totp.stepNow(at);
  assert.equal(totp.verify(RFC_SECRET, totp.codeForStep(RFC_SECRET, step), { at }), step);
  assert.equal(totp.verify(RFC_SECRET, '000000', { at, after: null }), null,
    'a wrong code does not verify');
  assert.equal(totp.verify(RFC_SECRET, '12345', { at }), null, 'five digits is not a code');
  assert.equal(totp.verify(RFC_SECRET, 'abcdef', { at }), null, 'letters are not a code');
  assert.equal(totp.verify(RFC_SECRET, '', { at }), null);
  assert.equal(totp.verify(RFC_SECRET, null, { at }), null);
});

test('A USED CODE CANNOT BE USED AGAIN', () => {
  const at = Date.now();
  const step = totp.stepNow(at);
  const code = totp.codeForStep(RFC_SECRET, step);
  assert.equal(totp.verify(RFC_SECRET, code, { at }), step);
  assert.equal(totp.verify(RFC_SECRET, code, { at, after: step }), null,
    'A CODE WAS ACCEPTED TWICE — a code is valid for thirty seconds, so without '
    + 'refusing steps at or below the last accepted one, anyone who reads it over '
    + 'a shoulder or through a phishing proxy can use it too');
  // And the code from the step before the last accepted one is dead as well,
  // which is what stops the skew window being a way back in.
  const previous = totp.codeForStep(RFC_SECRET, step - 1);
  assert.equal(totp.verify(RFC_SECRET, previous, { at, after: step }), null);
});

test('clock drift is tolerated by one step and no more', () => {
  const at = Date.now();
  const code = totp.codeForStep(RFC_SECRET, totp.stepNow(at));
  assert.notEqual(totp.verify(RFC_SECRET, code, { at: at + 30_000 }), null, '+30s accepted');
  assert.notEqual(totp.verify(RFC_SECRET, code, { at: at - 30_000 }), null, '-30s accepted');
  assert.equal(totp.verify(RFC_SECRET, code, { at: at + 90_000 }), null,
    '+90s refused — every extra step of tolerance is another thirty seconds in '
    + 'which an intercepted code still works');
  assert.equal(totp.verify(RFC_SECRET, code, { at: at - 90_000 }), null, '-90s refused');
});

test('secrets are 20 bytes and never repeat', () => {
  const seen = new Set();
  for (let i = 0; i < 50; i++) {
    const s = totp.newSecret();
    assert.equal(s.length, 20, 'RFC 4226 recommends 160 bits');
    seen.add(s.toString('hex'));
  }
  assert.equal(seen.size, 50);
});

test('the otpauth uri carries what an app needs', () => {
  const uri = totp.otpauthUri(RFC_SECRET, 'jpool2@yahoo.com');
  assert.match(uri, /^otpauth:\/\/totp\/SDI%3Ajpool2%40yahoo\.com\?/);
  assert.match(uri, /secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ/);
  assert.match(uri, /issuer=SDI/);
  assert.match(uri, /digits=6/);
  assert.match(uri, /period=30/);
});

// --- encryption at rest ---------------------------------------------------
test('a secret seals and opens, and will not open under another key', () => {
  const was = process.env.SDI_MFA_KEY;
  try {
    process.env.SDI_MFA_KEY = crypto.randomBytes(32).toString('base64');
    const sealed = totp.seal(RFC_SECRET);
    assert.match(sealed, /^v1\$/, 'the format is versioned so a rotation can be detected');
    assert.ok(!sealed.includes(RFC_SECRET.toString('base64')),
      'THE PLAINTEXT SECRET APPEARED IN THE SEALED VALUE');
    assert.ok(totp.open(sealed).equals(RFC_SECRET));

    process.env.SDI_MFA_KEY = crypto.randomBytes(32).toString('base64');
    assert.throws(() => totp.open(sealed),
      'A SECRET OPENED UNDER THE WRONG KEY — GCM must reject it, or encrypting '
      + 'it bought nothing');
  } finally {
    if (was === undefined) delete process.env.SDI_MFA_KEY;
    else process.env.SDI_MFA_KEY = was;
  }
});

test('tampering with a sealed secret is detected, not silently decrypted', () => {
  const was = process.env.SDI_MFA_KEY;
  try {
    process.env.SDI_MFA_KEY = crypto.randomBytes(32).toString('base64');
    const parts = totp.seal(RFC_SECRET).split('$');
    const body = Buffer.from(parts[3], 'base64');
    body[0] ^= 0xff;
    parts[3] = body.toString('base64');
    assert.throws(() => totp.open(parts.join('$')),
      'a flipped bit in the ciphertext must fail the GCM tag');
    assert.throws(() => totp.open('garbage'));
    assert.throws(() => totp.open(''));
  } finally {
    if (was === undefined) delete process.env.SDI_MFA_KEY;
    else process.env.SDI_MFA_KEY = was;
  }
});

test('a missing key fails loudly rather than defaulting to a shared one', () => {
  const was = process.env.SDI_MFA_KEY;
  try {
    delete process.env.SDI_MFA_KEY;
    assert.equal(totp.keyConfigured(), false);
    assert.throws(() => totp.seal(RFC_SECRET), /SDI_MFA_KEY is not set/,
      'A BUILT-IN DEFAULT KEY would mean every deployment shares one, which is '
      + 'the same as no encryption while looking like some');
    process.env.SDI_MFA_KEY = Buffer.alloc(16).toString('base64');
    assert.throws(() => totp.seal(RFC_SECRET), /32 bytes/, 'a short key is refused');
  } finally {
    if (was === undefined) delete process.env.SDI_MFA_KEY;
    else process.env.SDI_MFA_KEY = was;
  }
});

// --- recovery codes -------------------------------------------------------
test('recovery codes are transcribable, unique, and avoid look-alike characters', () => {
  const codes = totp.newRecoveryCodes(10);
  assert.equal(codes.length, 10);
  assert.equal(new Set(codes).size, 10);
  for (const c of codes) {
    assert.match(c, /^[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}$/);
    assert.ok(!/[O01Il]/.test(c),
      `${c} contains a character somebody will mistype off a printout`);
  }
  assert.equal(totp.normaliseRecovery(' ctgd-396g-lcy9 '), 'CTGD396GLCY9',
    'a code typed back with its dashes, spaces or in lower case still matches');
});
