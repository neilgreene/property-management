// Webhook signature verification.
//
// GHL does not sign webhooks with an HMAC shared secret. It signs with an RSA
// private key and publishes the public key, so verification is asymmetric.
//
// Two rules that are easy to get wrong and fatal if you do:
//   1. Verify the RAW request body bytes. Parsing and re-serialising the JSON
//      changes key order and whitespace, and the signature will never match.
//   2. Reject stale and replayed deliveries. The payload carries `timestamp`
//      and `webhookId` precisely so you can.
//
// The exact algorithm and padding are not stated in GHL's published docs.
// PKCS#1 v1.5 with SHA-256 is the conventional pairing for this key format and
// is what we try first; confirm against a captured live delivery before
// trusting this in production. See docs/GHL-Interface-Specification.pdf s8.2.
'use strict';

const crypto = require('crypto');

const ALGORITHM = 'sha256';

function verifySignature(rawBody, signatureB64, publicKeyPem) {
  if (!Buffer.isBuffer(rawBody)) {
    throw new TypeError('rawBody must be a Buffer of the unparsed request body');
  }
  if (!signatureB64 || !publicKeyPem) return false;
  let signature;
  try {
    signature = Buffer.from(signatureB64, 'base64');
  } catch {
    return false;
  }
  if (signature.length === 0) return false;
  try {
    return crypto.verify(ALGORITHM, rawBody, publicKeyPem, signature);
  } catch {
    return false;
  }
}

// Returns { ok, reason }. Kept separate from signature checking so a caller can
// record a signature failure distinctly from a replay in ghl.webhook_event.
function checkFreshness(payload, windowSeconds, now = Date.now()) {
  if (!payload || !payload.timestamp) {
    return { ok: false, reason: 'missing timestamp' };
  }
  const t = Date.parse(payload.timestamp);
  if (Number.isNaN(t)) return { ok: false, reason: 'unparseable timestamp' };
  const ageSeconds = Math.abs(now - t) / 1000;
  if (ageSeconds > windowSeconds) {
    return { ok: false, reason: `outside replay window (${Math.round(ageSeconds)}s)` };
  }
  return { ok: true };
}

module.exports = { verifySignature, checkFreshness, ALGORITHM };
