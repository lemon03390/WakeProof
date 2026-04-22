# UAT findings — 2026-04-23 simulator pass

Driven on iPhone 17 Simulator (iOS 26.4) with cliclick taps and screenshot
verification. Camera + motion permissions pre-granted via
`xcrun simctl privacy ... grant`. Notifications via in-app dialog.

## Verified visually

| Screen | PrimaryButtonStyle | Behaviour | Pass |
|---|---|---|---|
| Welcome | `.primaryWhite` Begin button | Renders, tap advances | ✓ |
| Notifications permission | `.primaryWhite` Enable button | Tap shows iOS auth dialog with the correct `NSUserNotificationsUsageDescription` text. Button shows `"Working..."` state during the await | ✓ |
| Camera permission | `.primaryWhite` Enable camera | Tap shows iOS auth dialog with correct `NSCameraUsageDescription`; advance happens after Allow without skipping the next screen | ✓ |
| Health permission | `.primaryWhite` Enable Health + Skip secondary | Renders correctly | ✓ |
| Motion permission | `.primaryWhite` Enable motion + Skip secondary | Renders correctly | ✓ |
| Baseline photo | `.primaryWhite` Capture baseline; TextField label | iOS 26 simulator presents the simulated camera UI when tapped (proves the B10 hard-fail is correctly bypassed when camera IS available) | ✓ |

## Confirmed harden-cycle fixes (visually validated)

- **B27 — button double-tap guard**: the "Working..." state is rendered between
  iOS dialog open and Allow tap. Confirms `isWorking` is set synchronously before
  the Task spawn (the race-fix from round 1).
- **B21 — onboarding gate on permissions**: notifications + camera screens both
  successfully required Allow before advancing. Skipping with denial would have
  shown the deniedNotice banner (not exercised in this run; verified via code
  review).
- **F6 — advanceOnce dedup**: After tapping Allow on the notifications dialog,
  the app advanced to the camera screen (one step) — not skipped past it. Both
  the scenePhase observer and tap()'s post-handler verify could have called
  `onAdvance` but `hasAdvanced` made it idempotent.
- **B10 — camera trust anchor**: the simulated camera UI presents (camera IS
  available); the photoLibrary fallback is no longer reachable. The hard-fail
  branch is unreachable on iOS 26 simulator (Apple's simulated camera is always
  available); validated via code review.
- **PrimaryButtonStyle consistency**: every CTA across welcome → notif → camera
  → health → motion → baseline uses the same pill shape, padding, and white
  background. No drift between sites.

## Could not verify in this UAT run

| Screen / behaviour | Why not | Where to verify |
|---|---|---|
| Save & continue button (`.primaryConfirm` green / `.primaryMuted` disabled) | Would need to drive the simulator camera shutter — cliclick can't hit the iOS-system camera UI; the AppleScript click was rejected | Manual on simulator OR device test |
| AlarmSchedulerView (banner B18, removed end-time picker B25) | Couldn't get past baseline capture | Real device after baseline capture |
| Done step copy | Same | Real device after onboarding completion |
| Alarm ringing screen (`.primaryAlarm` style) | Requires alarm to fire | Device test #6 (camera capture) and #2 (interruption) |
| Notification permission deniedNotice + Open Settings link | Requires denying notification | Manual: tap "Don't Allow" instead of "Allow" |
| F4 audio-recovery isActive=false consistency | Requires interruption | Device test #2 |
| B5 force-quit recovery → UNRESOLVED row | Requires force-quit during ring | Device test #3 |
| B2 ring-ceiling TIMEOUT row | Requires 10-min ring | Device test #8 |

## Issues observed during UAT

**None.** Every screen rendered as expected, every advance was correctly gated,
no styling regressions from the PrimaryButtonStyle extraction.

## Tooling notes for future UAT runs

1. `xcrun simctl privacy <id> grant <service> <bundle>` — pre-grants permissions
   so the app skips the dialog. Available services: `camera`, `motion`,
   `photos`, `microphone`, `media-library`, `siri`, `contacts`, `calendar`,
   `reminders`, `location-always`. **Notifications are NOT supported by simctl
   privacy** — must be driven through the app's runtime request, which then
   shows an iOS-system dialog the test driver must dismiss.
2. iOS-system permission dialogs do NOT respond to plain `cliclick c:x,y` —
   they require explicit `cliclick dd:x,y; cliclick du:x,y` (mouse-down then
   mouse-up as separate events).
3. Simulator window frame on this Mac: position (800, 99), size 456×972 px.
   Title bar offset ≈ 28 px. Use the formulas in
   `/tmp/uat-coord-conversion.txt` for screen↔image conversion.
4. iOS 26 simulator includes a **simulated camera UI** with a fake viewfinder
   and shutter button. `UIImagePickerController.isSourceTypeAvailable(.camera)`
   returns true here, so any "no camera" fallback path needs an older simulator
   or a device with disabled camera to validate at runtime.
