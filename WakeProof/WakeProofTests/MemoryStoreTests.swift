//
//  MemoryStoreTests.swift
//  WakeProofTests
//

import XCTest
@testable import WakeProof

final class MemoryStoreTests: XCTestCase {

    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wakeproof-memory-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let root, FileManager.default.fileExists(atPath: root.path) {
            try? FileManager.default.removeItem(at: root)
        }
        try await super.tearDown()
    }

    private func makeStore(uuid: String = UUID().uuidString, historyLimit: Int = 5, profileCap: Int = 16 * 1024) -> MemoryStore {
        MemoryStore(configuration: .init(
            rootDirectory: root,
            userUUID: uuid,
            historyReadLimit: historyLimit,
            profileMaxBytes: profileCap
        ))
    }

    // MARK: - Empty paths

    func testReadOnFreshInstallReturnsEmpty() async throws {
        let store = makeStore()
        let snapshot = try await store.read()
        XCTAssertEqual(snapshot, .empty)
    }

    func testBootstrapIsIdempotent() async throws {
        let store = makeStore()
        try await store.bootstrapIfNeeded()
        try await store.bootstrapIfNeeded()
        // Hoist the `await` out of the XCTAssertTrue autoclosure — autoclosures
        // aren't `async`-aware, so `await` must resolve to a local value first.
        let uuid = await store.configurationUUIDForTests
        let exists = FileManager.default.fileExists(atPath: root.appendingPathComponent(uuid).path)
        XCTAssertTrue(exists)
    }

    // MARK: - Profile round-trips

    func testWriteProfileThenReadReturnsSameString() async throws {
        let store = makeStore()
        try await store.rewriteProfile("## Observations\nUser wakes groggy on Mondays.")
        let snapshot = try await store.read()
        XCTAssertEqual(snapshot.profile?.contains("groggy on Mondays"), true)
    }

    func testProfileRewriteReplacesNotAppends() async throws {
        let store = makeStore()
        try await store.rewriteProfile("first")
        try await store.rewriteProfile("second")
        let snap = try await store.read()
        XCTAssertEqual(snap.profile, "second")
    }

    func testOversizedProfileIsTruncatedPreservingNewlines() async throws {
        let store = makeStore(profileCap: 64)
        let oversized = String(repeating: "line\n", count: 200)  // 1000 bytes
        try await store.rewriteProfile(oversized)
        let snap = try await store.read()
        XCTAssertNotNil(snap.profile)
        XCTAssertLessThanOrEqual(snap.profile!.utf8.count, 64)
        XCTAssertTrue(snap.profile!.hasSuffix("\n"), "truncation should end on a newline when possible")
    }

    // MARK: - History append + read limits

    func testAppendHistoryThenReadReturnsEntry() async throws {
        let store = makeStore()
        let entry = MemoryEntry(
            timestamp: Date(timeIntervalSince1970: 1_745_466_662),
            verdict: "VERIFIED", confidence: 0.9, retryCount: 0, note: "clear"
        )
        try await store.appendHistory(entry)
        let snap = try await store.read()
        XCTAssertEqual(snap.recentHistory.count, 1)
        XCTAssertEqual(snap.recentHistory.first, entry)
        XCTAssertEqual(snap.totalHistoryCount, 1)
    }

    func testHistoryReadLimitTruncatesToMostRecent() async throws {
        let store = makeStore(historyLimit: 3)
        for i in 0..<10 {
            let entry = MemoryEntry(
                timestamp: Date(timeIntervalSince1970: 1_745_466_662 + TimeInterval(i)),
                verdict: "VERIFIED", confidence: Double(i) / 10.0,
                retryCount: 0, note: "entry-\(i)"
            )
            try await store.appendHistory(entry)
        }
        let snap = try await store.read()
        XCTAssertEqual(snap.recentHistory.count, 3)
        XCTAssertEqual(snap.totalHistoryCount, 10)
        XCTAssertEqual(snap.recentHistory.first?.note, "entry-7")
        XCTAssertEqual(snap.recentHistory.last?.note, "entry-9")
    }

    // MARK: - Concurrency

    func testConcurrentAppendsProduceDistinctEntriesNoCorruption() async throws {
        let store = makeStore(historyLimit: 100)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask {
                    let entry = MemoryEntry(
                        timestamp: Date(timeIntervalSince1970: 1_745_466_662 + TimeInterval(i)),
                        verdict: "VERIFIED", confidence: 0.8,
                        retryCount: 0, note: "concurrent-\(i)"
                    )
                    try? await store.appendHistory(entry)
                }
            }
        }
        let snap = try await store.read()
        XCTAssertEqual(snap.totalHistoryCount, 20)
        let notes = snap.recentHistory.compactMap(\.note)
        XCTAssertEqual(Set(notes).count, notes.count, "no duplicate notes — means all 20 lines survived")
    }

    // MARK: - Security

    func testInvalidUserUUIDIsRejected() async {
        let store = makeStore(uuid: "../../etc/passwd")
        do {
            _ = try await store.read()
            XCTFail("read() must throw for invalid UUID")
        } catch MemoryStoreError.invalidUserUUID {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testEmptyUUIDIsRejected() async {
        let store = makeStore(uuid: "")
        do {
            try await store.rewriteProfile("x")
            XCTFail("rewriteProfile must throw for invalid UUID")
        } catch MemoryStoreError.invalidUserUUID {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - File-protection attribute present

    func testHistoryFileIsExcludedFromBackup() async throws {
        let uuid = UUID().uuidString
        let store = makeStore(uuid: uuid)
        try await store.appendHistory(
            MemoryEntry(timestamp: .now, verdict: "VERIFIED", confidence: nil, retryCount: 0, note: nil)
        )
        let file = root.appendingPathComponent(uuid).appendingPathComponent("history.jsonl")
        let values = try file.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testProfileFileIsExcludedFromBackup() async throws {
        let uuid = UUID().uuidString
        let store = makeStore(uuid: uuid)
        try await store.rewriteProfile("hello")
        let file = root.appendingPathComponent(uuid).appendingPathComponent("profile.md")
        let values = try file.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }
}

// Test-only peek so the bootstrap-idempotent test can verify the directory landed.
// Scoped private to this test file — actor reads are async even for configuration,
// so we isolate the shim here to keep production MemoryStore clean.
extension MemoryStore {
    var configurationUUIDForTests: String {
        get async { configuration.userUUID }
    }
}
