//
//  MemoryPromptBuilderTests.swift
//  WakeProofTests
//

import XCTest
@testable import WakeProof

final class MemoryPromptBuilderTests: XCTestCase {

    func testEmptySnapshotReturnsNil() {
        XCTAssertNil(MemoryPromptBuilder.render(.empty))
    }

    func testProfileOnlyRendersProfileBlock() {
        let snap = MemorySnapshot(profile: "User wakes groggy Mondays.", recentHistory: [], totalHistoryCount: 3)
        let out = MemoryPromptBuilder.render(snap)
        XCTAssertNotNil(out)
        XCTAssertTrue(out!.contains("<memory_context total_history=\"3\">"))
        XCTAssertTrue(out!.contains("<profile>"))
        XCTAssertTrue(out!.contains("User wakes groggy Mondays."))
        XCTAssertFalse(out!.contains("<recent_history>"))
    }

    func testHistoryOnlyRendersTable() {
        let entry = MemoryEntry(
            timestamp: Date(timeIntervalSince1970: 1_745_466_662),
            verdict: "VERIFIED", confidence: 0.82, retryCount: 0, note: "clear"
        )
        let snap = MemorySnapshot(profile: nil, recentHistory: [entry], totalHistoryCount: 1)
        let out = MemoryPromptBuilder.render(snap)
        XCTAssertNotNil(out)
        XCTAssertTrue(out!.contains("<recent_history>"))
        XCTAssertTrue(out!.contains("| when | verdict |"))
        XCTAssertTrue(out!.contains("VERIFIED"))
        XCTAssertTrue(out!.contains("0.82"))
        XCTAssertFalse(out!.contains("<profile>"))
    }

    func testBothRendersProfileFirst() {
        let entry = MemoryEntry(
            timestamp: Date(timeIntervalSince1970: 1_745_466_662),
            verdict: "VERIFIED", confidence: 0.82, retryCount: 0, note: nil
        )
        let snap = MemorySnapshot(profile: "PROFILE_MARKER", recentHistory: [entry], totalHistoryCount: 1)
        let out = MemoryPromptBuilder.render(snap)!
        let profileIndex = out.range(of: "PROFILE_MARKER")!
        let historyIndex = out.range(of: "<recent_history>")!
        XCTAssertLessThan(profileIndex.lowerBound, historyIndex.lowerBound)
    }

    func testOversizedInputTruncatesHistoryPreservesProfile() {
        let profile = "Profile body observations that should survive truncation."
        let entries: [MemoryEntry] = (0..<50).map { i in
            MemoryEntry(
                timestamp: Date(timeIntervalSince1970: 1_745_466_662 + TimeInterval(i)),
                verdict: "VERIFIED", confidence: 0.8,
                retryCount: 0, note: String(repeating: "padding-", count: 10)
            )
        }
        let snap = MemorySnapshot(profile: profile, recentHistory: entries, totalHistoryCount: 1000)
        let out = MemoryPromptBuilder.render(snap)!
        XCTAssertLessThanOrEqual(out.count, MemoryPromptBuilder.maxLength)
        XCTAssertTrue(out.contains(profile), "profile must survive truncation")
    }

    func testNotePipeIsEscaped() {
        let entry = MemoryEntry(
            timestamp: Date(timeIntervalSince1970: 1_745_466_662),
            verdict: "VERIFIED", confidence: 0.82, retryCount: 0,
            note: "something with | inside"
        )
        let snap = MemorySnapshot(profile: nil, recentHistory: [entry], totalHistoryCount: 1)
        let out = MemoryPromptBuilder.render(snap)!
        // pipe inside a note must not break the table — we replace with '/'.
        XCTAssertFalse(out.contains("with | inside"))
        XCTAssertTrue(out.contains("with / inside"))
    }

    func testNoteNewlineIsFlattened() {
        let entry = MemoryEntry(
            timestamp: Date(timeIntervalSince1970: 1_745_466_662),
            verdict: "VERIFIED", confidence: 0.82, retryCount: 0,
            note: "first line\nsecond line"
        )
        let snap = MemorySnapshot(profile: nil, recentHistory: [entry], totalHistoryCount: 1)
        let out = MemoryPromptBuilder.render(snap)!
        XCTAssertTrue(out.contains("first line second line"))
    }

    func testMissingConfidenceRendersDash() {
        let entry = MemoryEntry(
            timestamp: Date(timeIntervalSince1970: 1_745_466_662),
            verdict: "CAPTURED", confidence: nil, retryCount: 0, note: nil
        )
        let snap = MemorySnapshot(profile: nil, recentHistory: [entry], totalHistoryCount: 1)
        let out = MemoryPromptBuilder.render(snap)!
        XCTAssertTrue(out.contains(" — "))
    }
}
