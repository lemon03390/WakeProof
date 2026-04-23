# WakeProof — On-Device Test Protocol

The simulator can't validate what makes WakeProof actually a wake-up tool: audio
session survival across an overnight background period, real notification delivery,
camera capture handoff, and audio interruption recovery. This protocol covers
exactly the things the simulator hides.

Run before every TestFlight submission and after any change to:
`AudioSessionKeepalive`, `AlarmScheduler`, `AlarmSoundEngine`, the Info.plist
background-modes section, or anything in `Verification/`.

## Prerequisites

- iPhone running iOS 17.0 or later (project minimum). The connected iPhone 17 Pro
  (`85609BDA-8D2A-539C-A5B3-C720E41AA783`) is the primary test target.
- Device installed: `xcrun devicectl device install app --device <id> /path/to/WakeProof.app`
- Charge ≥ 30 % so Low Power Mode can be tested separately.
- Ringer **on** at the start of each test (mute path is its own test).

---

## Test 1 — Audio session keepalive (overnight survival)

**Why:** the entire alarm relies on the silent loop keeping our audio session
hot in the background. If iOS suspends the session, the in-app `AVAudioPlayer`
won't fire even when `Task.sleep` resumes.

**Steps**
1. Schedule the alarm for `now + 30 minutes`.
2. Lock the device. Set Silent mode **OFF**. Plug in to a charger (rules out
   Low-Power-Mode termination).
3. Do NOT touch the device. Walk away.
4. At the scheduled time, observe whether the alarm rings.
5. Unlock and check Console.app filter `subsystem:com.wakeproof.audio` — confirm
   no `Audio session interruption BEGAN` events were silently swallowed.

**Pass:** alarm rings within ±5 seconds of the scheduled time.
**Pass with caveat:** alarm rings late (Task.sleep was suspended). The backup
notification should have rung at the right time as belt-and-suspenders;
verify in Console.

**Fail:** alarm doesn't ring at all. Capture `os_log` filtered to
`subsystem:com.wakeproof.audio` AND `subsystem:com.wakeproof.alarm` for
post-mortem.

---

## Test 2 — Phone call interruption (the F4/B4 fix)

**Why:** `AudioSessionKeepalive.handleInterruptionEnded` resumes `alarmPlayer`
unconditionally after `interruption.began`. Without this, an incoming call
during the alarm = silent black screen.

**Steps**
1. Schedule the alarm for `now + 2 minutes`.
2. Lock the device.
3. Have a second phone call the test device 30 s after the alarm starts ringing.
4. **Decline** the call.
5. Verify the alarm sound resumes within 1–2 seconds after declining.
6. Repeat with **answering** the call for 10 s, then ending it.

**Pass:** alarm resumes after both decline and end-call paths.
**Fail:** alarm stays silent → check `subsystem:com.wakeproof.audio` for
`Alarm player refused to resume after interruption.ended` faults.

---

## Test 3 — Force-quit recovery (the B5 / UNRESOLVED audit-trail fix)

**Why:** The persisted `lastFireAt` in UserDefaults must survive force-quit
during ring; the next launch should insert an `UNRESOLVED` `WakeAttempt` row.

**Steps**
1. Schedule the alarm for `now + 1 minute`.
2. When the alarm rings, swipe up the App Switcher and force-quit WakeProof.
3. Wait 30 seconds.
4. Re-open WakeProof.
5. Optional: open Xcode → Devices & Simulators → WakeProof → Container → download
   container, open the SwiftData store, confirm a row exists with
   `verdict = "UNRESOLVED"` and `scheduledAt` matching step 1's fire time.

**Pass:** UNRESOLVED row recorded on next launch; user lands on
`AlarmSchedulerView` without a stranded ringing overlay.
**Fail:** no UNRESOLVED row OR app gets stuck in `.ringing` phase.

---

## Test 4 — Backup notification delivery

**Why:** `UNTimeIntervalNotificationTrigger` is the belt-and-suspenders that
fires when our process is suspended past `Task.sleep`'s deadline.

**Steps**
1. Grant notifications during onboarding.
2. Schedule the alarm for `now + 5 minutes`.
3. Force-quit WakeProof immediately.
4. Lock the device. Wait the full 5 minutes.

**Pass:** at the scheduled time, the notification banner appears with sound
"alarm.caf" and `interruptionLevel: .timeSensitive` (shows even while DND on
the home screen; sound up to 30 s).
**Fail:** no notification → check Settings → Notifications → WakeProof →
permissions; verify Critical Alerts is requested (will likely be denied
without entitlement).

