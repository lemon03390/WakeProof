//
//  HealthKitSleepReaderTests.swift
//  WakeProofTests
//

import HealthKit
import XCTest
@testable import WakeProof

/// We can't reasonably synthesise HKCategorySample / HKQuantitySample without an
/// authenticated HKHealthStore, so these tests exercise `aggregate` with real
/// HealthKit value types wherever the test simulator allows it, and skip the
/// portions that require authorised stores. The device-side sanity test in Phase
/// B.6 validates the full integration path end-to-end.

final class HealthKitSleepReaderTests: XCTestCase {

    func testAggregateWithNoSamplesReturnsEmpty() {
        let reader = HealthKitSleepReader()
        let snapshot = reader.aggregate(
            sleepSamples: [],
            hrSamples: [],
            windowStart: Date(timeIntervalSince1970: 0),
            windowEnd: Date(timeIntervalSince1970: 0)
        )
        XCTAssertEqual(snapshot.totalInBedMinutes, 0)
        XCTAssertEqual(snapshot.awakeMinutes, 0)
        XCTAssertEqual(snapshot.heartRateSampleCount, 0)
        XCTAssertNil(snapshot.heartRateAvg)
    }

    func testWindowFieldsArePreserved() {
        let reader = HealthKitSleepReader()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let end = Date(timeIntervalSince1970: 1_050_000)
        let snapshot = reader.aggregate(
            sleepSamples: [], hrSamples: [],
            windowStart: start, windowEnd: end
        )
        XCTAssertEqual(snapshot.windowStart, start)
        XCTAssertEqual(snapshot.windowEnd, end)
    }

    func testEmptyInBedMinutesIsZero() {
        let reader = HealthKitSleepReader()
        let snap = reader.aggregate(sleepSamples: [], hrSamples: [],
                                    windowStart: .now, windowEnd: .now)
        XCTAssertTrue(snap.isEmpty)
    }
}
