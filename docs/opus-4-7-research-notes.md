# Opus 4.7 Research Notes

```yaml
date: 2026-04-22
researcher: Claude Opus 4.7 (1M context) via Claude Code
purpose: Resolve three open questions blocking Layers 2 and 3 of the four-layer Opus 4.7 strategy (docs/opus-4-7-strategy.md, docs/technical-decisions.md Decision 8).
sources_checked:
  - https://platform.claude.com/docs/en/agents-and-tools/tool-use/memory-tool
  - https://platform.claude.com/docs/en/build-with-claude/task-budgets
  - https://platform.claude.com/docs/en/managed-agents/overview
  - https://platform.claude.com/docs/en/managed-agents/quickstart
  - https://platform.claude.com/docs/en/managed-agents/sessions
  - https://platform.claude.com/docs/en/managed-agents/events-and-streaming
  - https://platform.claude.com/docs/en/managed-agents/memory (research preview)
  - https://platform.claude.com/docs/en/about-claude/models/whats-new-claude-4-7
  - https://platform.claude.com/docs/en/about-claude/pricing
  - https://claude.com/blog/claude-managed-agents (launch announcement)
```

---

## Question 1 — Memory Tool (supports Layer 2)

### Answer

Read + write during a run is fully supported. It is a **client-side** tool (type `memory_20250818`): Claude emits tool calls, your app executes them against your own backend (file system, DB, encrypted store). Writes within a single conversation are the intended pattern — the 4.7 release notes say Opus 4.7 "is better at writing and using file-system-based memory" for agents that maintain "a scratchpad, notes file, or structured memory store across turns." The API shape did not change in 4.7; the model's reliability at using it did.

File-system semantics: a virtual `/memories` directory, six commands (`view`, `create`, `str_replace`, `insert`, `delete`, `rename`), persistence determined by your backend, ZDR-eligible. You must enforce path-traversal protection so Claude cannot escape `/memories`.

Injection is **automatic**. Enabling the tool causes Anthropic to auto-inject a system-prompt "MEMORY PROTOCOL" instruction, and Claude emits a `view` on `/memories` before doing anything else, then pulls specific files on demand. You do not pre-load memory into the prompt.

Managed Agents has a separate server-side **Memory Stores** system (Research Preview, access-gated). Up to 8 stores per session, `read_write` or `read_only`. Richer path if access is granted; otherwise the client-side tool is sufficient.

### Evidence

- https://platform.claude.com/docs/en/agents-and-tools/tool-use/memory-tool — "Claude can create, read, update, and delete files that persist between sessions" and "Since this is a client-side tool, Claude makes tool calls to perform memory operations, and your application executes those operations locally. This gives you complete control over where and how the memory is stored."
- Same page lists all six commands (`view`, `create`, `str_replace`, `insert`, `delete`, `rename`) with JSON schemas and error semantics. Tool type string: `memory_20250818`.
- Same page, auto-injected system instruction: "MEMORY PROTOCOL: 1. Use the `view` command of your `memory` tool to check for earlier progress. ... ASSUME INTERRUPTION: Your context window might be reset at any moment, so you risk losing any progress that is not recorded in your memory directory."
- https://platform.claude.com/docs/en/about-claude/models/whats-new-claude-4-7 — "Claude Opus 4.7 is better at writing and using file-system-based memory. ... To give Claude a managed scratchpad without building your own, use the client-side memory tool."
- https://platform.claude.com/docs/en/managed-agents/memory — "Memory stores let the agent carry learnings across sessions" — server-side variant; research preview, 8 stores max per session, individual memories capped at 100KB (~25K tokens), full version history preserved per mutation.

### Implication for WakeProof

Layer 2 is unblocked. Mount a per-user directory on device (e.g. `wakeproof/memories/<uuid>/`) and have the iOS app handle tool calls. Each verification request enables the memory tool; Claude auto-reads `/memories/profile.md` + `/memories/history.md`, reasons, emits `str_replace`/`create` to update. Local-first (matches Decision 4), no backend. If Managed Agents research-preview access is granted before Day 4, upgrade Layer 2 to share one server-side memory store with Layer 3. The "agent memory" framing holds either way; no fallback needed.

