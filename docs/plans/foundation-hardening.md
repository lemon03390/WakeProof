# Foundation Hardening Implementation Plan

> **For agentic workers:** Use `subagent-driven-development` skill to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Phase gates (end-of-phase validations) are **hard checkpoints** — do NOT advance past a gate that has not passed.

**Goal:** Turn the current build-only scaffold into a validated runtime-capable foundation: (a) no crash on any permission prompt, (b) audio keepalive survives 30 min + 8 h backgrounded, (c) onboarding end-to-end persists baseline photo via SwiftData, (d) git history pushed and annotated. Everything above this layer (alarm scheduling, Opus 4.7 vision, stretch features) depends on this plan's phase gates passing.

**Architecture:** Phase-based, with explicit verification gates between phases. Each gate is a binary PASS/FAIL on either a device test, a log inspection, or both. On FAIL: stop, diagnose, do not forward-roll into the next phase. Phase 6 (GO/NO-GO) has a codified pivot path into Decision 8 (iOS Clock + Shortcuts hybrid) — see `docs/go-no-go-audio-test.md` pivot section.

**Tech Stack:** Swift + SwiftUI + SwiftData (iOS 26.x target), `AVAudioSession`, `HKHealthStore`, `CMMotionActivityManager`, `UNUserNotificationCenter`, Apple-native `afconvert` + Python 3 `wave`/`struct` for audio asset generation (no brew/ffmpeg dependency).

**Non-goals for this plan:** Alarm scheduling UI, Claude API integration, vision verification, HealthKit read queries, stretch features. Those go into follow-up plans after Phase 8 passes.

---

## File Structure

New or modified in this plan:

| Path | Action | Responsibility |
|---|---|---|
| `WakeProof/WakeProof/Info.plist` | Create | Explicit usage descriptions + `UIBackgroundModes` |
| `WakeProof/WakeProof/WakeProof.entitlements` | Create (via Xcode UI) | Background Modes + HealthKit + critical-alerts request |
| `WakeProof/WakeProof.xcodeproj/project.pbxproj` | Modify | Switch from `GENERATE_INFOPLIST_FILE=YES` to explicit `INFOPLIST_FILE` + entitlements reference |
| `WakeProof/WakeProof/Resources/silence.m4a` | Create | 30 s inaudible AAC for foreground audio session keepalive |
| `WakeProof/WakeProof/Resources/test-tone.m4a` | Create | 2 s 1 kHz sine for GO/NO-GO audible verification |
| `WakeProof/WakeProof/Alarm/AudioSessionKeepalive.swift` | Modify | Add 30-min structured-concurrency scheduler at end of `start()` |
| `WakeProof/WakeProof/App/WakeProofApp.swift` | Modify | Add `#if DEBUG` test-tone button to `RootView` |
| `docs/go-no-go-audio-test.md` | Modify (appendix) | Record PASS/FAIL + timestamps + device conditions after Phase 6 and Phase 8 |
| `docs/technical-decisions.md` | Modify (only if Phase 6 FAILS) | Add Decision 8: pivot to iOS Clock + Shortcuts hybrid |
| `docs/day-2-priorities.md` | Create (Phase 8) | Top-3 priorities for next session, per build-plan.md convention |

---

## Phase 0 — Pre-flight

**Goal of phase:** ensure we have an observable-and-recoverable baseline before touching runtime-sensitive code.

### Task 0.1: Push existing commits to GitHub

**Files:** n/a (git operation)
**Dependencies:** none

- [ ] **Step 1: Verify unpushed commit**

Run: `git -C /Users/mountainfung/Desktop/WakeProof-Hackathon log --oneline origin/main..main`
Expected: shows `ba5e7f3 Fix: rename PermissionStep.body → message to avoid View.body collision`

- [ ] **Step 2: Push** (REQUIRES USER CONFIRMATION per CLAUDE.md 費用安全 rules)

Run: `git -C /Users/mountainfung/Desktop/WakeProof-Hackathon push origin main`
Expected: `ba5e7f3` lands on `origin/main`

- [ ] **Step 3: Verify**

