// Webhook intake.
//
// Deliberately a plain function over (rawBody, headers) rather than an HTTP
// route. This environment cannot receive live deliveries -- that needs an
// inbound public URL -- so the receiver is driven from fixtures in tests today
// and mounted on a route later without changing a line. It also keeps the
// verify-then-record ordering testable in isolation.
//
// Acknowledge fast and process asynchronously: a slow handler causes GHL to
// redeliver, which is exactly the duplicate work ghl.webhook_event prevents.
'use strict';

const { verifySignature, checkFreshness } = require('./signature');
const { recordWebhook } = require('./db');

const SIGNATURE_HEADER = 'x-wh-signature';

function headerValue(headers, name) {
  if (!headers) return null;
  if (typeof headers.get === 'function') return headers.get(name);
  const lower = name.toLowerCase();
  for (const [k, v] of Object.entries(headers)) {
    if (k.toLowerCase() === lower) return v;
  }
  return null;
}

async function receive(rawBody, headers, { db, cfg, now = Date.now() }) {
  if (!Buffer.isBuffer(rawBody)) {
    return { status: 400, reason: 'raw body required' };
  }

  const signature = headerValue(headers, SIGNATURE_HEADER);
  const signatureOk = verifySignature(rawBody, signature, cfg.webhookKey);

  let payload;
  try {
    payload = JSON.parse(rawBody.toString('utf8'));
  } catch {
    return { status: 400, reason: 'unparseable body', signatureOk };
  }

  // An unverified payload is never processed. It is still recorded when it
  // carries an id, so a sustained forgery attempt is visible rather than silent.
  if (!signatureOk) {
    if (payload.webhookId) {
      await recordWebhook(db, {
        webhookId: payload.webhookId,
        eventType: payload.type || 'unknown',
        occurredAt: payload.timestamp || new Date(now).toISOString(),
        signatureOk: false,
        payload,
      });
    }
    return { status: 401, reason: 'signature verification failed', signatureOk };
  }

  const fresh = checkFreshness(payload, cfg.replaySeconds, now);
  if (!fresh.ok) {
    return { status: 400, reason: fresh.reason, signatureOk };
  }

  if (!payload.webhookId) {
    return { status: 400, reason: 'missing webhookId', signatureOk };
  }

  const { duplicate } = await recordWebhook(db, {
    webhookId: payload.webhookId,
    eventType: payload.type || 'unknown',
    occurredAt: payload.timestamp,
    signatureOk: true,
    payload,
  });

  // A duplicate is a success from GHL's point of view: it must stop retrying.
  return { status: 200, duplicate, signatureOk: true, webhookId: payload.webhookId };
}

module.exports = { receive, SIGNATURE_HEADER };
