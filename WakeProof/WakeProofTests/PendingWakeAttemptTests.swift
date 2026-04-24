//
//  PendingWakeAttemptTests.swift
//  WakeProofTests
//
//  Wave 2.4 B4: round-trip, cap behaviour, and retry semantics for
//  PendingWakeAttemptQueue + PendingWakeAttempt.
//

import XCTest
@testable import WakeProof

final class PendingWakeAttemptTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        // Isolated UserDefaults suite per test — no state leaks into production defaults
        // and no order-dependencies across tests.
        suiteName = "com.wakeproof.tests.pending-attempt-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    // MARK: - Codable round-trip

    func testPendingWakeAttemptRoundTrip() throws {
        let original = PendingWakeAttempt(
            verdictRawValue: "VERIFIED",
            scheduledFor: Date(timeIntervalSince1970: 1714000000),
            enqueuedAt: Date(timeIntervalSince1970: 1714000100),
            retryCount: 3
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PendingWakeAttempt.self, from: data)
        XCTAssertEqual(decoded, original, "Codable round-trip must preserve every field")
    }

    // MARK: - Queue enqueue + snapshot

    func testEnqueueStoresAndRetrievesPendingAttempt() async {
        let queue = PendingWakeAttemptQueue(defaults: defaults)
        let pending = PendingWakeAttempt(verdictRawValue: "TIMEOUT", scheduledFor: .now)
        await queue.enqueue(pending)
        let snapshot = await queue.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot.first?.verdictRawValue, "TIMEOUT")
    }

    func testEnqueueAppendsInOrder() async {
        let queue = PendingWakeAttemptQueue(defaults: defaults)
        await queue.enqueue(PendingWakeAttempt(verdictRawValue: "UNRESOLVED", scheduledFor: .now))
        await queue.enqueue(PendingWakeAttempt(verdictRawValue: "TIMEOUT", scheduledFor: .now))
        await queue.enqueue(PendingWakeAttempt(verdictRawValue: "VERIFIED", scheduledFor: .now))
        let snapshot = await queue.snapshot()
        XCTAssertEqual(snapshot.map(\.verdictRawValue), ["UNRESOLVED", "TIMEOUT", "VERIFIED"])
    }

    // MARK: - Cap behaviour (hard invariant — test is load-bearing)

    func testEnqueueCapsAtMaxEntries() async {
        let queue = PendingWakeAttemptQueue(defaults: defaults)
        // Enqueue cap + 5 rows; oldest 5 should be dropped.
        let cap = PendingWakeAttemptQueue.maxQueueEntries
        for i in 0..<(cap + 5) {
            await queue.enqueue(PendingWakeAttempt(
                verdictRawValue: "V\(i)",
                scheduledFor: Date(timeIntervalSince1970: TimeInterval(i))
            ))
        }
        let snapshot = await queue.snapshot()
        XCTAssertEqual(snapshot.count, cap, "queue must cap at maxQueueEntries")
        XCTAssertEqual(snapshot.first?.verdictRawValue, "V5",
                       "FIFO drop — oldest 5 entries must be dropped so V5 becomes the new oldest")
        XCTAssertEqual(snapshot.last?.verdictRawValue, "V\(cap + 4)",
                       "newest entry must be preserved")
    }

    // MARK: - Replace (used by flush)

    func testReplaceOverwritesQueue() async {
        let queue = PendingWakeAttemptQueue(defaults: defaults)
        await queue.enqueue(PendingWakeAttempt(verdictRawValue: "ORIGINAL", scheduledFor: .now))
        let newEntries = [
            PendingWakeAttempt(verdictRawValue: "REPLACED", scheduledFor: .now, retryCount: 2)
        ]
        await queue.replace(with: newEntries)
        let snapshot = await queue.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot.first?.verdictRawValue, "REPLACED")
        XCTAssertEqual(snapshot.first?.retryCount, 2)
    }

    func testReplaceWithEmptyClearsStorage() async {
        let queue = PendingWakeAttemptQueue(defaults: defaults)
        await queue.enqueue(PendingWakeAttempt(verdictRawValue: "TO_CLEAR", scheduledFor: .now))
        await queue.replace(with: [])
        let snapshot = await queue.snapshot()
        XCTAssertTrue(snapshot.isEmpty, "replace with [] must remove UserDefaults key so counts reset")
        XCTAssertNil(defaults.data(forKey: PendingWakeAttemptQueue.defaultsKey),
                     "defaults key must be removed on empty replace to keep the blob small")
    }

    // MARK: - Persistence across actor instances (simulates app relaunch)

    func testQueueSurvivesActorRecreation() async {
        // First actor enqueues; second actor (same defaults) reads back — simulates a
        // relaunch where a previously-enqueued row must still be present after the
        // process ends and a fresh actor is constructed.
        let first = PendingWakeAttemptQueue(defaults: defaults)
        await first.enqueue(PendingWakeAttempt(verdictRawValue: "SURVIVE", scheduledFor: .now))

        let second = PendingWakeAttemptQueue(defaults: defaults)
        let snapshot = await second.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot.first?.verdictRawValue, "SURVIVE")
    }

    // MARK: - Corruption handling

    func testDecodeFailureWipesCorruptedQueue() async {
        defaults.set(Data([0x00, 0x01, 0x02, 0x03]), forKey: PendingWakeAttemptQueue.defaultsKey)
        let queue = PendingWakeAttemptQueue(defaults: defaults)
        let snapshot = await queue.snapshot()
        XCTAssertTrue(snapshot.isEmpty, "decoder failure must return empty queue")
        XCTAssertNil(defaults.data(forKey: PendingWakeAttemptQueue.defaultsKey),
                     "corrupted data must be wiped so we don't loop trying to decode the same bytes")
    }
}

