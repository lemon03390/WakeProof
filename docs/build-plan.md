# WakeProof — 5-Day Compressed Build Plan

> **Reality check:** Hackathon started Apr 21, 12:00 PM EDT. Vincent received approval ~14 hours late and is in HKT (EDT+12). Effective build window is Apr 22 evening HKT through Apr 27 8:00 AM HKT.

---

## Timezone Cheat Sheet

| Event | EDT | HKT |
|---|---|---|
| Hackathon start | Apr 21 12:00 PM | Apr 22 12:00 AM |
| **Submission deadline** | **Apr 26 8:00 PM** | **Apr 27 8:00 AM** |
| First round judging | Apr 27 all day | Apr 27 evening – Apr 28 morning |
| Final judging + closing | Apr 28 12:00 PM – 12:45 PM | Apr 29 12:00 AM – 12:45 AM |

### Live Sessions (most are 12 AM HKT — late night for Vincent)
- **Apr 23 12:00 AM HKT** (Wed): Thariq Shihipar AMA (Claude Code) — *recommended live*
- **Apr 23 11:00 PM HKT** (Thu): Michael Cohen on **Claude Managed Agents** — *MUST WATCH for $5k special prize*
- **Apr 25 12:00 AM HKT** (Fri): Mike Brown 4.6 winner retrospective
- **Apr 27 12:00 AM HKT** (Sun): Michal Nedoszytko 4.6 3rd place retrospective

Office hours daily 5–6 AM HKT — skip live, watch any recordings posted.

---

## Day-by-Day Plan

### Day 1 — Apr 22 (Wed HKT) — Foundation & Go/No-Go
**Effective hours: ~8h (evening only)**

**Morning admin (~1h):**
- [ ] Confirm Discord access via https://anthropic.com/discord
- [ ] Get hackathon role assigned, confirm channel visibility
- [ ] Read all `#announcements` pinned messages
- [ ] Watch kickoff recording if posted
- [ ] Claim $500 API credits, store key in `.env` (NOT TCM Pro key)
- [ ] Create new GitHub repo `wakeproof` — public, MIT license, README skeleton

