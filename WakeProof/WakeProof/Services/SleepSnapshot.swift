//
//  SleepSnapshot.swift
//  WakeProof
//
//  Snapshot of last night's HealthKit-derived sleep + heart-rate signals. Rendered
//  as JSON into the agent's session event payload (primary) or inlined into the
//  nightly synthesis prompt (fallback). Empty on devices without Apple Watch data
//  or when the user denied HealthKit read access — the agent's prompt handles
//  that gracefully ("sleep data unavailable tonight").
//

import Foundation

struct SleepSnapshot: Codable, Equatable {

    /// Total minutes recorded as in-bed (HKCategoryValueSleepAnalysis.inBed, asleep*, etc.).
    let totalInBedMinutes: Int

    /// Minutes recorded as awake during the window (HKCategoryValueSleepAnalysis.awake).
    let awakeMinutes: Int

    /// Resting / daytime heart-rate samples in the window.
    let heartRateAvg: Double?
    let heartRateMin: Double?
    let heartRateMax: Double?
    let heartRateSampleCount: Int

    /// True when at least one sleep-category sample came from an Apple Watch source.
    /// iPhone-only (accelerometer-based) sleep records still populate the numbers but
    /// flag this as false so the agent's prompt can soften certainty.
    let hasAppleWatchData: Bool

    /// Window-start ISO 8601 for display and debugging.
    let windowStart: Date
    let windowEnd: Date

    static let empty = SleepSnapshot(
        totalInBedMinutes: 0,
        awakeMinutes: 0,
        heartRateAvg: nil,
        heartRateMin: nil,
        heartRateMax: nil,
        heartRateSampleCount: 0,
        hasAppleWatchData: false,
        windowStart: Date(timeIntervalSince1970: 0),
        windowEnd: Date(timeIntervalSince1970: 0)
    )

    var isEmpty: Bool {
        totalInBedMinutes == 0 && heartRateSampleCount == 0
    }
}
