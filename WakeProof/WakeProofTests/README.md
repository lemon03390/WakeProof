# WakeProofTests

Pure-Swift unit tests for the alarm-core logic. They cover the parts that
are reasonable to assert without a device or simulator UI:

- `WakeWindow` — `nextFireDate` across day/midnight boundaries, `composeTime`,
  Codable round-trip + UserDefaults load/save (including corruption fallback).
- `WakeAttempt.Verdict` — `init(legacyRawValue:)` fallback semantics; `verdictEnum`
  computed accessor.
- `CameraCaptureError` — `errorDescription` distinctness + leak avoidance for
  underlying error info.
- `AlarmScheduler` — state-machine transitions (idle ↔ ringing ↔ capturing),
  `fire()` idempotency guard, `lastFireAt` UserDefaults persistence + recovery
  on the next instance, `handleRingCeiling` audit-trail wiring, and
  `updateWindow` re-schedule semantics.

What's **not** here (by design, needs device):
- Audio session keepalive across 8-hour background period
- Notification delivery via UNCalendarNotificationTrigger
- Phone-call interruption + alarm resume
- Camera capture → frame extraction
- Permission prompts

See `docs/device-test-protocol.md` for the on-device validation checklist.

## Running the tests

The `WakeProofTests` target is wired into `WakeProof.xcodeproj` (host: WakeProof
app, productType: `bundle.unit-test`, synchronized root group on the
`WakeProofTests/` directory). Run with `⌘ U` in Xcode or:

```bash
xcodebuild -project WakeProof.xcodeproj \
  -scheme WakeProof \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:WakeProofTests \
  test
```

33 tests across 4 suites, ~0.5 s wall-clock on M-series Mac.

## Adding more tests

Drop new `*Tests.swift` files in this directory. Synchronized groups will pick
them up automatically the next time the target builds.