**Build (~7h):**
- [ ] **GO/NO-GO TEST:** Create minimal Swift project, test foreground audio session keeping app alive 30+ min with screen locked. If this fails on real device, pivot strategy immediately.
- [ ] Set up Xcode project, SwiftUI structure
- [ ] Write `CLAUDE.md` for the repo (Claude Code context)
- [ ] Build permission onboarding flow:
  - Notifications (with critical alert request — likely denied, that's OK, document the ask)
  - Camera
  - HealthKit (read sleep data)
  - Motion & Fitness
  - Background audio (Info.plist `UIBackgroundModes`)
- [ ] Baseline photo capture screen with location label

**End of day deliverable:** App launches, walks through 5 permission requests, captures and saves a baseline photo locally. Audio session test passed.

**Discord:** Post intro to `#introductions`. React to 5+ other intros. Look for iOS-native potential teammate.

---

### Day 2 — Apr 23 (Thu HKT) — Alarm Core + Opus 4.7 Strategy Research
**Effective hours: ~10h**

**Build (alarm core):**
- [ ] Alarm scheduling UI (set wake window: e.g., 6:30–7:00 AM)
- [ ] Foreground audio session loop — silent audio at night, alarm sound when triggered
- [ ] Alarm escalation logic (volume ramps, sound switches)
- [ ] Alarm trigger → auto-launch camera screen
- [ ] Live photo / short video capture (2 sec)
- [ ] Local storage of attempts

**Research (Opus 4.7 feature inventory — see `docs/opus-4-7-strategy.md`):**
- [ ] Read Anthropic docs on **Memory Tool** — confirm the write-during-agent-run pattern works; confirm file-system semantics; confirm how memory files are injected at call time (required for Layer 2 of the strategy)
- [ ] Read Anthropic docs on **Task Budgets** — confirm minimum/maximum durations, pricing model, whether 8h overnight budget is expressible cleanly (required for Layer 3)
- [ ] Read Anthropic docs on **Claude Managed Agents** — understand hosting constraints, invocation model, observability (required for Layer 3)

**Late night (11 PM HKT):**
- [ ] **MUST WATCH:** Michael Cohen Live Session on Claude Managed Agents
- [ ] **Layer 3 commit/back-out decision** (see `docs/opus-4-7-strategy.md` for criteria) — if Managed Agents setup looks achievable in Day 4's window, Day 4 goes all-in on Layer 3. Otherwise Layer 3 degrades to a periodic local task and Layer 4 (weekly coach) takes the demo spotlight.

**End of day deliverable:** Set alarm → it rings on real device → camera opens → photo captured and saved. No verification yet. Opus 4.7 Layer 3 decision locked.

**Discord:** Post day-1 progress in `#show-and-tell` or build-log channel. Short, with screenshot.

---

### Day 3 — Apr 24 (Fri HKT) — Layer 1 (High-Res Vision + Self-Verification)
**Effective hours: ~10h**

**Build:**
- [ ] Photo upload pipeline (Claude API, direct from app — no Supabase unless sync becomes demo-relevant)
- [ ] **Core verification prompt** — per `docs/opus-4-7-strategy.md` Layer 1. Key non-negotiables:
  - [ ] Ship **full 3.75 MP / 2576px** photo (no downsizing). If this blows the token budget, investigate `image_detail=high` parameter before compressing.
  - [ ] Structured JSON output with `same_location / person_upright / eyes_open / appears_alert / lighting_suggests_room_lit / confidence / reasoning / verdict`.
  - [ ] **Self-verification chain** in prompt: instruct the model to list 3 plausible spoofing methods (photo-of-photo, mannequin, deepfake), verify each is ruled out, and only then return verdict. This is the 4.7-specific differentiator, not a nice-to-have.
- [ ] UI states: "Verifying..." (alarm volume reduces but not muted), Pass (alarm stops), Fail (alarm continues + retry prompt)
- [ ] Fail-handling: timeout fallback, retry counter
- [ ] Random action prompt (anti-spoofing): "Blink twice", "Show your right hand" — verify via Opus 4.7

**Test loop:**
- [ ] Test with 5 baseline scenarios (kitchen morning, kitchen night, bathroom, fake "in bed" attempt to verify rejection)
- [ ] Tune prompt for accuracy and latency
- [ ] Confirm self-verification chain catches a printed-photo attack (this is the demo money shot)

**End of day deliverable:** End-to-end flow works on device. Set alarm → rings → photo → Opus 4.7 verifies (high-res + self-verification chain) → alarm stops or continues based on result.

**Discord:** Post a short video of the working core loop. This is your most shareable moment so far.

---

### Day 4 — Apr 25 (Sat HKT) — Layer 2 + Layer 3 (Memory + Overnight Agent)
**Effective hours: ~12h**

The previous "pick one of Option A/B/C" branching has been pre-empted. Day 2's research + decision (see `docs/opus-4-7-strategy.md`) determines the split below. This plan assumes the Layer 3 commit went through; the fallback branch is at the end of the section.

**Morning — Polish + Layer 2 (Memory Tool):**
- [ ] HealthKit integration: read last night's sleep data (use Vincent's own Apple Watch if available)
- [ ] Show "last night's sleep summary" on dismiss screen
- [ ] Onboarding polish: clear copy, smooth transitions
- [ ] Visual design pass (colors, typography, dark mode for nighttime)
- [ ] Error states: no internet, API timeout, camera failure
- [ ] **Layer 2 (Memory Tool):** add per-user memory file that Claude reads before verification and writes after. Seed with a few synthetic mornings so demo shows personalization kicking in on the first live run.

**Afternoon — Layer 3 (Managed Agent overnight pipeline):**
- [ ] Provision the Managed Agent (per Day 2 research)
- [ ] Define the overnight task: ingest HealthKit scratchpad → analyze pattern against Layer 2 memory file → prepare morning briefing text → pre-compute tonight's expected wake-location lighting profile
- [ ] Wire iOS app to trigger the agent at sleep-start and pull its prepared output at alarm-time
- [ ] Verify with a simulated overnight run (compressed timeline, 10-min fake "night") that the agent produces useful output end-to-end — this is the live demo path for the video

