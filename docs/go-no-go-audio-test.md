# GO/NO-GO Audio Session Test — Day 1

This test decides whether WakeProof's core architecture survives contact with iOS reality. Run it before writing any other code beyond the scaffolding.

## What we're testing

iOS has no public Alarm API. To reliably fire a sound at a specific time with the app backgrounded and the phone locked, we use a **foreground audio session** that plays silent audio overnight and switches to the alarm sound when the trigger time arrives. This is the Alarmy approach.

iOS may terminate background audio sessions under memory pressure, OS updates to background task policy, or in Low Power Mode. If the session dies during the test window, our whole core mechanic fails.

## The test

**Target device:** Vincent's primary iPhone (not simulator, not spare device). Real hardware, real iOS version, real battery conditions.

**Setup:**

1. Install the app with only `AudioSessionKeepalive.swift` wired into `WakeProofApp`.
2. Plug phone in to charger (we'll test unplugged later — get the baseline first).
3. Volume at 50%.
4. Ring/silent switch: SILENT (this is the harder test — confirms entitlement path).
5. Do Not Disturb / Focus: OFF.
6. Low Power Mode: OFF for baseline pass.

**Procedure:**

1. Launch app. Observe debug log confirming audio session activated with `.playback` category.
2. Press home / lock button. Screen off.
3. Leave device for **30 minutes minimum**. Do not touch.
4. At the 30-min mark, the test code triggers a short audible tone (via `AudioSessionKeepalive.triggerTestTone()`).
5. **PASS:** tone plays clearly, even with silent switch on.
6. **FAIL:** no tone, or tone is inaudible (session lost `.playback` category), or app was backgrounded and terminated.

**After baseline pass, repeat with:**

- Unplugged (battery ~80%, then ~30%)
- Low Power Mode ON
- 2 hour duration (overnight simulation — the real deployment needs 8h)
- 8 hour overnight sleep simulation on a non-critical night

## Success criteria

All four runs must produce audible test tone at the scheduled moment. Any failure = pivot.

## Pivot path (if test fails)

Switch to **hybrid architecture:**

- User sets an iOS Clock alarm at their target wake time (the real noise maker).
- WakeProof ships a Shortcut that fires when the Clock alarm is dismissed.
- Shortcut auto-opens WakeProof, which runs the verification flow.
- If verification fails, WakeProof re-triggers a local notification with critical alert + the user's own recorded voice memo as the sound.
- Pitch reframes: "WakeProof is the verification layer Apple's Clock app is missing."

This pivot is weaker on demo impact but recoverable. Don't force the original architecture if the session dies — judges will see it die in the live demo.

## Common reasons the test fails

1. **Missing `Background Modes > Audio, AirPlay, and Picture in Picture`** in target capabilities.
2. **Wrong `AVAudioSession` category** — must be `.playback`, not `.ambient`.
3. **Not calling `setActive(true)` after category change** — silently no-ops.
4. **App in App Store sandbox restrictions** — TestFlight / Xcode-direct install behaves differently than dev-signed builds.
5. **iOS 17+ Ultra Low Power Mode** kills audio sessions aggressively. If this is what kills us, document the constraint and test without ULPM.

## Logging to capture during test

Add these log points before running the test:

- `AVAudioSession.sharedInstance().category` at activation
- `AVAudioSession.sharedInstance().isOtherAudioPlaying`
- Timestamp when app enters background
- Timestamp of any `AVAudioSession.interruptionNotification`
- Timestamp when test tone attempts to play
- Success/fail of the test tone

All go through `Logger(subsystem: "com.wakeproof.audio", category: "session")` so we can pull them with `log show` after the fact.

## Hard deadline

This test must be PASS or FAIL decided by end of Day 1 (Apr 22 HKT evening). Do not proceed to Day 2 alarm work without a clear answer. If the test is still running at bedtime, start the 8-hour overnight run and read results in the morning before beginning Day 2.