---

## Test 5 — Time-zone change overnight (the R5 fix)

**Why:** `UNTimeIntervalNotificationTrigger` for sub-day fires keeps the wall-clock
target stable across TZ changes. Switching to `UNCalendarNotificationTrigger`
would shift the fire time relative to the original wall clock.

**Steps**
1. Schedule the alarm for tomorrow 06:30 local.
2. Settings → General → Date & Time → toggle off Set Automatically → switch the
   region from Hong Kong to Tokyo (UTC+9) before midnight.
3. Wait until 06:30 Tokyo time.

**Pass:** alarm fires at the time the user originally scheduled when they were
in Hong Kong (06:30 HKT) regardless of the new region.
**Fail:** alarm fires at 06:30 Tokyo (which would be 05:30 the user's
original-region wall clock) → the trigger choice regressed.

> Note: Apple's intended semantic for the calendar trigger IS "06:30 wherever you
> are tomorrow", which is what the > 23h fallback path uses. Sub-day uses the
> time-interval trigger to anchor to the wall-clock when the user scheduled.

---

## Test 6 — Camera capture on-device (the B12 / B10 fixes)

**Why:** simulator validates the picker presents; only a real camera validates
the persist + frame extraction pipeline.

**Steps**
1. Complete onboarding to the AlarmSchedulerView.
2. DEBUG → Fire alarm now.
3. Tap "Prove you're awake".
4. Record a < 1 second clip (start-and-immediately-stop).
5. Pass: app shows "That clip was too short. Hold the record button for at
   least 1 second." (the B12 validation banner).
6. Tap "Prove you're awake" again. Record a 2-second clip normally.
7. Pass: app accepts, dismisses ringing UI, and a `WakeAttempt` row with
   `verdict = "CAPTURED"` is persisted.

---

## Test 7 — Background entry mid-capture (the B28 fix)

**Why:** `CameraHostController.handleAppDidBecomeActive` should detect the
"picker dismissed by iOS while we were backgrounded" case and call
`onFailed(.dismissedWhileBackgrounded)`.

**Steps**
1. Trigger an alarm. Tap "Prove you're awake" to enter capture.
2. Press the home indicator gesture to background the app while the camera
   picker is open.
3. Wait 60 s.
4. Foreground WakeProof.

**Pass:** The app surfaces "Camera closed while app was backgrounded. Try
again." and returns to the ringing screen — alarm is still ringing.
**Fail:** App stuck in `.capturing` with black screen → re-test the
`processingCaptureResult` flag isn't false-positive-blocking.

---

## Test 8 — Ring ceiling (the B2 fix)

**Why:** ring ceiling timeout MUST persist a `TIMEOUT` WakeAttempt or the
audit trail is fiction.

**Steps**
1. Trigger an alarm. Do nothing for the full 10 minutes (`AlarmSoundEngine.ringCeiling`).
2. After ceiling: alarm should hard-stop, ringing UI dismisses.
3. Optional: download container, confirm a `TIMEOUT` row exists with
   `scheduledAt` matching the fire time.

