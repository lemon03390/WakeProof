//
//  WakeProofApp.swift
//  WakeProof
//
//  App entry point. Wires up the top-level state containers and decides whether to show
//  onboarding or the main app based on whether a baseline photo exists.
//

import SwiftData
import SwiftUI

@main
struct WakeProofApp: App {

    // Shared long-lived services
    @State private var permissions = PermissionsManager()
    @State private var audioKeepalive = AudioSessionKeepalive.shared

    // SwiftData container
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
                .task {
                    // Activate audio keepalive on first launch.
                    // Day 1 GO/NO-GO depends on this surviving background.
                    audioKeepalive.start()
                }
        }
        .modelContainer(modelContainer)
    }
}

// MARK: - Root

struct RootView: View {
    @Query private var baselines: [BaselinePhoto]
    @Environment(AudioSessionKeepalive.self) private var audioKeepalive

    var body: some View {
        if baselines.isEmpty {
            OnboardingFlowView()
        } else {
            // HomeView not yet built — placeholder for the foundation-hardening plan.
            VStack(spacing: 16) {
                Text("WakeProof")
                    .font(.largeTitle).bold()
                Text("Onboarded. Home screen arrives in a later plan.")
                    .foregroundStyle(.secondary)

                #if DEBUG
                Button("Fire test tone") {
                    audioKeepalive.triggerTestTone()
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 24)

                Text("DEBUG only — proves the audio path can sound through silent mode before the 30-min unattended test.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                #endif
            }
            .padding()
        }
    }
}