**Layer 4 (Weekly Coach) — mocked for demo, not live-scheduled:**
- [ ] Seed 14 days of synthetic wake-attempt data (varied patterns — one strong pattern to make the insight land)
- [ ] Single Opus 4.7 call with 1M context: give it all 14 days + memory file, ask for one tasteful coaching insight
- [ ] Display in UI as "This week's insight" panel

**End of day deliverable:** App feels like a real product. Four-layer Opus 4.7 stack is observable in demo flow.

**Fallback if Layer 3 Managed Agent setup doesn't land:** degrade to a local periodic task (iOS `BGProcessingTaskRequest`) that calls the regular Messages API synchronously with the same overnight prompt. The "four layers" narrative still holds in the demo; only the "long-horizon agentic" framing weakens slightly.

---

### Wave 5 — Apr 24–25 (Thu–Fri HKT) — Hooked-derived engagement + final defense pass

Ran concurrent with the Day 4 Layer 2/3/4 work, scoped + tracked via `docs/self-sabotage-defense-analysis.md` §12. 8 commits (`14a758e` → `e67fda7`, Wave 5 items + Stage 8 review fixes). All 7 items in §12.2 processing order shipped; tests 366/0 at end of Stage 8.

**Why this wave exists:** §§1–11 of the self-sabotage doc framed WakeProof purely through defense (remove escape hatches). Hooked supplies the dual — build the *pull* so evening-self wants the contract, not just tolerates it. A contract the user dreads is brittle; one they look forward to is a habit.

**What shipped:**

| # | Item | Commit | Substance |
|---|------|--------|-----------|
| 1 | H1 — Variable Insight | `14a758e` | Opus 4.7 vision call now returns an optional `observation` string (30–60 char, specific). Layer 1 extension — see `docs/opus-4-7-strategy.md`. |
| 2 | H2 — Commitment note + reveal | `d048476` | Optional ≤60-char pre-sleep note; revealed in large type on MorningBriefingView. Absorbs G6 — see `docs/technical-decisions.md` Decision 9. |
| 3 | G3 — Chained backups | `b7645f5` | Backup notifications at +0/+90/+180s with distinct body copy. Hardens force-quit narrative. |
| 4 | H3 — Streak + calendar | `5c91a9f` | `StreakService` derived from WakeAttempt rows; badge + month grid. No new @Model. |
| 5 | H4 — Investment dashboard | `e7c301d` | "Your commitment" surface — baseline age, verified wakes, Opus insights count, framing line. Pure SwiftData query. |
| 6 | H5 — Share card | `65b01ea` | 1080×1920 `ImageRenderer` card with streak + observation, `ShareLink` export. Opt-in via settings toggle. |
| 7 | G1 — Disable gating | `c9ab7b3` | New `.disableChallenge` phase. Toggling alarm OFF post-grace requires the same Claude-verified photo as morning dismissal. 24h grace for new users + DEBUG bypass for demo recording. |
| 8 | Stage 8 review fixes | `e67fda7` | 7 findings from parallel code-reviewer + silent-failure-hunter (2 CRITICAL + 3 IMPORTANT + 2 MEDIUM) — all addressed. Round 2 sanity pass: 0 regressions. |

**Scoped out in Wave 5 (§12.5):** G6 absorbed into H2; G7 (memory integrity HMAC), G10 (Live Activity), G4 (full-screen blocker), G8 (uninstall friction) — post-hackathon.

**Demo value:** Layer 1's H1 observation + the H2 commitment reveal are now the emotional climax of the morning flow. G1 is the feature a reviewer will remember ("can you just disable it? — the app asks you to prove you're awake to stop the proof requirement"). H3/H4 surface the invisible switching cost that makes H1/H2/H5 load-bearing.

**Tests:** 366 passing / 0 failing at end of Wave 5 + Stage 8 (baseline was 296 at wave start — Δ+70 net).

---

### Day 5 — Apr 26 (Sun HKT) — Demo & Submission
**Effective hours: ~14h, hard deadline at 8:00 AM Apr 27 HKT**

**Morning — Final build freeze:**
- [ ] Lock features. NO new code unless fixing broken thing.
- [ ] Run full demo flow 5 times end-to-end. Fix any breaks.
- [ ] Clean up repo: README, install instructions, screenshots, demo gif
- [ ] Add open source license (MIT)
- [ ] Add `CLAUDE.md` documenting Claude Code usage in project

