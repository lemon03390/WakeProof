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
//    4. Bedtime (Layer 3 briefing enablement — skippable, default 23:00)
//    5. Baseline photo capture
//    6. Done — hand off to home
//

import SwiftData
import SwiftUI
import os

struct OnboardingFlowView: View {

    @Environment(PermissionsManager.self) private var permissions
    @Environment(\.modelContext) private var modelContext
    @State private var step: Step = .welcome
    @State private var saveError: String?

    private let logger = Logger(subsystem: LogSubsystem.onboarding, category: "flow")

    enum Step: CaseIterable {
        case welcome, notifications, camera, health, bedtime, baseline, done
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack {
                switch step {
                case .welcome:
                    WelcomeStep(advance: advance)
                case .notifications:
                    // Notifications are a hard requirement — without them the backup notification
                    // can't fire and the alarm silently no-ops if the OS has suspended the process.
                    PermissionStep(
                        title: "Let us wake you",
                        message: "WakeProof needs notification permission to ring your alarm even when the app is backgrounded. Keep your phone on ringer mode — silent mode bypass requires a Critical Alerts entitlement Apple is still reviewing.",
                        action: "Enable notifications",
                        deniedMessage: "Without notifications WakeProof can't reliably wake you. Open Settings → WakeProof → Notifications to enable, then return.",
                        handler: {
                            await permissions.requestNotifications()
                        },
                        verifyGranted: { permissions.notifications == .granted },
                        onAdvance: advance
                    )
                case .camera:
                    PermissionStep(
                        title: "The contract needs a witness",
                        message: "When your alarm rings, you'll take one live photo at your designated wake-location. Claude Opus 4.7 checks you're actually there and actually awake. No photos leave your device except that single verification call.",
                        action: "Enable camera",
                        deniedMessage: "Camera access is required to verify you're awake. Open Settings → WakeProof → Camera to enable, then return.",
                        handler: {
                            await permissions.requestCamera()
                        },
                        verifyGranted: { permissions.camera == .granted },
                        onAdvance: advance
                    )
                case .health:
                    PermissionStep(
                        title: "Last night in context",
                        message: "If you wear an Apple Watch, WakeProof reads your sleep data to show a summary when you successfully wake up. Optional — skip and everything else still works.",
                        action: "Enable Health",
                        secondary: "Skip",
                        handler: {
                            await permissions.requestHealthKit()
                        },
                        // Optional permission — never block advance.
                        verifyGranted: { true },
                        onAdvance: advance,
                        secondaryHandler: advance
                    )
                case .bedtime:
                    // Layer 3 — bedtime arms the overnight-briefing scheduler. Skippable;
                    // users who skip or disable the toggle never trigger BGProcessingTask
                    // refreshes, so the Managed Agents $0.08/hr meter never starts.
                    BedtimeStep(onAdvance: advance)
                case .baseline:
                    VStack(spacing: 12) {
                        BaselinePhotoView(onCaptured: persistBaseline)
                        if let saveError {
                            Text(saveError)
                                .font(.callout)
                                .foregroundStyle(.orange)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }
                    }
                case .done:
                    DoneStep()
                }
            }
            .padding()
            .foregroundStyle(.white)
        }
    }

    private func persistBaseline(_ photo: BaselinePhoto) {
        modelContext.insert(photo)
        do {
            try modelContext.save()
            saveError = nil
            // Wave 5 G1 (§12.4-G1): the first successful BaselinePhoto persist
            // is the moment the user has committed to WakeProof — start the
            // 24h grace clock here. Idempotent: repeat calls never overwrite
            // the first-install timestamp, so a user re-running onboarding
            // (baseline re-capture path) keeps the original grace window.
            // `WakeProofApp.bootstrapIfNeeded` also calls this as a defensive
            // backfill for pre-G1 users whose baseline pre-dates the timestamp.
            AlarmScheduler.recordFirstInstallIfNeeded()
            advance()
        } catch {
            // Without surfacing this, the user advances thinking the baseline is committed,
            // but RootView's @Query stays empty next launch and onboarding loops forever.
            logger.error("SwiftData save failed for BaselinePhoto: \(error.localizedDescription, privacy: .public)")
            modelContext.rollback()
            saveError = "Couldn't save your baseline. Please retake — if this keeps happening, restart WakeProof."
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
            Button("Begin", action: advance)
                .buttonStyle(.primaryWhite)
        }
    }
}

private struct PermissionStep: View {
    let title: String
    let message: String
    let action: String
    var secondary: String? = nil
    var deniedMessage: String? = nil
    let handler: @MainActor () async -> Void
    /// Returns true if the requested permission ended up granted. When false (and
    /// `deniedMessage` is set), the step refuses to advance and surfaces the message.
    let verifyGranted: @MainActor () -> Bool
    let onAdvance: @MainActor () -> Void
    var secondaryHandler: (() -> Void)? = nil

    @State private var isWorking = false
    @State private var deniedNotice: String?
    @State private var hasAdvanced = false
    @Environment(\.scenePhase) private var scenePhase

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
            if let deniedNotice {
                Text(deniedNotice)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            VStack(spacing: 12) {
                Button(action: tap) {
                    Text(isWorking ? "Working..." : action)
                }
                .buttonStyle(.primaryWhite)
                .disabled(isWorking)

                if deniedNotice != nil, let url = URL(string: UIApplication.openSettingsURLString) {
                    Link("Open Settings", destination: url)
                        .foregroundStyle(.white.opacity(0.85))
                }

                if let secondary, let secondaryHandler {
                    Button(secondary, action: secondaryHandler)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // After the user round-trips through Settings, scenePhase returns to .active.
            // Re-evaluate the gate so a now-granted permission auto-advances instead of
            // forcing the user to tap "Enable" again (which would just re-prompt iOS).
            // The deniedNotice guard scopes this to the post-deny path; the hasAdvanced
            // guard prevents racing tap()'s own onAdvance — both observers can fire when
            // the iOS permission prompt momentarily inactivates the scene then returns.
            guard newPhase == .active, deniedNotice != nil else { return }
            if verifyGranted() {
                deniedNotice = nil
                advanceOnce()
            }
        }
    }

    private func tap() {
        // Set isWorking synchronously BEFORE spawning the Task. The original code set it
        // inside the Task closure, which meant a fast second tap could fire before the first
        // task scheduled — both Tasks would run, advancing the user past a permission screen.
        guard !isWorking else { return }
        isWorking = true
        deniedNotice = nil
        Task { @MainActor in
            await handler()
            isWorking = false
            if verifyGranted() {
                advanceOnce()
            } else if let deniedMessage {
                deniedNotice = deniedMessage
            } else {
                advanceOnce()
            }
        }
    }

    /// Idempotent advance — either tap()'s post-handler verify OR the scenePhase observer
    /// can hit this; without the guard, an in-app permission prompt that briefly inactivates
    /// the scene then returns granted would call advance twice and SKIP the next step.
    private func advanceOnce() {
        guard !hasAdvanced else { return }
        hasAdvanced = true
        onAdvance()
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
