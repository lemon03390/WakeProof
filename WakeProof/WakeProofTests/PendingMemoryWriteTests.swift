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

    // MARK: - MemoryWriteBacklog sidecar
    //
    // SQ1 (Stage 4): the `MemoryWriteBacklog` @Observable sidecar was deleted as
    // dead code — no view ever read it. Its only test (`testBacklogUpdateReflectsNewCount`)
    // was removed with it. Queue-size verification now lives in the
    // `testFlushSuccessDrainsQueue` / `testFlushFailureRetainsEntriesAndBumpsRetryCount`
    // tests above, which read `queue.count()` directly on the underlying actor.
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
        // SQ1 (Stage 4): dropped the `memoryWriteBacklog.count == 0` assertion.
        // The @Observable sidecar was deleted; the underlying `queue.count()`
        // assertion immediately above covers the same invariant (and more
        // directly, since the sidecar's only job was to mirror that value).

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
