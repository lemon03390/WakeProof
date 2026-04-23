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

  const apiKey = req.headers['x-api-key'];
  if (!apiKey) {
    res.status(401).json({ error: { type: 'unauthorized', message: 'Missing x-api-key header' } });
    return;
  }

  const anthropicVersion = req.headers['anthropic-version'] || '2023-06-01';

  // R3 fix: bound the upload phase so a stalled cellular connection doesn't consume
  // the full Vercel Hobby 10s function budget before we ever reach Anthropic, and
  // cap the body size so a stray large payload can't DoS our proxy.
  // 8s covers the typical iOS 3.8MB upload at 3G speeds; 6MB ceiling covers the
  // expected 3.8MB + base64 slack + prompt JSON without truncating normal traffic.
  const UPLOAD_TIMEOUT_MS = 8000;
  const MAX_BODY_BYTES = 6 * 1024 * 1024;
  let bodyBuffer;
  try {
    bodyBuffer = await new Promise((resolve, reject) => {
      const chunks = [];
      let total = 0;
      const timer = setTimeout(
        () => reject(new Error('upload_timeout')),
        UPLOAD_TIMEOUT_MS
      );
      req.on('data', (chunk) => {
        total += chunk.length;
        if (total > MAX_BODY_BYTES) {
          clearTimeout(timer);
          reject(new Error('body_too_large'));
          return;
        }
        chunks.push(chunk);
      });
      req.on('end', () => {
        clearTimeout(timer);
        resolve(Buffer.concat(chunks));
      });
      req.on('error', (err) => {
        clearTimeout(timer);
        reject(err);
      });
    });
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
  }

  let upstream;
  try {
    upstream = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': apiKey,
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
