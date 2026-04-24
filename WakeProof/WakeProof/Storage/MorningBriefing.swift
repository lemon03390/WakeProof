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

/// Sendable value-type snapshot used to cross actor boundaries. The scheduler
/// actor (R5 fix) assembles and returns a DTO — the main actor is the one that
/// materialises a `MorningBriefing @Model` using `ModelContainer.mainContext`.
/// Without this shape, `finalizeBriefing` was creating a `ModelContext(modelContainer)`
/// *inside* the scheduler actor's non-main executor and returning the resulting
/// `@Model` instance back to the main actor — that was undefined behaviour because
/// SwiftData's model contexts are tied to the executor that constructed them.
struct BriefingDTO: Sendable {
    let briefingText: String
    let forWakeDate: Date
    let sourceSessionID: String
    let memoryUpdateApplied: Bool
}

/// B5 fix: Why the scheduler's return type expanded from `BriefingDTO?` to
/// `BriefingResult`.
///
/// The prior shape (`BriefingDTO?`) conflated three very different outcomes:
///   1. bedtime never enabled → nil (fresh-install / unarmed case)
///   2. fetchBriefing threw    → nil (transport error, session still burning $)
///   3. agent returned empty   → DTO with `briefingText = ""` (parseFailed)
///
/// In every case the UI showed "No briefing this morning — sleep well tonight"
/// which (a) looked like a fresh-install screen for a network hiccup, and (b)
/// masked the cost-leak: the fetch-failure catch branch did NOT cleanup the
/// Managed Agent session, so the meter ran at $0.08/hr until next app launch.
///
/// The enum forces the caller to handle each case and lets the View render a
/// distinct message per failure mode. The `failure` payload carries a
/// user-visible message and a machine-readable reason code for DEBUG overlays.
enum BriefingFailureReason: String, Sendable {
    case noSessionConfigured
    case fetchTransportFailed
    case fetchHTTPError
    case agentEmptyResponse
    case parseFailed
}

enum BriefingResult: Sendable {
    /// Agent produced a briefing; materialise the DTO into SwiftData.
    case success(BriefingDTO)
    /// Finalize attempted but failed (fetch threw, agent empty, parse broken).
    /// `message` is user-visible; `reason` is machine-readable for logs.
    case failure(reason: BriefingFailureReason, message: String)
    /// No active overnight session exists — bedtime never armed tonight, a
    /// prior finalize already cleared the handle, or this is a fresh install.
    /// Distinct from `.failure` because the UI should display the "Sleep well
    /// tonight — Claude will prepare one" encouragement rather than an error.
    case noSession
}

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
