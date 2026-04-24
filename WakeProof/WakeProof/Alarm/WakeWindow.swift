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
    /// Wave 5 H2 (§12.3-H2): optional one-line commitment note — "the first
    /// thing tomorrow-you needs to do". Surfaced in MorningBriefingView post-
    /// verified as a self-authored anchor alongside Claude's H1 observation.
    /// Declared without a `= nil` property-level default so synthesized
    /// Decodable conformance reads it from JSON (matching VerificationResult.
    /// memoryUpdate / .observation pattern). The memberwise `init` below gives
    /// it a `nil` default so existing pre-H2 call sites keep compiling, and
    /// the JSON decoder's tolerance for absent-optional keys means pre-H2
    /// UserDefaults blobs still decode (the missing key → nil).
    ///
    /// Absorbs G6 (bedtime contract re-sign): the user's own sentence is
    /// strictly stronger psychology than a `[Confirm 06:30] [Skip]` yes/no,
    /// so no separate confirmation screen is scheduled.
    var commitmentNote: String?

    /// 60 char cap — applied both at the TextField UI layer (truncate-on-change)
    /// and wherever a test invariant needs to reference "the limit". Single
    /// source of truth so UI + tests stay synchronized if the cap ever moves.
    static let commitmentNoteMaxLength: Int = 60

    init(
        startHour: Int,
        startMinute: Int,
        endHour: Int,
        endMinute: Int,
        isEnabled: Bool,
        commitmentNote: String? = nil
    ) {
        self.startHour = startHour
        self.startMinute = startMinute
        self.endHour = endHour
        self.endMinute = endMinute
        self.isEnabled = isEnabled
        self.commitmentNote = commitmentNote
    }

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
