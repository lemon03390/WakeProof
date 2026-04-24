# Self-Sabotage Defense — Alarmy Mechanism Analysis & WakeProof Adaptation

> **Status:** Analysis only. Produced 2026-04-24 while Full Review of the existing branch is in progress.
> **Scope:** Reverse-engineers Alarmy's self-sabotage defenses, maps them against iOS platform limits, and sketches adaptation paths for WakeProof. No code changes proposed as part of this doc — the "Priority subset" section is the input for a future implementation plan once Full Review closes.
> **Non-goals:** Not a task spec, not a build plan, not a commitment to ship any item listed here.

---

## 1. Why this matters for WakeProof

WakeProof's positioning line — *"a wake-up contract you can't unsign"* — is load-bearing on **three** attack surfaces, not just the morning one:

| Surface | Attack window | Current WakeProof posture |
|---|---|---|
| **Before ring** (night-before / any daytime) | Disable window, uninstall, revoke permissions, set Focus DND, enable airplane mode before bed | Minimal defenses. The user can just flip `WakeWindow.isEnabled` to false at bedtime. |
| **During ring** (60 s – 10 min window) | Force-quit, mute, volume-down, phone call interrupt, pull SIM, power-off | Solid: always-resume on interruption, time-sensitive backup notification, ring ceiling, UNRESOLVED recovery marker. |
| **After ring** (morning + rest of day) | Ignore UNRESOLVED log, lie in the memory file, delete WakeAttempt rows, re-install fresh | No defenses. Morning self has full write access to evening self's commitment record. |

Opus 4.7 vision closes the *ringing-moment* verification hole. It does not close the other two. Alarmy has spent ~8 years iterating on those other two and has visible market evidence of what works (60M+ downloads, top-10 iOS alarm category). This doc extracts that playbook.

---

## 2. Attack taxonomy — what the half-asleep self actually does

Before looking at defenses, a clear threat model. Sorted by frequency from user forums + App Store reviews of Alarmy and similar apps:

### 2.1 During-ring attacks (most common; target of Layer 1)

