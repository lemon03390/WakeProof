//
//  CameraCaptureFlow.swift
//  WakeProof
//
//  The "capturing" half of the alarm state machine. Presents CameraCaptureView
//  inline (no nested fullScreenCover — see the AlarmRingingView header for why),
//  handles durable persistence into Documents/WakeAttempts/, and routes cancel +
//  failure back to AlarmRingingView via scheduler.returnToRingingWith(error:).
//

import AVFoundation
import Foundation
import SwiftData
import SwiftUI
import os

struct CameraCaptureFlow: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(AlarmScheduler.self) private var scheduler

    let onSuccess: (WakeAttempt) -> Void

    private let logger = Logger(subsystem: "com.wakeproof.verification", category: "captureFlow")

    var body: some View {
        CameraCaptureView(
            onCaptured: { result in
                Task { @MainActor in
                    do {
                        let persistedAttempt = try await persist(result)
                        scheduler.markCaptureCompleted()
                        onSuccess(persistedAttempt)
                    } catch let error as CaptureRejectionReason {
                        scheduler.returnToRingingWith(error: error.userMessage)
                    } catch {
                        logger.error("Persist threw unexpected error: \(error.localizedDescription, privacy: .public)")
                        scheduler.returnToRingingWith(error: "Save failed — tap \"Prove you're awake\" to retry.")
                    }
                }
            },
            onCancelled: {
                scheduler.returnToRingingWith(error: "Canceled. Tap \"Prove you're awake\" to retry.")
            },
            onFailed: { error in
                logger.error("Capture failed: \(String(describing: error), privacy: .public)")
                scheduler.returnToRingingWith(error: error.errorDescription ?? "Capture failed. Try again.")
            }
        )
    }

    /// Reasons we may reject a capture before counting it as a verification attempt. Surfaces
    /// the user-facing message so the caller can route it to `returnToRingingWith(error:)`.
    private enum CaptureRejectionReason: LocalizedError {
        case videoTooShort(seconds: Double)
        case videoTooSmall(bytes: Int)
        case copyFailed(underlying: Error)
        case persistFailed(underlying: Error)

        var userMessage: String {
            switch self {
            case .videoTooShort: return "That clip was too short. Tap the red button to start, tap it again after 1–2 seconds to stop."
            case .videoTooSmall: return "That capture was empty. Make sure the camera saw something — tap \"Prove you're awake\" to retry."
            case .copyFailed:    return "Couldn't save the clip. Storage may be full — tap \"Prove you're awake\" to retry."
            case .persistFailed: return "Save failed — tap \"Prove you're awake\" to retry."
            }
        }

        var errorDescription: String? { userMessage }
    }

    /// Persist the capture. Returns the result with `videoURL` rewritten to the Documents
    /// copy so downstream handlers use the durable path. Throws `CaptureRejectionReason` on
    /// any rejection so the caller leaves the alarm running for retry.
    private func persist(_ result: CameraCaptureResult) async throws -> WakeAttempt {
        try await validate(result.videoURL)

        let durableVideoURL: URL
        do {
            durableVideoURL = try moveVideoToDocuments(result.videoURL)
        } catch {
            logger.error("Failed to move captured video to Documents: \(error.localizedDescription, privacy: .public)")
            throw CaptureRejectionReason.copyFailed(underlying: error)
        }

        // lastFireAt is the canonical "when did this alarm actually fire" — using nextFireAt
        // would record tomorrow's date because fire() pre-schedules the next morning before
        // the user finishes capturing.
        let scheduledFor = scheduler.lastFireAt ?? scheduler.nextFireAt ?? .now
        let attempt = WakeAttempt(scheduledAt: scheduledFor)
        attempt.capturedAt = .now
        attempt.imageData = result.stillImage.jpegData(compressionQuality: 0.9)
        attempt.videoPath = durableVideoURL.lastPathComponent // relative to WakeAttempts/
        attempt.triggeredWindowStart = WakeWindow.composeTime(hour: scheduler.window.startHour,
                                                              minute: scheduler.window.startMinute)
        attempt.triggeredWindowEnd = WakeWindow.composeTime(hour: scheduler.window.endHour,
                                                            minute: scheduler.window.endMinute)
        attempt.verdict = WakeAttempt.Verdict.captured.rawValue

        modelContext.insert(attempt)
        do {
            try modelContext.save()
            logger.info("WakeAttempt persisted at \(attempt.capturedAt?.ISO8601Format() ?? "?", privacy: .public) (scheduledFor=\(scheduledFor.ISO8601Format(), privacy: .public))")
        } catch {
            logger.error("SwiftData save failed for WakeAttempt: \(error.localizedDescription, privacy: .public)")
            modelContext.rollback()
            throw CaptureRejectionReason.persistFailed(underlying: error)
        }
        return attempt
    }

    /// Reject obvious sham captures (zero-byte stub files, 0.1 s tap-and-cancel videos).
    /// Skipped on simulator so the synthetic-result UI flow still works end-to-end.
    private func validate(_ videoURL: URL) async throws {
        #if targetEnvironment(simulator)
        return
        #else
        let fm = FileManager.default
        let attrs = try? fm.attributesOfItem(atPath: videoURL.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        guard size >= 10_000 else {
            logger.warning("Validation rejected: file size \(size) < 10000")
            throw CaptureRejectionReason.videoTooSmall(bytes: size)
        }
        let asset = AVURLAsset(url: videoURL)
        let duration = (try? await asset.load(.duration)) ?? .zero
        guard duration.seconds >= 1.0 else {
            logger.warning("Validation rejected: duration \(duration.seconds) < 1.0")
            throw CaptureRejectionReason.videoTooShort(seconds: duration.seconds)
        }
        #endif
    }

    /// Move the picker's tmp video into `Documents/WakeAttempts/` so it survives relaunch.
    /// iOS purges NSTemporaryDirectory aggressively; storing the tmp path in SwiftData
    /// would mean the video is a dead reference by morning. Move (not copy) avoids leaving
    /// a duplicate behind that the system would have to clean up.
    ///
    /// B13 fix: each .mov contains the user's bedroom audio + video. Without explicit
    /// file protection it's readable post-first-unlock; without excludeFromBackup it
    /// syncs to iCloud Backup. A heavy user accumulates months of private footage in
    /// iCloud over time — multi-week forensic retention if the iCloud account is ever
    /// compromised. Apply `.complete` protection (needs unlock for every access) and
    /// mark excluded from backup.
    private func moveVideoToDocuments(_ tmpURL: URL) throws -> URL {
        let fm = FileManager.default
        let docsURL = try fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = docsURL.appendingPathComponent("WakeAttempts", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // Mark the directory as excluded from iCloud backup. Unconditional set is
        // idempotent (microsecond write); the previous pre-check read was doing the
        // same kind of stat syscall and saving nothing on the happy path.
        dir.markingExcludedFromBackup()
        let dest = dir.appendingPathComponent("\(UUID().uuidString).mov")
        do {
            try fm.moveItem(at: tmpURL, to: dest)
        } catch {
            // Fall back to copy if move fails (e.g., cross-volume): better to preserve the
            // capture than to drop it because of an unexpected filesystem layout.
            try fm.copyItem(at: tmpURL, to: dest)
        }
        // Best-effort protection: if this fails (ephemeral filesystem state, iOS bug),
        // log but don't block the capture flow — the scheduled alarm takes priority
        // over a defence-in-depth privacy hardening that has already excluded backup.
        do {
            try fm.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: dest.path
            )
        } catch {
            logger.warning("Failed to set .complete file protection on \(dest.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        return dest
    }

}
