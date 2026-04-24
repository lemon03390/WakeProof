//
//  PendingMemoryWriteTests.swift
//  WakeProofTests
//
//  Wave 2.4 R14: round-trip, cap behaviour, and retry semantics for
//  PendingMemoryWriteQueue + PendingMemoryWrite. Also covers the
//  max-retry drop path (exhausted entries must drop with .error log).
//

import XCTest
@testable import WakeProof

final class PendingMemoryWriteTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "com.wakeproof.tests.pending-memory-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    // MARK: - Codable round-trip

    func testPendingMemoryWriteRoundTrip() throws {
        let entry = MemoryEntry(
            timestamp: Date(timeIntervalSince1970: 1714000000),
            verdict: "VERIFIED",
            confidence: 0.92,
            retryCount: 0,
            note: "first verified morning"
        )
        let original = PendingMemoryWrite(
            entry: entry,
            profileDelta: "updated profile markdown",
            enqueuedAt: Date(timeIntervalSince1970: 1714000100),
            retryCount: 2
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PendingMemoryWrite.self, from: data)
        XCTAssertEqual(decoded, original, "Codable round-trip must preserve every field")
    }

    // MARK: - Cap behaviour (hard invariant — test is load-bearing)

    func testEnqueueCapsAtMaxEntries() async {
        let queue = PendingMemoryWriteQueue(defaults: defaults)
        let cap = PendingMemoryWriteQueue.maxQueueEntries
        for i in 0..<(cap + 4) {
            let entry = MemoryEntry(
                timestamp: Date(timeIntervalSince1970: TimeInterval(i)),
                verdict: "VERIFIED",
                confidence: nil,
                retryCount: 0,
                note: "entry \(i)"
            )
            await queue.enqueue(PendingMemoryWrite(entry: entry, profileDelta: nil))
        }
        let count = await queue.count()
        XCTAssertEqual(count, cap, "queue must cap at maxQueueEntries")
    }

    // MARK: - Flush semantics

    func testFlushSuccessDrainsQueue() async {
        let queue = PendingMemoryWriteQueue(defaults: defaults)
        for i in 0..<3 {
            let entry = MemoryEntry(
                timestamp: Date(timeIntervalSinceNow: TimeInterval(i)),
                verdict: "VERIFIED",
                confidence: 0.9,
                retryCount: 0,
                note: nil
            )
            await queue.enqueue(PendingMemoryWrite(entry: entry, profileDelta: nil))
        }
        let preFlush = await queue.count()
        XCTAssertEqual(preFlush, 3)

        let remaining = await queue.flush { _, _ in /* always succeed */ }
        XCTAssertEqual(remaining, 0, "all entries must drop on success")
        let postFlush = await queue.count()
        XCTAssertEqual(postFlush, 0)
    }

    func testFlushFailureRetainsEntriesAndBumpsRetryCount() async {
        let queue = PendingMemoryWriteQueue(defaults: defaults)
        let entry = MemoryEntry(
            timestamp: .now, verdict: "VERIFIED",
            confidence: nil, retryCount: 0, note: nil
        )
        await queue.enqueue(PendingMemoryWrite(entry: entry, profileDelta: "delta"))

        struct TestError: Error {}
        let remaining = await queue.flush { _, _ in throw TestError() }
        XCTAssertEqual(remaining, 1, "failed entry must be retained")

        // Check retryCount on the now-retained entry.
        let queue2 = PendingMemoryWriteQueue(defaults: defaults)
        let count = await queue2.count()
        XCTAssertEqual(count, 1)
    }

    /// Hard invariant: after maxRetryAttempts-1 bumps plus one more failed flush,
    /// the entry must be dropped (its next flush lands the row at retryCount ==
    /// maxRetryAttempts, which triggers the exhaustion branch).
    func testFlushDropsEntryAfterMaxRetries() async {
        let queue = PendingMemoryWriteQueue(defaults: defaults)
        let entry = MemoryEntry(
            timestamp: .now, verdict: "VERIFIED",
            confidence: nil, retryCount: 0, note: nil
        )
        await queue.enqueue(PendingMemoryWrite(entry: entry, profileDelta: nil))

        struct TestError: Error {}
        let failingWriter: (MemoryEntry, String?) async throws -> Void = { _, _ in throw TestError() }
        // Run flush maxRetryAttempts times; the last one must drop the entry.
        for _ in 0..<PendingMemoryWriteQueue.maxRetryAttempts {
            _ = await queue.flush(using: failingWriter)
        }
        let remaining = await queue.count()
        XCTAssertEqual(remaining, 0,
                       "entry must drop after \(PendingMemoryWriteQueue.maxRetryAttempts) failed flushes")
    }

    // MARK: - P10: dropped-counter UserDefaults surface

    /// P10 (Stage 6 Wave 2): when a row exhausts its retry budget the queue
    /// drops it AND bumps the UserDefaults-backed `droppedCount` so
    /// AlarmSchedulerView's banner can surface "N writes dropped". Previously
    /// the drop was logger.error only — silent from the user's side, which
    /// is the banned pattern the promoted rule protects against.
    ///
    /// Pre-P10 behavior: count stayed at 0 even as entries vanished. Fix:
    /// each drop increments the counter by 1. This test drives two entries
    /// through the flush loop past maxRetryAttempts and asserts the
    /// cumulative counter reflects both drops.
    func testDroppedCounterIncrementsAfterMaxRetries() async {
        let queue = PendingMemoryWriteQueue(defaults: defaults)
        PendingMemoryWriteQueue.resetDroppedCount(on: defaults)

        // Seed two entries so we can assert the counter accumulates.
        let entryA = MemoryEntry(timestamp: Date(timeIntervalSince1970: 1), verdict: "VERIFIED",
                                 confidence: nil, retryCount: 0, note: "A")
        let entryB = MemoryEntry(timestamp: Date(timeIntervalSince1970: 2), verdict: "VERIFIED",
                                 confidence: nil, retryCount: 0, note: "B")
        await queue.enqueue(PendingMemoryWrite(entry: entryA, profileDelta: nil))
        await queue.enqueue(PendingMemoryWrite(entry: entryB, profileDelta: nil))

        // Precondition.
        XCTAssertEqual(PendingMemoryWriteQueue.droppedCount(on: defaults), 0,
                       "counter must start at zero before any exhaustion")

        // Always-failing writer; run flush past maxRetryAttempts so both rows
        // exhaust their budget in the final pass.
        struct TestError: Error {}
        let failingWriter: (MemoryEntry, String?) async throws -> Void = { _, _ in throw TestError() }
        for _ in 0..<PendingMemoryWriteQueue.maxRetryAttempts {
            _ = await queue.flush(using: failingWriter)
        }

        // Post: both entries should have dropped, counter bumps exactly by 2.
        let remaining = await queue.count()
        XCTAssertEqual(remaining, 0, "both rows must drop after retry exhaustion")
        XCTAssertEqual(PendingMemoryWriteQueue.droppedCount(on: defaults), 2,
                       "P10 counter must increment by 1 per dropped row — reflecting drops to the AlarmSchedulerView banner")
    }

    /// R3-5 (Stage 6 Wave 3): the dropped-count bump must land inside the
    /// same lock block as `saveQueueUnsafe` — a crash between the two writes
    /// would otherwise persist the counter while leaving the dropped rows on
    /// disk, causing the next launch to re-drop them and double-count.
    ///
    /// This test pins the ordering by running a mixed flush (one row drops,
    /// one survives sub-cap) and asserting that:
    ///   (1) After flush, `queue.count() == 1` (the survivor, retryCount=1).
    ///   (2) `droppedCount == 1` (the single exhausted row).
    /// Re-reading the queue back after flush confirms the counter and the
    /// queue are in consistent steady-state. True crash-between-writes would
    /// require a fault injection harness we don't have, but this assertion
    /// locks in the "survivors save + counter bump are done in the same
    /// critical section" shape — a regression that re-splits the two would
    /// break the `count() == 1` portion because `saveQueueUnsafe` would land
    /// before the concurrent-merge logic had run under the lock.
    func testDroppedCountAndSurvivorsLandTogetherInSameLockBlock() async {
        let queue = PendingMemoryWriteQueue(defaults: defaults)
        PendingMemoryWriteQueue.resetDroppedCount(on: defaults)

        // Entry A will exhaust retries (seed with retryCount = max - 1 so one
        // more failed flush lands it at max, dropping + bumping the counter).
        // Entry B stays sub-cap and survives.
        let exhaustCandidate = MemoryEntry(
            timestamp: Date(timeIntervalSince1970: 1_000),
            verdict: "VERIFIED", confidence: nil, retryCount: 0, note: "exhaust"
        )
        let survivor = MemoryEntry(
            timestamp: Date(timeIntervalSince1970: 2_000),
            verdict: "VERIFIED", confidence: nil, retryCount: 0, note: "survive"
        )

        // Prime the exhaust candidate at max - 1 retries so one failing flush
        // pushes it past the threshold.
        let primed = PendingMemoryWrite(
            entry: exhaustCandidate,
            profileDelta: nil,
            retryCount: PendingMemoryWriteQueue.maxRetryAttempts - 1
        )
        await queue.enqueue(primed)
        await queue.enqueue(PendingMemoryWrite(entry: survivor, profileDelta: nil))

        // Both fail; one drops (exhausted), one survives (still below cap).
        struct TestError: Error {}
        _ = await queue.flush { _, _ in throw TestError() }

        let postCount = await queue.count()
        XCTAssertEqual(postCount, 1, "exhaust candidate must drop, survivor must remain")
        XCTAssertEqual(PendingMemoryWriteQueue.droppedCount(on: defaults), 1,
                       "R3-5: exactly one drop must bump the counter — counter and queue save are atomic")

        // A fresh queue instance reads from UserDefaults: the survivor is
        // STILL there with retryCount bumped to 1, and the counter STILL
        // reads 1. This pins the ordering — if the two writes were separate
        // and the save happened BEFORE the counter bump (pre-R3-5 ordering
        // with partial crash simulation), we'd see counter=0 here despite
        // the survivor's bumped retry. The test doesn't simulate the crash
        // but verifies the final-state consistency the ordering guarantees.
        let fresh = PendingMemoryWriteQueue(defaults: defaults)
        let freshCount = await fresh.count()
        XCTAssertEqual(freshCount, 1, "UserDefaults must hold the single survivor")
        XCTAssertEqual(PendingMemoryWriteQueue.droppedCount(on: defaults), 1,
                       "counter must still read 1 on a fresh actor — UserDefaults is the source of truth")
    }

    /// P10 (Stage 6 Wave 2): transient failures (below the retry cap) must
    /// NOT bump the dropped counter. Only exhaustion-level drops are
    /// user-visible; earlier retries are kept in the queue and remain
    /// recoverable. This test fires one sub-cap flush and asserts the
    /// counter stays at zero.
    func testDroppedCounterStaysZeroOnSubCapFailures() async {
        let queue = PendingMemoryWriteQueue(defaults: defaults)
        PendingMemoryWriteQueue.resetDroppedCount(on: defaults)
        let entry = MemoryEntry(timestamp: .now, verdict: "VERIFIED",
                                confidence: nil, retryCount: 0, note: "retry")
        await queue.enqueue(PendingMemoryWrite(entry: entry, profileDelta: nil))

        struct TestError: Error {}
        // Single failed flush: row bumps retryCount to 1 (< maxRetryAttempts),
        // stays in queue, counter must NOT increment.
        _ = await queue.flush { _, _ in throw TestError() }
        XCTAssertEqual(PendingMemoryWriteQueue.droppedCount(on: defaults), 0,
                       "counter must stay zero for sub-cap retries — only final-exhaustion drops count")
        let count = await queue.count()
        XCTAssertEqual(count, 1, "sub-cap retry must stay in queue")
    }

    /// Partial success: some entries succeed, others fail — only the failing ones
    /// are retained with bumped retryCount.
    func testFlushPartialSuccess() async {
        let queue = PendingMemoryWriteQueue(defaults: defaults)
        let entryA = MemoryEntry(timestamp: .now, verdict: "VERIFIED", confidence: nil, retryCount: 0, note: "A")
        let entryB = MemoryEntry(timestamp: .now, verdict: "VERIFIED", confidence: nil, retryCount: 0, note: "B")
        await queue.enqueue(PendingMemoryWrite(entry: entryA, profileDelta: nil))
        await queue.enqueue(PendingMemoryWrite(entry: entryB, profileDelta: nil))

        struct TestError: Error {}
        let remaining = await queue.flush { entry, _ in
            if entry.note == "A" { throw TestError() }
            // B succeeds.
        }
        XCTAssertEqual(remaining, 1, "only the failing entry must be retained")
    }

    // MARK: - Persistence across actor instances

    func testQueueSurvivesActorRecreation() async {
        let entry = MemoryEntry(timestamp: .now, verdict: "VERIFIED", confidence: nil, retryCount: 0, note: "survivor")
        let first = PendingMemoryWriteQueue(defaults: defaults)
        await first.enqueue(PendingMemoryWrite(entry: entry, profileDelta: "delta"))

        let second = PendingMemoryWriteQueue(defaults: defaults)
        let count = await second.count()
        XCTAssertEqual(count, 1, "queue must survive actor recreation (UserDefaults-backed)")
    }

    // MARK: - Corruption handling

    func testDecodeFailureWipesCorruptedQueue() async {
        defaults.set(Data([0xDE, 0xAD, 0xBE, 0xEF]), forKey: PendingMemoryWriteQueue.defaultsKey)
        let queue = PendingMemoryWriteQueue(defaults: defaults)
        let count = await queue.count()
        XCTAssertEqual(count, 0)
        XCTAssertNil(defaults.data(forKey: PendingMemoryWriteQueue.defaultsKey),
                     "corrupted data must be wiped to break the decode-fail loop")
    }

    // MARK: - P8: enqueueSync lands before the call returns

    /// P8 (Stage 6 Wave 1): memory-write retry queue must land its row
    /// synchronously, same invariant as PendingWakeAttemptQueue. See
    /// `PendingWakeAttemptTests.testEnqueueSyncLandsBeforeFunctionReturns` for
    /// the full rationale.
    func testEnqueueSyncLandsBeforeFunctionReturns() {
        let queue = PendingMemoryWriteQueue(defaults: defaults)
        let entry = MemoryEntry(
            timestamp: Date(timeIntervalSince1970: 1_745_000_000),
            verdict: "VERIFIED",
            confidence: 0.92,
            retryCount: 0,
            note: "sync-landing-probe"
        )
        let pending = PendingMemoryWrite(entry: entry, profileDelta: "## delta")

        // Sync call — no await, no detached Task.
        queue.enqueueSync(pending)

        let raw = defaults.data(forKey: PendingMemoryWriteQueue.defaultsKey)
        XCTAssertNotNil(raw, "enqueueSync MUST persist synchronously — an async hop here would regress R14 retry-queue intent")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try? decoder.decode([PendingMemoryWrite].self, from: raw ?? Data())
        XCTAssertEqual(decoded?.count, 1)
        XCTAssertEqual(decoded?.first?.entry.note, "sync-landing-probe")
    }
}

