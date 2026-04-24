//
//  WakeWindow.swift
//  WakeProof
//
//  The wake window the user has configured (e.g., 06:30–07:00). Stored in
//  UserDefaults so a schema migration isn't forced on the SwiftData store
//  while Phase 6's unattended audio test is still running on-device.
//

import Foundation
import os

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
    private static let logger = Logger(subsystem: LogSubsystem.alarm, category: "wakeWindow")

    static func load(from defaults: UserDefaults = .standard) -> WakeWindow {
        guard let data = defaults.data(forKey: key) else {
            return .defaultWindow
        }
        do {
            return try SharedJSON.decodePlain(WakeWindow.self, from: data)
        } catch {
            logger.error("Failed to decode WakeWindow — falling back to default: \(error.localizedDescription, privacy: .public)")
            return .defaultWindow
        }
    }

    /// Returns true on success. Callers should surface failure to the user — silently
    /// failing here means the alarm tomorrow morning fires at the previous window's time
    /// (or never, if the user just enabled it for the first time).
    @discardableResult
    func save(to defaults: UserDefaults = .standard) -> Bool {
        do {
            let data = try SharedJSON.encodePlain(self)
            defaults.set(data, forKey: Self.key)
            return true
        } catch {
            Self.logger.error("Failed to encode WakeWindow: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// The next Date matching this window's start time, after `now`. Uses
    /// `Calendar.nextDate(after:matching:)` so DST spring-forward / fall-back
    /// is handled by the calendar, not hand-rolled.
    func nextFireDate(after now: Date = .now, calendar: Calendar = .current) -> Date? {
        var components = DateComponents()
        components.hour = startHour
        components.minute = startMinute
        components.second = 0
        return calendar.nextDate(
            after: now,
            matching: components,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        )
    }

    /// Build a Date for today at the given hour/minute. Falls back to `now` if the
    /// calendar can't materialize the components — practically unreachable for valid
    /// hour/minute values, but the optional return is the calendar's contract.
    static func composeTime(hour: Int, minute: Int, calendar: Calendar = .current, now: Date = .now) -> Date {
        var c = calendar.dateComponents([.year, .month, .day], from: now)
        c.hour = hour
        c.minute = minute
        return calendar.date(from: c) ?? now
    }
}
