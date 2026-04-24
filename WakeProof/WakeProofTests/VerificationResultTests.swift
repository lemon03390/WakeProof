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
        XCTAssertEqual(result.spoofingRuledOut?.count ?? 0, 3)
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

    /// L13 (Wave 2.5): the `Verdict` enum's raw values are all-uppercase. Because
    /// `Codable` raw-value decode is case-sensitive by default, Claude drifting to
    /// `"verified"` or `"Verified"` on a future model should fail the decode rather
    /// than silently map to `.verified`. If we ever need case-insensitive matching
    /// (e.g. Claude 5 emits mixed case), this test is the canary — a failure here
    /// forces explicit review rather than a silent downgrade.
    func testVerdictDecodingIsCaseSensitive() {
        let lowercase = cleanJSON.replacingOccurrences(of: "\"VERIFIED\"", with: "\"verified\"")
        XCTAssertNil(VerificationResult.fromClaudeMessageBody(lowercase),
                     "lowercase 'verified' must fail decode — Verdict rawValue is 'VERIFIED', case-sensitive")

        let mixedCase = cleanJSON.replacingOccurrences(of: "\"VERIFIED\"", with: "\"Verified\"")
        XCTAssertNil(VerificationResult.fromClaudeMessageBody(mixedCase),
                     "mixed-case 'Verified' must fail decode — prevents silent drift if Claude starts emitting title case")

        // Round-trip: explicit uppercase must STILL succeed (the canonical shape).
        XCTAssertNotNil(VerificationResult.fromClaudeMessageBody(cleanJSON),
                        "canonical uppercase 'VERIFIED' must continue to decode — baseline round-trip")
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

    // MARK: - Layer 2 memory_update parsing

    func testMemoryUpdatePresentDecodesBothFields() throws {
        let json = #"""
        {
          "same_location": true,
          "person_upright": true,
          "eyes_open": true,
          "appears_alert": true,
          "lighting_suggests_room_lit": true,
          "confidence": 0.9,
          "reasoning": "clear morning",
          "verdict": "VERIFIED",
          "memory_update": {
            "profile_delta": "User tends to wake alert on weekends.",
            "history_note": "weekend morning, fast verify"
          }
        }
        """#
        let result = try decode(json)
        XCTAssertNotNil(result.memoryUpdate)
        XCTAssertEqual(result.memoryUpdate?.profileDelta, "User tends to wake alert on weekends.")
        XCTAssertEqual(result.memoryUpdate?.historyNote, "weekend morning, fast verify")
    }

    func testMemoryUpdateAbsentIsNil() throws {
        // v1/v2 response shape — no memory_update field at all.
        let json = #"""
        {"same_location":true,"person_upright":true,"eyes_open":true,"appears_alert":true,"lighting_suggests_room_lit":true,"confidence":0.9,"reasoning":"x","verdict":"VERIFIED"}
        """#
        let result = try decode(json)
        XCTAssertNil(result.memoryUpdate)
    }

    func testMemoryUpdateEmptyObjectDecodesToBothNilInner() throws {
        let json = #"""
        {"same_location":true,"person_upright":true,"eyes_open":true,"appears_alert":true,"lighting_suggests_room_lit":true,"confidence":0.9,"reasoning":"x","verdict":"VERIFIED","memory_update":{}}
        """#
        let result = try decode(json)
        XCTAssertNotNil(result.memoryUpdate)
        XCTAssertNil(result.memoryUpdate?.profileDelta)
        XCTAssertNil(result.memoryUpdate?.historyNote)
    }

    func testMemoryUpdateNullDecodesToNilStruct() throws {
        let json = #"""
        {"same_location":true,"person_upright":true,"eyes_open":true,"appears_alert":true,"lighting_suggests_room_lit":true,"confidence":0.9,"reasoning":"x","verdict":"VERIFIED","memory_update":null}
        """#
        let result = try decode(json)
        XCTAssertNil(result.memoryUpdate)
    }

    func testMemoryUpdateUnknownInnerFieldsAreIgnored() throws {
        let json = #"""
        {"same_location":true,"person_upright":true,"eyes_open":true,"appears_alert":true,"lighting_suggests_room_lit":true,"confidence":0.9,"reasoning":"x","verdict":"VERIFIED","memory_update":{"profile_delta":"x","future_field":"ignored"}}
        """#
        let result = try decode(json)
        XCTAssertEqual(result.memoryUpdate?.profileDelta, "x")
    }

    func testMemoryUpdateOnlyProfileDeltaDecodes() throws {
        let json = #"""
        {"same_location":true,"person_upright":true,"eyes_open":true,"appears_alert":true,"lighting_suggests_room_lit":true,"confidence":0.9,"reasoning":"x","verdict":"VERIFIED","memory_update":{"profile_delta":"just profile"}}
        """#
        let result = try decode(json)
        XCTAssertEqual(result.memoryUpdate?.profileDelta, "just profile")
        XCTAssertNil(result.memoryUpdate?.historyNote)
    }

    func testMemoryUpdateOnlyHistoryNoteDecodes() throws {
        let json = #"""
        {"same_location":true,"person_upright":true,"eyes_open":true,"appears_alert":true,"lighting_suggests_room_lit":true,"confidence":0.9,"reasoning":"x","verdict":"VERIFIED","memory_update":{"history_note":"just note"}}
        """#
        let result = try decode(json)
        XCTAssertNil(result.memoryUpdate?.profileDelta)
        XCTAssertEqual(result.memoryUpdate?.historyNote, "just note")
    }

    // MARK: - M3 throwing variant

    /// M3 (Wave 2.6): `fromClaudeMessageBodyDetailed` throws instead of
    /// returning nil so callers (notably `ClaudeAPIClient`) can surface the
    /// specific field that failed decode. This is the key regression test: a
    /// body with a well-formed JSON object missing the `verdict` field must
    /// throw `DecodingError.keyNotFound` carrying a codingPath including the
    /// field name. Previously `try?` swallowed this and the user saw a
    /// generic "couldn't read response" with no trace.
    func testDetailedDecodeThrowsKeyNotFoundWithFieldInPath() {
        let missingVerdict = """
        {
          "same_location": true,
          "person_upright": true,
          "eyes_open": true,
          "appears_alert": true,
          "lighting_suggests_room_lit": true,
          "confidence": 0.9,
          "reasoning": "x"
        }
        """
        do {
            _ = try VerificationResult.fromClaudeMessageBodyDetailed(missingVerdict)
            XCTFail("expected DecodingError for missing verdict field")
        } catch let DecodingError.keyNotFound(key, _) {
            XCTAssertEqual(key.stringValue, "verdict",
                           "keyNotFound must name the missing field so log lines can point at it")
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    /// M3: no JSON object anywhere in the body → custom `noJSONObjectFound`
    /// rather than a DecodingError (since JSONDecoder never got invoked).
    /// Caller distinguishes this from a field-drift case.
    func testDetailedDecodeThrowsNoJSONObjectWhenBodyIsPlainProse() {
        do {
            _ = try VerificationResult.fromClaudeMessageBodyDetailed("I can't comply with that request.")
            XCTFail("expected noJSONObjectFound")
        } catch VerificationParseError.noJSONObjectFound {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    /// M3: type mismatch — confidence declared as String. DecodingError.typeMismatch
    /// carries a codingPath we expose via ClaudeAPIClient's log-formatting helper.
    func testDetailedDecodeThrowsTypeMismatchWhenFieldHasWrongType() {
        let wrongType = """
        {
          "same_location": true,
          "person_upright": true,
          "eyes_open": true,
          "appears_alert": true,
          "lighting_suggests_room_lit": true,
          "confidence": "high",
          "reasoning": "x",
          "verdict": "VERIFIED"
        }
        """
        do {
            _ = try VerificationResult.fromClaudeMessageBodyDetailed(wrongType)
            XCTFail("expected typeMismatch")
        } catch DecodingError.typeMismatch(_, let context) {
            XCTAssertTrue(context.codingPath.contains { $0.stringValue == "confidence" },
                          "typeMismatch codingPath must include the offending field")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    /// M3: shortcut preservation — nil-returning `fromClaudeMessageBody` is
    /// retained as a test convenience. Confirm it still returns nil on the
    /// exact same malformed input the detailed variant throws on.
    func testNilReturningShortcutSurvives() {
        XCTAssertNil(VerificationResult.fromClaudeMessageBody("I can't comply"))
    }

    // Helper used by the Layer 2 section above.
    private func decode(_ json: String) throws -> VerificationResult {
        guard let result = VerificationResult.fromClaudeMessageBody(json) else {
            throw TestDecodeError.returnedNil
        }
        return result
    }

    private enum TestDecodeError: Error { case returnedNil }
}