**Pass:** alarm self-stops at 10 min; TIMEOUT row recorded.
**Fail:** alarm rings forever (ceiling task didn't fire) OR no TIMEOUT row.

---

## Pass criteria for releasing a build

- All 8 tests pass with no `Fail:` outcomes.
- Console.app shows zero `fault` entries from any of `com.wakeproof.*`
  subsystems during the test run.
- Battery drain attributable to WakeProof during overnight test ≤ 8 % on a
  fully charged device (audio session keepalive should be near-zero CPU).

## Known not-tested-on-device

- Multi-day reliability (recurring alarms over a week).
- Behaviour with AirPods / Bluetooth audio routes connected at fire time
  (route-change observer is in place but only logs).
- Background fetch interaction with Low Power Mode.

These are deferred to extended testing windows past the hackathon scope.

---

## Vision verification scenarios (Day 3 Layer 1)

Exercise all five `docs/test-scenarios.md` fixtures on the primary test device. Each scenario is a
full alarm fire — schedule for `now + 2 minutes`, follow the capture flow through verification, and
confirm the expected verdict. Budget: ~$0.013 per scenario.

### Test 9 — Scenario 1 (kitchen/morning/alert → VERIFIED)
Follow `docs/test-scenarios.md` Scenario 1. Pass: verdict VERIFIED, alarm stops, WakeAttempt row
committed with `verdict = "VERIFIED"`.

### Test 10 — Scenario 2 (kitchen/night/alert → VERIFIED or RETRY)
Follow Scenario 2. Pass: verdict is not REJECTED; RETRY resolves after anti-spoof re-capture.

### Test 11 — Scenario 3 (bathroom/groggy → RETRY)
Follow Scenario 3. Pass: anti-spoof prompt displayed exactly once; second verification resolves
deterministically.

### Test 12 — Scenario 4 (printed photo → REJECTED) — DEMO MONEY SHOT
Follow Scenario 4. Pass: verdict REJECTED with spoofing reasoning; alarm keeps ringing; banner
surfaces the rejection reason.

### Test 13 — Scenario 5 (user in bed → REJECTED)
Follow Scenario 5. Pass: verdict REJECTED; alarm continues; banner mentions posture or location.

### Pass criteria (aggregate)
- All five verdicts match expected. Scenarios 2–3 have tolerance for alternate-path routing
  (RETRY-then-pass is valid for both).
- No console `fault` entries under `com.wakeproof.verification`.
- WakeAttempt count increments by exactly one per scenario (RETRY path does NOT create a duplicate;
  the same row is updated in place).
- Total API credit burn matches expectation (~$0.065 per full pass) in Anthropic console.

---

## Day 4 Layer 2 — Memory-aware verification (Tests 14–16)

### Test 14 — First-morning memory bootstrap (Layer 2)
Fresh install (delete + reinstall to ensure `Documents/memories/` is empty). Fire alarm → capture → VERIFIED.
Pass criteria:
- (a) Console log (subsystem `com.wakeproof.memory` category `verifier`) shows `Memory loaded: profile=false history=0/0` on this verify.
- (b) After verdict, `Documents/memories/<UserIdentity.shared.uuid>/` exists on the device container.
- (c) If Claude emitted a `memory_update` field, `profile.md` and/or `history.jsonl` are present with the expected content (`profile_delta` in profile.md, single JSONL line with verdict + note in history.jsonl).
- (d) No fault entries under `com.wakeproof.memory`.

### Test 15 — Second-morning memory injected (Layer 2)
Same install as Test 14. Fire a second alarm (2 min schedule) → capture → VERIFIED.
Pass criteria:
- Console log on this verify shows `Memory loaded: profile=<bool> history=1/1` (the single history line from Test 14 is now fed back).
- The Claude request body includes `<memory_context>` somewhere in the user-message content. Easiest way to see it: force a non-2xx response (e.g., temporarily break `Secrets.claudeEndpoint` to a 404 URL) so the debug-only 4xx dump at `ClaudeAPIClient.swift` fires and writes `Documents/last_4xx_request.json`; inspect that file for the memory block. Restore the endpoint for the next run.
- If Claude emits a second `memory_update`, history.jsonl now has 2 lines and profile.md may have been replaced.

### Test 16 — Seeded profile influences verdict (Layer 2, demo-friendly, optional)
Manually author `Documents/memories/<uuid>/profile.md` on the device (easiest: pull the simulator container, edit, push back — or on hardware use Xcode Devices container browser). Content example:
```
User's kitchen is dimly lit before 7 AM in winter. Do not reject on `lighting_suggests_room_lit=false` alone; cross-check with alertness + posture instead.
```
Fire alarm in genuinely dim-light conditions (curtains closed, room lamp off) → capture → expect VERIFIED or RETRY (NOT REJECTED on lighting alone).
Pass criteria:
- Verdict is VERIFIED or RETRY, not REJECTED. If REJECTED, Claude's `reasoning` field should NOT cite "room too dark" exclusively — that would indicate the memory calibration wasn't respected.
- Same "no fault entries" invariant as Tests 14–15.

### Pass criteria (aggregate, Layer 2)
- Memory directory is created exactly once on first run and persists across alarm fires.
- No `fault` entries under `com.wakeproof.memory`.
- `profile.md` and `history.jsonl` both have `isExcludedFromBackupKey=true` (verify via a separate debug Swift snippet reading `resourceValues(forKeys: [.isExcludedFromBackupKey])` from the file URL, or — more pragmatically — confirm absence of those files in an iCloud Backup listing).
- Token budget: a verify-without-memory call produces a request body within ~5% of the Day 3 baseline size (additional v3 system-prompt text is ~900 chars more than v2); a verify-with-memory call produces ≤ that + ~2000 chars (the memory-block rendered cap).
- Total API credit burn for Tests 14+15+16 ≤ ~$0.05 in Anthropic console.
