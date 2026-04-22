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
