# WakeProof — Opus 4.7 Usage Strategy

> Source of truth for how WakeProof uses Claude Opus 4.7. Targets the hackathon's "Creative use of Opus 4.7" 25% judging criterion and the **Most Creative Opus 4.7 Exploration ($5k)** special prize. Written 2026-04-22.

## Framing: why a single vision call is a trap

The judging criterion scores "creative use of Opus 4.7" — not "use of any vision model". If WakeProof's Opus 4.7 footprint is one `POST /v1/messages` with a photo attached, a reviewer sees no reason to prefer 4.7 over 4.6. The 25% category flatlines.

### Tiered thinking

| Tier | Example | Expected score |
|---|---|---|
| **Tier 1 (Boring)** | Single-shot `"describe this photo"` vision call. Plain text insight generation. One-prompt everything. | Low — nothing 4.6 wouldn't also do. |
| **Tier 2 (Solid)** | High-resolution vision used end-to-end (no downsizing). Structured JSON output leveraging 4.7's strict instruction following. Multi-factor verdict decision. | Competent. Judges see 4.7's reliability without feeling its ceiling. |
| **Tier 3 (Creative)** | Memory tool, task budgets, long-horizon agents, self-verification chains — features that only 4.7 reliably unlocks. | Target zone. Eligible for special prizes. |

**WakeProof commits to Tier 3 via a four-layer stack.** Each layer uses a capability the 4.7 release notes explicitly highlight.

---

## The Four-Layer Stack

### Layer 1 — Real-time vision verification (every alarm)

**Capability exploited:** high-resolution vision input + strict JSON instruction following + self-verification chain-of-thought.

**Design points:**
- Ship the full 3.75 MP / 2576px photo — **do not downsize**. The entire point of 4.7 over 4.6 is micro-detail resolution: pupil dilation, eyelid droop, micro-expression. Demo value collapses if we pre-compress.
- Prompt requests structured JSON with per-dimension booleans (same_location, person_upright, eyes_open, appears_alert, lighting_suggests_room_lit), confidence score, and free-text reasoning.
- **Self-verification chain:** prompt instructs the model to list 3 plausible spoofing methods (photo-of-photo, mannequin, deepfake), verify each is ruled out, and only then return a verdict. This exploits 4.7's improved ability to verify its own outputs before committing.

**Why 4.6 doesn't fit:** 4.6 at the same resolution tends to drop detail when parsing + reasoning + JSON-formatting simultaneously. 4.7's instruction following is measurably tighter for this workload — judges can feel the difference in demo latency and accuracy.

**Demo narrative:**
> "We require high-resolution vision because 4.6-level resolution cannot distinguish 'eyes-open-but-drowsy' from 'eyes-open-alert'. 4.7 makes this mechanic possible."

---

### Layer 2 — Persistent user memory (cross-session personalization)

**Capability exploited:** Claude's file-system-based **Memory Tool** (better in 4.7).

**Design:**
- Maintain a per-user memory file Claude reads + writes every morning:
  - Verification history (pass/fail counts, typical retry count, typical time-to-pass)
  - Scene-specific patterns ("user's kitchen at 6am has insufficient lighting in winter")
  - Behavioral patterns ("eyes take longer to open on Mondays", "weekend verifications 40% slower")
- After enough mornings, Claude's calibration of this specific user's wake-up pattern becomes the product's moat. Not a training pipeline, not a recommender system — a persistent agent memory file.

**Demo narrative:**
> "After 5 days of use, Claude knows this user's wake-up pattern better than any pre-coded algorithm could. We didn't build a training loop. Opus 4.7's memory tool did it for us."

**Why this beats a regular database:** the memory is Claude-authored and Claude-consumed. The retrieval is semantic, not keyed. No ML engineering overhead.

---

### Layer 3 — Overnight long-horizon agent (double-targets the Managed Agents prize)

**Capability exploited:** Claude Managed Agents + task budgets + long-horizon agentic work. This layer also targets the **Best use of Claude Managed Agents ($5k)** special prize — same code, two prize categories.

