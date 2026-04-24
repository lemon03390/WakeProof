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
//  P8 (Stage 6 Wave 1): added `enqueueSync(_:)` — a nonisolated synchronous
//  path that lands the row on disk before the caller returns. The prior
//  `Task.detached { await queue.enqueue(pending) }` pattern in
//  `AlarmScheduler.enqueuePendingAttempt` was a fire-and-forget hop; if the
//  app was terminated (iOS kill, force-quit, scene discard) BETWEEN the
//  `detach` and the actor receiving the message, the enqueue never landed
//  and the row was lost — defeating the whole B4 design. The sync path uses
//  an `OSAllocatedUnfairLock` to serialise the load-modify-save pattern
//  against the actor's async path (which now also acquires the lock from a
//  private nonisolated helper). Both entry points share the same underlying
//  state machine, so concurrent callers are safe regardless of which API
//  they use.
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
///
/// P20 (Stage 6 Wave 2): `retryCount` is `let` (previously `var`). See
/// `PendingMemoryWrite` for the rationale — the old `var retryCount +=` site
/// in `AlarmScheduler.flushPendingAttempts` now uses `bumpingRetry()` which
/// returns a new instance. Keeps the type fully immutable and prevents an
/// accidentally-shared mutable copy across actor boundaries.
struct PendingWakeAttempt: Codable, Equatable, Sendable {

    /// Raw string — matches `WakeAttempt.verdict` on disk. Stored as String so a
    /// future Verdict case addition doesn't break decoding of rows queued under
    /// an older build (same rationale as WakeAttempt.swift itself).
    let verdictRawValue: String
    let scheduledFor: Date
    let enqueuedAt: Date
    let retryCount: Int

    init(verdictRawValue: String, scheduledFor: Date, enqueuedAt: Date = .now, retryCount: Int = 0) {
        self.verdictRawValue = verdictRawValue
        self.scheduledFor = scheduledFor
        self.enqueuedAt = enqueuedAt
        self.retryCount = retryCount
    }

    /// P20 (Stage 6 Wave 2): return a copy with `retryCount` bumped by 1.
    /// The AlarmScheduler flush loop uses this in place of the old
    /// `var bumped = row; bumped.retryCount += 1` pattern.
    func bumpingRetry() -> Self {
        Self(
            verdictRawValue: verdictRawValue,
            scheduledFor: scheduledFor,
            enqueuedAt: enqueuedAt,
            retryCount: retryCount + 1
        )
    }
}

