// WakeProof Claude Proxy — Vercel Serverless Function (Node.js on AWS Lambda)
//
// Fallback proxy for the Cloudflare Worker at wakeproof.aspiratcm.com, which
// gets HTTP 403 from Anthropic's Cloudflare HKG edge when the iPhone request
// lands there (Smart Placement pins to local-HKG, and HKG → Anthropic-HKG
// is strict on Worker-originated traffic). This function runs on Vercel's
// default Serverless runtime (Node.js 20 on AWS Lambda, region iad1 by
// default — US East). Egress from AWS Lambda bypasses Cloudflare entirely,
// so the upstream fetch to api.anthropic.com comes from a "normal" US-East
// Anthropic-accepting path.
//
// Timeout: Vercel Hobby Serverless caps at 10s. Opus 4.7 vision usually
// returns in 5–8s for our workload, so this fits with a small margin. If
// we see timeouts post-demo, pivot to Fly.io / Railway for longer budgets.

// Disable Vercel's default JSON body parser so we can pass the raw bytes
// through to Anthropic unchanged (the request body is already valid JSON
// when it leaves the iOS client; re-parsing would cost memory + latency
// and risk subtle shape changes).
import {
  tokensEqual,
  isKillSwitchActive,
  checkBurstLimit,
  sanitizeUpstreamBody,
  readWithTimeout,
  classifyFetchError,
  tokenIdent,
  BURST_WINDOW_MS,
  BURST_LIMIT_DEFAULT,
} from '../../lib/proxy-helpers.js';

export const config = {
  api: {
    bodyParser: false,
  },
};

