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
//
// Wave 2.1 hardening (2026-04-24):
//   - R1: `anthropic-beta` header tokens are allowlisted; unknown tokens are
//     dropped and logged rather than forwarded verbatim upstream.
//   - R2: HTTP method allowlist (POST, GET, DELETE) with a 405 + Allow header
//     response for anything else.
//   - R3: path segments are validated against `/^[a-zA-Z0-9_\-\/]+$/` and
//     segment-level `.` / `..` / URL-encoded dot bypasses are rejected.
//   - B1: request-count metrics log line emitted on every validated request
//     so post-facto rate-limit abuse can be surfaced from Vercel logs.

/**
 * R1 allowlist — only these beta header values round-trip to Anthropic.
 * Split by comma so multiple betas in a single header are each validated;
 * unknown tokens are dropped with an info log, valid tokens are re-joined.
 * Add new beta identifiers here as we onboard them (keep alphabetical).
 */
const ALLOWED_BETA_HEADERS = new Set([
  'managed-agents-2026-04-01',
]);

/**
 * R2 allowlist — HTTP methods the proxy is willing to forward. POST covers
 * session create / event append; GET covers events fetch + models probe;
 * DELETE covers session termination. HEAD / OPTIONS / PUT / PATCH get 405.
 */
const ALLOWED_METHODS = new Set(['POST', 'GET', 'DELETE']);

/**
 * R3 path segment validator — only permits ASCII alphanumerics, underscore,
 * hyphen, and forward slash. Blocks `.`, `..`, and anything outside the
 * plain path-token charset. We also reject URL-encoded dot patterns BEFORE
 * decoding so a payload like `sessions/%2e%2e/events` can't bypass the
 * post-decode check.
 */
const SAFE_PATH_PATTERN = /^[a-zA-Z0-9_\-\/]+$/;
const ENCODED_DOT_PATTERN = /%2e/i;

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

  // R2: method allowlist. Reject before touching the body to minimise wasted
  // Lambda time on method-probing scans.
  const method = req.method || 'GET';
  if (!ALLOWED_METHODS.has(method)) {
    res.setHeader('Allow', [...ALLOWED_METHODS].join(', '));
    res.status(405).json({
      error: {
        type: 'method_not_allowed',
        message: `Method ${method} is not allowed. Allowed: ${[...ALLOWED_METHODS].join(', ')}.`,
      },
    });
    return;
  }

  // `wakePath` is the everything-after-/v1/ capture from the vercel.json
  // regex rewrite. Examples:
  //   /v1/models                       → wakePath = "models"
  //   /v1/sessions/abc/events          → wakePath = "sessions/abc/events"
  //   /v1/agents                       → wakePath = "agents"
  const wakePathRaw = typeof req.query.wakePath === 'string'
    ? req.query.wakePath
    : Array.isArray(req.query.wakePath)
      ? req.query.wakePath.join('/')
      : '';

  // R3: block URL-encoded dot sequences on the RAW (pre-decode) path. A
  // payload like `sessions/%2e%2e/events` would otherwise decode to `..`
  // after router processing and bypass our segment-level `.` / `..`
  // rejection below.
  if (ENCODED_DOT_PATTERN.test(wakePathRaw)) {
    res.status(400).json({
      error: {
        type: 'invalid_path',
        message: 'URL-encoded dot characters are not permitted in path.',
      },
    });
    return;
  }

  const cleaned = wakePathRaw.replace(/^\/+/, '').replace(/\/+$/, '');
  if (!cleaned) {
    res.status(404).json({
      error: {
        type: 'not_found',
        message: `Wildcard route missing wakePath (req.url=${req.url})`,
      },
    });
    return;
  }

  // R3: charset and segment-traversal check. Runs after edge-slash cleanup
  // so a leading / trailing slash doesn't spuriously reject an otherwise
  // valid path. Any segment equal to `.` or `..` (case-sensitive, matching
  // POSIX semantics) is rejected — combined with the pre-decode encoded-dot
  // check above this covers the standard traversal variants.
  if (!SAFE_PATH_PATTERN.test(cleaned)) {
    res.status(400).json({
      error: {
        type: 'invalid_path',
        message: 'Path contains characters outside the allowed set [a-zA-Z0-9_\\-/].',
      },
    });
    return;
  }
  const segments = cleaned.split('/');
  if (segments.some((seg) => seg === '.' || seg === '..')) {
    res.status(400).json({
      error: {
        type: 'invalid_path',
        message: 'Path contains . or .. segments.',
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
  const anthropicVersion = req.headers['anthropic-version'] || '2023-06-01';

  // R1: beta header allowlist. Clients are free to send one or many
  // comma-separated beta identifiers; we split, validate each against
  // ALLOWED_BETA_HEADERS, and only forward the subset that matches.
  // Unknown tokens are dropped and logged at info level so we can spot
  // misconfigured clients or new beta rollouts without enabling them
  // silently.
  const rawBeta = req.headers['anthropic-beta'];
  let allowedBeta = '';
  if (rawBeta) {
    const submitted = rawBeta.split(',').map((t) => t.trim()).filter(Boolean);
    const kept = submitted.filter((t) => ALLOWED_BETA_HEADERS.has(t));
    const dropped = submitted.filter((t) => !ALLOWED_BETA_HEADERS.has(t));
    if (dropped.length > 0) {
      console.info(`[beta-allowlist] dropped unknown tokens=${JSON.stringify(dropped)} path=${upstreamPath}`);
    }
    allowedBeta = kept.join(', ');
  }

  // B1: detective-only metrics log. The actual token is masked to last 6
  // chars so Vercel logs can correlate abuse without exposing the secret.
  // We log here (post-auth, pre-upstream) so invalid tokens never generate
  // a log line and thus can't flood the log stream with garbage.
  const tokenSuffix = clientToken.slice(-6);
  console.info(
    `[ratelimit-note] token=***${tokenSuffix} ts=${new Date().toISOString()} method=${method} path=/${upstreamPath}`
  );

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
  if (allowedBeta) upstreamHeaders['anthropic-beta'] = allowedBeta;
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
