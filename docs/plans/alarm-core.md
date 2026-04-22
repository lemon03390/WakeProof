# Alarm Core Implementation Plan

> **For agentic workers:** Use `subagent-driven-development` skill to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Phase gates are **hard checkpoints** — do NOT advance past a gate that has not passed.

**Goal:** End-of-Day-2 deliverable per `docs/build-plan.md` Day 2: user sets a wake window, the alarm rings on a real device at window start, auto-launches the camera, captures a still + 2-sec video, persists the attempt, and returns to an idle state. No Opus 4.7 vision call yet — that is Day 3.

**Architecture:** Three-phase. **Phase A** creates all new files under strict additive-only rules while Phase 6 (the unattended 30-min audio test from `docs/plans/foundation-hardening.md`) is live — no device builds, no edits to any file currently executing on-device. **Phase B** fires only after the user signals Phase 6 concluded; it appends playback methods to `AudioSessionKeepalive.swift`, integrates the new components in `WakeProofApp.swift`, and validates the full Set→Ring→Camera→Save loop on real hardware. **Phase C** runs the multi-phase review pipeline per `CLAUDE.md`.

**Tech Stack:** Swift + SwiftUI (iOS 17+), `UserDefaults` for wake-window persistence (avoids SwiftData schema migration mid-test), `AVFoundation` (`AVAudioPlayer`, `AVAssetImageGenerator`), `UIImagePickerController` in video mode for 2-sec capture, SwiftData (existing `WakeAttempt` + `BaselinePhoto` — additive-optional extensions only). No AVCaptureSession, no new SPM dependencies, no third-party audio tooling.

**Non-goals for this plan:**
- Opus 4.7 vision verification + JSON verdict + self-verification chain (Day 3 plan)
- Anti-spoofing random action prompts, retry/timeout policy (Day 3)
- Critical-alert entitlement runtime flow (pending Apple approval — see `foundation-hardening.md` Phase 2 Step 3)
- HealthKit sleep-summary display, morning briefing (Day 4 Layer 2/3)
- Production-grade alarm sound design (placeholder 10-sec 1 kHz/800 Hz alternating tone ships; real sound is a Day 5 polish pick)
- Motion-based smart-wake-within-window (window-end is captured but unused this plan — reserved for Day 3+)

---

## Critical constraints while Phase 6 runs

The user's other Claude Code instance is overseeing a live 30-min unattended on-device audio test (see `docs/plans/foundation-hardening.md` Phase 6). Breaking it wastes hours. Until the user signals Phase 6 concluded:

- **DO NOT** modify `start()`, `startSilentLoop()`, `triggerTestTone()`, `scheduleUnattendedTestTone()`, or any existing private state in `WakeProof/WakeProof/Alarm/AudioSessionKeepalive.swift`. Phase B Task B.1 appends new methods only; that is permitted.
- **DO NOT** modify `WakeProof/WakeProof/App/WakeProofApp.swift` at all during Phase A. Phase B Task B.4 edits it.
- **DO NOT** add a new `@Model` class to the SwiftData schema. Adding one changes the `ModelContainer(for:)` call, which forces a schema migration on the on-device store that Phase 6 runs against — a rebuild+redeploy during the test would invalidate it. `WakeWindow` is stored in `UserDefaults` instead. `WakeAttempt` extensions are *additive-optional* fields only (SwiftData handles those without schema migration).
- **DO NOT** remove or rename any existing field of `WakeAttempt` or `BaselinePhoto`.
- **DO NOT** run `xcodebuild` with a device destination. Simulator destination only: `-sdk iphonesimulator -destination 'generic/platform=iOS Simulator'`.
- **DO NOT** run `git push`. Local commits only. Per `CLAUDE.md` 費用安全, push requires the user's explicit yes.
- **NOTE on Task A.7:** A.7 modifies `WakeAttempt.swift` in source only. Because Phase A never deploys to the device, no on-device SwiftData migration is triggered while Phase 6 is running. The migration happens the first time Phase B.2's binary installs, by which point Phase 6 has already concluded.

Phase 6 is scheduled to fire at 2026-04-22T08:43:00Z and will conclude shortly after. The user will announce PASS/FAIL. Constraints relax on that signal.

---

## File Structure

New or modified in this plan:

