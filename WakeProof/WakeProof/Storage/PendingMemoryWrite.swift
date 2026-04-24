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
//  P8 (Stage 6 Wave 1): added `enqueueSync(_:)` mirroring the
//  `PendingWakeAttemptQueue` sync path — see that file for the full rationale.
//  The memory-write enqueue in `VisionVerifier.handleResult` used to hop
//  `await queue.enqueue(pending)` from inside a `Task { ... }`, which risked
//  the same app-teardown drop: calibration data silently lost.
//
//  Design:
//  - Codable struct (MemoryEntry + optional profileDelta + enqueuedAt +
//    retryCount) serialized via JSON in UserDefaults.
//  - Capped at 16 entries (smaller than WakeAttempt queue because each row
//    here can carry ~120-byte note + full profile markdown; the cap keeps the
//    UserDefaults blob bounded).
//  - Per-row retry cap of 5. A row that can't flush after 5 attempts gets
//    dropped with an .error log — memory is ancillary, unlike audit rows.
//  - SQ1 (Stage 4): the `MemoryWriteBacklog` @Observable sidecar was removed
//    as dead code. It existed to drive an AlarmSchedulerView banner that was
//    never actually wired — updates happened but no view ever read `.count`.
//    Backlog visibility is still available via `queue.count()` on the actor
//    if a UI consumer ever needs it.
//

import Foundation
import os

/// One failed memory write pending re-flush. Codable so it survives across
/// launches via UserDefaults.
///
/// P20 (Stage 6 Wave 2): `retryCount` is `let` (previously `var`) so the
/// struct is fully immutable at the type level. The flush loop bumps the
/// count via `bumpingRetry()` which returns a new value — matching the
/// actor-safe copy-semantics the codebase prefers everywhere else. The
/// previous `var retryCount` worked only because no code held a reference
/// to the same instance across a mutation; making that an invariant of
/// the type rather than a local-discipline concern closes that window
/// before a future refactor can accidentally share a mutable copy.
struct PendingMemoryWrite: Codable, Equatable, Sendable {

    let entry: MemoryEntry
    let profileDelta: String?
    let enqueuedAt: Date
    let retryCount: Int

    init(entry: MemoryEntry, profileDelta: String?, enqueuedAt: Date = .now, retryCount: Int = 0) {
        self.entry = entry
        self.profileDelta = profileDelta
        self.enqueuedAt = enqueuedAt
        self.retryCount = retryCount
    }

    /// P20 (Stage 6 Wave 2): return a copy with `retryCount` bumped by 1.
    /// The flush loop uses this in place of the old `var bumped = pending;
    /// bumped.retryCount += 1` pattern so the struct can stay immutable.
    func bumpingRetry() -> Self {
        Self(
            entry: entry,
            profileDelta: profileDelta,
            enqueuedAt: enqueuedAt,
            retryCount: retryCount + 1
        )
    }
}

