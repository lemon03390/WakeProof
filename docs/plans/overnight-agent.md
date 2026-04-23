# Overnight Agent (Layer 3) Implementation Plan

> **For agentic workers:** Implement task-by-task with the `subagent-driven-development` skill. Steps use checkbox (`- [ ]`). Phase gates are **hard checkpoints** — do NOT advance past a gate that has not passed. This plan carries two integration paths (primary: Claude Managed Agents; fallback: iOS BGProcessingTask + Messages API) with an explicit decision gate in Phase B.

**Goal:** End-of-afternoon Day 4 deliverable per `docs/build-plan.md` Day 4 Layer 3: a session begins at user-configured bedtime, analyzes HealthKit sleep signals and Layer 2 memory through the night, and produces a morning briefing that iOS pulls at alarm time and displays after the VERIFIED verdict. The feature double-targets the **Best use of Claude Managed Agents ($5k)** special prize (`docs/technical-decisions.md` Decision 6) and the **Creative use of Opus 4.7** 25% criterion via the "Claude is working while you sleep" narrative from `docs/opus-4-7-strategy.md` Layer 3.

**Architecture:** Three-phase, carrying both paths side-by-side through Phase A, choosing one in Phase B, and reviewing only the chosen path in Phase C. **Phase A** lands all new files additively for BOTH paths: the Vercel proxy wildcard route that forwards `/v1/*` to Anthropic with the existing `x-wakeproof-token` auth, a `HealthKitSleepReader`, a `MorningBriefing` SwiftData model, a `MorningBriefingView`, and two client implementations — `OvernightAgentClient` (Managed Agents) and a `NightlySynthesisClient` (Messages-API fallback). An `OvernightScheduler` that triggers bedtime sessions and handles BGProcessingTask wake-ups is written against a protocol so either client plugs in. **Phase B** runs the Managed Agents provisioning quickstart behind a hard 2-hour decision gate — if provisioning + a single dry-run session work inside 2h, Phase B.5 onwards integrates the Managed Agents path; if not, Phase B.5 switches to the fallback and the Managed Agents code stays compiled but unwired (preserved for post-hackathon). **Phase C** runs the multi-phase review pipeline on the integrated path.

**Tech Stack:** Swift + SwiftUI (iOS 17+). New `BackgroundTasks` framework for `BGProcessingTaskRequest` (fallback path and keepalive events on primary path). `HealthKit` for sleep + heart-rate reads. `URLSession` REST against the Vercel proxy. `Logger(subsystem: "com.wakeproof.overnight", …)`. SwiftData for the `MorningBriefing` model (additive; no migration). Vercel Serverless Node.js function for the wildcard proxy route. Anthropic API: Managed Agents `managed-agents-2026-04-01` beta header (Tier 4 account access per user confirmation); Opus 4.7 model. No new SPM dependencies. No React Native. No server-side state beyond what the proxy already has (environment variables for credentials; the wildcard route is stateless).

**Non-goals for this plan (deferred):**
- Real-time agent status UI during the night (a "session is running" indicator) — Day 5 polish
- Deep Apple-Watch integration beyond sleep-category reads — post-hackathon
- Multi-night session persistence beyond the 30-day Managed Agents checkpoint window — post-hackathon
- Custom Managed Agent tool definitions beyond the built-in Python environment — post-hackathon
- Bidirectional Memory Tool protocol in the agent (the `memory_20250818` client-side tool) — NOT enabled in Layer 3 per the architecture decision below; the agent uses its Python container's local filesystem for scratch work and reports the updated memory in its final message, which iOS writes back to the `MemoryStore` from Layer 2
- Research-Preview `Agent Memory Stores` — access-gated; not relied on
- Layer 4 weekly coach consumption of the briefing archive — handled in `docs/plans/weekly-coach.md`

---

## Architecture decision — Managed Agents primary, BGProcessingTask fallback

Research notes at `docs/opus-4-7-research-notes.md` Question 3 confirmed Managed Agents is GA on the Claude API for Tier-4 accounts: `managed-agents-2026-04-01` beta header, three-tier resource model (agent → environment → session), `$0.08/session-hour` running + standard token rates, idle time free, 60 rpm on create endpoints, 600 rpm on reads. User confirmed Tier 4 access during planning.

The research also surfaced two risks:

1. **8-hour unattended session reliability — undocumented.** The docs confirm sessions persist for 30 days after last activity and remain resumable. We need to validate they stay healthy through an 8-hour idle-plus-events pattern. The decision gate in Phase B tests this with a **compressed 10-minute "night"** rather than a full 8h — if the compressed run produces a reasonable briefing with multiple user.message events ingested, the architecture works; the difference between 10 min and 8 h is wall-clock idle time, which the research confirms is free and doesn't count toward `running` runtime.

2. **Cold-start latency at wake time — not quantified in docs.** The research suggests we should test early. The primary-path design sends all morning-briefing content as a pre-computed `agent.message` in the session's event list, so iOS just reads the latest agent.message when the alarm fires. No "wake up the agent" round-trip is needed at alarm time.

If Phase B.3's Managed Agents dry-run takes longer than 2 hours to get a first successful session end-to-end, the fallback path replaces the primary integration:

| Primary (Managed Agents) | Fallback (BGProcessingTask + Messages API) |
|---|---|
| Overnight session stays alive; agent ingests sample pokes | iOS BGProcessingTaskRequest wakes periodically, calls Messages API synchronously |
| Final agent.message contains briefing + memory updates | Each BGTask produces an incremental briefing written to SwiftData |
| $0.08/session-hour + ~$0.50/night in tokens | ~$0.02–0.05/night in tokens (2–3 calls) |
| Long-horizon agentic narrative holds | Scheduled-overnight-job narrative; still leverages Opus 4.7 for synthesis |

**Both paths produce the same iOS UI** (a `MorningBriefing` row in SwiftData, rendered by `MorningBriefingView` after VERIFIED). Phase A's file structure ensures the glue (`OvernightScheduler`, `MorningBriefingView`, `MorningBriefing` model) is path-agnostic.

The rejected alternatives in `docs/technical-decisions.md` Decision 6 Step 2 listed "revert to periodic local task" as the fallback. This plan operationalises that fallback as actual code landing in Phase A — it is not hypothetical.

---

## Critical constraints (Day 4, layer 3)

Day 3 is locked. Layer 2 (per `docs/plans/memory-tool.md`) lands earlier on Day 4 and introduces `UserIdentity`, `MemoryStore`, `MemorySnapshot`, `MemoryPromptBuilder`, and an optional `memoryContext` threading through `ClaudeAPIClient.verify(…)`. Layer 3 **reads** the Layer 2 memory on session creation (via `MemoryStore.read()`) and **writes** an update back when the agent emits one. We do NOT add new schema, new permission prompts, or new proxy auth tokens.

- **DO NOT** modify any file in `WakeProof/WakeProof/Verification/` except `MorningBriefingView.swift` (new). `VisionVerifier`, `ClaudeAPIClient`, `VerificationResult`, camera flow stay locked.
- **DO NOT** modify `WakeProof/WakeProof/Alarm/AlarmScheduler.swift` or `AudioSessionKeepalive.swift` or `AlarmSoundEngine.swift`. Layer 3's UI surfaces in the `.verified → .idle` transition via `MorningBriefingView` presented by `WakeProofApp`, without changing the state machine.
- **DO NOT** add new required permissions. HealthKit + background audio are already requested in onboarding; BGProcessingTask does NOT require a user-facing permission, only Info.plist entries. Critical alerts remain unrequested (entitlement path unchanged).
- **DO NOT** bypass the Vercel proxy. The Anthropic key lives in `ANTHROPIC_API_KEY` on Vercel; the iOS client continues to authenticate with `x-wakeproof-token`.
- **DO NOT** break the Vercel proxy's existing `/api/v1/messages.js` route. The wildcard route (`[...path].js`) is added alongside and only matches paths other than `/messages` — Next.js/Vercel resolves the more-specific `messages.js` first, so explicit file stays the fast path. If routing ambiguity surfaces during Task A.1, refactor to put both behind a single `[...path].js` with an `if (path === "messages")` branch, preserving the Day 3 byte-wire behaviour for the messages call.
- **DO NOT** hardcode any Anthropic key anywhere on the iOS side. Only `Secrets.wakeproofToken` (per-install) reaches the binary.
- **DO NOT** run Managed Agents sessions without a `max_tokens` / task budget. Each `POST /v1/sessions` that opens a runaway session can accrue $0.08/hr indefinitely if iOS forgets to terminate. Phase A sets a `task_budget.total = 128000` default; Phase B verifies termination paths.
- **DO NOT** run more than the single dry-run Managed Agents session in Task B.3 without user confirmation. Each session is ~$0.50; five dry runs are $2.50; ten would escalate the $500 credit. Iteration on the agent's prompt requires explicit user greenlight per iteration batch.
- **DO NOT** run `git push`. Local commits only.
- **DO NOT** let BGProcessingTask calls accumulate on one device. Cancel any pending handle before re-submitting. iOS imposes a system-wide budget on background processing; abuse gets our entire app's background-processing privilege revoked.

Phase A is fully additive: new files, new routes, new Info.plist keys, no observable runtime change. Phase B's decision gate is a bounded experiment. Phase C reviews whichever path integrated.

---

## File Structure

New or modified in this plan:

| Path | Action | Responsibility |
|---|---|---|
| `workers/wakeproof-proxy-vercel/api/v1/[...path].js` | Create | Vercel Serverless wildcard route. Matches `/v1/*` paths other than `/v1/messages` (which stays on `messages.js`). Validates `x-wakeproof-token`, reads `ANTHROPIC_API_KEY` + `ANTHROPIC_BETA_HEADER` (env-configurable) from env, forwards the request body unchanged with the upstream auth headers, streams response body back. Preserves `anthropic-version`, `anthropic-beta`, and request-id passthrough headers. 8-second upload cap + 6 MB body cap identical to messages.js. Does NOT attempt SSE — Vercel Hobby 10s hard cap makes SSE-with-long-connection impractical; iOS polls GET `/v1/sessions/:id/events` instead. |
| `workers/wakeproof-proxy-vercel/README.md` | Modify | Add a section documenting the wildcard route, the env vars it reads, and the iOS client expectations (polling vs. SSE). |
| `WakeProof/WakeProof/Services/HealthKitSleepReader.swift` | Create | `actor HealthKitSleepReader`. `async func lastNightSleep() throws -> SleepSnapshot`. Queries `HKCategoryType(.sleepAnalysis)` and `HKQuantityType(.heartRate)` over a bounded window (last 12h). Aggregates into `SleepSnapshot`: total-in-bed, estimated-awake, heart-rate avg / min / max / count, hasAppleWatchData bool. Returns `.empty` if no samples are accessible (user denied or no Apple Watch) — never throws for "no data," only for programmer-error paths (missing identifiers, etc.). |
| `WakeProof/WakeProof/Services/SleepSnapshot.swift` | Create | `struct SleepSnapshot: Codable, Equatable`. Pure value type. Rendered to JSON for posting as a `user.message` event payload; also embedded in fallback synthesize() prompts. |
| `WakeProof/WakeProof/Storage/MorningBriefing.swift` | Create | SwiftData `@Model`. Fields: `generatedAt: Date`, `forWakeDate: Date`, `briefingText: String`, `sourceSessionID: String?` (nil on fallback path; Managed-Agent session id on primary), `sleepSnapshotJSON: String?`, `memoryUpdateApplied: Bool`. Additive — adding this model bumps the `ModelContainer(for:)` call; SwiftData lightweight migration handles it (Day 3 alarm-core Phase A.7 established this pattern). |
| `WakeProof/WakeProof/Services/OvernightAgentClient.swift` | Create | **Primary-path client.** `actor OvernightAgentClient`. Thin wrapper over the Managed Agents REST API: `createAgentAndEnvironmentIfNeeded()`, `startSession(with:)`, `appendEvent(sessionID:message:)`, `fetchLatestAgentMessage(sessionID:)`, `terminateSession(sessionID:)`. Persists the agent-id and environment-id in UserDefaults so they're reused across nights (one-time creation). Uses `Secrets.claudeEndpoint` as the base, Vercel wildcard route forwards. Sets `managed-agents-2026-04-01` beta header. Specific error enum `OvernightAgentError`. |
| `WakeProof/WakeProof/Services/NightlySynthesisClient.swift` | Create | **Fallback-path client.** `struct NightlySynthesisClient` (not an actor — stateless). `async func synthesize(sleepSnapshot:memoryProfile:priorBriefings:) throws -> String`. Calls the existing `/v1/messages` endpoint (no Managed Agents needed). Uses a new `NightlyPromptTemplate.v1` with appropriate system prompt. Returns plain briefing text. Specific error enum `NightlySynthesisError`. |
| `WakeProof/WakeProof/Services/OvernightScheduler.swift` | Create | Orchestrates bedtime + wake. Protocol-based: `protocol OvernightBriefingSource: Actor { func planOvernight(sleep: SleepSnapshot, memoryProfile: String?) async throws -> String; func pokeIfNeeded(handle: String, sleep: SleepSnapshot) async throws -> Bool; func fetchBriefing(handle: String) async throws -> (text: String, memoryUpdate: String?); func cleanup(handle: String) async }`. Two conforming types: `ManagedAgentBriefingSource` (wraps `OvernightAgentClient`) and `SynthesisBriefingSource` (wraps `NightlySynthesisClient`). `OvernightScheduler` accepts a source on init — Phase B.5 picks the concrete type based on the B.3 decision-gate outcome. Exposes `startOvernightSession()`, `handleBackgroundRefresh(_:)`, `finalizeBriefing(forWakeDate:)`. `memoryProfile` argument is `String?` (the raw profile markdown) rather than the full `MemorySnapshot` so Layer 3's protocol does not force a dependency on Layer 2's snapshot type beyond what it actually needs. |
| `WakeProof/WakeProof/Services/NightlyPromptTemplate.swift` | Create | Isolated from `ClaudeAPIClient.VisionPromptTemplate` — a nightly synthesis prompt has a different shape (text output, not JSON; no images). `enum NightlyPromptTemplate { case v1 }`. `systemPrompt()` + `userPrompt(sleep:memory:priorBriefings:)`. |
| `WakeProof/WakeProof/Verification/MorningBriefingView.swift` | Create | SwiftUI view shown immediately after a VERIFIED verdict (`.verifying → .idle` transition), briefly overlaying the home view. Large "Good morning" greeting + date, the briefing text in a readable block, "Start your day" dismiss button. Dismiss animates back to `AlarmSchedulerView`. If no briefing is available (fallback never ran, network failed), view displays a graceful fallback card ("No briefing this morning — sleep well tonight!") so the UI never dead-ends. |
| `WakeProof/WakeProof/Onboarding/BedtimeStep.swift` | Create | New onboarding step: after baseline photo, ask the user to set a bedtime (DatePicker, default 23:00). Persists via `WakeWindow` extension or a separate `UserDefaults` key. Skippable with default. Framed as "When do you plan to sleep? Claude will prepare your morning briefing while you sleep." Optional step in onboarding flow; existing users land on defaults. |
| `WakeProof/WakeProof/Alarm/BedtimeSettings.swift` | Create | `struct BedtimeSettings: Codable, Equatable`. Fields: `hour: Int`, `minute: Int`, `isEnabled: Bool`. Same `UserDefaults`-backed pattern as `WakeWindow`. Separate from `WakeWindow` because bedtime is a different concept (the wake window is the alarm morning; bedtime is the evening-before). |
| `WakeProof/WakeProof/App/WakeProofApp.swift` | Modify (surgical) | Instantiate `OvernightScheduler` with the source that was committed to in Phase B.5. Register BGProcessingTask identifiers during bootstrap. Observe `scheduler.phase` for `(verifying, idle)` transition and show `MorningBriefingView`. |
| `WakeProof/Info.plist` | Modify | Add `BGTaskSchedulerPermittedIdentifiers` array with `com.wakeproof.overnight.refresh`. Add `processing` to existing `UIBackgroundModes` array. |
| `WakeProof/WakeProof/Alarm/AlarmSchedulerView.swift` | Modify (additive UI) | Add a "Bedtime" section surfacing `BedtimeSettings`. Toggle + DatePicker. Writes via `BedtimeSettings.save()`. Does not touch alarm-scheduling code — purely a settings panel addition. |
| `WakeProof/WakeProofTests/HealthKitSleepReaderTests.swift` | Create | Tests with a stubbed `HKHealthStore` (via a protocol) — never hits the real HealthKit. Coverage: empty-sample set returns `.empty`; mixed sleep-analysis categories aggregate correctly; HR samples outside window are excluded; total-in-bed math matches a hand-computed expectation. |
| `WakeProof/WakeProofTests/SleepSnapshotTests.swift` | Create | Codable round-trip + equality + empty construction. |
| `WakeProof/WakeProofTests/OvernightAgentClientTests.swift` | Create | `URLProtocol`-stubbed tests: POST /v1/agents returns 201 → id persisted; a 409 conflict on retry is handled as idempotent; POST /v1/sessions returns a session id; appendEvent posts to the right path; fetchLatestAgentMessage handles empty event list; terminateSession sends the right PATCH. |
| `WakeProof/WakeProofTests/NightlySynthesisClientTests.swift` | Create | `URLProtocol`-stubbed: happy path returns text; 4xx → classified error; timeout → classified; empty response → error. |
| `WakeProof/WakeProofTests/OvernightSchedulerTests.swift` | Create | Tests with a fake `OvernightBriefingSource`: `planOvernight` is called once per bedtime trigger; `handleBGProcessingTask` returns true on successful re-schedule; `fetchLatestBriefing` returns the freshest row from SwiftData; `scheduleBedtime` doesn't schedule duplicates. |
| `WakeProof/WakeProofTests/MorningBriefingTests.swift` | Create | SwiftData insertion test (in-memory container) — mirrors the Day 3 `WakeAttempt` pattern. |
| `WakeProof/WakeProofTests/BedtimeSettingsTests.swift` | Create | `UserDefaults` round-trip tests, enabled/disabled transitions. |
| `WakeProof/WakeProofTests/NightlyPromptTemplateTests.swift` | Create | Prompt-string tests: v1 systemPrompt mentions memory; userPrompt renders the SleepSnapshot + memory; no-memory case renders a bounded prompt. |
| `docs/managed-agents-setup.md` | Create | Step-by-step setup guide for the agent + environment + beta header. Mirrors `docs/go-no-go-audio-test.md` pattern. Includes the `curl` dry-run Task B.3 uses. |
| `docs/nightly-prompt.md` | Create | Versioned nightly-synthesis prompt (fallback-path). Mirrors `docs/vision-prompt.md`. |
| `docs/plans/overnight-agent.md` | Create | This file. |