Run: `git -C /Users/mountainfung/Desktop/WakeProof-Hackathon ls-remote origin main`
Expected: output hash matches local `git rev-parse main`

### Task 0.2: Verify Console log pipeline (user-driven)

**Files:** n/a (macOS Console.app)
**Dependencies:** Task 0.1

- [ ] **Step 1:** Open macOS Console.app
- [ ] **Step 2:** Plug iPhone via USB, select device in sidebar
- [ ] **Step 3:** Set subsystem filter to `com.wakeproof` (matches both `.audio` and `.permissions` categories)
- [ ] **Step 4:** Launch current app build on device
- [ ] **Step 5:** Confirm visible log lines appear — even one `"Audio session activated"` or `"missingSilenceAsset"` proves the log pipeline works

**Phase 0 gate (HARD):** `origin/main == ba5e7f3` AND Console streams at least one WakeProof subsystem log line. If Console shows nothing, Phase 6 will be undiagnosable — stop and fix logging first.

---

## Phase 1 — Explicit Info.plist

**Goal of phase:** Replace auto-generated Info.plist with a checked-in file containing all permission usage descriptions + `UIBackgroundModes`. Fixes the runtime-crash risk where any permission request today would crash (no description strings).

### Task 1.1: Create Info.plist with all keys

**Files:**
- Create: `WakeProof/WakeProof/Info.plist`

**Dependencies:** Phase 0 gate passed

- [ ] **Step 1: Create Info.plist** with exact content.

Note on omission: `docs/info-plist-requirements.md` lists `NSLocationWhenInUseUsageDescription` as present only because a dependency requests it. This project has no such dependency (pure Swift + SwiftUI + SwiftData + HealthKit + CoreMotion + AVFoundation — none of these require location). Intentionally omitting it; re-add only if a future build reports a location-access symbol.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>NSCameraUsageDescription</key>
    <string>WakeProof needs the camera to verify you're actually out of bed when your alarm rings. We take one photo per wake attempt, stored locally on your device.</string>

    <key>NSHealthShareUsageDescription</key>
    <string>WakeProof reads your sleep data from Apple Health to show you a summary of last night's rest when you successfully wake up.</string>

    <key>NSMotionUsageDescription</key>
    <string>WakeProof uses motion data to detect your natural awakening window and time your alarm to a lighter sleep phase. Motion stays on your device.</string>

    <key>NSUserNotificationsUsageDescription</key>
    <string>WakeProof sends alarm notifications so you wake up on time, even if the app is backgrounded.</string>

    <key>NSPhotoLibraryAddUsageDescription</key>
    <string>WakeProof optionally saves your baseline reference photo to your Photos library as a backup.</string>

    <key>UIBackgroundModes</key>
    <array>
        <string>audio</string>
        <string>fetch</string>
    </array>

    <key>UILaunchScreen</key>
    <dict/>

    <key>UIApplicationSceneManifest</key>
    <dict>
        <key>UIApplicationSupportsMultipleScenes</key>
        <true/>
    </dict>
</dict>
</plist>
```

### Task 1.2: Point Xcode at the explicit Info.plist

**Files:**
- Modify: `WakeProof/WakeProof.xcodeproj/project.pbxproj` (Debug + Release per-target build configs)

**Dependencies:** Task 1.1

- [ ] **Step 1: Locate the exact lines to modify (line numbers drift — use grep, not memorized offsets):**

```bash
grep -n "GENERATE_INFOPLIST_FILE\|INFOPLIST_KEY_UI" /Users/mountainfung/Desktop/WakeProof-Hackathon/WakeProof/WakeProof.xcodeproj/project.pbxproj
```
Expected: 2 occurrences of `GENERATE_INFOPLIST_FILE = YES;` (one Debug, one Release) plus 5 `INFOPLIST_KEY_UI*` entries in each config.

- [ ] **Step 2:** In both per-target Debug and Release build configs (the ones inside the PBXNativeTarget, NOT the PBXProject-level configs):
    - **Add:** `INFOPLIST_FILE = WakeProof/Info.plist;`
    - **Remove:** `GENERATE_INFOPLIST_FILE = YES;`
    - **Remove:** all `INFOPLIST_KEY_UIApplicationSceneManifest_Generation`, `INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents`, `INFOPLIST_KEY_UILaunchScreen_Generation`, `INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad`, `INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone` entries (they are now covered by the explicit plist, and duplicate keys cause build failures)

- [ ] **Step 2:** In Xcode: Product → Clean Build Folder → Build.
  Expected: builds cleanly with no "Multiple commands produce Info.plist" error.

- [ ] **Step 3: Commit**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon add WakeProof/WakeProof/Info.plist WakeProof/WakeProof.xcodeproj/project.pbxproj
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon commit -m "Phase 1: use explicit Info.plist for usage descriptions and background modes"
```

