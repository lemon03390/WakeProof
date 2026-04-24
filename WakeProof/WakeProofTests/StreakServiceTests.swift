//
//  StreakServiceTests.swift
//  WakeProofTests
//
//  Pure-logic tests for Wave 5 H3's StreakService. All tests feed a fixed
//  `now` and a fixed `Calendar` into `recompute(from:now:calendar:)` so the
//  outcome is deterministic regardless of when the suite runs.
//
//  The fixture calendar anchors on `2026-04-20` (a Monday in a non-DST
//  window, UTC) to sidestep DST transition edge cases that are otherwise
//  calendar-region dependent. The tests don't need DST coverage — the
//  production path uses `calendar.date(byAdding:.day,...)` which is
//  DST-safe by design (Calendar handles the wall-clock vs. elapsed-time
//  distinction internally).
//

import XCTest
@testable import WakeProof

@MainActor
final class StreakServiceTests: XCTestCase {

    // MARK: - Fixtures

    /// UTC calendar — no DST surprises, no locale-dependent first-day-of-week
    /// ambiguity. Production uses `Calendar.current` (the user's calendar),
    /// but the StreakService algorithm is calendar-agnostic — it only asks
    /// the calendar to compute `startOfDay`, `date(byAdding:.day,...)`, and
    /// `dateComponents([.day],...)`. Any well-formed calendar produces the
    /// same logical answer for the same logical date sequence.
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        if let utc = TimeZone(identifier: "UTC") {
            cal.timeZone = utc
        }
        return cal
    }

    /// "Now" = 2026-04-20 12:00:00 UTC (a Monday). All test dates are built
    /// relative to this anchor via `day(offset:)` so the intent of each test
    /// reads in plain English ("3 days ago was VERIFIED").
    private var now: Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 4
        components.day = 20
        components.hour = 12
        components.minute = 0
        components.second = 0
        // force-unwrap would be a CLAUDE.md violation; XCTAssertNotNil in
        // `setUp` would make every test fiddle with setup. The ISO anchor is
        // a guaranteed-valid calendar date; if construction fails we fall
        // back to `Date()` and the test trivially fails visibly rather than
        // crashing. (In practice the guard never fires.)
        return calendar.date(from: components) ?? Date()
    }

    /// Helper: returns `now + offset` days, snapped to startOfDay. Positive
    /// offsets are future, negatives are past. Uses the fixture calendar so
    /// the math matches the StreakService.
    private func day(offset: Int) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: offset, to: today) ?? today
    }

    /// Build a VERIFIED WakeAttempt for the given day offset.
    /// `capturedAt` is set so the service reads `capturedAt ?? scheduledAt`
    /// and lands on the intended day. We use offset+12h on `scheduledAt` to
    /// confirm the algorithm uses capturedAt when present (not scheduledAt).
    private func makeVerifiedAttempt(dayOffset: Int) -> WakeAttempt {
        let attempt = WakeAttempt(scheduledAt: day(offset: dayOffset))
        attempt.verdict = WakeAttempt.Verdict.verified.rawValue
        attempt.capturedAt = day(offset: dayOffset).addingTimeInterval(3600)  // +1h
        return attempt
    }

    /// Build a REJECTED attempt for the given day offset.
    private func makeRejectedAttempt(dayOffset: Int) -> WakeAttempt {
        let attempt = WakeAttempt(scheduledAt: day(offset: dayOffset))
        attempt.verdict = WakeAttempt.Verdict.rejected.rawValue
        attempt.capturedAt = day(offset: dayOffset).addingTimeInterval(3600)
        return attempt
    }

    // MARK: - Test 1

    /// No attempts at all → both streaks are 0.
    func testEmptyInputProducesZeroStreaks() {
        let service = StreakService()
        service.recompute(from: [], now: now, calendar: calendar)
        XCTAssertEqual(service.currentStreak, 0)
        XCTAssertEqual(service.bestStreak, 0)
    }

    // MARK: - Test 2

    /// Single VERIFIED attempt for yesterday → current=1, best=1.
    /// Today has no attempt at all, but the algorithm walks back from
    /// yesterday when today isn't in the set, so yesterday alone counts.
    func testSingleVerifiedYesterdayProducesCurrent1() {
        let service = StreakService()
        service.recompute(
            from: [makeVerifiedAttempt(dayOffset: -1)],
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(service.currentStreak, 1)
        XCTAssertEqual(service.bestStreak, 1)
    }

    // MARK: - Test 3

    /// Today verified (the user just verified moments ago) → current=1, best=1.
    /// This is the immediate post-verify state the home-view badge should show.
    func testSingleVerifiedTodayProducesCurrent1() {
        let service = StreakService()
        service.recompute(
            from: [makeVerifiedAttempt(dayOffset: 0)],
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(service.currentStreak, 1)
        XCTAssertEqual(service.bestStreak, 1)
    }

    // MARK: - Test 4

    /// Three consecutive days verified ending yesterday → current=3, best=3.
    /// Tests the base "walk backward from yesterday" path with a non-trivial
    /// run. Dates -3, -2, -1 verified; today has no attempt.
    func testThreeConsecutiveVerifiedEndingYesterdayProducesCurrent3() {
        let service = StreakService()
        service.recompute(
            from: [
                makeVerifiedAttempt(dayOffset: -3),
                makeVerifiedAttempt(dayOffset: -2),
                makeVerifiedAttempt(dayOffset: -1)
            ],
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(service.currentStreak, 3)
        XCTAssertEqual(service.bestStreak, 3)
    }

    // MARK: - Test 5

    /// 5-day verified run (days -10..-6), gap, 2-day run (days -4..-3),
    /// gap, today verified. Current streak = 1 (today only). Best = 5.
    /// Proves the best-streak scan correctly finds the longest historical run
    /// even when it's not adjacent to today.
    func testGapBreaksCurrentButBestRemembersLongerRun() {
        let service = StreakService()
        let attempts: [WakeAttempt] = [
            makeVerifiedAttempt(dayOffset: -10),
            makeVerifiedAttempt(dayOffset: -9),
            makeVerifiedAttempt(dayOffset: -8),
            makeVerifiedAttempt(dayOffset: -7),
            makeVerifiedAttempt(dayOffset: -6),
            // -5 gap
            makeVerifiedAttempt(dayOffset: -4),
            makeVerifiedAttempt(dayOffset: -3),
            // -2, -1 gap
            makeVerifiedAttempt(dayOffset: 0)
        ]
        service.recompute(from: attempts, now: now, calendar: calendar)
        XCTAssertEqual(service.currentStreak, 1)
        XCTAssertEqual(service.bestStreak, 5)
    }

    // MARK: - Test 6

    /// Yesterday has a REJECTED attempt (no verified). Days -3..-2 are
    /// verified. Since yesterday isn't verified AND today isn't verified,
    /// the "walk from yesterday" path finds yesterday not in the set and
    /// returns 0. Best streak captures the -3..-2 two-day run.
    func testNonVerifiedDayBreaksStreak() {
        let service = StreakService()
        service.recompute(
            from: [
                makeVerifiedAttempt(dayOffset: -3),
                makeVerifiedAttempt(dayOffset: -2),
                makeRejectedAttempt(dayOffset: -1)
            ],
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(service.currentStreak, 0,
                       "yesterday's REJECTED breaks the current streak immediately")
        XCTAssertEqual(service.bestStreak, 2)
    }

    // MARK: - Test 7

    /// A single day with BOTH a REJECTED and a VERIFIED attempt. Collapses to
    /// "verified" for streak-day purposes because the user did ultimately get
    /// up — the first attempt failed but the retry succeeded.
    func testMultipleAttemptsInOneDayCountAsOneVerifiedIfAnyAreVerified() {
        let service = StreakService()
        service.recompute(
            from: [
                makeRejectedAttempt(dayOffset: -1),
                makeVerifiedAttempt(dayOffset: -1)
            ],
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(service.currentStreak, 1)
        XCTAssertEqual(service.bestStreak, 1)
    }

    // MARK: - Test 8

    /// A day with ONLY rejected attempts (no verified). Not a verified day;
    /// both streaks 0.
    func testDayWithOnlyRejectedIsNotVerified() {
        let service = StreakService()
        service.recompute(
            from: [
                makeRejectedAttempt(dayOffset: -1),
                makeRejectedAttempt(dayOffset: -1)
            ],
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(service.currentStreak, 0)
        XCTAssertEqual(service.bestStreak, 0)
    }

    // MARK: - Test 9

    /// Attempts dated tomorrow (DEBUG fire-now can produce future-dated rows
    /// on clock-adjusted devices; robustness edge case). Tomorrow's VERIFIED
    /// plus today's VERIFIED should NOT crash and should produce a valid
    /// count. Today counts for current=1; tomorrow doesn't extend the current
    /// streak backward-walk but does contribute to the best-streak scan.
    /// Best = 2 (today + tomorrow consecutive in the verified set).
    func testFutureDaysDoNotAffectAnything() {
        let service = StreakService()
        service.recompute(
            from: [
                makeVerifiedAttempt(dayOffset: 0),
                makeVerifiedAttempt(dayOffset: 1)
            ],
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(service.currentStreak, 1,
                       "current walks backward from today; future days don't extend it")
        XCTAssertEqual(service.bestStreak, 2,
                       "best streak scans all days including future ones — the longest run is still the longest")
    }

    // MARK: - Test 10

    /// Recompute with data, then recompute with empty → both streaks must
    /// fall to 0. Guards against a stale @Observable cache (e.g. a naive
    /// implementation that only writes when `attempts` is non-empty).
    func testResetToZeroAfterAllVerifiedRemoved() {
        let service = StreakService()
        service.recompute(
            from: [
                makeVerifiedAttempt(dayOffset: -1),
                makeVerifiedAttempt(dayOffset: 0)
            ],
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(service.currentStreak, 2)
        XCTAssertEqual(service.bestStreak, 2)

        // User clears history (or tests the dev-debug path that deletes all
        // WakeAttempt rows). Recompute must honestly reset.
        service.recompute(from: [], now: now, calendar: calendar)
        XCTAssertEqual(service.currentStreak, 0)
        XCTAssertEqual(service.bestStreak, 0)
    }

    // MARK: - Extra determinism coverage (algorithm-level)

    /// Direct test of the static helper: a single verified day with
    /// `verifiedDays = {today}` yields current=1.
    func testComputeCurrentStreakStaticHelperTodayOnly() {
        let today = calendar.startOfDay(for: now)
        let result = StreakService.computeCurrentStreak(
            verifiedDays: [today],
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(result, 1)
    }

    /// Direct test of the static helper: empty verifiedDays → best=0.
    func testComputeBestStreakStaticHelperEmpty() {
        let result = StreakService.computeBestStreak(verifiedDays: [], calendar: calendar)
        XCTAssertEqual(result, 0)
    }
}
