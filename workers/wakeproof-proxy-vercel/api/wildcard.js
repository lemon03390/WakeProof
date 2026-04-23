// WakeProof Claude Proxy — Vercel Serverless wildcard route
//
// Handles anything under /v1/* that isn't /v1/messages (which stays on
// api/v1/messages.js with higher route priority). Primarily Managed Agents
// endpoints (/v1/agents, /v1/environments, /v1/sessions,
// /v1/sessions/:id/events) and occasional probes like /v1/models.
//
// Architecture note: we originally tried Vercel's `[...path].js` filesystem
// catch-all under api/v1/, but Vercel's rewrite-to-filesystem-catch-all
// combination wasn't reliably populating req.query.path for multi-segment
// URLs like /v1/sessions/abc/events. Reverted to a simpler shape: a regex
// rewrite (`/v1/(.*)` → `/api/wildcard?wakePath=$1`) captures the remainder
// as a plain query param, this handler reads it. Single file, no filesystem
// catch-all magic.
//
// Auth model identical to messages.js:
//   - Validate `x-wakeproof-token` against WAKEPROOF_CLIENT_TOKEN env
//   - Inject `x-api-key` from ANTHROPIC_API_KEY env
//   - Forward `anthropic-version` + optional `anthropic-beta`

export const config = {
  api: {
    bodyParser: false,
  },
};

export default async function handler(req, res) {
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
  if (!clientToken || clientToken !== expectedToken) {
    res.status(401).json({
      error: { type: 'unauthorized', message: 'Missing or invalid x-wakeproof-token' },
    });
    return;
  }

  // `wakePath` is the everything-after-/v1/ capture from the vercel.json
  // regex rewrite. Examples:
  //   /v1/models                       → wakePath = "models"
  //   /v1/sessions/abc/events          → wakePath = "sessions/abc/events"
  //   /v1/agents                       → wakePath = "agents"
  const wakePath = typeof req.query.wakePath === 'string'
    ? req.query.wakePath
    : Array.isArray(req.query.wakePath)
      ? req.query.wakePath.join('/')
      : '';
  const cleaned = wakePath.replace(/^\/+/, '').replace(/\/+$/, '');
  if (!cleaned) {
    res.status(404).json({
      error: {
        type: 'not_found',
        message: `Wildcard route missing wakePath (req.url=${req.url})`,
      },
    });
    return;
  }

  // Defense-in-depth: prevent routing /v1/messages through the wildcard
  // even if someone mis-edits vercel.json in the future.
  if (cleaned === 'messages' || cleaned.startsWith('messages/')) {
    res.status(404).json({
      error: { type: 'route_conflict', message: 'messages is served by /api/v1/messages, not the wildcard' },
    });
    return;
  }

  const upstreamPath = `v1/${cleaned}`;
  const method = req.method || 'GET';
  const anthropicVersion = req.headers['anthropic-version'] || '2023-06-01';
  const anthropicBeta = req.headers['anthropic-beta'];

  // Read body for methods that carry one. 8s upload cap + 6MB body cap
  // match messages.js.
  let bodyBuffer;
  if (method !== 'GET' && method !== 'DELETE' && method !== 'HEAD') {
    const UPLOAD_TIMEOUT_MS = 8000;
    const MAX_BODY_BYTES = 6 * 1024 * 1024;
    const chunks = [];
    let total = 0;
    const timer = setTimeout(() => req.destroy(new Error('upload_timeout')), UPLOAD_TIMEOUT_MS);
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
  }

  const upstreamHeaders = {
    'x-api-key': anthropicKey,
    'anthropic-version': anthropicVersion,
    'User-Agent': 'wakeproof-proxy-vercel/1.0-wildcard',
  };
  if (anthropicBeta) upstreamHeaders['anthropic-beta'] = anthropicBeta;
  if (bodyBuffer) upstreamHeaders['Content-Type'] = req.headers['content-type'] || 'application/json';

  let upstream;
  try {
    upstream = await fetch(`https://api.anthropic.com/${upstreamPath}`, {
      method,
      headers: upstreamHeaders,
      body: bodyBuffer,
    });
  } catch (err) {
    res.status(502).json({ error: { type: 'upstream_fetch_failed', message: String(err) } });
    return;
  }

  const upstreamBody = Buffer.from(await upstream.arrayBuffer());
  res.setHeader('Content-Type', upstream.headers.get('Content-Type') || 'application/json');
  res.setHeader('x-wakeproof-worker', 'vercel-serverless-wildcard-v1');
  res.setHeader('x-wakeproof-upstream-status', String(upstream.status));
  res.setHeader('x-wakeproof-upstream-path', upstreamPath);
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
