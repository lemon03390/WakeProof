//
//  WakeAttempt.swift
//  WakeProof
//
//  Per-alarm log of the user's verification attempts.
//  Day 1 scaffolding — populated properly starting Day 3.
//

import Foundation
import SwiftData

@Model
final class WakeAttempt {
    var scheduledAt: Date
    var capturedAt: Date?
    var imageData: Data?

    /// Verdict is intentionally a raw String for now. Day 3's vision-verification plan
    /// introduces a `Verdict: String, Codable` enum whose `rawValue` maps to this column,
    /// so current rows migrate without a schema rename. Typing it as String today avoids
    /// a forced migration of the on-device store built up during Phase 6 testing.
    var verdict: String?
    var verdictReasoning: String?
    var retryCount: Int
    var dismissedAt: Date?

    // Additive fields for Day 2 alarm-core. SwiftData treats new optional @Attribute
    // properties as a lightweight migration — the on-device store is preserved.
    var videoPath: String?
    var triggeredWindowStart: Date?
    var triggeredWindowEnd: Date?

    init(scheduledAt: Date) {
        self.scheduledAt = scheduledAt
        self.retryCount = 0
    }

    /// String constants matching the Day-3 enum spec. Storing as String preserves the
    /// migration-free property; the namespace prevents typos at call sites.
    enum Verdict: String {
        case captured       = "CAPTURED"        // user produced a video; vision verdict pending (Day 3)
        case verified       = "VERIFIED"        // vision call confirmed
        case rejected       = "REJECTED"        // vision call disagreed
        case retry          = "RETRY"           // user cancelled/failed mid-capture
        case timeout        = "TIMEOUT"         // ring ceiling reached without capture
        case unresolved     = "UNRESOLVED"      // alarm fired but app died before resolution

        /// Decode a stored value, treating any unrecognised string as `.unresolved` rather
        /// than nil. Old rows from pre-enum schema persisted arbitrary strings; without
        /// this fallback, Day-3 history views would crash or display blank verdicts.
        init(legacyRawValue: String?) {
            guard let raw = legacyRawValue, let value = Verdict(rawValue: raw) else {
                self = .unresolved
                return
            }
            self = value
        }
    }
}
