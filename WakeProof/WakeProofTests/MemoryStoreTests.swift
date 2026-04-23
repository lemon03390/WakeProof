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

    /// S4: a single buggy or malicious Claude response that returns an empty
    /// profile_delta must NEVER wipe the user's entire profile. rewriteProfile
    /// guards against empty + whitespace-only strings; write should no-op and
    /// leave the existing profile intact.
    func testRewriteProfileEmptyStringDoesNotWipeExistingProfile() async throws {
        let store = makeStore()
        try await store.rewriteProfile("## Original profile\nUser wakes groggy on Mondays.")
        // Sanity: the write landed.
        let before = try await store.read()
        XCTAssertEqual(before.profile?.contains("groggy"), true)
        // Empty string should be ignored, not overwrite.
        try await store.rewriteProfile("")
        let afterEmpty = try await store.read()
        XCTAssertEqual(afterEmpty.profile, before.profile,
                       "empty-string rewrite must preserve the existing profile")
        // Whitespace-only should also be ignored.
        try await store.rewriteProfile("   \n\t  ")
        let afterWhitespace = try await store.read()
        XCTAssertEqual(afterWhitespace.profile, before.profile,
                       "whitespace-only rewrite must preserve the existing profile")
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

    // MARK: - R3: UTF-8-safe truncation

    /// R3 fix: when the profile is oversized AND contains no newline to fall back on,
    /// byte-truncation alone can slice a multi-byte UTF-8 codepoint in half and leave
    /// an invalid trailing byte. `String(contentsOf:encoding:.utf8)` then returns nil
    /// on the next read, which silently evicts the profile (loadProfile returns nil
    /// via `try?`). The fix walks back over UTF-8 continuation bytes (10xxxxxx) until
    /// the last byte is a leading byte or ASCII.
    ///
    /// Input: `"a" * 19 + "¢"` = 19 ASCII bytes + 2 UTF-8 bytes (0xC2 0xA2) = 21 bytes.
    /// With profileCap=20, byte-truncation would slice to byte 20 (the 0xA2 continuation),
    /// leaving invalid UTF-8. With the fix, we walk back to byte 19 (drop the whole ¢).
    func testOversizedProfileWithoutNewlineTruncatesAtCodepointBoundary() async throws {
        let store = makeStore(profileCap: 20)
        let input = String(repeating: "a", count: 19) + "¢"  // 21 bytes, no newline
        try await store.rewriteProfile(input)
        let snap = try await store.read()
        XCTAssertNotNil(snap.profile, "truncated profile must still decode as valid UTF-8")
        // The ¢ must be dropped entirely; 19 a's remain.
        XCTAssertEqual(snap.profile, String(repeating: "a", count: 19))
        // Defensive check that the byte count is valid UTF-8 boundary.
        let bytes = Data(snap.profile!.utf8)
        XCTAssertEqual(bytes.count, 19)
    }

    // MARK: - R5: first-create protection class

    /// R5 fix: memory files are created with `.complete` file protection from the
    /// first write — no brief weaker-default window between atomic-write landing
    /// and a subsequent `setAttributes` upgrade.
    ///
    /// The iPhone 17 simulator (iOS 26.4) does not surface a protectionKey on
    /// APFS-backed sim storage — `FileManager.attributesOfItem` returns an
    /// attributes dict without the key. On device the key IS present and equals
    /// `.complete` (validated in B.4 device-test-protocol Test 14). Assert that
    /// IF the attribute is visible we get the right value; otherwise the test
    /// records the simulator gap via `XCTSkip` so the suite stays green without
    /// hiding a production regression — if production code ever regresses to
    /// "no attribute set at all," this test will still fail on device.
    func testHistoryFileHasCompleteProtection() async throws {
        let uuid = UUID().uuidString
        let store = makeStore(uuid: uuid)
        try await store.appendHistory(
            MemoryEntry(timestamp: .now, verdict: "VERIFIED", confidence: nil, retryCount: 0, note: nil)
        )
        let file = root.appendingPathComponent(uuid).appendingPathComponent("history.jsonl")
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        guard let protection = attrs[.protectionKey] as? FileProtectionType else {
            throw XCTSkip("Simulator does not surface .protectionKey on APFS — validated on device via B.4 Test 14")
        }
        XCTAssertEqual(protection, .complete,
                       "history.jsonl must be .complete-protected from first-create (R5 fix)")
    }

    func testProfileFileHasCompleteProtection() async throws {
        let uuid = UUID().uuidString
        let store = makeStore(uuid: uuid)
        try await store.rewriteProfile("hello")
        let file = root.appendingPathComponent(uuid).appendingPathComponent("profile.md")
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        guard let protection = attrs[.protectionKey] as? FileProtectionType else {
            throw XCTSkip("Simulator does not surface .protectionKey on APFS — validated on device via B.4 Test 14")
        }
        XCTAssertEqual(protection, .complete,
                       "profile.md must be .complete-protected from first-create (R5 fix)")
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
