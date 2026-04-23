//
//  MemoryEntryTests.swift
//  WakeProofTests
//

import XCTest
@testable import WakeProof

final class MemoryEntryTests: XCTestCase {

    private let fixedDate = Date(timeIntervalSince1970: 1_745_466_662)  // 2025-04-24T00:31:02Z

    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    func testRoundTrip() throws {
        let entry = MemoryEntry(
            timestamp: fixedDate,
            verdict: "VERIFIED",
            confidence: 0.82,
            retryCount: 0,
            note: "first morning, well-lit"
        )
        let data = try encoder.encode(entry)
        let decoded = try decoder.decode(MemoryEntry.self, from: data)
        XCTAssertEqual(entry, decoded)
    }

    func testEncodedKeysUseCompactNames() throws {
        let entry = MemoryEntry(
            timestamp: fixedDate, verdict: "REJECTED",
            confidence: 0.41, retryCount: 1, note: nil
        )
        let data = try encoder.encode(entry)
        let string = String(data: data, encoding: .utf8) ?? ""
        // Compact keys keep prompt token cost down across many history lines.
        XCTAssertTrue(string.contains("\"t\""))
        XCTAssertTrue(string.contains("\"v\""))
        XCTAssertTrue(string.contains("\"r\""))
        XCTAssertFalse(string.contains("\"timestamp\""))
    }

    func testMissingOptionalFieldsDecodeAsNil() throws {
        let minimal = #"{"t":"2025-04-24T00:31:02Z","v":"CAPTURED","r":0}"#
        let data = Data(minimal.utf8)
        let decoded = try decoder.decode(MemoryEntry.self, from: data)
        XCTAssertNil(decoded.confidence)
        XCTAssertNil(decoded.note)
        XCTAssertEqual(decoded.verdict, "CAPTURED")
    }

    func testUnknownFieldsAreIgnored() throws {
        // Future-proofing: adding a new field (e.g., "location") in v4 must not break v3 readers.
        let withExtra = #"{"t":"2025-04-24T00:31:02Z","v":"VERIFIED","r":0,"location":"kitchen"}"#
        let data = Data(withExtra.utf8)
        let decoded = try decoder.decode(MemoryEntry.self, from: data)
        XCTAssertEqual(decoded.verdict, "VERIFIED")
    }

    func testConfidencePrecisionPreserved() throws {
        let entry = MemoryEntry(
            timestamp: fixedDate, verdict: "VERIFIED",
            confidence: 0.7523456789, retryCount: 0, note: nil
        )
        let data = try encoder.encode(entry)
        let decoded = try decoder.decode(MemoryEntry.self, from: data)
        XCTAssertEqual(entry.confidence!, decoded.confidence!, accuracy: 1e-10)
    }

    // Note: the following two tests intentionally exercise the deprecated
    // `makeEntry(fromAttempt:)` factory to guard its behaviour for any caller
    // that still references it. Production code must NOT use this factory —
    // see the @available(deprecated) annotation on MemoryEntry for rationale.
    func testMakeEntryFromAttempt() {
        let attempt = WakeAttempt(scheduledAt: fixedDate)
        attempt.verdict = "VERIFIED"
        attempt.retryCount = 1
        let entry = MemoryEntry.makeEntry(
            timestamp: fixedDate,
            fromAttempt: attempt,
            confidence: 0.9,
            note: "second try after retry"
        )
        XCTAssertEqual(entry.verdict, "VERIFIED")
        XCTAssertEqual(entry.retryCount, 1)
        XCTAssertEqual(entry.confidence, 0.9)
        XCTAssertEqual(entry.note, "second try after retry")
        XCTAssertEqual(entry.timestamp, fixedDate)
    }

    func testMakeEntryHandlesNilVerdict() {
        // WakeAttempt.verdict is optional; a row that persists with no string should
        // map to the legacy .unresolved sentinel via the established fallback.
        let attempt = WakeAttempt(scheduledAt: fixedDate)
        attempt.verdict = nil
        let entry = MemoryEntry.makeEntry(
            timestamp: fixedDate, fromAttempt: attempt,
            confidence: nil, note: nil
        )
        XCTAssertEqual(entry.verdict, WakeAttempt.Verdict.unresolved.rawValue)
    }
}
