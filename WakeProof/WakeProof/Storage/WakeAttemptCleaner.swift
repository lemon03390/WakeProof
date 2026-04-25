//
//  WakeAttemptCleaner.swift
//  WakeProof
//
//  S-C4 (Wave 2.1, 2026-04-26): retention policy for wake-attempt artefacts.
//
//  Rationale: every wake attempt persists a bedroom video (~3.5 s @ .medium
//  preset, ~30–80 KB) and a JPEG-compressed still inside SwiftData. Without a
//  retention policy these accumulate indefinitely — a daily user has 365
//  bedroom recordings after a year. The Info.plist `NSMicrophoneUsageDescription`
//  and `NSCameraUsageDescription` (post-S-C4 update) promise ~7-day local
//  retention; this service enforces that promise.
//
//  Retention policy (subject-to-change-with-product):
//    - Video files (`Documents/WakeAttempts/*.mov`):   delete after 7 days
//    - WakeAttempt.imageData (in SwiftData rows):       nil out after 30 days
//      (we keep the row for streak / audit purposes, just drop the bytes)
//    - tmp capture leftovers (`tmp/wakeproof-capture-*`): delete > 24 h old
//
//  The 30-day window for imageData is longer than the 7-day video window so
//  the user can scroll back further visually if the verdict is contested in
//  the morning briefing flow. Image bytes are smaller than video bytes per
//  attempt by ~10×, so the privacy footprint is bounded.
//
//  Invocation: launched from `WakeProofApp.bootstrapIfNeeded()` once per cold
//  start. Cheap (single fetch + filesystem scan); no recurring timer.
//
//  S-I6 (Wave 2.1): `WakeAttempt.videoPath` is validated as a plain filename
//  (no `/`, no `..`, no leading `.`) before any filesystem operation. A
//  tampered SwiftData row with a traversal payload would cause a no-op delete
//  + warning log, never an out-of-directory file removal.
//

import Foundation
import SwiftData
import os

@MainActor
enum WakeAttemptCleaner {
    private static let logger = Logger(subsystem: LogSubsystem.app, category: "wake-attempt-cleaner")

    /// Days to keep .mov clips on disk.
    static let videoRetentionDays: Int = 7
    /// Days to keep `imageData` bytes in WakeAttempt rows. Row itself is kept.
    static let imageDataRetentionDays: Int = 30
    /// Hours to keep tmp capture leftovers (cancelled / orphaned recordings).
    static let tmpCaptureRetentionHours: Int = 24

    /// Run all retention sweeps. Safe to call repeatedly — each pass is bounded
    /// by an age cutoff so already-cleaned rows are skipped.
    static func runRetentionSweep(context: ModelContext) {
        sweepOldImageData(context: context)
        sweepOldVideoFiles()
        sweepTmpCaptureLeftovers()
    }

