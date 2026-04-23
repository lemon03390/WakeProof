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
- Client passes `x-api-key` + `anthropic-version` headers; we forward them unchanged.
- Response includes marker headers: `x-wakeproof-worker: vercel-serverless-v1` and `x-wakeproof-upstream-status: <code>` for client-side diagnostics.

## Timeout caveat

Vercel Hobby tier caps Serverless Function duration at **10 seconds**. Claude Opus 4.7 vision typically returns in 3–8s for our workload, so this usually fits. If you see timeouts after deploying for real use:

- Option A: upgrade Vercel to Pro (~$20/mo) → 60s duration cap.
- Option B: move the proxy to Fly.io or Railway (long-running containers, unlimited duration on free tier within resource budgets).

## Post-hackathon hardening

Same as the Worker README — move `claudeAPIKey` to a Vercel environment variable (`vercel env add ANTHROPIC_API_KEY`) and read `process.env.ANTHROPIC_API_KEY` instead of forwarding `x-api-key`.

## `/v1/*` wildcard route (Layer 3 overnight-agent)

Added 2026-04-24 to support Claude Managed Agents (`/v1/agents`, `/v1/environments`, `/v1/sessions`, `/v1/sessions/:id/events`) plus occasional probes (`/v1/models`) without one explicit route per endpoint.

File: `api/v1/[...path].js`. Matches any `/v1/*` path not served by a more-specific file (so `/v1/messages` stays on `messages.js` with higher routing priority).

Auth model identical to messages.js: `x-wakeproof-token` validated against `WAKEPROOF_CLIENT_TOKEN` env, upstream `x-api-key` injected from `ANTHROPIC_API_KEY` env. Forwards `anthropic-version` and `anthropic-beta` headers. 8s upload cap + 6MB body cap match messages.js.

Response marker: `x-wakeproof-worker: vercel-serverless-wildcard-v1`.

No SSE. iOS polls GET session events at wake time and uses BGProcessingTask-driven event POSTs during the night; each round-trip fits within the Vercel Hobby 10s budget.
