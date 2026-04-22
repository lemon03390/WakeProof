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
    var verdict: String?  // "VERIFIED" | "REJECTED" | "RETRY" | "TIMEOUT"
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
}
