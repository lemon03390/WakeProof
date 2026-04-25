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

    /// R8 fix: watchdog against "camera callbacks never fire". Previously the
    /// `CameraHostController` callback defaults were `Logger.fault(...)`; if the
    /// picker ever failed to deliver a terminal outcome (iOS bug, stuck
    /// controller, permission race) the alarm stayed in `.capturing` forever
    /// and the user's only escape was force-quit — which produced an
    /// UNRESOLVED WakeAttempt row with no user-visible explanation. The
    /// watchdog fires after `watchdogTimeout` seconds and reverse-transitions
    /// back to `.ringing` with a user-visible error, exactly as if the user
    /// had cancelled the picker themselves.
    ///
    /// 30s is conservative: a real capture (tap record, 1–2s video, tap stop,
    /// frame extraction) completes in < 10s on a 3-year-old device. 30s
    /// leaves plenty of headroom for cold-start camera init while still
    /// cutting off genuinely stuck sessions before the user thinks they need
    /// to force-quit.
    let watchdogTimeout: TimeInterval

    init(watchdogTimeout: TimeInterval = 30, onSuccess: @escaping (WakeAttempt) -> Void) {
        self.watchdogTimeout = watchdogTimeout
        self.onSuccess = onSuccess
    }

    private let logger = Logger(subsystem: LogSubsystem.verification, category: "captureFlow")

    /// Holds the watchdog task + a flag that a terminal callback has already
    /// fired. Using a class so multiple nested closures can share mutable
    /// state on the main actor without fighting SwiftUI's value-type `@State`.
    /// Stored in a `@State` wrapper below because the instance must survive
    /// re-renders for the duration of the capture flow.
    @State private var watchdog = WatchdogBox()

    var body: some View {
        CameraCaptureView(
            onCaptured: { result in
                // Watchdog cancel BEFORE touching scheduler state — if cancel
                // misorders with the async persist, a late watchdog fire
                // could double-transition. Claiming also prevents the
                // persist's own failure path from double-reporting.
                guard watchdog.claim() else {
                    logger.warning("onCaptured fired after watchdog already claimed — dropping (scheduler already returned to ringing)")
                    return
                }
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
                guard watchdog.claim() else {
                    logger.warning("onCancelled fired after watchdog already claimed — dropping")
                    return
                }
                scheduler.returnToRingingWith(error: "Canceled. Tap \"Prove you're awake\" to retry.")
            },
            onFailed: { error in
                guard watchdog.claim() else {
                    logger.warning("onFailed fired after watchdog already claimed — dropping")
                    return
                }
                logger.error("Capture failed: \(String(describing: error), privacy: .public)")
                scheduler.returnToRingingWith(error: error.errorDescription ?? "Capture failed. Try again.")
            }
        )
        .onAppear { armWatchdog() }
        .onDisappear { watchdog.cancelTimer() }
    }

    /// Arm the watchdog timer. Called on view appear. If a terminal callback
    /// claims the latch first, the timer's closure body short-circuits. If
    /// the timer wins, it reverse-transitions to ringing with the user-visible
    /// "camera didn't respond" message.
    ///
    /// Timer is a detached Task.sleep rather than a Timer — keeps everything
    /// in the Swift-Concurrency lane so cancellation is structured and the
    /// body can hop to MainActor cleanly.
    @MainActor
    private func armWatchdog() {
        // Defensive: cancel any prior timer. SwiftUI can re-invoke `onAppear`
        // on identity churn (e.g., environment object change) — we don't want
        // two timers racing.
        watchdog.cancelTimer()
        let timeout = watchdogTimeout
        let box = watchdog
        let boundLogger = logger
        let boundScheduler = scheduler
        let task = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(timeout))
            } catch {
                return // cancelled — a terminal callback already claimed.
            }
            guard box.claim() else { return }
            boundLogger.fault("Camera watchdog fired — no terminal callback in \(timeout, privacy: .public)s; reverse-transitioning to ringing")
            boundScheduler.returnToRingingWith(error: "Camera didn't respond — please try again.")
        }
        watchdog.installTimer(task)
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
        // S-I6 (Wave 2.1, 2026-04-26): defence-in-depth — the source is always a
        // UUID-derived filename from `moveVideoToDocuments`, but validating before
        // persisting means any future change to the naming convention can't
        // accidentally introduce a traversal-shaped value into SwiftData.
        let videoFilename = durableVideoURL.lastPathComponent
        if WakeAttemptCleaner.isSafeFilename(videoFilename) {
            attempt.videoPath = videoFilename // relative to WakeAttempts/
        } else {
            logger.fault("Refusing to persist unsafe videoPath='\(videoFilename, privacy: .private)' — leaving nil")
        }
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

// MARK: - Watchdog helper

/// R8 fix: single-use latch + timer box that coordinates the camera-capture
/// watchdog with the three terminal callbacks (captured / cancelled / failed).
/// Whichever side calls `claim()` first owns the right to drive the scheduler
/// transition; the loser short-circuits. The timer task is retained so the
/// successful-callback paths can cancel it cleanly.
///
/// Reference type because multiple closures (onCaptured / onCancelled /
/// onFailed / the timer task) share this state. MainActor-confined because
/// SwiftUI `@State` reads happen on the main actor and the watchdog is
/// scoped to a single view's lifetime — no need for lock-based synchronisation.
///
/// Split from `CompletionLatch` (BackgroundTasks) because that one has to be
/// Sendable + `OSAllocatedUnfairLock`-guarded (called from an unspecified
/// BackgroundTasks queue). This one only runs on MainActor, so the lighter
/// shape is appropriate.
@MainActor
final class WatchdogBox {
    private var claimed = false
    private var timer: Task<Void, Never>?

    init() {}

    /// Claim the latch. Returns true on first call, false thereafter. Safe to
    /// call from all the terminal-callback paths and from the timer itself.
    func claim() -> Bool {
        guard !claimed else { return false }
        claimed = true
        timer?.cancel()
        timer = nil
        return true
    }

    /// Install the watchdog timer task. Stored so `claim()` + `cancelTimer()`
    /// can both cancel it deterministically.
    func installTimer(_ task: Task<Void, Never>) {
        timer = task
    }

    /// Cancel the timer without claiming the latch. Called from
    /// `onDisappear` — if the view is torn down while still waiting for a
    /// callback, we don't want the timer to outlive its context.
    func cancelTimer() {
        timer?.cancel()
        timer = nil
    }

    /// Read-only view of whether anyone has claimed. Used by tests to assert
    /// the latch's final state.
    var isClaimed: Bool { claimed }
}
