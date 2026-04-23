//
//  BedtimeSettingsTests.swift
//  WakeProofTests
//

import XCTest
@testable import WakeProof

final class BedtimeSettingsTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "com.wakeproof.tests.bedtime")!
        defaults.removePersistentDomain(forName: "com.wakeproof.tests.bedtime")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "com.wakeproof.tests.bedtime")
        super.tearDown()
    }

    func testLoadReturnsDefaultWhenMissing() {
        let loaded = BedtimeSettings.load(from: defaults)
        XCTAssertEqual(loaded, .defaultSettings)
    }

    func testSaveThenLoadRoundTrips() {
        let original = BedtimeSettings(hour: 22, minute: 45, isEnabled: true)
        original.save(to: defaults)
        let loaded = BedtimeSettings.load(from: defaults)
        XCTAssertEqual(loaded, original)
    }

    func testNextBedtimeReturnsFutureToday() {
        let settings = BedtimeSettings(hour: 23, minute: 0, isEnabled: true)
        let reference = dateAt(hour: 21, minute: 0)
        let next = settings.nextBedtime(after: reference)
        XCTAssertEqual(next?.formatted(date: .omitted, time: .shortened), dateAt(hour: 23, minute: 0).formatted(date: .omitted, time: .shortened))
    }

    func testNextBedtimeRollsToTomorrowIfPassed() {
        let settings = BedtimeSettings(hour: 23, minute: 0, isEnabled: true)
        let reference = dateAt(hour: 23, minute: 30)
        let next = settings.nextBedtime(after: reference)
        XCTAssertNotNil(next)
        XCTAssertGreaterThan(next!, reference)
    }

    private func dateAt(hour: Int, minute: Int) -> Date {
        var c = Calendar.current.dateComponents([.year, .month, .day], from: .now)
        c.hour = hour
        c.minute = minute
        return Calendar.current.date(from: c)!
    }
}
