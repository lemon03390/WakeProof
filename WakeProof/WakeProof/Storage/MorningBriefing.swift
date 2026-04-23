//
//  MorningBriefing.swift
//  WakeProof
//
//  Per-night briefing produced by the overnight agent (primary path) or the
//  nightly synthesis call (fallback path). Cached locally so the alarm UI does
//  not depend on live agent availability — at wake time, MorningBriefingView
//  queries the latest row for today's wake date and renders offline.
//

import Foundation
import SwiftData

@Model
final class MorningBriefing {
    var generatedAt: Date
    var forWakeDate: Date
    var briefingText: String

    /// Populated on the Managed Agents path with the session id. Nil on fallback.
    var sourceSessionID: String?

    /// JSON representation of the SleepSnapshot at generation time. Kept for
    /// Layer 4's weekly-coach consumption and for debugging.
    var sleepSnapshotJSON: String?

    /// Whether the briefing's memory_update (if any) has been applied to MemoryStore.
    /// Default false; flipped to true by the applying code path.
    var memoryUpdateApplied: Bool

    init(
        generatedAt: Date = .now,
        forWakeDate: Date,
        briefingText: String,
        sourceSessionID: String? = nil,
        sleepSnapshotJSON: String? = nil,
        memoryUpdateApplied: Bool = false
    ) {
        self.generatedAt = generatedAt
        self.forWakeDate = forWakeDate
        self.briefingText = briefingText
        self.sourceSessionID = sourceSessionID
        self.sleepSnapshotJSON = sleepSnapshotJSON
        self.memoryUpdateApplied = memoryUpdateApplied
    }
}
