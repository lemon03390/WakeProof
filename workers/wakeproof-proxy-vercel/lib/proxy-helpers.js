// Shared helpers for the WakeProof Vercel proxy routes.
//
// S-C1 / S-I5 / E-L4 / E-L5 (Wave 2.1, 2026-04-26): centralised here so
// `messages.js` and `wildcard.js` apply the same hardening posture. Add new
// guards here, not in the route files.

import { timingSafeEqual, createHash } from 'node:crypto';

// Round-1 PR-review I-6 (Wave 3.2, 2026-04-26): tokenIdent replaces the
// last-6-chars suffix used previously for burst-cache keying + log
// correlation. Two motivations:
//   1. Collision: with token rotation, two tokens sharing the last 6 hex
//      chars (1-in-16M) would share a burst counter.
//   2. Log leak: the 6-char suffix in Vercel logs reveals 6 hex chars of the
//      token; an attacker with log read access correlates suffixes across
//      rotations or guesses adjacent tokens. The SHA-256 prefix doesn't
//      reveal anything about the original token's bytes.
// SHA-256 hex prefix is collision-resistant for the per-warm-Lambda cache
// (10–100 active suffixes max). Length 12 chars = 48 bits = 1-in-280-trillion
// collision probability per cache cycle — practically zero.
export function tokenIdent(token) {
  return createHash('sha256').update(token).digest('hex').slice(0, 12);
}

// L1 (Wave 2.7): constant-time token compare. Mirrored from the original
// route-file implementations now that both share this module.
export function tokensEqual(clientToken, expectedToken) {
  if (typeof clientToken !== 'string' || typeof expectedToken !== 'string') return false;
  if (clientToken.length !== expectedToken.length) return false;
  const clientBuf = Buffer.from(clientToken, 'utf8');
  const expectedBuf = Buffer.from(expectedToken, 'utf8');
  if (clientBuf.length !== expectedBuf.length) return false;
  return timingSafeEqual(clientBuf, expectedBuf);
}

// S-C1 (Wave 2.1): operator kill-switch.
export function isKillSwitchActive() {
  return process.env.WAKEPROOF_KILL_SWITCH === '1';
}

// S-C1 (Wave 2.1): per-token burst rate limit (best-effort, warm-Lambda only).
// AWS Lambda containers stay warm 5–15 minutes between invocations, so this
// limits a single token-extracted attacker hammering one warm container. It
// does NOT cap globally — different containers have independent counters.
// Production-grade: replace this Map with Upstash Redis or Vercel KV.
export const BURST_WINDOW_MS = 60 * 1000; // 1 minute
export const BURST_LIMIT_DEFAULT = 30;     // 30 req/min/token/warm-container

function getBurstCache() {
  if (!globalThis.__wakeproofBurstCache) {
    globalThis.__wakeproofBurstCache = new Map();
  }
  return globalThis.__wakeproofBurstCache;
}

export function checkBurstLimit(tokenSuffix, limit) {
  const cache = getBurstCache();
  const now = Date.now();
  const cutoff = now - BURST_WINDOW_MS;
  // Wave 2.6: opportunistic prune of stale OTHER buckets so a long-warm
  // Lambda doesn't accumulate orphaned token-suffix keys (idle tokens after
  // their burst window expired). With ~1-10 active suffixes per warm
  // container, the per-call sweep is trivial; without it the Map grows
  // monotonically until container recycle. We compute `cutoff` once and use
  // it both for our own bucket filter and for sibling-bucket eviction.
  for (const [key, entries] of cache) {
    if (key === tokenSuffix) continue;
    // entries is sorted by push order (monotonic now()); the last entry is
    // the most recent. If even the newest entry is past the cutoff, no
    // entries in this bucket can still count toward a future check.
    if (entries.length === 0 || entries[entries.length - 1] <= cutoff) {
      cache.delete(key);
    }
  }
  const recent = (cache.get(tokenSuffix) || []).filter((ts) => ts > cutoff);
  if (recent.length >= limit) {
    cache.set(tokenSuffix, recent);
    return { allowed: false, count: recent.length };
  }
  recent.push(now);
  cache.set(tokenSuffix, recent);
  return { allowed: true, count: recent.length };
}

// S-I5 (Wave 2.1): sanitise upstream 4xx response bodies. Anthropic 4xx
// responses sometimes echo the offending request fragment (including base64
// image data); forwarding verbatim could leak prompt content into the iOS
// client's logs. We strip down to {type, message} for 4xx and bound message
// length. 2xx and 5xx pass through unchanged.
//
// SF-6 (Wave 3.1, 2026-04-26): JSON.parse failure path now returns a synthetic
// safe-by-construction error body instead of passing through the original
// bytes. The fall-through was the exact silent-leak vector the function
// exists to prevent — if Anthropic ever returns a malformed/truncated 4xx
// with an echoed prompt fragment, the parse-fail catch would have re-emitted
// it verbatim. Now we fail safe with a generic "Upstream error
// (unparseable)" body. Non-JSON 4xx is still passed through (the function
// only owns the JSON sanitisation contract).
export function sanitizeUpstreamBody(status, originalBytes, contentType) {
  if (status < 400 || status >= 500) return originalBytes;
  if (!contentType || !contentType.includes('json')) return originalBytes;
  try {
    const parsed = JSON.parse(originalBytes.toString('utf8'));
    const errorObj = parsed?.error;
    if (!errorObj || typeof errorObj !== 'object') {
      // Shape mismatch — synthesize a generic 4xx body rather than leaking
      // whatever was in the original.
      return Buffer.from(
        JSON.stringify({ error: { type: 'invalid_request_error', message: 'Upstream error (unexpected shape)' } }),
        'utf8'
      );
    }
    const sanitized = {
      type: typeof errorObj.type === 'string' ? errorObj.type : 'invalid_request_error',
      message: typeof errorObj.message === 'string'
        ? errorObj.message.slice(0, 500)
        : 'Upstream error (details suppressed)',
    };
    return Buffer.from(JSON.stringify({ error: sanitized }), 'utf8');
  } catch {
    // Parse failure on a JSON-claimed content type. Don't pass-through —
    // emit a synthetic safe body. Logged at the proxy route via the upstream
    // status code, so triage still has the original status.
    return Buffer.from(
      JSON.stringify({ error: { type: 'invalid_request_error', message: 'Upstream error (unparseable)' } }),
      'utf8'
    );
  }
}

// E-L4 (Wave 2.5): bound the upstream-body read.
export async function readWithTimeout(upstream, timeoutMs) {
  return Promise.race([
    upstream.arrayBuffer().then((b) => Buffer.from(b)),
    new Promise((_, reject) =>
      setTimeout(() => reject(new Error('upstream_response_too_slow')), timeoutMs)
    ),
  ]);
}

// E-L5 (Wave 2.5): classify upstream fetch failure for log triage.
export function classifyFetchError(err) {
  return err?.cause?.code || err?.code || 'unknown';
}
