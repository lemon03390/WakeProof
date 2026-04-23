//
//  BedtimeSettings.swift
//  WakeProof
//
//  When the overnight agent session is kicked off. Separate from WakeWindow
//  because bedtime is the evening-before event, not part of the alarm morning.
//

import Foundation
import os

struct BedtimeSettings: Codable, Equatable {
    var hour: Int
    var minute: Int
    var isEnabled: Bool

    static let defaultSettings = BedtimeSettings(hour: 23, minute: 0, isEnabled: false)

    private static let key = "com.wakeproof.alarm.bedtimeSettings"
    private static let logger = Logger(subsystem: "com.wakeproof.overnight", category: "bedtime")

    static func load(from defaults: UserDefaults = .standard) -> BedtimeSettings {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(BedtimeSettings.self, from: data) else {
            return .defaultSettings
        }
        return decoded
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.key)
            Self.logger.info("BedtimeSettings saved: \(self.hour, privacy: .public):\(self.minute, privacy: .public) enabled=\(self.isEnabled, privacy: .public)")
        } else {
            Self.logger.error("BedtimeSettings save failed: JSON encode returned nil (should be unreachable for Codable struct)")
        }
    }

    /// Next bedtime in the future relative to `reference`. If the time has already
    /// passed today, returns tomorrow's bedtime at the same clock time.
    func nextBedtime(after reference: Date = .now, calendar: Calendar = .current) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: reference)
        components.hour = hour
        components.minute = minute
        guard let today = calendar.date(from: components) else { return nil }
        return today > reference ? today : calendar.date(byAdding: .day, value: 1, to: today)
    }
}
