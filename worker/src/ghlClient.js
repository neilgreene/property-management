// HTTP client for the GoHighLevel v2 API.
//
// The Version header is not advisory: it is a required header parameter with a
// single-value enum in the OpenAPI spec, so it is set here once rather than at
// each call site. Same for the bearer token.
//
// Rate limits are 100 requests / 10 seconds and 200,000/day, scoped per app per
// location -- not per user. The bucket below keeps this worker well under the
// burst ceiling so it does not starve the rest of the system.
'use strict';

class RateLimiter {
  constructor(perSecond) {
    this.intervalMs = 1000 / Math.max(perSecond, 1);
    this.next = 0;
  }
  async take() {
    const now = Date.now();
    const at = Math.max(now, this.next);
    this.next = at + this.intervalMs;
    if (at > now) await new Promise((r) => setTimeout(r, at - now));
  }
}

class GhlError extends Error {
  constructor(message, { status, body, retryable }) {
    super(message);
    this.name = 'GhlError';
    this.status = status;
    this.body = body;
    this.retryable = retryable;
  }
}

const RETRYABLE = new Set([408, 429, 500, 502, 503, 504]);

class GhlClient {
  constructor(cfg, { fetchImpl = globalThis.fetch, sleep } = {}) {
    this.cfg = cfg;
    this.fetch = fetchImpl;
    this.limiter = new RateLimiter(cfg.ratePerSecond);
    this.sleep = sleep || ((ms) => new Promise((r) => setTimeout(r, ms)));
    this.rateSnapshot = {};
  }

  headers(extra = {}) {
    return {
      Authorization: `Bearer ${this.cfg.token}`,
      Version: this.cfg.apiVersion,
      Accept: 'application/json',
      ...extra,
    };
  }

  async request(method, path, { query, body, correlationId } = {}) {
    const url = new URL(path, this.cfg.baseUrl);
    for (const [k, v] of Object.entries(query || {})) {
      if (v !== undefined && v !== null) url.searchParams.set(k, String(v));
    }

    let attempt = 0;
    for (;;) {
      await this.limiter.take();
      let res;
      try {
        res = await this.fetch(url.toString(), {
          method,
          headers: this.headers(body ? { 'Content-Type': 'application/json' } : {}),
          body: body ? JSON.stringify(body) : undefined,
        });
      } catch (cause) {
        // Network-level failure: retryable.
        if (attempt++ >= this.cfg.maxRetries) {
          throw new GhlError(`network failure calling ${method} ${path}`, {
            status: 0, body: String(cause), retryable: true,
          });
        }
        await this.sleep(backoffMs(attempt));
        continue;
      }

      this.captureRateHeaders(res);

      if (res.ok) {
        const text = await res.text();
        return text ? JSON.parse(text) : null;
      }

      const text = await res.text().catch(() => '');
      const retryable = RETRYABLE.has(res.status);

      if (retryable && attempt++ < this.cfg.maxRetries) {
        await this.sleep(backoffMs(attempt, res.headers.get('retry-after')));
        continue;
      }

      throw new GhlError(
        `${method} ${path} failed: ${res.status}` +
        (correlationId ? ` [correlation ${correlationId}]` : ''),
        { status: res.status, body: text, retryable }
      );
    }
  }

  captureRateHeaders(res) {
    const g = (n) => res.headers && res.headers.get ? res.headers.get(n) : null;
    const daily = g('X-RateLimit-Daily-Remaining');
    if (daily !== null) {
      this.rateSnapshot = {
        dailyRemaining: Number(daily),
        dailyLimit: Number(g('X-RateLimit-Limit-Daily')),
        max: Number(g('X-RateLimit-Max')),
        intervalMs: Number(g('X-RateLimit-Interval-Milliseconds')),
        at: new Date().toISOString(),
      };
    }
  }

  // ---- endpoints actually used by this worker -------------------------

  listTransactions({ startAt, endAt, limit = 100, offset = 0 } = {}) {
    return this.request('GET', '/payments/transactions', {
      query: {
        altId: this.cfg.locationId, altType: 'location',
        startAt, endAt, limit, offset,
      },
    });
  }

  getTransaction(id) {
    return this.request('GET', `/payments/transactions/${encodeURIComponent(id)}`, {
      query: { altId: this.cfg.locationId, altType: 'location' },
    });
  }

  // GHL publishes no document-signed webhook, so the fee agreement state is
  // polled. status: draft|sent|viewed|completed|accepted
  listDocuments({ status, limit = 100, skip = 0 } = {}) {
    return this.request('GET', '/proposals/document', {
      query: { locationId: this.cfg.locationId, status, limit, skip },
    });
  }

  upsertContact(contact) {
    return this.request('POST', '/contacts/upsert', {
      body: { locationId: this.cfg.locationId, ...contact },
    });
  }

  // Associations are what preserve EspoCRM's relational integrity. They are a
  // separate call from record creation by necessity: both endpoints must
  // already exist and carry GHL ids.
  createRelation({ firstRecordId, secondRecordId, associationId }) {
    return this.request('POST', '/associations/relations', {
      body: { locationId: this.cfg.locationId, firstRecordId, secondRecordId, associationId },
    });
  }

  createRecord(schemaKey, record) {
    return this.request('POST', `/objects/${encodeURIComponent(schemaKey)}/records`, {
      body: { locationId: this.cfg.locationId, ...record },
    });
  }
}

function backoffMs(attempt, retryAfterHeader) {
  if (retryAfterHeader) {
    const secs = Number(retryAfterHeader);
    if (!Number.isNaN(secs) && secs > 0) return Math.min(secs * 1000, 60000);
  }
  const base = Math.min(2 ** attempt * 250, 30000);
  return base + Math.floor(Math.random() * 250); // jitter
}

module.exports = { GhlClient, GhlError, RateLimiter, backoffMs };
