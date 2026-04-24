//
//  ManagedAgentBriefingSourceTests.swift
//  WakeProofTests
//
//  Unit tests for the pure `parseAgentReply` static function. The actor
//  wrapper itself is exercised end-to-end through OvernightSchedulerTests
//  (via the RecordingSource protocol conformance) and on-device during
//  Task B.6's compressed-night debug run — URL-stubbing the nested
//  OvernightAgentClient here would duplicate OvernightAgentClientTests
//  for no additional coverage.
//
//  B5.3 update: parseAgentReply now throws `OvernightAgentError.emptyBriefingResponse`
//  when the input is empty or the BRIEFING: marker has no prose after it. The
//  old silently-returning-("", nil) behaviour was masking Layer 3 failures
//  under the UI's fresh-install fallback. Empty-case tests updated to assert
//  the throw; happy-path tests unchanged except for `try`.
//

import XCTest
@testable import WakeProof

final class ManagedAgentBriefingSourceTests: XCTestCase {

    func testParseAgentReplyBothMarkers() throws {
        let raw = "BRIEFING: You slept 7h. Looked steady.\nMEMORY_UPDATE: User sleeps longer on Fridays."
        let (text, memory) = try ManagedAgentBriefingSource.parseAgentReply(raw)
        XCTAssertEqual(text, "You slept 7h. Looked steady.")
        XCTAssertEqual(memory, "User sleeps longer on Fridays.")
    }

    func testParseAgentReplyMemoryUpdateNONE() throws {
        let raw = "BRIEFING: Quick verify expected.\nMEMORY_UPDATE: NONE"
        let (text, memory) = try ManagedAgentBriefingSource.parseAgentReply(raw)
        XCTAssertEqual(text, "Quick verify expected.")
        XCTAssertNil(memory)
    }

    func testParseAgentReplyOnlyBriefingMarker() throws {
        let raw = "BRIEFING: Short and sweet."
        let (text, memory) = try ManagedAgentBriefingSource.parseAgentReply(raw)
        XCTAssertEqual(text, "Short and sweet.")
        XCTAssertNil(memory)
    }

    func testParseAgentReplyNoMarkers() throws {
        let raw = "You had a restless night. Consider an earlier bedtime tonight."
        let (text, memory) = try ManagedAgentBriefingSource.parseAgentReply(raw)
        XCTAssertEqual(text, "You had a restless night. Consider an earlier bedtime tonight.")
        XCTAssertNil(memory)
    }

    func testParseAgentReplyEmptyStringThrows() {
        // B5.3: empty input previously returned ("", nil) which cascaded into
        // an empty MorningBriefing row + cleaned-up session — judges saw the
        // fresh-install card as if Layer 3 was never wired. Now it throws.
        XCTAssertThrowsError(try ManagedAgentBriefingSource.parseAgentReply("")) { error in
            guard let agentError = error as? OvernightAgentError,
                  case .emptyBriefingResponse = agentError else {
                XCTFail("Expected .emptyBriefingResponse, got \(error)")
                return
            }
        }
    }

    func testParseAgentReplyWhitespaceOnlyThrows() {
        // Multi-line whitespace — content is effectively empty but the raw
        // string is non-empty. Must still throw.
        XCTAssertThrowsError(try ManagedAgentBriefingSource.parseAgentReply("  \n\t\n   ")) { error in
            guard let agentError = error as? OvernightAgentError,
                  case .emptyBriefingResponse = agentError else {
                XCTFail("Expected .emptyBriefingResponse, got \(error)")
                return
            }
        }
    }

    func testParseAgentReplyBriefingMarkerWithEmptyContentThrows() {
        // Marker present but nothing after it. This is the "agent emitted a
        // malformed reply" scenario — parseAgentReply must distinguish from
        // a completely-missing marker (which would be treated as raw prose).
        XCTAssertThrowsError(try ManagedAgentBriefingSource.parseAgentReply("BRIEFING:   \n")) { error in
            guard let agentError = error as? OvernightAgentError,
                  case .emptyBriefingResponse = agentError else {
                XCTFail("Expected .emptyBriefingResponse, got \(error)")
                return
            }
        }
    }

    func testParseAgentReplyBothMarkersEmptyBriefingThrows() {
        // Both markers present but BRIEFING content is whitespace-only.
        let raw = "BRIEFING:   \nMEMORY_UPDATE: Something real."
        XCTAssertThrowsError(try ManagedAgentBriefingSource.parseAgentReply(raw)) { error in
            guard let agentError = error as? OvernightAgentError,
                  case .emptyBriefingResponse = agentError else {
                XCTFail("Expected .emptyBriefingResponse, got \(error)")
                return
            }
        }
    }

    func testParseAgentReplyLowercaseMarkers() throws {
        let raw = "briefing: lowercase test\nmemory_update: NONE"
        let (text, memory) = try ManagedAgentBriefingSource.parseAgentReply(raw)
        XCTAssertEqual(text, "lowercase test")
        XCTAssertNil(memory)
    }

    /// L11 (Wave 2.5): pins the parser's CURRENT behaviour when Claude emits the
    /// markers in the wrong order (MEMORY_UPDATE: before BRIEFING:). The parser's
    /// "both markers present" branch requires `briefingRange.upperBound <= memoryRange.lowerBound`
    /// — when that ordering invariant is violated, the branch is skipped and the
    /// code falls through to the "just BRIEFING:" branch, which then slices from
    /// BRIEFING: to end-of-string (which includes the MEMORY_UPDATE: remnants as
    /// part of the briefing text). That means the briefing text ends up containing
    /// "X\nMEMORY_UPDATE: Y" verbatim; the memory update is lost.
    ///
    /// This is LLM-ordering-dependent behaviour — Claude is instructed to emit
    /// BRIEFING: first, so reversed order is a drift signal. Pinning here so a
    /// refactor that changes the fallback (e.g. adds proper two-marker-in-any-order
    /// handling) forces human review by failing this assertion.
    func testParseAgentReplyReversedMarkersProducesBestEffortBriefing() throws {
        let raw = "MEMORY_UPDATE: X\nBRIEFING: Y"
        let (text, memory) = try ManagedAgentBriefingSource.parseAgentReply(raw)
        // Current behavior: "just BRIEFING:" branch matches; everything after the
        // BRIEFING: marker (just "Y") becomes the briefing text. The MEMORY_UPDATE:
        // content sits BEFORE the briefing marker so it's not in the sliced region.
        XCTAssertEqual(text, "Y",
                       "reversed-order markers: briefing text is everything after BRIEFING: (current behavior pin)")
        XCTAssertNil(memory,
                     "reversed-order markers: memory_update is lost because the reversed ordering falls outside the both-markers branch")
    }
}
