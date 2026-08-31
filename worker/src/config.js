// Configuration. Every GHL secret comes from the environment; nothing is
// committed and nothing is ever sent to a browser (see README: a GHL bearer
// token is scoped to the whole sub-account).
'use strict';

const REQUIRED_IN_LIVE = ['GHL_TOKEN', 'GHL_LOCATION_ID'];

function load(env = process.env) {
  const cfg = {
    baseUrl:      env.GHL_BASE_URL || 'https://services.leadconnectorhq.com',
    apiVersion:   env.GHL_API_VERSION || '2021-07-28',
    token:        env.GHL_TOKEN || null,          // Private Integration Token
    locationId:   env.GHL_LOCATION_ID || null,
    webhookKey:   env.GHL_WEBHOOK_PUBLIC_KEY || null,
    replaySeconds: Number(env.GHL_REPLAY_WINDOW_SECONDS || 300),
    // Burst limit is 100 requests / 10s per app per location, shared across
    // every caller. Sit well under it: this worker is not the only client.
    ratePerSecond: Number(env.GHL_RATE_PER_SECOND || 8),
    maxRetries:    Number(env.GHL_MAX_RETRIES || 5),
    dryRun:        env.GHL_DRY_RUN === '1',
  };
  return cfg;
}

function assertLive(cfg) {
  const missing = REQUIRED_IN_LIVE.filter((k) => !cfg[k === 'GHL_TOKEN' ? 'token' : 'locationId']);
  if (missing.length) {
    throw new Error(`missing required environment: ${missing.join(', ')}`);
  }
}

module.exports = { load, assertLive };
