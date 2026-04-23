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

## Decision record (2026-04-24)

**B.3 dry-run outcome: PRIMARY PATH chosen (Managed Agents).**

All 5 steps passed in ~3 minutes via curl against the Vercel wildcard proxy.
Total cost: ~$0.003 (559 input + 29 output tokens on a single agent call
plus resource creation which is free).

### API-shape corrections discovered

The plan's A.8 code assumed API shapes that turned out to be wrong. Corrections
now landed in `OvernightAgentClient.swift`:

| Endpoint | Plan assumed | Reality |
|---|---|---|
| `POST /v1/environments` | `{"name", "runtime":"python"}` | `{"name"}` only — no runtime field |
| `POST /v1/sessions` | `{"agent_id", "environment_id", "initial_message", "task_budget"}` | `{"agent", "environment_id"}` only. Send seed prompt as follow-up event. |
| `POST /v1/sessions/:id/events` | `{"event": {...}}` (singular) | `{"events": [{...}]}` (plural array) |
| Terminate | `PATCH /v1/sessions/:id {"status":"terminated"}` | `DELETE /v1/sessions/:id` — PATCH endpoint doesn't exist |
| Session ID prefix | `sess_` | `sesn_` |
| `GET events` response key | `{"events": [...]}` | `{"data": [...]}` |

### Observed event flow (single-message round-trip)

1. `session.status_running` (~0.1s after POST event)
2. Our `user.message` (captured)
3. `span.model_request_start`
4. **`agent.message`** — the briefing content (~1s after event)
5. `span.model_request_end` with `model_usage` (input/output tokens)
6. `session.status_idle` with `stop_reason.type = "end_turn"`

Round-trip event → agent.message: ~2 seconds. Well under the Vercel 10s cap.

### Next steps

- **B.4a**: implement `ManagedAgentBriefingSource` as an `OvernightBriefingSource` conformer wrapping the corrected `OvernightAgentClient`.
- **B.5**: swap `NoopBriefingSource` for `ManagedAgentBriefingSource` in `WakeProofApp`.
- **B.6**: compressed-night smoke test.

### Cost projection

Per-night production run (assuming 1 session open at bedtime, 2-3 BGTask pokes during night, one fetch at wake):
- Session create: free
- 4 user.message events × ~500 input tokens each + agent response: ~2500 input + ~200 output = ~$0.0175 per night.
- Session DELETE: free.
- 7-night demo: ~$0.12. Well under $50 cap.