export default async function handler(req, res) {
  if (req.method !== 'POST') {
    res.status(404).json({ error: { type: 'not_found', message: 'POST only' } });
    return;
  }

  // S-C1 (Wave 2.1, 2026-04-26): operator kill-switch. Set
  // `WAKEPROOF_KILL_SWITCH=1` in Vercel env to instantly reject all traffic
  // without redeploy. Use case: token leak detected → flip switch → rotate
  // token → unset switch.
  if (isKillSwitchActive()) {
    console.warn('[kill-switch] proxy rejecting all traffic — WAKEPROOF_KILL_SWITCH=1');
    res.status(503).json({
      error: { type: 'service_unavailable', message: 'Proxy temporarily disabled by operator' },
    });
    return;
  }

  // B1 + B2 fix: Anthropic key now lives in a Vercel env var (ANTHROPIC_API_KEY)
  // rather than shipped inside the iOS binary. The iOS client authenticates to
  // this proxy with a shared per-install token (x-wakeproof-token) that we
  // validate against WAKEPROOF_CLIENT_TOKEN in env — combined, this means the
  // binary no longer contains the Anthropic credential, and the proxy is no
  // longer an open relay for arbitrary keys. Abuse is bounded to clients who
  // extracted the token from a .ipa; the token is trivially rotatable.
  const expectedToken = process.env.WAKEPROOF_CLIENT_TOKEN;
  const anthropicKey = process.env.ANTHROPIC_API_KEY;
  if (!expectedToken || !anthropicKey) {
    res.status(500).json({
      error: {
        type: 'proxy_not_configured',
        message: 'Vercel env missing WAKEPROOF_CLIENT_TOKEN or ANTHROPIC_API_KEY',
      },
    });
    return;
  }
  const clientToken = req.headers['x-wakeproof-token'];
  if (!clientToken || !tokensEqual(clientToken, expectedToken)) {
    res.status(401).json({
      error: { type: 'unauthorized', message: 'Missing or invalid x-wakeproof-token' },
    });
    return;
  }

  // S-C1 (Wave 2.1) + I-6 (Wave 3.2): per-token burst rate limit, keyed on
  // `tokenIdent(token)` (SHA-256 prefix) instead of last-6-char suffix so a
  // log read doesn't reveal token bytes and rotation can't collide on a 6-hex
  // suffix. Detective `[ratelimit-note]` log lines remain.
  const ident = tokenIdent(clientToken);
  const burstLimit = parseInt(process.env.WAKEPROOF_BURST_LIMIT, 10) || BURST_LIMIT_DEFAULT;
  const burst = checkBurstLimit(ident, burstLimit);
  console.info(
    `[ratelimit-note] token=h:${ident} ts=${new Date().toISOString()} method=POST path=/v1/messages burst=${burst.count}/${burstLimit}`
  );
  if (!burst.allowed) {
    console.warn(`[ratelimit-trip] token=h:${ident} burst=${burst.count}/${burstLimit} (warm-Lambda only)`);
    res.setHeader('Retry-After', String(Math.ceil(BURST_WINDOW_MS / 1000)));
    res.status(429).json({
      error: {
        type: 'rate_limited',
        message: `Burst limit ${burstLimit}/min exceeded. Retry after ${BURST_WINDOW_MS / 1000}s.`,
      },
    });
    return;
  }

  const anthropicVersion = req.headers['anthropic-version'] || '2023-06-01';

  // Bound the upload phase so a stalled cellular connection doesn't consume the
  // full Vercel Hobby 10s function budget before we ever reach Anthropic, and
  // cap the body size so a stray large payload can't DoS the proxy. 8s covers
  // the typical iOS 3.8MB upload at 3G speeds; 6MB ceiling covers expected
  // payload + base64 slack without truncating normal traffic.
  const UPLOAD_TIMEOUT_MS = 8000;
  const MAX_BODY_BYTES = 6 * 1024 * 1024;
  const chunks = [];
  let total = 0;
  const timer = setTimeout(() => req.destroy(new Error('upload_timeout')), UPLOAD_TIMEOUT_MS);
  let bodyBuffer;
  try {
    for await (const chunk of req) {
      total += chunk.length;
      if (total > MAX_BODY_BYTES) throw new Error('body_too_large');
      chunks.push(chunk);
    }
    bodyBuffer = Buffer.concat(chunks);
  } catch (err) {
    const msg = String(err.message || err);
    const status = msg === 'body_too_large' ? 413 : 408;
    res.status(status).json({
      error: {
        type: msg === 'body_too_large' ? 'body_too_large' : 'upload_timeout',
        message: `Proxy ${msg} before reaching Anthropic (after ${UPLOAD_TIMEOUT_MS}ms / ${MAX_BODY_BYTES} bytes)`,
      },
    });
    return;
  } finally {
    clearTimeout(timer);
  }

  let upstream;
  try {
    // L4 (Wave 2.7) SECURITY INVARIANT: upstream headers are built from scratch —
    // do NOT spread req.headers into this object. Client-supplied x-api-key must
    // never reach Anthropic's upstream; the proxy holds the only credential that
    // flows to Anthropic, and it comes exclusively from ANTHROPIC_API_KEY env.
    // A future refactor that spreads req.headers here and relies on later-keys-win
    // ordering would regress the B1+B2 fix; if a future maintainer needs to forward
    // additional headers, pick them explicitly (like anthropic-version below),
    // never bulk-spread.
    upstream = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': anthropicKey, // from env, never from the client
        'anthropic-version': anthropicVersion,
        'User-Agent': 'wakeproof-proxy-vercel/1.0',
      },
      body: bodyBuffer,
    });
  } catch (err) {
    // E-L5 (Wave 2.5): classify the failure for postmortem. console.error so it
    // shows up in Vercel logs at the right severity. Distinguish DNS / TLS /
    // network from generic failure via err.cause when available.
    const cause = classifyFetchError(err);
    console.error(`[upstream_fetch_failed] cause=${cause} err=${String(err)}`);
    res.status(502).json({
      error: {
        type: 'upstream_fetch_failed',
        message: `Upstream fetch failed (${cause})`,
      },
    });
    return;
  }

  // E-L4 (Wave 2.5): bound upstream body read. Worst-case happy path is ~7s
  // upload + Anthropic round-trip; we have the rest of the 10s function budget
  // for body read + response send. Allow up to 1.5s for the body read.
  const UPSTREAM_BODY_TIMEOUT_MS = 1500;
  let originalBytes;
  try {
    originalBytes = await readWithTimeout(upstream, UPSTREAM_BODY_TIMEOUT_MS);
  } catch (err) {
    console.error(`[upstream_response_too_slow] status=${upstream.status} err=${String(err)}`);
    res.status(502).json({
      error: {
        type: 'upstream_response_too_slow',
        message: `Upstream body read exceeded ${UPSTREAM_BODY_TIMEOUT_MS}ms`,
      },
    });
    return;
  }

  // S-I5 (Wave 2.1): sanitise 4xx response bodies to drop any echoed prompt /
  // image-data fragments. Pass-through for 2xx and 5xx.
  const upstreamContentType = upstream.headers.get('Content-Type') || 'application/json';
  const upstreamBody = sanitizeUpstreamBody(upstream.status, originalBytes, upstreamContentType);

  res.setHeader('Content-Type', upstreamContentType);
  res.setHeader('x-wakeproof-worker', 'vercel-serverless-v1');
  res.setHeader('x-wakeproof-upstream-status', String(upstream.status));
  for (const key of [
    'request-id',
    'x-request-id',
    'anthropic-ratelimit-requests-remaining',
    'anthropic-ratelimit-tokens-remaining',
  ]) {
    const value = upstream.headers.get(key);
    if (value) res.setHeader(key, value);
  }

  res.status(upstream.status).send(upstreamBody);
}
