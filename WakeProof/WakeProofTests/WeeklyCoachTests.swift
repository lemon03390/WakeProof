//
//  WeeklyCoachTests.swift
//  WakeProofTests
//
//  B6.T15 (Wave 2.5): existing tests updated to pass `skipChecksumValidation: true`
//  — they don't care about the seed/insight checksum agreement, only about
//  insight-loading / fallback paths. The two new checksum-aware tests
//  (`testChecksumMatchAcceptsInsight` / `testChecksumMismatchDropsInsight`)
//  exercise the validation branch that previously had 0% coverage.
//

import XCTest
@testable import WakeProof

final class WeeklyCoachTests: XCTestCase {

    private var fixtureURL: URL!

    private static let fixtureJSON = """
    {
      "generatedAt": "2026-04-24T10:00:00Z",
      "model": "claude-opus-4-7",
      "elapsedSeconds": 4.21,
      "inputTokens": 2987,
      "outputTokens": 261,
      "seedChecksum": "abcdef1234567890",
      "insight": {
        "insightText": "Your Mondays consistently take an extra verification attempt — this is a clear pattern over the last 14 days. Tuesdays through Sundays tend to verify on the first try with 85-90% confidence. Try shifting Sunday's bedtime forward by 30 minutes this week and see if the Monday friction drops.",
        "patternNoticed": "Mondays retry-heavy",
        "suggestedAction": "Earlier Sunday bedtime"
      }
    }
    """

    override func setUpWithError() throws {
        try super.setUpWithError()
        fixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-weekly-insight-\(UUID().uuidString).json")
        try Self.fixtureJSON.data(using: .utf8)!.write(to: fixtureURL)
    }

    override func tearDownWithError() throws {
        if let fixtureURL, FileManager.default.fileExists(atPath: fixtureURL.path) {
            try? FileManager.default.removeItem(at: fixtureURL)
        }
        try super.tearDownWithError()
    }

    @MainActor
    func testLoadsFromFixture() {
        let coach = WeeklyCoach(resourceURL: fixtureURL, skipChecksumValidation: true)
        let insight = coach.currentInsight
        XCTAssertNotNil(insight)
        XCTAssertTrue(insight?.insightText.contains("Mondays") ?? false)
        XCTAssertEqual(insight?.patternNoticed, "Mondays retry-heavy")
        XCTAssertEqual(insight?.suggestedAction, "Earlier Sunday bedtime")
    }

    @MainActor
    func testNilResourceURLProducesNoInsight() {
        let coach = WeeklyCoach(resourceURL: nil, skipChecksumValidation: true)
        XCTAssertNil(coach.currentInsight)
    }

