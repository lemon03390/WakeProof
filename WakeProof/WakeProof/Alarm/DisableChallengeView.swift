//
//  DisableChallengeView.swift
//  WakeProof
//
//  Wave 5 G1 (§12.4-G1): the mirror surface of AlarmRingingView for the
//  disable-challenge flow. Evening-self tapping "Alarm enabled → off" in
//  AlarmSchedulerView lands here; they must capture a photo and pass the same
//  Claude Opus 4.7 vision check as a morning ring before the toggle flips.
//
//  Two-state view:
//    1. Explainer — what's about to happen, with a "Prove" / "Cancel" pair.
//    2. Capture — embedded CameraCaptureFlow; on onSuccess we route the
//       WakeAttempt to VisionVerifier.verifyDisableChallenge(...).
//
//  No anti-spoof re-prompt branch — the G1 flow is intentionally single-shot
//  (see VisionVerifier.verifyDisableChallenge docstring). A failed challenge
//  returns the user to AlarmSchedulerView with the alarm still enabled.
//

import SwiftData
import SwiftUI

struct DisableChallengeView: View {

    @Environment(AlarmScheduler.self) private var scheduler
    @Environment(VisionVerifier.self) private var verifier
    @Environment(\.modelContext) private var modelContext

    @Query private var baselines: [BaselinePhoto]

    /// Two-state toggle. Starts false; tap "Prove you're awake → disable"
    /// flips it true and embeds CameraCaptureFlow. Cancel / reject verdicts
    /// exit the view via scheduler transitions (.disableChallenge → .idle),
    /// so there's no path that needs to flip this back to false mid-view.
    @State private var showCapture = false

    var body: some View {
        ZStack {
            // Match AlarmRingingView's background so the swap from idle →
            // disableChallenge doesn't flash a different palette. The
            // explainer reads as "you're about to do something serious"
            // rather than "you're inside a form setting".
            Color.wpChar900.ignoresSafeArea()
            if showCapture {
                CameraCaptureFlow(onSuccess: handleCapturedAttempt)
            } else {
                explainer
            }
        }
        .preferredColorScheme(.dark)
    }

    /// Initial explainer surface. Copy intentionally echoes AlarmRingingView's
    /// "Meet yourself at {location}" frame — the point is that disabling the
    /// alarm imposes the SAME proof burden as the morning ring, so the UX
    /// language is deliberately identical.
    private var explainer: some View {
        VStack(spacing: WPSpacing.xl) {
            Spacer()

            Image(systemName: "lock.shield")
                .font(.system(size: 64))
                .foregroundStyle(Color.wpCream50.opacity(0.9))

            Text("Prove you're awake to disable.")
                .wpFont(.title2)
                .foregroundStyle(Color.wpCream50)
                .multilineTextAlignment(.center)
                .padding(.horizontal, WPSpacing.xl2)

            if let location = baselines.first?.locationLabel {
                Text("Meet yourself at \(location) first — same as a morning ring.")
                    .wpFont(.body)
                    .foregroundStyle(Color.wpCream50.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, WPSpacing.xl2)
            } else {
                // Onboarding should have guaranteed a baseline before the
                // scheduler view is reachable — if we somehow hit this
                // branch, show a neutral message rather than a blank
                // placeholder.
                Text("Disabling requires the same proof as waking.")
                    .wpFont(.body)
                    .foregroundStyle(Color.wpCream50.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, WPSpacing.xl2)
            }

            if let error = scheduler.lastCaptureError {
                Text(error)
                    .wpFont(.footnote)
                    .foregroundStyle(Color.wpAttempted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, WPSpacing.xl2)
            }

            Spacer()

            VStack(spacing: WPSpacing.sm) {
                Button("Prove you're awake → disable") {
                    showCapture = true
                }
                .buttonStyle(.primaryAlarm)

                Button("Cancel") {
                    scheduler.cancelDisableChallenge()
                }
                .foregroundStyle(Color.wpCream50.opacity(0.7))
                .padding(.top, WPSpacing.xs1)
            }
            .padding(.horizontal, WPSpacing.xl2)
            .padding(.bottom, WPSpacing.xl3)
        }
    }

    /// Hand the captured WakeAttempt to the verifier. Baseline is guaranteed
    /// by the same invariant that protects `CameraCaptureFlow`'s ring path —
    /// AlarmSchedulerView is only rendered when baselines.isEmpty is false
    /// (see `RootView.body`). A missing baseline here is a programmer error;
    /// we surface it via `disableChallengeFailed` rather than silently
    /// hanging so the alarm stays enabled and the user is returned to idle.
    private func handleCapturedAttempt(_ attempt: WakeAttempt) {
        guard let baseline = baselines.first else {
            scheduler.disableChallengeFailed(
                error: "No baseline photo — re-run onboarding."
            )
            return
        }
        Task { @MainActor in
            await verifier.verifyDisableChallenge(
                attempt: attempt,
                baseline: baseline,
                context: modelContext
            )
        }
    }
}
