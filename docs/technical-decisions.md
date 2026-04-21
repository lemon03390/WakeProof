# WakeProof — Technical Risks & Decisions Log

> Reference doc for architectural and scope trade-offs. When facing a build decision during the sprint, check here first to avoid re-litigating settled questions.

---

## Decision 1: iOS Alarm Architecture

### Constraint
iOS has **no public Alarm API**. Apple's built-in Clock app uses private frameworks unavailable to third-party apps. Third-party "alarms" are always a workaround.

### Workaround chosen
**Foreground audio session + critical alert notifications**, Alarmy-style.
- App must keep audio session alive overnight (silent audio loop)
- When alarm time hits, switches audio buffer to alarm sound
- Critical alert notification fires in parallel (bypasses silent mode if entitlement granted)
- User must keep app foregrounded or in recent task before sleep

### Rejected alternatives
| Alternative | Why rejected |
|---|---|
| Hijack iOS Clock dismiss | Sandbox prevents intercepting other apps' UI |
| Pure local notification | 30 sec sound limit, easily dismissed |
| Push notification trigger | Requires server, unreliable wake at exact time |
| Background processing tasks | iOS aggressively kills them, can't guarantee firing |

### Demo-day framing
"WakeProof creates a wake-up contract you can't unsign. Apple's Clock can be muted in 2 seconds — WakeProof can't. Here's how."

### Risk if this fails Day 1 test
Pivot to Shortcuts automation + WakeProof verification layer. User dismisses iOS Clock, Shortcuts auto-launches WakeProof, which then runs verification before allowing notification permanent dismissal.

---

## Decision 2: Photo Verification Strategy

### Layered approach
1. **Baseline capture** during onboarding at user-designated awake-location (kitchen, bathroom)
2. **Wake-time capture** as live photo or 2-sec video
3. **Pre-flight on-device check** (optional Day 4): basic face detection via iOS Vision framework
4. **Opus 4.7 vision verification** with structured prompt
5. **Random anti-spoofing prompt** for retries: "blink twice", "show right hand"

### Opus 4.7 verification prompt structure
```
You are verifying that a user is awake and out of bed for a wake-up accountability app.

BASELINE PHOTO: User's reference photo taken in their designated wake location.
NEW PHOTO: Just captured. User is required to be in the same location, standing, eyes open, alert.

Analyze and return JSON:
{
  "same_location": true/false,
  "person_upright": true/false,
  "eyes_open": true/false,
  "appears_alert": true/false,
  "lighting_suggests_room_lit": true/false,
  "confidence": 0.0-1.0,
  "reasoning": "brief explanation",
  "verdict": "VERIFIED" | "REJECTED" | "RETRY"
}

VERIFIED requires all booleans true and confidence > 0.75.
RETRY if person is in correct location but not standing or eyes barely open.
REJECTED if location wrong or appears to be photo-of-photo.
```

### Known failure modes & mitigations
| Failure mode | Mitigation |
|---|---|
| User shows photo of baseline (spoofing) | Random action prompt + 2-sec video for liveness |
| Baseline lighting differs from morning lighting | Onboarding instructs morning capture at expected wake time |
| User changes clothes, hair messy | Verification focuses on location + alertness, not identity match |
| API latency 3–8 sec | Reduce volume during verifying, don't mute; timeout 15 sec → retry |
| API failure (no internet) | Local fallback: face detection + motion check, log for review |

### Cost projection (rough)
- Vision call: ~1500 input tokens (2 images encoded) + ~200 output = $5/MTok input + $25/MTok output
- Per verification ≈ $0.013
- $500 credits ÷ $0.013 = ~38,000 verifications worth of headroom
- **Verdict:** vision cost is not a constraint. Use Opus 4.7 freely.

---

## Decision 3: Sleep Tracking — Scope Cut

### Reality
Real sleep stage detection (deep / REM / light) requires polysomnography or, at consumer level, an Apple Watch with months of trained ML. iPhone alone cannot do this accurately in a 5-day build.

### What we WILL do
- **HealthKit read-only:** if user has Apple Watch sleep data, display it in dashboard
- **Wake window detection:** user sets a window (e.g., 6:30–7:00). Within that window, app monitors accelerometer for "natural awakening signals" (micro-movements indicating lighter sleep). Triggers alarm at first detected stir, or at end of window if none.

### What we WON'T do
- Claim to detect sleep stages from iPhone alone
- Build adaptive learning of alarm sounds (needs months of data)
- Run microphone overnight (battery drain + privacy concern)

