//
//  MorningBriefingTests.swift
//  WakeProofTests
//

import SwiftData
import XCTest
@testable import WakeProof

final class MorningBriefingTests: XCTestCase {

    private var container: ModelContainer!

    override func setUpWithError() throws {
        let schema = Schema([MorningBriefing.self])
        let config = ModelConfiguration("briefing-tests", schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [config])
    }

    override func tearDownWithError() throws {
        container = nil
    }

    func testInsertAndFetch() throws {
        let context = ModelContext(container)
        let briefing = MorningBriefing(
            forWakeDate: Date(timeIntervalSince1970: 1_745_500_000),
            briefingText: "Today's insight: sleep was consistent.",
            sourceSessionID: "sess_abc",
            sleepSnapshotJSON: "{\"totalInBedMinutes\":420}"
        )
        context.insert(briefing)
        try context.save()
        let fetched = try context.fetch(FetchDescriptor<MorningBriefing>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.briefingText, "Today's insight: sleep was consistent.")
        XCTAssertEqual(fetched.first?.sourceSessionID, "sess_abc")
    }

    func testDefaultsAreSane() {
        let briefing = MorningBriefing(forWakeDate: .now, briefingText: "hi")
        XCTAssertFalse(briefing.memoryUpdateApplied)
        XCTAssertNil(briefing.sourceSessionID)
        XCTAssertNil(briefing.sleepSnapshotJSON)
    }

    func testSortByGeneratedAtIsReasonable() throws {
        let context = ModelContext(container)
        for i in 0..<5 {
            context.insert(MorningBriefing(
                generatedAt: Date(timeIntervalSince1970: 1_745_500_000 + TimeInterval(i * 60)),
                forWakeDate: Date(timeIntervalSince1970: 1_745_500_000),
                briefingText: "briefing-\(i)"
            ))
        }
        try context.save()
        let descriptor = FetchDescriptor<MorningBriefing>(sortBy: [SortDescriptor(\.generatedAt, order: .reverse)])
        let fetched = try context.fetch(descriptor)
        XCTAssertEqual(fetched.first?.briefingText, "briefing-4")
        XCTAssertEqual(fetched.last?.briefingText, "briefing-0")
    }

    // MARK: - P19: BriefingDTO failable init

    /// P19 (Stage 6 Wave 2): empty `briefingText` returns nil from the init.
    /// Before P19 the constructor was non-failable — callers could route an
    /// empty DTO into `.success`, which the UI would render as "No briefing
    /// this morning" identical to the no-session case. Moving the guard into
    /// the type makes "non-empty" a compile-time invariant.
    func testBriefingDTOFailsInitOnEmptyText() {
        let dto = BriefingDTO(
            briefingText: "",
            forWakeDate: Date(timeIntervalSince1970: 1_745_500_000),
            sourceSessionID: "sesn_test",
            memoryUpdateApplied: false
        )
        XCTAssertNil(dto, "empty briefingText must fail construction")
    }

    /// P19 (Stage 6 Wave 2): whitespace-only text trims to empty → init
    /// returns nil. Covers the agent-emits-only-padding pathology.
    func testBriefingDTOFailsInitOnWhitespaceOnly() {
        let dto = BriefingDTO(
            briefingText: "   \n\t  ",
            forWakeDate: Date(timeIntervalSince1970: 1_745_500_000),
            sourceSessionID: "sesn_test",
            memoryUpdateApplied: false
        )
        XCTAssertNil(dto, "whitespace-only briefingText must fail construction")
    }

    /// P19 (Stage 6 Wave 2): valid text yields a non-nil DTO with the
    /// original text preserved (not trimmed). Trimming inside the guard but
    /// storing the original lets downstream formatting (deliberate paragraph
    /// breaks) survive.
    func testBriefingDTOConstructsWithValidTextPreservingOriginal() {
        let raw = "  Valid briefing text with leading/trailing spaces  "
        let dto = BriefingDTO(
            briefingText: raw,
            forWakeDate: Date(timeIntervalSince1970: 1_745_500_000),
            sourceSessionID: "sesn_test",
            memoryUpdateApplied: true
        )
        XCTAssertNotNil(dto)
        XCTAssertEqual(dto?.briefingText, raw,
                       "original text must be preserved — guard only rejects empty-after-trim, not the text itself")
        XCTAssertEqual(dto?.memoryUpdateApplied, true)
    }
}