| Path | Action | Responsibility |
|---|---|---|
| `WakeProof/WakeProof/Alarm/WakeWindow.swift` | Create | `Codable` struct with `startHour/startMinute/endHour/endMinute/isEnabled`. Static `load()` / `save()` against `UserDefaults.standard` under a single key. |
| `WakeProof/WakeProof/Alarm/AlarmScheduler.swift` | Create | `@Observable` class. Owns the `WakeWindow` state and a cancellation handle for the next-fire `Task`. Public API: `scheduleNextFireIfEnabled()`, `cancel()`, `fireNow()`, `stopRinging()`. Published state: `window: WakeWindow`, `isRinging: Bool`, `nextFireAt: Date?`. Does not play audio directly — Phase B wires it to `AudioSessionKeepalive`. |
| `WakeProof/WakeProof/Alarm/AlarmSoundEngine.swift` | Create | Volume-ramp + sound-switch escalation policy. Public API: `start(keepalive:)`, `stop()`. Holds a `Task` that ramps volume `0.3 → 1.0` over 60 s via `keepalive.setAlarmVolume(_:)`. Separate from keepalive so escalation policy changes don't require touching the audio-critical file. |
| `WakeProof/WakeProof/Alarm/AlarmSchedulerView.swift` | Create | SwiftUI home view replacing the post-onboarding placeholder. Two `DatePicker(displayedComponents: .hourAndMinute)` controls, `Toggle` for enabled, "Save & schedule" button. `#if DEBUG` "Fire now" button for demo fallback. |
| `WakeProof/WakeProof/Alarm/AlarmRingingView.swift` | Create | Full-screen view shown when `scheduler.isRinging == true`. Large time display, wake-location label (queried from SwiftData `BaselinePhoto`), single "Prove you're awake" button that presents `CameraCaptureView`. No dismiss button — the only exit is a saved `WakeAttempt` via camera. |
| `WakeProof/WakeProof/Verification/CameraCaptureView.swift` | Create | `UIImagePickerController` wrapper in video mode (`mediaTypes=[kUTTypeMovie]`, `videoMaximumDuration=2`, `videoQuality=.typeMedium`). On capture, extracts the middle frame via `AVAssetImageGenerator`, returns `(UIImage, URL)` through a completion closure. |
| `WakeProof/WakeProof/Storage/WakeAttempt.swift` | Modify (additive-only) | Add optional `videoPath: String?`, `triggeredWindowStart: Date?`, `triggeredWindowEnd: Date?`. Existing fields preserved byte-for-byte. |
| `WakeProof/WakeProof/Resources/alarm.m4a` | Create | 10-sec alternating 1 kHz / 800 Hz AAC placeholder, same `python3 wave` + `afconvert` pattern as `test-tone.m4a`. |
| `WakeProof/WakeProof/Alarm/AudioSessionKeepalive.swift` | Modify (Phase B, append-only) | Append `playAlarmSound(url:)`, `stopAlarmSound()`, `setAlarmVolume(_:)` below existing content. New private `alarmPlayer: AVAudioPlayer?`. Existing methods and observed state untouched. |
| `WakeProof/WakeProof/App/WakeProofApp.swift` | Modify (Phase B) | Instantiate `AlarmScheduler` + `AlarmSoundEngine` as `@State`. Register via `.environment()`. Replace the onboarded-placeholder branch of `RootView` with `AlarmSchedulerView`. Add `.fullScreenCover(isPresented:)` presenting `AlarmRingingView`. Call `scheduler.scheduleNextFireIfEnabled()` in `.task` after `audioKeepalive.start()`. |
| `WakeProof/WakeProof/Onboarding/BaselinePhotoView.swift` | Unchanged | The richer `CameraCaptureView` is for verification only; baseline capture's one-shot still is served fine by the existing `UIImagePickerController` wrapper. Reusing `CameraCaptureView` there is a follow-up, not Day 2 scope. |

---

## Phase A — Additive infrastructure (Phase-6 safe)

**Goal of phase:** Land all new files and additive SwiftData extensions without touching anything currently running on-device. Verify each compiles against the simulator. No runtime testing, no device deploy, no integration yet.

### Task A.1: WakeWindow storage

**Files:**
- Create: `WakeProof/WakeProof/Alarm/WakeWindow.swift`

**Dependencies:** none (first task in the plan)

- [ ] **Step 1: Create the file with this exact content**

```swift
//
//  WakeWindow.swift
//  WakeProof
//
//  The wake window the user has configured (e.g., 06:30–07:00). Stored in
//  UserDefaults so a schema migration isn't forced on the SwiftData store
//  while Phase 6's unattended audio test is still running on-device.
//

import Foundation

struct WakeWindow: Codable, Equatable {
    var startHour: Int
    var startMinute: Int
    var endHour: Int
    var endMinute: Int
    var isEnabled: Bool

    static let defaultWindow = WakeWindow(
        startHour: 6, startMinute: 30,
        endHour: 7, endMinute: 0,
        isEnabled: false
    )

    private static let key = "com.wakeproof.alarm.wakeWindow"

    static func load(from defaults: UserDefaults = .standard) -> WakeWindow {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(WakeWindow.self, from: data) else {
            return .defaultWindow
        }
        return decoded
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key)
    }

    /// The next Date matching this window's start time, relative to `now`.
    /// If the start time already passed today, returns tomorrow's occurrence.
    func nextFireDate(after now: Date = .now, calendar: Calendar = .current) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = startHour
        components.minute = startMinute
        components.second = 0
        guard let candidate = calendar.date(from: components) else { return nil }
        if candidate > now {
            return candidate
        }
        return calendar.date(byAdding: .day, value: 1, to: candidate)
    }
}
```

- [ ] **Step 2: Simulator compile check**

```bash
xcodebuild -project /Users/mountainfung/Desktop/WakeProof-Hackathon/WakeProof/WakeProof.xcodeproj -scheme WakeProof -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -30
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon add WakeProof/WakeProof/Alarm/WakeWindow.swift
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon commit -m "Alarm Phase A.1: WakeWindow UserDefaults-backed storage (avoids SwiftData schema migration during Phase 6)"
```

### Task A.2: AlarmScheduler

**Files:**
- Create: `WakeProof/WakeProof/Alarm/AlarmScheduler.swift`

**Dependencies:** Task A.1

- [ ] **Step 1: Create the file**

```swift
//
//  AlarmScheduler.swift
//  WakeProof
//
//  Owns the user's wake-window configuration and the Task that fires the
//  alarm at window-start. Does not play audio directly — `playAlarmSound`
//  is a method on AudioSessionKeepalive added in Phase B. This separation
//  keeps the audio-critical file append-only during Phase 6.
//

import Foundation
import Observation
import os

@Observable
@MainActor
final class AlarmScheduler {

    // MARK: - Observable state

    private(set) var window: WakeWindow
    private(set) var isRinging: Bool = false
    private(set) var nextFireAt: Date?

    // MARK: - Dependencies (late-bound; Phase B wires these)

    /// Set by the app at startup once AudioSessionKeepalive + AlarmSoundEngine are available.
    var onFire: (() -> Void)?

    // MARK: - Private

    private let logger = Logger(subsystem: "com.wakeproof.alarm", category: "scheduler")
    private var fireTask: Task<Void, Never>?

    init() {
        self.window = WakeWindow.load()
    }

    // MARK: - Public API

    func updateWindow(_ new: WakeWindow) {
        window = new
        window.save()
        scheduleNextFireIfEnabled()
    }

    func scheduleNextFireIfEnabled() {
        cancel()
        guard window.isEnabled, let fireAt = window.nextFireDate() else {
            nextFireAt = nil
            logger.info("Scheduler idle — window disabled or invalid")
            return
        }
        nextFireAt = fireAt
        let interval = fireAt.timeIntervalSinceNow
        logger.info("Alarm scheduled for \(fireAt.ISO8601Format(), privacy: .public) (in \(interval, privacy: .public)s)")
        fireTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.fire() }
        }
    }

    func cancel() {
        fireTask?.cancel()
        fireTask = nil
        nextFireAt = nil
    }

    /// Demo-friendly manual trigger. Used by DEBUG "Fire now" button and by tests.
    func fireNow() {
        logger.info("Manual fireNow() invoked")
        fire()
    }

    func stopRinging() {
        isRinging = false
        logger.info("Ringing cleared")
    }

    // MARK: - Private

    private func fire() {
        logger.info("Alarm firing at \(Date().ISO8601Format(), privacy: .public)")
        isRinging = true
        onFire?()
        // Re-schedule the next day's fire. Cheap: this just sets up another Task.sleep.
        scheduleNextFireIfEnabled()
    }
}
```

