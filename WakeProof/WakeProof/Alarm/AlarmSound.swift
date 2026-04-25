//
//  AlarmSound.swift
//  WakeProof
//
//  User-selectable alarm sound. The bundle ships two .m4a files at the
//  Resources/ root: `alarm.m4a` (standard ramped tone) and
//  `annoying-alarm.m4a` (deliberately abrasive — for users who genuinely
//  need help waking up). Selection is persisted via UserDefaults under a
//  shared static key so the @AppStorage binding (settings UI) and the
//  static `current()` reader (WakeProofApp's onFire wiring) read the
//  same value without drift.
//

import Foundation

enum AlarmSound: String, CaseIterable, Identifiable {
    case standard
    case annoying

    /// UserDefaults key shared between the @AppStorage binding in
    /// AlarmSchedulerView and the static `current()` reader in
    /// WakeProofApp's onFire path. CLAUDE.md auto-promoted rule:
    /// shared @AppStorage keys must live as a single static constant
    /// so a rename can't desynchronise the writer and reader.
    static let userDefaultsKey = "com.wakeproof.alarmSound"

    /// Default for first-launch users (no UserDefaults entry yet) and
    /// for any future read where the stored raw value doesn't decode
    /// (e.g. a sound is removed in a later build).
    static let `default`: AlarmSound = .standard

    var id: String { rawValue }

    /// Sentence-case display name for the settings UI per design-system
    /// voice rules. No emoji, no marketing adjectives.
    var displayName: String {
        switch self {
        case .standard: return "Standard"
        case .annoying: return "Annoying"
        }
    }

    /// Bundle resource basename (extension is .m4a for both — see
    /// Resources/). WakeProofApp uses this with
    /// `Bundle.main.url(forResource:withExtension:"m4a")`.
    var bundleResourceName: String {
        switch self {
        case .standard: return "alarm"
        case .annoying: return "annoying-alarm"
        }
    }

    /// Resolve the user's current selection from UserDefaults. Falls back
    /// to `.default` on missing or undecodable raw values so the alarm
    /// fire path is never blocked by a corrupted preference.
    static func current() -> AlarmSound {
        guard let raw = UserDefaults.standard.string(forKey: userDefaultsKey),
              let sound = AlarmSound(rawValue: raw) else {
            return .default
        }
        return sound
    }
}
