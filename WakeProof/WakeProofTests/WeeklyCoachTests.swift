//
//  WeeklyCoachTests.swift
//  WakeProofTests
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
        let coach = WeeklyCoach(resourceURL: fixtureURL)
        let insight = coach.currentInsight
        XCTAssertNotNil(insight)
        XCTAssertTrue(insight?.insightText.contains("Mondays") ?? false)
        XCTAssertEqual(insight?.patternNoticed, "Mondays retry-heavy")
        XCTAssertEqual(insight?.suggestedAction, "Earlier Sunday bedtime")
    }

    @MainActor
    func testNilResourceURLProducesNoInsight() {
        let coach = WeeklyCoach(resourceURL: nil)
        XCTAssertNil(coach.currentInsight)
    }

    @MainActor
    func testMissingFileIsGraceful() {
        let missing = URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString).json")
        let coach = WeeklyCoach(resourceURL: missing)
        XCTAssertNil(coach.currentInsight)
    }

    @MainActor
    func testMalformedJsonIsGraceful() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bad-\(UUID().uuidString).json")
        try "{this is not json}".data(using: .utf8)!.write(to: tmp)
        let coach = WeeklyCoach(resourceURL: tmp)
        XCTAssertNil(coach.currentInsight)
    }

    @MainActor
    func testGeneratedAtExposedFromWrapper() throws {
        let coach = WeeklyCoach(resourceURL: fixtureURL)
        let generatedAt = try XCTUnwrap(coach.generatedAt)
        let iso = ISO8601DateFormatter()
        XCTAssertEqual(iso.string(from: generatedAt), "2026-04-24T10:00:00Z")
    }
}
