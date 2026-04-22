//
//  AlarmRingingView.swift
//  WakeProof
//
//  The full-screen "wake up" view. The only exit is a completed capture —
//  there is no dismiss button, per CLAUDE.md "the alarm must not be bypassable".
//  Force-quit is still possible (we cannot prevent that on iOS) but we do not
//  expose an in-app shortcut to it.
//

import Foundation
import SwiftData
import SwiftUI
import os

struct AlarmRingingView: View {

    @Environment(AlarmScheduler.self) private var scheduler
    @Environment(\.modelContext) private var modelContext
    @Query private var baselines: [BaselinePhoto]

    @State private var showCamera: Bool = false
    @State private var captureError: String?

    let onVerificationCaptured: (CameraCaptureResult) -> Void

    private let logger = Logger(subsystem: "com.wakeproof.alarm", category: "ringing")

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

                if let captureError {
                    Text(captureError)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Spacer()

                Button {
                    captureError = nil
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
                    captureError = nil
                    if let persisted = persist(result) {
                        onVerificationCaptured(persisted)
                    } else {
                        // Persistence failed — do not stop the alarm. User must retry.
                        captureError = "Save failed — tap again to retry."
                    }
                },
                onCancelled: {
                    showCamera = false
                    captureError = "Canceled. Tap \"Prove you're awake\" to retry."
                },
                onFailed: { error in
                    showCamera = false
                    logger.error("Capture failed: \(String(describing: error), privacy: .public)")
                    captureError = "Capture failed. Try again — good light, face visible."
                }
            )
        }
    }

    /// Persist the capture. Returns the result with `videoURL` rewritten to the Documents
    /// copy so downstream handlers use the durable path. Returns nil on save failure
    /// (caller leaves the alarm running).
    private func persist(_ result: CameraCaptureResult) -> CameraCaptureResult? {
        let durableVideoURL: URL
        do {
            durableVideoURL = try copyVideoToDocuments(result.videoURL)
        } catch {
            logger.error("Failed to copy captured video to Documents: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        let attempt = WakeAttempt(scheduledAt: scheduler.nextFireAt ?? .now)
        attempt.capturedAt = .now
        attempt.imageData = result.stillImage.jpegData(compressionQuality: 0.9)
        attempt.videoPath = durableVideoURL.lastPathComponent // relative to WakeAttempts/
        attempt.triggeredWindowStart = composeTime(hour: scheduler.window.startHour,
                                                   minute: scheduler.window.startMinute)
        attempt.triggeredWindowEnd = composeTime(hour: scheduler.window.endHour,
                                                 minute: scheduler.window.endMinute)

        modelContext.insert(attempt)
        do {
            try modelContext.save()
            logger.info("WakeAttempt persisted at \(attempt.capturedAt?.ISO8601Format() ?? "?", privacy: .public)")
        } catch {
            logger.error("SwiftData save failed for WakeAttempt: \(error.localizedDescription, privacy: .public)")
            modelContext.rollback()
            return nil
        }
        return CameraCaptureResult(stillImage: result.stillImage, videoURL: durableVideoURL)
    }

    /// Move the picker's tmp video into `Documents/WakeAttempts/` so it survives relaunch.
    /// iOS purges NSTemporaryDirectory aggressively; storing the tmp path in SwiftData
    /// would mean the video is a dead reference by morning.
    private func copyVideoToDocuments(_ tmpURL: URL) throws -> URL {
        let fm = FileManager.default
        let docsURL = try fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = docsURL.appendingPathComponent("WakeAttempts", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("\(UUID().uuidString).mov")
        try fm.copyItem(at: tmpURL, to: dest)
        return dest
    }

    private func composeTime(hour: Int, minute: Int) -> Date {
        var c = Calendar.current.dateComponents([.year, .month, .day], from: .now)
        c.hour = hour; c.minute = minute
        return Calendar.current.date(from: c) ?? .now
    }
}
