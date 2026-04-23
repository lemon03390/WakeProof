//
//  WeeklyCoach.swift
//  WakeProof
//
//  Loads the dev-laptop-generated weekly-insight-seed.json from the app
//  bundle and exposes its parsed contents. Read-only at runtime; regeneration
//  is a dev-machine operation via scripts/generate-weekly-insight.py.
//

import CryptoKit
import Foundation
import Observation
import os

@Observable
@MainActor
final class WeeklyCoach {

    struct Insight: Codable, Equatable {
        let insightText: String
        let patternNoticed: String?
        let suggestedAction: String?
    }

    struct Wrapper: Codable, Equatable {
        let generatedAt: Date
        let model: String
        let elapsedSeconds: Double
        let inputTokens: Int
        let outputTokens: Int
        let seedChecksum: String
        let insight: Insight
    }

    private(set) var wrapper: Wrapper?
    private let logger = Logger(subsystem: "com.wakeproof.coach", category: "weekly")

    /// Injectable for tests — production uses the bundle resource. Referencing the
    /// concrete type (not `Self`) in the default argument sidesteps the Swift
    /// "covariant 'Self' cannot be referenced from a default argument" diagnostic,
    /// and marking the static accessor `nonisolated` lets it cross the MainActor
    /// boundary of the default-argument evaluation context.
    ///
    /// When `resourceURL` is the bundled default, the wrapper's `seedChecksum` is
    /// validated against the live bundled seed. A mismatch (someone edited the
    /// seed without re-running `scripts/generate-weekly-insight.py`) drops the
    /// wrapper so the fallback UI surfaces the staleness. Tests pass a custom URL
    /// and therefore skip the checksum check — the fixture-vs-bundled-seed
    /// mismatch would otherwise break every test run.
    init(resourceURL: URL? = WeeklyCoach.defaultResourceURL) {
        guard let resourceURL else {
            logger.info("WeeklyCoach: no resource URL, running without an insight")
            return
        }
        do {
            let data = try Data(contentsOf: resourceURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let parsed = try decoder.decode(Wrapper.self, from: data)

            // Only validate checksum when loading from the bundled default path.
            // Custom URLs (tests, previews) skip validation — otherwise the fixture
            // checksum would mismatch the live bundled seed and break the tests.
            let isBundledDefault = resourceURL == WeeklyCoach.defaultResourceURL
            if isBundledDefault,
               let seedURL = Bundle.main.url(forResource: "mock-wake-history-seed", withExtension: "json"),
               let seedData = try? Data(contentsOf: seedURL) {
                let liveChecksum = WeeklyCoach.sha256Prefix16(seedData)
                if liveChecksum != parsed.seedChecksum {
                    logger.fault("WeeklyCoach: seedChecksum mismatch — bundled seed=\(liveChecksum, privacy: .public) insight=\(parsed.seedChecksum, privacy: .public). Dropping insight to force regeneration.")
                    return  // self.wrapper stays nil → fallback UI renders
                }
            }

            self.wrapper = parsed
            logger.info("WeeklyCoach: loaded insight generatedAt=\(parsed.generatedAt.ISO8601Format(), privacy: .public) tokens=\(parsed.inputTokens, privacy: .public)in/\(parsed.outputTokens, privacy: .public)out")
        } catch {
            logger.error("WeeklyCoach: failed to load insight — \(error.localizedDescription, privacy: .public)")
        }
    }

    var currentInsight: Insight? { wrapper?.insight }
    var generatedAt: Date? { wrapper?.generatedAt }

    nonisolated private static var defaultResourceURL: URL? {
        Bundle.main.url(forResource: "weekly-insight-seed", withExtension: "json")
    }

    /// SHA-256 hex digest, first 16 chars — mirrors
    /// `hashlib.sha256(...).hexdigest()[:16]` in
    /// `scripts/generate-weekly-insight.py` so the two sides stay comparable.
    static func sha256Prefix16(_ data: Data) -> String {
        let hash = SHA256.hash(data: data)
        return String(hash.map { String(format: "%02x", $0) }.joined().prefix(16))
    }
}
