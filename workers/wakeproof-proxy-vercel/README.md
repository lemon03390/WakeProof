# WakeProof Claude Proxy — Vercel Serverless fallback

Alternative to the Cloudflare Worker at [../wakeproof-proxy](../wakeproof-proxy).

## Why this exists

The Cloudflare Worker version routes iOS requests from Hong Kong through Cloudflare's HKG edge to Anthropic's HKG edge, which applies strict bot rules and returns `HTTP 403 "Request not allowed"`. Cloudflare Smart Placement kept the worker pinned to `local-HKG` even after deploying `mode = "smart"` (it treats the fast 403s as successful responses, so it has no signal to relocate).

This Vercel Serverless function runs on **AWS Lambda** (Node.js 20) in the default `iad1` (US East) region. AWS Lambda egress is outside Cloudflare's network entirely, so the upstream fetch to `api.anthropic.com` reaches Anthropic's US edge via a normal AWS → Anthropic path — the same path Anthropic's SDKs and server integrations use — which accepts the request.

## Deploy

1. From this directory:

```
cd workers/wakeproof-proxy-vercel
npx vercel login        # opens browser if first time
npx vercel deploy --prod
```

First deploy asks a few interactive questions:
- **Set up and deploy?** → Yes
- **Which scope?** → your personal account
- **Link to existing project?** → No
- **Project name?** → `wakeproof-proxy` (or accept default)
- **Directory with your code?** → `.`
- **Modify settings?** → No

The output ends with a production URL like `https://wakeproof-proxy-<hash>.vercel.app` or `https://wakeproof-proxy.vercel.app`. The `/v1/messages` rewrite means you call `https://<host>/v1/messages` directly (no `/api/` prefix needed client-side).

2. Paste the URL into `WakeProof/WakeProof/Services/Secrets.swift`:

```swift
static let claudeEndpoint: String = "https://<your-host>.vercel.app/v1/messages"
```

3. Rebuild + install the app, retry the smoke test.

## Request/response contract

Identical to [../wakeproof-proxy/worker.js](../wakeproof-proxy/worker.js):

- Accepts `POST /v1/messages` with Anthropic's standard body shape.
- Client passes `x-wakeproof-token` header; the proxy validates against `WAKEPROOF_CLIENT_TOKEN` env and injects `x-api-key` from `ANTHROPIC_API_KEY` env.
- Response includes marker headers: `x-wakeproof-worker: vercel-serverless-v1` and `x-wakeproof-upstream-status: <code>` for client-side diagnostics.

## Timeout caveat

Vercel Hobby tier caps Serverless Function duration at **10 seconds**. Claude Opus 4.7 vision typically returns in 3–8s for our workload, so this usually fits. If you see timeouts after deploying for real use:

- Option A: upgrade Vercel to Pro (~$20/mo) → 60s duration cap.
- Option B: move the proxy to Fly.io or Railway (long-running containers, unlimited duration on free tier within resource budgets).

## `/v1/*` wildcard route (Layer 3 overnight-agent)

Added 2026-04-24 to support Claude Managed Agents (`/v1/agents`, `/v1/environments`, `/v1/sessions`, `/v1/sessions/:id/events`) plus occasional probes (`/v1/models`) without one explicit route per endpoint.

File: `api/wildcard.js`. Matches any `/v1/*` path not served by a more-specific file (so `/v1/messages` stays on `messages.js` with higher routing priority).

Auth model identical to messages.js: `x-wakeproof-token` validated against `WAKEPROOF_CLIENT_TOKEN` env, upstream `x-api-key` injected from `ANTHROPIC_API_KEY` env. Forwards `anthropic-version` and validates `anthropic-beta` against an allowlist (see below). 8s upload cap + 6MB body cap match messages.js.

Response marker: `x-wakeproof-worker: vercel-serverless-wildcard-v1`.

No SSE. iOS polls GET session events at wake time and uses BGProcessingTask-driven event POSTs during the night; each round-trip fits within the Vercel Hobby 10s budget.

## Wave 2.1 hardening (2026-04-24)

The wildcard route applies input validation before forwarding upstream:

