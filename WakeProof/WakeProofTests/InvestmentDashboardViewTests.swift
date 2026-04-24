//
//  InvestmentDashboardViewTests.swift
//  WakeProofTests
//
//  Wave 5 H4 (§12.3-H4): unit coverage for the pure-logic helpers on
//  `InvestmentDashboardModel`. The SwiftUI view itself is deliberately
//  untested at snapshot level — spec scope is to exercise the date
//  formatting, counting, and empty-state decisions that are orthogonal to
//  rendering.
//

import XCTest
@testable import WakeProof

final class InvestmentDashboardViewTests: XCTestCase {

    // MARK: - Baseline age formatting

    func testBaselineAgeZeroDaysRendersToday() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_714_000_000)
        // Same timestamp → exact 0 days.
        let capturedAt = now
        XCTAssertEqual(
            InvestmentDashboardModel.baselineAgeText(
                capturedAt: capturedAt, now: now, calendar: calendar
            ),
            "Today"
        )
    }

    func testBaselineAgeOneDayRendersYesterday() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_714_000_000)
        // 24 hours earlier — one calendar day diff.
        let capturedAt = now.addingTimeInterval(-24 * 3600)
        XCTAssertEqual(
            InvestmentDashboardModel.baselineAgeText(
                capturedAt: capturedAt, now: now, calendar: calendar
            ),
            "Yesterday"
        )
    }

    func testBaselineAgeTenDaysRendersTenDaysAgo() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_714_000_000)
        let capturedAt = now.addingTimeInterval(-10 * 24 * 3600)
        XCTAssertEqual(
            InvestmentDashboardModel.baselineAgeText(
                capturedAt: capturedAt, now: now, calendar: calendar
            ),
            "10 days ago"
        )
    }

    func testBaselineAgeNegativeRendersTodayNotNegative() {
        // A clock-skew future date must NOT produce "-5 days ago"; collapse to "Today".
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_714_000_000)
        let capturedAt = now.addingTimeInterval(5 * 24 * 3600)  // future
        XCTAssertEqual(
            InvestmentDashboardModel.baselineAgeText(
                capturedAt: capturedAt, now: now, calendar: calendar
            ),
            "Today"
        )
    }

    // MARK: - Framing line gating

    func testFramingLineHiddenWhenNoBaseline() {
        XCTAssertFalse(InvestmentDashboardModel.shouldShowFramingLine(hasBaseline: false))
    }

    func testFramingLineShownWhenBaselineExists() {
        XCTAssertTrue(InvestmentDashboardModel.shouldShowFramingLine(hasBaseline: true))
    }

    func testFramingLineCopyUsesVerifiedCount() {
        XCTAssertEqual(
            InvestmentDashboardModel.framingLine(verifiedCount: 0),
            "Apple Clock doesn't know you. WakeProof has 0 of your mornings."
        )
        XCTAssertEqual(
            InvestmentDashboardModel.framingLine(verifiedCount: 47),
            "Apple Clock doesn't know you. WakeProof has 47 of your mornings."
        )
    }

    // MARK: - Insights count rendering

    func testInsightsCountNilRendersDash() {
        XCTAssertEqual(InvestmentDashboardModel.insightsCountText(nil), "-")
    }

    func testInsightsCountZeroRendersZero() {
        // A nil and a zero mean different things — zero must not collapse to "-"
        // or the empty-state sub-hint ("Opus starts noticing…") would never fire.
        XCTAssertEqual(InvestmentDashboardModel.insightsCountText(0), "0")
    }

    func testInsightsCountPositiveRendersInteger() {
        XCTAssertEqual(InvestmentDashboardModel.insightsCountText(23), "23")
    }

    // MARK: - Verified counting

    func testVerifiedCountOnlyCountsVerifiedVerdict() {
        let a1 = WakeAttempt(scheduledAt: Date())
        a1.verdict = WakeAttempt.Verdict.verified.rawValue
        let a2 = WakeAttempt(scheduledAt: Date())
        a2.verdict = WakeAttempt.Verdict.rejected.rawValue
        let a3 = WakeAttempt(scheduledAt: Date())
        a3.verdict = WakeAttempt.Verdict.verified.rawValue
        XCTAssertEqual(
            InvestmentDashboardModel.verifiedCount(from: [a1, a2, a3]),
            2
        )
    }

    func testVerifiedCountIgnoresCapturedAndTimeoutAndRetry() {
        // Defense-in-depth: every non-VERIFIED rawValue must NOT bump the count.
        // This is the invariant the framing-line copy depends on.
        let attempts: [WakeAttempt] = [
            WakeAttempt.Verdict.captured,
            .rejected,
            .retry,
            .timeout,
            .unresolved
        ].map { verdict in
            let a = WakeAttempt(scheduledAt: Date())
            a.verdict = verdict.rawValue
            return a
        }
        XCTAssertEqual(
            InvestmentDashboardModel.verifiedCount(from: attempts),
            0
        )
    }

    func testVerifiedCountEmptyArrayReturnsZero() {
        XCTAssertEqual(InvestmentDashboardModel.verifiedCount(from: []), 0)
    }

    // MARK: - Empty-state copy

    func testEmptyStateCopy() {
        XCTAssertEqual(
            InvestmentDashboardModel.noBaselineCopy,
            "Capture your baseline to start collecting mornings"
        )
    }

    // MARK: - Baseline sub-hint formatting

    func testBaselineSubHintIncludesLocationAndDate() {
        let locale = Locale(identifier: "en_US_POSIX")
        let date = Date(timeIntervalSince1970: 1_714_000_000)  // 2024-04-24 UTC-ish
        let hint = InvestmentDashboardModel.baselineSubHint(
            locationLabel: "Kitchen",
            capturedAt: date,
            locale: locale
        )
        XCTAssertTrue(hint.hasPrefix("Kitchen, "),
                      "Expected 'Kitchen, <date>' but got '\(hint)'")
        // Date portion: the abbreviated-month format must include the month abbreviation.
        // Cover months that abbreviate distinctly in en_US_POSIX to stay robust.
        XCTAssertTrue(
            hint.contains("Apr") || hint.contains("Mar") || hint.contains("May"),
            "Expected a month abbreviation in '\(hint)'"
        )
    }

    func testBaselineSubHintTrimmingEmptyLocationReturnsDateOnly() {
        // Whitespace-only location must NOT produce "  , <date>" — semantically
        // that's the same as "no location" and should render identically to an
        // empty label. A raw "contains comma" check would be brittle because
        // many locales' abbreviated date format includes a comma internally
        // (e.g. "Apr 25, 2024" in en_US). We verify the actual invariant:
        // whitespace-only == empty label produces the same output.
        let locale = Locale(identifier: "en_US_POSIX")
        let date = Date(timeIntervalSince1970: 1_714_000_000)
        let hintFromWhitespace = InvestmentDashboardModel.baselineSubHint(
            locationLabel: "   ",
            capturedAt: date,
            locale: locale
        )
        let hintFromEmpty = InvestmentDashboardModel.baselineSubHint(
            locationLabel: "",
            capturedAt: date,
            locale: locale
        )
        XCTAssertEqual(hintFromWhitespace, hintFromEmpty,
                       "Whitespace-only label must render identically to empty label")
        XCTAssertFalse(hintFromWhitespace.hasPrefix(" "),
                       "Hint must not start with whitespace: '\(hintFromWhitespace)'")
        XCTAssertFalse(hintFromWhitespace.hasPrefix(","),
                       "Hint must not start with a separator comma: '\(hintFromWhitespace)'")
    }
}
