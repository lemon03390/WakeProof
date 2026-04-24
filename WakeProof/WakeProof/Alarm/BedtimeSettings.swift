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
    private static let logger = Logger(subsystem: LogSubsystem.overnight, category: "bedtime")

    /// M4 (Wave 2.6): split the guard into a do/catch so a decode failure emits
    /// a `logger.error` (visible in sysdiagnose) instead of silently reverting to
    /// defaults. Before, a user whose UserDefaults payload drifted shape (e.g.
    /// app upgrade with a schema change, disk corruption) would see their
    /// configured bedtime silently reset to 23:00 with no trace — making the
    /// overnight agent start at the wrong time and no way to diagnose why.
    /// Mirrors sibling `WakeWindow.load` exactly.
    static func load(from defaults: UserDefaults = .standard) -> BedtimeSettings {
        guard let data = defaults.data(forKey: key) else { return .defaultSettings }
        do {
            return try SharedJSON.decodePlain(BedtimeSettings.self, from: data)
        } catch {
            logger.error("BedtimeSettings decode failed: \(error.localizedDescription, privacy: .public) — reverting to defaults")
            return .defaultSettings
        }
    }

    /// M5 (Wave 2.6): returns `true` on success, `false` on encode failure.
    /// Before, `save()` returned Void and callers (notably `BedtimeStep`'s
    /// "Save & continue" button) had no signal that persistence failed —
    /// the user would tap through onboarding, think bedtime was saved, and
    /// find the overnight briefing never ran. Mirrors sibling `WakeWindow.save`.
    @discardableResult
    func save(to defaults: UserDefaults = .standard) -> Bool {
        do {
            let data = try SharedJSON.encodePlain(self)
            defaults.set(data, forKey: Self.key)
            Self.logger.info("BedtimeSettings saved: \(self.hour, privacy: .public):\(self.minute, privacy: .public) enabled=\(self.isEnabled, privacy: .public)")
            return true
        } catch {
            Self.logger.error("BedtimeSettings save failed: \(error.localizedDescription, privacy: .public)")
            return false
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