- [ ] **Step 2: Simulator compile check**

```bash
xcodebuild -project /Users/mountainfung/Desktop/WakeProof-Hackathon/WakeProof/WakeProof.xcodeproj -scheme WakeProof -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -30
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon add WakeProof/WakeProof/Alarm/AlarmScheduler.swift
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon commit -m "Alarm Phase A.2: AlarmScheduler with Task.sleep fire mechanism (audio wiring deferred to Phase B)"
```

### Task A.3: AlarmSoundEngine

**Files:**
- Create: `WakeProof/WakeProof/Alarm/AlarmSoundEngine.swift`

**Dependencies:** Task A.2

- [ ] **Step 1: Create the file**

```swift
//
//  AlarmSoundEngine.swift
//  WakeProof
//
//  Escalation policy: how alarm volume and sound selection evolve while the
//  user is dragging their feet. Decoupled from AudioSessionKeepalive so the
//  audio-critical file stays append-only. This engine only asks the keepalive
//  to mutate volume; it never touches AVAudioPlayer directly.
//

import Foundation
import Observation
import os

@Observable
@MainActor
final class AlarmSoundEngine {

    private let logger = Logger(subsystem: "com.wakeproof.alarm", category: "soundEngine")
    private var escalationTask: Task<Void, Never>?

    /// Begins the escalation loop. Caller is responsible for starting the actual
    /// audio playback on AudioSessionKeepalive before calling this.
    /// - Parameter setVolume: callback the engine invokes each ramp step.
    func start(setVolume: @MainActor @escaping (Float) -> Void) {
        stop()
        logger.info("Escalation started at \(Date().ISO8601Format(), privacy: .public)")
        escalationTask = Task { [weak self] in
            // Ramp 0.3 → 1.0 over 60 s in 12 steps.
            let steps = 12
            let startVolume: Float = 0.3
            let endVolume: Float = 1.0
            let stepInterval: Double = 60.0 / Double(steps)
            for i in 0...steps {
                guard !Task.isCancelled else { return }
                let t = Float(i) / Float(steps)
                let v = startVolume + (endVolume - startVolume) * t
                await MainActor.run { setVolume(v) }
                self?.logger.debug("Ramp step \(i, privacy: .public) → volume \(v, privacy: .public)")
                try? await Task.sleep(for: .seconds(stepInterval))
            }
        }
    }

    func stop() {
        escalationTask?.cancel()
        escalationTask = nil
        logger.info("Escalation stopped")
    }
}
```

- [ ] **Step 2: Simulator compile check** (same command as A.2 Step 2). Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon add WakeProof/WakeProof/Alarm/AlarmSoundEngine.swift
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon commit -m "Alarm Phase A.3: AlarmSoundEngine ramp escalation decoupled from keepalive"
```

### Task A.4: AlarmSchedulerView

**Files:**
- Create: `WakeProof/WakeProof/Alarm/AlarmSchedulerView.swift`

**Dependencies:** Task A.2

- [ ] **Step 1: Create the file**

```swift
//
//  AlarmSchedulerView.swift
//  WakeProof
//
//  The post-onboarding home screen: configure the wake window, toggle the alarm,
//  and (DEBUG) fire immediately for demo video capture.
//

import SwiftUI

struct AlarmSchedulerView: View {

    @Environment(AlarmScheduler.self) private var scheduler

    @State private var startTime: Date = .now
    @State private var endTime: Date = .now
    @State private var isEnabled: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Wake window") {
                    DatePicker("Start", selection: $startTime, displayedComponents: .hourAndMinute)
                    DatePicker("End", selection: $endTime, displayedComponents: .hourAndMinute)
                    Toggle("Alarm enabled", isOn: $isEnabled)
                }

                Section {
                    Button("Save & schedule") { save() }
                        .disabled(endTime <= startTime)
                }

                if let next = scheduler.nextFireAt {
                    Section("Next fire") {
                        Text(next.formatted(date: .abbreviated, time: .standard))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }

                #if DEBUG
                Section("DEBUG") {
                    Button("Fire alarm now") { scheduler.fireNow() }
                        .foregroundStyle(.red)
                }
                #endif
            }
            .navigationTitle("WakeProof")
            .onAppear(perform: loadFromScheduler)
        }
    }

    private func loadFromScheduler() {
        let w = scheduler.window
        startTime = composeTime(hour: w.startHour, minute: w.startMinute)
        endTime = composeTime(hour: w.endHour, minute: w.endMinute)
        isEnabled = w.isEnabled
    }

    private func save() {
        let startComponents = Calendar.current.dateComponents([.hour, .minute], from: startTime)
        let endComponents = Calendar.current.dateComponents([.hour, .minute], from: endTime)
        let w = WakeWindow(
            startHour: startComponents.hour ?? 6,
            startMinute: startComponents.minute ?? 30,
            endHour: endComponents.hour ?? 7,
            endMinute: endComponents.minute ?? 0,
            isEnabled: isEnabled
        )
        scheduler.updateWindow(w)
    }

    private func composeTime(hour: Int, minute: Int) -> Date {
        var c = Calendar.current.dateComponents([.year, .month, .day], from: .now)
        c.hour = hour; c.minute = minute
        return Calendar.current.date(from: c) ?? .now
    }
}
```

- [ ] **Step 2: Simulator compile check**. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon add WakeProof/WakeProof/Alarm/AlarmSchedulerView.swift
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon commit -m "Alarm Phase A.4: AlarmSchedulerView home screen with DEBUG fire-now"
```

