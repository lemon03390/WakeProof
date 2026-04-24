//
//  PendingWakeAttempt.swift
//  WakeProof
//
//  UserDefaults-backed retry queue for WakeAttempt audit rows whose SwiftData
//  save failed. Wave 2.4 B4 fix: the previous `try? context.save()` / catch +
//  rollback + log-only pattern meant VERIFIED/REJECTED/RETRY/UNRESOLVED rows
//  could silently vanish on disk-full or schema hiccups, and the scheduler had
//  already cleared `lastFireAt` — next-launch recovery could not rescue them.
//
//  These rows exist SPECIFICALLY to prevent silent data loss, so themselves
//  being lost silently is the banned pattern (CLAUDE.md promoted rule #2).
//
//  Design:
//  - UserDefaults-backed (not file I/O) so writes are fast + atomic.
//  - Capped at 32 entries; older drop with a WARN log.
//  - Retry count bumped per flush attempt; no per-retry cap (a persistently
//    failing row stays in the queue and keeps re-trying on each launch — the
//    cap bounds the memory footprint, not retries).
//

import Foundation
import os

/// One failed-persist row pending re-save. Codable into a JSON array stored in
/// UserDefaults. The struct is Sendable so the retry queue actor can vend
/// values across isolation boundaries.
struct PendingWakeAttempt: Codable, Equatable, Sendable {

    /// Raw string — matches `WakeAttempt.verdict` on disk. Stored as String so a
    /// future Verdict case addition doesn't break decoding of rows queued under
    /// an older build (same rationale as WakeAttempt.swift itself).
    let verdictRawValue: String
    let scheduledFor: Date
    let enqueuedAt: Date
    var retryCount: Int

    init(verdictRawValue: String, scheduledFor: Date, enqueuedAt: Date = .now, retryCount: Int = 0) {
        self.verdictRawValue = verdictRawValue
        self.scheduledFor = scheduledFor
        self.enqueuedAt = enqueuedAt
        self.retryCount = retryCount
    }
}

/// Actor owning the pending-WakeAttempt queue. Injectable `UserDefaults` lets
/// tests run against an in-memory suite without polluting the app domain.
///
/// `actor` (not @MainActor) because this is called from the MainActor
/// AlarmScheduler via `Task` hops — a concurrent flush triggered from bootstrap
/// must not contend with an enqueue from a simultaneous persist-failure. The
/// serial executor serialises both paths.
actor PendingWakeAttemptQueue {

    static let defaultsKey = "com.wakeproof.pending.attempts"
    static let maxQueueEntries = 32

    private let defaults: UserDefaults
    private let logger = Logger(subsystem: LogSubsystem.alarm, category: "pending-attempt-queue")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Append a row and persist. If the queue would exceed the cap, drop the
    /// OLDEST entry (FIFO) so the most recent failures have the best chance to
    /// survive + replay — a queue full of week-old entries with no room for
    /// tonight's failure is worse than losing the oldest.
    func enqueue(_ pending: PendingWakeAttempt) {
        var queue = loadQueue()
        queue.append(pending)
        if queue.count > Self.maxQueueEntries {
            let dropped = queue.count - Self.maxQueueEntries
            logger.warning("Pending-attempt queue cap reached (\(queue.count, privacy: .public) > \(Self.maxQueueEntries, privacy: .public)) — dropping \(dropped, privacy: .public) oldest")
            queue.removeFirst(dropped)
        }
        saveQueue(queue)
        logger.info("Enqueued pending WakeAttempt verdict=\(pending.verdictRawValue, privacy: .public) retryCount=\(pending.retryCount, privacy: .public) queueSize=\(queue.count, privacy: .public)")
    }

    /// Read all pending entries. Callers drive their own flush order; the queue
    /// is otherwise opaque.
    func snapshot() -> [PendingWakeAttempt] {
        loadQueue()
    }

    /// Replace the queue. Used by the flush path: after attempting re-save of
    /// each entry, the caller computes which survive and writes them back.
    func replace(with entries: [PendingWakeAttempt]) {
        saveQueue(entries)
        logger.info("Pending-attempt queue replaced — size=\(entries.count, privacy: .public)")
    }

    /// Count helper for UI / test assertions.
    func count() -> Int {
        loadQueue().count
    }

    // MARK: - Private

    private func loadQueue() -> [PendingWakeAttempt] {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return [] }
        do {
            return try SharedJSON.iso8601Decoder.decode([PendingWakeAttempt].self, from: data)
        } catch {
            // Decoding failure = queue format drift from an older build. Log +
            // wipe so we don't loop trying to decode the same bad bytes every
            // launch. The user-facing impact is an already-lost row staying lost;
            // we accept this rather than crash-looping.
            logger.error("Pending-attempt queue decode failed, wiping: \(error.localizedDescription, privacy: .public)")
            defaults.removeObject(forKey: Self.defaultsKey)
            return []
        }
    }

    private func saveQueue(_ queue: [PendingWakeAttempt]) {
        if queue.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
            return
        }
        do {
            let data = try SharedJSON.iso8601Encoder.encode(queue)
            defaults.set(data, forKey: Self.defaultsKey)
        } catch {
            // Encoding a small Codable struct array cannot fail in normal use —
            // this branch exists only so the .error surface is visible if some
            // future field makes the struct non-encodable. The queue is lost
            // for this invocation; next enqueue will overwrite cleanly.
            logger.error("Pending-attempt queue encode failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