### Open follow-ups

- Do memory-tool file reads count as input tokens on every call? (Almost certainly yes — they are tool results. Budget a small padding per verification.)
- SDK helper classes (`BetaAbstractMemoryTool` Python, `betaMemoryTool` TS) — confirm Swift consumers hand-roll handlers since no Swift SDK helper exists.

---

## Question 2 — Task Budgets (supports Layer 3)

### Answer

Task budgets are **token-denominated, not time-denominated** — tokens consumed across an agentic loop (thinking + tool calls + tool results + output). Minimum is **20,000 tokens** (a 400 error below that); no documented maximum beyond practical limits. Budgets are **advisory** — Claude sees a running countdown and paces itself but may exceed if interrupting a tool call would be disruptive. `max_tokens` is the only hard per-request ceiling.

An 8-hour wall-clock "overnight budget" is **not directly expressible**. No duration field exists. This does not block Layer 3: duration lives in the Managed Agents session, not the task budget. Size the token envelope for the work (e.g. 128k–256k tokens to ingest HealthKit samples + analyze + draft briefing); wall-clock duration falls out of Claude's pace plus free idle time between events.

For multi-request client-side agent loops, pass `remaining` on follow-ups so the countdown survives client-side compaction. Requires the `task-budgets-2026-03-13` beta header; Opus-4.7-only (not 4.6, not Haiku 4.5, not Claude Code). **Not supported inside Managed Agents sessions** — that surface handles effort automatically.

Pricing: no extra fee for the feature. Standard Opus 4.7 token rates ($5 / $0.50 cache / $25 per MTok). A 128k-token loop is ≤ $3.20 if all uncached output, ≤ $0.65 if input-heavy + cached.

### Evidence

- https://platform.claude.com/docs/en/build-with-claude/task-budgets — "Task budgets let you tell Claude how many tokens it has for a full agentic loop, including thinking, tool calls, tool results, and output."
- Same page: "The minimum accepted `task_budget.total` is **20,000 tokens**; values below the minimum return a 400 error." Schema shape: `{"type": "tokens", "total": N, "remaining": M?}`.
- Same page: "Task budgets are a **soft hint, not a hard cap**. Claude may occasionally exceed the budget if it is in the middle of an action that would be more disruptive to interrupt than to finish."
- Same page, feature support table: Opus 4.7 public beta (`task-budgets-2026-03-13`); Opus 4.6 / Sonnet 4.6 / Haiku 4.5 = Not supported. "Task budgets are not supported on Claude Code or Cowork surfaces at launch."
- https://platform.claude.com/docs/en/about-claude/models/whats-new-claude-4-7 — task-budgets section confirms 20k minimum and advisory semantics; the `xhigh` effort level is new in 4.7 and pairs naturally with task budgets for long-horizon work.
- https://platform.claude.com/docs/en/about-claude/pricing — Opus 4.7 token rates confirmed: $5 / $0.50 cache-read / $25 output per MTok.

### Implication for WakeProof

**Don't model "sleep window" as a budget** — model it as a token envelope. Pattern: (a) open a Managed Agents session at bedtime, (b) send one `user.message` instructing Claude to wait for HealthKit scratchpad updates and produce the morning briefing, (c) let the session idle (free) between periodic pokes. Duration lives in the session. If Layer 3 falls back to a client-side loop (Messages API + BGProcessingTask), then `task_budget: {type: "tokens", total: 128000}` with the beta header becomes the pace-control primitive — decrement `remaining` across calls. Key caveat: task budgets do not apply inside a Managed Agent — rely on `effort` + prompting there.

### Open follow-ups

- Is there a way to hint wall-clock duration to a Managed Agents session (e.g. "pause and wait 30 minutes before next step")? Not documented — **requires Michael Cohen live session 2026-04-23 11 PM HKT** to confirm idiomatic pattern.
- Can `remaining` be negative in practice if Claude overshoots? Behavior undocumented.

---

## Question 3 — Claude Managed Agents (supports Layer 3)

### Answer