| Attack | Effort | Current WakeProof block? |
|---|---|---|
| Swipe-up force-quit via App Switcher | Very low | Partial — `.ringing` phase is persisted via `lastFireAt`; next launch logs UNRESOLVED ([AlarmScheduler.swift:278-283](../WakeProof/WakeProof/Alarm/AlarmScheduler.swift#L278-L283)). Backup notification still fires. **Not blocked** — just logged. |
| Mute switch (ringer silence) | Very low | Blocked — `.playback` category + critical alert entitlement request. See [AudioSessionKeepalive.swift:40-50](../WakeProof/WakeProof/Alarm/AudioSessionKeepalive.swift#L40-L50). |
| Volume-down to zero | Low | **Not blocked.** User can drag volume slider to 0 during ring. AlarmSoundEngine's ramp targets `player.volume`, not the device output volume. |
| Incoming phone call | Zero (not user-initiated) | Blocked — always-resume on `.ended` regardless of `shouldResume` hint ([AudioSessionKeepalive.swift:186-201](../WakeProof/WakeProof/Alarm/AudioSessionKeepalive.swift#L186-L201)). |
| Airplane mode | Low | Partial — audio continues, but Opus 4.7 verification call dies. Graceful-degrade path not explicitly implemented. |
| Power-off / hard reset | Medium friction (requires button combo + slider) | Cannot be blocked on iOS. Next launch logs UNRESOLVED. |
| Pull SIM / remove battery (legacy phones) | High | N/A on modern iOS — battery is non-removable. |

### 2.2 Before-ring attacks (the quiet killers)

| Attack | Effort | Current block? |
|---|---|---|
| Disable alarm via in-app toggle | Very low (1 tap) | **Not blocked.** `updateWindow(.isEnabled = false)` is a plain state mutation. Alarmy gates this behind a mission. |
| Change window to 23:59 ("I'll fix it tomorrow") | Low | Not blocked. |
| Revoke notification permission via Settings | Medium (requires leaving app) | Detected (`PermissionsManager.notifications == .denied`) but not re-prompted. User can just leave it denied. |
| Revoke camera permission | Medium | Same — detected but no re-prompt at runtime. |
| Enable Focus mode / Do Not Disturb the night before | Low | iOS Focus does NOT silence critical alerts — but WakeProof cannot guarantee critical alert entitlement. See §4. |
| Uninstall app | Medium (requires long-press + confirm) | **Not blocked at all.** No nag, no farewell mission, no re-install reminder. |
| Factory reset / Restore | High | Cannot be blocked. |

### 2.3 After-ring attacks (the most subtle)

| Attack | Effort | Current block? |
|---|---|---|
| Ignore UNRESOLVED WakeAttempt row in history | Zero | History is passive. No nag, no weekly review card, no "contract broken" narrative. |
| Delete WakeAttempt rows from SwiftData | Requires SQL tooling — N/A for real users | Not a realistic attack. |
| Edit the MemoryStore file to hide a bad morning | Zero (the file is user-readable; Claude trusts it) | **Not blocked.** Memory file is in the app sandbox with no integrity seal. Evening Claude reads what morning-self wrote. |
| Re-install fresh to wipe history | Medium (uninstall + re-onboard) | **Not blocked.** Onboarding treats every install as Day 1 — no iCloud continuity, no ShareSheet-exportable badge proving prior commitment. |

---

## 3. Alarmy's actual mechanisms — reverse-engineered

Marking confidence levels:
- **[Observed]** — visible in the app or verifiable in a simulator
- **[Inferred]** — mechanism deduced from behavior, not confirmed in documentation
- **[Rumored]** — App Store reviews / user reports only; may be ex-behavior or marketing copy

### 3.1 Ring-window defenses (overlaps heavily with WakeProof)

**M1. AVAudioSession .playback + silent loop keepalive** [Observed]
- Standard iOS hack for "alarm-class" apps without a public Alarm API.
- **Same as WakeProof.** No meaningful difference.

**M2. Always-resume on interruption.ended, ignoring shouldResume hint** [Inferred]
- A common-sense defense; WakeProof already implements it ([AudioSessionKeepalive.swift:186-201](../WakeProof/WakeProof/Alarm/AudioSessionKeepalive.swift#L186-L201)).
- **No gap.**

**M3. Volume re-raise when user presses volume-down** [Rumored / historically observed]
- Observes `AVAudioSession.outputVolume` via KVO on `MPVolumeView`, detects drops, programmatically sets a new volume via the private `MPVolumeView` slider subview.
- **App Store risk:** Apple has pushed back on this historically. Private API use + user hostility. **Alarmy has softened this over versions** — current behavior is closer to "notify you the volume is low" than "force-raise".
- **WakeProof should not copy this as a direct fight.** See §9 anti-patterns.

**M4. Backup local notifications stacked at 1-min intervals** [Observed]
- If the app is force-quit during ring, Alarmy schedules 3–5 backup `UNNotificationRequest`s at 60 s intervals, each with the alarm sound attached.
- User's phone keeps beeping even after the app is dead.
- WakeProof currently schedules **one** backup ([AlarmScheduler.swift:328-374](../WakeProof/WakeProof/Alarm/AlarmScheduler.swift#L328-L374)). Clear gap.

**M5. Critical Alert entitlement** [Observed]
- Apple-granted only; requires request-per-bundle-id approval. Alarmy has it. WakeProof has requested it ([PermissionsManager.swift:48-50](../WakeProof/WakeProof/Services/PermissionsManager.swift#L48-L50)) but the request almost certainly returns denied until Apple approves.
- **Comment in code acknowledges this**: `"Critical alert entitlement is almost certainly not granted — document the status."`
- Gap is regulatory, not technical. File the Critical Alerts request separately if this becomes demo-critical.

### 3.2 Before-ring defenses (where WakeProof has real gaps)

**M6. Disable-alarm gated behind a mission** [Observed — Pro feature]
- Toggling an alarm off requires completing the mission *first*, same as the morning dismissal.
- Psychologically: the user has to pre-commit to being awake when they want to cancel the commitment. If morning-self can't do it, evening-self can't either.
- **This is the single most replicable, high-impact gap WakeProof has.** The self-commitment contract leaks precisely because evening-self has a disable button morning-self doesn't.

**M7. "Commitment screen" on alarm setup** [Observed]
- Before enabling a new alarm with missions, an explicit modal: *"Once set, this alarm cannot be canceled without completing the selected missions. Continue?"*
- Purely psychological — it is a consent timestamp, not a technical lock. But it raises the cost of dismissal because the user has explicitly agreed in writing.
- Aligns perfectly with WakeProof's "contract" framing. Currently absent.

**M8. Uninstall friction** [Inferred]
- On delete, iOS shows the standard confirmation. Alarmy cannot block it.
- What Alarmy DOES: the app itself has a "Quit Alarmy" flow inside settings that walks the user through a "are you sure? you've kept a 47-day streak" screen. Users who delete the app via Settings → General → iPhone Storage also see this.
- **Social-debt framing**: show the user what they're losing, not a roadblock.
- WakeProof equivalent: onboarding produces a "streak" or "contract count"; Settings' "disable forever" flow surfaces it.

**M9. Permission-revoke detection + nag** [Observed]
- On app foreground, Alarmy checks notification authorization. If revoked, a full-screen modal: *"Alarmy cannot wake you if notifications are off. [Open Settings]."*
- Similar for camera (for photo missions).
- WakeProof **detects** this ([AlarmSchedulerView.swift:91](../WakeProof/WakeProof/Alarm/AlarmSchedulerView.swift#L91)) but shows an inline banner, not a blocking modal. The inline banner is dismissable by ignoring it.

**M10. Backup alarm on rival systems** [Observed — Android only, but instructive]
- On Android, Alarmy can schedule a redundant alarm via the system AlarmClock provider so killing Alarmy's process still fires a system-level alarm.
- iOS has no equivalent public API. `UNCalendarNotificationTrigger` is already WakeProof's version of this.

### 3.3 After-ring defenses (the moral-infrastructure layer)

**M11. Streak counters prominent on home screen** [Observed]
- Alarmy shows "{N} days streak" and "{N} missions completed" front-and-center. Breaking the streak feels like loss.
- Behavioral economics: loss aversion >> gain motivation. A broken 30-day streak hurts more than a new streak gives pleasure.
- WakeProof has no streak UI.

**M12. Share-to-social badges** [Observed — Pro feature]
- After a verified wake, user can share a "I woke up at 6:30" card to Instagram. Makes the contract public.
- Has an adoption-loop benefit (viral marketing) and a commitment-device benefit (public pre-commitment in Schelling-point sense).
- WakeProof could surface this via the Layer 4 weekly coach's report.

**M13. Shame log (failed wakes)** [Observed — buried in settings]
- A history view shows failed/dismissed alarms with timestamps. Not spammy — just visible when the user navigates there.
- Combined with M11, reads as: "you broke your streak on March 14; here's the row."

**M14. Sleep-time contract signing** [Observed in newer versions]
- Night-before flow: "Your alarm is set for 6:30. Commit?" — explicit second confirmation at bedtime, separate from setup.
- Psychologically different from setup consent because it's closer in time to the temptation event.
- Fits WakeProof's Layer 3 overnight agent beautifully: the overnight agent is already awake at bedtime and could present the contract via a notification.

---

## 4. iOS platform floor — what no app can do

Be honest about this in any scope discussion. No iOS 17+ app, Alarmy included, can:

1. **Prevent force-quit** via the App Switcher swipe-up gesture.
2. **Prevent airplane mode** (physical toggle in Control Center is system-owned).
3. **Prevent Focus / Do Not Disturb activation** before alarm fires. *However:* Critical Alerts bypass Focus.
4. **Prevent Control Center gestures** during a ring. Guided Access can, but requires user pre-enrollment — cannot be forced.
5. **Prevent uninstallation**. Parental Controls + MDM can, but WakeProof has no MDM posture.
6. **Prevent the physical power button** from triggering power-off.
7. **Block Siri from running a "turn off alarms" shortcut**.
8. **Guarantee audio plays when silent mode is on** without the Critical Alerts entitlement (Apple-granted case by case; WakeProof's request will likely be denied for a single-dev hackathon build, and is currently noted as such in [PermissionsManager.swift:53-55](../WakeProof/WakeProof/Services/PermissionsManager.swift#L53-L55)).
9. **Persist a process indefinitely** in the background. The `.playback` audio session is the only reliable keepalive, and iOS can still terminate it under memory pressure.
10. **Read other apps' state** (whether DND is active, whether Screen Time app limit is hit, etc.).

**Implication:** every "defense" is friction, not a wall. The product must make the cost of sabotage higher than the cost of waking up. This is a UX problem, not a technical one.

---

## 5. WakeProof current defenses — ground truth

Verified by reading the current code on the branch under review:

| # | Defense | File | Status |
|---|---|---|---|
| W1 | `.playback` audio category + silent loop keepalive | [AudioSessionKeepalive.swift:40-50](../WakeProof/WakeProof/Alarm/AudioSessionKeepalive.swift#L40-L50) | Shipped |
| W2 | Always-resume on interruption.ended | [AudioSessionKeepalive.swift:186-201](../WakeProof/WakeProof/Alarm/AudioSessionKeepalive.swift#L186-L201) | Shipped |
| W3 | 60 s volume ramp 0.3→1.0 | [AlarmSoundEngine.swift:44-66](../WakeProof/WakeProof/Alarm/AlarmSoundEngine.swift#L44-L66) | Shipped |
| W4 | 10 min ring ceiling (safety net) | [AlarmSoundEngine.swift:68-82](../WakeProof/WakeProof/Alarm/AlarmSoundEngine.swift#L68-L82) | Shipped |
| W5 | Single backup `UNCalendarNotificationTrigger` / `UNTimeIntervalNotificationTrigger` | [AlarmScheduler.swift:328-374](../WakeProof/WakeProof/Alarm/AlarmScheduler.swift#L328-L374) | Shipped |
| W6 | Time-sensitive interruption level on backup notification | [AlarmScheduler.swift:341](../WakeProof/WakeProof/Alarm/AlarmScheduler.swift#L341) | Shipped |
| W7 | `lastFireAt` persistence + UNRESOLVED recovery row on next launch | [AlarmScheduler.swift:278-283](../WakeProof/WakeProof/Alarm/AlarmScheduler.swift#L278-L283) | Shipped |
| W8 | Scheduling-generation counter to reject stale async resolves | [AlarmScheduler.swift:109-129](../WakeProof/WakeProof/Alarm/AlarmScheduler.swift#L109-L129) | Shipped |
| W9 | Foreground scene-phase reconciler (catches OS-suspended-past-fire) | [AlarmScheduler.swift:288-295](../WakeProof/WakeProof/Alarm/AlarmScheduler.swift#L288-L295) | Shipped |
| W10 | Critical Alert entitlement requested (expected denied) | [PermissionsManager.swift:48-50](../WakeProof/WakeProof/Services/PermissionsManager.swift#L48-L50) | Requested |
| W11 | Permission-denied inline banner on scheduler view | [AlarmSchedulerView.swift:91-103](../WakeProof/WakeProof/Alarm/AlarmSchedulerView.swift#L91-L103) | Shipped |
| W12 | Random anti-spoof action prompt on RETRY | [AntiSpoofActionPromptView.swift](../WakeProof/WakeProof/Verification/AntiSpoofActionPromptView.swift) + [VisionVerifier.swift:53-57](../WakeProof/WakeProof/Verification/VisionVerifier.swift#L53-L57) | Shipped |
| W13 | One-retry cap on RETRY (second RETRY → REJECTED) | [VisionVerifier.swift](../WakeProof/WakeProof/Verification/VisionVerifier.swift) | Shipped |

**WakeProof is actually stronger than a naive Alarmy port on the ring-window** (W8, W9, W12, W13 are non-trivial and not all Alarmy has). The gap is elsewhere.

---

## 6. Gap analysis — Alarmy has, WakeProof lacks

Cross-referencing §3 against §5:

| Gap | Impact | Alarmy ref | Effort estimate | Touches |
|---|---|---|---|---|
| **G1.** Disable-alarm gated behind a mission | High — closes the biggest loophole | M6 | Substantial | `AlarmScheduler.updateWindow`, new "disable challenge" flow, onboarding |
| **G2.** Commitment screen on alarm enable | Medium (psychological) | M7 | Trivial | New onboarding slide + one modal at enable-time |
| **G3.** Chained backup notifications (3–5 at 1-min intervals) | High — raises force-quit cost | M4 | Trivial–Moderate | `AlarmScheduler.scheduleBackupNotification` — scheduling loop |
| **G4.** Permission-revoke full-screen blocker on foreground | Medium | M9 | Moderate | New blocker view + scene-phase hook |
| **G5.** Streak counter / broken-contract surface | Medium (loss aversion) | M11, M13 | Moderate | New `CommitmentStreak` model + home view |
| **G6.** Bedtime contract re-sign via overnight agent | Medium–High (fits Layer 3) | M14 | Moderate | `OvernightScheduler` + notification flow |
| **G7.** Memory-file integrity seal (evening-Claude can detect morning-self edits) | Low–Medium | (Alarmy has no equivalent; original to WakeProof) | Moderate | `MemoryStore` signature layer |
| **G8.** Uninstall-friction farewell flow | Low (only triggers at deletion) | M8 | Trivial | One settings screen |
| **G9.** Share-badge after verified wake | Low (viral, not commitment) | M12 | Trivial | ShareLink API |
| **G10.** Live Activity on Lock Screen during ring | High (makes "quietly kill" visually hard) | (Alarmy uses it; iOS 16+) | Moderate–Substantial | New ActivityKit target, Lock Screen widget |

**Note:** "Effort" is relative sizing (trivial / moderate / substantial), not a time estimate. Substantial items touch 3+ files and require new UI surfaces.

---

## 7. Adaptation recommendations — detailed sketches

Per-item design notes. These are architectural only — not task specs.

### 7.1 G1 — Disable-gated-by-mission (highest impact)

**Mechanism.** Replace the plain `WakeWindow.isEnabled = false` path with a flow identical to the morning ring:
1. User taps "Disable alarm".
2. App presents `AlarmRingingView` (or a variant) requiring capture + vision verification.
3. On `VERIFIED`, the disable is committed.
4. On `REJECTED` / `RETRY` / cancel, the alarm stays enabled.

**Why it works.** Evening-self wanting to sabotage must go find the exact kitchen/bathroom baseline scene in the evening, at current lighting, with open eyes, and pass the same Opus 4.7 check. Morning-self facing this is no harder than the normal wake-up. The asymmetric pain point is the evening path — it becomes an active weirdness tax.

**Owning subsystem.** `AlarmScheduler.updateWindow` becomes:
```swift
// pseudocode — not committed
func requestDisable(completion: (DisableOutcome) -> Void) {
    // Transitions to a new `.disableChallenge` phase.
    // Camera + VisionVerifier flow reused verbatim.
    // On VERIFIED → window.isEnabled = false, save, completion(.allowed)
    // On anything else → completion(.refused(reason: ...))
}
```

**Nuances.**
- **Grace period.** New users get 24 h after onboarding where plain disable works (so they can recover from a wrong-baseline setup). After grace, mission-gated.
- **Window-time change (not full disable).** Moving the window from 06:30 to 07:00 should probably NOT require verification — the user is not sabotaging, just adjusting. Only `isEnabled = false`, and maybe `startHour shifted by >30 min`, trigger the challenge.
- **Uninstall is still a bypass.** Accept this as a platform floor. The protection is probabilistic, not absolute.

**Risks.**
- Users in genuine emergencies (sick, flying at 3 AM) need an escape. Alarmy's answer: a "solve 10 math problems" fallback. WakeProof could offer "type the 20-word commitment sentence" as the bypass — less fun than a photo, but unambiguously a consent moment.
- Demo risk: if the reviewer wants to disable the alarm mid-demo, they will hate this. Ship it behind a DEBUG-off toggle or grace-period flag for the hackathon submission.

**Demo value.** Very high — this is the feature that most concretely delivers on "contract you can't unsign" for judges.

**Fit for Opus 4.7 positioning.** Perfect. Reuses Layer 1 for a second purpose.

---

### 7.2 G3 — Chained backup notifications

**Mechanism.** Today WakeProof schedules one backup notification at `fireAt`. Extend to a sequence:
- `fireAt + 0 s` — primary backup (already exists)
- `fireAt + 90 s` — "Still sleeping? WakeProof needs your photo."
- `fireAt + 180 s` — "Your commitment expires in 7 minutes."
- `fireAt + 330 s` — final before ring ceiling hits.

Each has a distinct identifier (`com.wakeproof.alarm.next.backup.1`, `.2`, `.3`) so cancellation is surgical. All use `.timeSensitive` interruption level and the `alarm.caf` sound.

**Cancellation.** When the user successfully enters `.capturing`, all pending backup notifications are removed. When the ring ceiling fires, they are also removed.

**Owning subsystem.** `AlarmScheduler.scheduleBackupNotification` becomes a loop. One identifier becomes `[String]`. Nothing else shifts.

**Risks.**
- iOS undelivered notification cap is 64 per app. We use 3–4 per alarm. No realistic risk.
- Reviewer hostility if chained pings in demo. Mitigation: the sequence is only active when `.ringing` phase did not successfully transition to `.capturing`. In normal demo flow, only the primary fires.

**Effort.** Trivial. ~30 lines of Swift in one existing method.

**Demo value.** Medium — you only see it if you force-quit mid-ring.

**Fit.** Orthogonal to Opus 4.7; pure platform hardening.

---

### 7.3 G5 + G6 — Streak counter + bedtime contract signing (Layer 3 extension)

**Mechanism.** A new `CommitmentStreak` model in SwiftData:
```swift
// pseudocode
@Model final class CommitmentStreak {
    var current: Int
    var best: Int
    var lastBrokenAt: Date?
    var lastBrokenReason: String?  // "timeout", "unresolved", "user_disabled"
}
```

Surfaced in two places:
1. **Alarm scheduler home view** — small streak badge. "7-day streak."
2. **Overnight agent bedtime notification** — "You're on a 7-day streak. Confirm tomorrow's wake window: 06:30? [Confirm] [Skip]."

The "Skip" path in bedtime confirmation counts as a breach in the narrative even though the alarm didn't technically fire. This is psychologically significant because the user is actively choosing to break the streak the night before, not in the fog of 6 AM — they cannot blame half-asleep self.

**Owning subsystem.**
- New model + SwiftData migration.
- `OvernightScheduler` extended to include a bedtime notification branch.
- `WeeklyCoach` gains access to the streak model for Layer 4's report.

**Risks.** The bedtime confirmation is a new notification and must be on a separate permission scope from the alarm itself — no extra iOS permission required, but UX clarity matters.

**Effort.** Moderate. Touches 4–5 files and requires a migration.

**Demo value.** Medium — the streak is a quiet UI element, the bedtime notification is a before-bed moment that most demo reviewers will not see. But it makes the Layer 4 weekly coach report much stronger, which IS demo'd.

**Fit for Opus 4.7 positioning.** Strong. The streak becomes narrative raw material for the weekly coach's 1M-context call. *"Last Tuesday you broke a 6-day streak and the memory file noted you felt uncharacteristically groggy. Here's what Monday night's sleep data looked like."*

---

### 7.4 G4 — Permission-revoke blocker

**Mechanism.** On `scenePhase == .active`, `PermissionsManager` re-queries `UNUserNotificationCenter.notificationSettings()` and `AVCaptureDevice.authorizationStatus(for: .video)`. If either has downgraded since last check, present a blocking modal that consumes the entire scene until the user either:
- Taps "Open Settings" (deep-link via `UIApplication.shared.open(settingsURL)`)
- Returns with permission re-granted, or
- Explicitly confirms "Keep alarm broken" (logs a breach event).

**Owning subsystem.** `PermissionsManager` + root-level sheet in `WakeProofApp`.

**Why not a banner.** The existing inline banner is dismissable by ignoring it. The whole point is to make this NOT dismissable without a conscious breach event.

**Risks.** App Store reviewer hostility if this blocker is over-aggressive. Keep it single-screen and single-action.

**Effort.** Moderate. New view, scene-phase observer, state.

**Demo value.** Low — only triggers if someone revokes permissions mid-demo, which nobody will do. But raises the app's legitimate ship-to-production posture.

**Fit.** Orthogonal to Opus 4.7; pure platform hardening.

---

### 7.5 G7 — Memory-file integrity seal

**Mechanism.** Opus 4.7's Layer 2 memory is currently a plain file ([MemoryStore.swift](../WakeProof/WakeProof/Services/MemoryStore.swift)) that Claude reads + writes. An advanced user with Files app access could edit it between sessions.

Defense:
1. Every Claude write includes a rolling HMAC of the previous file's content + the new content, stored in a separate file (or in the UserDefaults-anchored `lastFireAt`-style marker).
2. On every read, the HMAC is verified. A mismatch means the file was edited externally.
3. A mismatch does not block reads — it logs a `MEMORY_TAMPERED` event for the weekly coach to notice and narrate.

**Why HMAC, not signing.** We don't need non-repudiation; we need integrity. A device-local secret key in Keychain is sufficient.

**Why not block.** Blocking a read over a tampered file bricks the app. Logging it lets the Layer 4 coach be the voice that says *"You edited the memory file on April 11. Why?"* — which is a more Alarmy-style social-debt response than a hard refusal.

**Risks.** Legitimate schema migrations would trigger false positives. Mitigation: version the HMAC payload with schema version.

**Effort.** Moderate. Keychain integration + two sites in MemoryStore.

**Demo value.** Very low in hackathon demo (invisible unless you tamper). High for product narrative — this is the kind of depth that reads as "real engineering" for the Depth & execution 20% criterion.

**Fit for Opus 4.7.** Strong. This is what makes the memory file a real contract record, not a write-through cache.

---

### 7.6 G10 — Live Activity on Lock Screen

**Mechanism.** Using iOS 16+ ActivityKit, when the alarm enters `.ringing`, start a `LiveActivity` that:
- Shows on Lock Screen + Dynamic Island
- Displays "WakeProof — verifying requested" with a progress indicator
- Auto-ends on phase → `.idle`

**Why it helps self-sabotage resistance.** A Live Activity makes the running alarm **visually undeniable**. User cannot pretend "the alarm didn't go off" — it's literally on Lock Screen. Force-quit still works technically, but the visual evidence persists for the 8-hour Live Activity budget iOS grants.

**Owning subsystem.** New ActivityKit target + widget extension. Scheduler fires Activity events on phase transitions.

**Risks.** ActivityKit adds target-membership complexity. Cross-cuts build config.

**Effort.** Substantial. New Xcode target, new entitlement, new widget code, new App Intent to dismiss.

**Demo value.** High. A Lock Screen Live Activity in the demo video is visually striking.

**Fit.** Orthogonal to Opus 4.7 but lifts "Depth & execution 20%" and "Demo 25%" together.

---

### 7.7 G8 — Uninstall friction

**Mechanism.** Settings → "Quit WakeProof" screen that surfaces:
- Current streak
- Number of verified wakes
- Opus 4.7-written farewell paragraph: *"You're about to end a {N}-day commitment. Are you sure?"*

This does not prevent deletion via iOS Settings → General → iPhone Storage. It only catches users who exit through the app itself.

**Effort.** Trivial. One settings row + one view.

**Demo value.** Very low.

**Fit.** Weak. Only ship if the rest of Layer 4 is already solid.

---

## 8. Priority subset for hackathon (if any items pulled in before submission)

If — and only if — Full Review concludes early and there is true free time before the demo video, the **two** items with the best ratio of demo impact to effort:

### P1. G1 — Disable-gated-by-mission (the "contract" feature)
- **Why first.** Directly delivers on the tagline. A reviewer who asks *"can you just disable it?"* and watches the capture flow trigger again will remember that moment.
- **Scope discipline for hackathon.** Ship with the 24 h grace period ON + a DEBUG bypass toggle for demo recording. Do NOT ship the fallback math-typing bypass — that's post-hack.
- **Demo script add-on.** "Let me try to disable this... oh, it's asking me to prove I'm awake to stop the proof requirement. That's the contract."

### P2. G3 — Chained backup notifications
- **Why second.** Fractional effort, fractional regression risk. Hardens the "force-quit doesn't escape" narrative with zero new UI surface.
- **Scope discipline for hackathon.** Ship exactly 3 backups at 0/90/180 s. Don't over-engineer the escalating copy.

**Everything else in §7 is post-hackathon.** Streak UI (G5), bedtime contract (G6), memory integrity (G7), and Live Activity (G10) are all substantial surface-area changes that would destabilize Full Review's closure.

> **Update 2026-04-24:** Superseded by §12. Full Review is closer to closing than this section assumed; the priority subset has expanded to include Hooked-derived engagement items (H1–H5) alongside G1 + G3, all to ship as Wave 5. Reasoning + processing order in §12.2.

---

## 9. Anti-patterns — what NOT to copy from Alarmy

### A1. Volume-button re-raise via MPVolumeView subview surgery
Private-API surface, App Store rejection risk, user-hostile. WakeProof's `.playback` category and critical alerts already fight silent switch without going here. Skip.

### A2. 5+ stacked backup notifications at 30 s intervals
Alarmy's old versions did this and got feedback that it was harassment. Keep the chain to 3–4.

### A3. Paywall-gating self-sabotage defenses
Alarmy puts disable-by-mission behind Pro. For the hackathon WakeProof has no monetization, so this is moot — but note that if real monetization comes later, the "contract" mechanic should be free-tier, not paid. Charging the user to be protected from themselves is bad UX and bad ethics.

### A4. Spam-class push to re-install after uninstall
Technically impossible (app is gone) and, even where possible via server-push to an account ID, reads as creepy. Skip.

### A5. Shaming-style copy ("You failed 3 mornings this week")
The tone matters. Alarmy's shame logs are dry and neutral — timestamps and verdicts. Narrative shaming belongs in the Layer 4 coach's voice, where Opus 4.7 can tune tone to the user's memory profile. Hardcoded shame strings age badly.

---

## 10. What this doc does not cover

- **Business model / pricing.** Outside scope.
- **Cross-device continuity.** WakeProof is local-first; iCloud sync is a separate design question. Self-sabotage via "install on a second device and disable the first" is a real attack but requires a backend to defend against.
- **Social-accountability features** (partner watching, commitment-contract with friends). These work in the Beeminder / StickK tradition and are out-of-scope for a 5-day hackathon.
- **Medical exceptions.** Shift workers, people with children, people with medical conditions need easy-out paths. The 24 h grace period in P1 is the placeholder; a fuller answer belongs in a separate accessibility doc.

---

## 11. References for implementation later

When any of these items graduates from analysis to build, the relevant docs / files:

- [AlarmScheduler.swift](../WakeProof/WakeProof/Alarm/AlarmScheduler.swift) — owner of phase machine + backup notification scheduling (Wave 5 added `.disableChallenge` phase for G1)
- [AudioSessionKeepalive.swift](../WakeProof/WakeProof/Alarm/AudioSessionKeepalive.swift) — audio floor; do not modify without re-running the overnight foundation test
- [PermissionsManager.swift](../WakeProof/WakeProof/Services/PermissionsManager.swift) — runtime permission state
- [MemoryStore.swift](../WakeProof/WakeProof/Services/MemoryStore.swift) — Layer 2 memory file
- [OvernightScheduler.swift](../WakeProof/WakeProof/Services/OvernightScheduler.swift) — Layer 3 entry point
- [WeeklyCoach.swift](../WakeProof/WakeProof/Services/WeeklyCoach.swift) — Layer 4 surface for narrating broken contracts
- [docs/opus-4-7-strategy.md](opus-4-7-strategy.md) — confirm any new Claude-touching feature preserves the four-layer framing
- [docs/technical-decisions.md](technical-decisions.md) — log any newly locked decision from this set
- [docs/go-no-go-audio-test.md](go-no-go-audio-test.md) — the foundation test; any audio-adjacent change must re-pass

**Wave 5 additions (landed 2026-04-24 → 2026-04-25, commits `14a758e` → `e67fda7`):**

- [VisionVerifier.swift](../WakeProof/WakeProof/Verification/VisionVerifier.swift) — now also owns the `verifyDisableChallenge(...)` path for G1; the H1 `observation` field plumbs through `handleResult` onto `WakeAttempt`
- [MorningBriefingView.swift](../WakeProof/WakeProof/Verification/MorningBriefingView.swift) — H1 observation + H2 commitment note reveal + H5 Share button
- [WakeWindow.swift](../WakeProof/WakeProof/Alarm/WakeWindow.swift) — H2 `commitmentNote: String?` field + `commitmentNoteMaxLength = 60`
- [StreakService.swift](../WakeProof/WakeProof/Services/StreakService.swift) — H3 current + best streak (pure derivation from WakeAttempt rows; no new @Model)
- [StreakBadgeView.swift](../WakeProof/WakeProof/Alarm/StreakBadgeView.swift) — H3 home-view badge
- [StreakCalendarView.swift](../WakeProof/WakeProof/Alarm/StreakCalendarView.swift) — H3 month-grid view
- [InvestmentDashboardView.swift](../WakeProof/WakeProof/Alarm/InvestmentDashboardView.swift) — H4 "Your commitment" surface
- [ShareCardView.swift](../WakeProof/WakeProof/Alarm/ShareCardView.swift) — H5 1080×1920 render target
- [ShareCardModel.swift](../WakeProof/WakeProof/Alarm/ShareCardModel.swift) — H5 pure helpers + `shareCardEnabledKey` UserDefaults constant
- [DisableChallengeView.swift](../WakeProof/WakeProof/Alarm/DisableChallengeView.swift) — G1 two-step explainer → capture view

---

## 12. Wave 5 plan — Hooked-derived engagement + final defense pass

> **Status:** Drafted 2026-04-24. The doc's character shifts here from analysis-only (§§1–11) to a committed wave plan. Source for the engagement half: 54 strategies retrieved from Supabase `marketing_knowledge` where `id LIKE 'HOOK_%'` (Nir Eyal — *Hooked*), accessed via Supabase MCP `execute_sql` because the `search-rag` Edge Function's `requireServiceRole` guard rejects the rotated service-role JWT (Edge Function env var holds an older key — out of scope to fix here). Wave 5 fires after Full Review closes and runs alongside any review-surfaced fixes.
> **Scope.** Two halves, one wave: (a) Hooked-derived engagement items H1–H5 — adds the *pull* (reasons evening-self wants to engage) that pure defense cannot supply. (b) Two defense items from §6 (G1 + G3) pulled forward so the engagement layer is load-bearing rather than decorative.
> **Non-goals.** Not a re-design of the verified core. Every item is additive on top of the Full-Review baseline.

### 12.1 Why this section exists — defense and engagement are duals

§§1–11 frame WakeProof entirely through self-sabotage *defense*: remove escape hatches, raise exit cost. Hooked supplies the dual — build the *pull* so evening-self wants the contract, not just tolerates it. A wake-up contract the user dreads is brittle; one the user looks forward to is a habit. WakeProof needs both because:

- Defense alone produces a tool the user resents and eventually deletes.
- Engagement alone produces a tool the user loves but bypasses when it gets hard.
- Together: the user wants to sign the contract AND can't easily unsign it.

Hooked stages mapped onto WakeProof's three attack surfaces from §1:

| Hooked stage | Maps to surface | Effect on contract |
|---|---|---|
| **Trigger** — internal: anxiety about reliability; external: alarm + bedtime ritual | Before-ring | Pulls user TO set the alarm tonight rather than avoid it |
| **Action** — *asymmetric* (night setup = trivial; morning dismissal = hard by design) | During-ring | Reinforces existing photo-verification friction; preserves the moral "morning is hard" |
| **Variable reward** — Opus 4.7 daily observation, never repeating | After-ring | Replaces "I survived the alarm" with "I want to see what Opus saw today" |
| **Investment** — commitment notes, streak, baseline photo, coach memory | All three | Raises switching cost; an hourly-rate to leave the app |

The asymmetric-action point matters: standard Hooked playbook (Ch3) reduces friction everywhere. WakeProof reduces friction *only* on the bedtime side; the morning side stays hard. Items below respect this split.

### 12.2 Processing order (the main output)

Ordered by dependency first, then by risk. Cross-references to full definitions in §§12.3–12.4.

1. **H1 — Variable Insight in VisionVerifier.** Highest single-change risk in the wave (modifies the Opus prompt that the verified core depends on). Doing it first lets every later visual item compose against a stable result shape; doing it later means re-touching screens already shipped.
2. **H2 — Pre-sleep commitment note + morning reveal.** Builds the morning-reveal screen that H1's `observation` will also surface in. One screen iteration covers both.
3. **G3 — Chained backup notifications.** Fully orthogonal to H1/H2 (no shared files). Clearing this defense gap before more visual work means later iterations are not interleaved with scheduler-touching changes. See §7.2 for the full sketch.
4. **H3 — Streak counter + calendar.** Depends only on existing [WakeAttempt.swift](../WakeProof/WakeProof/Storage/WakeAttempt.swift) rows; produces the streak data H5 will consume.
5. **H4 — Investment dashboard.** Pure SwiftData query over existing models; ships in isolation. Acts as a second SwiftUI surface to refine the visual language before H5 has to render to image.
6. **H5 — Share card.** Depends on both H1 (observation text) and H3 (streak number). Highest rendering edge-case surface; do last when its inputs are stable.
7. **G1 — Disable-gated-by-mission.** Last because G1 introduces a *new* failure mode for demo recording (the reviewer cannot simply toggle the alarm off). Putting it after H1–H5 means the engagement items can be iterated without the disable-flow blocking. Also: G1's UX copy benefits from the visual language H3/H4 establish. See §7.1 for the full sketch — ship with the 24 h grace period ON and a DEBUG bypass toggle for demo recording.

If the wave runs short, cut from the bottom: H5 → G1 → H4 → H3. **Do not cut H1 or H2** — they ARE the demo's emotional climax.

### 12.3 Hooked-derived items — full definitions

Source citations refer to entries in `marketing_knowledge` where `id` matches the cited `HOOK_*` key.

#### H1. Variable Insight in the vision call

- **Source.** HOOK_S4_2 (資訊瀑布與智能獵物酬賞 / variable reward as informational hunt), HOOK_S7_5 (情感共鳴與神秘感酬賞 / unpredictable insight per session).
- **Mechanism.** Single Opus 4.7 vision call returns three things instead of one: `verdict`, `confidence`, AND a 30–60-character `observation` — a specific, *verifiable* noticed detail (e.g. *"窗光比上週同時間早 22 分鐘 — 鏡頭裡的眼睛比 baseline 清醒"*). Constraint in the prompt: must reference something physically visible in the frame OR a comparison to baseline / recent attempts. Never generic comfort, never "great job".
- **Owning subsystem.** [VisionVerifier.swift](../WakeProof/WakeProof/Verification/VisionVerifier.swift) — extend prompt + add `observation: String?` to the result type. [AlarmRingingView.swift](../WakeProof/WakeProof/Alarm/AlarmRingingView.swift) — display in success state.
- **Fit for Opus 4.7 positioning.** Direct hit on the Most Creative Opus 4.7 Exploration prize: vision + reasoning + insight in a single call, exactly the "do three jobs at once" thesis in [docs/opus-4-7-strategy.md](opus-4-7-strategy.md).
- **Risk.** Prompt may produce flat or formulaic observations. **Fallback:** split into two sequential calls (verify → observe) at +~$0.02 / morning. Budget impact negligible relative to §12.5's API spend cap.

#### H2. Pre-sleep commitment note + morning reveal

- **Source.** HOOK_S0_6 (痛點與內部觸發綁定), HOOK_S2_5 (負面情緒與內部觸發綁定), HOOK_S7_5 (情感共鳴).
- **Mechanism.** Setting an alarm gains an optional one-line text field: *"What's the first thing tomorrow-you needs to do?"* (≤60 chars; skippable but with low-friction nudge copy). On verified wake, the success screen reveals that line in large type alongside H1's observation.
- **Absorbs G6 (bedtime contract re-sign).** The note IS the second consent point §3.2-M14 calls for. The original G6 framing of *"[Confirm 06:30] [Skip]"* is a thinner version of the same psychology — H2 supersedes it because it generates a personal artefact, not a yes/no click.
- **Owning subsystem.** [AlarmScheduler.swift](../WakeProof/WakeProof/Alarm/AlarmScheduler.swift) — Alarm model gains `commitmentNote: String?` (SwiftData migration). [AlarmRingingView.swift](../WakeProof/WakeProof/Alarm/AlarmRingingView.swift) — reveal on success.
- **Fit.** Bedtime + morning becomes a self-authored ritual. The reveal moment is what the demo video is built around.
- **Risk.** Users skip the note. Empty-note path still works (just shows H1's observation alone) — no broken state.

#### H3. Streak counter + calendar (closes G5)

- **Source.** HOOK_S5_3 (漸進式微小投入與承諾一致性), HOOK_S7_6 (連續性視覺反饋與不中斷心理).
- **Mechanism.** A `StreakService` derived from existing [WakeAttempt.swift](../WakeProof/WakeProof/Storage/WakeAttempt.swift) rows. Home view shows current + best streak prominently. A month-grid `StreakCalendarView` shows green-check / red-break / gray-future per day.
- **Break handling.** Streak resets do NOT silently zero. Instead, the next alarm-set flow requires re-capturing the baseline photo + writing one line on why it broke. The friction itself becomes the re-commitment ritual — softens the loss-aversion sting while preserving the contract narrative.
- **Owning subsystem.** New `StreakService` + `StreakCalendarView`. No scheduler changes.
- **Replaces.** G5 in §6's gap table; same intent, Hooked framing supplies the break-handling design.
- **Fit.** Loss-aversion narrative for §3.3-M11.
- **Risk.** Re-capture-baseline-on-break could feel punitive. Copy must frame as "fresh start", not penalty. Internal review before demo.

#### H4. Investment dashboard

- **Source.** HOOK_S5_2 (數據資料投入防護網), HOOK_S7_8 (高頻投入與數據資產化).
- **Mechanism.** A profile / settings card surfaces accumulated assets:
  - Baseline captured X days ago
  - N verified mornings recorded
  - M insights Opus has noticed about you (count derived from [WeeklyCoach.swift](../WakeProof/WakeProof/Services/WeeklyCoach.swift) memory)
  - One framing line: *"Apple Clock doesn't know you. WakeProof has N of your mornings."*
- **Owning subsystem.** New view; pure SwiftData query; no new models.
- **Fit.** Makes invisible SwiftData assets visible — raises switching cost via tangible loss aversion. Directly supports the "self-commitment device, not sleep tracker" positioning in CLAUDE.md.
- **Risk.** Empty / new-user state needs a graceful copy variant (e.g. *"Capture your baseline to start collecting mornings"*).

#### H5. Share card (closes G9)

- **Source.** HOOK_S7_7 (社交榮耀與一鍵分享).
- **Mechanism.** On verified wake, success screen offers an opt-in [Share] button. SwiftUI `ImageRenderer` produces a minimalist image: large streak number, H1's observation in mid-type, WakeProof mark in corner. `ShareLink` exports to Photos / IG Story / WhatsApp.
- **Replaces.** G9 in §6's gap table.
- **Opt-in is non-negotiable.** HOOK_S4_5 (逆反心理防禦與自主權保障): forced share = abandonment. Default off; surfaced as a one-time prompt the first time a streak crosses 7 days, then never auto-prompted again.
- **Owning subsystem.** New view + `ImageRenderer` snapshot. Depends on H1 (observation) and H3 (streak number) being in place.
- **Fit.** Viral moment for the demo video; "humblebrag" satisfies the social-reward axis without WakeProof needing a friend graph.
- **Risk.** Render quality across screen sizes. Mitigation: design at 1080×1920 portrait, downscale; verify on iPhone SE through 15 Pro Max in simulator before demo.

### 12.4 Defense items pulled into Wave 5

Both have full design sketches in §7 already. The notes below are only why-now justifications.

#### G1. Disable-gated-by-mission *(design: §7.1)*

Without G1, evening-self can mute the contract H2 just authored — H1–H5 become decorative. G1 is what makes the engagement layer load-bearing. Hackathon-scope discipline from §7.1 stands: 24 h grace period ON, DEBUG bypass toggle for demo recording.

#### G3. Chained backup notifications *(design: §7.2)*

Tiny effort, hardens the during-ring story before the demo. Already nominated in §8 as P2; no new rationale needed beyond pulling it into the same wave as H-items.

### 12.5 Items explicitly deferred (post-hackathon, not Wave 5)

- **G6 — bedtime contract re-sign.** Absorbed into H2; H2 generates a personal artefact whereas G6 was a yes/no click. No standalone G6 ships.
- **G7 — memory file integrity seal.** No demo visibility; large surface area (Keychain + HMAC at every read/write site).
- **G10 — Live Activity on Lock Screen.** New Xcode target + new entitlement + new widget code. Too much surface change for this wave.
- **G4 — permission-revoke blocker (full-screen).** Existing inline banner is acceptable for demo; productionizing this is post-hack.
- **G8 — uninstall friction.** No demo visibility; ship only after the rest of the engagement layer settles.

### 12.6 Hooked anti-patterns explicitly avoided

In addition to §9 (Alarmy anti-patterns), these Hooked-adjacent patterns are out of scope for WakeProof regardless of effort:

- **Points / badges / leaderboards.** HOOK_S4_4 (拒絕無效遊戲化) — solves no real pain; clashes with the premium-commitment positioning. The Streak in H3 is loss-aversion narrative, not a points economy.
- **Daily push notifications outside bedtime / wake window.** HOOK_S6_4 (操控模式矩陣) — would not improve user life; degrades the contract's seriousness.
- **Friend graph / social leaderboards / "compete with friends".** HOOK_S6_2 (避免成為「兜售商」) — incompatible with a self-commitment device. H5's share card is one-way export, not a social network.
- **Paywall-gating self-sabotage defenses.** Already in §9.A3; restated because Hooked Ch1 (HOOK_S1_1) covers freemium tactics that would tempt this. The contract mechanic must be free-tier if WakeProof ever monetizes.
- **Shame-style copy on broken streaks.** Already in §9.A5; reinforced by HOOK_S4_5 (autonomy preservation). Streak-break copy in H3 must frame as "fresh start", not "you failed".

### 12.7 Doc updates needed when Wave 5 closes

> **Status:** Wave 5 closed 2026-04-25. All four updates below are landed.

- [docs/opus-4-7-strategy.md](opus-4-7-strategy.md) — add H1's "vision + reasoning + observation in one call" pattern as an explicit example under the relevant layer. ✓ landed (Layer 1 section).
- [docs/technical-decisions.md](technical-decisions.md) — log the H2-absorbs-G6 decision so future contributors don't re-litigate the bedtime confirmation question. ✓ landed as Decision 9.
- [docs/build-plan.md](build-plan.md) — replace any pre-existing Day 4/5 content with Wave 5's items if that doc is still authoritative. ✓ landed as a new Wave 5 section inserted between Day 4 and Day 5.
- This file (§11 References) — add new files once they exist: `StreakService.swift`, `StreakCalendarView.swift`, `InvestmentDashboardView.swift`, `ShareCardView.swift`. ✓ landed as a "Wave 5 additions" subsection in §11.
- This file (§11 References) — add new files once they exist: `StreakService.swift`, `StreakCalendarView.swift`, `InvestmentDashboardView.swift`, `ShareCardView.swift`.

---

*End of Wave 5 plan. Execution starts after Full Review closes; processing order in §12.2 is the contract.*
