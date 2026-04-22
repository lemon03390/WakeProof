//
//  WakeProofApp.swift
//  WakeProof
//
//  App entry point. Wires up the top-level state containers and decides whether
//  to show onboarding, the alarm scheduler home, or the ringing alarm modal.
//

import SwiftData
import SwiftUI
import os

@main
struct WakeProofApp: App {

    @State private var permissions = PermissionsManager()
    @State private var audioKeepalive = AudioSessionKeepalive.shared
    @State private var scheduler = AlarmScheduler()
    @State private var soundEngine = AlarmSoundEngine()
    @State private var visionVerifier = VisionVerifier()
    /// One-shot guard so .task running on every RootView re-mount (multi-scene attach,
    /// SwiftUI identity churn) doesn't repeatedly cancel + reschedule the fire pipeline.
    @State private var didBootstrap = false

    private static let logger = Logger(subsystem: "com.wakeproof.app", category: "root")
    let modelContainer: ModelContainer

    init() {
        do {
            modelContainer = try ModelContainer(
                for: BaselinePhoto.self, WakeAttempt.self
            )
        } catch {
            // Log before the fatal so crash reports carry the decoded reason rather than
            // just a stack trace. Recoverable storage-init UI is out of scope here; this
            // is a fail-fast programmer-error path (schema mismatch, disk full at install).
            Self.logger.critical("ModelContainer init failed: \(error.localizedDescription, privacy: .public)")
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
                .environment(visionVerifier)
                .task { bootstrapIfNeeded() }
        }
        .modelContainer(modelContainer)
    }

    private func bootstrapIfNeeded() {
        guard !didBootstrap else { return }
        didBootstrap = true
        audioKeepalive.start()
        wireSchedulerCallbacks()
        // Late-bind the scheduler into the verifier so VisionVerifier.verify(...) can drive
        // phase transitions on VERIFIED / REJECTED / RETRY without the verifier holding a
        // non-optional scheduler reference (which would couple it at test-time).
        visionVerifier.scheduler = scheduler
        // Recover any fire that started in a prior session but never resolved (force-quit
        // during ring). Persists an UNRESOLVED WakeAttempt so the audit trail records the
        // missed wake instead of silently forgetting it.
        scheduler.recoverUnresolvedFireIfNeeded()
        scheduler.scheduleNextFireIfEnabled()
    }

    /// Install the scheduler's late-bound callbacks. Each guard makes the call idempotent
    /// in case the scheduler instance is reused across SwiftUI identity churn.
    private func wireSchedulerCallbacks() {
        wireSchedulerOnFireIfNeeded()
        wireSchedulerPersistenceIfNeeded()
    }

    private func wireSchedulerOnFireIfNeeded() {
        guard scheduler.onFire == nil else { return }
        scheduler.onFire = { [audioKeepalive, soundEngine, weak scheduler] firedAt in
            Self.logger.info("onFire received fire at \(firedAt.ISO8601Format(), privacy: .public)")
            guard let url = Bundle.main.url(forResource: "alarm", withExtension: "m4a") else {
                Self.logger.fault("alarm.m4a missing from bundle — alarm will fire silently")
                return
            }
            audioKeepalive.playAlarmSound(url: url)
            soundEngine.start(
                setVolume: { volume in
                    audioKeepalive.setAlarmVolume(volume)
                },
                onCeilingReached: { [weak soundEngine, weak audioKeepalive, weak scheduler] in
                    // weak everywhere: a strong capture of `scheduler` would form a retain
                    // cycle through scheduler.onFire → this closure → scheduler.
                    Self.logger.warning("Hard-stopping alarm at ring ceiling")
                    soundEngine?.stop()
                    audioKeepalive?.stopAlarmSound()
                    // handleRingCeiling persists a TIMEOUT WakeAttempt then calls stopRinging,
                    // keeping the audit-trail bookkeeping in one place.
                    scheduler?.handleRingCeiling()
                }
            )
        }
    }

