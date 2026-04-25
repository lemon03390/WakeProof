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