### Task 1.3: Device verification — all 5 prompts appear

**Files:** n/a (device test)
**Dependencies:** Task 1.2

- [ ] **Step 1:** Delete existing `WakeProof` app from iPhone (clears prior permission state)
- [ ] **Step 2:** Fresh install via Xcode
- [ ] **Step 3:** Launch → step through onboarding:
    - Welcome → Begin
    - Notifications permission prompt **appears** (grant or deny)
    - Camera permission prompt **appears**
    - HealthKit permission prompt **appears** (expected to silently fail without capability — will fix in Phase 2)
    - Motion permission prompt **appears**
    - Baseline photo screen **loads** (do not capture yet — save for Phase 7)

**Phase 1 gate (HARD):** All 4 iOS permission prompts render (HealthKit may not actually prompt until Phase 2 capability is added — that's expected). Zero crashes. Onboarding proceeds to baseline screen.

---

## Phase 2 — Capabilities & Entitlements

**Goal of phase:** Enable Background Modes (Audio) so the foreground audio session survives lock+background, and HealthKit so the health prompt actually prompts.

### Task 2.1: Add capabilities via Xcode UI (user-driven)

**Files (Xcode will generate):**
- Create: `WakeProof/WakeProof/WakeProof.entitlements`
- Modify: `WakeProof/WakeProof.xcodeproj/project.pbxproj` (capability references)

**Dependencies:** Phase 1 gate passed

- [ ] **Step 1:** Xcode → target `WakeProof` → Signing & Capabilities → `+ Capability` → **Background Modes** → tick:
    - ✅ Audio, AirPlay, and Picture in Picture
    - ✅ Background fetch

- [ ] **Step 2:** Same panel → `+ Capability` → **HealthKit**. Do not tick "Clinical Health Records".

- [ ] **Step 3:** Open the auto-generated `WakeProof.entitlements` file → add to the dict:

```xml
<key>com.apple.developer.usernotifications.critical-alerts</key>
<true/>
```

(Apple will reject critical-alerts on a personal dev account — that is expected; the request being present is a demo narration point per CLAUDE.md and `docs/info-plist-requirements.md`.)

- [ ] **Step 4:** Build on device.

- [ ] **Step 5:** Check Console log. Expected new line when app starts:
  `com.wakeproof.audio session: "Audio session activated. category=AVAudioSessionCategoryPlayback isOtherAudioPlaying=..."`
  (category must be `playback`, not `ambient`. If it's not `playback`, Background Modes capability did not take — re-check Step 1.)

- [ ] **Step 6: Commit**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon add WakeProof/WakeProof/WakeProof.entitlements WakeProof/WakeProof.xcodeproj/project.pbxproj
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon commit -m "Phase 2: add Background Modes + HealthKit capabilities; request critical-alerts entitlement"
```

**Phase 2 gate (HARD):**
- Console log shows `category=AVAudioSessionCategoryPlayback` at start
- Fresh install → onboarding → HealthKit prompt actually renders (not silently skipped)
- App does NOT yet play audio (silence.m4a still missing — that's Phase 3)

---

## Phase 3 — Audio assets

**Goal of phase:** Embed the two audio files required by `AudioSessionKeepalive` without any third-party dependency. macOS `afconvert` + Python 3 `wave` are sufficient and deterministic.

### Task 3.1: Generate silence.m4a and test-tone.m4a

**Files:**
- Create: `WakeProof/WakeProof/Resources/silence.m4a` (30 s, 44.1 kHz, mono, AAC 64 kbps)
- Create: `WakeProof/WakeProof/Resources/test-tone.m4a` (2 s, 1000 Hz sine, same codec)

**Dependencies:** Phase 2 gate passed

- [ ] **Step 1:** Create Resources folder:

```bash
mkdir -p /Users/mountainfung/Desktop/WakeProof-Hackathon/WakeProof/WakeProof/Resources
```

- [ ] **Step 2:** Generate silence WAV then AAC:

```bash
python3 -c "
import wave
with wave.open('/tmp/silence.wav', 'w') as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(44100)
    w.writeframes(b'\x00\x00' * 44100 * 30)
"
afconvert -f m4af -d aac -b 64000 /tmp/silence.wav \
  /Users/mountainfung/Desktop/WakeProof-Hackathon/WakeProof/WakeProof/Resources/silence.m4a
```

Expected: `silence.m4a` is ~250 KB, `afinfo silence.m4a` reports 30 s duration, AAC format.

- [ ] **Step 3:** Generate test-tone WAV then AAC:

```bash
python3 -c "
import wave, math, struct
frames = bytearray()
for i in range(44100 * 2):
    val = int(32767 * 0.5 * math.sin(2 * math.pi * 1000 * i / 44100))
    frames += struct.pack('<h', val)
with wave.open('/tmp/tone.wav', 'w') as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(44100)
    w.writeframes(bytes(frames))
"
afconvert -f m4af -d aac -b 64000 /tmp/tone.wav \
  /Users/mountainfung/Desktop/WakeProof-Hackathon/WakeProof/WakeProof/Resources/test-tone.m4a
```

Expected: `test-tone.m4a` is ~20 KB, `afinfo` reports 2 s duration.

- [ ] **Step 4:** Verify `afinfo` on both files:

```bash
afinfo /Users/mountainfung/Desktop/WakeProof-Hackathon/WakeProof/WakeProof/Resources/silence.m4a | head -8
afinfo /Users/mountainfung/Desktop/WakeProof-Hackathon/WakeProof/WakeProof/Resources/test-tone.m4a | head -8
```

Expected output for each: `File type ID: m4af`, `Data format: 1 ch, 44100 Hz, 'aac'`, duration matches expectation.

- [ ] **Step 5:** Build app. Because `WakeProof.xcodeproj` uses `PBXFileSystemSynchronizedRootGroup`, the new files under `WakeProof/WakeProof/Resources/` are auto-added to the build target.

- [ ] **Step 6: Commit**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon add WakeProof/WakeProof/Resources/silence.m4a WakeProof/WakeProof/Resources/test-tone.m4a
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon commit -m "Phase 3: add silence + 1kHz test-tone AAC assets for audio keepalive"
```

### Task 3.2: Device verification — silent loop starts cleanly

**Files:** n/a (device test)
**Dependencies:** Task 3.1

- [ ] **Step 1:** Fresh install → launch app → check Console log.
  Expected: `com.wakeproof.audio session: "Silent loop started"`
  NOT expected: `missingSilenceAsset` or `playerRefusedToStart`

**Phase 3 gate (HARD):** `Silent loop started` log line present; no keepalive error log. (Audibility of test-tone still unverified — that is Phase 4.)

---

## Phase 4 — Manual test-tone verification button

**Goal of phase:** Confirm the audio format + playback path are actually audible **before** trusting a 30-min unattended test. If the m4a file itself is malformed or the silent-mode escape doesn't work, we find out in 10 seconds instead of 30 minutes.

### Task 4.1: Add DEBUG-only test-tone button

**Files:**
- Modify: `WakeProof/WakeProof/App/WakeProofApp.swift` (RootView, lines ~49-66)

**Dependencies:** Phase 3 gate passed

- [ ] **Step 1:** Replace the existing `RootView` body in `WakeProof/WakeProof/App/WakeProofApp.swift`:

```swift
struct RootView: View {
    @Query private var baselines: [BaselinePhoto]
    @Environment(AudioSessionKeepalive.self) private var audioKeepalive

    var body: some View {
        if baselines.isEmpty {
            OnboardingFlowView()
        } else {
            VStack(spacing: 16) {
                Text("WakeProof")
                    .font(.largeTitle).bold()
                Text("Onboarded. Home screen arrives in a later plan.")
                    .foregroundStyle(.secondary)

                #if DEBUG
                Button("Fire test tone") {
                    audioKeepalive.triggerTestTone()
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 24)
                #endif
            }
            .padding()
        }
    }
}
```

- [ ] **Step 2:** Build + install on device.

- [ ] **Step 3: Prepare conditions**
    - Ring/silent switch: **SILENT**
    - Volume: 50%
    - DND / Focus: OFF
    - Low Power Mode: OFF

- [ ] **Step 4:** If onboarding not yet completed, complete it with a throwaway baseline photo (we will redo in Phase 7 with a proper image).

- [ ] **Step 5:** On home screen, tap `Fire test tone`.
  Expected: audible 1 kHz tone plays (~2 s), **even with silent switch on** (this proves `.playback` category + Background Modes audio entitlement are effective).

- [ ] **Step 6: If no tone heard:** STOP. This is a Phase 4 failure, not a Phase 6 failure — easier to debug now. Check in order:
    1. `afinfo test-tone.m4a` — is duration 2 s, AAC, mono?
    2. Console: does `Test tone triggered at ...` log line appear?
    3. Console: is `category=AVAudioSessionCategoryPlayback`?
    4. Silent switch — confirm it's actually SILENT (iOS sometimes requires a physical toggle to re-register)
    5. Try with silent switch OFF as a second data point

- [ ] **Step 7: Commit (only if Step 5 PASSED)**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon add WakeProof/WakeProof/App/WakeProofApp.swift
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon commit -m "Phase 4: add DEBUG test-tone button for audio path verification"
```

**Phase 4 gate (HARD):** Tone is audible at 50% volume with silent switch ON. Console log shows `Test tone triggered at <ISO8601>`.

---

## Phase 5 — 30-min auto-fire scheduler

**Goal of phase:** Have `AudioSessionKeepalive.start()` auto-fire `triggerTestTone()` exactly 30 minutes after app launch, without further user interaction.

### Task 5.1: Add structured-concurrency 30-min timer

**Files:**
- Modify: `WakeProof/WakeProof/Alarm/AudioSessionKeepalive.swift` (append to `start()` method, after line 54)

**Dependencies:** Phase 4 gate passed

- [ ] **Step 1:** In `AudioSessionKeepalive.swift`, at the end of `start()` (after `observeInterruptions()` call), append:

```swift
        // Schedule the 30-min GO/NO-GO auto-fire tone. One-shot; this is the foundation validation test.
        // Weak self avoids retaining the singleton across the sleep window.
        Task { @MainActor [weak self] in
            let intervalSeconds: UInt64 = 30 * 60
            self?.logger.info("30-min test tone scheduled for \(Date().addingTimeInterval(TimeInterval(intervalSeconds)).ISO8601Format(), privacy: .public)")
            try? await Task.sleep(for: .seconds(Double(intervalSeconds)))
            self?.logger.info("30-min mark reached — firing test tone")
            self?.triggerTestTone()
        }
```

- [ ] **Step 2:** Build cleanly (no warnings).

- [ ] **Step 3:** Launch on device. Console log should immediately show:
  `30-min test tone scheduled for 2026-04-22T...`
  with a timestamp exactly 30 minutes out from app launch.

- [ ] **Step 4: Commit**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon add WakeProof/WakeProof/Alarm/AudioSessionKeepalive.swift
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon commit -m "Phase 5: schedule 30-min unattended test tone for GO/NO-GO validation"
```

**Phase 5 gate (HARD):** Log shows scheduled timestamp. No code is asserted to fire yet — that is Phase 6.

---

## Phase 6 — GO/NO-GO live 30-min unattended test

**Goal of phase:** Validate that the foreground audio session survives 30 min of background + locked screen + silent mode on a real device. This is the architecture-defining test per `docs/go-no-go-audio-test.md`.

### Task 6.1: Run the test

**Files:**
- Modify (post-test only): `docs/go-no-go-audio-test.md` (append appendix)

**Dependencies:** Phase 5 gate passed

- [ ] **Step 1: Conditions checklist** (all must be true before starting):
    - Device battery ≥ 80%, plugged into charger
    - Volume: 50%
    - Ring/silent switch: **SILENT**
    - DND / Focus: **OFF**
    - Low Power Mode: **OFF**
    - Console.app connected and streaming `com.wakeproof` subsystem logs

- [ ] **Step 2:** Force-quit WakeProof (swipe up from app switcher) to guarantee fresh launch.

- [ ] **Step 3:** Launch WakeProof fresh. Note exact timestamp.
  Console should show, in order:
    - `Audio session activated. category=AVAudioSessionCategoryPlayback isOtherAudioPlaying=false`
    - `Silent loop started`
    - `30-min test tone scheduled for <T + 30 min>`

- [ ] **Step 4:** Lock screen. Put device face-down. Do NOT touch for 30 minutes.

- [ ] **Step 5:** At T+30min ±10s:
    - **PASS:** Audible 1 kHz tone plays. Console shows `30-min mark reached` then `Test tone triggered at ...`.
    - **FAIL:** No tone. Console may show an interruption log, a route change, or nothing (process terminated).

- [ ] **Step 6 (PASS path):** Screen-record the Console log showing `Silent loop started` through `Test tone triggered` as the evidence artifact. Save to `~/Desktop/wakeproof-phase6-pass.mov` (not `/tmp/` — macOS clears `/tmp/` on reboot and we want this artifact for demo-day reference). The file is intentionally not committed (binary, large, device-specific) — note its existence in the appendix below. Append to `docs/go-no-go-audio-test.md`:

```markdown
## Appendix: Phase 6 Result (2026-04-22)

**Status:** PASS

**Conditions:** battery 80%+ plugged, volume 50%, silent switch ON, DND OFF, LPM OFF, iOS 26.x on <device model>.

**Timestamps:**
- App launched: <ISO8601>
- Silent loop started: <ISO8601>
- 30-min mark: <ISO8601>
- Tone audible: yes (~2 s, 1 kHz)

**Notes:** <any interruption logs observed during the 30-min window, if any>
```

Then commit:

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon add docs/go-no-go-audio-test.md
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon commit -m "Phase 6 PASS: 30-min unattended audio session test validated on-device"
```

- [ ] **Step 6 (FAIL path):** Do not retry. Do not edit code. Execute the pivot:
    1. Draft **Decision 8** in `docs/technical-decisions.md` documenting the hybrid iOS Clock + Shortcuts architecture per `docs/go-no-go-audio-test.md` pivot section
    2. Commit the Decision 8 draft
    3. Still start the Phase 8 overnight 8h run — failure data is useful for justifying the pivot in the demo narrative
    4. Surface to user with a clear status summary; do not silently roll into Phase 7

**Phase 6 gate (HARD):** Either (a) PASS documented in go-no-go-audio-test.md appendix, OR (b) FAIL with Decision 8 pivot documented. No other state exits this phase.

---

## Phase 7 — Onboarding end-to-end + SwiftData persistence

**Goal of phase:** Validate that the full onboarding flow completes with a real captured photo and that SwiftData actually persists across force-quit.

### Task 7.1: Clean install → full onboarding → persistence check

**Files:** n/a (device test)
**Dependencies:** Phase 6 PASS (or explicit user go-ahead after Phase 6 pivot — onboarding UI still needs to work regardless of audio architecture)

- [ ] **Step 1:** Delete app from device. Fresh install.

- [ ] **Step 2:** Launch → walk through every screen:
    - Welcome → Begin
    - Notifications → Enable (or Deny — both paths should advance)
    - Camera → Enable
    - HealthKit → Enable (or Skip)
    - Motion → Enable (or Skip)
    - Baseline photo screen:
        - Tap `Capture baseline` → camera opens
        - **Actually walk to the physical location** you will use as your wake-location (kitchen counter, bathroom sink, desk — pick one, commit)
        - Take a photo in the lighting you will see tomorrow morning
        - Enter a location label (e.g. "kitchen counter")
        - Tap `Save & continue`
    - DoneStep — "You're set." visible

- [ ] **Step 2 verification:** Console should log permission state decisions for every requested permission.

- [ ] **Step 3:** Force-quit (swipe up from app switcher). Wait 5 seconds.

- [ ] **Step 4:** Relaunch app.
  Expected: App skips onboarding entirely and shows the home placeholder with the DEBUG test-tone button. (If onboarding shows again, SwiftData persistence is broken — stop and diagnose.)

- [ ] **Step 5: Document + push**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon status    # should be clean
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon push origin main   # REQUIRES USER CONFIRMATION
```

**Phase 7 gate (HARD):** Full onboarding completes with real baseline photo. Force-quit + relaunch skips onboarding. All commits through Phase 6 pushed to origin.

---

## Phase 8 — 8-hour overnight run + Day 2 priorities prep

**Goal of phase:** Collect the real 8-hour deployment-condition data. Even a Phase 6 PASS only covers 30 minutes; an 8h run is the actual stress test.

### Task 8.1: Start the 8h unattended run

**Files:** n/a (device test, hands-off)
**Dependencies:** Phase 7 gate passed (or Phase 6 FAIL — data is still useful for pivot)

- [ ] **Step 1:** We need the 30-min scheduler replaced with an 8h scheduler for this run OR we accept that Phase 5's scheduler will fire once at T+30min and nothing more will be measured after. For measurement purposes, replace the sleep duration temporarily:

**Option A (quickest):** Keep `30 * 60` as-is. The 30-min fire at T+30 proves survival for 30 min; we then visually/log-inspect the app at T+8h the next morning to confirm process still live and audio session still active (log will show any `interruption BEGAN` events during the window).

**Option B (more informative):** Temporarily edit the constant to `8 * 60 * 60` and rebuild. Fires a tone at 8h sharp — hard evidence of 8h survival. Must be reverted before the next work session.

Pick one. For the more robust path without touching code again, use Option A plus plan a Phase 8.2 morning-after log inspection.

If Option B chosen, execute these steps in addition to the ones below:

- [ ] **Option B Step 1:** Edit `AudioSessionKeepalive.swift`, change `let intervalSeconds: UInt64 = 30 * 60` to `let intervalSeconds: UInt64 = 8 * 60 * 60`. Rebuild.
- [ ] **Option B Step 2:** Proceed with Step 2 below.
- [ ] **Option B Step 3 (mandatory, executed in Phase 8.2 morning-after):** Revert `intervalSeconds` back to `30 * 60`. Rebuild. Verify Console on next launch shows a ~30-min-out scheduled timestamp, not 8h. Commit the revert with message `Phase 8: revert 8h test-tone interval back to 30 min after overnight validation`. Do NOT merge the 8h-interval code into any long-lived branch.

- [ ] **Step 2:** Conditions at bedtime:
    - Battery ≥ 90% (unplugged — this is the realistic condition; if overnight fails on battery, morning alarms fail)
    - Volume: 50%
    - Silent switch: SILENT
    - DND / Focus: as you would normally sleep
    - Low Power Mode: OFF (LPM aggressively kills audio sessions — do not let this be the variable)

- [ ] **Step 3:** Force-quit + relaunch WakeProof fresh. Confirm Console shows `Silent loop started`.

- [ ] **Step 4:** Lock phone. Place face-down. Go sleep.

### Task 8.2: Morning-after log inspection

**Files:**
- Modify: `docs/go-no-go-audio-test.md` (append 8h result to appendix)
- Create: `docs/day-2-priorities.md`

**Dependencies:** Task 8.1 complete (overnight elapsed)

- [ ] **Step 1:** Reconnect to Console.app. Filter `com.wakeproof.audio`.

- [ ] **Step 2:** Look for:
    - `Audio session interruption BEGAN` entries (count them, note times)
    - `Audio session interruption ENDED` entries (were they followed by successful reactivation?)
    - `Audio route changed` entries (usually benign — headphones, Bluetooth, etc.)
    - Absence of the `30-min mark reached` or `Test tone triggered` lines after launch = process was killed before the timer fired

- [ ] **Step 3:** Append to `docs/go-no-go-audio-test.md`:

```markdown
## Appendix: Phase 8 Overnight Result (YYYY-MM-DD)

**Status:** PASS / DEGRADED / FAIL

**Conditions:** <battery start%>, <battery end%>, silent switch <on/off>, DND <state>, LPM <state>, iOS <version>, <device model>

**Duration observed alive:** <N hours M minutes>
**Interruptions:** <count>, types: <calls | notifications | Bluetooth route change | ...>
**Session survived to morning:** yes / no

**Notes:** <any anomalies>
```

- [ ] **Step 4:** Create `docs/day-2-priorities.md` with top-3 priorities for the next working session, chosen from `docs/build-plan.md` Day 2 section but re-prioritized based on Phase 6/8 outcomes:

```markdown
# Next Session — Top 3 Priorities

Generated after Phase 8 overnight completion on YYYY-MM-DD.

## Phase 8 outcome summary
- Phase 6 (30-min): PASS / FAIL
- Phase 8 (overnight 8h): PASS / DEGRADED / FAIL
- Decision 8 pivot needed: yes / no

## Priorities (ordered)
1. <highest-leverage next step based on outcomes>
2. <second>
3. <third>

## Deferred from build-plan Day 2
<list items from docs/build-plan.md Day 2 that do not make the top 3, with one-line justification each>
```

- [ ] **Step 5: Commit + push**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon add docs/go-no-go-audio-test.md docs/day-2-priorities.md
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon commit -m "Phase 8: record 8h overnight result and next-session priorities"
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon push origin main   # REQUIRES USER CONFIRMATION
```

**Phase 8 gate (HARD):** Overnight outcome documented. `day-2-priorities.md` written. Git history pushed. Foundation phase closed.

---

## Cross-phase dependency summary

```
0 (push + logs) ── hard gate ──▶ 1 (Info.plist) ── hard gate ──▶ 2 (capabilities)
                                                                    │
                                                                    ▼ hard gate
                                                  3 (audio assets) ◀─┘
                                                         │ hard gate
                                                         ▼
                                                  4 (manual tone button) ── hard gate ──▶ 5 (30-min scheduler)
                                                                                                 │ hard gate
                                                                                                 ▼
                                         ┌───────────────────────────────────── 6 (GO/NO-GO 30-min) ──┐
                                         │ PASS                                                        │ FAIL
                                         ▼                                                             ▼
                                     7 (onboarding E2E)                                     Decision 8 pivot + continue 8h run
                                         │ hard gate
                                         ▼
                                     8 (8h overnight + priorities)
```

## Pivot triggers (do not forward-roll past these)

| Condition | Action |
|---|---|
| Phase 1 gate fails (any prompt crashes) | Stop. Fix Info.plist keys before Phase 2. |
| Phase 2 log shows `category=ambient` or missing | Stop. Background Modes capability did not apply; recheck Xcode signing. |
| Phase 3 still logs `missingSilenceAsset` | Stop. Resource folder not in sync group; manually verify target membership. |
| Phase 4 tone inaudible | Stop. Do not proceed to 30-min test — debug audibility first. |
| Phase 6 tone inaudible at T+30 | Execute Decision 8 pivot. Do not retry. |
| Phase 7 onboarding loops after force-quit | SwiftData persistence broken; must fix before any feature work. |
| Phase 8 overnight process killed < 4h | Data point supporting Decision 8 even if Phase 6 PASSed. Reassess architecture. |

## Follow-up plans (out of scope for this document)

Created after this plan closes:
- `docs/plans/alarm-core.md` — scheduling UI, ramped audio, camera auto-launch (Day 2 equivalent)
- `docs/plans/vision-verification.md` — Claude Opus 4.7 prompt + retry + anti-spoofing (Day 3 equivalent)
- `docs/plans/polish-and-stretch.md` — HealthKit read, morning briefing, one stretch pick (Day 4 equivalent)
- `docs/plans/demo-submission.md` — video, README, submission (Day 5 equivalent)

Day numbers from `docs/build-plan.md` are **reference only**. Advance when the current plan's gates pass, not on calendar rollover.
