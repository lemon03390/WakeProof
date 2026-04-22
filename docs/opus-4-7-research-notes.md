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

- https://platform.claude.com/docs/en/agents-and-tools/tool-use/memory-tool — "Claude can create, read, update, and delete files that persist between sessions"; "client-side tool, Claude makes tool calls to perform memory operations, and your application executes those operations locally"; six commands documented: `view`, `create`, `str_replace`, `insert`, `delete`, `rename`; tool type `memory_20250818`; auto-injected system prompt "MEMORY PROTOCOL: 1. Use the `view` command of your `memory` tool to check for earlier progress ... ASSUME INTERRUPTION".
- https://platform.claude.com/docs/en/about-claude/models/whats-new-claude-4-7 — "Claude Opus 4.7 is better at writing and using file-system-based memory. ... To give Claude a managed scratchpad without building your own, use the client-side memory tool."
- https://platform.claude.com/docs/en/managed-agents/memory — "Memory stores let the agent carry learnings across sessions"; Research Preview; 8 stores/session max; memories capped at 100KB (~25K tokens); full version history per mutation.

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

- https://platform.claude.com/docs/en/build-with-claude/task-budgets — "Task budgets let you tell Claude how many tokens it has for a full agentic loop, including thinking, tool calls, tool results, and output"; "The minimum accepted `task_budget.total` is **20,000 tokens**; values below the minimum return a 400 error"; schema `{"type": "tokens", "total": N, "remaining": M?}`; "soft hint, not a hard cap"; feature-support table lists Opus 4.7 public beta only (4.6 / Sonnet 4.6 / Haiku 4.5 = Not supported); "Task budgets are not supported on Claude Code or Cowork surfaces at launch."
- https://platform.claude.com/docs/en/about-claude/models/whats-new-claude-4-7 — confirms 20k minimum, advisory semantics; new `xhigh` effort level pairs with task budgets.
- https://platform.claude.com/docs/en/about-claude/pricing — Opus 4.7: $5 / $0.50 cache-read / $25 output per MTok.

### Implication for WakeProof

**Don't model "sleep window" as a budget** — model it as a token envelope. Pattern: (a) open a Managed Agents session at bedtime, (b) send one `user.message` instructing Claude to wait for HealthKit scratchpad updates and produce the morning briefing, (c) let the session idle (free) between periodic pokes. Duration lives in the session. If Layer 3 falls back to a client-side loop (Messages API + BGProcessingTask), then `task_budget: {type: "tokens", total: 128000}` with the beta header becomes the pace-control primitive — decrement `remaining` across calls. Key caveat: task budgets do not apply inside a Managed Agent — rely on `effort` + prompting there.

### Open follow-ups

- Is there a way to hint wall-clock duration to a Managed Agents session (e.g. "pause and wait 30 minutes before next step")? Not documented — **requires Michael Cohen live session 2026-04-23 11 PM HKT** to confirm idiomatic pattern.
- Can `remaining` be negative in practice if Claude overshoots? Behavior undocumented.

---

## Question 3 — Claude Managed Agents (supports Layer 3)

### Answer

**Hosting.** Fully Anthropic-hosted cloud containers (Python/Node/Go pre-installed, configurable networking). No customer infra. Claude API only — not on Bedrock/Vertex/Foundry.

**Invocation.** REST + SDK, not webhooks. Three resources: `agents` (reusable config) → `environments` (container templates) → `sessions` (runs). Flow: `POST /v1/agents` + `POST /v1/environments` once, then per task `POST /v1/sessions`, `POST /v1/sessions/{id}/events` for `user.message` events, and SSE on `/v1/sessions/{id}/stream` for `agent.message` / `agent.thinking` / `agent.tool_use` / `agent.tool_result` / `session.status_*` events. Stream is resumable; events are persisted and retrievable later. Statuses: `idle`, `running`, `rescheduling`, `terminated`.

**Observability.** Session tracing is in the Claude Console ("inspect every tool call, decision, and failure mode"). Events are persisted server-side, listable and fetchable by session ID. Checkpoints (full container state) preserved for **30 days** after last activity; periodic `user.message` events reset that inactivity timer.

**Pricing.** Two-part: standard token rates (Opus 4.7 = $5 / $0.50 cache / $25 per MTok) **plus $0.08 per session-hour of `running` runtime**. Idle / rescheduling / terminated time is free. Web search is the usual $10 per 1,000. Session runtime replaces Code Execution container-hour billing. Batch / fast-mode / data-residency / long-context premiums do **not** apply.

**Rate limits.** Per-org: 60 req/min on create endpoints, 600 req/min on read endpoints. Tier-based token RPM limits layered on top.

