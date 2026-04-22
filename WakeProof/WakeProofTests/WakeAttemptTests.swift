//
//  WakeAttemptTests.swift
//  WakeProofTests
//

import XCTest
@testable import WakeProof

final class WakeAttemptTests: XCTestCase {

    func testInitDefaultsRetryToZero() {
        let attempt = WakeAttempt(scheduledAt: Date())
        XCTAssertEqual(attempt.retryCount, 0)
        XCTAssertNil(attempt.verdict)
    }

    // MARK: - Verdict.init(legacyRawValue:)

    func testVerdictInitFromKnownRawValue() {
        XCTAssertEqual(WakeAttempt.Verdict(legacyRawValue: "CAPTURED"), .captured)
        XCTAssertEqual(WakeAttempt.Verdict(legacyRawValue: "VERIFIED"), .verified)
        XCTAssertEqual(WakeAttempt.Verdict(legacyRawValue: "REJECTED"), .rejected)
        XCTAssertEqual(WakeAttempt.Verdict(legacyRawValue: "RETRY"), .retry)
        XCTAssertEqual(WakeAttempt.Verdict(legacyRawValue: "TIMEOUT"), .timeout)
        XCTAssertEqual(WakeAttempt.Verdict(legacyRawValue: "UNRESOLVED"), .unresolved)
    }

    func testVerdictInitFromNilFallsBackToUnresolved() {
        XCTAssertEqual(WakeAttempt.Verdict(legacyRawValue: nil), .unresolved)
    }

    func testVerdictInitFromEmptyStringFallsBackToUnresolved() {
        XCTAssertEqual(WakeAttempt.Verdict(legacyRawValue: ""), .unresolved)
    }

    func testVerdictInitFromUnknownStringFallsBackToUnresolved() {
        XCTAssertEqual(WakeAttempt.Verdict(legacyRawValue: "ANYTHING_ELSE"), .unresolved)
        XCTAssertEqual(WakeAttempt.Verdict(legacyRawValue: "captured"), .unresolved,
                       "case-sensitive on purpose: pre-enum migration data was uppercased")
    }

    // MARK: - verdictEnum computed prop

    func testVerdictEnumNilColumnReadsAsUnresolved() {
        let attempt = WakeAttempt(scheduledAt: Date())
        XCTAssertEqual(attempt.verdictEnum, .unresolved)
    }

    func testVerdictEnumWrittenStringReadsBackAsEnum() {
        let attempt = WakeAttempt(scheduledAt: Date())
        attempt.verdict = WakeAttempt.Verdict.timeout.rawValue
        XCTAssertEqual(attempt.verdictEnum, .timeout)
    }

    func testVerdictEnumGarbageColumnReadsAsUnresolved() {
        let attempt = WakeAttempt(scheduledAt: Date())
        attempt.verdict = "ROLLBACK_FROM_FUTURE_RELEASE"
        XCTAssertEqual(attempt.verdictEnum, .unresolved)
    }
}