**Hosting.** Fully Anthropic-hosted. You do not bring your own infra. Each `Session` is "a running agent instance within an environment" where an `Environment` is "a configured container template (packages, network access)" with Python, Node.js, Go, etc. pre-installed. Network access is configurable (`unrestricted` in the quickstart). Only available through the Claude API directly — not on Bedrock/Vertex/Foundry.

**Invocation.** SDK / REST API, not webhooks. Three separate resources: `agents` (reusable config), `environments` (container templates), `sessions` (actual runs). Flow: create an agent once, create an environment once, then for each task `POST /v1/sessions` to spin up a session, `POST /v1/sessions/{id}/events` to send `user.message` events, and open a **Server-Sent Events (SSE) stream** on `/v1/sessions/{id}/stream` to receive `agent.message`, `agent.thinking`, `agent.tool_use`, `agent.tool_result`, `session.status_*` events. If the stream disconnects, the API buffers events server-side and you can reconnect. Events are persisted and fully retrievable after the fact. Sessions have four statuses — `idle`, `running`, `rescheduling`, `terminated`.

**Observability.** Session tracing and inspection are built into the Claude Console ("inspect every tool call, decision, and failure mode" — launch blog). Events are persisted server-side and listable/fetchable by session ID. Session checkpoints (full container state, files, installed tools) are preserved for **30 days** after the session's last activity; periodic `user.message` events reset the inactivity timer.

**Pricing.** Two-part: standard token rates (Opus 4.7 = $5 / $0.50 cache / $25 per MTok) **plus $0.08 per session-hour of `running` runtime**. Runtime accrues only while status is `running`; `idle`, `rescheduling`, and `terminated` are free. Web search inside a session is the normal $10 per 1,000 searches. Session runtime replaces Code Execution container-hour billing (no double charge). Batch, fast-mode, data-residency, and long-context premium modifiers do **not** apply to Managed Agents.

**Rate limits.** Per-organization: 60 req/min on create endpoints, 600 req/min on read endpoints. Tier-based token RPM limits layered on top.

**Beta flag.** `managed-agents-2026-04-01` on all requests. Outcomes, multi-agent, and **Agent Memory stores** are Research Preview — request access.

### Evidence

- https://platform.claude.com/docs/en/managed-agents/overview — "Claude Managed Agents provides the harness and infrastructure for running Claude as an autonomous agent. Instead of building your own agent loop, tool execution, and runtime, you get a fully managed environment where Claude can read files, run commands, browse the web, and execute code securely."
- Same page, rate-limits table: "Create endpoints: 60 requests per minute / Read endpoints: 600 requests per minute." Beta header: `managed-agents-2026-04-01`.
- https://platform.claude.com/docs/en/managed-agents/sessions — session statuses, agent/environment/session three-tier resource model, pinning to agent version, archive/delete semantics, "A `running` session cannot be deleted; send an [interrupt event] if you need to delete it immediately."
- https://platform.claude.com/docs/en/managed-agents/events-and-streaming — SSE event stream, user/agent event types, "While session history is persisted until deleted, checkpoints are only preserved for 30 days after the session's last activity. If your workflow requires the full container state (files, installed tools, and so on) to persist beyond 30 days, send periodic `user.message` events to reset the inactivity timer before the checkpoint expires."
- https://platform.claude.com/docs/en/managed-agents/quickstart — full invocation flow: `POST /v1/agents`, `POST /v1/environments`, `POST /v1/sessions`, `POST /v1/sessions/{id}/events`, SSE on `/v1/sessions/{id}/stream`.
- https://platform.claude.com/docs/en/about-claude/pricing — Managed Agents pricing section: "$0.08 per session-hour", "Runtime is measured to the millisecond and accrues only while the session's status is `running`. Time spent `idle` ... `rescheduling`, or `terminated` does not count toward runtime." Worked example shows a 1-hour Opus 4.7 session consuming 50k input + 15k output = $0.705 total.
- https://claude.com/blog/claude-managed-agents — launch announcement: "Session tracing, integration analytics, and troubleshooting guidance are built directly into the Claude Console."
- https://platform.claude.com/docs/en/managed-agents/memory — Research Preview. 8 stores per session max; individual memory cap 100KB; versioned with `mem_.../memver_...` IDs; `read_write` or `read_only` access; full audit-log via `memory_versions` endpoints.

