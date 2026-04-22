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
            Color.black.ignoresSafeArea()
            VStack(spacing: 24) {
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(context.date.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 88, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }

                if let location = baselines.first?.locationLabel {
                    Text("Meet yourself at \(location).")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                } else {
                    Text("Prove you're awake.")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.85))
                }

                if let error = scheduler.lastCaptureError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Spacer()

                Button {
                    onRequestCapture()
                } label: {
                    Text("Prove you're awake")
                        .font(.title3.bold())
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.white)
                        .foregroundStyle(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .padding(.horizontal)
                .padding(.bottom, 32)
            }
        }
    }
}
