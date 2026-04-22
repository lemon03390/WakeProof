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
    var verdict: String?  // "VERIFIED" | "REJECTED" | "RETRY"
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