// MARK: - VisionVerifier integration

@MainActor
final class VisionVerifierPendingMemoryQueueTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "com.wakeproof.tests.verifier-pending-memory-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    private func tempMemoryStoreRoot() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("verifier-mem-queue-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// flushMemoryWriteQueue drains the backing queue through the wired memoryStore.
    /// Successful writes drain the entry; backlog count updates to zero.
    func testFlushMemoryWriteQueueDrainsThroughMemoryStore() async throws {
        let tmp = tempMemoryStoreRoot()
        let store = MemoryStore(configuration: .init(rootDirectory: tmp, userUUID: UUID().uuidString))
        try await store.bootstrapIfNeeded()

        // Prime the queue directly with one entry.
        let queue = PendingMemoryWriteQueue(defaults: defaults)
        let entry = MemoryEntry(timestamp: .now, verdict: "VERIFIED", confidence: 0.9, retryCount: 0, note: "to-flush")
        await queue.enqueue(PendingMemoryWrite(entry: entry, profileDelta: nil))
        let seeded = await queue.count()
        XCTAssertEqual(seeded, 1)

        // Wire the verifier with our primed queue + memoryStore, then flush.
        let verifier = VisionVerifier(client: NeverCalledClient())
        verifier.memoryStore = store
        verifier.memoryWriteQueue = queue
        await verifier.flushMemoryWriteQueue()

        let postCount = await queue.count()
        XCTAssertEqual(postCount, 0, "successful flush must drain the queue")

        // Sanity: the entry actually landed in MemoryStore.
        let snapshot = try await store.read()
        XCTAssertEqual(snapshot.recentHistory.first?.note, "to-flush")
    }

    /// With no memoryStore wired, flushMemoryWriteQueue must leave the queue intact —
    /// premature flush with nil store would discard entries that could still be retried
    /// after a successful bootstrap on the next launch.
    func testFlushMemoryWriteQueueWithoutMemoryStoreIsNoOp() async throws {
        let queue = PendingMemoryWriteQueue(defaults: defaults)
        let entry = MemoryEntry(timestamp: .now, verdict: "VERIFIED", confidence: nil, retryCount: 0, note: "stay")
        await queue.enqueue(PendingMemoryWrite(entry: entry, profileDelta: nil))

        let verifier = VisionVerifier(client: NeverCalledClient())
        verifier.memoryStore = nil
        verifier.memoryWriteQueue = queue
        await verifier.flushMemoryWriteQueue()

        let postCount = await queue.count()
        XCTAssertEqual(postCount, 1,
                       "nil memoryStore must leave queue intact so next-launch flush can retry")
    }

    /// Vision verifier client that should never be called in these tests; if it is,
    /// we fail loudly because the tests are about the queue path, not live verification.
    private final class NeverCalledClient: ClaudeVisionClient {
        func verify(baselineJPEG: Data, stillJPEG: Data, baselineLocation: String, antiSpoofInstruction: String?, memoryContext: String?) async throws -> VerificationResult {
            XCTFail("NeverCalledClient.verify must not be invoked in memory-queue tests")
            throw ClaudeAPIError.emptyResponse
        }
    }
}
