//
//  SecretsConstants.swift
//  WakeProof
//
//  Constants referenced by both `Secrets.swift.example` (template, tracked)
//  and `Secrets.swift` (real values, git-ignored), plus by client init
//  guards in `ClaudeAPIClient`, `OvernightAgentClient`, and
//  `NightlySynthesisClient`.
//
//  S-I8 (Wave 2.1, 2026-04-26): the placeholder string used to be a literal
//  duplicated in three call sites — if `Secrets.swift.example` ever updated
//  the placeholder text (e.g. for a longer entropy bump), one of the three
//  comparators would slip and the placeholder check would silently stop
//  catching unconfigured installs. Centralising here ensures the literal
//  is mutated in exactly one place.
//

import Foundation

/// Constants that are NOT secrets but must remain in sync between
/// `Secrets.swift.example`, `Secrets.swift`, and client guards.
nonisolated enum SecretsConstants {
    /// Placeholder value used in `Secrets.swift.example` to mark "you must set
    /// this before the app will run". Client init code crashes via
    /// `preconditionFailure` if `Secrets.wakeproofToken` still equals this.
    static let tokenPlaceholder: String = "REPLACE_WITH_OPENSSL_RAND_HEX_32"
}