---

## Phase A — Additive infrastructure (zero runtime integration)

**Goal of phase:** Land every new file for both integration paths plus all supporting iOS services (HealthKit reader, BGProcessingTask scaffolding, briefing UI). All code compiles against the simulator. No runtime behaviour changes — Phase A ends with a build that still does exactly what Day 3 + Layer 2 do on-device.

### Task A.0: Plan lands in repo

**Files:**
- Create: `docs/plans/overnight-agent.md` (this document)

**Dependencies:** none

- [ ] **Step 1: Verify the file is present.**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon/ status docs/plans/overnight-agent.md
```

- [ ] **Step 2: Commit.**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon/ add docs/plans/overnight-agent.md
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon/ commit -m "Overnight Phase A.0: land the overnight-agent implementation plan document"
```

### Task A.1: Vercel wildcard proxy route

**Files:**
- Create: `workers/wakeproof-proxy-vercel/api/v1/[...path].js`
- Modify: `workers/wakeproof-proxy-vercel/README.md` (append wildcard-route section)

**Dependencies:** Task A.0

**Important context:** The Day 3 proxy exposes only `/v1/messages`. Managed Agents uses `/v1/agents`, `/v1/environments`, `/v1/sessions`, `/v1/sessions/:id/events`. A single `[...path].js` wildcard handler forwards anything we don't already have an explicit route for — this matches the Anthropic API surface one-to-one. The `messages.js` file stays as-is and wins route resolution by being more specific.

Vercel's catch-all convention: a file at `api/v1/[...path].js` matches anything under `/api/v1/` that doesn't match a more-specific file. The `path` parameter in `req.query` is an array of path segments (e.g., `["sessions", "abc123", "events"]`).

The wildcard route must NOT attempt SSE streaming — Vercel Hobby 10s cap makes it impractical for overnight sessions. iOS polls `GET /v1/sessions/:id/events` at alarm time; during the night, BGProcessingTask-driven `POST` events are fire-and-forget.

- [ ] **Step 1: Create `[...path].js`.**

