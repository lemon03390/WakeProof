//
//  WeeklyCoach.swift
//  WakeProof
//
//  Loads the dev-laptop-generated weekly-insight-seed.json from the app
//  bundle and exposes its parsed contents. Read-only at runtime; regeneration
//  is a dev-machine operation via scripts/generate-weekly-insight.py.
//

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
}