    /// Wire the WakeAttempt persistence closure that the scheduler invokes on TIMEOUT and
    /// UNRESOLVED paths. The model context is captured here so AlarmScheduler stays free of
    /// SwiftData coupling.
    private func wireSchedulerPersistenceIfNeeded() {
        guard scheduler.persistAttempt == nil else { return }
        let context = modelContainer.mainContext
        scheduler.persistAttempt = { verdict, scheduledFor in
            let attempt = WakeAttempt(scheduledAt: scheduledFor)
            attempt.verdict = verdict.rawValue
            attempt.dismissedAt = .now
            context.insert(attempt)
            do {
                try context.save()
                Self.logger.info("Persisted WakeAttempt verdict=\(verdict.rawValue, privacy: .public) scheduledFor=\(scheduledFor.ISO8601Format(), privacy: .public)")
            } catch {
                Self.logger.error("Failed to persist WakeAttempt verdict=\(verdict.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
                context.rollback()
            }
        }
    }
}

// MARK: - Root

struct RootView: View {
    @Query private var baselines: [BaselinePhoto]
    @Environment(AlarmScheduler.self) private var scheduler
    @Environment(AudioSessionKeepalive.self) private var audioKeepalive
    @Environment(AlarmSoundEngine.self) private var soundEngine
    @Environment(VisionVerifier.self) private var visionVerifier
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            if baselines.isEmpty {
                OnboardingFlowView()
            } else {
                AlarmSchedulerView()
            }

            // Alarm overlay sits on top of whatever's below. Using a ZStack instead of a
            // fullScreenCover because on iOS 26, swapping cover content mid-presentation
            // (ringing → capturing) triggers SwiftUI's dismiss+re-present cycle, during
            // which the cover's binding setter fires false and cascades through stopRinging.
            // ZStack keeps everything in a single stable view tree; content swaps are free.
            if scheduler.phase != .idle {
                alarmPhaseContent
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: scheduler.phase)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                // Catches the case where Task.sleep was suspended past its fire time overnight
                // — the backup notification will have beeped; this promotes the in-app ringing UI.
                scheduler.reconcileAfterForeground()
            }
        }
        .onChange(of: scheduler.phase) { oldPhase, newPhase in
            switch (oldPhase, newPhase) {
            case (.verifying, .idle):
                // VERIFIED path — alarm stops, verifier state resets.
                soundEngine.stop()
                audioKeepalive.stopAlarmSound()
                visionVerifier.resetForNewFire()
            case (_, .verifying):
                // Reduce but do not mute during verification; Decision 2 failure-mode table says
                // a full mute makes the user think they already succeeded. Applies to both the
                // initial .capturing → .verifying hop AND the anti-spoof re-capture → .verifying hop.
                audioKeepalive.setAlarmVolume(0.2)
            case (.verifying, .ringing):
                // Verification failed (REJECTED or network error). Restore full volume and reset
                // the verifier so a user-initiated "Prove you're awake" retry starts with a fresh
                // two-attempt budget rather than carrying over the previous fire's state.
                audioKeepalive.setAlarmVolume(1.0)
                visionVerifier.resetForNewFire()
            // .verifying → .antiSpoofPrompt intentionally has no volume change: the anti-spoof
            // view keeps the ring volume at 0.2 (already reduced above) because the user is about
            // to re-capture in seconds. Adding a restore-then-reduce cycle would be a noticeable click.
            default:
                break
            }
        }
    }

    @ViewBuilder
    private var alarmPhaseContent: some View {
        switch scheduler.phase {
        case .idle:
            EmptyView()
        case .ringing:
            AlarmRingingView(onRequestCapture: { scheduler.beginCapturing() })
        case .capturing:
            CameraCaptureFlow(onSuccess: { attempt in
                // Hand the WakeAttempt to the verifier. Volume reduction + stop chain are
                // driven by the .onChange(of: scheduler.phase) handler below (keyed off the
                // .capturing → .verifying → .idle/.ringing transitions the verifier triggers).
                Task { @MainActor in
                    if let baseline = baselines.first {
                        await visionVerifier.verify(
                            attempt: attempt,
                            baseline: baseline,
                            context: modelContext
                        )
                    } else {
                        // No baseline means onboarding incomplete. RootView gates on
                        // baselines.isEmpty before showing the scheduler, so hitting this
                        // branch is a programmer error — surface it rather than hang.
                        scheduler.returnToRingingWith(error: "No baseline photo — re-run onboarding.")
                    }
                }
            })
        case .verifying:
            VerifyingView()
        case .antiSpoofPrompt(let instruction):
            // Wired directly to the A.6 view; B.3 may refine with additional context later.
            AntiSpoofActionPromptView(
                instruction: instruction,
                onReady: { scheduler.beginCapturing() }
            )
        }
    }
}