```javascript
// WakeProof Claude Proxy — Vercel Serverless Function, Managed Agents + Memory Stores passthrough
//
// Wildcard route for `/api/v1/*` paths other than `/v1/messages` (which has its
// own dedicated messages.js). Forwards the request body and method through to
// `https://api.anthropic.com/v1/<path>` preserving anthropic-version and
// anthropic-beta headers.
//
// Auth model identical to messages.js: validate `x-wakeproof-token` against
// WAKEPROOF_CLIENT_TOKEN env; inject `x-api-key` from ANTHROPIC_API_KEY env.
// The Anthropic credential never leaves Vercel.
//
// No SSE / streaming on this route — Vercel Hobby's 10s function cap makes
// long-lived connections impractical. iOS polls GET on session events at wake
// time and uses BGProcessingTask-driven POSTs during the night, each of which
// completes well under the 10s budget.

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

  // Reconstruct the path from Vercel's path-array. `req.query.path` is an array
  // of segments (e.g., ["sessions", "abc123", "events"]); prepend "v1" because
  // this file lives under /api/v1/.
  const segments = Array.isArray(req.query.path) ? req.query.path : [req.query.path].filter(Boolean);
  if (segments.length === 0) {
    res.status(404).json({ error: { type: 'not_found', message: 'No path specified' } });
    return;
  }
  const upstreamPath = `v1/${segments.join('/')}`;

  // Do not re-implement the /messages route. If anyone hits this wildcard with
  // a messages-shaped path we should fail closed — the dedicated file would
  // have already handled it in normal routing.
  if (segments[0] === 'messages') {
    res.status(404).json({
      error: { type: 'route_conflict', message: 'messages is served by /api/v1/messages, not the wildcard' },
    });
    return;
  }

  const method = req.method || 'GET';
  const anthropicVersion = req.headers['anthropic-version'] || '2023-06-01';
  const anthropicBeta = req.headers['anthropic-beta']; // e.g. "managed-agents-2026-04-01"

  // Read the request body for methods that carry one. 8s upload cap + 6MB
  // body cap match messages.js. GET / DELETE skip.
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
```

- [ ] **Step 2: Update the proxy README.**

In `workers/wakeproof-proxy-vercel/README.md`, append after the existing `/v1/messages` section:

```markdown
## `/v1/*` wildcard route (Layer 3)

Added 2026-04-24 to support Claude Managed Agents (`/v1/agents`, `/v1/environments`, `/v1/sessions`, `/v1/sessions/:id/events`) without one explicit route per endpoint.

File: `api/v1/[...path].js`. Matches any `/v1/*` path not served by a more-specific file (so `/v1/messages` stays routed to `messages.js`).

Auth model identical to messages: `x-wakeproof-token` against `WAKEPROOF_CLIENT_TOKEN` env.
Upstream auth injected from `ANTHROPIC_API_KEY` env.
Forwards `anthropic-version` (default `2023-06-01`) and `anthropic-beta` (e.g., `managed-agents-2026-04-01`) headers through.

No SSE. 8s upload cap + 6MB body cap. iOS polls GET session events at wake; night-time event POSTs complete within the Vercel 10s budget.
```

- [ ] **Step 3: Deploy (USER CONFIRMATION REQUIRED).** Announce to the user: *"Deploying the Vercel wildcard route — preview deployment, doesn't touch production /v1/messages behaviour. Proceed?"* Wait for yes. Then:

```bash
cd /Users/mountainfung/Desktop/WakeProof-Hackathon/workers/wakeproof-proxy-vercel && \
  vercel --prod 2>&1 | tail -30
```

Expected: `Production: https://wakeproof-proxy-vercel.vercel.app` URL confirmed. Note that `vercel --prod` is used even though this is our first wildcard deploy — there is no non-prod staging on Vercel Hobby, and the `/v1/messages` route is unchanged.

- [ ] **Step 4: Smoke-test the wildcard route with curl.** The goal of this step is narrow: prove the Vercel proxy accepts our client token, injects the Anthropic key, and forwards the request to `api.anthropic.com` with a well-formed response header flow. We are NOT testing Anthropic's product surface — we don't need a specific endpoint to exist.

```bash
curl -sS -X GET \
  -H "x-wakeproof-token: $(cat /tmp/wakeproof-client-token)" \
  -D - \
  https://wakeproof-proxy-vercel.vercel.app/v1/models 2>&1 | head -40
```

(Write your proxy token to `/tmp/wakeproof-client-token` out-of-band before running — NEVER paste it into this plan or a commit. After the test, `rm /tmp/wakeproof-client-token`.)

**Pass criteria (any of these proves the proxy forwarded):**
- Any `HTTP/...` status line (2xx OR 4xx).
- The response includes our proxy's `x-wakeproof-worker: vercel-serverless-wildcard-v1` header (added at line 112 of the wildcard handler).
- The response includes `x-wakeproof-upstream-status: <N>` — this is our proxy echoing Anthropic's status back.

**Failure signals (these mean the proxy isn't doing its job):**
- `401 {"error":"unauthorized"}` *from the proxy itself* (body missing `x-wakeproof-worker` header) → `WAKEPROOF_CLIENT_TOKEN` mismatch on Vercel.
- `500 {"error":{"type":"proxy_not_configured"}}` → env vars unset.
- `502 {"error":{"type":"upstream_fetch_failed"}}` → proxy running but can't reach Anthropic.
- The `x-wakeproof-worker` header is absent → Vercel routed to the wrong file (likely a route-resolution bug; re-check `[...path].js` placement and redeploy).

If Anthropic returns a 404 (e.g., because `/v1/models` isn't a documented endpoint on their side), **the smoke test still passes** as long as the `x-wakeproof-worker` header is present — that proves our proxy forwarded. The point is proxy plumbing, not Anthropic endpoint discovery.

- [ ] **Step 5: Commit the route file + README update.**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon/ add \
  workers/wakeproof-proxy-vercel/api/v1/\[...path\].js \
  workers/wakeproof-proxy-vercel/README.md
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon/ commit -m "Overnight Phase A.1: Vercel wildcard proxy route for /v1/* (Managed Agents endpoints) with same auth as messages.js"
```

### Task A.2: SleepSnapshot value type

**Files:**
- Create: `WakeProof/WakeProof/Services/SleepSnapshot.swift`
- Create: `WakeProof/WakeProofTests/SleepSnapshotTests.swift`

**Dependencies:** Task A.1

- [ ] **Step 1: Create `SleepSnapshot.swift`.**

```swift
//
//  SleepSnapshot.swift
//  WakeProof
//
//  Snapshot of last night's HealthKit-derived sleep + heart-rate signals. Rendered
//  as JSON into the agent's session event payload (primary) or inlined into the
//  nightly synthesis prompt (fallback). Empty on devices without Apple Watch data
//  or when the user denied HealthKit read access — the agent's prompt handles
//  that gracefully ("sleep data unavailable tonight").
//

import Foundation

struct SleepSnapshot: Codable, Equatable {

    /// Total minutes recorded as in-bed (HKCategoryValueSleepAnalysis.inBed, asleep*, etc.).
    let totalInBedMinutes: Int

    /// Minutes recorded as awake during the window (HKCategoryValueSleepAnalysis.awake).
    let awakeMinutes: Int

    /// Resting / daytime heart-rate samples in the window.
    let heartRateAvg: Double?
    let heartRateMin: Double?
    let heartRateMax: Double?
    let heartRateSampleCount: Int

    /// True when at least one sleep-category sample came from an Apple Watch source.
    /// iPhone-only (accelerometer-based) sleep records still populate the numbers but
    /// flag this as false so the agent's prompt can soften certainty.
    let hasAppleWatchData: Bool

    /// Window-start ISO 8601 for display and debugging.
    let windowStart: Date
    let windowEnd: Date

    static let empty = SleepSnapshot(
        totalInBedMinutes: 0,
        awakeMinutes: 0,
        heartRateAvg: nil,
        heartRateMin: nil,
        heartRateMax: nil,
        heartRateSampleCount: 0,
        hasAppleWatchData: false,
        windowStart: Date(timeIntervalSince1970: 0),
        windowEnd: Date(timeIntervalSince1970: 0)
    )

    var isEmpty: Bool {
        totalInBedMinutes == 0 && heartRateSampleCount == 0
    }
}
```

- [ ] **Step 2: Create `SleepSnapshotTests.swift`.**

```swift
//
//  SleepSnapshotTests.swift
//  WakeProofTests
//

import XCTest
@testable import WakeProof

final class SleepSnapshotTests: XCTestCase {

    func testEmptyIsEmpty() {
        XCTAssertTrue(SleepSnapshot.empty.isEmpty)
    }

    func testPopulatedIsNotEmpty() {
        let snapshot = SleepSnapshot(
            totalInBedMinutes: 420,
            awakeMinutes: 30,
            heartRateAvg: 58, heartRateMin: 48, heartRateMax: 75,
            heartRateSampleCount: 128, hasAppleWatchData: true,
            windowStart: Date(timeIntervalSince1970: 1_745_400_000),
            windowEnd: Date(timeIntervalSince1970: 1_745_425_200)
        )
        XCTAssertFalse(snapshot.isEmpty)
    }

    func testRoundTrip() throws {
        let original = SleepSnapshot(
            totalInBedMinutes: 420, awakeMinutes: 30,
            heartRateAvg: 58.2, heartRateMin: 48, heartRateMax: 75,
            heartRateSampleCount: 128, hasAppleWatchData: true,
            windowStart: Date(timeIntervalSince1970: 1_745_400_000),
            windowEnd: Date(timeIntervalSince1970: 1_745_425_200)
        )
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(original)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let roundtripped = try dec.decode(SleepSnapshot.self, from: data)
        XCTAssertEqual(original, roundtripped)
    }

    func testOptionalHeartRateNilsSurvive() throws {
        let snapshot = SleepSnapshot(
            totalInBedMinutes: 60, awakeMinutes: 10,
            heartRateAvg: nil, heartRateMin: nil, heartRateMax: nil,
            heartRateSampleCount: 0, hasAppleWatchData: false,
            windowStart: Date(timeIntervalSince1970: 0),
            windowEnd: Date(timeIntervalSince1970: 0)
        )
        let enc = JSONEncoder()
        let data = try enc.encode(snapshot)
        let dec = JSONDecoder()
        let roundtripped = try dec.decode(SleepSnapshot.self, from: data)
        XCTAssertEqual(snapshot, roundtripped)
    }
}
```

- [ ] **Step 3: Simulator build + run tests.**

```bash
xcodebuild -project /Users/mountainfung/Desktop/WakeProof-Hackathon/WakeProof/WakeProof.xcodeproj \
  -scheme WakeProof -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  test -only-testing:WakeProofTests/SleepSnapshotTests 2>&1 | tail -40
```

Expected: 4 tests pass.

- [ ] **Step 4: Commit.**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon/ add WakeProof/WakeProof/Services/SleepSnapshot.swift WakeProof/WakeProofTests/SleepSnapshotTests.swift
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon/ commit -m "Overnight Phase A.2: SleepSnapshot value type (Codable, empty/populated invariants) + tests"
```

### Task A.3: HealthKitSleepReader

**Files:**
- Create: `WakeProof/WakeProof/Services/HealthKitSleepReader.swift`
- Create: `WakeProof/WakeProofTests/HealthKitSleepReaderTests.swift`

**Dependencies:** Task A.2

**Important context:** HealthKit queries are async but not actor-safe. The reader is an `actor` so all internal state (the HKHealthStore, cached identifiers) is isolated. Testing HealthKit without a device is non-trivial: the path we cover in tests is the aggregation logic, with a stubbed "sample source" that feeds known `HKCategorySample` / `HKQuantitySample` arrays. The actual `HKHealthStore` queries are exercised on-device in Phase B.6.

We read a bounded window — default 12 hours back from `Date.now`. Running at wake time, that's the user's last sleep period. Running overnight via BGProcessingTask, that's "from the moment the user went to bed" through "now" — slightly fuzzier but still useful for incremental update events.

- [ ] **Step 1: Create `HealthKitSleepReader.swift`.**

```swift
//
//  HealthKitSleepReader.swift
//  WakeProof
//
//  Reads last night's sleep + heart-rate signals from HealthKit. Returns a
//  SleepSnapshot the overnight agent can ingest as JSON. Never throws for the
//  "no data / permission denied" path — returns SleepSnapshot.empty. Throws only
//  for programmer-error cases (identifiers absent on this iOS version).
//
//  Actor so HKHealthStore access and any shared caches stay serialised.
//

import Foundation
import HealthKit
import os

actor HealthKitSleepReader {

    enum ReaderError: LocalizedError {
        case healthKitUnavailable
        case identifierUnresolvable(String)

        var errorDescription: String? {
            switch self {
            case .healthKitUnavailable:
                return "HealthKit is not available on this device."
            case .identifierUnresolvable(let id):
                return "HealthKit identifier \(id) is not known on this iOS version."
            }
        }
    }

    private let healthStore: HKHealthStore
    private let logger = Logger(subsystem: "com.wakeproof.overnight", category: "healthkit")

    init(healthStore: HKHealthStore = HKHealthStore()) {
        self.healthStore = healthStore
    }

    /// Read last-N-hours sleep + HR data. Default window 12 h back.
    func lastNightSleep(windowHours: Int = 12) async throws -> SleepSnapshot {
        guard HKHealthStore.isHealthDataAvailable() else {
            logger.info("HealthKit unavailable on this device; returning empty snapshot")
            return .empty
        }

        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            throw ReaderError.identifierUnresolvable("sleepAnalysis")
        }
        guard let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate) else {
            throw ReaderError.identifierUnresolvable("heartRate")
        }

        let end = Date.now
        let start = end.addingTimeInterval(-Double(windowHours) * 3600)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictEndDate)

        let sleepSamples: [HKCategorySample] = (try? await querySamples(type: sleepType, predicate: predicate)) ?? []
        let hrSamples: [HKQuantitySample] = (try? await queryQuantities(type: heartRateType, predicate: predicate)) ?? []

        return aggregate(sleepSamples: sleepSamples, hrSamples: hrSamples, windowStart: start, windowEnd: end)
    }

    /// Pure aggregation. Exposed `internal` so tests can drive it with synthetic samples
    /// — the underlying HKHealthStore query is hard to stub without a bigger harness.
    nonisolated func aggregate(
        sleepSamples: [HKCategorySample],
        hrSamples: [HKQuantitySample],
        windowStart: Date,
        windowEnd: Date
    ) -> SleepSnapshot {
        let (inBed, awake) = Self.summariseSleepCategory(samples: sleepSamples)

        var avg: Double? = nil
        var min: Double? = nil
        var max: Double? = nil
        if !hrSamples.isEmpty {
            let bpmUnit = HKUnit.count().unitDivided(by: .minute())
            let values = hrSamples.map { $0.quantity.doubleValue(for: bpmUnit) }
            let total = values.reduce(0, +)
            avg = total / Double(values.count)
            min = values.min()
            max = values.max()
        }

        let hasAW = sleepSamples.contains { sample in
            sample.sourceRevision.productType?.contains("Watch") ?? false
        }

        return SleepSnapshot(
            totalInBedMinutes: inBed,
            awakeMinutes: awake,
            heartRateAvg: avg,
            heartRateMin: min,
            heartRateMax: max,
            heartRateSampleCount: hrSamples.count,
            hasAppleWatchData: hasAW,
            windowStart: windowStart,
            windowEnd: windowEnd
        )
    }

    // MARK: - Private

    private func querySamples(type: HKCategoryType, predicate: NSPredicate) async throws -> [HKCategorySample] {
        try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, results, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: (results as? [HKCategorySample]) ?? [])
            }
            healthStore.execute(q)
        }
    }

    private func queryQuantities(type: HKQuantityType, predicate: NSPredicate) async throws -> [HKQuantitySample] {
        try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, results, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: (results as? [HKQuantitySample]) ?? [])
            }
            healthStore.execute(q)
        }
    }

    private static func summariseSleepCategory(samples: [HKCategorySample]) -> (inBedMinutes: Int, awakeMinutes: Int) {
        var inBed = 0.0
        var awake = 0.0
        for sample in samples {
            let minutes = sample.endDate.timeIntervalSince(sample.startDate) / 60.0
            // HKCategoryValueSleepAnalysis raw values: inBed=0, asleep*=1-4 (iOS 16+), awake=5 (iOS 16+).
            // We pool "inBed" + all "asleep*" into inBed; "awake" stays awake.
            switch sample.value {
            case HKCategoryValueSleepAnalysis.inBed.rawValue,
                 HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                 HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                 HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                 HKCategoryValueSleepAnalysis.asleepREM.rawValue:
                inBed += minutes
            case HKCategoryValueSleepAnalysis.awake.rawValue:
                awake += minutes
            default:
                break
            }
        }
        return (Int(inBed.rounded()), Int(awake.rounded()))
    }
}
```

- [ ] **Step 2: Create `HealthKitSleepReaderTests.swift`.**

Since we can't easily instantiate `HKCategorySample` / `HKQuantitySample` with full mocks in a unit test (their initializers require HKHealthStore auth), target the **pure aggregate()** path and exercise it with synthetic samples via a minimal builder.

```swift
//
//  HealthKitSleepReaderTests.swift
//  WakeProofTests
//

import HealthKit
import XCTest
@testable import WakeProof

/// We can't reasonably synthesise HKCategorySample / HKQuantitySample without an
/// authenticated HKHealthStore, so these tests exercise `aggregate` with real
/// HealthKit value types wherever the test simulator allows it, and skip the
/// portions that require authorised stores. The device-side sanity test in Phase
/// B.6 validates the full integration path end-to-end.

final class HealthKitSleepReaderTests: XCTestCase {

    func testAggregateWithNoSamplesReturnsEmpty() {
        let reader = HealthKitSleepReader()
        let snapshot = reader.aggregate(
            sleepSamples: [],
            hrSamples: [],
            windowStart: Date(timeIntervalSince1970: 0),
            windowEnd: Date(timeIntervalSince1970: 0)
        )
        XCTAssertEqual(snapshot.totalInBedMinutes, 0)
        XCTAssertEqual(snapshot.awakeMinutes, 0)
        XCTAssertEqual(snapshot.heartRateSampleCount, 0)
        XCTAssertNil(snapshot.heartRateAvg)
    }

    func testWindowFieldsArePreserved() {
        let reader = HealthKitSleepReader()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let end = Date(timeIntervalSince1970: 1_050_000)
        let snapshot = reader.aggregate(
            sleepSamples: [], hrSamples: [],
            windowStart: start, windowEnd: end
        )
        XCTAssertEqual(snapshot.windowStart, start)
        XCTAssertEqual(snapshot.windowEnd, end)
    }

    func testEmptyInBedMinutesIsZero() {
        let reader = HealthKitSleepReader()
        let snap = reader.aggregate(sleepSamples: [], hrSamples: [],
                                    windowStart: .now, windowEnd: .now)
        XCTAssertTrue(snap.isEmpty)
    }
}
```

The aggregation correctness on real `HKCategorySample`/`HKQuantitySample` data is covered in Phase B.6 device run; unit tests keep the deterministic paths tight. If future development wants stronger coverage, extract `summariseSleepCategory` / HR aggregation to pure funcs taking value tuples rather than sample types — a Day 5 refactor.

- [ ] **Step 3: Simulator build + run tests.**

```bash
xcodebuild -project /Users/mountainfung/Desktop/WakeProof-Hackathon/WakeProof/WakeProof.xcodeproj \
  -scheme WakeProof -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  test -only-testing:WakeProofTests/HealthKitSleepReaderTests 2>&1 | tail -40
```

Expected: 3 tests pass.

- [ ] **Step 4: Commit.**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon/ add \
  WakeProof/WakeProof/Services/HealthKitSleepReader.swift \
  WakeProof/WakeProofTests/HealthKitSleepReaderTests.swift
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon/ commit -m "Overnight Phase A.3: HealthKitSleepReader (sleep category + HR aggregation) + unit tests for aggregate fn"
```

### Task A.4: MorningBriefing SwiftData model

**Files:**
- Create: `WakeProof/WakeProof/Storage/MorningBriefing.swift`
- Create: `WakeProof/WakeProofTests/MorningBriefingTests.swift`
- Modify: `WakeProof/WakeProof/App/WakeProofApp.swift` (add `MorningBriefing.self` to `ModelContainer(for:)`)

**Dependencies:** Task A.3

**Important context:** Adding a new `@Model` class means adding it to the `ModelContainer(for: BaselinePhoto.self, WakeAttempt.self)` call — that's a SwiftData schema mutation. SwiftData handles lightweight migrations (adding a new model is treated as additive; `@Attribute` with default or optional values is tolerated). This is the same pattern alarm-core.md Day 2 used for `WakeAttempt` additive extensions. No migration script needed.

- [ ] **Step 1: Create `MorningBriefing.swift`.**

```swift
//
//  MorningBriefing.swift
//  WakeProof
//
//  Per-night briefing produced by the overnight agent (primary path) or the
//  nightly synthesis call (fallback path). Cached locally so the alarm UI does
//  not depend on live agent availability — at wake time, MorningBriefingView
//  queries the latest row for today's wake date and renders offline.
//

import Foundation
import SwiftData

@Model
final class MorningBriefing {
    var generatedAt: Date
    var forWakeDate: Date
    var briefingText: String

    /// Populated on the Managed Agents path with the session id. Nil on fallback.
    var sourceSessionID: String?

    /// JSON representation of the SleepSnapshot at generation time. Kept for
    /// Layer 4's weekly-coach consumption and for debugging.
    var sleepSnapshotJSON: String?

    /// Whether the briefing's memory_update (if any) has been applied to MemoryStore.
    /// Default false; flipped to true by the applying code path.
    var memoryUpdateApplied: Bool

    init(
        generatedAt: Date = .now,
        forWakeDate: Date,
        briefingText: String,
        sourceSessionID: String? = nil,
        sleepSnapshotJSON: String? = nil,
        memoryUpdateApplied: Bool = false
    ) {
        self.generatedAt = generatedAt
        self.forWakeDate = forWakeDate
        self.briefingText = briefingText
        self.sourceSessionID = sourceSessionID
        self.sleepSnapshotJSON = sleepSnapshotJSON
        self.memoryUpdateApplied = memoryUpdateApplied
    }
}
```

- [ ] **Step 2: Add `MorningBriefing.self` to the ModelContainer**. In `WakeProofApp.swift` init:

```swift
            modelContainer = try ModelContainer(
                for: BaselinePhoto.self, WakeAttempt.self, MorningBriefing.self
            )
```

- [ ] **Step 3: Create `MorningBriefingTests.swift`.**

```swift
//
//  MorningBriefingTests.swift
//  WakeProofTests
//

import SwiftData
import XCTest
@testable import WakeProof

final class MorningBriefingTests: XCTestCase {

    private var container: ModelContainer!

    override func setUpWithError() throws {
        let schema = Schema([MorningBriefing.self])
        let config = ModelConfiguration("briefing-tests", schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [config])
    }

    override func tearDownWithError() throws {
        container = nil
    }

    func testInsertAndFetch() throws {
        let context = ModelContext(container)
        let briefing = MorningBriefing(
            forWakeDate: Date(timeIntervalSince1970: 1_745_500_000),
            briefingText: "Today's insight: sleep was consistent.",
            sourceSessionID: "sess_abc",
            sleepSnapshotJSON: "{\"totalInBedMinutes\":420}"
        )
        context.insert(briefing)
        try context.save()
        let fetched = try context.fetch(FetchDescriptor<MorningBriefing>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.briefingText, "Today's insight: sleep was consistent.")
        XCTAssertEqual(fetched.first?.sourceSessionID, "sess_abc")
    }

    func testDefaultsAreSane() {
        let briefing = MorningBriefing(forWakeDate: .now, briefingText: "hi")
        XCTAssertFalse(briefing.memoryUpdateApplied)
        XCTAssertNil(briefing.sourceSessionID)
        XCTAssertNil(briefing.sleepSnapshotJSON)
    }

    func testSortByGeneratedAtIsReasonable() throws {
        let context = ModelContext(container)
        for i in 0..<5 {
            context.insert(MorningBriefing(
                generatedAt: Date(timeIntervalSince1970: 1_745_500_000 + TimeInterval(i * 60)),
                forWakeDate: Date(timeIntervalSince1970: 1_745_500_000),
                briefingText: "briefing-\(i)"
            ))
        }
        try context.save()
        let descriptor = FetchDescriptor<MorningBriefing>(sortBy: [SortDescriptor(\.generatedAt, order: .reverse)])
        let fetched = try context.fetch(descriptor)
        XCTAssertEqual(fetched.first?.briefingText, "briefing-4")
        XCTAssertEqual(fetched.last?.briefingText, "briefing-0")
    }
}
```

- [ ] **Step 4: Simulator build + run tests.**

```bash
xcodebuild -project /Users/mountainfung/Desktop/WakeProof-Hackathon/WakeProof/WakeProof.xcodeproj \
  -scheme WakeProof -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  test -only-testing:WakeProofTests/MorningBriefingTests 2>&1 | tail -40
```

Expected: 3 tests pass; no schema migration errors on the existing BaselinePhoto/WakeAttempt store.

- [ ] **Step 5: Commit.**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon/ add \
  WakeProof/WakeProof/Storage/MorningBriefing.swift \
  WakeProof/WakeProofTests/MorningBriefingTests.swift \
  WakeProof/WakeProof/App/WakeProofApp.swift
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon/ commit -m "Overnight Phase A.4: MorningBriefing SwiftData model (+ ModelContainer registration) with insert/sort tests"
```

### Task A.5: BedtimeSettings + onboarding step

**Files:**
- Create: `WakeProof/WakeProof/Alarm/BedtimeSettings.swift`
- Create: `WakeProof/WakeProof/Onboarding/BedtimeStep.swift`
- Create: `WakeProof/WakeProofTests/BedtimeSettingsTests.swift`

**Dependencies:** Task A.4

**Important context:** Bedtime is the time at which the overnight session opens. Default 23:00; user-adjustable via the new onboarding step (and later via the scheduler view's settings panel — Phase B.4). Stored in UserDefaults under `com.wakeproof.alarm.bedtimeSettings`, mirroring `WakeWindow`'s pattern.

- [ ] **Step 1: Create `BedtimeSettings.swift`.**

```swift
//
//  BedtimeSettings.swift
//  WakeProof
//
//  When the overnight agent session is kicked off. Separate from WakeWindow
//  because bedtime is the evening-before event, not part of the alarm morning.
//

import Foundation

struct BedtimeSettings: Codable, Equatable {
    var hour: Int
    var minute: Int
    var isEnabled: Bool

    static let defaultSettings = BedtimeSettings(hour: 23, minute: 0, isEnabled: false)

    private static let key = "com.wakeproof.alarm.bedtimeSettings"

    static func load(from defaults: UserDefaults = .standard) -> BedtimeSettings {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(BedtimeSettings.self, from: data) else {
            return .defaultSettings
        }
        return decoded
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.key)
        }
    }

    /// Next bedtime in the future relative to `reference`. If the time has already
    /// passed today, returns tomorrow's bedtime at the same clock time.
    func nextBedtime(after reference: Date = .now, calendar: Calendar = .current) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: reference)
        components.hour = hour
        components.minute = minute
        guard let today = calendar.date(from: components) else { return nil }
        return today > reference ? today : calendar.date(byAdding: .day, value: 1, to: today)
    }
}
```

- [ ] **Step 2: Create `BedtimeStep.swift` (onboarding sub-view).**

```swift
//
//  BedtimeStep.swift
//  WakeProof
//
//  New onboarding step (between .motion and .baseline) that asks the user
//  when they plan to sleep. Skippable; the overnight-agent feature works
//  with the default 23:00 bedtime and can be revisited in Settings later.
//

import SwiftUI

struct BedtimeStep: View {
    let onAdvance: () -> Void

    @State private var settings: BedtimeSettings = BedtimeSettings.load()
    @State private var isEnabled: Bool = BedtimeSettings.load().isEnabled

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Text("When do you sleep?")
                .font(.system(size: 34, weight: .bold))
                .multilineTextAlignment(.center)
            Text("Claude will prepare your morning briefing overnight — analyzing sleep patterns and adjusting for what it has learned about your wake-ups. Skip if you'd rather not.")
                .font(.body)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
            Spacer()

            Toggle(isOn: $isEnabled) { Text("Turn on overnight briefings") }
                .foregroundStyle(.white)
                .tint(.white)

            if isEnabled {
                DatePicker(
                    "Bedtime",
                    selection: Binding<Date>(
                        get: {
                            Calendar.current.date(from: DateComponents(hour: settings.hour, minute: settings.minute)) ?? .now
                        },
                        set: { date in
                            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                            settings.hour = c.hour ?? 23
                            settings.minute = c.minute ?? 0
                        }
                    ),
                    displayedComponents: .hourAndMinute
                )
                .foregroundStyle(.white)
                .tint(.white)
            }

            VStack(spacing: 12) {
                Button("Save & continue") {
                    settings.isEnabled = isEnabled
                    settings.save()
                    onAdvance()
                }
                .buttonStyle(.primaryWhite)

                Button("Skip — use default 23:00", action: onAdvance)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }
}
```

- [ ] **Step 3: Create `BedtimeSettingsTests.swift`.**

```swift
//
//  BedtimeSettingsTests.swift
//  WakeProofTests
//

import XCTest
@testable import WakeProof

final class BedtimeSettingsTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "com.wakeproof.tests.bedtime")!
        defaults.removePersistentDomain(forName: "com.wakeproof.tests.bedtime")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "com.wakeproof.tests.bedtime")
        super.tearDown()
    }

    func testLoadReturnsDefaultWhenMissing() {
        let loaded = BedtimeSettings.load(from: defaults)
        XCTAssertEqual(loaded, .defaultSettings)
    }

    func testSaveThenLoadRoundTrips() {
        let original = BedtimeSettings(hour: 22, minute: 45, isEnabled: true)
        original.save(to: defaults)
        let loaded = BedtimeSettings.load(from: defaults)
        XCTAssertEqual(loaded, original)
    }

    func testNextBedtimeReturnsFutureToday() {
        let settings = BedtimeSettings(hour: 23, minute: 0, isEnabled: true)
        let reference = dateAt(hour: 21, minute: 0)
        let next = settings.nextBedtime(after: reference)
        XCTAssertEqual(next?.formatted(date: .omitted, time: .shortened), dateAt(hour: 23, minute: 0).formatted(date: .omitted, time: .shortened))
    }

    func testNextBedtimeRollsToTomorrowIfPassed() {
        let settings = BedtimeSettings(hour: 23, minute: 0, isEnabled: true)
        let reference = dateAt(hour: 23, minute: 30)
        let next = settings.nextBedtime(after: reference)
        XCTAssertNotNil(next)
        XCTAssertGreaterThan(next!, reference)
    }

    private func dateAt(hour: Int, minute: Int) -> Date {
        var c = Calendar.current.dateComponents([.year, .month, .day], from: .now)
        c.hour = hour
        c.minute = minute
        return Calendar.current.date(from: c)!
    }
}
```

- [ ] **Step 4: Simulator build + run tests.**

```bash
xcodebuild -project /Users/mountainfung/Desktop/WakeProof-Hackathon/WakeProof/WakeProof.xcodeproj \
  -scheme WakeProof -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  test -only-testing:WakeProofTests/BedtimeSettingsTests 2>&1 | tail -40
```

Expected: 4 tests pass.

- [ ] **Step 5: Commit.**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon/ add \
  WakeProof/WakeProof/Alarm/BedtimeSettings.swift \
  WakeProof/WakeProof/Onboarding/BedtimeStep.swift \
  WakeProof/WakeProofTests/BedtimeSettingsTests.swift
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon/ commit -m "Overnight Phase A.5: BedtimeSettings (UserDefaults-backed) + onboarding BedtimeStep view + tests"
```

### Task A.6: NightlyPromptTemplate (fallback-path prompt)

**Files:**
- Create: `WakeProof/WakeProof/Services/NightlyPromptTemplate.swift`
- Create: `WakeProof/WakeProofTests/NightlyPromptTemplateTests.swift`
- Create: `docs/nightly-prompt.md`

**Dependencies:** Task A.5

- [ ] **Step 1: Create `NightlyPromptTemplate.swift`.**

```swift
//
//  NightlyPromptTemplate.swift
//  WakeProof
//
//  Prompt template for the nightly synthesis call (fallback path, Messages API).
//  Distinct from VisionPromptTemplate because the output is prose, not JSON, and
//  there are no images in the request.
//

import Foundation

enum NightlyPromptTemplate {
    case v1

    func systemPrompt() -> String {
        switch self {
        case .v1:
            return """
            You are the overnight analyst of a wake-up accountability app called WakeProof. During the night, \
            you ingest the user's sleep signals and (optionally) a persistent memory file of observed patterns \
            across prior wake-ups. Produce a short morning briefing (3–5 sentences, plain prose, no markdown) \
            the user will read right after they prove they're awake.

            Tone: warm, concise, specific. Avoid platitudes. If sleep data is missing or very thin, acknowledge \
            that briefly — do not invent numbers.

            If a memory profile is provided, use it to tailor the briefing. Do not surface the memory file \
            contents verbatim; weave the insight into the briefing naturally. Example good line: "You slept \
            40 minutes less than your typical Monday — expect slower verification today." Example bad line: \
            "According to your memory file: 'Mondays are harder.'"

            Never speculate about medical issues, sleep disorders, or diagnoses. This is a self-commitment \
            tool, not a medical device.
            """
        }
    }

    func userPrompt(sleep: SleepSnapshot, memoryProfile: String?, priorBriefings: [String]) -> String {
        switch self {
        case .v1:
            let sleepBlock = render(sleep)
            let memoryBlock = memoryProfile.map { "\n\n<memory_profile>\n\($0)\n</memory_profile>" } ?? ""
            let priorBlock: String = {
                guard !priorBriefings.isEmpty else { return "" }
                let rendered = priorBriefings.prefix(3).enumerated().map { idx, text in
                    let count = idx + 1
                    let suffix = count == 1 ? "night ago" : "nights ago"
                    return "[\(count) \(suffix)] \(text)"
                }.joined(separator: "\n")
                return "\n\n<prior_briefings>\n\(rendered)\n</prior_briefings>"
            }()

            return """
            \(sleepBlock)\(memoryBlock)\(priorBlock)

            Write the morning briefing now. Plain prose, 3–5 sentences. No heading. No preamble.
            """
        }
    }

    // MARK: - Private

    private func render(_ snapshot: SleepSnapshot) -> String {
        guard !snapshot.isEmpty else {
            return "<sleep>No sleep data available for this window.</sleep>"
        }
        let hrLine: String = {
            guard let avg = snapshot.heartRateAvg else { return "no heart-rate samples" }
            return "HR avg \(Int(avg.rounded())) bpm (\(snapshot.heartRateSampleCount) samples)"
        }()
        return """
        <sleep>
        Window: \(snapshot.windowStart.ISO8601Format()) → \(snapshot.windowEnd.ISO8601Format()).
        Time in bed: \(snapshot.totalInBedMinutes) minutes. Awake: \(snapshot.awakeMinutes) minutes.
        \(hrLine).
        Source includes Apple Watch: \(snapshot.hasAppleWatchData ? "yes" : "no").
        </sleep>
        """
    }
}
```

- [ ] **Step 2: Create `NightlyPromptTemplateTests.swift`.**

```swift
//
//  NightlyPromptTemplateTests.swift
//  WakeProofTests
//

import XCTest
@testable import WakeProof

final class NightlyPromptTemplateTests: XCTestCase {

    private let fullSleep = SleepSnapshot(
        totalInBedMinutes: 420, awakeMinutes: 30,
        heartRateAvg: 58, heartRateMin: 48, heartRateMax: 75,
        heartRateSampleCount: 128, hasAppleWatchData: true,
        windowStart: Date(timeIntervalSince1970: 1_745_400_000),
        windowEnd: Date(timeIntervalSince1970: 1_745_425_200)
    )

    func testSystemPromptMentionsWakeProof() {
        XCTAssertTrue(NightlyPromptTemplate.v1.systemPrompt().contains("WakeProof"))
    }

    func testSystemPromptForbidsMedicalAdvice() {
        XCTAssertTrue(NightlyPromptTemplate.v1.systemPrompt().contains("medical"))
    }

    func testUserPromptIncludesSleepBlock() {
        let p = NightlyPromptTemplate.v1.userPrompt(
            sleep: fullSleep, memoryProfile: nil, priorBriefings: []
        )
        XCTAssertTrue(p.contains("Time in bed: 420"))
        XCTAssertTrue(p.contains("Apple Watch: yes"))
    }

    func testEmptySleepRendersDeclaratively() {
        let p = NightlyPromptTemplate.v1.userPrompt(
            sleep: .empty, memoryProfile: nil, priorBriefings: []
        )
        XCTAssertTrue(p.contains("No sleep data available"))
    }

    func testMemoryProfileIsWrappedInTags() {
        let p = NightlyPromptTemplate.v1.userPrompt(
            sleep: fullSleep, memoryProfile: "User wakes groggy on Mondays.",
            priorBriefings: []
        )
        XCTAssertTrue(p.contains("<memory_profile>"))
        XCTAssertTrue(p.contains("User wakes groggy on Mondays."))
    }

    func testPriorBriefingsAreLimitedToThree() {
        let priors = (0..<10).map { "briefing \($0)" }
        let p = NightlyPromptTemplate.v1.userPrompt(
            sleep: fullSleep, memoryProfile: nil, priorBriefings: priors
        )
        XCTAssertTrue(p.contains("briefing 0"))
        XCTAssertTrue(p.contains("briefing 2"))
        XCTAssertFalse(p.contains("briefing 3"))
    }
}
```

- [ ] **Step 3: Create `docs/nightly-prompt.md`.**

```markdown
# Overnight Nightly Synthesis Prompt (Fallback Path)

> Versioned artifact. The live prompt is sourced from `WakeProof/WakeProof/Services/NightlyPromptTemplate.swift`; this file mirrors it for documentation.
>
> Used only on the BGProcessingTask fallback path (`NightlySynthesisClient`). The primary path (Managed Agents) uses a different system prompt defined at Agent creation time in `docs/managed-agents-setup.md`.

## v1 — 2026-04-24

### System prompt

(paste from NightlyPromptTemplate.v1.systemPrompt())

### User prompt template

(paste from NightlyPromptTemplate.v1.userPrompt())

### Input block shapes

\`\`\`xml
<sleep>
Window: 2026-04-23T23:00:00Z → 2026-04-24T07:00:00Z.
Time in bed: 420 minutes. Awake: 30 minutes.
HR avg 58 bpm (128 samples).
Source includes Apple Watch: yes.
</sleep>

<memory_profile>
User wakes groggy on Mondays; weekend verifications are faster and more alert.
</memory_profile>

<prior_briefings>
[1 nights ago] You slept consistently — verification should be snappy.
[2 nights ago] A short awake period around 3 AM; nothing concerning.
</prior_briefings>
\`\`\`

### Output shape

Plain prose. No markdown. 3–5 sentences. No heading, no preamble.

### Change log

- **v1 (2026-04-24)** — initial Layer 3 fallback-path prompt.
```

- [ ] **Step 4: Simulator build + run tests.**

```bash
xcodebuild -project /Users/mountainfung/Desktop/WakeProof-Hackathon/WakeProof/WakeProof.xcodeproj \
  -scheme WakeProof -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  test -only-testing:WakeProofTests/NightlyPromptTemplateTests 2>&1 | tail -40
```

Expected: 6 tests pass.

- [ ] **Step 5: Commit.**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon/ add \
  WakeProof/WakeProof/Services/NightlyPromptTemplate.swift \
  WakeProof/WakeProofTests/NightlyPromptTemplateTests.swift \
  docs/nightly-prompt.md
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon/ commit -m "Overnight Phase A.6: NightlyPromptTemplate v1 (fallback path) + doc mirror + tests"
```

### Task A.7: NightlySynthesisClient (fallback-path client)

**Files:**
- Create: `WakeProof/WakeProof/Services/NightlySynthesisClient.swift`
- Create: `WakeProof/WakeProofTests/NightlySynthesisClientTests.swift`

**Dependencies:** Task A.6

**Important context:** This is the fallback-path client. Calls the existing `/v1/messages` endpoint (Vercel messages.js) with the nightly prompt. Returns plain text. Single round-trip per BGProcessingTask wake-up. Uses the Day 3 `Secrets.wakeproofToken` for auth; no new secrets.

- [ ] **Step 1: Create `NightlySynthesisClient.swift`.**

```swift
//
//  NightlySynthesisClient.swift
//  WakeProof
//
//  Fallback-path client for the nightly synthesis call. Calls the existing
//  /v1/messages route (via Vercel proxy) with the NightlyPromptTemplate.v1
//  prompt. Returns the briefing text. Chosen on the BGProcessingTask path
//  when Managed Agents onboarding did not land in Phase B's decision gate.
//

import Foundation
import os

enum NightlySynthesisError: LocalizedError {
    case missingProxyToken
    case invalidURL
    case transportFailed(underlying: Error)
    case httpError(status: Int, snippet: String)
    case timeout
    case emptyResponse
    case decodingFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .missingProxyToken: return "Nightly synthesis: proxy token missing."
        case .invalidURL: return "Nightly synthesis: could not build URL."
        case .transportFailed: return "Nightly synthesis: network error."
        case .httpError(let status, _): return "Nightly synthesis: HTTP \(status)."
        case .timeout: return "Nightly synthesis: timed out."
        case .emptyResponse: return "Nightly synthesis: empty response."
        case .decodingFailed: return "Nightly synthesis: response parse failed."
        }
    }
}

struct NightlySynthesisClient {

    let session: URLSession
    let endpoint: URL
    let model: String
    private let proxyToken: String
    private let logger = Logger(subsystem: "com.wakeproof.overnight", category: "synthesis")

    init(
        session: URLSession = Self.defaultSession,
        endpoint: URL = Self.defaultMessagesEndpoint,
        model: String = Secrets.textModel,
        proxyToken: String = Secrets.wakeproofToken
    ) {
        self.session = session
        self.endpoint = endpoint
        self.model = model
        self.proxyToken = proxyToken
    }

    private static var defaultMessagesEndpoint: URL {
        // Reuse the Day 3 messages.js endpoint. `Secrets.claudeEndpoint` is the
        // base; the messages.js route is `.../v1/messages`.
        let base = Secrets.claudeEndpoint.isEmpty
            ? "https://api.anthropic.com/v1/messages"
            : Secrets.claudeEndpoint
        return URL(string: base)!
    }

    private static var defaultSession: URLSession {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 30
        return URLSession(configuration: c)
    }

    func synthesize(
        sleep: SleepSnapshot,
        memoryProfile: String?,
        priorBriefings: [String]
    ) async throws -> String {
        guard !proxyToken.isEmpty, proxyToken != "REPLACE_WITH_OPENSSL_RAND_HEX_32" else {
            throw NightlySynthesisError.missingProxyToken
        }

        let template = NightlyPromptTemplate.v1
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 500,
            "system": template.systemPrompt(),
            "messages": [[
                "role": "user",
                "content": [[
                    "type": "text",
                    "text": template.userPrompt(sleep: sleep, memoryProfile: memoryProfile, priorBriefings: priorBriefings)
                ]]
            ]]
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(proxyToken, forHTTPHeaderField: "x-wakeproof-token")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = bodyData

        logger.info("Nightly synthesis: calling model=\(self.model, privacy: .public) memory=\(memoryProfile != nil, privacy: .public)")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw NightlySynthesisError.timeout
        } catch {
            throw NightlySynthesisError.transportFailed(underlying: error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw NightlySynthesisError.emptyResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let snippet = String(data: data.prefix(500), encoding: .utf8) ?? "<non-utf8>"
            throw NightlySynthesisError.httpError(status: http.statusCode, snippet: snippet)
        }

        struct Body: Decodable {
            struct Block: Decodable { let type: String; let text: String? }
            let content: [Block]?
        }
        do {
            let parsed = try JSONDecoder().decode(Body.self, from: data)
            guard let text = parsed.content?.first(where: { $0.type == "text" })?.text else {
                throw NightlySynthesisError.emptyResponse
            }
            return text
        } catch {
            throw NightlySynthesisError.decodingFailed(underlying: error)
        }
    }
}
```

- [ ] **Step 2: Create `NightlySynthesisClientTests.swift`.**

Mirror the `URLProtocol`-stub pattern used in `ClaudeAPIClientTests.swift`. Test coverage: success (200 with text block), 401 → httpError, 500 → httpError, timeout → .timeout, missing content → .emptyResponse, malformed body → .decodingFailed.

(Fill in using the existing test suite's stub pattern — exact implementation mirrors Day 3's ClaudeAPIClientTests with the endpoint and request-body assertions adapted.)

- [ ] **Step 3: Simulator build + run tests.**

Expected: ~6 tests pass for NightlySynthesisClient.

- [ ] **Step 4: Commit.**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon/ add \
  WakeProof/WakeProof/Services/NightlySynthesisClient.swift \
  WakeProof/WakeProofTests/NightlySynthesisClientTests.swift
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon/ commit -m "Overnight Phase A.7: NightlySynthesisClient (fallback path via /v1/messages) + URLProtocol-stubbed tests"
```

### Task A.8: OvernightAgentClient (Managed Agents client)

**Files:**
- Create: `WakeProof/WakeProof/Services/OvernightAgentClient.swift`
- Create: `WakeProof/WakeProofTests/OvernightAgentClientTests.swift`
- Create: `docs/managed-agents-setup.md`

**Dependencies:** Task A.7

**Important context:** The Managed Agents REST API uses three resources: **agent** (reusable config; create once), **environment** (container template; create once), **session** (per-night run). Our client caches the first two resource IDs in UserDefaults (`com.wakeproof.overnight.agentID`, `com.wakeproof.overnight.environmentID`) so normal nights only POST a session.

The agent's system prompt is set at agent-create time and includes WakeProof's overnight task. The environment we use is Python 3 (per research notes — pre-installed) so the agent can write scratch files during its reasoning. Task budget is set per-session.

Event shape (per research notes):
- `POST /v1/sessions/:id/events` body: `{"event": {"type": "user.message", "content": [...]}}`
- `GET /v1/sessions/:id/events?after=<eventID>` returns an array of events
- We look for `{"type": "agent.message", ...}` with the final briefing

Error cases to handle:
- 401 Unauthorized: proxy token rejected or Anthropic key invalid
- 403 Forbidden: Managed Agents not enabled for this tier (Tier-4 access should preclude this)
- 429 Rate-limited: back off and retry
- 5xx: transport failure

**Not handled (documented, not implemented):** 409 Conflict on agent/environment creation
retries. The research notes don't specify whether duplicate-name creates return 409 with a
pointer to the existing resource or create a duplicate; we rely on `UserDefaults` caching
the first-successful IDs so retries are avoided on the happy path. If B.3 dry-run surfaces
a 409 shape we need to handle, add a branch then — do not pre-implement untested error
handling.

- [ ] **Step 1: Create `OvernightAgentClient.swift`.**

```swift
//
//  OvernightAgentClient.swift
//  WakeProof
//
//  Primary-path client for the overnight Managed Agent. Wraps the three-tier
//  resource model (agent → environment → session) plus events and termination.
//  Agent and environment IDs persist in UserDefaults across nights; sessions
//  are one-per-night.
//
//  All calls route through the Vercel wildcard proxy (/api/v1/*) — the
//  Anthropic key never reaches the device. Required beta header:
//  `managed-agents-2026-04-01`.
//

import Foundation
import os

enum OvernightAgentError: LocalizedError {
    case missingProxyToken
    case invalidURL
    case transportFailed(underlying: Error)
    case httpError(status: Int, snippet: String)
    case timeout
    case missingResourceID(String)
    case decodingFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .missingProxyToken: return "Overnight agent: proxy token missing."
        case .invalidURL: return "Overnight agent: invalid URL."
        case .transportFailed: return "Overnight agent: transport failed."
        case .httpError(let status, _): return "Overnight agent: HTTP \(status)."
        case .timeout: return "Overnight agent: timed out."
        case .missingResourceID(let name): return "Overnight agent: expected \(name) not found in response."
        case .decodingFailed: return "Overnight agent: response parse failed."
        }
    }
}

actor OvernightAgentClient {

    struct Handle: Codable, Equatable {
        let agentID: String
        let environmentID: String
        let sessionID: String
    }

    private let session: URLSession
    private let baseURL: URL
    private let proxyToken: String
    private let beta: String
    private let logger = Logger(subsystem: "com.wakeproof.overnight", category: "agent-client")

    init(
        session: URLSession = Self.defaultSession,
        baseURL: URL = Self.defaultBaseURL,
        proxyToken: String = Secrets.wakeproofToken,
        beta: String = "managed-agents-2026-04-01"
    ) {
        self.session = session
        self.baseURL = baseURL
        self.proxyToken = proxyToken
        self.beta = beta
    }

    private static var defaultBaseURL: URL {
        // Strip the messages suffix if the Day 3 Secrets value points at it.
        let raw = Secrets.claudeEndpoint.isEmpty
            ? "https://api.anthropic.com"
            : Secrets.claudeEndpoint
        // Secrets.claudeEndpoint ends in ".../v1/messages" on Day 3; the base URL for
        // the agent client is the same host without the messages segment. Our proxy's
        // wildcard route resolves everything from /v1/* onwards.
        if let url = URL(string: raw),
           let host = url.host,
           let scheme = url.scheme {
            return URL(string: "\(scheme)://\(host)")!
        }
        return URL(string: "https://api.anthropic.com")!
    }

    private static var defaultSession: URLSession {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 30
        return URLSession(configuration: c)
    }

    // MARK: - Public API

    /// Ensure the agent + environment resources exist. Reuses cached IDs in
    /// UserDefaults; creates new ones on first call. Idempotent.
    func ensureAgentAndEnvironment() async throws -> (agentID: String, environmentID: String) {
        let cachedAgent = UserDefaults.standard.string(forKey: "com.wakeproof.overnight.agentID")
        let cachedEnv = UserDefaults.standard.string(forKey: "com.wakeproof.overnight.environmentID")
        if let a = cachedAgent, let e = cachedEnv { return (a, e) }

        let agentID = try await createAgent()
        UserDefaults.standard.set(agentID, forKey: "com.wakeproof.overnight.agentID")
        let envID = try await createEnvironment()
        UserDefaults.standard.set(envID, forKey: "com.wakeproof.overnight.environmentID")
        return (agentID, envID)
    }

    /// Start a new session for tonight. Returns the session id + the attached
    /// agent / environment ids baked into a `Handle`.
    func startSession(seedMessage: String, taskBudgetTokens: Int = 128_000) async throws -> Handle {
        let (agentID, envID) = try await ensureAgentAndEnvironment()
        let url = baseURL.appendingPathComponent("v1/sessions")
        let body: [String: Any] = [
            "agent_id": agentID,
            "environment_id": envID,
            "initial_message": [
                "role": "user",
                "content": [["type": "text", "text": seedMessage]]
            ],
            "task_budget": ["type": "tokens", "total": taskBudgetTokens]
        ]
        let data = try await postJSON(url: url, body: body)
        struct Resp: Decodable { let id: String? }
        let parsed = try JSONDecoder().decode(Resp.self, from: data)
        guard let id = parsed.id else { throw OvernightAgentError.missingResourceID("session.id") }
        logger.info("Managed Agent session started id=\(id, privacy: .public) budget=\(taskBudgetTokens, privacy: .public) tokens")
        return Handle(agentID: agentID, environmentID: envID, sessionID: id)
    }

    /// Append a user.message event to a live session.
    func appendEvent(sessionID: String, text: String) async throws {
        let url = baseURL.appendingPathComponent("v1/sessions/\(sessionID)/events")
        let body: [String: Any] = [
            "event": [
                "type": "user.message",
                "content": [["type": "text", "text": text]]
            ]
        ]
        _ = try await postJSON(url: url, body: body)
        logger.info("Appended event to session \(sessionID, privacy: .public) (bytes=\(text.utf8.count, privacy: .public))")
    }

    /// Fetch events and return the latest agent.message content (if any).
    func fetchLatestAgentMessage(sessionID: String) async throws -> String? {
        let url = baseURL.appendingPathComponent("v1/sessions/\(sessionID)/events")
        let data = try await getJSON(url: url)
        struct Events: Decodable {
            struct Event: Decodable {
                struct Block: Decodable { let type: String; let text: String? }
                let type: String
                let content: [Block]?
            }
            let events: [Event]?
        }
        let parsed = try JSONDecoder().decode(Events.self, from: data)
        let agentMessages = parsed.events?.filter { $0.type == "agent.message" } ?? []
        let lastText = agentMessages.last?.content?.first(where: { $0.type == "text" })?.text
        return lastText
    }

    /// Terminate the session so its `running` runtime stops accruing. Sessions
    /// can be listed and read after termination; this only stops billing the
    /// running time.
    ///
    /// **API shape is assumed, not confirmed by the research notes.** The notes
    /// (docs/opus-4-7-research-notes.md Question 3) document session statuses
    /// (`idle`/`running`/`rescheduling`/`terminated`) and note that "A running
    /// session cannot be deleted; send an interrupt event if you need to delete
    /// it immediately." The PATCH shape below is our best-effort first attempt;
    /// if Task B.3 dry-run Step 5 rejects the PATCH, switch to the interrupt-
    /// event fallback (defined below this method). Task B.3 Step 5 verifies.
    func terminateSession(sessionID: String) async throws {
        let url = baseURL.appendingPathComponent("v1/sessions/\(sessionID)")
        let body: [String: Any] = ["status": "terminated"]
        do {
            _ = try await patchJSON(url: url, body: body)
            logger.info("Terminated session \(sessionID, privacy: .public) via PATCH /v1/sessions/:id")
        } catch OvernightAgentError.httpError(let status, _) where status == 404 || status == 405 {
            // PATCH path doesn't exist — fall back to the documented interrupt-event pattern.
            logger.info("PATCH termination got \(status, privacy: .public); retrying with interrupt event")
            try await terminateViaInterruptEvent(sessionID: sessionID)
        }
    }

    /// Fallback termination path — send a user event with an interrupt payload.
    /// Shape inferred from research notes ("send an interrupt event if you need
    /// to delete it immediately"). Task B.3's dry-run records the actual shape
    /// Anthropic accepts; update this body literal if dry-run reveals a different
    /// required key.
    private func terminateViaInterruptEvent(sessionID: String) async throws {
        let url = baseURL.appendingPathComponent("v1/sessions/\(sessionID)/events")
        let body: [String: Any] = [
            "event": [
                "type": "user.interrupt",
                "reason": "client-terminated"
            ]
        ]
        _ = try await postJSON(url: url, body: body)
        logger.info("Terminated session \(sessionID, privacy: .public) via interrupt event")
    }

    // MARK: - Private helpers

    private func createAgent() async throws -> String {
        let url = baseURL.appendingPathComponent("v1/agents")
        let body: [String: Any] = [
            "name": "wakeproof-overnight",
            "model": Secrets.visionModel,  // Opus 4.7 — same model as the vision call
            "system": Self.agentSystemPrompt()
        ]
        let data = try await postJSON(url: url, body: body)
        struct Resp: Decodable { let id: String? }
        let parsed = try JSONDecoder().decode(Resp.self, from: data)
        guard let id = parsed.id else { throw OvernightAgentError.missingResourceID("agent.id") }
        return id
    }

    private func createEnvironment() async throws -> String {
        let url = baseURL.appendingPathComponent("v1/environments")
        let body: [String: Any] = [
            "name": "wakeproof-env-python",
            "runtime": "python"
        ]
        let data = try await postJSON(url: url, body: body)
        struct Resp: Decodable { let id: String? }
        let parsed = try JSONDecoder().decode(Resp.self, from: data)
        guard let id = parsed.id else { throw OvernightAgentError.missingResourceID("environment.id") }
        return id
    }

    private static func agentSystemPrompt() -> String {
        """
        You are the overnight analyst of WakeProof, a wake-up accountability app. Over the course of \
        one night, you ingest sleep + heart-rate data the iOS client sends as user.message events. You \
        are also given a `memory_profile` markdown block describing observed patterns from prior \
        wake-ups. Your task: produce a short morning briefing (3–5 sentences, plain prose, no markdown) \
        the user will read right after they prove they're awake tomorrow.

        Use the Python environment to write scratch notes to /tmp/notes/ as you reason. Do not echo \
        environment contents back in your final message — the user only sees the briefing.

        Your FINAL message must have this shape on the agent.message content:

          BRIEFING: <3–5 sentences of prose>
          MEMORY_UPDATE: <optional updated profile markdown, or "NONE">

        Rules:
          - Warm, specific, concise. No platitudes. No medical speculation.
          - If sleep data is missing, say so briefly in BRIEFING, do not invent numbers.
          - MEMORY_UPDATE is only for durable insights ("user's Monday mornings are harder than weekends"), \
            not a log of this night's events. Output NONE if nothing new.
        """
    }

    private func postJSON(url: URL, body: [String: Any]) async throws -> Data {
        try await jsonRequest(url: url, method: "POST", body: body)
    }

    private func getJSON(url: URL) async throws -> Data {
        try await jsonRequest(url: url, method: "GET", body: nil)
    }

    private func patchJSON(url: URL, body: [String: Any]) async throws -> Data {
        try await jsonRequest(url: url, method: "PATCH", body: body)
    }

    private func jsonRequest(url: URL, method: String, body: [String: Any]?) async throws -> Data {
        guard !proxyToken.isEmpty, proxyToken != "REPLACE_WITH_OPENSSL_RAND_HEX_32" else {
            throw OvernightAgentError.missingProxyToken
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(proxyToken, forHTTPHeaderField: "x-wakeproof-token")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue(beta, forHTTPHeaderField: "anthropic-beta")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw OvernightAgentError.timeout
        } catch {
            throw OvernightAgentError.transportFailed(underlying: error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw OvernightAgentError.decodingFailed(underlying: OvernightAgentError.invalidURL)
        }
        guard (200..<300).contains(http.statusCode) else {
            let snippet = String(data: data.prefix(500), encoding: .utf8) ?? "<non-utf8>"
            throw OvernightAgentError.httpError(status: http.statusCode, snippet: snippet)
        }
        return data
    }
}
```

- [ ] **Step 2: Create `OvernightAgentClientTests.swift`.**

Mirror the `URLProtocol`-stub pattern from `ClaudeAPIClientTests.swift`. Cover:

- `ensureAgentAndEnvironment()` creates agent + env on first call; caches IDs
- `ensureAgentAndEnvironment()` reuses cached IDs on second call (no HTTP traffic)
- `startSession(seedMessage:)` returns a Handle with the right session id
- `startSession` includes `task_budget` in the POST body
- `appendEvent(sessionID:)` posts to the right path with the right body
- `fetchLatestAgentMessage(sessionID:)` finds `agent.message` type events and returns the latest text
- `fetchLatestAgentMessage(sessionID:)` returns nil when no agent.message events are present
- `terminateSession(sessionID:)` sends PATCH with `{"status":"terminated"}` on the happy path
- `terminateSession(sessionID:)` falls back to interrupt-event POST when PATCH returns 404 or 405
- Each method sends `anthropic-beta: managed-agents-2026-04-01`

Approximately 10 tests (±2 depending on how the PATCH/interrupt-event fallback test cases are counted).

- [ ] **Step 3: Create `docs/managed-agents-setup.md`.**

```markdown
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

## Re-use on subsequent nights

`OvernightAgentClient` caches the agent id and environment id in UserDefaults after first successful create. Nightly use is `startSession()` only.
```

- [ ] **Step 4: Simulator build + run tests.**

```bash
xcodebuild -project /Users/mountainfung/Desktop/WakeProof-Hackathon/WakeProof/WakeProof.xcodeproj \
  -scheme WakeProof -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  test -only-testing:WakeProofTests/OvernightAgentClientTests 2>&1 | tail -50
```

Expected: ~10 tests pass.

- [ ] **Step 5: Commit.**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon/ add \
  WakeProof/WakeProof/Services/OvernightAgentClient.swift \
  WakeProof/WakeProofTests/OvernightAgentClientTests.swift \
  docs/managed-agents-setup.md
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon/ commit -m "Overnight Phase A.8: OvernightAgentClient (Managed Agents primary) + setup doc + URLProtocol-stubbed tests"
```

### Task A.9: OvernightScheduler + protocol abstraction

**Files:**
- Create: `WakeProof/WakeProof/Services/OvernightScheduler.swift`
- Create: `WakeProof/WakeProofTests/OvernightSchedulerTests.swift`

**Dependencies:** Task A.8

**Important context:** This is the orchestration layer that both paths plug into via `OvernightBriefingSource`. It owns the bedtime trigger, the BGProcessingTask registration, and the briefing fetch at wake time. Its implementation is path-agnostic.

- [ ] **Step 1: Create `OvernightScheduler.swift`.**

```swift
//
//  OvernightScheduler.swift
//  WakeProof
//
//  Layer 3 orchestration. Plugs into a briefing source (Managed Agent or
//  nightly synthesis) via the OvernightBriefingSource protocol. Handles bedtime
//  → start of session, periodic BGProcessingTask wake-ups for event pokes,
//  and the fetch at alarm time.
//

import BackgroundTasks
import Foundation
import SwiftData
import os

/// Abstraction the scheduler drives. Phase B.5 picks a concrete impl.
protocol OvernightBriefingSource: Actor {
    /// Open the session (primary) or store initial data for BGProcessingTask-based
    /// synthesis (fallback). Returns an opaque handle the scheduler persists.
    func planOvernight(sleep: SleepSnapshot, memoryProfile: String?) async throws -> String

    /// Called from BGProcessingTask wake-ups. Returns true if a briefing has been
    /// produced and stored; false if more work is expected.
    func pokeIfNeeded(handle: String, sleep: SleepSnapshot) async throws -> Bool

    /// Called at alarm time. Returns the briefing text + optional memory update.
    func fetchBriefing(handle: String) async throws -> (text: String, memoryUpdate: String?)

    /// Best-effort cleanup. Terminates primary-path sessions; no-op on fallback.
    func cleanup(handle: String) async
}

actor OvernightScheduler {

    static let backgroundTaskIdentifier = "com.wakeproof.overnight.refresh"

    private let source: any OvernightBriefingSource
    private let sleepReader: HealthKitSleepReader
    private let memoryStore: MemoryStore
    private let modelContainer: ModelContainer
    private let logger = Logger(subsystem: "com.wakeproof.overnight", category: "scheduler")

    init(
        source: any OvernightBriefingSource,
        sleepReader: HealthKitSleepReader,
        memoryStore: MemoryStore,
        modelContainer: ModelContainer
    ) {
        self.source = source
        self.sleepReader = sleepReader
        self.memoryStore = memoryStore
        self.modelContainer = modelContainer
    }

    /// Kick off tonight's session. Called from WakeProofApp when BedtimeSettings
    /// is enabled and the clock crosses bedtime.
    func startOvernightSession() async {
        do {
            let sleep = (try? await sleepReader.lastNightSleep()) ?? .empty
            let snap = (try? await memoryStore.read()) ?? .empty
            let handle = try await source.planOvernight(sleep: sleep, memoryProfile: snap.profile)
            UserDefaults.standard.set(handle, forKey: "com.wakeproof.overnight.activeHandle")
            logger.info("Overnight session started, handle=\(handle, privacy: .private)")
            scheduleNextBackgroundRefresh()
        } catch {
            logger.error("Overnight start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// BGProcessingTask handler. Order matters: set the expiration handler BEFORE
    /// any async work so iOS can reclaim the task cleanly if the user-time budget
    /// runs out mid-refresh. Then schedule the next refresh (so a crash after
    /// this point still leaves a future task queued). Then do the work.
    func handleBackgroundRefresh(_ task: BGProcessingTask) async {
        // (1) Expiration handler first. If iOS needs to reclaim the task before
        // we finish, this marks us cancelled so the task system doesn't revoke
        // our background-processing privilege for missing the deadline.
        task.expirationHandler = { [weak self] in
            self?.logger.warning("Background refresh expired before completion")
            task.setTaskCompleted(success: false)
        }
        // (2) Schedule next refresh. Submitting before the work means a crash
        // during the work still leaves tomorrow's refresh queued.
        scheduleNextBackgroundRefresh()
        // (3) The work itself.
        guard let handle = UserDefaults.standard.string(forKey: "com.wakeproof.overnight.activeHandle") else {
            task.setTaskCompleted(success: false)
            return
        }
        do {
            let sleep = (try? await sleepReader.lastNightSleep()) ?? .empty
            let briefingReady = try await source.pokeIfNeeded(handle: handle, sleep: sleep)
            if briefingReady {
                // Source signals the briefing is done; stop consuming BGTask budget
                // for tonight. The next session opens at next bedtime, not sooner.
                logger.info("Briefing ready — skipping additional BGTask submissions tonight")
                // (No explicit cancel API for a just-submitted BGProcessingTaskRequest;
                // it will fire once and then stop because source returns true again.)
            }
            task.setTaskCompleted(success: true)
        } catch {
            logger.error("Background refresh failed: \(error.localizedDescription, privacy: .public)")
            task.setTaskCompleted(success: false)
        }
    }

    /// Called at wake time. Pulls the briefing, persists to SwiftData, clears
    /// the active handle, and cleans up the source.
    func finalizeBriefing(forWakeDate wakeDate: Date) async -> MorningBriefing? {
        guard let handle = UserDefaults.standard.string(forKey: "com.wakeproof.overnight.activeHandle") else {
            return nil
        }
        do {
            let (text, memoryUpdate) = try await source.fetchBriefing(handle: handle)
            let context = ModelContext(modelContainer)
            let briefing = MorningBriefing(
                forWakeDate: wakeDate,
                briefingText: text,
                sourceSessionID: handle
            )
            context.insert(briefing)
            try context.save()
            if let memoryUpdate {
                try? await memoryStore.rewriteProfile(memoryUpdate)
                briefing.memoryUpdateApplied = true
                try? context.save()
            }
            await source.cleanup(handle: handle)
            UserDefaults.standard.removeObject(forKey: "com.wakeproof.overnight.activeHandle")
            return briefing
        } catch {
            logger.error("finalizeBriefing failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Register the BGProcessingTask identifier during app launch. Must be called
    /// before any `submit(_:)` call AND before `UIApplication.didFinishLaunching`
    /// completes — iOS crashes the app on first BGTask fire if the identifier
    /// was not registered by launch time. The `.task { bootstrapIfNeeded() }` in
    /// `WakeProofApp.body` runs AFTER launch completes (it fires on first scene
    /// attach), so registration CANNOT live in `bootstrapIfNeeded`. Task B.1
    /// Step 3 places the `registerBackgroundTask` call inside `WakeProofApp.init`
    /// right after the `ModelContainer` init.
    ///
    /// The launch handler cannot reach a scheduler actor that doesn't exist yet
    /// at init time, so the handler captures a weak pointer through a dispatch
    /// hop — by the time a BGTask actually fires (earliest minutes after boot),
    /// `overnightScheduler` is set.
    nonisolated static func registerBackgroundTask(onHandle: @escaping (BGProcessingTask) -> Void) {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: backgroundTaskIdentifier,
            using: nil,
            launchHandler: onHandle
        )
    }

    private func scheduleNextBackgroundRefresh() {
        let request = BGProcessingTaskRequest(identifier: Self.backgroundTaskIdentifier)
        request.requiresExternalPower = false
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = Date(timeIntervalSinceNow: 2 * 3600)  // 2h out
        do {
            try BGTaskScheduler.shared.submit(request)
            logger.info("Scheduled next BGProcessingTask for \(request.earliestBeginDate?.ISO8601Format() ?? "?", privacy: .public)")
        } catch {
            logger.error("BGProcessingTask submit failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
```

- [ ] **Step 2: Create `OvernightSchedulerTests.swift`.**

Tests drive the scheduler with a fake `OvernightBriefingSource` that records `planOvernight` / `pokeIfNeeded` / `fetchBriefing` / `cleanup` calls. Verify:

- `startOvernightSession()` calls `planOvernight` once with the latest sleep + memory data
- `startOvernightSession()` stores the returned handle in UserDefaults
- `finalizeBriefing(forWakeDate:)` returns the briefing and inserts into SwiftData (in-memory container)
- `finalizeBriefing(forWakeDate:)` applies memoryUpdate to the store when non-nil
- `finalizeBriefing(forWakeDate:)` removes the active handle from UserDefaults
- `handleBackgroundRefresh` schedules the next refresh before pokeIfNeeded runs (so a crash after poke still results in a future refresh)

Approximately 8 tests.

- [ ] **Step 3: Simulator build + run tests.**

Expected: 8 tests pass.

- [ ] **Step 4: Commit.**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon/ add \
  WakeProof/WakeProof/Services/OvernightScheduler.swift \
  WakeProof/WakeProofTests/OvernightSchedulerTests.swift
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon/ commit -m "Overnight Phase A.9: OvernightScheduler + OvernightBriefingSource protocol (path-agnostic orchestration) + tests"
```

### Task A.10: MorningBriefingView

**Files:**
- Create: `WakeProof/WakeProof/Verification/MorningBriefingView.swift`

**Dependencies:** Task A.9

- [ ] **Step 1: Create the view.**

```swift
//
//  MorningBriefingView.swift
//  WakeProof
//
//  Shown immediately after VERIFIED — small black overlay fading to the home
//  screen. Renders the briefing text produced by the overnight source. Graceful
//  fallback if none is available.
//

import SwiftUI

struct MorningBriefingView: View {
    let briefing: MorningBriefing?
    let onDismiss: () -> Void

    /// True when there's nothing useful to show — either no briefing row at all,
    /// or an empty briefingText (which parseAgentReply can return when the agent's
    /// reply lacks the BRIEFING marker AND is empty).
    private var hasContent: Bool {
        guard let briefing else { return false }
        return !briefing.briefingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 24) {
                Spacer()
                Text("Good morning")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(.white)
                Text(Date.now.formatted(date: .complete, time: .omitted))
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                if hasContent, let briefing {
                    Text(briefing.briefingText)
                        .font(.title3)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 28)
                } else {
                    VStack(spacing: 8) {
                        Text("No briefing this morning")
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.7))
                        Text("Sleep well tonight — Claude will prepare one.")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                Spacer()
                Button("Start your day", action: onDismiss)
                    .buttonStyle(.primaryWhite)
                    .padding(.bottom, 40)
            }
        }
    }
}

#Preview("With briefing") {
    MorningBriefingView(
        briefing: MorningBriefing(
            forWakeDate: .now,
            briefingText: "You slept 7h 15m — steady HR overnight. Expect a smooth verification today. Hydrate early; you were lighter on water yesterday evening."
        ),
        onDismiss: {}
    )
}

#Preview("No briefing") {
    MorningBriefingView(briefing: nil, onDismiss: {})
}
```

- [ ] **Step 2: Simulator build.**

```bash
xcodebuild -project /Users/mountainfung/Desktop/WakeProof-Hackathon/WakeProof/WakeProof.xcodeproj \
  -scheme WakeProof -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | tail -20
```

- [ ] **Step 3: Commit.**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon/ add WakeProof/WakeProof/Verification/MorningBriefingView.swift
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon/ commit -m "Overnight Phase A.10: MorningBriefingView with graceful-fallback card"
```

### Task A.11: Info.plist additions (BGTask identifier + processing mode)

**Files:**
- Modify: `WakeProof/Info.plist`

**Dependencies:** Task A.10

- [ ] **Step 1: Edit Info.plist.** Add to the existing `UIBackgroundModes` array:

```xml
<string>processing</string>
```

So the array now reads:

```xml
<key>UIBackgroundModes</key>
<array>
    <string>audio</string>
    <string>fetch</string>
    <string>processing</string>
</array>
```

Add a new top-level key:

```xml
<key>BGTaskSchedulerPermittedIdentifiers</key>
<array>
    <string>com.wakeproof.overnight.refresh</string>
</array>
```

- [ ] **Step 2: Simulator build.** Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit.**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon/ add WakeProof/Info.plist
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon/ commit -m "Overnight Phase A.11: Info.plist — add processing background mode + BGTaskSchedulerPermittedIdentifiers"
```

### Task A.12: Full test sweep

**Files:** n/a

**Dependencies:** Task A.11

- [ ] **Step 1: Run the complete test suite.**

```bash
xcodebuild -project /Users/mountainfung/Desktop/WakeProof-Hackathon/WakeProof/WakeProof.xcodeproj \
  -scheme WakeProof -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 15' test 2>&1 | tail -80
```

Expected: all Day 3 (52) + Layer 2 Memory Tool (~46) + Layer 3 Overnight Agent Phase A (~34 new — HealthKit reader 3 + SleepSnapshot 4 + MorningBriefing 3 + BedtimeSettings 4 + NightlyPromptTemplate 6 + NightlySynthesisClient 6 + OvernightAgentClient 10 + OvernightScheduler 8) = cumulative ~132 tests. All green.

- [ ] **Step 2: Verify no runtime behaviour changed.** Simulator launch, onboarding, alarm-fire happy path — the Day 3 flow still works end-to-end. Phase A has added nothing to the main flow; the OvernightScheduler is instantiated but never called.

- [ ] **Step 3: Sanity-check.**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon/ log --all --full-history --diff-filter=A --name-only -- 'WakeProof/WakeProof/Services/Secrets.swift'
```

Expected: empty.

**Phase A gate (HARD):** All tests green. Both client paths compile. Vercel wildcard proxy route deploys and smoke-tests. Info.plist changes land without signing errors. Cumulative test count ≥ 132. `Secrets.swift` never committed. **SwiftData migration check on device:** install Day 3 build on a clean device (creates BaselinePhoto + WakeAttempt rows); install Layer 3 Phase A build over it (triggers lightweight migration for the added `MorningBriefing.self` model); confirm baseline photo and recent wake attempts still appear in the UI. Takes ~5 minutes; prevents discovering migration breakage during Phase C review.

---

## Phase B — Integration (decision gate + wiring)

**Goal of phase:** Pick ONE of the two paths based on the Managed Agents dry-run in Task B.3. Wire that path into `WakeProofApp`, onboarding, and the alarm-wake flow. The unchosen path's code stays compiled but unused (preserved for post-hackathon).

### Task B.1: Wire OvernightScheduler into WakeProofApp

**Files:**
- Modify: `WakeProof/WakeProof/App/WakeProofApp.swift`

**Dependencies:** Phase A gate

**Important context:** At this point both `OvernightAgentClient` and `NightlySynthesisClient` are available but not yet connected to `OvernightScheduler`. Phase B.5 picks which concrete `OvernightBriefingSource` implementation to instantiate. For Task B.1 we stage the scaffolding with a temporary **no-op source** that does nothing; the app builds and the new `MorningBriefingView` renders only when a briefing exists (which, with the no-op, is never — so the UI shows "No briefing this morning" gracefully). This lets us ship Task B.1 commit without a decision and without risk.

- [ ] **Step 1: Add `@State` properties and environment wiring** to `WakeProofApp`:

```swift
    @State private var overnightScheduler: OvernightScheduler?
    @State private var noopSource = NoopBriefingSource()  // temporary for Task B.1; Task B.5 swaps
```

Split the work between `init()` (for registration, which iOS requires by launch-completion time) and `bootstrapIfNeeded()` (for everything else).

**In `WakeProofApp.init()`, immediately after the `ModelContainer` init:**

```swift
        // BGTaskScheduler requires identifier registration before
        // application(_:didFinishLaunchingWithOptions:) returns. `.task { … }` in
        // SwiftUI runs AFTER launch completes, so this cannot live in bootstrap.
        // The launch handler captures a weak box to self so it can reach the
        // scheduler actor that gets constructed later during bootstrap.
        let schedulerBox = Self.schedulerBox
        OvernightScheduler.registerBackgroundTask { task in
            Task {
                guard let scheduler = schedulerBox.value else {
                    task.setTaskCompleted(success: false)
                    return
                }
                await scheduler.handleBackgroundRefresh(task)
            }
        }
```

**Add a private class-level weak box** (file scope, below the WakeProofApp struct):

```swift
// Class so the box itself is reference-typed and can be captured into the
// BGTaskScheduler launch handler closure without needing to capture `self`
// before `self` exists.
final class OvernightSchedulerBox {
    weak var value: OvernightScheduler?
}
```

**On `WakeProofApp`, add the box as a static property:**

```swift
    private static let schedulerBox = OvernightSchedulerBox()
```

**Inside `bootstrapIfNeeded()`, after `visionVerifier.memoryStore = memoryStore`:**

```swift
        let scheduler = OvernightScheduler(
            source: noopSource,
            sleepReader: HealthKitSleepReader(),
            memoryStore: memoryStore,
            modelContainer: modelContainer
        )
        self.overnightScheduler = scheduler
        Self.schedulerBox.value = scheduler

        // Launch-time cleanup: if the previous app run crashed mid-session without
        // terminating (see Phase C.1 cost-containment review), UserDefaults still
        // holds `com.wakeproof.overnight.activeHandle` and the Managed Agents session
        // is still billing $0.08/hr. Kick off best-effort termination on launch.
        if let staleHandle = UserDefaults.standard.string(forKey: "com.wakeproof.overnight.activeHandle") {
            Task { @MainActor in
                Self.logger.warning("Found stale overnight handle on launch; attempting cleanup")
                await scheduler.cleanupStale(handle: staleHandle)
            }
        }
```

(Requires adding a `func cleanupStale(handle:) async` to `OvernightScheduler` — a thin pass-through to `source.cleanup(handle:)` followed by `UserDefaults.removeObject(forKey: "com.wakeproof.overnight.activeHandle")`. Add this method alongside `finalizeBriefing`.)

If a BGTask fires before bootstrap has run (rare — iOS would have to launch the app specifically for the BGTask before the first scene attaches), the handler's `schedulerBox.value` is nil and the task completes with `success: false`, which iOS retries. Acceptable degraded behaviour; the actual session work resumes once the app reaches bootstrap.

- [ ] **Step 2: Add a NoopBriefingSource.** In a file `WakeProof/WakeProof/Services/NoopBriefingSource.swift`:

```swift
//
//  NoopBriefingSource.swift
//  WakeProof
//
//  Temporary placeholder until Phase B.5 picks the primary or fallback source.
//  All methods succeed trivially; the MorningBriefingView handles the "no
//  briefing available" state by showing its graceful fallback card.
//

import Foundation

actor NoopBriefingSource: OvernightBriefingSource {
    func planOvernight(sleep: SleepSnapshot, memoryProfile: String?) async throws -> String { "noop" }
    func pokeIfNeeded(handle: String, sleep: SleepSnapshot) async throws -> Bool { true }
    func fetchBriefing(handle: String) async throws -> (text: String, memoryUpdate: String?) {
        throw OvernightNoopError.notConfigured
    }
    func cleanup(handle: String) async {}
}

enum OvernightNoopError: LocalizedError {
    case notConfigured
    var errorDescription: String? { "Overnight briefing not configured yet (Phase B.5 placeholder)." }
}
```

- [ ] **Step 3: Hook MorningBriefingView into the verified → idle transition.** In `RootView.body`, add state:

```swift
    @State private var latestBriefing: MorningBriefing?
    @State private var showBriefing = false
```

Extend the `.onChange(of: scheduler.phase)` handler's `(verifying, idle)` case:

```swift
            case (.verifying, .idle):
                soundEngine.stop()
                audioKeepalive.stopAlarmSound()
                visionVerifier.resetForNewFire()
                // NEW: surface morning briefing if one was prepared overnight.
                Task { @MainActor in
                    if let s = overnightScheduler {
                        latestBriefing = await s.finalizeBriefing(forWakeDate: .now)
                        showBriefing = true
                    }
                }
```

And add the overlay:

```swift
        .fullScreenCover(isPresented: $showBriefing) {
            MorningBriefingView(briefing: latestBriefing, onDismiss: {
                showBriefing = false
                latestBriefing = nil
            })
        }
```

**Wiring the scheduler into RootView — resolved approach.** Register `OvernightScheduler` via `.environment()` in the `WindowGroup` body (same pattern Day 3 uses for every other top-level service), and consume it in `RootView` with `@Environment`. Concretely:

(a) In `WakeProofApp.body`, after `.environment(visionVerifier)` and alongside the other environment lines, add (once `scheduler` is instantiated — see Step 2 below for construction order):

```swift
                .environment(overnightScheduler!)
```

The force-unwrap is safe because `bootstrapIfNeeded` runs inside `.task { … }` which the `WindowGroup` fires AFTER `body` first evaluates — by the time environment is read downstream, bootstrap has set `overnightScheduler`. If the force-unwrap feels brittle, refactor to construct the scheduler synchronously in `init()` (see the A.9 `registerBackgroundTask` correction below which forces this anyway) and drop the optional.

(b) In `RootView`, add:

```swift
    @Environment(OvernightScheduler.self) private var overnightScheduler
```

(c) The `.onChange(of: scheduler.phase)` handler in `RootView.body` can now call `overnightScheduler.finalizeBriefing(forWakeDate: .now)` directly without reaching back up into `WakeProofApp`.

This turns a "bridged in somehow" vague instruction into an explicit wiring path. The alternative — making the briefing hook live in `WakeProofApp` rather than `RootView` — would work but splits the alarm-phase-transition logic across two types, which Day 3's C.2 simplify pass would flag.

- [ ] **Step 4: Simulator build.** Expected: `** BUILD SUCCEEDED **`. Launch once to confirm UI doesn't crash — morning briefing overlay should NOT appear because the scheduler's `finalizeBriefing` returns nil (no active handle without a started session).

- [ ] **Step 5: Commit.**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon/ add \
  WakeProof/WakeProof/App/WakeProofApp.swift \
  WakeProof/WakeProof/Services/NoopBriefingSource.swift
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon/ commit -m "Overnight Phase B.1: wire OvernightScheduler + MorningBriefingView; NoopBriefingSource placeholder (replaced in B.5)"
```

### Task B.2: Onboarding flow integration (BedtimeStep)

**Files:**
- Modify: `WakeProof/WakeProof/Onboarding/OnboardingFlowView.swift`

**Dependencies:** Task B.1

- [ ] **Step 1: Add the `.bedtime` case.** In the `Step` enum:

```swift
    enum Step: CaseIterable {
        case welcome, notifications, camera, health, motion, bedtime, baseline, done
    }
```

In the switch inside `body`, after the `.motion` case and before `.baseline`:

```swift
                case .bedtime:
                    BedtimeStep(onAdvance: advance)
```

- [ ] **Step 2: Simulator build + walkthrough.** Run the simulator through onboarding from scratch (delete app first) to confirm bedtime screen appears, accepts input, persists, and advances to baseline.

- [ ] **Step 3: Commit.**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon/ add WakeProof/WakeProof/Onboarding/OnboardingFlowView.swift
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon/ commit -m "Overnight Phase B.2: insert BedtimeStep into onboarding between motion and baseline"
```

### Task B.3: Managed Agents decision-gate dry-run (USER CONFIRMATION REQUIRED)

**Files:** n/a (live Anthropic call)

**Dependencies:** Task B.2

**Important context:** This is the decision gate. We follow `docs/managed-agents-setup.md` steps 1–5 end-to-end using `curl` commands. Total cost: ≤ $0.60. If the dry-run completes inside 2 hours (timer starts when Step 1 is attempted), commit to the primary path and Task B.5 wires `ManagedAgentBriefingSource`. If ANY step fails or the wall-clock exceeds 2 hours, commit to the fallback path and Task B.5 wires `SynthesisBriefingSource`.

- [ ] **Step 1: Announce.** Output to the user: *"About to run the Managed Agents decision-gate dry-run per docs/managed-agents-setup.md. Creates one agent, one environment, one session, one ~20k-token message, then terminates. Cost ≤ $0.60. Starting the 2-hour decision-gate timer now. Proceed?"* Wait for yes.

- [ ] **Step 2: Run the curl sequence.** Note `DRY_RUN_START=$(date +%s)` first so we can measure. Follow steps 1 through 5 of `docs/managed-agents-setup.md`. Capture every response body.

- [ ] **Step 3: Evaluate outcome.** Three branches:
    - **All 5 curl steps succeed and agent.message is produced:** Primary path chosen. Proceed to Task B.4 primary branch.
    - **Step 1 or 2 fails with 403 / managed-agents-not-enabled:** Fallback path chosen. Proceed to Task B.4 fallback branch.
    - **Step 3 succeeds but step 4 shows no agent.message within 90 s:** Do NOT auto-retry. Output to the user: *"First session produced no agent.message within 90 s. Retrying would spend another ~$0.50. Options: (a) retry once more, (b) adjust the seed message to force an agent reply and retry, (c) accept this as fail and go to fallback. Which?"* — then wait for explicit greenlight. This preserves the plan's Critical-Constraint rule "DO NOT run more than the single dry-run Managed Agents session in Task B.3 without user confirmation."

- [ ] **Step 4: Write the decision record.** Append to `docs/managed-agents-setup.md`:

```markdown
## Decision record (2026-04-24)

- Dry-run wall-clock: XX minutes.
- Step 1 (agent create): <PASS/FAIL> — <brief note>
- Step 2 (env create): <PASS/FAIL> — <brief note>
- Step 3 (session create): <PASS/FAIL> — <brief note>
- Step 4 (agent.message produced): <PASS/FAIL> — <brief note>
- Step 5 (terminate): <PASS/FAIL> — <brief note>
- **Decision:** Primary (Managed Agents) / Fallback (BGProcessingTask synthesis).
- **Reason:** <sentence>
```

- [ ] **Step 5: Commit the decision record.**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon/ add docs/managed-agents-setup.md
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon/ commit -m "Overnight Phase B.3: Managed Agents dry-run decision record — <primary|fallback> chosen"
```

### Task B.4: Path-specific source implementations

Depending on the B.3 outcome, implement ONE of the two concrete `OvernightBriefingSource` types.

#### Task B.4a — Primary path: ManagedAgentBriefingSource (if B.3 PASSED)

**Files:**
- Create: `WakeProof/WakeProof/Services/ManagedAgentBriefingSource.swift`
- Create: `WakeProof/WakeProofTests/ManagedAgentBriefingSourceTests.swift`

- [ ] **Step 1: Create `ManagedAgentBriefingSource.swift`.**

```swift
//
//  ManagedAgentBriefingSource.swift
//  WakeProof
//
//  Primary-path OvernightBriefingSource. Wraps OvernightAgentClient.
//

import Foundation

actor ManagedAgentBriefingSource: OvernightBriefingSource {

    private let client: OvernightAgentClient
    private var sessionID: String?

    init(client: OvernightAgentClient = OvernightAgentClient()) {
        self.client = client
    }

    func planOvernight(sleep: SleepSnapshot, memoryProfile: String?) async throws -> String {
        let seed = buildSeedMessage(sleep: sleep, memoryProfile: memoryProfile)
        let handle = try await client.startSession(seedMessage: seed)
        self.sessionID = handle.sessionID
        return handle.sessionID
    }

    func pokeIfNeeded(handle: String, sleep: SleepSnapshot) async throws -> Bool {
        let sleepJSON: String = {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            guard let data = try? enc.encode(sleep),
                  let text = String(data: data, encoding: .utf8) else { return "{}" }
            return text
        }()
        try await client.appendEvent(sessionID: handle, text: "Fresh sleep data: \(sleepJSON)")
        return false  // not done yet; agent is still analysing
    }

    func fetchBriefing(handle: String) async throws -> (text: String, memoryUpdate: String?) {
        let rawText = try await client.fetchLatestAgentMessage(sessionID: handle) ?? ""
        return Self.parseAgentReply(rawText)
    }

    func cleanup(handle: String) async {
        try? await client.terminateSession(sessionID: handle)
    }

    // MARK: - Private

    private func buildSeedMessage(sleep: SleepSnapshot, memoryProfile: String?) -> String {
        var parts: [String] = []
        if let profile = memoryProfile, !profile.isEmpty {
            parts.append("<memory_profile>\n\(profile)\n</memory_profile>")
        }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(sleep), let text = String(data: data, encoding: .utf8) {
            parts.append("<sleep>\(text)</sleep>")
        }
        parts.append("Begin your analysis. I will send more events during the night. Produce the final briefing when ready, formatted as:\n\nBRIEFING: ...\nMEMORY_UPDATE: ...")
        return parts.joined(separator: "\n\n")
    }

    /// Parse the agent's reply looking for `BRIEFING:` and `MEMORY_UPDATE:` markers.
    /// Returns `("", nil)` if the input is empty or contains no briefing content
    /// — the scheduler's `fetchBriefing` path maps this to "no briefing available"
    /// so `MorningBriefingView` renders its fallback card instead of an empty one.
    static func parseAgentReply(_ text: String) -> (text: String, memoryUpdate: String?) {
        let briefingKey = "BRIEFING:"
        let memoryKey = "MEMORY_UPDATE:"
        guard let briefingRange = text.range(of: briefingKey) else {
            // No explicit marker: the whole text IS the briefing (Claude occasionally
            // drops markers despite the system prompt).
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed, nil)
        }
        let afterBriefing = text[briefingRange.upperBound...]
        let memoryRange = afterBriefing.range(of: memoryKey)
        let briefing = (memoryRange.map { String(afterBriefing[..<$0.lowerBound]) } ?? String(afterBriefing))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let memoryRaw: String? = memoryRange.map { r in
            String(afterBriefing[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let memoryUpdate = memoryRaw.flatMap { $0.uppercased() == "NONE" ? nil : $0 }
        return (briefing, memoryUpdate)
    }
}
```

- [ ] **Step 2: Tests.** Cover `parseAgentReply` extensively — 8 cases: full body with briefing + memory, briefing only, briefing + MEMORY_UPDATE: NONE, empty input, trailing whitespace, memory block with newlines, unknown marker ordering, body without any marker.

- [ ] **Step 3: Commit.**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon/ add \
  WakeProof/WakeProof/Services/ManagedAgentBriefingSource.swift \
  WakeProof/WakeProofTests/ManagedAgentBriefingSourceTests.swift
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon/ commit -m "Overnight Phase B.4a: ManagedAgentBriefingSource (primary path) + parseAgentReply tests"
```

#### Task B.4b — Fallback path: SynthesisBriefingSource (if B.3 FAILED)

**Files:**
- Create: `WakeProof/WakeProof/Services/SynthesisBriefingSource.swift`
- Create: `WakeProof/WakeProofTests/SynthesisBriefingSourceTests.swift`

- [ ] **Step 1: Create `SynthesisBriefingSource.swift`.**

```swift
//
//  SynthesisBriefingSource.swift
//  WakeProof
//
//  Fallback-path OvernightBriefingSource. Each BGProcessingTask wake-up runs
//  one synthesis call; the latest result is cached and returned at alarm time.
//  Handle is a synthetic UUID because there is no server-side session id.
//

import Foundation

actor SynthesisBriefingSource: OvernightBriefingSource {

    private let client: NightlySynthesisClient
    private var cache: [String: String] = [:]  // handle → latest briefing text

    init(client: NightlySynthesisClient = NightlySynthesisClient()) {
        self.client = client
    }

    func planOvernight(sleep: SleepSnapshot, memoryProfile: String?) async throws -> String {
        let handle = UUID().uuidString
        let briefing = try await client.synthesize(sleep: sleep, memoryProfile: memoryProfile, priorBriefings: [])
        cache[handle] = briefing
        return handle
    }

    func pokeIfNeeded(handle: String, sleep: SleepSnapshot) async throws -> Bool {
        let priorBriefings = cache[handle].map { [$0] } ?? []
        let briefing = try await client.synthesize(sleep: sleep, memoryProfile: nil, priorBriefings: priorBriefings)
        cache[handle] = briefing
        return true
    }

    func fetchBriefing(handle: String) async throws -> (text: String, memoryUpdate: String?) {
        return (cache[handle] ?? "No briefing prepared tonight.", nil)
    }

    func cleanup(handle: String) async {
        cache.removeValue(forKey: handle)
    }
}
```

- [ ] **Step 2: Tests.** Verify cache behaviour on poke, handle uniqueness, fetchBriefing fallback message when cache miss, cleanup removes entry.

- [ ] **Step 3: Commit.**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon/ add \
  WakeProof/WakeProof/Services/SynthesisBriefingSource.swift \
  WakeProof/WakeProofTests/SynthesisBriefingSourceTests.swift
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon/ commit -m "Overnight Phase B.4b: SynthesisBriefingSource (fallback path) + cache behaviour tests"
```

### Task B.5: Swap NoopBriefingSource for the chosen concrete source

**Files:**
- Modify: `WakeProof/WakeProof/App/WakeProofApp.swift`

**Dependencies:** Task B.4a OR B.4b (whichever landed)

- [ ] **Step 1: Delete the `noopSource` property.**

- [ ] **Step 2: Instantiate the chosen concrete source.** If primary:

```swift
    @State private var briefingSource = ManagedAgentBriefingSource()
```

If fallback:

```swift
    @State private var briefingSource = SynthesisBriefingSource()
```

- [ ] **Step 3: Wire into OvernightScheduler.** Replace the `source: noopSource` argument with `source: briefingSource`.

- [ ] **Step 4: Delete `NoopBriefingSource.swift`** if we're committed to one path. (If we keep it for tests or future-switch, add a doc comment explaining why.)

- [ ] **Step 5: Simulator build.**

- [ ] **Step 6: Commit.**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon/ add WakeProof/WakeProof/App/WakeProofApp.swift
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon/ commit -m "Overnight Phase B.5: swap NoopBriefingSource for <primary|fallback> path source"
```

### Task B.6: Compressed "night" device test (USER CONFIRMATION REQUIRED)

**Files:** n/a (live device test)

**Dependencies:** Task B.5

This is the hard-gate test for Layer 3. Full overnight isn't feasible during Day 4; we compress into a ~10-minute exercise that proves the architecture holds.

- [ ] **Step 1: Announce.** Output to the user: *"About to run the compressed 10-minute overnight-test flow on device. Creates a session, sends 2 simulated sleep-sample events spaced 2 min apart, then fetches the briefing. Cost estimate ~$0.50. Proceed?"* Wait for yes.

- [ ] **Step 2: Build + install on device.**

- [ ] **Step 3: Run the flow.** iOS schedules `BGProcessingTaskRequest` on a best-effort basis — actual wake-ups can happen immediately, hours later, or not at all within a compressed test window. Use the debug "Fire BGProcessing now" button (added for this test — see sub-step below) as the primary mechanism; don't rely on waiting.

    Add the debug button once: in `AlarmSchedulerView`, under `#if DEBUG`, add a small button wired to `BGTaskScheduler.shared.getPendingTaskRequests` + a manual `overnightScheduler.handleBackgroundRefresh` call for the pending request, OR simply call `overnightScheduler.handleBackgroundRefresh` with a mock `BGProcessingTask` fixture. A simpler path: expose a `debugTriggerRefresh()` method on `OvernightScheduler` that runs the refresh body without the `BGProcessingTask` wrapper, and invoke that from the button.

    Then on device:

    1. Enable bedtime for 2 min out in BedtimeSettings.
    2. Wait for the bedtime trigger → session opens.
    3. Tap the debug "Fire BGProcessing now" button — simulates refresh #1.
    4. Wait ~1 min, tap the button again — simulates refresh #2.
    5. Fire the alarm immediately via the existing `#if DEBUG` "Fire now" button. Capture → verify → VERIFIED.
    6. Expect the `MorningBriefingView` to appear with real briefing text.

- [ ] **Step 4: Record outcomes** in `docs/device-test-protocol.md`:

```markdown
### Test 17 — Compressed overnight (Layer 3)
Bedtime trigger → session open → 2 simulated pokes → alarm → briefing shown.
Pass: MorningBriefingView displays non-placeholder text; primary-path `sourceSessionID` non-nil (or fallback path's matches a synthetic handle). Total cost ≤ $0.80.
```

- [ ] **Step 5: Commit the device test appendix.**

**Phase B gate (HARD):** Test 17 PASSES. The briefing text displays on-device. No Day 3 regressions on Tests 9–13 (re-run Test 9 at minimum). Total Day 4 Layer 3 cost ≤ $5 so far. Full test suite green.

---

## Phase C — Review pipeline

Same pattern as Day 3 / Layer 2. Run `adversarial-review`, fix, `simplify`, fix, re-review until zero issues (or each remaining carries a "won't-fix + technical reason" disposition).

### Task C.1: adversarial-review

Focus prompts:
- **Stuck session billing:** a crashing iOS app between `startSession` and `cleanup` leaves a `running` session billing indefinitely. Is there a guard on app resume that terminates dangling sessions? Should be, via `UserDefaults` "com.wakeproof.overnight.activeHandle" + a cleanup-on-launch check.
- **BGProcessingTask budget leak:** iOS may silently cap background processing for an app that submits too many requests. Does `scheduleNextBackgroundRefresh` rate-limit itself?
- **SwiftData migration risk:** adding `MorningBriefing.self` to the `ModelContainer(for:)` list triggers lightweight migration. Does the user's existing store tolerate this? Tested on simulator; device flow may differ subtly. Re-test Day 3 flows after migration.
- **`agentID` / `environmentID` cache staleness:** if Anthropic invalidates a cached agent id (quota reset, account move), do we detect 404 on session create and auto-recreate?
- **Proxy wildcard auth on new routes:** the wildcard route forwards every `/v1/*` except `/v1/messages`. Does it accept `DELETE` / `PATCH` / `PUT` safely, or did we bake in `POST`-only assumptions?
- **Prompt injection via HealthKit notes:** HKSample metadata can carry a `"HKMetadataKeySleepAnalysisAsleepStage"` string. Does our serialisation escape untrusted strings that hit the agent's prompt?
- **Double-briefing race:** two rapid `verified → idle` transitions could both call `finalizeBriefing`. Does the scheduler guard against double-consume?

### Task C.2: simplify

Look for:
- `OvernightAgentClient`'s three similar HTTP wrappers (POST/GET/PATCH) — worth extracting the common body into a single helper vs. keeping them explicit for readability?
- `ManagedAgentBriefingSource.parseAgentReply` — the marker-based parser vs. requesting the agent to return JSON. JSON is a cleaner contract but we'd need to parse whatever the agent actually emits, which at the Managed Agents level could be free-form.
- `OvernightScheduler`'s error handling — many `try?` swallows that could surface more informatively.
- `NoopBriefingSource`: delete if Phase B.5 committed to a concrete source; keep as `PreviewBriefingSource` if useful for SwiftUI previews.

### Task C.3: Re-review loop

- [ ] Re-run `adversarial-review` on the simplified diff.
- [ ] Zero open issues (or all carry explicit won't-fix dispositions logged in `docs/plans/overnight-agent-findings.md`).
- [ ] Log the final state:

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon/ log --oneline origin/main..HEAD
```

**Phase C gate (HARD):** Zero open review issues. `Secrets.swift` untouched. `MorningBriefing` schema migrates cleanly on existing devices. Managed Agents sessions are terminated on app-close or next-launch. Full test suite green. Cumulative cost ≤ $10.

---

## Cross-phase dependency summary

```
Phase A (additive, both paths; zero runtime integration)
  A.0 plan commit
  A.1 Vercel wildcard proxy route ──┐
                                    │
  A.2 SleepSnapshot ──▶ A.3 HealthKitSleepReader
                                    │
                                    ▼
              A.4 MorningBriefing SwiftData model
                                    │
                        A.5 BedtimeSettings + onboarding step
                                    │
              ┌─────────────────────┼─────────────────────┐
              ▼                                           ▼
  A.6 NightlyPromptTemplate        A.8 OvernightAgentClient + setup doc
              ▼                                           ▼
  A.7 NightlySynthesisClient        (primary-path client ready)
              │                                           │
              └───────────────────┬───────────────────────┘
                                  ▼
              A.9 OvernightScheduler + OvernightBriefingSource protocol
                                  ▼
              A.10 MorningBriefingView
                                  ▼
              A.11 Info.plist (BGTask identifier + processing mode)
                                  ▼
              A.12 full test sweep ── HARD GATE ──▶

Phase B (decision gate + chosen-path wiring)
  B.1 wire OvernightScheduler with NoopBriefingSource placeholder
                                  ▼
                        B.2 onboarding BedtimeStep integration
                                  ▼
                     B.3 Managed Agents dry-run ── DECISION ──▶
                                  ▼
              ┌─────────────────── B.4 path-specific source ───────────────┐
              ▼                                                            ▼
  B.4a ManagedAgentBriefingSource                              B.4b SynthesisBriefingSource
              │                                                            │
              └──────────────────────────┬─────────────────────────────────┘
                                         ▼
                          B.5 swap Noop for chosen source
                                         ▼
                    B.6 compressed-night device test ── HARD GATE ──▶

Phase C (review pipeline)
  C.1 adversarial-review ──▶ fix ──▶ C.2 simplify ──▶ fix ──▶ C.3 re-review ──▶ HARD GATE
```

## Pivot triggers

| Condition | Action |
|---|---|
| Phase A simulator build fails | Stop. Fix before next task. |
| A.1 `vercel --prod` fails | Diagnose the wildcard route file's routing ambiguity. If the `messages.js` route suddenly breaks, revert A.1 entirely and reconsider single-catch-all shape. |
| Day 3 or Layer 2 tests regress at any Phase A task | Back out the most recent edit. Layer 3 must not regress earlier layers. |
| B.3 dry-run exceeds the 2-hour gate | Abandon primary path. Phase B.4b + B.5 pick fallback. Document in the decision record. |
| B.3 cost exceeds $2 during dry-run iterations | STOP. Multiple sessions spawning. Audit `OvernightAgentClient.terminateSession` usage. |
| B.6 device test shows no briefing text | If primary path: confirm the agent produced an agent.message (Anthropic console); if yes, parser regressed; if no, the seed message's "produce briefing when ready" framing is too weak — retest with stronger phrasing. If fallback path: NightlySynthesisClient failed; inspect logs. |
| `MorningBriefing` schema migration fails on existing device | Revert A.4's ModelContainer change and add the model behind a separate storage configuration. |
| `Secrets.swift` appears in a diff | Same recovery as Day 3 / Layer 2. Immediate hard-stop. |

## Out of scope for this plan

- Real SSE streaming for session events (would require a non-Vercel-Hobby host)
- Agent Memory Stores (Research Preview)
- Multi-night session continuity using the 30-day checkpoint window
- Per-event tracing UI in-app (Day 5 polish)
- Retry / resubmit of failed BGProcessingTask runs (today we log and move on)
- HealthKit write-back (we only read)
- Bedtime reminder push notification (Day 5 polish)
- Agent tool definitions beyond Python runtime (e.g., web search, custom tools)
- Sharing briefing history across installs of the app

Day numbers from `docs/build-plan.md` are reference only; advance when gates pass.
