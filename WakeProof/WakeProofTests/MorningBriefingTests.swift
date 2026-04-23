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
}
