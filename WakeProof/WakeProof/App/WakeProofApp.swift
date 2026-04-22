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
        scheduler.onFire = { [audioKeepalive, soundEngine, logger] in
            guard let url = Bundle.main.url(forResource: "alarm", withExtension: "m4a") else {
                logger.error("alarm.m4a missing from bundle — alarm will fire silently")
                return
            }
            audioKeepalive.playAlarmSound(url: url)
            soundEngine.start(
                setVolume: { volume in
                    audioKeepalive.setAlarmVolume(volume)
                },
                onCeilingReached: { [scheduler] in
                    logger.warning("Hard-stopping alarm at ring ceiling")
                    soundEngine.stop()
                    audioKeepalive.stopAlarmSound()
                    scheduler.stopRinging()
                }
            )
        }
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
