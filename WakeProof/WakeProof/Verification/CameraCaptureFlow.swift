//
//  CameraCaptureFlow.swift
//  WakeProof
//
//  The "capturing" half of the alarm state machine. Presents CameraCaptureView
//  inline (no nested fullScreenCover — see the AlarmRingingView header for why),
//  handles durable persistence into Documents/WakeAttempts/, and routes cancel +
//  failure back to AlarmRingingView via scheduler.returnToRingingWith(error:).
//

import Foundation
import SwiftData
import SwiftUI
import os

struct CameraCaptureFlow: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(AlarmScheduler.self) private var scheduler

    let onSuccess: (CameraCaptureResult) -> Void

    private let logger = Logger(subsystem: "com.wakeproof.verification", category: "captureFlow")

    var body: some View {
        CameraCaptureView(
            onCaptured: { result in
                if let persisted = persist(result) {
                    onSuccess(persisted)
                } else {
                    scheduler.returnToRingingWith(error: "Save failed — tap \"Prove you're awake\" to retry.")
                }
            },
            onCancelled: {
                scheduler.returnToRingingWith(error: "Canceled. Tap \"Prove you're awake\" to retry.")
            },
            onFailed: { error in
                logger.error("Capture failed: \(String(describing: error), privacy: .public)")
                scheduler.returnToRingingWith(error: "Capture failed. Try again — good light, face visible.")
            }
        )
    }

    /// Persist the capture. Returns the result with `videoURL` rewritten to the Documents
    /// copy so downstream handlers use the durable path. Returns nil on save failure so
    /// the caller leaves the alarm running for retry.
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
