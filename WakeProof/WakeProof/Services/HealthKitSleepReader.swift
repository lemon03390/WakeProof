//
//  HealthKitSleepReader.swift
//  WakeProof
//
//  Reads last night's sleep + heart-rate signals from HealthKit. Returns a
//  SleepSnapshot the overnight agent can ingest as JSON. Never throws for the
//  "no data / permission denied" path — returns SleepSnapshot.empty. Throws only
//  for programmer-error cases (identifiers absent on this iOS version).
//
//  Actor so HKHealthStore access and any shared caches stay serialised.
//

import Foundation
import HealthKit
import os

/// R11 (Wave 2.5): abstraction so tests can swap in a deterministic fake instead of
/// relying on simulator quirks (the simulator's "no HealthKit data → empty snapshot"
/// behavior is implicit and could break across iOS major versions). Sendable + actor
/// conformance is required because `OvernightScheduler` is an actor that calls into
/// this across the actor boundary.
protocol SleepReading: Sendable {
    /// Read last-N-hours sleep + HR data. Default window 12h back on the production
    /// reader. Conformers may throw `HealthKitSleepReader.ReaderError` or a test-only
    /// equivalent; callers (`OvernightScheduler.readSleepSafely`) already swallow
    /// every error back to `.empty`.
    func lastNightSleep() async throws -> SleepSnapshot
}

actor HealthKitSleepReader: SleepReading {

    enum ReaderError: LocalizedError {
        case healthKitUnavailable
        case identifierUnresolvable(String)

        var errorDescription: String? {
            switch self {
            case .healthKitUnavailable:
                return "HealthKit is not available on this device."
            case .identifierUnresolvable(let id):
                return "HealthKit identifier \(id) is not known on this iOS version."
            }
        }
    }

    private let healthStore: HKHealthStore
    private let logger = Logger(subsystem: "com.wakeproof.overnight", category: "sleep-reader")

    init(healthStore: HKHealthStore = HKHealthStore()) {
        self.healthStore = healthStore
    }

    /// SleepReading protocol conformance — forwards to the default 12h window.
    /// Callers that need a different window still call `lastNightSleep(windowHours:)`
    /// directly, which is not part of the protocol.
    func lastNightSleep() async throws -> SleepSnapshot {
        try await lastNightSleep(windowHours: 12)
    }

    /// Read last-N-hours sleep + HR data. Default window 12 h back.
    func lastNightSleep(windowHours: Int = 12) async throws -> SleepSnapshot {
        logger.info("Fetching sleep samples: window=\(windowHours, privacy: .public)h")

        guard HKHealthStore.isHealthDataAvailable() else {
            logger.info("HealthKit unavailable on this device; returning empty snapshot")
            return .empty
        }

        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            logger.error("HealthKit read failed: sleepAnalysis identifier unresolvable on this iOS version")
            throw ReaderError.identifierUnresolvable("sleepAnalysis")
        }
        guard let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate) else {
            logger.error("HealthKit read failed: heartRate identifier unresolvable on this iOS version")
            throw ReaderError.identifierUnresolvable("heartRate")
        }

        let end = Date.now
        let start = end.addingTimeInterval(-Double(windowHours) * 3600)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictEndDate)

        let sleepSamples: [HKCategorySample]
        do {
            sleepSamples = try await querySamples(type: sleepType, predicate: predicate)
        } catch {
            logger.error("HealthKit sleep query failed: \(error.localizedDescription, privacy: .public); continuing with empty sleep samples")
            sleepSamples = []
        }

        let hrSamples: [HKQuantitySample]
        do {
            hrSamples = try await queryQuantities(type: heartRateType, predicate: predicate)
        } catch {
            logger.error("HealthKit HR query failed: \(error.localizedDescription, privacy: .public); continuing with empty HR samples")
            hrSamples = []
        }

        // Log counts only — NEVER raw sample bodies (privacy).
        logger.info("Fetched \(sleepSamples.count, privacy: .public) sleep samples, \(hrSamples.count, privacy: .public) HR samples")

        return aggregate(sleepSamples: sleepSamples, hrSamples: hrSamples, windowStart: start, windowEnd: end)
    }

    /// Pure aggregation. Exposed `internal` so tests can drive it with synthetic samples
    /// — the underlying HKHealthStore query is hard to stub without a bigger harness.
    nonisolated func aggregate(
        sleepSamples: [HKCategorySample],
        hrSamples: [HKQuantitySample],
        windowStart: Date,
        windowEnd: Date
    ) -> SleepSnapshot {
        let (inBed, awake) = Self.summariseSleepCategory(samples: sleepSamples)

        var avg: Double? = nil
        var min: Double? = nil
        var max: Double? = nil
        if !hrSamples.isEmpty {
            let bpmUnit = HKUnit.count().unitDivided(by: .minute())
            let values = hrSamples.map { $0.quantity.doubleValue(for: bpmUnit) }
            let total = values.reduce(0, +)
            avg = total / Double(values.count)
            min = values.min()
            max = values.max()
        }

        let hasAW = sleepSamples.contains { sample in
            sample.sourceRevision.productType?.contains("Watch") ?? false
        }

        return SleepSnapshot(
            totalInBedMinutes: inBed,
            awakeMinutes: awake,
            heartRateAvg: avg,
            heartRateMin: min,
            heartRateMax: max,
            heartRateSampleCount: hrSamples.count,
            hasAppleWatchData: hasAW,
            windowStart: windowStart,
            windowEnd: windowEnd
        )
    }

    // MARK: - Private

    private func querySamples(type: HKCategoryType, predicate: NSPredicate) async throws -> [HKCategorySample] {
        try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, results, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: (results as? [HKCategorySample]) ?? [])
            }
            healthStore.execute(q)
        }
    }

    private func queryQuantities(type: HKQuantityType, predicate: NSPredicate) async throws -> [HKQuantitySample] {
        try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, results, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: (results as? [HKQuantitySample]) ?? [])
            }
            healthStore.execute(q)
        }
    }

    private static func summariseSleepCategory(samples: [HKCategorySample]) -> (inBedMinutes: Int, awakeMinutes: Int) {
        var inBed = 0.0
        var awake = 0.0
        for sample in samples {
            let minutes = sample.endDate.timeIntervalSince(sample.startDate) / 60.0
            // HKCategoryValueSleepAnalysis raw values: inBed=0, asleep*=1-4 (iOS 16+), awake=5 (iOS 16+).
            // We pool "inBed" + all "asleep*" into inBed; "awake" stays awake.
            switch sample.value {
            case HKCategoryValueSleepAnalysis.inBed.rawValue,
                 HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                 HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                 HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                 HKCategoryValueSleepAnalysis.asleepREM.rawValue:
                inBed += minutes
            case HKCategoryValueSleepAnalysis.awake.rawValue:
                awake += minutes
            default:
                break
            }
        }
        return (Int(inBed.rounded()), Int(awake.rounded()))
    }
}
