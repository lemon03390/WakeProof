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
    /// B6.T15 (Wave 2.5): both `insightURL` and `seedURL` are now injectable,
    /// and the checksum-skip toggle is an explicit `skipChecksumValidation` flag
    /// instead of a hardcoded URL-equality comparison. This forces tests to be
    /// explicit about intent — either they seed a matching checksum (default
    /// behaviour now) or they opt out. Production boot in `WakeProofApp` relies
    /// on the defaults, which keep checksum validation ON.
    ///
    /// Previously every test used a custom URL, which silently skipped validation —
    /// meaning a regression flipping `if liveChecksum == parsed.seedChecksum`
    /// inverted would ship with 0% coverage. The new tests
    /// (`testChecksumMatchAcceptsInsight` / `testChecksumMismatchDropsInsight`)
    /// exercise both branches.
    init(
        resourceURL: URL? = WeeklyCoach.defaultResourceURL,
        seedURL: URL? = WeeklyCoach.defaultSeedURL,
        skipChecksumValidation: Bool = false
    ) {
        guard let resourceURL else {
            logger.info("WeeklyCoach: no resource URL, running without an insight")
            return
        }
        do {
            let data = try Data(contentsOf: resourceURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let parsed = try decoder.decode(Wrapper.self, from: data)

            // Validate the insight's `seedChecksum` matches the live seed file
            // unless the caller opted out. A mismatch means someone edited the
            // seed without re-running `scripts/generate-weekly-insight.py`, and
            // we drop the wrapper so fallback UI renders.
            if !skipChecksumValidation,
               let seedURL,
               let seedData = try? Data(contentsOf: seedURL) {
                let liveChecksum = WeeklyCoach.sha256Prefix16(seedData)
                if liveChecksum != parsed.seedChecksum {
                    logger.fault("WeeklyCoach: seedChecksum mismatch — live seed=\(liveChecksum, privacy: .public) insight=\(parsed.seedChecksum, privacy: .public). Dropping insight to force regeneration.")
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

    /// B6.T15 (Wave 2.5): extracted from the previous inline bundle-lookup so tests
    /// can swap in a fixture seed via `seedURL:`. Defaults to the live bundled
    /// `mock-wake-history-seed.json` — production WakeProofApp uses the default.
    nonisolated private static var defaultSeedURL: URL? {
        Bundle.main.url(forResource: "mock-wake-history-seed", withExtension: "json")
    }

    /// SHA-256 hex digest, first 16 chars — mirrors
    /// `hashlib.sha256(...).hexdigest()[:16]` in
    /// `scripts/generate-weekly-insight.py` so the two sides stay comparable.
    static func sha256Prefix16(_ data: Data) -> String {
        let hash = SHA256.hash(data: data)
        return String(hash.map { String(format: "%02x", $0) }.joined().prefix(16))
    }
}
