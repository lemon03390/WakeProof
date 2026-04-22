//
//  WakeWindow.swift
//  WakeProof
//
//  The wake window the user has configured (e.g., 06:30–07:00). Stored in
//  UserDefaults so a schema migration isn't forced on the SwiftData store
//  while Phase 6's unattended audio test is still running on-device.
//

import Foundation

struct WakeWindow: Codable, Equatable {
    var startHour: Int
    var startMinute: Int
    var endHour: Int
    var endMinute: Int
    var isEnabled: Bool

    static let defaultWindow = WakeWindow(
        startHour: 6, startMinute: 30,
        endHour: 7, endMinute: 0,
        isEnabled: false
    )

    private static let key = "com.wakeproof.alarm.wakeWindow"

    static func load(from defaults: UserDefaults = .standard) -> WakeWindow {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(WakeWindow.self, from: data) else {
            return .defaultWindow
        }
        return decoded
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key)
    }

    /// The next Date matching this window's start time, relative to `now`.
    /// If the start time already passed today, returns tomorrow's occurrence.
    func nextFireDate(after now: Date = .now, calendar: Calendar = .current) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = startHour
        components.minute = startMinute
        components.second = 0
        guard let candidate = calendar.date(from: components) else { return nil }
        if candidate > now {
            return candidate
        }
        return calendar.date(byAdding: .day, value: 1, to: candidate)
    }
}
