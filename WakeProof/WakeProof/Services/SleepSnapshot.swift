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

    /// M6 (Wave 2.6): short labels for sub-queries that THREW during collection
    /// (e.g. `["heartRate"]` when the HR query errored but the sleep query
    /// succeeded). Empty array means every sub-query completed. Rendered into
    /// the agent prompt as "Sleep data partial — queries that failed: [...]"
    /// so Claude doesn't reason from partial data as if it were complete.
    ///
    /// Codable with a default of `[]` (via the custom `init(from:)` below) so
    /// older JSON payloads lacking the field decode cleanly — the scheduler
    /// persists SleepSnapshot on disk between app runs and a schema break
    /// there would silently drop overnight briefings.
    let queryErrors: [String]

    enum CodingKeys: String, CodingKey {
        case totalInBedMinutes
        case awakeMinutes
        case heartRateAvg
        case heartRateMin
        case heartRateMax
        case heartRateSampleCount
        case hasAppleWatchData
        case windowStart
        case windowEnd
        case queryErrors
    }

    init(
        totalInBedMinutes: Int,
        awakeMinutes: Int,
        heartRateAvg: Double?,
        heartRateMin: Double?,
        heartRateMax: Double?,
        heartRateSampleCount: Int,
        hasAppleWatchData: Bool,
        windowStart: Date,
        windowEnd: Date,
        queryErrors: [String] = []
    ) {
        self.totalInBedMinutes = totalInBedMinutes
        self.awakeMinutes = awakeMinutes
        self.heartRateAvg = heartRateAvg
        self.heartRateMin = heartRateMin
        self.heartRateMax = heartRateMax
        self.heartRateSampleCount = heartRateSampleCount
        self.hasAppleWatchData = hasAppleWatchData
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.queryErrors = queryErrors
    }

    /// M6: custom decode so a pre-Wave-2.6 JSON payload (no `queryErrors` key)
    /// decodes to `[]` rather than failing. Symmetric with the default in the
    /// memberwise init above.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.totalInBedMinutes = try c.decode(Int.self, forKey: .totalInBedMinutes)
        self.awakeMinutes = try c.decode(Int.self, forKey: .awakeMinutes)
        self.heartRateAvg = try c.decodeIfPresent(Double.self, forKey: .heartRateAvg)
        self.heartRateMin = try c.decodeIfPresent(Double.self, forKey: .heartRateMin)
        self.heartRateMax = try c.decodeIfPresent(Double.self, forKey: .heartRateMax)
        self.heartRateSampleCount = try c.decode(Int.self, forKey: .heartRateSampleCount)
        self.hasAppleWatchData = try c.decode(Bool.self, forKey: .hasAppleWatchData)
        self.windowStart = try c.decode(Date.self, forKey: .windowStart)
        self.windowEnd = try c.decode(Date.self, forKey: .windowEnd)
        self.queryErrors = try c.decodeIfPresent([String].self, forKey: .queryErrors) ?? []
    }

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

    /// `isEmpty` measures data presence, not query health. A snapshot with an
    /// empty HR array because the query THREW still counts as empty here — the
    /// prompt renders both `isEmpty` AND `queryErrors` so Claude can tell the
    /// two apart. (If a future caller wants "complete OR errored?", expose a
    /// separate `isComplete` property.)
    var isEmpty: Bool {
        totalInBedMinutes == 0 && heartRateSampleCount == 0
    }
}