### Task A.5: CameraCaptureView

**Files:**
- Create: `WakeProof/WakeProof/Verification/CameraCaptureView.swift`

**Dependencies:** none (independent of A.1–A.4)

- [ ] **Step 1: Create the Verification directory and file**

The directory is new. File system must exist for Xcode's `PBXFileSystemSynchronizedRootGroup` to pick it up.

```bash
mkdir -p /Users/mountainfung/Desktop/WakeProof-Hackathon/WakeProof/WakeProof/Verification
```

Then create the file:

```swift
//
//  CameraCaptureView.swift
//  WakeProof
//
//  Wake-time capture: a short (≤2 s) video plus a middle-frame still extracted
//  for the Opus 4.7 vision prompt on Day 3. For Day 2 we only persist both
//  outputs locally; no API call yet.
//

import AVFoundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct CameraCaptureResult {
    let stillImage: UIImage
    let videoURL: URL
}

struct CameraCaptureView: UIViewControllerRepresentable {

    let onCaptured: (CameraCaptureResult) -> Void
    let onCancelled: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            picker.sourceType = .camera
            picker.cameraCaptureMode = .video
        } else {
            picker.sourceType = .photoLibrary
        }
        picker.mediaTypes = [UTType.movie.identifier]
        picker.videoMaximumDuration = 2.0
        picker.videoQuality = .typeMedium
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraCaptureView
        init(_ parent: CameraCaptureView) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            picker.dismiss(animated: true)
            guard let videoURL = info[.mediaURL] as? URL else {
                parent.onCancelled()
                return
            }
            Task { [weak self] in
                guard let self else { return }
                do {
                    let still = try await Self.extractMiddleFrame(videoURL: videoURL)
                    await MainActor.run {
                        self.parent.onCaptured(CameraCaptureResult(stillImage: still, videoURL: videoURL))
                    }
                } catch {
                    await MainActor.run { self.parent.onCancelled() }
                }
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
            parent.onCancelled()
        }

        private static func extractMiddleFrame(videoURL: URL) async throws -> UIImage {
            let asset = AVURLAsset(url: videoURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            let duration = try await asset.load(.duration)
            let midpoint = CMTime(seconds: duration.seconds / 2, preferredTimescale: duration.timescale)
            let cgImage = try await generator.image(at: midpoint).image
            return UIImage(cgImage: cgImage)
        }
    }
}
```

- [ ] **Step 2: Simulator compile check**. Expected: `** BUILD SUCCEEDED **`.

Note: `UIImagePickerController.cameraCaptureMode` is set to `.video`; on iPhone the picker shows the video recorder UI. Simulator lacks a camera — in simulator mode the picker falls back to `.photoLibrary` and the user would have to pick a pre-existing `.mov`. Phase B Task B.5 (device run) is where the camera is actually exercised.

- [ ] **Step 3: Commit**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon add WakeProof/WakeProof/Verification/CameraCaptureView.swift
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon commit -m "Alarm Phase A.5: CameraCaptureView with 2s video capture + middle-frame still extraction"
```

### Task A.6: AlarmRingingView

**Files:**
- Create: `WakeProof/WakeProof/Alarm/AlarmRingingView.swift`

**Dependencies:** Task A.5 (uses `CameraCaptureView`), Task A.7 (uses `WakeAttempt` with new fields)

- [ ] **Step 1: Create the file**

```swift
//
//  AlarmRingingView.swift
//  WakeProof
//
//  The full-screen "wake up" view. The only exit is a completed capture —
//  there is no dismiss button, per CLAUDE.md "the alarm must not be bypassable".
//  Force-quit is still possible (we cannot prevent that on iOS) but we do not
//  expose an in-app shortcut to it.
//

import SwiftData
import SwiftUI

struct AlarmRingingView: View {

    @Environment(AlarmScheduler.self) private var scheduler
    @Environment(\.modelContext) private var modelContext
    @Query private var baselines: [BaselinePhoto]

    @State private var now: Date = .now
    @State private var showCamera: Bool = false

    let onVerificationCaptured: (CameraCaptureResult) -> Void

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 24) {
                Spacer()
                Text(now.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 88, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                if let location = baselines.first?.locationLabel {
                    Text("Meet yourself at \(location).")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                } else {
                    Text("Prove you're awake.")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.85))
                }
                Spacer()

                Button {
                    showCamera = true
                } label: {
                    Text("Prove you're awake")
                        .font(.title3.bold())
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.white)
                        .foregroundStyle(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .padding(.horizontal)
                .padding(.bottom, 32)
            }
        }
        .onReceive(ticker) { now = $0 }
        .fullScreenCover(isPresented: $showCamera) {
            CameraCaptureView(
                onCaptured: { result in
                    showCamera = false
                    persist(result)
                    onVerificationCaptured(result)
                },
                onCancelled: {
                    showCamera = false
                }
            )
        }
    }

    private func persist(_ result: CameraCaptureResult) {
        let attempt = WakeAttempt(scheduledAt: scheduler.nextFireAt ?? .now)
        attempt.capturedAt = .now
        attempt.imageData = result.stillImage.jpegData(compressionQuality: 0.9)
        attempt.videoPath = result.videoURL.path
        attempt.triggeredWindowStart = composeTime(hour: scheduler.window.startHour,
                                                   minute: scheduler.window.startMinute)
        attempt.triggeredWindowEnd = composeTime(hour: scheduler.window.endHour,
                                                 minute: scheduler.window.endMinute)
        modelContext.insert(attempt)
        try? modelContext.save()
    }

    private func composeTime(hour: Int, minute: Int) -> Date {
        var c = Calendar.current.dateComponents([.year, .month, .day], from: .now)
        c.hour = hour; c.minute = minute
        return Calendar.current.date(from: c) ?? .now
    }
}
```

- [ ] **Step 2: Do NOT attempt to simulator-compile yet.** This file references new `WakeAttempt` fields (`videoPath`, `triggeredWindowStart`, `triggeredWindowEnd`) that Task A.7 adds. Compilation verification happens in Task A.8 after A.7 lands.

- [ ] **Step 3: Commit**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon add WakeProof/WakeProof/Alarm/AlarmRingingView.swift
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon commit -m "Alarm Phase A.6: AlarmRingingView with no-dismiss contract and capture handoff"
```

