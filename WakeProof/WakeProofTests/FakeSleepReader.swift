//
//  FakeSleepReader.swift
//  WakeProofTests
//
//  R11 (Wave 2.5): programmable fake conforming to `SleepReading` so tests don't
//  depend on simulator quirks (the "simulator returns no HealthKit data → empty
//  snapshot" assumption was implicit and would break on a future iOS / device-run
//  regression). The scheduler's `readSleepSafely` helper already swallows every
//  error back to `.empty`, so throwing from here is safe and exercised by setting
//  `nextResult = .failure(...)`.
//

import Foundation
@testable import WakeProof

/// Actor so concurrent setters/getters don't race. Mutations go through the
/// `setNextResult` async method rather than a direct property set.
///
/// `SleepSnapshot.empty` is main-actor-isolated under the project's default-actor
/// setting. We lazily build the initial "empty" value at first access rather than
/// referencing `.empty` from this non-main actor's initializer. Tests that care
/// about the initial state can explicitly pass `.success(.empty)` via the
/// `init(result:)` convenience overload from a main-actor context, or call
/// `setNextResult(.success(.empty))` which hops through the actor for them.
actor FakeSleepReader: SleepReading {

    private var nextResult: Result<SleepSnapshot, Error>? = nil

    /// Default: empty snapshot on first call. The snapshot is built locally here
    /// (not via `SleepSnapshot.empty`) to avoid main-actor isolation at init time.
    private static let defaultEmptySnapshot = SleepSnapshot(
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

    /// Initialize with no preloaded result — `lastNightSleep` returns an empty
    /// snapshot (matching what `SleepSnapshot.empty` holds). Tests override via
    /// `setNextResult`.
    init() {}

    /// Convenience initializer preloaded with a specific result.
    init(result: Result<SleepSnapshot, Error>) {
        self.nextResult = result
    }

    func setNextResult(_ result: Result<SleepSnapshot, Error>) {
        self.nextResult = result
    }

    func lastNightSleep() async throws -> SleepSnapshot {
        switch nextResult {
        case .some(.success(let snapshot)): return snapshot
        case .some(.failure(let error)): throw error
        case .none: return Self.defaultEmptySnapshot
        }
    }
}