### Demo-day framing
"WakeProof doesn't claim clinical sleep staging. It detects your natural awakening window and times your alarm to a moment when you're already drifting toward consciousness. Opus 4.7 learns your personal pattern over time."

---

## Decision 4: Tech Stack

### Locked decisions
- **Frontend:** Swift + SwiftUI (NOT React Native — RN bridges for HealthKit/audio session/Screen Time are unreliable for a 5-day build)
- **Storage:** Local first (SwiftData or simple file storage). Add Supabase only if multi-device sync becomes demo-relevant.
- **AI:** Claude Opus 4.7 for vision verification + insight generation. Claude Sonnet 4.6 for any non-critical text generation to save credits.
- **Repo:** GitHub public, MIT license

### Why no Supabase by default
- Hackathon rule: must be all open source. Supabase project introduces config complexity for judges who want to run repo locally.
- Single-user demo doesn't need cloud sync.
- If Managed Agents path chosen, that becomes the cloud component instead.

### Claude Code usage
- All Swift code generated/refined via Claude Code
- `CLAUDE.md` in repo documents project context for any reviewer who clones
- Multi-agent setup not needed for solo build of this size — would add overhead

---

## Decision 5: Permissions & User Authorization Strategy

### Permission stack
| Permission | Purpose | Risk if denied |
|---|---|---|
| Notifications | Alarm trigger fallback | High — must request firmly |
| Critical Alerts (entitlement) | Bypass silent mode | Almost certainly denied for hackathon (Apple approval needed). Document as roadmap. |
| Camera | Wake verification photo | Hard requirement — app non-functional without |
| Background Audio | Keep audio session alive overnight | Hard requirement |
| HealthKit | Sleep data read | Soft — only enables sleep summary feature |
| Motion & Fitness | Wake window detection + anti-spoofing | Soft — degrades gracefully |
| Screen Time / Family Controls | Strict mode (block other apps until verified) | Stretch goal Day 4 only |

### Onboarding flow design
Each permission requested with a contextual screen explaining *why*, not iOS's default modal. Increases grant rate dramatically. Frame each as "your contract with future-you."

---

## Decision 6: Claude Managed Agents — Special Prize Path

### Opportunity
$5k special prize for "Best use of Claude Managed Agents." Most teams will focus on direct API calls. Targeting this is high-leverage given low competition.

### Possible Managed Agent applications in WakeProof
- **Overnight sleep analysis pipeline:** Agent runs at end of sleep window, ingests HealthKit data + accelerometer log + previous nights, generates personalized morning briefing before alarm fires
- **Weekly insight agent:** Runs Sunday night, processes 7 days of data, generates coaching email/notification
- **Pattern discovery agent:** Runs monthly, looks for surprising correlations (caffeine timing, weekday vs weekend, etc.)

### Decision criteria (Day 2 evening)
After watching Michael Cohen's Live Session (Apr 23 11 PM HKT):
- Is Managed Agents setup achievable in <8 hours?
- Does it add genuine demo value vs. distract from core?
- Can the morning briefing be a "wow moment" in the demo video?

If all three yes → commit Day 4 to this path. If not → fall back to mocked weekly dashboard with Opus 4.7 insight generation.

---

## Decision 7: Demo Video Strategy

### Format: 3 minutes max
Hard cap. Judges watch 50+ videos. Going over is amateur.

### Structure (locked)
1. Hook (20 sec): "What if your alarm could tell when you're lying?"
2. Problem (30 sec): snooze hell, real cost
3. Live demo (85 sec): set alarm → ring → photo → verify → result on real device
4. Opus 4.7 angle (25 sec): why vision + reasoning is the unlock
5. Vision/closing (20 sec): generalizes beyond sleep — any intent-action gap

### Production
- Real device (Vincent's iPhone), not simulator — judges can tell
- Screen recording via QuickTime + iPhone mirror, OR phone-on-tripod second angle
- One take preferred. If editing, use Descript for filler-word removal
- Background music: low ambient, no copyright traps
- Captions: yes (judges may watch muted in batch review)

### Voice
Vincent's own voice. Authentic > polished. Practitioner + dev background gives credibility.

---

## Open Questions (resolve during build)

- [ ] Does Vincent have an Apple Watch with recent sleep data to demo HealthKit integration? If no, drop sleep summary from MVP.
- [ ] Will Discord teammate channel produce a useful iOS-native partner before Day 2 evening cutoff?
- [ ] Does the foreground audio session approach actually survive overnight on iOS 17/18 in 2026? (Apple may have tightened restrictions.)
- [ ] Can demo recording capture the alarm sound clearly? Test mic placement.