### Task A.7: WakeAttempt additive extension

**Files:**
- Modify: `WakeProof/WakeProof/Storage/WakeAttempt.swift`

**Dependencies:** Task A.6 (uses these new fields)

- [ ] **Step 1: Replace the existing `WakeAttempt` with this extended version**

The existing file is:

```swift
@Model
final class WakeAttempt {
    var scheduledAt: Date
    var capturedAt: Date?
    var imageData: Data?
    var verdict: String?  // "VERIFIED" | "REJECTED" | "RETRY"
    var verdictReasoning: String?
    var retryCount: Int
    var dismissedAt: Date?

    init(scheduledAt: Date) {
        self.scheduledAt = scheduledAt
        self.retryCount = 0
    }
}
```

Replace with:

```swift
@Model
final class WakeAttempt {
    var scheduledAt: Date
    var capturedAt: Date?
    var imageData: Data?
    var verdict: String?  // "VERIFIED" | "REJECTED" | "RETRY"
    var verdictReasoning: String?
    var retryCount: Int
    var dismissedAt: Date?

    // Additive fields for Day 2 alarm-core. SwiftData treats new optional @Attribute
    // properties as a lightweight migration — the on-device store is preserved.
    var videoPath: String?
    var triggeredWindowStart: Date?
    var triggeredWindowEnd: Date?

    init(scheduledAt: Date) {
        self.scheduledAt = scheduledAt
        self.retryCount = 0
    }
}
```

- [ ] **Step 2: Simulator compile check**

```bash
xcodebuild -project /Users/mountainfung/Desktop/WakeProof-Hackathon/WakeProof/WakeProof.xcodeproj -scheme WakeProof -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -30
```

Expected: `** BUILD SUCCEEDED **`. Every reference in `AlarmRingingView.swift` should resolve now.

- [ ] **Step 3: Commit**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon add WakeProof/WakeProof/Storage/WakeAttempt.swift
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon commit -m "Alarm Phase A.7: extend WakeAttempt additively with video path and triggered window"
```

### Task A.8: Alarm sound asset

**Files:**
- Create: `WakeProof/WakeProof/Resources/alarm.m4a`

**Dependencies:** none (can run any time during Phase A)

- [ ] **Step 1: Generate a 10-sec alternating-tone WAV then transcode to AAC**

```bash
python3 -c "
import wave, math, struct
sample_rate = 44100
total_seconds = 10
toggle_every_seconds = 0.5
frames = bytearray()
for i in range(sample_rate * total_seconds):
    t = i / sample_rate
    slot = int(t / toggle_every_seconds) % 2
    freq = 1000 if slot == 0 else 800
    val = int(32767 * 0.5 * math.sin(2 * math.pi * freq * t))
    frames += struct.pack('<h', val)
with wave.open('/tmp/alarm.wav', 'w') as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(sample_rate)
    w.writeframes(bytes(frames))
"
afconvert -f m4af -d aac -b 64000 /tmp/alarm.wav \
  /Users/mountainfung/Desktop/WakeProof-Hackathon/WakeProof/WakeProof/Resources/alarm.m4a
afinfo /Users/mountainfung/Desktop/WakeProof-Hackathon/WakeProof/WakeProof/Resources/alarm.m4a | head -8
```

Expected: `afinfo` reports `File type ID: m4af`, `Data format: 1 ch, 44100 Hz, 'aac'`, duration ~10.0 s.

- [ ] **Step 2: Simulator compile check** (confirms the Resources directory still syncs cleanly). Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon add WakeProof/WakeProof/Resources/alarm.m4a
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon commit -m "Alarm Phase A.8: add 10s alarm.m4a placeholder (1kHz/800Hz alternating, same pipeline as test-tone)"
```

### Task A.9: Simulator build sweep

**Files:** n/a (verification task)
**Dependencies:** A.1–A.8 all complete

- [ ] **Step 1: Clean build from the simulator**

```bash
xcodebuild -project /Users/mountainfung/Desktop/WakeProof-Hackathon/WakeProof/WakeProof.xcodeproj -scheme WakeProof -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' clean build 2>&1 | tail -50
```

Expected: `** BUILD SUCCEEDED **` with no warnings in any of the new files.

