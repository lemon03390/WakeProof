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

### Day 2 — Apr 23 (Thu HKT) — Alarm Core
**Effective hours: ~10h**

**Build:**
- [ ] Alarm scheduling UI (set wake window: e.g., 6:30–7:00 AM)
- [ ] Foreground audio session loop — silent audio at night, alarm sound when triggered
- [ ] Alarm escalation logic (volume ramps, sound switches)
- [ ] Alarm trigger → auto-launch camera screen
- [ ] Live photo / short video capture (2 sec)
- [ ] Local storage of attempts

**Late night (11 PM HKT):**
- [ ] **MUST WATCH:** Michael Cohen Live Session on Claude Managed Agents
- [ ] Decide: can WakeProof use a Managed Agent for overnight sleep analysis pipeline? If yes → unlocks $5k special prize path

**End of day deliverable:** Set alarm → it rings on real device → camera opens → photo captured and saved. No verification yet.

**Discord:** Post day-1 progress in `#show-and-tell` or build-log channel. Short, with screenshot.

---

### Day 3 — Apr 24 (Fri HKT) — Opus 4.7 Vision Verification
**Effective hours: ~10h**

**Build:**
- [ ] Backend setup: Supabase project (or skip Supabase, use direct Claude API from app)
- [ ] Photo upload pipeline (base64 to Claude API)
- [ ] **Core verification prompt** for Opus 4.7 vision:
  - Same location as baseline?
  - Person standing / upright?
  - Eyes open?
  - Lighting suggests room lights are on?
  - Confidence score
- [ ] UI states: "Verifying..." (alarm volume reduces but not muted), Pass (alarm stops), Fail (alarm continues + retry prompt)
- [ ] Fail-handling: timeout fallback, retry counter
- [ ] Random action prompt (anti-spoofing): "Blink twice", "Show your right hand" — verify via Opus 4.7

**Test loop:**
- [ ] Test with 5 baseline scenarios (kitchen morning, kitchen night, bathroom, fake "in bed" attempt to verify rejection)
- [ ] Tune prompt for accuracy and latency

**End of day deliverable:** End-to-end flow works on device. Set alarm → rings → photo → Opus 4.7 verifies → alarm stops or continues based on result.

**Discord:** Post a short video of the working core loop. This is your most shareable moment so far.

---

### Day 4 — Apr 25 (Sat HKT) — Polish & Stretch Features
**Effective hours: ~12h**

**Morning — Polish:**
- [ ] HealthKit integration: read last night's sleep data (use Vincent's own Apple Watch if available)
- [ ] Show "last night's sleep summary" on dismiss screen
- [ ] Onboarding polish: clear copy, smooth transitions
- [ ] Visual design pass (colors, typography, dark mode for nighttime)
- [ ] Error states: no internet, API timeout, camera failure

**Afternoon — Stretch Picks (do max 1 of these):**
- [ ] **Option A:** Mocked weekly analytics dashboard with Opus 4.7-generated insight (seed 14 days fake data, generate one good insight) — solid but expected
- [ ] **Option B:** Claude Managed Agents integration — if Day 2 research confirmed feasibility, build a Managed Agent that processes the night's data + generates morning briefing — targets $5k special prize
- [ ] **Option C:** Screen Time API "strict mode" — block other apps until verified — most impressive but highest risk

**Recommended:** Option B if doable, Option A if not.

**End of day deliverable:** App feels like a real product. Has a "wow moment" beyond core flow.

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
- 0:50–2:15 — Live demo on device: set alarm → ring → photo → Opus 4.7 verifies → result
- 2:15–2:40 — How Opus 4.7 powers it (vision + reasoning + insight generation)
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
