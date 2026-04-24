//
//  WakeWindowTests.swift
//  WakeProofTests
//

import XCTest
@testable import WakeProof

final class WakeWindowTests: XCTestCase {

    // MARK: - nextFireDate

    func testNextFireDateReturnsTodayWhenWindowIsLater() throws {
        let cal = calendarHongKong()
        let now = try date(year: 2026, month: 4, day: 23, hour: 5, minute: 0, in: cal)
        let window = WakeWindow(startHour: 6, startMinute: 30, endHour: 7, endMinute: 0, isEnabled: true)
        let fire = try XCTUnwrap(window.nextFireDate(after: now, calendar: cal))
        let comp = cal.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
        XCTAssertEqual(comp.day, 23)
        XCTAssertEqual(comp.hour, 6)
        XCTAssertEqual(comp.minute, 30)
    }

    func testNextFireDateRollsToTomorrowWhenWindowAlreadyPassed() throws {
        let cal = calendarHongKong()
        let now = try date(year: 2026, month: 4, day: 23, hour: 8, minute: 0, in: cal)
        let window = WakeWindow(startHour: 6, startMinute: 30, endHour: 7, endMinute: 0, isEnabled: true)
        let fire = try XCTUnwrap(window.nextFireDate(after: now, calendar: cal))
        let comp = cal.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
        XCTAssertEqual(comp.day, 24)
        XCTAssertEqual(comp.hour, 6)
        XCTAssertEqual(comp.minute, 30)
    }

    func testNextFireDateExactlyAtFireTimeReturnsTomorrow() throws {
        let cal = calendarHongKong()
        let now = try date(year: 2026, month: 4, day: 23, hour: 6, minute: 30, in: cal)
        let window = WakeWindow(startHour: 6, startMinute: 30, endHour: 7, endMinute: 0, isEnabled: true)
        let fire = try XCTUnwrap(window.nextFireDate(after: now, calendar: cal))
        let comp = cal.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
        XCTAssertEqual(comp.day, 24, "nextDate(after:) must be strictly after `now`")
    }

    func testNextFireDateHandlesMidnight() throws {
        let cal = calendarHongKong()
        let now = try date(year: 2026, month: 4, day: 23, hour: 23, minute: 30, in: cal)
        let window = WakeWindow(startHour: 0, startMinute: 0, endHour: 0, endMinute: 30, isEnabled: true)
        let fire = try XCTUnwrap(window.nextFireDate(after: now, calendar: cal))
        let comp = cal.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
        XCTAssertEqual(comp.day, 24)
        XCTAssertEqual(comp.hour, 0)
        XCTAssertEqual(comp.minute, 0)
    }

    // MARK: - composeTime

    func testComposeTimeReturnsTodayAtGivenHourMinute() throws {
        let cal = calendarHongKong()
        let now = try date(year: 2026, month: 4, day: 23, hour: 14, minute: 0, in: cal)
        let composed = WakeWindow.composeTime(hour: 7, minute: 15, calendar: cal, now: now)
        let comp = cal.dateComponents([.year, .month, .day, .hour, .minute], from: composed)
        XCTAssertEqual(comp.year, 2026)
        XCTAssertEqual(comp.month, 4)
        XCTAssertEqual(comp.day, 23)
        XCTAssertEqual(comp.hour, 7)
        XCTAssertEqual(comp.minute, 15)
    }

    // MARK: - Codable round-trip + UserDefaults

    func testSaveLoadRoundTripPreservesAllFields() throws {
        let defaults = ephemeralDefaults()
        let original = WakeWindow(startHour: 5, startMinute: 45, endHour: 6, endMinute: 15, isEnabled: true)
        XCTAssertTrue(original.save(to: defaults))
        let loaded = WakeWindow.load(from: defaults)
        XCTAssertEqual(loaded, original)
    }

    func testLoadReturnsDefaultWhenNoStoredValue() {
        let defaults = ephemeralDefaults()
        let loaded = WakeWindow.load(from: defaults)
        XCTAssertEqual(loaded, WakeWindow.defaultWindow)
    }

    func testLoadReturnsDefaultWhenStoredValueIsCorrupted() {
        let defaults = ephemeralDefaults()
        defaults.set(Data("not valid json".utf8), forKey: "com.wakeproof.alarm.wakeWindow")
        let loaded = WakeWindow.load(from: defaults)
        XCTAssertEqual(loaded, WakeWindow.defaultWindow)
    }