- **HTTP method allowlist** — only `POST`, `GET`, `DELETE` are forwarded. Other methods return `405` with an `Allow` header.
- **`anthropic-beta` header allowlist** — only tokens listed in `ALLOWED_BETA_HEADERS` at the top of `wildcard.js` are forwarded. Today that set is `{'managed-agents-2026-04-01'}`. Multiple comma-separated tokens are each validated; unknown ones are dropped with an info log, known ones are re-joined and forwarded.
- **Path traversal rejection** — the `wakePath` capture is validated against `/^[a-zA-Z0-9_\-\/]+$/` and any segment equal to `.` or `..` is rejected with `400 invalid_path`. URL-encoded dot patterns (`%2e`) are rejected on the raw (pre-decode) path so `sessions/%2e%2e/events` cannot bypass the segment-level check.

These layers do not replace the proxy's auth check — they run alongside it.

## Cost safety posture

### Stranded-session cleanup cron (B1)

`api/cron/cleanup-stale-sessions.js` runs every two hours via the Vercel cron config in `vercel.json` (`"schedule": "0 */2 * * *"`). It enumerates Managed Agents sessions, finds any whose attached agent name starts with `wakeproof-overnight` and whose `created_at` is more than 12 hours old, and calls `DELETE /v1/sessions/:id` on each.

Why: the overnight flow creates a session per night, seeds it, then the iOS scheduler terminates it when the alarm fires. If the app is force-quit overnight, termination never runs and the session accrues billable agent-running time indefinitely. The cron is the backstop.

Authentication:
- Vercel's own invocation sends `x-vercel-cron: 1` — the handler accepts that as sufficient.
- Manual triggers (curl from a dev laptop) can use `Authorization: Bearer $WAKEPROOF_CRON_TOKEN` where the env var is set on Vercel.
- Without either header, the handler returns 401.

Manual trigger for testing:

```
curl -H "Authorization: Bearer $WAKEPROOF_CRON_TOKEN" https://<your-host>.vercel.app/api/cron/cleanup-stale-sessions
```

Response body includes `{scanned, stale, deleted, failed, results}` so you can see exactly what it touched.

### Request-count metrics logging (B1 detective)

Every validated request (both `messages.js` and `wildcard.js`) logs a line in the form:

```
[ratelimit-note] token=***<last6> ts=<iso> method=<method> path=<path>
```

The token is masked to its last six characters so logs can correlate abuse without exposing the secret. This is **detective**, not **preventative** — see the next section for why.

### Explicit non-goal: per-invocation rate limiting

In-memory / per-invocation rate limiting (`const counts = {}` at module scope) is **not implemented**. Vercel Serverless cold-starts each invocation on a fresh Lambda; shared state does not persist between requests — so a map of `{token: count}` at module scope is effectively reset on every cold start, which happens roughly every ~minute of idle. Implementing it would waste code without providing enforcement.

If the threat model changes (specifically: if the proxy token leaks publicly and abuse exceeds our $50/session budget), the recommended post-hackathon hardening is:

1. Add [Upstash Redis](https://upstash.com/) via the Vercel Marketplace (serverless-compatible KV).
2. In `messages.js` and `wildcard.js`, before forwarding: `await redis.incr(tokenKey)` with `EXPIRE` of 1 hour; reject with `429` if the count exceeds an abuse ceiling.
3. The cron above already handles session cleanup, so the Redis layer only needs to cover ad-hoc message spam.

Approximate cost: Upstash Hobby tier is free up to 10k commands/day; for WakeProof's volumes that tier is enough.

### Token rotation procedure

The proxy token (`WAKEPROOF_CLIENT_TOKEN`) is a shared secret embedded in the iOS binary. Rotate it if:
- The binary is shared publicly (e.g. TestFlight with external testers).
- Logs (`[ratelimit-note]`) show traffic from token suffixes you don't recognise.
- Any other evidence of leakage.

Steps:

1. Generate a new token locally:

```
openssl rand -hex 32
```

2. Update the Vercel env var:

```
vercel env rm WAKEPROOF_CLIENT_TOKEN production
vercel env add WAKEPROOF_CLIENT_TOKEN production
# paste the new value when prompted
vercel deploy --prod
```

3. Update `WakeProof/WakeProof/Services/Secrets.swift` with the same value, rebuild, and reinstall on any devices running the app.

4. Any old-token requests will start returning 401 within ~seconds of the new Vercel deployment going live.