**Beta.** `managed-agents-2026-04-01` header on every request. Outcomes, multi-agent, and **Agent Memory stores** are Research Preview (access-gated form).

### Evidence

- https://platform.claude.com/docs/en/managed-agents/overview — "fully managed environment where Claude can read files, run commands, browse the web, and execute code securely"; create endpoints 60 rpm / read endpoints 600 rpm per org; beta header `managed-agents-2026-04-01`.
- https://platform.claude.com/docs/en/managed-agents/sessions — three-tier resource model (agent / environment / session); four statuses (`idle`, `running`, `rescheduling`, `terminated`); "A `running` session cannot be deleted; send an [interrupt event] if you need to delete it immediately."
- https://platform.claude.com/docs/en/managed-agents/events-and-streaming — SSE event stream with typed events; "session history is persisted until deleted, checkpoints are only preserved for 30 days after the session's last activity. ... send periodic `user.message` events to reset the inactivity timer."
- https://platform.claude.com/docs/en/managed-agents/quickstart — full flow: `POST /v1/agents`, `POST /v1/environments`, `POST /v1/sessions`, `POST /v1/sessions/{id}/events`, SSE on `/v1/sessions/{id}/stream`.
- https://platform.claude.com/docs/en/about-claude/pricing — "$0.08 per session-hour"; "Runtime is measured to the millisecond and accrues only while the session's status is `running`. Time spent `idle` ... `rescheduling`, or `terminated` does not count toward runtime"; worked example: 1-hour Opus 4.7 session, 50k input + 15k output = $0.705.
- https://claude.com/blog/claude-managed-agents — "Session tracing, integration analytics, and troubleshooting guidance are built directly into the Claude Console."
- https://platform.claude.com/docs/en/managed-agents/memory — Research Preview; 8 stores/session max; 100KB per-memory cap; `mem_.../memver_...` versioned; `read_write` or `read_only`; full audit via `memory_versions`.

### Implication for WakeProof

Layer 3 is buildable in budget. Plan: (1) create Agent + Environment once via CLI; (2) at bedtime, `POST /v1/sessions` (attach memory store if research-preview granted, else seed inline); (3) during sleep, periodically `POST .../events` as HealthKit samples arrive — idle time is free, the key cost saver; (4) pre-alarm, pull prepared briefing from session events.

7-night demo cost: ~7 × (2 `running` hours × $0.08 + ~$0.50 tokens) = **~$4.50**. Trivial against $500. The 60-req/min write limit is a non-issue at one session-create per night.

Fallbacks: Agent Memory RP denied → client-side Memory Tool, narrative holds. Managed Agents beta onboarding blocks Day 4 → revert to `BGProcessingTaskRequest` local-agent-loop (strategy doc line 111); demo narrative downgrades from "long-horizon agentic" to "scheduled overnight job". 8-hour unattended reliability unknown → send a keepalive `user.message` every ~30 min (idle stays free).

### Open follow-ups

- Hard maximum session duration (beyond the 30-day checkpoint retention) — docs do not state an explicit wall-clock cap on a single session. **Requires Michael Cohen live session 2026-04-23 11 PM HKT** to confirm 8-hour unattended runs are supported.
- Whether Agent Memory research-preview access is granted fast enough for a 5-day sprint (Day 4 deadline).
- Cold-start latency for a new session / container provisioning — not quantified in docs; the demo video pre-alarm pull must be fast, so test this early.
- Branding constraint to note in submission: we can call it "Claude Agent" or "WakeProof powered by Claude" but not "Claude Code Agent".

---

## Summary table

| # | Question | Status | Source |
|---|---|---|---|
| 1 | Memory Tool supports read + write during a run; auto-injected `/memories` file system | answered | docs |
| 2 | Task budget: 20k-token minimum, token-only unit, advisory not hard cap | answered | docs |
| 2a | 8-hour wall-clock expressible cleanly? | partial (no duration field; duration lives in Managed Agents session) | docs + inference |
| 3 | Managed Agents hosting / invocation / observability / pricing / rate limits | answered ($0.08/session-hour running, 60-600 rpm org limit, SSE stream, Console tracing) | docs |
| 3a | 8-hour unattended session reliability / max session duration | blocked | awaits 04-23 session |
| 3b | Agent Memory research-preview access latency | blocked | awaits access form |

Net: Layer 2 is green-lit today. Layer 3 is green-lit with two open risks for the 2026-04-23 Michael Cohen session to close (max session duration, Agent Memory access). Both have documented fallbacks that preserve the four-layer narrative.