/// Actor owning the pending-WakeAttempt queue. Injectable `UserDefaults` lets
/// tests run against an in-memory suite without polluting the app domain.
///
/// `actor` (not @MainActor) because this is called from the MainActor
/// AlarmScheduler via `Task` hops — a concurrent flush triggered from bootstrap
/// must not contend with an enqueue from a simultaneous persist-failure. The
/// serial executor serialises both paths.
///
/// P8 (Stage 6 Wave 1): the underlying mutation state is guarded by an
/// `OSAllocatedUnfairLock` (see `sharedLock`) so the nonisolated `enqueueSync`
/// path and the actor's async paths serialise against each other. Without this
/// shared lock, the two entry points would use *different* mutexes (the lock
/// vs. the actor's executor) and could interleave reads + writes.
actor PendingWakeAttemptQueue {

    static let defaultsKey = "com.wakeproof.pending.attempts"
    static let maxQueueEntries = 32

    /// P8 (Stage 6 Wave 1): `nonisolated(unsafe)` so the sync enqueue path can
    /// reach the UserDefaults instance without an actor hop. `UserDefaults`
    /// is documented thread-safe (Apple's Foundation docs explicitly promise
    /// concurrent-read + concurrent-write safety for primitives and Data),
    /// but Swift 6 doesn't treat it as `Sendable`. The `unsafe` qualifier is
    /// the language-level escape hatch that says "I've verified the concurrency
    /// contract myself" — here the sharedLock below serialises every operation
    /// that touches defaults in this queue.
    private nonisolated(unsafe) let defaults: UserDefaults
    private nonisolated let logger = Logger(subsystem: LogSubsystem.alarm, category: "pending-attempt-queue")
    /// P8 (Stage 6 Wave 1): shared lock across the sync + async paths.
    /// `OSAllocatedUnfairLock<Void>` with a zero-sized state cell — we only
    /// need the lock's mutual-exclusion semantics; there is no protected
    /// scalar state. `nonisolated` so the sync entry points can reach it
    /// without crossing the actor boundary.
    ///
    /// Why `OSAllocatedUnfairLock` and not a Swift actor: the sync path must
    /// land the row before returning (no async suspension tolerance — the app
    /// may be torn down microseconds after we return). An actor-hop would lose
    /// that window. This lock gives us synchronous mutual exclusion against
    /// all concurrent paths, and the lock is `Sendable` so it captures cleanly
    /// into a nonisolated method.
    private nonisolated let sharedLock = OSAllocatedUnfairLock<Void>(uncheckedState: ())

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Append a row and persist. Async version — callable from any async
    /// context. Delegates to the shared sync helper to preserve lock-serialised
    /// ordering against `enqueueSync`.
    ///
    /// If the queue would exceed the cap, drop the OLDEST entry (FIFO) so the
    /// most recent failures have the best chance to survive + replay — a queue
    /// full of week-old entries with no room for tonight's failure is worse
    /// than losing the oldest.
    func enqueue(_ pending: PendingWakeAttempt) {
        enqueueLocked(pending)
    }

    /// P8 (Stage 6 Wave 1): synchronous enqueue that lands the row before the
    /// call returns. Use from MainActor callers where the alternative
    /// (`Task.detached { await queue.enqueue(...) }`) races app-teardown and
    /// can drop the row silently. Nonisolated + uses the shared lock so it
    /// serialises with the actor's async paths.
    ///
    /// Test invariant: `testEnqueueSyncLandsBeforeFunctionReturns()` asserts
    /// the row is on disk immediately after this call returns.
    nonisolated func enqueueSync(_ pending: PendingWakeAttempt) {
        enqueueLocked(pending)
    }

    /// Read all pending entries. Callers drive their own flush order; the queue
    /// is otherwise opaque.
    func snapshot() -> [PendingWakeAttempt] {
        sharedLock.withLock { _ in loadQueueUnsafe() }
    }

    /// Replace the queue. Used by the flush path: after attempting re-save of
    /// each entry, the caller computes which survive and writes them back.
    func replace(with entries: [PendingWakeAttempt]) {
        sharedLock.withLock { _ in saveQueueUnsafe(entries) }
        logger.info("Pending-attempt queue replaced — size=\(entries.count, privacy: .public)")
    }

    /// Count helper for UI / test assertions.
    func count() -> Int {
        sharedLock.withLock { _ in loadQueueUnsafe().count }
    }

    // MARK: - Private

    /// Shared enqueue implementation used by both `enqueue` and `enqueueSync`.
    /// Runs under `sharedLock` so the load-modify-save sequence is atomic
    /// against concurrent callers of either public entry point.
    /// `nonisolated` so `enqueueSync` (also nonisolated) can call it directly
    /// without hopping to the actor executor — that hop would re-introduce the
    /// exact async-schedule window P8 is trying to close.
    private nonisolated func enqueueLocked(_ pending: PendingWakeAttempt) {
        let newCount = sharedLock.withLock { _ -> Int in
            var queue = loadQueueUnsafe()
            queue.append(pending)
            if queue.count > Self.maxQueueEntries {
                let dropped = queue.count - Self.maxQueueEntries
                logger.warning("Pending-attempt queue cap reached (\(queue.count, privacy: .public) > \(Self.maxQueueEntries, privacy: .public)) — dropping \(dropped, privacy: .public) oldest")
                queue.removeFirst(dropped)
            }
            saveQueueUnsafe(queue)
            return queue.count
        }
        logger.info("Enqueued pending WakeAttempt verdict=\(pending.verdictRawValue, privacy: .public) retryCount=\(pending.retryCount, privacy: .public) queueSize=\(newCount, privacy: .public)")
    }

    /// Caller MUST hold `sharedLock`. Suffix `Unsafe` flags the invariant at
    /// the call site so a future refactor can't silently drop the lock.
    private nonisolated func loadQueueUnsafe() -> [PendingWakeAttempt] {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return [] }
        do {
            return try SharedJSON.decodeISO8601([PendingWakeAttempt].self, from: data)
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

    /// Caller MUST hold `sharedLock`.
    private nonisolated func saveQueueUnsafe(_ queue: [PendingWakeAttempt]) {
        if queue.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
            return
        }
        do {
            let data = try SharedJSON.encodeISO8601(queue)
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
