//
//  WakeProofApp.swift
//  WakeProof
//
//  App entry point. Wires up the top-level state containers and decides whether
//  to show onboarding, the alarm scheduler home, or the ringing alarm modal.
//

import BackgroundTasks
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

    // Non-Observable actor services — held as `private let` rather than `@State` because
    // they provide no SwiftUI-observable surface. A @State wrapper around a value-type
    // actor-reference adds binding machinery we never use.
    private let memoryStore = MemoryStore()
    // Primary path (B.5): Managed Agents. `NoopBriefingSource` is retained in the
    // codebase for previews and rollback — see NoopBriefingSource.swift header.
    private let briefingSource = ManagedAgentBriefingSource()
    private let sleepReader = HealthKitSleepReader()
    private let overnightScheduler: OvernightScheduler

    private static let logger = Logger(subsystem: "com.wakeproof.app", category: "root")
    /// Weak bridge between `init()`'s synchronously-registered BGTask launch handler and
    /// the scheduler instance. `nonisolated static` so the handler closure can capture
    /// it without reaching into `self` (which the closure can't safely hold at register
    /// time — the runtime invokes it during cold-launch before any instance lifetime
    /// guarantees). Weak so the box itself never keeps the scheduler alive past app
    /// teardown; live reference is held by `WakeProofApp.overnightScheduler`.
    private static let schedulerBox = OvernightSchedulerBox()
    let modelContainer: ModelContainer

    init() {
        do {
            modelContainer = try ModelContainer(
                for: BaselinePhoto.self, WakeAttempt.self, MorningBriefing.self
            )
        } catch {
            // Log before the fatal so crash reports carry the decoded reason rather than
            // just a stack trace. Recoverable storage-init UI is out of scope here; this
            // is a fail-fast programmer-error path (schema mismatch, disk full at install).
            Self.logger.critical("ModelContainer init failed: \(error.localizedDescription, privacy: .public)")
            fatalError("Failed to initialize SwiftData ModelContainer: \(error)")
        }

        // Build scheduler synchronously so it's ready for RootView at first render.
        // Phase B.5 wired `ManagedAgentBriefingSource` (primary path, chosen by the
        // B.3 decision gate) as the live source — each bedtime starts a real Managed
        // Agents session; each wake fetches the final agent.message.
        let scheduler = OvernightScheduler(
            source: briefingSource,
            sleepReader: sleepReader,
            memoryStore: memoryStore,
            modelContainer: modelContainer
        )
        self.overnightScheduler = scheduler
        Self.schedulerBox.value = scheduler
        Self.logger.info("OvernightScheduler wired with ManagedAgentBriefingSource (primary path)")

        // BGTaskScheduler requires identifier registration before
        // `application(_:didFinishLaunchingWithOptions:)` returns. `.task { bootstrapIfNeeded }`
        // fires AFTER first scene attach, which is well past launch completion — iOS has
        // already crashed the app by then on any early BGTask fire. Registering here in
        // init() is the crash-safety guarantee (plan's R1 fix).
        let box = Self.schedulerBox
        OvernightScheduler.registerBackgroundTask { task in
            Task {
                guard let scheduler = box.value else {
                    Self.logger.warning("BGTask fired before scheduler ready; completing as failure so iOS retries")
                    task.setTaskCompleted(success: false)
                    return
                }
                await scheduler.handleBackgroundRefresh(task)
            }
        }
        Self.logger.info("BGTaskScheduler registered identifier=\(OvernightScheduler.backgroundTaskIdentifier, privacy: .public)")
    }

    var body: some Scene {
        WindowGroup {
            // `overnightScheduler` is passed as a constructor parameter rather than via
            // SwiftUI's `.environment(_:)` because it's an `actor` (not `@Observable`) —
            // same constraint as MemoryStore. Downstream views either read it here in
            // RootView's closure, or access it through RootView's state-transition hook.
            RootView(overnightScheduler: overnightScheduler)
                .environment(permissions)
                .environment(audioKeepalive)
                .environment(scheduler)
                .environment(soundEngine)
                .environment(visionVerifier)
                // NOTE: MemoryStore + OvernightScheduler are Swift `actor`s, not `Observable`,
                // so SwiftUI's .environment(_:) refuses them. MemoryStore reaches views via
                // `visionVerifier.memoryStore`; OvernightScheduler is passed directly to
                // RootView above.
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
        Task { @MainActor in
            do {
                try await memoryStore.bootstrapIfNeeded()
                // Only expose the store to the verifier AFTER bootstrap completes so
                // the first verify() call can never win the directory-creation race.
                // (The actor's read() handles missing-dir gracefully via .empty, but
                // moving the assignment here makes the invariant visible in the code
                // shape — S6 in memory-tool-findings.md.)
                visionVerifier.memoryStore = memoryStore
            } catch {
                Self.logger.error("MemoryStore bootstrap failed: \(error.localizedDescription, privacy: .public)")
                // Bootstrap failed — do NOT expose the store. read() would still work
                // (it early-returns .empty on missing dir), but writes would fail
                // repeatedly — better to run memory-less for this launch.
            }
        }
        // Recover any fire that started in a prior session but never resolved (force-quit
        // during ring). Persists an UNRESOLVED WakeAttempt so the audit trail records the
        // missed wake instead of silently forgetting it.
        scheduler.recoverUnresolvedFireIfNeeded()
        scheduler.scheduleNextFireIfEnabled()

        // Launch-time stale-handle cleanup. C.1 cost-containment: Managed Agents charges
        // $0.08/hr while a session is running; a crash during the night leaves the
        // session meter running until its 24h ceiling. Catching it on next launch caps
        // the cost at "time until next launch" instead. No-op when no stale handle is
        // present (the happy path after a clean finalize).
        if let staleHandle = UserDefaults.standard.string(forKey: OvernightScheduler.activeHandleKey) {
            let scheduler = overnightScheduler
            Task {
                Self.logger.warning("Found stale overnight handle on launch; attempting cleanup")
                await scheduler.cleanupStale(handle: staleHandle)
            }
        }
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
            // onCeilingReached is the same closure regardless of whether audio starts —
            // hoisted so both the happy path and the R7 missing-asset fallback share it.
            let ceilingHandler: @MainActor () -> Void = { [weak soundEngine, weak audioKeepalive, weak scheduler] in
                // weak everywhere: a strong capture of `scheduler` would form a retain
                // cycle through scheduler.onFire → this closure → scheduler.
                Self.logger.warning("Hard-stopping alarm at ring ceiling")
                soundEngine?.stop()
                audioKeepalive?.stopAlarmSound()
                // handleRingCeiling persists a TIMEOUT WakeAttempt then calls stopRinging,
                // keeping the audit-trail bookkeeping in one place.
                scheduler?.handleRingCeiling()
            }

            guard let url = Bundle.main.url(forResource: "alarm", withExtension: "m4a") else {
                // R7 fix: on a build-config regression that drops alarm.m4a we previously
                // early-returned, which meant soundEngine was never started → ceiling never
                // fired → the unresolved-fire marker dangled forever and the WakeAttempt
                // row stayed UNRESOLVED even after the user interacted. Start the ceiling
                // timer anyway so the state machine reaches a terminal audit row.
                Self.logger.fault("alarm.m4a missing from bundle — silent alarm, but ceiling armed so audit row lands")
                soundEngine.start(
                    setVolume: { _ in /* no audio player to mutate */ },
                    onCeilingReached: ceilingHandler
                )
                return
            }
            audioKeepalive.playAlarmSound(url: url)
            soundEngine.start(
                setVolume: { volume in
                    audioKeepalive.setAlarmVolume(volume)
                },
                onCeilingReached: ceilingHandler
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
    /// `actor` reference — held directly rather than through `@Environment` because
    /// SwiftUI environment requires `@Observable` types. See WakeProofApp.body for
    /// the rationale.
    let overnightScheduler: OvernightScheduler

    @Query private var baselines: [BaselinePhoto]
    @Environment(AlarmScheduler.self) private var scheduler
    @Environment(AudioSessionKeepalive.self) private var audioKeepalive
    @Environment(AlarmSoundEngine.self) private var soundEngine
    @Environment(VisionVerifier.self) private var visionVerifier
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    /// Briefing finalized on the (.verifying → .idle) transition. Latched here so the
    /// fullScreenCover reads a stable reference even after its background Task resolves.
    @State private var latestBriefing: MorningBriefing?
    @State private var showBriefing = false

    private static let logger = Logger(subsystem: "com.wakeproof.overnight", category: "briefing-view")

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
        .fullScreenCover(isPresented: $showBriefing) {
            // Presented on VERIFIED. `latestBriefing` can be nil when the scheduler
            // had no active session (fresh install, no bedtime set, or the Noop source
            // returned an error at fetchBriefing) — MorningBriefingView handles nil
            // by rendering a fallback "no briefing yet" card.
            MorningBriefingView(briefing: latestBriefing) {
                showBriefing = false
                latestBriefing = nil
            }
        }
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
                // Surface the overnight briefing right after a successful verify. The
                // fetch runs in a detached Task so the scheduler's isolation boundary
                // is honoured; the main-actor hop afterwards drives the cover binding.
                // The whole thing is ancillary — any error here just means no briefing
                // appears, which is the same UX as no bedtime being set (handled by
                // MorningBriefingView's nil-briefing fallback).
                let scheduler = overnightScheduler
                Task { @MainActor in
                    let briefing = await scheduler.finalizeBriefing(forWakeDate: .now)
                    Self.logger.info("VERIFIED transition: briefing fetched present=\(briefing != nil, privacy: .public)")
                    latestBriefing = briefing
                    showBriefing = true
                }
            case (_, .verifying):
                // Reduce but do not mute during verification; Decision 2 failure-mode table says
                // a full mute makes the user think they already succeeded. Applies to both the
                // initial .capturing → .verifying hop AND the anti-spoof re-capture → .verifying hop.
                //
                // B6 fix: pauseRamp() BEFORE setAlarmVolume(0.2) so the ramp's next 5s tick
                // doesn't overwrite our externally-set volume back to the escalation curve
                // (which previously caused an audible sawtooth pattern during verification).
                soundEngine.pauseRamp()
                audioKeepalive.setAlarmVolume(0.2)
            case (.verifying, .ringing):
                // Verification failed (REJECTED or network error). Restore full volume and reset
                // the verifier so a user-initiated "Prove you're awake" retry starts with a fresh
                // two-attempt budget rather than carrying over the previous fire's state.
                // Ramp stays paused — user has engaged at least once, full-volume attention is
                // warranted on the retry path (no benefit to re-escalating from 0.3).
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

// MARK: - File-scope helpers

/// Weak bridge from the file-scope BGTask launch handler registered in
/// `WakeProofApp.init()` to the scheduler instance. Declared at file scope (not nested
/// inside the struct) so the launch-handler closure — which must be captured before
/// the struct has any stable instance identity — can reference it without a `self`
/// capture. Weak because this box should never extend the scheduler's lifetime.
final class OvernightSchedulerBox {
    weak var value: OvernightScheduler?
}
