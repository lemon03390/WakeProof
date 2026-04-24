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
        XCTAssertTrue(original.save(to: defaults))
        let loaded = BedtimeSettings.load(from: defaults)
        XCTAssertEqual(loaded, original)
    }

    /// M5 (Wave 2.6): save returns Bool now — true on success, false on encode
    /// failure. We can't provoke a realistic JSONEncoder failure for this struct
    /// (all fields are value-types that encode reliably), so this test pins the
    /// success-path contract: a Codable struct that encodes cleanly must return
    /// true so callers' Bool-acting branches (see `BedtimeStep.swift`) work.
    /// If a future encode-failure regression lands, a sibling test should stub
    /// a failing encoder; for now, the success invariant is the canary.
    func testSaveReturnsTrueOnSuccess() {
        let settings = BedtimeSettings(hour: 22, minute: 30, isEnabled: true)
        XCTAssertTrue(settings.save(to: defaults))
    }

    /// M4 (Wave 2.6): corrupted UserDefaults payload must not crash and must
    /// revert to defaults. Before M4, a decode failure was silent (try?) so a
    /// regression where the Codable shape drifted would appear as "user's
    /// bedtime randomly reset" with no log. After the do/catch split, the
    /// same outcome happens but with a logger.error line in sysdiagnose.
    func testLoadReturnsDefaultsWhenStoredValueIsCorrupted() {
        defaults.set(Data("not valid json at all".utf8), forKey: "com.wakeproof.alarm.bedtimeSettings")
        let loaded = BedtimeSettings.load(from: defaults)
        XCTAssertEqual(loaded, .defaultSettings,
                       "corrupt payload must fall back to defaults rather than crashing")
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
