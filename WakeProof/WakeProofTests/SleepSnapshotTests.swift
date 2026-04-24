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

    // MARK: - M6 queryErrors

    /// M6 (Wave 2.6): queryErrors must be observable as a separate signal from
    /// "data was actually empty". Before this change, a HealthKit HR-query
    /// failure reset `hrSamples = []` and the prompt emitted "no HR samples"
    /// as if the user had no wearable data — overnight agent would reason
    /// from that as a true zero. Now: the field carries a label for each
    /// failed sub-query and the prompt renders it separately.
    func testQueryErrorsSurfaceSeparatelyFromEmptyArrays() {
        // Both HR and sleep queries failed: HR array is empty but the cause
        // is a query error, not a data-absent user.
        let snapshot = SleepSnapshot(
            totalInBedMinutes: 0,
            awakeMinutes: 0,
            heartRateAvg: nil, heartRateMin: nil, heartRateMax: nil,
            heartRateSampleCount: 0,
            hasAppleWatchData: false,
            windowStart: Date(timeIntervalSince1970: 1_745_400_000),
            windowEnd: Date(timeIntervalSince1970: 1_745_443_200),
            queryErrors: ["sleep", "heartRate"]
        )
        // Data-empty shape (no samples at all) still flags isEmpty=true — the
        // emptiness is real as far as data presence goes.
        XCTAssertTrue(snapshot.isEmpty, "no samples + zero bed minutes → isEmpty")
        // But queryErrors also surfaces as an independent signal so the
        // downstream prompt can distinguish "user has no data" from "queries
        // threw". Checking both in the same assertion pins the contract.
        XCTAssertEqual(snapshot.queryErrors, ["sleep", "heartRate"],
                       "queryErrors must survive round-trip through the struct so the prompt can reflect partial-failure")
    }

    /// M6: backwards-compat — older persisted JSON (before queryErrors existed)
    /// must decode to an empty-array default. The scheduler may persist a
    /// SleepSnapshot to disk between app launches; breaking that decode would
    /// silently drop overnight briefings on version upgrades.
    func testLegacyJSONWithoutQueryErrorsKeyDecodesToEmpty() throws {
        // Legacy shape: pre-Wave-2.6 snapshot lacking the queryErrors key.
        let legacyJSON = """
        {
          "totalInBedMinutes": 420,
          "awakeMinutes": 30,
          "heartRateAvg": 58,
          "heartRateMin": 48,
          "heartRateMax": 75,
          "heartRateSampleCount": 128,
          "hasAppleWatchData": true,
          "windowStart": "2026-04-23T06:00:00Z",
          "windowEnd": "2026-04-23T13:00:00Z"
        }
        """
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let decoded = try dec.decode(SleepSnapshot.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decoded.queryErrors, [],
                       "legacy JSON without queryErrors key must decode to [] — breaking this would drop overnight briefings on upgrade")
        XCTAssertEqual(decoded.totalInBedMinutes, 420)
    }

    /// M6: the NightlyPromptTemplate renders the queryErrors label so the
    /// agent's reasoning sees the partial-data caveat. String-level assertion
    /// because byte-level would couple to whitespace.
    func testPromptTemplateSurfacesPartialDataLineWhenQueryErrorsPresent() {
        let snapshot = SleepSnapshot(
            totalInBedMinutes: 420, awakeMinutes: 30,
            heartRateAvg: nil, heartRateMin: nil, heartRateMax: nil,
            heartRateSampleCount: 0,
            hasAppleWatchData: true,
            windowStart: Date(timeIntervalSince1970: 1_745_400_000),
            windowEnd: Date(timeIntervalSince1970: 1_745_443_200),
            queryErrors: ["heartRate"]
        )
        let prompt = NightlyPromptTemplate.v1.userPrompt(
            sleep: snapshot, memoryProfile: nil, priorBriefings: []
        )
        XCTAssertTrue(prompt.contains("Sleep data partial"),
                      "prompt must include the partial-data caveat when queryErrors is non-empty")
        XCTAssertTrue(prompt.contains("heartRate"),
                      "partial-data caveat must name which sub-query failed")
    }

    /// M6: the converse — no queryErrors means no partial-data line. A missing
    /// test here would let a regression re-introduce the caveat unconditionally
    /// and spam the prompt.
    func testPromptTemplateOmitsPartialDataLineWhenQueryErrorsEmpty() {
        let snapshot = SleepSnapshot(
            totalInBedMinutes: 420, awakeMinutes: 30,
            heartRateAvg: 58, heartRateMin: 48, heartRateMax: 75,
            heartRateSampleCount: 128,
            hasAppleWatchData: true,
            windowStart: Date(timeIntervalSince1970: 1_745_400_000),
            windowEnd: Date(timeIntervalSince1970: 1_745_443_200)
            // queryErrors defaults to []
        )
        let prompt = NightlyPromptTemplate.v1.userPrompt(
            sleep: snapshot, memoryProfile: nil, priorBriefings: []
        )
        XCTAssertFalse(prompt.contains("Sleep data partial"),
                       "empty queryErrors must produce no partial-data line — keeps the prompt terse on the happy path")
    }
}