**Design:**
- At sleep-time, launch a Managed Agent with a task budget sized for the full sleep window.
- During the night, agent does:
  1. Ingests HealthKit sleep signals (via API-writeable scratchpad the iOS app populates periodically)
  2. Analyzes pattern against user's memory file from Layer 2
  3. Prepares a morning briefing text tailored to last night's sleep quality
  4. Pre-computes the expected lighting profile for tonight's wake-location baseline (accounting for sunrise time + weather forecast)
- At alarm time, the iOS app pulls the agent's prepared context — no latency in morning flow because the agent did the work overnight.

**Why 4.7 specifically:** task budgets + long-horizon agent stability are 4.7 release features. 4.6 agents at this duration tend to degrade or exit early.

**Demo narrative:**
> "Opus 4.7 is working while the user sleeps. By the time the alarm rings, the agent has already done the analysis and prepared the morning briefing."

---

### Layer 4 — Weekly coach (1M context window)

**Capability exploited:** 1M context window for knowledge work.

**Design:**
- Every Sunday night, a single 4.7 call is given the full raw data of the past week (all verification photos as metadata, all HealthKit samples, all memory-file entries) — potentially 200K+ tokens — and asked to produce a single coaching report.
- The report is not a dashboard; it is a piece of tasteful written insight. Claude's strength in one-shot knowledge work shows here because nothing has to be pre-aggregated.

**Why 4.7 specifically:** 1M context lets the model reason over the whole week without RAG or summarization passes that would lose nuance.

---

## Demo video key line

Memorable, quotable, fits under 15 seconds:

> *"WakeProof uses Opus 4.7 not as a single API call, but as four layers: real-time high-res vision for verification, persistent memory for personalization, an overnight managed agent for sleep analysis, and a weekly coaching loop. Each layer uses a capability that only 4.7 unlocks."*

Follow with a quick on-screen diagram: four stacked rectangles labelled Vision / Memory / Agent / Coach, each with a 4.7-specific capability tag.

---

## Build-plan implications

This strategy changes the back half of the sprint. See `docs/build-plan.md` for the updated Day 2–5 content. In summary:

- **Day 2:** in addition to the previously-planned alarm core, reserve research time for the Memory Tool docs and Task Budget docs; commit to or back out of Layer 3 before Day 3 starts.
- **Day 3:** the core verification prompt (Layer 1) must be built for high-resolution input and include the self-verification chain. Do not downsize images. Structured JSON with per-dimension booleans, not prose.
- **Day 4:** the "pick A / B / C stretch" decision is pre-empted. Day 4 is now **all-in on Layer 3 (Managed Agent overnight pipeline)**. Layer 4 (weekly coach) is a mocked demo, not a live scheduled job — seed 14 days of fake data and generate one genuinely good insight.
- **Day 5:** demo video must visually show the four-layer diagram. Submission copy uses the "four layers" key line verbatim.

## Budget & risk

- Cost per verification call (Layer 1): ~$0.013 (per Decision 2 projections). Four-layer stack with 1 user = roughly $2–5 of the $500 credit budget per day. Not a constraint.
- Layer 3 failure mode: if Managed Agents onboarding takes >8 hours on Day 4, fall back to `launchctl`-style periodic local task that calls the regular API synchronously. The 4-layer framing still holds; only "long-horizon agentic" is weakened.
- Layer 4 failure mode: if 1M context is slow or unreliable for this specific workload, fall back to a chunked summarisation pipeline — narrative stays intact.

## Open questions

- [ ] Does the Memory Tool docs released with 4.7 support the write-during-agent-run pattern Layer 2 needs, or is it read-only within a single conversation?
- [ ] Task budget minimum for overnight agent — can we express an 8h budget cleanly, or do we need to chunk?
- [ ] Managed Agents pricing — flat rate on budget, or token-metered? Could affect $500 credit burn.

Research these during Day 2 Anthropic docs pass + Michael Cohen live session (Apr 23 11 PM HKT).