- [ ] **Step 2: Confirm no device-destination build was triggered**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon status
```
Expected: working tree clean. No uncommitted changes from accidental Xcode auto-saves.

**Phase A gate (HARD):** Simulator clean-build passes. Zero commits modify `AudioSessionKeepalive.swift`, `WakeProofApp.swift`, or the `ModelContainer` call. All 8 Phase A commits landed on local `main`. `git log origin/main..main` shows the Phase A commits as unpushed.

---

## Phase B — Wire-up (post-Phase-6 only)

**Goal of phase:** Phase 6 has PASSed (or FAILed and been replaced by Decision 8 pivot — in the FAIL case, confirm with the user whether to proceed with the Alarmy-style architecture here or pivot this plan too). Once confirmed, integrate the Phase A pieces: append audio methods to `AudioSessionKeepalive`, mount the scheduler in the root app, and validate on real hardware.

**Entry condition:** user has explicitly said "Phase 6 done, proceed to Phase B". If the user has not said this, STOP and wait.

### Task B.1: Append alarm-playback methods to AudioSessionKeepalive

**Files:**
- Modify: `WakeProof/WakeProof/Alarm/AudioSessionKeepalive.swift`

**Dependencies:** Phase A gate, user confirmation that Phase 6 has concluded

- [ ] **Step 1: Read the file** to confirm its current contents match what this plan assumes. If the other instance has added further methods in the meantime, adapt — do not blindly overwrite.

- [ ] **Step 2: Append to the END of the file (after `enum KeepaliveError`'s closing brace and the final `}` of the class)** — put the new methods inside the class via an extension so the existing class body is byte-for-byte unchanged:

```swift
// MARK: - Alarm playback (added in alarm-core Phase B)

extension AudioSessionKeepalive {

