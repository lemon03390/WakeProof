//
//  PendingMemoryWrite.swift
//  WakeProof
//
//  Wave 2.4 R14 fix: UserDefaults-backed retry queue for MemoryStore writes
//  whose atomic `writeVerdictRow` call failed. VisionVerifier's fire-and-forget
//  Task previously caught + logged + silently continued — which is the banned
//  pattern (CLAUDE.md promoted rule #2): calibration data was quietly lost,
//  degrading Layer 2 memory fidelity over time without any signal to the user.
//
//  Design:
//  - Codable struct (MemoryEntry + optional profileDelta + enqueuedAt +
//    retryCount) serialized via JSON in UserDefaults.
//  - Capped at 16 entries (smaller than WakeAttempt queue because each row
//    here can carry ~120-byte note + full profile markdown; the cap keeps the
//    UserDefaults blob bounded).
//  - Per-row retry cap of 5. A row that can't flush after 5 attempts gets
//    dropped with an .error log — memory is ancillary, unlike audit rows.
//  - `@Observable` sidecar (MemoryWriteBacklog) exposes `count` for UI banners.
//

import Foundation
import Observation
import os

/// One failed memory write pending re-flush. Codable so it survives across
/// launches via UserDefaults.
struct PendingMemoryWrite: Codable, Equatable, Sendable {

    let entry: MemoryEntry
    let profileDelta: String?
    let enqueuedAt: Date
    var retryCount: Int

    init(entry: MemoryEntry, profileDelta: String?, enqueuedAt: Date = .now, retryCount: Int = 0) {
        self.entry = entry
        self.profileDelta = profileDelta
        self.enqueuedAt = enqueuedAt
        self.retryCount = retryCount
    }
}

/// @Observable sidecar. VisionVerifier owns an instance; AlarmSchedulerView
/// reads `.count` via a @MainActor-isolated hop off the queue actor and
/// publishes a banner when the backlog exceeds 5. Kept separate from the
/// queue actor itself because SwiftUI's observation machinery requires
/// MainActor-isolated @Observable classes; actors cannot conform.
@Observable
@MainActor
final class MemoryWriteBacklog {
    private(set) var count: Int = 0

    func update(_ newCount: Int) {
        count = newCount
    }
}

/// Actor owning the pending-memory-write queue. Same isolation rationale as
/// `PendingWakeAttemptQueue`: called from VisionVerifier (@MainActor) on
/// persist-failure and from the app bootstrap on launch-flush.
actor PendingMemoryWriteQueue {

    static let defaultsKey = "com.wakeproof.pending.memory"
    static let maxQueueEntries = 16
    static let maxRetryAttempts = 5

    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.wakeproof.memory", category: "pending-write-queue")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Append a row and persist. FIFO-drop oldest on cap overflow — see
    /// PendingWakeAttemptQueue.enqueue rationale; same tradeoff applies.
    func enqueue(_ pending: PendingMemoryWrite) {
        var queue = loadQueue()
        queue.append(pending)
        if queue.count > Self.maxQueueEntries {
            let dropped = queue.count - Self.maxQueueEntries
            logger.warning("Pending-memory queue cap reached (\(queue.count, privacy: .public) > \(Self.maxQueueEntries, privacy: .public)) — dropping \(dropped, privacy: .public) oldest")
            queue.removeFirst(dropped)
        }
        saveQueue(queue)
        logger.info("Enqueued pending memory write retryCount=\(pending.retryCount, privacy: .public) queueSize=\(queue.count, privacy: .public)")
    }

    /// Flush all entries through the supplied async closure. On success the
    /// entry is dropped; on failure its `retryCount` is bumped and if the cap
    /// (5) is exceeded it's dropped with an .error log. Queue is written back
    /// once at the end so a flush-time crash doesn't leave the queue half-
    /// consumed. Returns the post-flush queue size so callers can update any
    /// @Observable backlog count.
    ///
    /// The `writer` closure must be async-throws and MUST be idempotent with
    /// respect to the underlying MemoryStore — i.e. re-submitting the same
    /// entry on a later launch is acceptable because the store uses append-
    /// only history and latest-write-wins profile semantics.
    func flush(using writer: (MemoryEntry, String?) async throws -> Void) async -> Int {
        let original = loadQueue()
        guard !original.isEmpty else { return 0 }
        var survivors: [PendingMemoryWrite] = []
        for pending in original {
            do {
                try await writer(pending.entry, pending.profileDelta)
                logger.info("Flushed pending memory write (retryCount=\(pending.retryCount, privacy: .public))")
            } catch {
                var bumped = pending
                bumped.retryCount += 1
                if bumped.retryCount >= Self.maxRetryAttempts {
                    logger.error("Memory write retry exhausted after \(bumped.retryCount, privacy: .public) attempts — dropping: \(error.localizedDescription, privacy: .public)")
                    // drop — do NOT append to survivors
                } else {
                    logger.warning("Memory write flush attempt \(bumped.retryCount, privacy: .public) failed, keeping in queue: \(error.localizedDescription, privacy: .public)")
                    survivors.append(bumped)
                }
            }
        }
        saveQueue(survivors)
        return survivors.count
    }

    /// Count helper for backlog surfacing.
    func count() -> Int {
        loadQueue().count
    }

    /// Test helper — wipes the queue. Production callers should never need this.
    func reset() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    // MARK: - Private

    private func loadQueue() -> [PendingMemoryWrite] {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([PendingMemoryWrite].self, from: data)
        } catch {
            logger.error("Pending-memory queue decode failed, wiping: \(error.localizedDescription, privacy: .public)")
            defaults.removeObject(forKey: Self.defaultsKey)
            return []
        }
    }

    private func saveQueue(_ queue: [PendingMemoryWrite]) {
        if queue.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(queue)
            defaults.set(data, forKey: Self.defaultsKey)
        } catch {
            logger.error("Pending-memory queue encode failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
