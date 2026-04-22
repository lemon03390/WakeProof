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
                    scheduler.onFire = { [audioKeepalive, soundEngine] in
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
