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

import XCTest
@testable import WakeProof

final class ManagedAgentBriefingSourceTests: XCTestCase {

    func testParseAgentReplyBothMarkers() {
        let raw = "BRIEFING: You slept 7h. Looked steady.\nMEMORY_UPDATE: User sleeps longer on Fridays."
        let (text, memory) = ManagedAgentBriefingSource.parseAgentReply(raw)
        XCTAssertEqual(text, "You slept 7h. Looked steady.")
        XCTAssertEqual(memory, "User sleeps longer on Fridays.")
    }

    func testParseAgentReplyMemoryUpdateNONE() {
        let raw = "BRIEFING: Quick verify expected.\nMEMORY_UPDATE: NONE"
        let (text, memory) = ManagedAgentBriefingSource.parseAgentReply(raw)
        XCTAssertEqual(text, "Quick verify expected.")
        XCTAssertNil(memory)
    }

    func testParseAgentReplyOnlyBriefingMarker() {
        let raw = "BRIEFING: Short and sweet."
        let (text, memory) = ManagedAgentBriefingSource.parseAgentReply(raw)
        XCTAssertEqual(text, "Short and sweet.")
        XCTAssertNil(memory)
    }

    func testParseAgentReplyNoMarkers() {
        let raw = "You had a restless night. Consider an earlier bedtime tonight."
        let (text, memory) = ManagedAgentBriefingSource.parseAgentReply(raw)
        XCTAssertEqual(text, "You had a restless night. Consider an earlier bedtime tonight.")
        XCTAssertNil(memory)
    }

    func testParseAgentReplyEmptyString() {
        let (text, memory) = ManagedAgentBriefingSource.parseAgentReply("")
        XCTAssertEqual(text, "")
        XCTAssertNil(memory)
    }

    func testParseAgentReplyLowercaseMarkers() {
        let raw = "briefing: lowercase test\nmemory_update: NONE"
        let (text, memory) = ManagedAgentBriefingSource.parseAgentReply(raw)
        XCTAssertEqual(text, "lowercase test")
        XCTAssertNil(memory)
    }
}
