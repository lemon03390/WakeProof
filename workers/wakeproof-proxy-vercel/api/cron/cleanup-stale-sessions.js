// WakeProof Claude Proxy — cron: cleanup stale overnight agent sessions
//
// Wave 2.1 / B1: the overnight Managed Agents path creates a session per
// night, seeds it with sleep data, and terminates it when the alarm fires.
// If the app is force-quit overnight, the scheduler never runs its cleanup
// step, and the session accrues billable agent-running time indefinitely.
// This cron enumerates the account's sessions every two hours and terminates
// any `wakeproof-overnight-*` session older than 12 hours that is still in
// an `active` state.
//
// Schedule: `0 */2 * * *` from `vercel.json` (every two hours on the hour).
// Twelve hours is a generous ceiling — a legitimate overnight session
// runs ≤10h; beyond that we assume the pairing device is gone.
//
// Auth:
//   - S-I2 (Wave 2.1, 2026-04-26): Vercel signs scheduled cron invocations with
//     `Authorization: Bearer <CRON_SECRET>` automatically when the `CRON_SECRET`
//     env var is set on the project. We REQUIRE this Bearer auth — the
//     `x-vercel-cron: 1` header alone is no longer sufficient. The header was
//     accepted historically, but Vercel's platform stripping of that header
//     for non-cron traffic is undocumented behaviour. Trusting only Bearer
//     auth removes the entire class of "spoof the header" attack.
//   - Manual triggers (curl from a dev laptop) use the same Bearer surface
//     with `WAKEPROOF_CRON_TOKEN` value. Either env var's value is accepted.
//   - Setup: `vercel env add CRON_SECRET production` with `openssl rand -hex 32`.
//     Without CRON_SECRET, scheduled crons return 401 — Vercel won't add the
//     header on its own. This is the intended fail-closed posture.
//
// Cost: one listing call + N DELETE calls, where N is the stale session
// count. Both call the Managed Agents beta so we forward the beta header.
// Anthropic API pricing for listing/deleting is cheap-to-free vs. the
// session-hour billing this prevents.

// P4 (Stage 6 Wave 1): single source of truth for the current Managed
// Agents beta identifier. See ../../lib/beta-headers.js for the rationale
// (cron + wildcard share the constant so a future beta bump is one edit).
import { CURRENT_BETA } from '../../lib/beta-headers.js';

const ANTHROPIC_BASE = 'https://api.anthropic.com';
const WAKEPROOF_AGENT_PREFIX = 'wakeproof-overnight';
const STALE_THRESHOLD_MS = 12 * 60 * 60 * 1000; // 12 hours