    func testSaveReturnsTrueOnSuccess() {
        let defaults = ephemeralDefaults()
        XCTAssertTrue(WakeWindow.defaultWindow.save(to: defaults))
    }

    // MARK: - Wave 5 H2 commitment note

    /// H2: a commitment note must round-trip through the UserDefaults-backed
    /// Codable boundary. If it didn't, `save(...) / load(...)` would silently
    /// drop the user's typed sentence between launches — the briefing cover
    /// would read `nil` the morning after they armed the alarm with a note.
    func testRoundTripsCommitmentNote() throws {
        let defaults = ephemeralDefaults()
        let original = WakeWindow(
            startHour: 6, startMinute: 30,
            endHour: 7, endMinute: 0,
            isEnabled: true,
            commitmentNote: "Finish the hackathon submission"
        )
        XCTAssertTrue(original.save(to: defaults))
        let loaded = WakeWindow.load(from: defaults)
        XCTAssertEqual(loaded.commitmentNote, "Finish the hackathon submission")
        XCTAssertEqual(loaded, original, "all fields including commitmentNote should round-trip")
    }

    /// H2: an explicit nil must survive Codable — the decoder doesn't invent
    /// a default value for an absent Optional, but the encoded form of `nil`
    /// (a JSON `null` under PlainJSON's policy) should decode back as `nil`,
    /// not an empty string.
    func testRoundTripsNilCommitmentNote() throws {
        let defaults = ephemeralDefaults()
        let original = WakeWindow(
            startHour: 6, startMinute: 30,
            endHour: 7, endMinute: 0,
            isEnabled: true,
            commitmentNote: nil
        )
        XCTAssertTrue(original.save(to: defaults))
        let loaded = WakeWindow.load(from: defaults)
        XCTAssertNil(loaded.commitmentNote)
    }

    /// H2: pre-H2 payloads on disk (written by earlier app versions) omit the
    /// `commitmentNote` key entirely. The decoder must tolerate the absence
    /// and synthesize `nil` — otherwise the first launch after updating
    /// would fall back to `defaultWindow` and silently discard the user's
    /// previously-configured alarm time. This is the backwards-compat contract
    /// the controller decision calls out (§decision-1: missing field → nil).
    func testLegacyDecodeWithoutCommitmentNote() throws {
        let defaults = ephemeralDefaults()
        let legacyJSON = #"{"startHour":6,"startMinute":30,"endHour":7,"endMinute":0,"isEnabled":true}"#
        defaults.set(Data(legacyJSON.utf8), forKey: "com.wakeproof.alarm.wakeWindow")
        let loaded = WakeWindow.load(from: defaults)
        XCTAssertEqual(loaded.startHour, 6)
        XCTAssertEqual(loaded.startMinute, 30)
        XCTAssertEqual(loaded.endHour, 7)
        XCTAssertEqual(loaded.endMinute, 0)
        XCTAssertTrue(loaded.isEnabled)
        XCTAssertNil(loaded.commitmentNote, "pre-H2 payloads without the key must decode as nil")
    }

    /// H2: a fresh install / first-run default must have a nil note so the
    /// briefing cover doesn't render a stale placeholder before the user has
    /// typed anything.
    func testDefaultWindowHasNilCommitmentNote() {
        XCTAssertNil(WakeWindow.defaultWindow.commitmentNote)
    }

    /// H2: 60-char cap is the contract — both the TextField truncation logic
    /// and any test invariant read through this constant. A future drift (e.g.
    /// someone silently bumps it to 80 in WakeWindow but not in the UI) is
    /// caught by this assertion.
    func testCommitmentNoteMaxLengthIsSixty() {
        XCTAssertEqual(WakeWindow.commitmentNoteMaxLength, 60)
    }

    // MARK: - Helpers

    private func calendarHongKong() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Hong_Kong") ?? .current
        return cal
    }

    private func date(year: Int, month: Int, day: Int, hour: Int, minute: Int, in cal: Calendar) throws -> Date {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day; c.hour = hour; c.minute = minute
        return try XCTUnwrap(cal.date(from: c))
    }

    private func ephemeralDefaults() -> UserDefaults {
        let suite = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
