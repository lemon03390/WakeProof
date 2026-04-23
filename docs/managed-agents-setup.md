# Managed Agents Setup (Layer 3 Primary Path)

> One-time setup + dry-run procedure for WakeProof's overnight Managed Agent. Run the steps in order in Task B.3.

## Prerequisites

- Anthropic API Tier 4 (user confirmed during planning)
- Vercel proxy wildcard route (`/api/v1/*` wildcard) already deployed — see `workers/wakeproof-proxy-vercel/README.md` and Task A.1
- Environment variables on Vercel: `ANTHROPIC_API_KEY`, `WAKEPROOF_CLIENT_TOKEN`
- iOS `Secrets.swift`: `claudeEndpoint = "https://wakeproof-proxy-vercel.vercel.app/v1/messages"` (the client derives the base URL by stripping `/v1/messages`)

## Step 1 — Dry-run agent create

```bash
curl -sS -X POST \
  -H "x-wakeproof-token: $TOKEN" \
  -H "Content-Type: application/json" \
  -H "anthropic-beta: managed-agents-2026-04-01" \
  -d '{"name":"wakeproof-overnight","model":"claude-opus-4-7","system":"test agent"}' \
  https://wakeproof-proxy-vercel.vercel.app/v1/agents
```

Expected: 201 Created with `{"id": "agent_abc..."}`. Save that ID.

## Step 2 — Dry-run environment create

```bash
curl -sS -X POST \
  -H "x-wakeproof-token: $TOKEN" \
  -H "Content-Type: application/json" \
  -H "anthropic-beta: managed-agents-2026-04-01" \
  -d '{"name":"wakeproof-env-python","runtime":"python"}' \
  https://wakeproof-proxy-vercel.vercel.app/v1/environments
```

Expected: 201 Created with `{"id": "env_xyz..."}`. Save that ID.

## Step 3 — Dry-run session

```bash
curl -sS -X POST \
  -H "x-wakeproof-token: $TOKEN" \
  -H "Content-Type: application/json" \
  -H "anthropic-beta: managed-agents-2026-04-01" \
  -d '{
    "agent_id": "agent_abc...",
    "environment_id": "env_xyz...",
    "initial_message": {"role": "user", "content": [{"type": "text", "text": "say hi"}]},
    "task_budget": {"type": "tokens", "total": 20000}
  }' \
  https://wakeproof-proxy-vercel.vercel.app/v1/sessions
```

Expected: 201 Created with `{"id": "sess_..."}`. Save that session id.

## Step 4 — Poll for agent.message

```bash
curl -sS -H "x-wakeproof-token: $TOKEN" \
  -H "anthropic-beta: managed-agents-2026-04-01" \
  https://wakeproof-proxy-vercel.vercel.app/v1/sessions/sess_.../events
```

Expected: within 30–60 s, an `agent.message` event appears containing a text reply.

## Step 5 — Terminate

```bash
curl -sS -X PATCH \
  -H "x-wakeproof-token: $TOKEN" \
  -H "Content-Type: application/json" \
  -H "anthropic-beta: managed-agents-2026-04-01" \
  -d '{"status":"terminated"}' \
  https://wakeproof-proxy-vercel.vercel.app/v1/sessions/sess_...
```

Expected: 200 OK.

## Cost for the dry-run

20,000-token task budget × Opus 4.7 rates = at most ~$0.50. Running a ~1-minute session adds ~$0.0013 in session-hour billing. Total for the full dry-run: under $0.60.

## If ANY step fails

Record the error body and status. Decide: proceed with primary path (Task B.3 continues) or switch to fallback (Task B.4 onwards uses `NightlySynthesisClient` instead of `OvernightAgentClient`).

If Step 5 specifically returns 404 or 405, the `terminateSession()` method in `OvernightAgentClient.swift` already falls back to `POST /v1/sessions/:id/events` with `{"event":{"type":"user.interrupt","reason":"client-terminated"}}`. Verify that fallback succeeds manually, and update the `terminateViaInterruptEvent` body literal if Anthropic accepts a different shape.

## Re-use on subsequent nights

`OvernightAgentClient` caches the agent id and environment id in UserDefaults after first successful create. Nightly use is `startSession()` only.
