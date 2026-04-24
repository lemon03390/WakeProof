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
import { timingSafeEqual } from 'node:crypto';

export const config = {
  api: {
    bodyParser: false,
  },
};

// L1 (Wave 2.7): constant-time token compare. JS string `!==` short-circuits
// on first mismatch so an attacker with timing telemetry could in principle
// brute-force the token byte-by-byte. `timingSafeEqual` runs in constant time
// but REQUIRES equal-length Buffers (else it throws), so we pre-check length
// and bail on mismatch before allocating the second Buffer. Length of the
// expected token is not secret (it's `openssl rand -hex 32` = 64 chars).
function tokensEqual(clientToken, expectedToken) {
  if (typeof clientToken !== 'string' || typeof expectedToken !== 'string') return false;
  if (clientToken.length !== expectedToken.length) return false;
  const clientBuf = Buffer.from(clientToken, 'utf8');
  const expectedBuf = Buffer.from(expectedToken, 'utf8');
  if (clientBuf.length !== expectedBuf.length) return false;
  return timingSafeEqual(clientBuf, expectedBuf);
}

export default async function handler(req, res) {
  if (req.method !== 'POST') {
    res.status(404).json({ error: { type: 'not_found', message: 'POST only' } });
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

  // Wave 2.1 / B1: detective metrics log. We cannot rate-limit in Vercel
  // Serverless (each invocation cold-starts; shared state does not persist),
  // so instead we log a masked token + timestamp on every validated call so
  // post-facto abuse can be spotted from Vercel logs. See README.md
  // "Cost safety posture" for the full threat model.
  const tokenSuffix = clientToken.slice(-6);
  console.info(
    `[ratelimit-note] token=***${tokenSuffix} ts=${new Date().toISOString()} method=POST path=/v1/messages`
  );

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
    res.status(502).json({ error: { type: 'upstream_fetch_failed', message: String(err) } });
    return;
  }

  const upstreamBody = Buffer.from(await upstream.arrayBuffer());

  res.setHeader('Content-Type', upstream.headers.get('Content-Type') || 'application/json');
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
