//
//  MemorySnapshotTests.swift
//  WakeProofTests
//

import XCTest
@testable import WakeProof

final class MemorySnapshotTests: XCTestCase {

    func testEmptyHasNoContent() {
        XCTAssertTrue(MemorySnapshot.empty.isEmpty)
        XCTAssertEqual(MemorySnapshot.empty.recentHistory.count, 0)
        XCTAssertNil(MemorySnapshot.empty.profile)
        XCTAssertEqual(MemorySnapshot.empty.totalHistoryCount, 0)
    }

    func testProfileOnlyIsNotEmpty() {
        let snap = MemorySnapshot(profile: "Observations across 3 mornings…", recentHistory: [], totalHistoryCount: 0)
        XCTAssertFalse(snap.isEmpty)
    }

    func testHistoryOnlyIsNotEmpty() {
        let entry = MemoryEntry(timestamp: .now, verdict: "VERIFIED", confidence: 0.8, retryCount: 0, note: nil)
        let snap = MemorySnapshot(profile: nil, recentHistory: [entry], totalHistoryCount: 1)
        XCTAssertFalse(snap.isEmpty)
    }

    func testTotalCountIndependentOfRecent() {
        let entries = (0..<5).map { i in
            MemoryEntry(timestamp: .now, verdict: "VERIFIED", confidence: 0.8, retryCount: 0, note: "entry \(i)")
        }
        let snap = MemorySnapshot(profile: nil, recentHistory: entries, totalHistoryCount: 1000)
        XCTAssertEqual(snap.recentHistory.count, 5)
        XCTAssertEqual(snap.totalHistoryCount, 1000)
    }
}