### Implication for WakeProof

Layer 3 is buildable in the hackathon budget. Plan:

1. One-time setup (Day 2 evening or Day 4 morning): create one Agent + one Environment via CLI.
2. At bedtime each night: iOS app calls `POST /v1/sessions` with the user's memory-store ID (if research-preview granted) or seeds a fresh session with baseline data inline.
3. During sleep: app periodically sends `user.message` events as HealthKit samples arrive (idle time between them is free — this is the key cost-saver).
4. Pre-alarm: iOS app reads session events to pull the prepared briefing.

Cost budget for a 7-night demo window: ≈ 7 × (2 hours actual running × $0.08 + ~$0.50 tokens) = **~$4.50 credit burn** — trivial against the $500 pool. The 60-req/min org-level write limit is not a concern (one session create per night).

Fallbacks if Layer 3 blocks on Day 4:
- **Research Preview access denied for Agent Memory** → use Messages API + client-side Memory Tool, same narrative, no demo loss.
- **Beta onboarding surprises (CLI auth, vault config)** → revert to the `BGProcessingTaskRequest` local-agent-loop fallback per `opus-4-7-strategy.md` line 111. Demo narrative downgrades from "long-horizon agentic" to "scheduled overnight job". Still competent.
- **Unattended 8-hour session reliability unknown** → mitigate by sending a keepalive `user.message` every ~30 min (still well inside idle-time zero cost).

### Open follow-ups

- Hard maximum session duration (beyond the 30-day checkpoint retention) — docs do not state an explicit wall-clock cap on a single session. **Requires Michael Cohen live session 2026-04-23 11 PM HKT** to confirm 8-hour unattended runs are supported.
- Whether Agent Memory research-preview access is granted fast enough for a 5-day sprint (Day 4 deadline).
- Cold-start latency for a new session / container provisioning — not quantified in docs; the demo video pre-alarm pull must be fast, so test this early.
- Branding constraint to note in submission: we can call it "Claude Agent" or "WakeProof powered by Claude" but not "Claude Code Agent".

---

## Summary table

| # | Question | Status | Source of truth |
|---|---|---|---|
| 1 | Memory Tool: read + write during a run? | **answered** | docs (memory-tool page, what's-new-4-7) |
| 1a | File-system semantics (paths, ops, persistence) | **answered** | docs (memory-tool page) |
| 1b | Auto-injection vs explicit | **answered** | docs (memory-tool auto-inserted MEMORY PROTOCOL) |
| 2 | Task budget min/max | **answered** (20k min, no documented max, token-denominated only) | docs (task-budgets page) |
| 2a | Express 8-hour overnight cleanly? | **partial** — not directly; duration lives in Managed Agents session, not task budget | docs + inference |
| 2b | Task budget pricing | **answered** (no extra fee; tokens at standard rates) | docs (pricing page) |
| 3 | Managed Agents hosting | **answered** (Anthropic-hosted containers, not customer infra) | docs (overview + quickstart) |
| 3a | Invocation model | **answered** (REST + SSE stream, not webhooks) | docs (quickstart, events-and-streaming) |
| 3b | Observability / logs | **answered** (Console + event replay + 30-day checkpoint retention) | docs + launch blog |
| 3c | Pricing | **answered** ($0.08/session-hour running + token rates) | docs (pricing page) |
| 3d | Rate limits for $500 hobbyist budget | **answered** (60/600 rpm org-level; not a constraint for 1 user × 7 nights) | docs (overview page) |
| 3e | 8-hour unattended session reliability | **blocked** — no explicit docs ceiling; awaits live session | unresolved |
| 3f | Agent Memory research-preview access latency | **blocked** — access-form gate | unresolved |

Net: Layer 2 is green-lit today. Layer 3 is green-lit with two open risks that the 2026-04-23 Michael Cohen live session should close (max session duration, Agent Memory access). Both have documented fallbacks that preserve the four-layer demo narrative.
