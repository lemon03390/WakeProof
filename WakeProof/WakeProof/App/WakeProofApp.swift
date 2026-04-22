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

    private let logger = Logger(subsystem: "com.wakeproof.app", category: "root")
    let modelContainer: ModelContainer

    init() {
        do {
            modelContainer = try ModelContainer(
                for: BaselinePhoto.self, WakeAttempt.self
            )
        } catch {
            // Logged before the fatal so the crash report carries the decoded reason,
            // not just a stack trace. A recoverable UI for storage init failure belongs in
            // the Day 4 polish plan — Day 2 keeps this as a fail-fast programmer-error path.
            Logger(subsystem: "com.wakeproof.app", category: "root")
                .critical("ModelContainer init failed: \(error.localizedDescription, privacy: .public)")
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
                    wireSchedulerOnFireIfNeeded()
                    wireSchedulerPersistenceIfNeeded()
                    // Recover any fire that started in a prior session but never resolved
                    // (force-quit during ring). Persists an UNRESOLVED WakeAttempt so the
                    // audit trail records the missed wake instead of silently forgetting it.
                    scheduler.recoverUnresolvedFireIfNeeded()
                    scheduler.scheduleNextFireIfEnabled()
                }
        }
        .modelContainer(modelContainer)
    }

    /// `.task` fires on every RootView appear. Only install the onFire handler once
    /// to avoid re-allocating closures across re-renders; also gives us a place to log
    /// missing-asset conditions instead of silently returning.
    private func wireSchedulerOnFireIfNeeded() {
        guard scheduler.onFire == nil else { return }
        scheduler.onFire = { [audioKeepalive, soundEngine, logger, weak scheduler] firedAt in
            logger.info("onFire received fire at \(firedAt.ISO8601Format(), privacy: .public)")
            guard let url = Bundle.main.url(forResource: "alarm", withExtension: "m4a") else {
                logger.fault("alarm.m4a missing from bundle — alarm will fire silently")
                return
            }
            audioKeepalive.playAlarmSound(url: url)
            soundEngine.start(
                setVolume: { volume in
                    audioKeepalive.setAlarmVolume(volume)
                },
                onCeilingReached: { [weak soundEngine, weak audioKeepalive, weak scheduler, logger] in
                    // weak everywhere: prior strong-capture of `scheduler` formed a retain
                    // cycle through scheduler.onFire → closure → scheduler.
                    logger.warning("Hard-stopping alarm at ring ceiling")
                    soundEngine?.stop()
                    audioKeepalive?.stopAlarmSound()
                    // handleRingCeiling persists a TIMEOUT WakeAttempt then calls stopRinging
                    // for us — keeps the audit-trail bookkeeping in one place.
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
        scheduler.persistAttempt = { [logger] verdict, scheduledFor in
            let attempt = WakeAttempt(scheduledAt: scheduledFor)
            attempt.verdict = verdict.rawValue
            attempt.dismissedAt = .now
            context.insert(attempt)
            do {
                try context.save()
                logger.info("Persisted WakeAttempt verdict=\(verdict.rawValue, privacy: .public) scheduledFor=\(scheduledFor.ISO8601Format(), privacy: .public)")
            } catch {
                logger.error("Failed to persist WakeAttempt verdict=\(verdict.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
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
    }

    @ViewBuilder
    private var alarmPhaseContent: some View {
        switch scheduler.phase {
        case .idle:
            EmptyView()
        case .ringing:
            AlarmRingingView(onRequestCapture: { scheduler.beginCapturing() })
        case .capturing:
            CameraCaptureFlow(onSuccess: { _ in
                soundEngine.stop()
                audioKeepalive.stopAlarmSound()
                scheduler.stopRinging()
            })
        }
    }
}
