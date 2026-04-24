//
//  LogSubsystem.swift
//  WakeProof
//
//  SR3 (Stage 4): single source of truth for the `subsystem:` label passed to
//  every `Logger(subsystem:category:)` instantiation in this app. Previously
//  the 19 call sites across alarm/, audio, coach, memory/, onboarding/,
//  overnight/, permissions, verification each carried a string literal like
//  `"com.wakeproof.verification"`. A typo in any one of them silently split a
//  subsystem into two, hiding log lines from Console filters and sysdiagnose
//  queries. Centralising the literals here means future renames or additions
//  are mechanical and diffable in one file.
//
//  Naming convention: `com.wakeproof.<domain>` matches the bundle identifier
//  prefix so Console.app's unified-log filter catches every WakeProof line
//  with a single `subsystem:com.wakeproof.*` query.
//

import Foundation

/// Well-known log subsystems. See file header for rationale.
enum LogSubsystem {
    static let alarm = "com.wakeproof.alarm"
    static let app = "com.wakeproof.app"
    static let audio = "com.wakeproof.audio"
    static let coach = "com.wakeproof.coach"
    static let memory = "com.wakeproof.memory"
    static let onboarding = "com.wakeproof.onboarding"
    static let overnight = "com.wakeproof.overnight"
    static let permissions = "com.wakeproof.permissions"
    static let verification = "com.wakeproof.verification"
}
