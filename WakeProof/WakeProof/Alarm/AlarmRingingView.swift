//
//  AlarmRingingView.swift
//  WakeProof
//
//  Pure UI for the "wake up" screen. Persistence, camera presentation, and phase
//  transitions live outside this view — see CameraCaptureFlow + RootView.phaseContent.
//  Keeping this view pure was the fix for the nested-fullScreenCover dismissal bug
//  where tapping "Prove you're awake" closed the whole ringing screen.
//

import SwiftData
import SwiftUI

struct AlarmRingingView: View {

    @Environment(AlarmScheduler.self) private var scheduler
    @Query private var baselines: [BaselinePhoto]

    let onRequestCapture: () -> Void

    /// Round-1 PR-review I-1 (Wave 3.2, 2026-04-26): cache the decoded
    /// baseline `UIImage` in @State so an 18MP TrueDepth JPEG isn't decoded
    /// on MainActor for every body re-render. The previous
    /// `UIImage(data: $0.imageData)` call ran inside the body builder — at
    /// alarm fire (when the screen is competing for MainActor with the audio
    /// session re-arm + animation transitions), a synchronous 5–7 MB image
    /// decode is the same R4-class jank class that `ClaudeAPIClient.resizeForUpload`
    /// + `Task.detached` was supposed to address everywhere else.
    /// Populated in `.onAppear` via Task.detached and used directly in body.
    @State private var cachedBaselineImage: UIImage?

    /// Round-2 F-6 (Wave 3.4, 2026-04-26): when decode returns nil (corrupt
    /// JPEG bytes — rare; SwiftData store partial corruption), the body
    /// would silently render only the error banner with no visual reference.
    /// The user, half-awake at 7am, has no signal that the baseline image
    /// is unrecoverable. This flag drives a "Re-run onboarding" hint so the
    /// failure mode is visible.
    @State private var baselineDecodeFailed: Bool = false

    var body: some View {
        ZStack {
            Color.wpChar900.ignoresSafeArea()
            VStack(spacing: WPSpacing.xl) {
                Spacer()
                WPHeroTimeDisplay(style: .large)

                if let location = baselines.first?.locationLabel {
                    Text("Meet yourself at \(location).")
                        .wpFont(.title3)
                        .foregroundStyle(Color.wpCream50.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, WPSpacing.xl2)
                } else {
                    Text("Prove you're awake.")
                        .wpFont(.title3)
                        .foregroundStyle(Color.wpCream50.opacity(0.85))
                }

                if let error = scheduler.lastCaptureError {
                    // Phase 8 fix: when verification fails, also show the
                    // baseline photo so the user can match the framing.
                    // Text-only error ("scene mismatch") was hard to act on
                    // — users didn't know what to aim the camera at.
                    //
                    // I-1 (Wave 3.2): use cached UIImage populated in
                    // .onAppear off-main rather than decoding 5–7 MB of JPEG
                    // on MainActor for every body re-render.
                    if let baselineImage = cachedBaselineImage {
                        VStack(spacing: WPSpacing.sm) {
                            Text("Match this scene")
                                .wpFont(.caption)
                                .foregroundStyle(Color.wpCream50.opacity(0.6))
                            Image(uiImage: baselineImage)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 200)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .padding(.horizontal, WPSpacing.xl2)
                    } else if baselineDecodeFailed {
                        // F-6 (Wave 3.4): decode failed — surface the
                        // unrecoverable state so the user knows to re-run
                        // onboarding rather than tap "Prove you're awake"
                        // forever against a missing reference.
                        Text("Baseline photo couldn't be loaded. Reinstall to re-capture.")
                            .wpFont(.footnote)
                            .foregroundStyle(Color.wpAttempted)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, WPSpacing.xl2)
                    }
                    Text(error)
                        .wpFont(.callout)
                        .foregroundStyle(Color.wpAttempted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, WPSpacing.xl2)
                }

                Spacer()

                Button("Prove you're awake", action: onRequestCapture)
                    .buttonStyle(.primaryAlarm)
                    .padding(.horizontal, WPSpacing.xl2)
                    .padding(.bottom, WPSpacing.xl2)
            }
        }
        .preferredColorScheme(.dark)
        .task {
            // I-1 (Wave 3.2): decode the baseline JPEG off MainActor so a
            // late-arriving REJECTED render doesn't pay 5–7 MB of decode at
            // animation time. Decode on the user-initiated background QoS
            // and assign back to MainActor.
            //
            // F-6 (Wave 3.4): record decode-failed so the body can render
            // the "couldn't load" hint instead of silently skipping the
            // "Match this scene" overlay.
            if cachedBaselineImage == nil, let data = baselines.first?.imageData {
                let image = await Task.detached(priority: .userInitiated) {
                    UIImage(data: data)
                }.value
                if let image {
                    cachedBaselineImage = image
                } else {
                    baselineDecodeFailed = true
                }
            }
        }
    }
}
