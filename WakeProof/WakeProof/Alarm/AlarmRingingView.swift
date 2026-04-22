//
//  AlarmRingingView.swift
//  WakeProof
//
//  The full-screen "wake up" view. The only exit is a completed capture —
//  there is no dismiss button, per CLAUDE.md "the alarm must not be bypassable".
//  Force-quit is still possible (we cannot prevent that on iOS) but we do not
//  expose an in-app shortcut to it.
//

import SwiftData
import SwiftUI

struct AlarmRingingView: View {

    @Environment(AlarmScheduler.self) private var scheduler
    @Environment(\.modelContext) private var modelContext
    @Query private var baselines: [BaselinePhoto]

    @State private var showCamera: Bool = false

    let onVerificationCaptured: (CameraCaptureResult) -> Void

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
                Spacer()

                Button {
                    showCamera = true
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
        .fullScreenCover(isPresented: $showCamera) {
            CameraCaptureView(
                onCaptured: { result in
                    showCamera = false
                    persist(result)
                    onVerificationCaptured(result)
                },
                onCancelled: {
                    showCamera = false
                }
            )
        }
    }

    private func persist(_ result: CameraCaptureResult) {
        let attempt = WakeAttempt(scheduledAt: scheduler.nextFireAt ?? .now)
        attempt.capturedAt = .now
        attempt.imageData = result.stillImage.jpegData(compressionQuality: 0.9)
        attempt.videoPath = result.videoURL.path
        attempt.triggeredWindowStart = composeTime(hour: scheduler.window.startHour,
                                                   minute: scheduler.window.startMinute)
        attempt.triggeredWindowEnd = composeTime(hour: scheduler.window.endHour,
                                                 minute: scheduler.window.endMinute)
        modelContext.insert(attempt)
        try? modelContext.save()
    }

    private func composeTime(hour: Int, minute: Int) -> Date {
        var c = Calendar.current.dateComponents([.year, .month, .day], from: .now)
        c.hour = hour; c.minute = minute
        return Calendar.current.date(from: c) ?? .now
    }
}