// MARK: - AlarmScheduler integration

@MainActor
final class AlarmSchedulerPendingQueueTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var scheduler: AlarmScheduler!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "com.wakeproof.tests.scheduler-pending-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        UserDefaults.standard.removeObject(forKey: "com.wakeproof.alarm.lastFireAt")
        scheduler = AlarmScheduler()
        scheduler.pendingAttemptQueue = PendingWakeAttemptQueue(defaults: defaults)
    }

    override func tearDown() async throws {
        scheduler.cancel()
        UserDefaults.standard.removeObject(forKey: "com.wakeproof.alarm.lastFireAt")
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        scheduler = nil
        try await super.tearDown()
    }

    /// When persistAttempt throws, the scheduler must enqueue the verdict for retry
    /// rather than silently swallowing it — this is the core B4 fix invariant.
    func testPersistAttemptThrowEnqueuesPendingRow() async throws {
        struct TestError: Error {}
        scheduler.persistAttempt = { _, _ in throw TestError() }

        scheduler.fireNow()
        scheduler.handleRingCeiling()

        // Detached enqueue Task needs a moment to land.
        try await Task.sleep(nanoseconds: 200_000_000)
        let queue = scheduler.pendingAttemptQueue
        let snapshot = await queue.snapshot()
        XCTAssertEqual(snapshot.count, 1, "persistAttempt throw MUST enqueue to the retry queue")
        XCTAssertEqual(snapshot.first?.verdictRawValue, "TIMEOUT")
    }

    /// When persistAttempt is not wired, the scheduler must enqueue defensively so a
    /// wiring-time hot-patch plus a later flush can still land the audit row.
    func testPersistAttemptUnwiredEnqueuesDefensively() async throws {
        // No persistAttempt wired — exercise the `guard let persistAttempt else` branch.
        scheduler.fireNow()
        scheduler.handleRingCeiling()

        try await Task.sleep(nanoseconds: 200_000_000)
        let queue = scheduler.pendingAttemptQueue
        let snapshot = await queue.snapshot()
        XCTAssertEqual(snapshot.count, 1,
                       "unwired closure must still enqueue so a late wire + flush can recover the row")
    }

    /// flushPendingAttempts drains the queue through the currently-wired closure.
    /// Successful flushes remove the entry; failures retain with bumped retryCount.
    func testFlushPendingAttemptsDrainsQueueOnSuccess() async throws {
        // Pre-populate queue with one entry by forcing a persist failure.
        struct TestError: Error {}
        scheduler.persistAttempt = { _, _ in throw TestError() }
        scheduler.fireNow()
        scheduler.handleRingCeiling()
        try await Task.sleep(nanoseconds: 200_000_000)
        let preFlushCount = await scheduler.pendingAttemptQueue.count()
        XCTAssertEqual(preFlushCount, 1)

        // Swap in a succeeding closure and flush.
        var flushedVerdicts: [WakeAttempt.Verdict] = []
        scheduler.persistAttempt = { verdict, _ in
            flushedVerdicts.append(verdict)
        }
        await scheduler.flushPendingAttempts()

        XCTAssertEqual(flushedVerdicts, [.timeout])
        let postFlushCount = await scheduler.pendingAttemptQueue.count()
        XCTAssertEqual(postFlushCount, 0, "successful flush must drain the queue to zero")
    }

    func testFlushRetainsEntriesOnContinuedFailure() async throws {
        // Pre-populate one row.
        struct TestError: Error {}
        scheduler.persistAttempt = { _, _ in throw TestError() }
        scheduler.fireNow()
        scheduler.handleRingCeiling()
        try await Task.sleep(nanoseconds: 200_000_000)

        // Flush with a still-failing closure; retryCount on the single entry should bump.
        await scheduler.flushPendingAttempts()

        let snapshot = await scheduler.pendingAttemptQueue.snapshot()
        XCTAssertEqual(snapshot.count, 1, "failing flush must retain the entry")
        XCTAssertEqual(snapshot.first?.retryCount, 1,
                       "retryCount must increment on each failed flush attempt")
    }

    /// markAttemptPersistFailed is the external entry point for a caller that can't
    /// signal failure through the throwing closure. Exercises the same enqueue path.
    func testMarkAttemptPersistFailedEnqueuesDirectly() async throws {
        let scheduledFor = Date(timeIntervalSince1970: 1714000000)
        scheduler.markAttemptPersistFailed(verdict: .verified, scheduledFor: scheduledFor)
        try await Task.sleep(nanoseconds: 200_000_000)

        let snapshot = await scheduler.pendingAttemptQueue.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        let row = try XCTUnwrap(snapshot.first)
        XCTAssertEqual(row.verdictRawValue, "VERIFIED")
        XCTAssertEqual(row.scheduledFor.timeIntervalSince1970, 1714000000, accuracy: 1.0)
    }
}
