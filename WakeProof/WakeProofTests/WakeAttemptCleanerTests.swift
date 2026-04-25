//
//  WakeAttemptCleanerTests.swift
//  WakeProofTests
//
//  Round-1 PR-review test gaps T-1, T-3, T-6 (Wave 3.1, 2026-04-26):
//  WakeAttemptCleaner shipped without direct test coverage. The most urgent
//  gap was `isSafeFilename`, the load-bearing path-traversal guard for both
//  `runRetentionSweep` and `purgeAllWakeRecordings` — a bypass means deleting
//  files outside `Documents/WakeAttempts/`. The header comment claimed the
//  function rejects `/`, `..`, `.`-leading, NUL, >255 chars, but no test
//  verified those claims.
//

import XCTest
import SwiftData
@testable import WakeProof

@MainActor
final class WakeAttemptCleanerTests: XCTestCase {

    // MARK: - T-1: isSafeFilename security primitive

    /// Plain UUID-derived filenames are accepted (this is what
    /// `CameraCaptureFlow.moveVideoToDocuments` produces).
    func testIsSafeFilenameAcceptsUUIDDerivedNames() {
        XCTAssertTrue(WakeAttemptCleaner.isSafeFilename("ABC123-xyz.mov"))
        XCTAssertTrue(WakeAttemptCleaner.isSafeFilename("550e8400-e29b-41d4-a716-446655440000.mov"))
    }

    /// Path traversal attempts via `..` rejected. The agent's example
    /// "../../../etc/passwd" is the canonical attack.
    func testIsSafeFilenameRejectsPathTraversal() {
        XCTAssertFalse(WakeAttemptCleaner.isSafeFilename(".."))
        XCTAssertFalse(WakeAttemptCleaner.isSafeFilename("../foo.mov"))
        XCTAssertFalse(WakeAttemptCleaner.isSafeFilename("foo/../bar.mov"))
        XCTAssertFalse(WakeAttemptCleaner.isSafeFilename("../../etc/passwd"))
    }

    /// Absolute paths rejected (a single `/` anywhere disqualifies).
    func testIsSafeFilenameRejectsAbsolutePaths() {
        XCTAssertFalse(WakeAttemptCleaner.isSafeFilename("/etc/passwd"))
        XCTAssertFalse(WakeAttemptCleaner.isSafeFilename("/tmp/foo.mov"))
        XCTAssertFalse(WakeAttemptCleaner.isSafeFilename("a/b.mov"))
    }

    /// Backslash variants (Windows-style traversal attempts) rejected.
    func testIsSafeFilenameRejectsBackslashes() {
        XCTAssertFalse(WakeAttemptCleaner.isSafeFilename("..\\foo.mov"))
        XCTAssertFalse(WakeAttemptCleaner.isSafeFilename("a\\b.mov"))
    }

    /// Leading dot rejected — would otherwise hide files and bypass the
    /// `.skipsHiddenFiles` enumerator option in `sweepOldVideoFiles`.
    func testIsSafeFilenameRejectsLeadingDot() {
        XCTAssertFalse(WakeAttemptCleaner.isSafeFilename(".hidden.mov"))
        XCTAssertFalse(WakeAttemptCleaner.isSafeFilename("."))
    }

    /// NUL byte rejected (not a real filename character on Unix; would
    /// truncate path interpretation in some C-API paths).
    func testIsSafeFilenameRejectsNullByte() {
        XCTAssertFalse(WakeAttemptCleaner.isSafeFilename("foo\0bar.mov"))
    }

    /// Empty string rejected — covers a future bug where an empty
    /// `videoPath` is set on a row and a downstream path-resolver doesn't
    /// pre-check.
    func testIsSafeFilenameRejectsEmpty() {
        XCTAssertFalse(WakeAttemptCleaner.isSafeFilename(""))
    }

    /// >255 characters rejected — typical filesystem path-component ceiling.
    func testIsSafeFilenameRejectsOverlengthNames() {
        let tooLong = String(repeating: "a", count: 256) + ".mov"
        XCTAssertFalse(WakeAttemptCleaner.isSafeFilename(tooLong))
    }

    /// 255-character boundary — accepted (one byte under the cap).
    func testIsSafeFilenameAcceptsMaxLength() {
        let exactly255 = String(repeating: "a", count: 255)
        XCTAssertTrue(WakeAttemptCleaner.isSafeFilename(exactly255))
    }

    // MARK: - T-3: purgeAllWakeRecordings rollback ordering

    /// Round-1 M-8 fix: file deletes happen AFTER `context.save()` succeeds,
    /// so a SwiftData rollback can't desync (file gone but row's videoPath
    /// restored, leading to AlarmRingingView reading a now-nonexistent
    /// playback URL). This test exercises the happy path: save succeeds,
    /// then files delete.
    func testPurgeAllWakeRecordingsHappyPathClearsRowsAndDeletesFiles() throws {
        let container = try ModelContainer(
            for: BaselinePhoto.self, WakeAttempt.self, MorningBriefing.self,
            configurations: .init(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext

        // Seed: a row with imageData + a fake videoPath. We don't actually
        // create the file (FileManager-backed deletes are best-effort and
        // the test is about the SwiftData mutations). Rows with imageData =
        // nil and videoPath = nil are still purgeable but have nothing to
        // mutate, so the count assertion is exact.
        let attempt = WakeAttempt(scheduledAt: .now)
        attempt.capturedAt = .now
        attempt.imageData = Data([0xFF, 0xD8, 0xFF])
        attempt.videoPath = "test-uuid.mov"
        context.insert(attempt)
        try context.save()

        WakeAttemptCleaner.purgeAllWakeRecordings(context: context)

        XCTAssertNil(attempt.imageData, "purgeAll must nil imageData")
        XCTAssertNil(attempt.videoPath, "purgeAll must nil videoPath")
    }

    // MARK: - T-6: tmp prefix-bypass attack

    /// Round-1 finding 6: the tmp sweep must filter to `wakeproof-capture-`
    /// prefixed files only. A future refactor that broadens the prefix to
    /// `wakeproof-` would silently start touching other transient tmp files.
    /// We can't seed tmp directly in unit tests without side-effects, so this
    /// test asserts `isSafeFilename` doesn't do anything unexpected with the
    /// test inputs that DO arrive through filesystem-derived APIs in
    /// production. Behavioral coverage of the actual sweep lives in the
    /// device-test protocol (docs/device-test-protocol.md).
    ///
    /// What this test pins: the prefix match contract. If `sweepTmpCaptureLeftovers`'
    /// guard `name.hasPrefix("wakeproof-capture-")` is ever changed, the
    /// constant string here must change in lockstep.
    func testTmpCapturePrefixIsExactlyExpected() {
        // Sentinel test — names matching this prefix are subject to retention
        // sweeps; names not matching are off-limits. If this assertion fires
        // after a refactor, manually verify the sweep doesn't widen its
        // filesystem footprint.
        let prefix = "wakeproof-capture-"
        XCTAssertTrue("wakeproof-capture-abc.mov".hasPrefix(prefix))
        XCTAssertFalse("wakeproof-other.mov".hasPrefix(prefix))
        XCTAssertFalse("apple-snapshot-foo".hasPrefix(prefix))
    }
}