    /// Allows the user to manually clear all wake recordings + image bytes.
    /// Wired to a Settings action; doesn't delete the WakeAttempt rows themselves
    /// (those carry verdict / streak data the user may want to keep).
    static func purgeAllWakeRecordings(context: ModelContext) {
        let allAttempts: [WakeAttempt]
        do {
            allAttempts = try context.fetch(FetchDescriptor<WakeAttempt>())
        } catch {
            logger.error("purgeAll fetch failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        var rowsCleared = 0
        var filesDeleted = 0
        let attemptsDir = wakeAttemptsDirectory()

        for attempt in allAttempts {
            if attempt.imageData != nil {
                attempt.imageData = nil
                rowsCleared += 1
            }
            if let dir = attemptsDir, let path = attempt.videoPath, isSafeFilename(path) {
                let url = dir.appendingPathComponent(path)
                if (try? FileManager.default.removeItem(at: url)) != nil {
                    filesDeleted += 1
                }
                attempt.videoPath = nil
            }
        }
        do {
            try context.save()
            logger.info("Purged all wake recordings: rows=\(rowsCleared) files=\(filesDeleted)")
        } catch {
            logger.error("purgeAll save failed: \(error.localizedDescription, privacy: .public)")
            context.rollback()
        }
    }

    // MARK: - Internals

    private static func sweepOldImageData(context: ModelContext) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -imageDataRetentionDays, to: .now) ?? .now
        // Predicate scoped to rows that still have imageData AND are older than cutoff —
        // bounded fetch so we don't reload the whole table.
        let descriptor = FetchDescriptor<WakeAttempt>(
            predicate: #Predicate { attempt in
                attempt.imageData != nil &&
                ((attempt.capturedAt ?? attempt.scheduledAt) < cutoff)
            }
        )
        let rows: [WakeAttempt]
        do {
            rows = try context.fetch(descriptor)
        } catch {
            logger.error("imageData sweep fetch failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard !rows.isEmpty else { return }
        for attempt in rows {
            attempt.imageData = nil
        }
        do {
            try context.save()
            logger.info("Cleared imageData on \(rows.count) WakeAttempt rows older than \(imageDataRetentionDays) days")
        } catch {
            logger.error("imageData sweep save failed: \(error.localizedDescription, privacy: .public)")
            context.rollback()
        }
    }

    private static func sweepOldVideoFiles() {
        let fm = FileManager.default
        guard let attemptsDir = wakeAttemptsDirectory() else { return }
        guard fm.fileExists(atPath: attemptsDir.path) else { return }

        let cutoff = Calendar.current.date(byAdding: .day, value: -videoRetentionDays, to: .now) ?? .now
        let resourceKeys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        let enumerator = fm.enumerator(
            at: attemptsDir,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )

        var deletedCount = 0
        var bytesReclaimed: Int64 = 0
        while let next = enumerator?.nextObject() as? URL {
            guard let values = try? next.resourceValues(forKeys: resourceKeys),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified < cutoff else {
                continue
            }
            let size = (try? next.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if (try? fm.removeItem(at: next)) != nil {
                deletedCount += 1
                bytesReclaimed += Int64(size)
            }
        }
        if deletedCount > 0 {
            logger.info("Deleted \(deletedCount) wake-attempt videos older than \(videoRetentionDays) days; bytes=\(bytesReclaimed)")
        }
    }

    private static func sweepTmpCaptureLeftovers() {
        let fm = FileManager.default
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        // Wave 2.6: switched from `contentsOfDirectory(at:includingPropertiesForKeys:)`
        // (eager — materialises every entry + stats every file's mtime up front) to
        // a lazy `enumerator` that allows the prefix check to short-circuit BEFORE
        // we pay for `.contentModificationDateKey`. NSTemporaryDirectory is shared
        // with the OS — a fresh launch can land on a /tmp with hundreds of system
        // entries (URLSession download staging, snapshot caches). Filtering name
        // first cuts the stat-call cost to "the few files we actually own".
        let enumerator = fm.enumerator(
            at: tmpURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )
        let cutoff = Date().addingTimeInterval(-Double(tmpCaptureRetentionHours) * 3600.0)
        var deletedCount = 0
        while let next = enumerator?.nextObject() as? URL {
            let name = next.lastPathComponent
            // Match only our own tmp files — never touch other tenants of /tmp.
            guard name.hasPrefix("wakeproof-capture-") else { continue }
            guard let modified = (try? next.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate),
                  modified < cutoff else {
                continue
            }
            if (try? fm.removeItem(at: next)) != nil {
                deletedCount += 1
            }
        }
        if deletedCount > 0 {
            logger.info("Cleaned \(deletedCount) tmp capture leftover files older than \(tmpCaptureRetentionHours)h")
        }
    }

    /// Resolve `Documents/WakeAttempts/` — the durable directory videos and
    /// tmp-promoted captures land in. Returns `nil` if Documents is
    /// unreachable (sandbox edge case at app launch). Shared by both the
    /// retention sweep and the manual purge so directory-naming changes
    /// happen in one place.
    private static func wakeAttemptsDirectory() -> URL? {
        guard let docsURL = try? FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else {
            return nil
        }
        return docsURL.appendingPathComponent("WakeAttempts", isDirectory: true)
    }

    /// S-I6 (Wave 2.1): only accept `videoPath` values shaped as plain filenames.
    /// Rejects `/`, `..`, anything starting with `.`, anything with a path
    /// separator, anything that decodes any traversal-shaped form. Used to
    /// validate `WakeAttempt.videoPath` before resolving it against
    /// `Documents/WakeAttempts/`.
    static func isSafeFilename(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        if name.hasPrefix(".") { return false }
        if name.contains("/") || name.contains("\\") { return false }
        if name.contains("..") { return false }
        if name.contains("\0") { return false }
        // Length ceiling: filesystem path components are typically ≤255.
        if name.count > 255 { return false }
        return true
    }
}
