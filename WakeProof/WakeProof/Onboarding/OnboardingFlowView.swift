//
//  OnboardingFlowView.swift
//  WakeProof
//
//  Multi-step onboarding. Each permission lives behind a contextual explanation screen
//  that sells *why* WakeProof wants it, framed as a self-commitment contract.
//
//  Flow:
//    0. Welcome / manifesto
//    1. Notifications permission
//    2. Camera permission
//    3. HealthKit permission
//    4. Motion permission
//    5. Baseline photo capture
//    6. Done — hand off to home
//

import SwiftData
import SwiftUI

struct OnboardingFlowView: View {

    @Environment(PermissionsManager.self) private var permissions
    @Environment(\.modelContext) private var modelContext
    @State private var step: Step = .welcome

    enum Step: CaseIterable {
        case welcome, notifications, camera, health, motion, baseline, done
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack {
                switch step {
                case .welcome:
                    WelcomeStep(advance: advance)
                case .notifications:
                    PermissionStep(
                        title: "Let us wake you",
                        message: "WakeProof needs notification permission to ring your alarm. Critical Alert permission is requested too — that's the one that bypasses silent mode when your morning self has muted your phone.",
                        action: "Enable notifications",
                        handler: {
                            await permissions.requestNotifications()
                            advance()
                        }
                    )
                case .camera:
                    PermissionStep(
                        title: "The contract needs a witness",
                        message: "When your alarm rings, you'll take one live photo at your designated wake-location. Claude Opus 4.7 checks you're actually there and actually awake. No photos leave your device except that single verification call.",
                        action: "Enable camera",
                        handler: {
                            await permissions.requestCamera()
                            advance()
                        }
                    )
                case .health:
                    PermissionStep(
                        title: "Last night in context",
                        message: "If you wear an Apple Watch, WakeProof reads your sleep data to show a summary when you successfully wake up. Optional — skip and everything else still works.",
                        action: "Enable Health",
                        secondary: "Skip",
                        handler: {
                            await permissions.requestHealthKit()
                            advance()
                        },
                        secondaryHandler: { advance() }
                    )
                case .motion:
                    PermissionStep(
                        title: "Catch the natural wake",
                        message: "WakeProof watches for the micro-movements that mean you're already drifting toward consciousness, and times your alarm to that moment instead of jolting you out of deep sleep.",
                        action: "Enable motion",
                        secondary: "Skip",
                        handler: {
                            await permissions.requestMotion()
                            advance()
                        },
                        secondaryHandler: { advance() }
                    )
                case .baseline:
                    BaselinePhotoView(onCaptured: { photo in
                        modelContext.insert(photo)
                        try? modelContext.save()
                        advance()
                    })
                case .done:
                    DoneStep()
                }
            }
            .padding()
            .foregroundStyle(.white)
        }
    }

    private func advance() {
        guard let currentIndex = Step.allCases.firstIndex(of: step) else { return }
        let next = Step.allCases.index(after: currentIndex)
        if next < Step.allCases.endIndex {
            step = Step.allCases[next]
        }
    }
}

// MARK: - Sub-views

private struct WelcomeStep: View {
    let advance: () -> Void
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Text("WakeProof")
                .font(.system(size: 42, weight: .bold))
            Text("An alarm your future self can't cheat.")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
            Spacer()
            Text("You'll set a contract with yourself: tomorrow morning, you will be out of bed at your designated wake-location. The only way to silence the alarm is to prove it. Claude Opus 4.7 is the witness.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.75))
            Button(action: advance) {
                Text("Begin")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.white)
                    .foregroundStyle(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}

private struct PermissionStep: View {
    let title: String
    let message: String
    let action: String
    var secondary: String? = nil
    let handler: @MainActor () async -> Void
    var secondaryHandler: (() -> Void)? = nil

    @State private var isWorking = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Text(title)
                .font(.system(size: 34, weight: .bold))
                .multilineTextAlignment(.center)
            Text(message)
                .font(.body)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
            Spacer()
            VStack(spacing: 12) {
                Button {
                    Task {
                        isWorking = true
                        await handler()
                        isWorking = false
                    }
                } label: {
                    Text(isWorking ? "Working..." : action)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.white)
                        .foregroundStyle(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(isWorking)

                if let secondary, let secondaryHandler {
                    Button(secondary, action: secondaryHandler)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
    }
}

private struct DoneStep: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("You're set.")
                .font(.system(size: 34, weight: .bold))
            Text("Tomorrow morning, meet yourself at your wake-location.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.8))
        }
    }
}
