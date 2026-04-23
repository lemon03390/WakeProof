# WakeProof Claude Proxy (Cloudflare Worker)

Cloudflare Worker that forwards `POST /v1/messages` to `https://api.anthropic.com/v1/messages`.

## Why this exists

iOS `URLSession` calls directly to `api.anthropic.com` get blocked at Cloudflare's edge with `HTTP 403 "Request not allowed"` — Cloudflare Bot Management scores the HTTP/2 frame pattern + TLS extension shape as non-browser and rejects before Anthropic's backend ever sees the request. `curl` on the same machine with the same API key, same endpoint, same body returns `HTTP 200`. Browser-like User-Agent, Accept headers, and forcing TLS 1.2 did not lower the score enough (see commit history: `a3252c3`, `8baf307`, `7e23393`).

Server-to-server fetches from inside a Cloudflare Worker to `api.anthropic.com` are not subject to this bot-scoring, so the Worker is a transparent shim: the iOS app POSTs to the Worker URL with the same body and headers it would have sent to Anthropic, and the Worker forwards as-is.

## Deploy

1. Install wrangler (Cloudflare's CLI) if you don't have it:

```
npm install -g wrangler
```

2. Sign in to your Cloudflare account:

```
wrangler login
```

This opens a browser to authorize. The free Workers tier is sufficient for this proxy.

3. From `workers/wakeproof-proxy/`:

```
cd workers/wakeproof-proxy
wrangler deploy
```

The output ends with a URL like `https://wakeproof-proxy.<your-subdomain>.workers.dev`. Copy it.

4. Open `WakeProof/WakeProof/Services/Secrets.swift` (the real one, git-ignored) and paste the Worker URL as the value of `claudeEndpoint`, appending `/v1/messages`:

```swift
static let claudeEndpoint: String = "https://wakeproof-proxy.<your-subdomain>.workers.dev/v1/messages"
```

5. Rebuild and install the app. `Phase → verifying` should now succeed and the verdict banner should reflect whatever Claude returned for your actual baseline vs. live photo.

## How auth works today

The iOS app sends the Anthropic API key in the `x-api-key` header. The Worker forwards that header verbatim to Anthropic. This keeps `Secrets.swift` as the single source of truth for the key during the hackathon.

## Post-hackathon hardening

Move the Anthropic key off the iOS client entirely:

1. `wrangler secret put ANTHROPIC_API_KEY` — store the key server-side
2. Update `worker.js` to read `env.ANTHROPIC_API_KEY` instead of forwarding `x-api-key`
3. Add a shared per-install token the iOS app sends (so the Worker can reject unauthorized callers beyond the obscurity of the URL)
4. Remove `claudeAPIKey` from `Secrets.swift`

That's the production-grade layout. Out of scope for the 5-day hackathon.

## Local dev / testing

```
wrangler dev
```

Spins up a local dev server at `http://localhost:8787`. You can curl against it with the same body you'd send to Anthropic and verify the proxy relays correctly before deploying.
