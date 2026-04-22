//
//  VerificationResultTests.swift
//  WakeProofTests
//

import XCTest
@testable import WakeProof

final class VerificationResultTests: XCTestCase {

    private let cleanJSON = """
    {
      "same_location": true,
      "person_upright": true,
      "eyes_open": true,
      "appears_alert": true,
      "lighting_suggests_room_lit": true,
      "confidence": 0.92,
      "reasoning": "Same kitchen counter; eyes open; alert posture.",
      "spoofing_ruled_out": ["photo-of-photo", "mannequin", "deepfake"],
      "verdict": "VERIFIED"
    }
    """

    func testCleanJSONDecodes() throws {
        let result = try XCTUnwrap(VerificationResult.fromClaudeMessageBody(cleanJSON))
        XCTAssertEqual(result.verdict, .verified)
        XCTAssertEqual(result.mapped, .verified)
        XCTAssertEqual(result.confidence, 0.92, accuracy: 0.001)
        XCTAssertEqual(result.spoofingRuledOut.count, 3)
    }

    func testFencedJSONBlockDecodes() throws {
        let fenced = "Here is the verdict:\n```json\n\(cleanJSON)\n```"
        let result = try XCTUnwrap(VerificationResult.fromClaudeMessageBody(fenced))
        XCTAssertEqual(result.verdict, .verified)
    }

    func testProseSurroundingJSONStillDecodes() throws {
        let messy = "I reasoned about the three spoofing paths and conclude:\n\n\(cleanJSON)\n\nThat's my verdict."
        let result = try XCTUnwrap(VerificationResult.fromClaudeMessageBody(messy))
        XCTAssertEqual(result.verdict, .verified)
    }

    func testMalformedJSONReturnsNil() {
        XCTAssertNil(VerificationResult.fromClaudeMessageBody("no json here"))
        XCTAssertNil(VerificationResult.fromClaudeMessageBody("{\"verdict\": \"VERIFIED\""), "unclosed brace")
    }

    func testRetryVerdictMapsToRetry() throws {
        let retryJSON = cleanJSON.replacingOccurrences(of: "\"VERIFIED\"", with: "\"RETRY\"")
        let result = try XCTUnwrap(VerificationResult.fromClaudeMessageBody(retryJSON))
        XCTAssertEqual(result.verdict, .retry)
        XCTAssertEqual(result.mapped, .retry)
    }

    func testRejectedVerdictMapsToRejected() throws {
        let rejectedJSON = cleanJSON.replacingOccurrences(of: "\"VERIFIED\"", with: "\"REJECTED\"")
        let result = try XCTUnwrap(VerificationResult.fromClaudeMessageBody(rejectedJSON))
        XCTAssertEqual(result.mapped, .rejected)
    }

    func testUnknownVerdictReturnsNil() {
        let junk = cleanJSON.replacingOccurrences(of: "\"VERIFIED\"", with: "\"WHATEVER\"")
        XCTAssertNil(VerificationResult.fromClaudeMessageBody(junk), "unknown verdict must fail decode — do not silently downgrade")
    }

    func testBracesInsideStringsDontFoolParser() throws {
        let tricky = """
        {
          "same_location": true,
          "person_upright": true,
          "eyes_open": true,
          "appears_alert": true,
          "lighting_suggests_room_lit": true,
          "confidence": 0.9,
          "reasoning": "User said: \\"it's 6am{braces}\\" — counter visible.",
          "spoofing_ruled_out": ["photo-of-photo"],
          "verdict": "VERIFIED"
        }
        """
        let result = try XCTUnwrap(VerificationResult.fromClaudeMessageBody(tricky))
        XCTAssertEqual(result.verdict, .verified)
    }
}
