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

## How to wire this into the Xcode project (one-time, ~30 seconds)

The tests are committed but the test **target** isn't yet (test targets
require xcode-project surgery that's risky to do via script — the user
adds it once via the Xcode UI).

1. Open `WakeProof/WakeProof.xcodeproj` in Xcode.
2. **File → New → Target** (`⌘ N`).
3. Pick **iOS → Test → Unit Testing Bundle**, click **Next**.
4. Name: `WakeProofTests`. Team: same as the app target. Target to be tested: `WakeProof`.
5. Click **Finish**. Xcode creates a default `WakeProofTests/` group.
6. Xcode 16 synchronized groups will auto-discover the existing files in
   `WakeProof/WakeProofTests/` once you point the new target at them:
   - In the project navigator, select the freshly-created `WakeProofTests` group
     and delete its single placeholder file (`WakeProofTests.swift`).
   - Right-click the empty group → **Add Files to "WakeProof"…** → select all
     four files in `WakeProof/WakeProofTests/` (excluding this README) →
     **Add to target: WakeProofTests** → **Finish**.

Run the suite with `⌘ U` or:

```bash
xcodebuild -project WakeProof.xcodeproj \
  -scheme WakeProof \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  test
```

## Adding more tests

Drop new `*Tests.swift` files in this directory. Synchronized groups will pick
them up automatically the next time the target builds.
