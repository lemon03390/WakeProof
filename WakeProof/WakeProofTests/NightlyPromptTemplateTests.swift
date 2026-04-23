//
//  NightlyPromptTemplateTests.swift
//  WakeProofTests
//

import XCTest
@testable import WakeProof

final class NightlyPromptTemplateTests: XCTestCase {

    private let fullSleep = SleepSnapshot(
        totalInBedMinutes: 420, awakeMinutes: 30,
        heartRateAvg: 58, heartRateMin: 48, heartRateMax: 75,
        heartRateSampleCount: 128, hasAppleWatchData: true,
        windowStart: Date(timeIntervalSince1970: 1_745_400_000),
        windowEnd: Date(timeIntervalSince1970: 1_745_425_200)
    )

    func testSystemPromptMentionsWakeProof() {
        XCTAssertTrue(NightlyPromptTemplate.v1.systemPrompt().contains("WakeProof"))
    }

    func testSystemPromptForbidsMedicalAdvice() {
        XCTAssertTrue(NightlyPromptTemplate.v1.systemPrompt().contains("medical"))
    }

    func testUserPromptIncludesSleepBlock() {
        let p = NightlyPromptTemplate.v1.userPrompt(
            sleep: fullSleep, memoryProfile: nil, priorBriefings: []
        )
        XCTAssertTrue(p.contains("Time in bed: 420"))
        XCTAssertTrue(p.contains("Apple Watch: yes"))
    }

    func testEmptySleepRendersDeclaratively() {
        let p = NightlyPromptTemplate.v1.userPrompt(
            sleep: .empty, memoryProfile: nil, priorBriefings: []
        )
        XCTAssertTrue(p.contains("No sleep data available"))
    }

    func testMemoryProfileIsWrappedInTags() {
        let p = NightlyPromptTemplate.v1.userPrompt(
            sleep: fullSleep, memoryProfile: "User wakes groggy on Mondays.",
            priorBriefings: []
        )
        XCTAssertTrue(p.contains("<memory_profile>"))
        XCTAssertTrue(p.contains("User wakes groggy on Mondays."))
    }

    func testPriorBriefingsAreLimitedToThree() {
        let priors = (0..<10).map { "briefing \($0)" }
        let p = NightlyPromptTemplate.v1.userPrompt(
            sleep: fullSleep, memoryProfile: nil, priorBriefings: priors
        )
        XCTAssertTrue(p.contains("briefing 0"))
        XCTAssertTrue(p.contains("briefing 2"))
        XCTAssertFalse(p.contains("briefing 3"))
    }
}