/// Actor owning the pending-memory-write queue. Same isolation rationale as
/// `PendingWakeAttemptQueue`: called from VisionVerifier (@MainActor) on
/// persist-failure and from the app bootstrap on launch-flush.
///
/// P8 (Stage 6 Wave 1): mutation paths (enqueue / enqueueSync / flush / replace)
/// run under a shared `OSAllocatedUnfairLock` so the nonisolated sync
/// `enqueueSync` serialises against the actor's async paths. See
/// `PendingWakeAttemptQueue` for the full rationale — the two queues share the
/// same concurrency model.
actor PendingMemoryWriteQueue {

    static let defaultsKey = "com.wakeproof.pending.memory"
    static let maxQueueEntries = 16
    static let maxRetryAttempts = 5

    /// P10 (Stage 6 Wave 2): UserDefaults key for the cumulative count of
    /// memory-write rows dropped after exhausting `maxRetryAttempts`. The
    /// value survives relaunches so AlarmSchedulerView's banner reflects
    /// every drop since install, not just the current session. Prior to P10
    /// the drop was logger-only — a row silently vanished with no user-
    /// visible signal, which is the exact scenario the promoted rule ("no
    /// silent catch") protects against.
    static let droppedCountKey = "com.wakeproof.pending.memory.droppedCount"

    /// P8 (Stage 6 Wave 1): `nonisolated(unsafe)` so the sync enqueue path can
    /// reach the UserDefaults instance without an actor hop. See
    /// `PendingWakeAttemptQueue.defaults` for the full rationale.
    private nonisolated(unsafe) let defaults: UserDefaults
    private nonisolated let logger = Logger(subsystem: LogSubsystem.memory, category: "pending-write-queue")
    /// P8 (Stage 6 Wave 1): see `PendingWakeAttemptQueue.sharedLock` comment.
    private nonisolated let sharedLock = OSAllocatedUnfairLock<Void>(uncheckedState: ())

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Append a row and persist. Async version — delegates to the shared sync
    /// helper for lock-serialised ordering against `enqueueSync`.
    ///
    /// FIFO-drop oldest on cap overflow — see `PendingWakeAttemptQueue.enqueue`
    /// rationale; same tradeoff applies.
    func enqueue(_ pending: PendingMemoryWrite) {
        enqueueLocked(pending)
    }

    /// P8 (Stage 6 Wave 1): synchronous enqueue that lands the row before the
    /// call returns. Use from MainActor callers where the `Task { await ... }`
    /// alternative races app teardown. See `PendingWakeAttemptQueue.enqueueSync`
    /// for the full rationale.
    nonisolated func enqueueSync(_ pending: PendingMemoryWrite) {
        enqueueLocked(pending)
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
    ///
    /// P8: NOT wrapped in `sharedLock` around the await — the lock cannot be
    /// held across an `await` (it's a sync lock). Instead we load under the
    /// lock, release, run the writer, re-acquire briefly to persist survivors.
    /// Concurrent enqueues during the `await writer(...)` window land cleanly
    /// and are NOT over-written by the save-back step — see the merge logic
    /// inside the lock block.
    func flush(using writer: (MemoryEntry, String?) async throws -> Void) async -> Int {
        let original = sharedLock.withLock { _ in loadQueueUnsafe() }
        guard !original.isEmpty else { return 0 }
        var survivors: [PendingMemoryWrite] = []
        var droppedThisPass = 0
        for pending in original {
            do {
                try await writer(pending.entry, pending.profileDelta)
                logger.info("Flushed pending memory write (retryCount=\(pending.retryCount, privacy: .public))")
            } catch {
                let bumped = pending.bumpingRetry()
                if bumped.retryCount >= Self.maxRetryAttempts {
                    logger.error("Memory write retry exhausted after \(bumped.retryCount, privacy: .public) attempts — dropping: \(error.localizedDescription, privacy: .public)")
                    // P10 (Stage 6 Wave 2): bump the UserDefaults-backed
                    // counter so the AlarmSchedulerView banner can surface
                    // "N writes dropped" to the user. Before P10 this drop
                    // was logger.error only — silent from the user's side,
                    // which is the banned pattern the promoted rule targets.
                    droppedThisPass += 1
                    // drop — do NOT append to survivors
                } else {
                    logger.warning("Memory write flush attempt \(bumped.retryCount, privacy: .public) failed, keeping in queue: \(error.localizedDescription, privacy: .public)")
                    survivors.append(bumped)
                }
            }
        }
        if droppedThisPass > 0 {
            Self.incrementDroppedCount(by: droppedThisPass, on: defaults)
        }
        // P8: merge any rows that landed during the await window. Without this,
        // a concurrent enqueue during flush would be clobbered by the save-back.
        // Read the current queue, subtract the pre-flush set, append the survivors.
        //
        // Snapshot `survivors` into a `let` before capturing so the closure
        // holds an immutable copy — Swift 6 strict concurrency rejects
        // capturing a mutable `var` by reference into the `withLock` closure
        // (which is `Sendable`-constrained).
        let finalSurvivors = survivors
        sharedLock.withLock { _ in
            let currentQueue = loadQueueUnsafe()
            let preFlushIDs = Set(original.map { row in
                // Composite key — (entry.timestamp, retryCount) uniquely identifies
                // a pre-flush row. `entry` is a struct so direct equality is fine
                // for set membership, but we'd need `Hashable` conformance on
                // MemoryEntry — the timestamp + retryCount pair is enough for
                // identification without changing the type's conformances.
                "\(row.entry.timestamp.timeIntervalSince1970)_\(row.retryCount)"
            })
            let concurrentlyAdded = currentQueue.filter { row in
                !preFlushIDs.contains("\(row.entry.timestamp.timeIntervalSince1970)_\(row.retryCount)")
            }
            saveQueueUnsafe(finalSurvivors + concurrentlyAdded)
        }
        return finalSurvivors.count
    }

    /// Count helper for backlog surfacing.
    func count() -> Int {
        sharedLock.withLock { _ in loadQueueUnsafe().count }
    }

    /// Test helper — wipes the queue. Production callers should never need this.
    func reset() {
        sharedLock.withLock { _ in
            defaults.removeObject(forKey: Self.defaultsKey)
            // P10 (Stage 6 Wave 2): also clear the dropped-count so tests
            // start from a known-zero state. Production callers should use
            // the static `resetDroppedCount(on:)` if they ever need this
            // (e.g. a DEBUG "clear memory retry state" button).
            defaults.removeObject(forKey: Self.droppedCountKey)
        }
    }

    /// P10 (Stage 6 Wave 2): total rows dropped across all flushes since
    /// install. Reads from the default UserDefaults; see
    /// `droppedCount(on:)` for the injected-suite variant tests can use.
    /// Nonisolated + static so AlarmSchedulerView can read it without
    /// hopping into the actor — the backing key is UserDefaults, which is
    /// documented thread-safe for primitive reads.
    nonisolated static func droppedCount() -> Int {
        droppedCount(on: .standard)
    }

    /// Test-suite variant of `droppedCount()` that reads from an injected
    /// UserDefaults. Same thread-safety guarantee as the default-suite form.
    nonisolated static func droppedCount(on defaults: UserDefaults) -> Int {
        defaults.integer(forKey: droppedCountKey)
    }

    /// P10 (Stage 6 Wave 2): test helper — wipe the dropped counter so tests
    /// that assert on bumps start from zero. Production callers should never
    /// need this.
    nonisolated static func resetDroppedCount(on defaults: UserDefaults) {
        defaults.removeObject(forKey: droppedCountKey)
    }

    /// Increment the persisted dropped-count under the shared UserDefaults
    /// suite. Called from inside the flush loop when a row exhausts its
    /// retry budget. Cheap — a single read + write under the default
    /// isolation lock UserDefaults already provides.
    fileprivate static func incrementDroppedCount(by delta: Int, on defaults: UserDefaults) {
        let current = defaults.integer(forKey: droppedCountKey)
        defaults.set(current + delta, forKey: droppedCountKey)
    }

    // MARK: - Private

    /// Shared enqueue implementation used by both `enqueue` and `enqueueSync`.
    /// Runs under `sharedLock` so load-modify-save is atomic.
    private nonisolated func enqueueLocked(_ pending: PendingMemoryWrite) {
        let newCount = sharedLock.withLock { _ -> Int in
            var queue = loadQueueUnsafe()
            queue.append(pending)
            if queue.count > Self.maxQueueEntries {
                let dropped = queue.count - Self.maxQueueEntries
                logger.warning("Pending-memory queue cap reached (\(queue.count, privacy: .public) > \(Self.maxQueueEntries, privacy: .public)) — dropping \(dropped, privacy: .public) oldest")
                queue.removeFirst(dropped)
            }
            saveQueueUnsafe(queue)
            return queue.count
        }
        logger.info("Enqueued pending memory write retryCount=\(pending.retryCount, privacy: .public) queueSize=\(newCount, privacy: .public)")
    }

    /// Caller MUST hold `sharedLock`. Suffix `Unsafe` flags the invariant at
    /// the call site so a future refactor can't silently drop the lock.
    private nonisolated func loadQueueUnsafe() -> [PendingMemoryWrite] {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return [] }
        do {
            return try SharedJSON.decodeISO8601([PendingMemoryWrite].self, from: data)
        } catch {
            logger.error("Pending-memory queue decode failed, wiping: \(error.localizedDescription, privacy: .public)")
            defaults.removeObject(forKey: Self.defaultsKey)
            return []
        }
    }

    /// Caller MUST hold `sharedLock`.
    private nonisolated func saveQueueUnsafe(_ queue: [PendingMemoryWrite]) {
        if queue.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
            return
        }
        do {
            let data = try SharedJSON.encodeISO8601(queue)
            defaults.set(data, forKey: Self.defaultsKey)
        } catch {
            logger.error("Pending-memory queue encode failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