    @MainActor
    func testMissingFileIsGraceful() {
        let missing = URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString).json")
        let coach = WeeklyCoach(resourceURL: missing, skipChecksumValidation: true)
        XCTAssertNil(coach.currentInsight)
    }

    @MainActor
    func testMalformedJsonIsGraceful() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bad-\(UUID().uuidString).json")
        try "{this is not json}".data(using: .utf8)!.write(to: tmp)
        let coach = WeeklyCoach(resourceURL: tmp, skipChecksumValidation: true)
        XCTAssertNil(coach.currentInsight)
    }

    @MainActor
    func testGeneratedAtExposedFromWrapper() throws {
        let coach = WeeklyCoach(resourceURL: fixtureURL, skipChecksumValidation: true)
        let generatedAt = try XCTUnwrap(coach.generatedAt)
        let iso = ISO8601DateFormatter()
        XCTAssertEqual(iso.string(from: generatedAt), "2026-04-24T10:00:00Z")
    }

    /// Verifies that optional fields (`patternNoticed`, `suggestedAction`) decode
    /// to nil when Claude's response has them as JSON null — a realistic case
    /// because the system prompt explicitly permits `null` for those fields.
    /// This sits alongside `testLoadsFromFixture` (where both are populated) to
    /// lock both shapes into the contract.
    @MainActor
    func testWrapperWithNullOptionalFields() throws {
        let nullableJSON = """
        {
          "generatedAt": "2026-04-24T10:00:00Z",
          "model": "claude-opus-4-7",
          "elapsedSeconds": 3.15,
          "inputTokens": 2800,
          "outputTokens": 140,
          "seedChecksum": "deadbeefcafef00d",
          "insight": {
            "insightText": "No strong pattern this week — verification stayed consistent across all 14 days.",
            "patternNoticed": null,
            "suggestedAction": null
          }
        }
        """
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nullable-\(UUID().uuidString).json")
        try nullableJSON.data(using: .utf8)!.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let coach = WeeklyCoach(resourceURL: tmp, skipChecksumValidation: true)
        let insight = try XCTUnwrap(coach.currentInsight)
        XCTAssertTrue(insight.insightText.contains("No strong pattern"))
        XCTAssertNil(insight.patternNoticed)
        XCTAssertNil(insight.suggestedAction)
    }

    // MARK: - B6.T15: checksum-validation coverage

    /// B6.T15 (Wave 2.5): exercises the happy-path checksum branch — insight's
    /// `seedChecksum` MATCHES the live seed's `sha256Prefix16`. WeeklyCoach must
    /// accept the insight (wrapper non-nil). Previously every existing test used
    /// a custom URL that silently skipped validation; this test is the first one
    /// that actually runs through the validation branch.
    ///
    /// Setup: write a seed fixture with known bytes, compute its checksum, then
    /// write an insight JSON with `seedChecksum` set to that computed value.
    /// Load with `skipChecksumValidation: false` → insight should load.
    @MainActor
    func testChecksumMatchAcceptsInsight() throws {
        // (1) Write a deterministic seed file with known bytes.
        let seedBytes = Data("FIXTURE-SEED-CONTENT-for-checksum-match-test".utf8)
        let seedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("checksum-match-seed-\(UUID().uuidString).json")
        try seedBytes.write(to: seedURL)
        defer { try? FileManager.default.removeItem(at: seedURL) }

        // (2) Compute its checksum using the same method WeeklyCoach uses.
        let expectedChecksum = WeeklyCoach.sha256Prefix16(seedBytes)

        // (3) Write an insight JSON whose seedChecksum matches.
        let insightJSON = """
        {
          "generatedAt": "2026-04-24T10:00:00Z",
          "model": "claude-opus-4-7",
          "elapsedSeconds": 4.0,
          "inputTokens": 1000,
          "outputTokens": 200,
          "seedChecksum": "\(expectedChecksum)",
          "insight": {
            "insightText": "Matched checksum — insight loads.",
            "patternNoticed": null,
            "suggestedAction": null
          }
        }
        """
        let insightURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("checksum-match-insight-\(UUID().uuidString).json")
        try insightJSON.data(using: .utf8)!.write(to: insightURL)
        defer { try? FileManager.default.removeItem(at: insightURL) }

        // (4) Inject both URLs; validation ON. Insight must load.
        let coach = WeeklyCoach(
            resourceURL: insightURL,
            seedURL: seedURL,
            skipChecksumValidation: false
        )
        let insight = try XCTUnwrap(coach.currentInsight,
                                    "checksum match should accept the insight — got nil wrapper")
        XCTAssertEqual(insight.insightText, "Matched checksum — insight loads.")
    }

    /// B6.T15 (Wave 2.5): exercises the rejection branch — insight's seedChecksum
    /// does NOT match the live seed's sha256Prefix16. WeeklyCoach must drop the
    /// wrapper (nil insight) so fallback UI renders rather than shipping stale
    /// calibration based on a pre-edit seed.
    ///
    /// Previously this branch had 0% coverage because every test used a custom
    /// resourceURL (which silently skipped the hardcoded bundle-equality check).
    /// A regression inverting `if liveChecksum != parsed.seedChecksum` to
    /// `if liveChecksum == parsed.seedChecksum` would have shipped silently.
    @MainActor
    func testChecksumMismatchDropsInsight() throws {
        // (1) Write seed A.
        let seedBytes = Data("SEED-A-REAL-BYTES".utf8)
        let seedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mismatch-seed-\(UUID().uuidString).json")
        try seedBytes.write(to: seedURL)
        defer { try? FileManager.default.removeItem(at: seedURL) }

        // (2) Compute seed B's checksum (a DIFFERENT payload) so we know seed A's
        // actual checksum won't match what's baked into the insight.
        let seedBBytes = Data("SEED-B-DIFFERENT-BYTES-entirely".utf8)
        let seedBChecksum = WeeklyCoach.sha256Prefix16(seedBBytes)

        // Sanity: the two checksums must differ or the test proves nothing.
        XCTAssertNotEqual(WeeklyCoach.sha256Prefix16(seedBytes), seedBChecksum,
                          "test invariant: seed A and seed B must have different checksums")

        // (3) Write an insight JSON claiming seed B's checksum while seed A is the live seed.
        let insightJSON = """
        {
          "generatedAt": "2026-04-24T10:00:00Z",
          "model": "claude-opus-4-7",
          "elapsedSeconds": 4.0,
          "inputTokens": 1000,
          "outputTokens": 200,
          "seedChecksum": "\(seedBChecksum)",
          "insight": {
            "insightText": "Tampered — should be dropped.",
            "patternNoticed": null,
            "suggestedAction": null
          }
        }
        """
        let insightURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mismatch-insight-\(UUID().uuidString).json")
        try insightJSON.data(using: .utf8)!.write(to: insightURL)
        defer { try? FileManager.default.removeItem(at: insightURL) }

        // (4) Load with validation ON → wrapper must be nil, insight must be nil.
        let coach = WeeklyCoach(
            resourceURL: insightURL,
            seedURL: seedURL,
            skipChecksumValidation: false
        )
        XCTAssertNil(coach.currentInsight,
                     "checksum mismatch must drop the insight — fallback UI relies on this signal to render staleness")
        XCTAssertNil(coach.generatedAt,
                     "generatedAt derives from the wrapper which stays nil on mismatch")
    }
}