    /// Begin looping an alarm sound at moderate initial volume. The caller
    /// (AlarmSoundEngine) drives escalation through setAlarmVolume.
    func playAlarmSound(url: URL) {
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1
            player.volume = 0.3
            guard player.prepareToPlay(), player.play() else {
                logger.error("Alarm player refused to start for \(url.lastPathComponent, privacy: .public)")
                return
            }
            alarmPlayer = player
            logger.info("Alarm sound started at \(Date().ISO8601Format(), privacy: .public)")
        } catch {
            logger.error("Failed to start alarm sound: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stopAlarmSound() {
        alarmPlayer?.stop()
        alarmPlayer = nil
        logger.info("Alarm sound stopped at \(Date().ISO8601Format(), privacy: .public)")
    }

    func setAlarmVolume(_ volume: Float) {
        alarmPlayer?.volume = max(0.0, min(1.0, volume))
    }
}

// Swift doesn't let extensions store properties directly; use an associated-object-free
// approach by routing through a single private reference stored as a class property.
// To keep this plan append-only, instead of modifying the class body we add one file-local
// reference via a nested holder.
```

Actually stored properties can't live on extensions. Adjust:

**Revised Step 2:** Instead of an extension, add the new properties + methods to the main class. To preserve append-only, add them at the **bottom of the class body**, immediately before the enum declaration. Open the file, find the line `enum KeepaliveError: Error {` (near the end). Insert these lines immediately above it, indented to match method indentation (4 spaces inside class):

```swift
    // MARK: - Alarm playback (alarm-core Phase B)

    private var alarmPlayer: AVAudioPlayer?

    /// Begin looping an alarm sound at moderate initial volume. Caller drives escalation via setAlarmVolume.
    func playAlarmSound(url: URL) {
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1
            player.volume = 0.3
            guard player.prepareToPlay(), player.play() else {
                logger.error("Alarm player refused to start for \(url.lastPathComponent, privacy: .public)")
                return
            }
            alarmPlayer = player
            logger.info("Alarm sound started at \(Date().ISO8601Format(), privacy: .public)")
        } catch {
            logger.error("Failed to start alarm sound: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stopAlarmSound() {
        alarmPlayer?.stop()
        alarmPlayer = nil
        logger.info("Alarm sound stopped at \(Date().ISO8601Format(), privacy: .public)")
    }

    func setAlarmVolume(_ volume: Float) {
        alarmPlayer?.volume = max(0.0, min(1.0, volume))
    }
```

This is strictly additive — no existing method body, existing property, or existing observer is modified. `start()`, `startSilentLoop()`, `triggerTestTone()`, `scheduleUnattendedTestTone()`, and `stop()` are byte-for-byte preserved.

- [ ] **Step 3: Simulator compile check**. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon add WakeProof/WakeProof/Alarm/AudioSessionKeepalive.swift
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon commit -m "Alarm Phase B.1: append alarm playback methods to keepalive (existing methods byte-preserved)"
```

### Task B.2: Root integration in WakeProofApp

**Files:**
- Modify: `WakeProof/WakeProof/App/WakeProofApp.swift`

**Dependencies:** Task B.1

- [ ] **Step 1: Replace `WakeProofApp.swift` with this integrated version**

```swift
//
//  WakeProofApp.swift
//  WakeProof
//
//  App entry point. Wires up the top-level state containers and decides whether
//  to show onboarding, the alarm scheduler home, or the ringing alarm modal.
//

import SwiftData
import SwiftUI

@main
struct WakeProofApp: App {

    @State private var permissions = PermissionsManager()
    @State private var audioKeepalive = AudioSessionKeepalive.shared
    @State private var scheduler = AlarmScheduler()
    @State private var soundEngine = AlarmSoundEngine()

    let modelContainer: ModelContainer

    init() {
        do {
            modelContainer = try ModelContainer(
                for: BaselinePhoto.self, WakeAttempt.self
            )
        } catch {
            fatalError("Failed to initialize SwiftData ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(permissions)
                .environment(audioKeepalive)
                .environment(scheduler)
                .environment(soundEngine)
                .task {
                    audioKeepalive.start()
                    scheduler.onFire = {
                        guard let url = Bundle.main.url(forResource: "alarm", withExtension: "m4a") else { return }
                        audioKeepalive.playAlarmSound(url: url)
                        soundEngine.start { volume in
                            audioKeepalive.setAlarmVolume(volume)
                        }
                    }
                    scheduler.scheduleNextFireIfEnabled()
                }
        }
        .modelContainer(modelContainer)
    }
}

// MARK: - Root

struct RootView: View {
    @Query private var baselines: [BaselinePhoto]
    @Environment(AlarmScheduler.self) private var scheduler
    @Environment(AudioSessionKeepalive.self) private var audioKeepalive
    @Environment(AlarmSoundEngine.self) private var soundEngine

    var body: some View {
        Group {
            if baselines.isEmpty {
                OnboardingFlowView()
            } else {
                AlarmSchedulerView()
            }
        }
        .fullScreenCover(isPresented: .init(
            get: { scheduler.isRinging },
            set: { if !$0 { scheduler.stopRinging() } }
        )) {
            AlarmRingingView(onVerificationCaptured: { _ in
                soundEngine.stop()
                audioKeepalive.stopAlarmSound()
                scheduler.stopRinging()
            })
        }
    }
}
```

Notes:
- The DEBUG "Fire test tone" button from the foundation-hardening plan is intentionally removed now that the home screen is the scheduler. The scheduler's own DEBUG "Fire alarm now" button supersedes it, and anyone still wanting to test the silent-loop can call `audioKeepalive.triggerTestTone()` from a new DEBUG button if needed — but the keepalive-proving job is already done (Phase 6).
- `AlarmSoundEngine` is made `@Observable` or not? It currently isn't. Check: the view hierarchy doesn't read any state off it, only calls `start/stop`. So it does not need `@Observable`. The `.environment(soundEngine)` still works because SwiftUI's `Environment` accepts any reference type. If the compiler complains, mark `AlarmSoundEngine` with `@Observable` in Task A.3's file — a single-token change.

- [ ] **Step 2: Simulator compile check**. Expected: `** BUILD SUCCEEDED **`.

(`AlarmSoundEngine` is marked `@Observable` at its creation in A.3, so `.environment(soundEngine)` type-checks without adjustment.)

- [ ] **Step 3: Commit**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon add WakeProof/WakeProof/App/WakeProofApp.swift
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon commit -m "Alarm Phase B.2: mount scheduler + sound engine in WakeProofApp root"
```

### Task B.3: Device verification — Set → Ring → Camera → Save

**Files:** n/a (device test)
**Dependencies:** Task B.2

- [ ] **Step 1: Conditions**
  - Device battery ≥ 50%, charger attached
  - Volume: 50%
  - Silent switch: SILENT
  - DND / Focus: OFF
  - Low Power Mode: OFF
  - Console.app connected, filter `com.wakeproof`

- [ ] **Step 2: Fresh install from Xcode.** Launch. Walk through onboarding if the store still has a baseline (expected), otherwise you should land directly on `AlarmSchedulerView`.

- [ ] **Step 3: Set a wake window 2 minutes in the future**
  - Open `AlarmSchedulerView`
  - Start: 2 minutes from now (at minute granularity). End: 30 min later (unused Day 2 but captured).
  - Toggle "Alarm enabled" ON
  - Tap "Save & schedule"
  - Console should log: `Alarm scheduled for <ISO8601> (in ~120s)`

- [ ] **Step 4: Lock the phone. Place face-down.** Wait.

- [ ] **Step 5: At window start:**
  - Audio: alarm tone plays, ramping volume 0.3 → 1.0 over 60 s
  - Console: `Alarm firing at <ISO8601>`, `Alarm sound started at <ISO8601>`, `Escalation started at <ISO8601>`
  - Unlock the phone. `AlarmRingingView` is displayed fullscreen — no dismiss button.

- [ ] **Step 6: Prove you're awake**
  - Tap "Prove you're awake"
  - iOS video camera appears. Record a 2-sec clip.
  - Accept the clip (system "Use Video" button)
  - Expected console sequence: `Escalation stopped`, `Alarm sound stopped`, `Ringing cleared`
  - Audio stops. `AlarmRingingView` dismisses. Home screen returns.

- [ ] **Step 7: Verify persistence**
  - Force-quit the app
  - Relaunch
  - In Xcode, attach a breakpoint / use a temporary `#if DEBUG` button in `AlarmSchedulerView` body (`Text("Attempts: \(attempts.count)")` via `@Query` of `WakeAttempt`) if direct Core Data browsing isn't available. At minimum, relaunch and rerun Step 3 — the new attempt from the previous run should not reset the scheduler.

- [ ] **Step 8: Append to `docs/go-no-go-audio-test.md`**

```markdown
## Appendix: Alarm-core Phase B end-to-end (YYYY-MM-DD)

**Status:** PASS / FAIL

**Scenario:** Set window 2 min out → lock phone → alarm fires → camera captures → WakeAttempt persisted.

**Timestamps:**
- Scheduled at: <ISO8601>
- Fire time scheduled for: <ISO8601>
- Actually fired at: <ISO8601>
- Drift: <seconds>
- Camera captured at: <ISO8601>

**Notes:** <anything anomalous>
```

Commit the appendix:

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon add docs/go-no-go-audio-test.md
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon commit -m "Alarm Phase B.3: record alarm-core end-to-end on-device validation"
```

**Phase B gate (HARD):** Device ran the full Set→Ring→Camera→Save loop. `WakeAttempt` persists across force-quit. Fire-time drift ≤ 30 s. Console log contains the expected sequence. Appendix committed.

---

## Phase C — Review pipeline

Per `CLAUDE.md` "Multi-phase review pipeline". Each sub-step runs in order and must reach zero open issues before the plan closes. This is where the commit-gate in `CLAUDE.md` is enforced across the full alarm-core diff (not per-commit).

### Task C.1: adversarial-review

**Files:** n/a (review task)
**Dependencies:** Phase B gate

- [ ] **Step 1:** Invoke adversarial-review skill against the alarm-core diff: `git diff origin/main..HEAD -- WakeProof/WakeProof/Alarm WakeProof/WakeProof/Verification WakeProof/WakeProof/Storage WakeProof/WakeProof/App WakeProof/WakeProof/Resources`. Focus areas to prompt:
    - Race between `fireTask` completion and a concurrent `cancel()`
    - Alarm-player volume lag if `setAlarmVolume` is called before `playAlarmSound` resolves
    - `AlarmScheduler.scheduleNextFireIfEnabled()` self-recursion inside `fire()` — stack-safe under `Task.sleep`? (yes, new Task; confirm in review)
    - `UserDefaults` read in `AlarmScheduler.init()` running off-main-actor — is the `@MainActor` annotation sufficient?
    - `WakeAttempt.videoPath` as `String` (plain path) — risk the iOS sandbox relocation invalidates the path on reinstall. Consider storing a bookmark or the `videoData` itself inline.
    - `AlarmRingingView.persist()` silently swallows `try? modelContext.save()` — violates the "no silent catch" global rule
    - No-dismiss contract: is the `.fullScreenCover` genuinely unskippable or can user swipe down to dismiss?
    - Alarm fires at day-boundary: does `nextFireDate` handle a `nextFire` exactly at 00:00?
- [ ] **Step 2:** Surface every issue regardless of severity. Per `CLAUDE.md` global rule, anything found must be fixed — cannot skip by "pre-existing" or "low risk".
- [ ] **Step 3:** Fix surfaced issues. Each fix is its own commit with WHY in the message.

### Task C.2: simplify

**Files:** n/a (review task)
**Dependencies:** Task C.1 zero open issues

- [ ] **Step 1:** Invoke `simplify` skill on the same diff.
- [ ] **Step 2:** Look specifically for:
    - `AlarmScheduler.scheduleNextFireIfEnabled` duplicated code with its re-entrance from `fire()` — is the chain necessary?
    - `composeTime(hour:minute:)` implemented in both `AlarmSchedulerView` and `AlarmRingingView` — extract to `WakeWindow` as a method? (Only if the duplication is true duplication — consider CLAUDE.md "wait for the third repetition before extracting".)
    - `CameraCaptureResult` struct only holding two fields — is it pulling its weight vs. a tuple?
- [ ] **Step 3:** Apply simplifications. Commit each with WHY.

### Task C.3: Re-review loop

**Files:** n/a
**Dependencies:** Task C.2

- [ ] **Step 1:** Re-run `adversarial-review` against the simplified diff. If any new issue surfaces from the simplification, fix it and repeat.
- [ ] **Step 2:** When both `adversarial-review` and `simplify` return zero issues for the same diff state, Phase C completes.
- [ ] **Step 3:** Mark the plan complete. Commit the final clean state:

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon log --oneline origin/main..main
```
Expected: the full alarm-core commit series, ready for a `git push` when the user explicitly authorizes.

**Phase C gate (HARD):** Zero open review issues across both `adversarial-review` and `simplify`. All commit gate requirements from `CLAUDE.md` satisfied (builds cleanly, no `print()`, no force-unwraps, no hardcoded keys, commit messages explain WHY).

---

## Cross-phase dependency summary

```
Phase A (Phase-6 safe, all new files)
  A.1 WakeWindow ──▶ A.2 AlarmScheduler ──▶ A.3 AlarmSoundEngine
                                     │
                                     ▼
                                  A.4 AlarmSchedulerView
  A.5 CameraCaptureView ──▶ A.6 AlarmRingingView ◀── A.7 WakeAttempt extension
  A.8 alarm.m4a asset
                                     │
                                     ▼
                                  A.9 simulator build sweep  ── HARD GATE ──▶
                                                                              │
(user confirms Phase 6 concluded) ◀────────────────────────────────────────────┘
                                     │
                                     ▼
Phase B (touches audio-critical file + root app)
  B.1 Append alarm playback to AudioSessionKeepalive
  B.2 Mount scheduler + sound engine in WakeProofApp
  B.3 Device validation Set→Ring→Camera→Save
                                     │
                                     ▼ HARD GATE
Phase C (review pipeline)
  C.1 adversarial-review ──▶ fix ──▶ C.2 simplify ──▶ fix ──▶ C.3 re-review
                                                                         │
                                                                         ▼ HARD GATE
                                                              alarm-core complete
```

## Pivot triggers (do not forward-roll past these)

| Condition | Action |
|---|---|
| Phase A simulator build fails at any task | Stop. Fix before moving to next task. |
| Phase 6 FAILed and user opted for Decision 8 hybrid (iOS Clock + Shortcuts) | **Do not execute Phase B as written.** Alarm scheduling is handed off to iOS Clock; this plan's `AlarmScheduler.scheduleNextFireIfEnabled` becomes a no-op and `AlarmRingingView` is presented by a Shortcut intent instead. Rewrite Phase B tasks before proceeding. |
| Phase B.3 device test fails: alarm doesn't fire | Check Phase 6 appendix — did audio session survive the interval? If yes, scheduler bug. If no, Phase 6 regression. |
| Phase B.3 device test fails: alarm fires but camera doesn't auto-launch | `scheduler.isRinging` not propagating. Check `@Environment` wiring + `fullScreenCover` binding. |
| Phase B.3 device test fails: attempt not persisted | `modelContext.save()` threw silently. Add explicit error logging (per CLAUDE.md global rule against silent catches) before retry. |
| Phase C.1 or C.2 surfaces a critical issue requiring architectural change | Stop. Do not accumulate fixes — open a new plan or extend this one explicitly. |

## Out of scope for this plan (captured for follow-ups)

Each bullet is a known Day 3+ deliverable surfaced here so the subagent does not scope-creep:

- Claude Opus 4.7 vision verification call + structured JSON verdict (`docs/plans/vision-verification.md`)
- Self-verification chain prompt listing 3 spoofing methods (same plan)
- Random anti-spoofing action prompts ("blink twice", "show right hand") (same plan)
- Retry counter + timeout policy for failed verdicts (same plan)
- Memory Tool per-user memory file (Layer 2) (Day 4 plan)
- Managed Agent overnight pipeline (Layer 3) (Day 4 plan)
- Weekly coach 1M-context call (Layer 4) (Day 4 plan)
- Production alarm sound (licensed or original) (Day 5 polish plan)
- AVFoundation-based camera replacing `UIImagePickerController` (Day 5 polish plan if time)
- HealthKit sleep-summary display on dismiss screen (Day 4 plan)

Day numbers from `docs/build-plan.md` are reference only; advance when gates pass, not on calendar rollover.
