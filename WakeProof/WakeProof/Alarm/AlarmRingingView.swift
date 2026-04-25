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
                    if let baselineImage = baselines.first.flatMap({ UIImage(data: $0.imageData) }) {
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
    }
}
