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
}