**Afternoon — Demo video (3 min max):**
- [ ] Write script (see template below)
- [ ] Record on real device + screen recording
- [ ] Edit in iMovie / Descript / similar
- [ ] Upload to YouTube unlisted or Loom
- [ ] Test playback link

**Demo video structure (3 min):**
- 0:00–0:20 — Hook: "What if your alarm could tell when you're lying about being awake?"
- 0:20–0:50 — The problem: snooze hell, dismissed alarms, real cost
- 0:50–2:10 — Live demo on device: set alarm → ring → photo → Opus 4.7 verifies → result
- 2:10–2:40 — **Four-layer Opus 4.7 diagram** (see `docs/opus-4-7-strategy.md`): on-screen rectangles labelled Vision / Memory / Agent / Coach, each with its 4.7-specific capability tag. Narration uses the key line verbatim: *"WakeProof uses Opus 4.7 not as a single API call, but as four layers: real-time high-res vision for verification, persistent memory for personalization, an overnight managed agent for sleep analysis, and a weekly coaching loop. Each layer uses a capability that only 4.7 unlocks."*
- 2:40–3:00 — Vision: this is a self-commitment device for any high-stakes habit, not just waking up

**Evening — Written summary (100–200 words):**

Draft template:
> WakeProof is an iOS alarm that uses Claude Opus 4.7 vision to verify you're actually out of bed — not just dismissing a notification. Users take a baseline photo at a designated awake-location during onboarding (kitchen, bathroom). When the alarm rings, the only way to silence it is to take a new live photo: Opus 4.7 verifies same-location, eyes-open, alert-posture, and runs random anti-spoofing prompts ("blink twice"). Failed verification keeps the alarm escalating.
>
> Beyond the core mechanic, Opus 4.7 generates personalized morning briefings from the night's HealthKit data and produces weekly coaching insights from accumulated wake-up patterns.
>
> WakeProof reframes the alarm from a passive notification into a self-commitment device. Future-you can't cheat past-you's contract. The mechanic generalizes beyond sleep: medication adherence, gym accountability, study sessions — anywhere intent-action gaps need third-party verification.
>
> Built solo over 5 days. iOS native (Swift/SwiftUI), Claude Opus 4.7 API, Supabase. Open source under MIT.

[Adjust word count after writing — currently ~190 words.]

**Final hour — Submit:**
- [ ] Demo video link ✓
- [ ] GitHub repo link ✓ (public, license added, README complete)
- [ ] Written summary ✓ (100–200 words verified)
- [ ] Submit via CV platform link from Discord
- [ ] **Hard cutoff: Apr 27 8:00 AM HKT (Apr 26 8:00 PM EDT)**

---

## Universal Risk Mitigations

### If foreground audio session fails (Day 1)
**Pivot:** Reframe as "verification companion" — user uses iOS Clock for alarm sound, WakeProof launches via Shortcuts automation when Clock alarm dismisses. Demo this hybrid flow.

### If Opus 4.7 vision is too slow (Day 3)
**Pivot:** Use Sonnet for first-pass, Opus only for confidence-scoring edge cases. Document this as cost-optimization architecture decision.

### If solo dev pace is too slow
**Action:** Day 2 evening = decision point. If core alarm + camera not done, post in `#find-a-teammate` Discord with clear ask: "Need iOS dev for 4 days, will share submission credit."

### If running out of API credits
**Action:** Switch all non-vision Claude calls to Sonnet. Batch test runs. Use mock responses during UI iteration.

---

## Daily Discipline

**Every morning (Vincent's local 9 AM HKT):**
- Check `#announcements` for overnight changes
- Check `#show-and-tell` for what others are building (calibrate ambition)

**Every evening (before sleep):**
- Push code to GitHub
- Post short progress update to build-log channel
- Write tomorrow's top 3 priorities

**No-no list:**
- Do not refactor TCM Pro habits onto this codebase
- Do not add features not in this plan without dropping something else
- Do not aim for App Store readiness — TestFlight or Xcode-direct install is fine for demo
- Do not stay up so late that Day N+1 is wrecked
