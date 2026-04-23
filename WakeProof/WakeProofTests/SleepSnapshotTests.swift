//
//  SleepSnapshotTests.swift
//  WakeProofTests
//

import XCTest
@testable import WakeProof

final class SleepSnapshotTests: XCTestCase {

    func testEmptyIsEmpty() {
        XCTAssertTrue(SleepSnapshot.empty.isEmpty)
    }

    func testPopulatedIsNotEmpty() {
        let snapshot = SleepSnapshot(
            totalInBedMinutes: 420,
            awakeMinutes: 30,
            heartRateAvg: 58, heartRateMin: 48, heartRateMax: 75,
            heartRateSampleCount: 128, hasAppleWatchData: true,
            windowStart: Date(timeIntervalSince1970: 1_745_400_000),
            windowEnd: Date(timeIntervalSince1970: 1_745_425_200)
        )
        XCTAssertFalse(snapshot.isEmpty)
    }

    func testRoundTrip() throws {
        let original = SleepSnapshot(
            totalInBedMinutes: 420, awakeMinutes: 30,
            heartRateAvg: 58.2, heartRateMin: 48, heartRateMax: 75,
            heartRateSampleCount: 128, hasAppleWatchData: true,
            windowStart: Date(timeIntervalSince1970: 1_745_400_000),
            windowEnd: Date(timeIntervalSince1970: 1_745_425_200)
        )
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(original)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let roundtripped = try dec.decode(SleepSnapshot.self, from: data)
        XCTAssertEqual(original, roundtripped)
    }

    func testOptionalHeartRateNilsSurvive() throws {
        let snapshot = SleepSnapshot(
            totalInBedMinutes: 60, awakeMinutes: 10,
            heartRateAvg: nil, heartRateMin: nil, heartRateMax: nil,
            heartRateSampleCount: 0, hasAppleWatchData: false,
            windowStart: Date(timeIntervalSince1970: 0),
            windowEnd: Date(timeIntervalSince1970: 0)
        )
        let enc = JSONEncoder()
        let data = try enc.encode(snapshot)
        let dec = JSONDecoder()
        let roundtripped = try dec.decode(SleepSnapshot.self, from: data)
        XCTAssertEqual(snapshot, roundtripped)
    }
}
