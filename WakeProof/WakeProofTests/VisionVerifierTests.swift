//
//  VisionVerifierTests.swift
//  WakeProofTests
//

import XCTest
import SwiftData
import UIKit
@testable import WakeProof

@MainActor
final class VisionVerifierTests: XCTestCase {

    /// In-memory `ModelContainer` so tests don't touch the on-device SwiftData store.
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }
    private var scheduler: AlarmScheduler!
    private var baseline: BaselinePhoto!

    override func setUp() async throws {
        try await super.setUp()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: BaselinePhoto.self, WakeAttempt.self, configurations: config)
        UserDefaults.standard.removeObject(forKey: "com.wakeproof.alarm.lastFireAt")
        scheduler = AlarmScheduler()
        baseline = BaselinePhoto(imageData: Data([0xFF, 0xD8, 0xFF]), locationLabel: "kitchen")
        context.insert(baseline)
    }

    override func tearDown() async throws {
        scheduler.cancel()
        UserDefaults.standard.removeObject(forKey: "com.wakeproof.alarm.lastFireAt")
        scheduler = nil
        container = nil
        baseline = nil
        try await super.tearDown()
    }

    private func makeAttempt() -> WakeAttempt {
        let attempt = WakeAttempt(scheduledAt: Date())
        attempt.imageData = Data([0xFF, 0xD8, 0xFF])
        attempt.verdict = WakeAttempt.Verdict.captured.rawValue
        context.insert(attempt)
        try? context.save()
        return attempt
    }

    private func enterVerifyingState() {
        scheduler.fireNow()
        scheduler.beginCapturing()
    }

    // MARK: - Verdict routing

    func testVerifiedVerdictTransitionsSchedulerToIdleAndUpdatesRow() async throws {
        let result = VerificationResult(sameLocation: true, personUpright: true, eyesOpen: true,
                                        appearsAlert: true, lightingSuggestsRoomLit: true,
                                        confidence: 0.9, reasoning: "All good.",
                                        spoofingRuledOut: ["photo-of-photo", "mannequin", "deepfake"],
                                        verdict: .verified)
        let client = FakeClient(result: .success(result))
        let verifier = VisionVerifier(client: client)
        verifier.scheduler = scheduler
        enterVerifyingState()
        let attempt = makeAttempt()

        await verifier.verify(attempt: attempt, baseline: baseline, context: context)

        XCTAssertEqual(scheduler.phase, .idle)
        XCTAssertEqual(attempt.verdictEnum, .verified)
        XCTAssertEqual(attempt.verdictReasoning, "All good.")
    }

    func testRejectedVerdictReturnsToRingingWithError() async {
        let result = VerificationResult(sameLocation: false, personUpright: true, eyesOpen: true,
                                        appearsAlert: true, lightingSuggestsRoomLit: true,
                                        confidence: 0.3, reasoning: "Different location.",
                                        spoofingRuledOut: ["photo-of-photo", "mannequin", "deepfake"],
                                        verdict: .rejected)
        let client = FakeClient(result: .success(result))
        let verifier = VisionVerifier(client: client)
        verifier.scheduler = scheduler
        enterVerifyingState()
        let attempt = makeAttempt()

        await verifier.verify(attempt: attempt, baseline: baseline, context: context)

        XCTAssertEqual(scheduler.phase, .ringing)
        XCTAssertTrue(scheduler.lastCaptureError?.contains("Different location") == true)
        XCTAssertEqual(attempt.verdictEnum, .rejected)
    }

    func testRetryVerdictTransitionsToAntiSpoofPrompt() async {
        let result = VerificationResult(sameLocation: true, personUpright: false, eyesOpen: true,
                                        appearsAlert: false, lightingSuggestsRoomLit: true,
                                        confidence: 0.62, reasoning: "Unclear posture.",
                                        spoofingRuledOut: ["photo-of-photo", "mannequin", "deepfake"],
                                        verdict: .retry)
        let client = FakeClient(result: .success(result))
        let verifier = VisionVerifier(client: client)
        verifier.scheduler = scheduler
        enterVerifyingState()
        let attempt = makeAttempt()

        await verifier.verify(attempt: attempt, baseline: baseline, context: context)

        guard case let .antiSpoofPrompt(instruction) = scheduler.phase else {
            return XCTFail("expected phase=.antiSpoofPrompt, got \(scheduler.phase)")
        }
        XCTAssertFalse(instruction.isEmpty)
        XCTAssertEqual(verifier.currentAntiSpoofInstruction, instruction)
        XCTAssertEqual(attempt.retryCount, 1)
    }

    func testSecondRetryCoercesToRejected() async {
        let result = VerificationResult(sameLocation: true, personUpright: false, eyesOpen: true,
                                        appearsAlert: false, lightingSuggestsRoomLit: true,
                                        confidence: 0.6, reasoning: "Still unclear.",
                                        spoofingRuledOut: ["photo-of-photo", "mannequin", "deepfake"],
                                        verdict: .retry)
        let client = FakeClient(result: .success(result))
        let verifier = VisionVerifier(client: client)
        verifier.scheduler = scheduler
        enterVerifyingState()
        let attempt = makeAttempt()

        // First call: RETRY → anti-spoof prompt
        await verifier.verify(attempt: attempt, baseline: baseline, context: context)
        // User taps "I'm ready", re-enters capturing, fresh attempt
        scheduler.beginCapturing()
        let retryAttempt = makeAttempt()
        // Second call: RETRY again → coerced to REJECTED
        await verifier.verify(attempt: retryAttempt, baseline: baseline, context: context)

        XCTAssertEqual(scheduler.phase, .ringing)
        XCTAssertEqual(retryAttempt.verdictEnum, .rejected)
    }

    func testNetworkErrorIsClassifiedAsRejected() async {
        let client = FakeClient(result: .failure(ClaudeAPIError.timeout))
        let verifier = VisionVerifier(client: client)
        verifier.scheduler = scheduler
        enterVerifyingState()
        let attempt = makeAttempt()

        await verifier.verify(attempt: attempt, baseline: baseline, context: context)

        XCTAssertEqual(scheduler.phase, .ringing)
        XCTAssertEqual(attempt.verdictEnum, .rejected)
        XCTAssertTrue(scheduler.lastCaptureError?.contains("Couldn't reach Claude") == true)
    }

    func testMissingAPIKeyShowsConfigMessage() async {
        let client = FakeClient(result: .failure(ClaudeAPIError.missingAPIKey))
        let verifier = VisionVerifier(client: client)
        verifier.scheduler = scheduler
        enterVerifyingState()
        let attempt = makeAttempt()

        await verifier.verify(attempt: attempt, baseline: baseline, context: context)

        XCTAssertTrue(scheduler.lastCaptureError?.contains("Secrets.swift") == true)
    }

    func testResetForNewFireClearsCounter() async {
        let result = VerificationResult(sameLocation: true, personUpright: true, eyesOpen: true,
                                        appearsAlert: true, lightingSuggestsRoomLit: true,
                                        confidence: 0.9, reasoning: "ok",
                                        spoofingRuledOut: ["photo-of-photo", "mannequin", "deepfake"],
                                        verdict: .retry)
        let client = FakeClient(result: .success(result))
        let verifier = VisionVerifier(client: client)
        verifier.scheduler = scheduler
        enterVerifyingState()
        let attempt = makeAttempt()
        await verifier.verify(attempt: attempt, baseline: baseline, context: context)
        XCTAssertEqual(verifier.currentAttemptIndex, 1)

        verifier.resetForNewFire()
        XCTAssertEqual(verifier.currentAttemptIndex, 0)
        XCTAssertNil(verifier.currentAntiSpoofInstruction)
    }

    // MARK: - Fake client

    private final class FakeClient: ClaudeVisionClient {
        let result: Result<VerificationResult, Error>
        init(result: Result<VerificationResult, Error>) { self.result = result }
        func verify(baselineJPEG: Data, stillJPEG: Data, baselineLocation: String, antiSpoofInstruction: String?) async throws -> VerificationResult {
            switch result {
            case .success(let r): return r
            case .failure(let e): throw e
            }
        }
    }
}