export default async function handler(req, res) {
  const anthropicKey = process.env.ANTHROPIC_API_KEY;
  if (!anthropicKey) {
    res.status(500).json({ error: { type: 'cron_not_configured', message: 'ANTHROPIC_API_KEY missing' } });
    return;
  }

  // S-I2 (Wave 2.1, 2026-04-26): Bearer-only auth. Either CRON_SECRET (Vercel
  // platform-injected for scheduled crons) or WAKEPROOF_CRON_TOKEN (manual curl)
  // is accepted. The `x-vercel-cron: 1` header is no longer trusted.
  const authHeader = req.headers['authorization'] || '';
  const cronSecret = process.env.CRON_SECRET;
  const manualToken = process.env.WAKEPROOF_CRON_TOKEN;
  const presented = authHeader.startsWith('Bearer ') ? authHeader.slice(7) : '';

  // Use constant-time-ish comparison via length pre-check to discourage timing
  // oracles. Both env vars are 64-char hex (256-bit entropy) so length match
  // is the common case.
  const isCron = !!cronSecret && presented.length === cronSecret.length && presented === cronSecret;
  const isManual = !!manualToken && presented.length === manualToken.length && presented === manualToken;

  if (!isCron && !isManual) {
    console.warn(`[cron-cleanup] unauthorized invocation rejected; presented_len=${presented.length}`);
    res.status(401).json({ error: { type: 'unauthorized', message: 'Bearer token required (CRON_SECRET or WAKEPROOF_CRON_TOKEN)' } });
    return;
  }

  const startedAt = new Date();
  console.info(`[cron-cleanup] invoked at=${startedAt.toISOString()} trigger=${isCron ? 'vercel-cron' : 'manual'}`);

  const upstreamHeaders = {
    'x-api-key': anthropicKey,
    'anthropic-version': '2023-06-01',
    'anthropic-beta': CURRENT_BETA,
    'User-Agent': 'wakeproof-proxy-vercel/cron-cleanup',
  };

  // 1. List sessions. The Managed Agents beta exposes /v1/sessions with
  //    pagination; for the expected volumes (1 session per user per night,
  //    hackathon scale ≤50 users) a single page covers us. If we ever
  //    outgrow one page, add `before_id` pagination here.
  let listing;
  try {
    listing = await fetch(`${ANTHROPIC_BASE}/v1/sessions?limit=100`, {
      method: 'GET',
      headers: upstreamHeaders,
    });
  } catch (err) {
    console.error(`[cron-cleanup] list fetch failed: ${String(err)}`);
    res.status(502).json({ error: { type: 'upstream_fetch_failed', message: String(err) } });
    return;
  }

  if (!listing.ok) {
    const snippet = await listing.text().catch(() => '<non-utf8>');
    console.error(`[cron-cleanup] list HTTP ${listing.status}: ${snippet.slice(0, 500)}`);
    res.status(502).json({
      error: {
        type: 'upstream_error',
        status: listing.status,
        message: `Upstream list returned ${listing.status}`,
      },
    });
    return;
  }

  let sessionsPayload;
  try {
    sessionsPayload = await listing.json();
  } catch (err) {
    console.error(`[cron-cleanup] list JSON parse failed: ${String(err)}`);
    res.status(502).json({ error: { type: 'upstream_parse_failed', message: String(err) } });
    return;
  }

  // API surface returns sessions in `data: [...]`. Defensive fallback for
  // shape drift: accept `sessions` or top-level array.
  const sessions = Array.isArray(sessionsPayload?.data)
    ? sessionsPayload.data
    : Array.isArray(sessionsPayload?.sessions)
      ? sessionsPayload.sessions
      : Array.isArray(sessionsPayload)
        ? sessionsPayload
        : [];

  const now = Date.now();
  const stale = sessions.filter((session) => {
    // Only touch sessions whose attached agent name matches our naming
    // convention. The exact field depends on API shape — we check both the
    // session's own `name` (if echoed) and its `agent.name` nested object.
    const agentName = session?.agent?.name || session?.agent_name || session?.name || '';
    if (!agentName.startsWith(WAKEPROOF_AGENT_PREFIX)) return false;
    if (session?.state && session.state !== 'active') return false;
    const createdAtRaw = session?.created_at;
    if (!createdAtRaw) return false;
    const createdAtMs = Date.parse(createdAtRaw);
    if (Number.isNaN(createdAtMs)) return false;
    return (now - createdAtMs) > STALE_THRESHOLD_MS;
  });

  console.info(`[cron-cleanup] scanned=${sessions.length} stale=${stale.length}`);

  // 2. Terminate each stale session. Collect outcomes so the response body
  //    gives a clean audit trail (visible in Vercel logs + curl output).
  const results = [];
  for (const session of stale) {
    const id = session?.id;
    if (!id) continue;
    try {
      const del = await fetch(`${ANTHROPIC_BASE}/v1/sessions/${encodeURIComponent(id)}`, {
        method: 'DELETE',
        headers: upstreamHeaders,
      });
      const ok = del.ok;
      const status = del.status;
      if (!ok) {
        const snippet = await del.text().catch(() => '');
        console.warn(`[cron-cleanup] delete failed id=${id} status=${status} body=${snippet.slice(0, 200)}`);
      } else {
        console.info(`[cron-cleanup] deleted id=${id} status=${status}`);
      }
      results.push({ id, status, ok });
    } catch (err) {
      console.warn(`[cron-cleanup] delete threw id=${id} err=${String(err)}`);
      results.push({ id, status: 0, ok: false, error: String(err) });
    }
  }

  const elapsedMs = Date.now() - startedAt.getTime();
  res.status(200).json({
    ok: true,
    scanned: sessions.length,
    stale: stale.length,
    deleted: results.filter((r) => r.ok).length,
    failed: results.filter((r) => !r.ok).length,
    elapsed_ms: elapsedMs,
    results,
  });
}
