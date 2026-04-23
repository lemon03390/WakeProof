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

    // MARK: - Test helpers

    private func makeAttempt() -> WakeAttempt {
        let attempt = WakeAttempt(scheduledAt: Date())
        attempt.imageData = Data([0xFF, 0xD8, 0xFF])
        attempt.verdict = WakeAttempt.Verdict.captured.rawValue
        context.insert(attempt)
        try? context.save()
        return attempt
    }

    /// Builds a `VerificationResult` with the happy-verified defaults; each test
    /// overrides only the fields it actually cares about. Previously every test
    /// inlined the 9-argument constructor with near-identical values, obscuring
    /// intent.
    private func makeResult(
        verdict: VerificationResult.Verdict,
        confidence: Double = 0.9,
        reasoning: String = "ok",
        sameLocation: Bool = true,
        personUpright: Bool = true,
        eyesOpen: Bool = true,
        appearsAlert: Bool = true,
        lightingSuggestsRoomLit: Bool = true
    ) -> VerificationResult {
        VerificationResult(
            sameLocation: sameLocation,
            personUpright: personUpright,
            eyesOpen: eyesOpen,
            appearsAlert: appearsAlert,
            lightingSuggestsRoomLit: lightingSuggestsRoomLit,
            confidence: confidence,
            reasoning: reasoning,
            spoofingRuledOut: nil,
            verdict: verdict
        )
    }

    private func enterVerifyingState() {
        scheduler.fireNow()
        scheduler.beginCapturing()
    }

    // MARK: - Verdict routing

    func testVerifiedVerdictTransitionsSchedulerToIdleAndUpdatesRow() async throws {
        let client = FakeClient(result: .success(makeResult(verdict: .verified, reasoning: "All good.")))
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
        let client = FakeClient(result: .success(makeResult(
            verdict: .rejected,
            confidence: 0.3,
            reasoning: "Different location.",
            sameLocation: false
        )))
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
        let client = FakeClient(result: .success(makeResult(
            verdict: .retry,
            confidence: 0.62,
            reasoning: "Unclear posture.",
            personUpright: false,
            appearsAlert: false
        )))
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
        let client = FakeClient(result: .success(makeResult(
            verdict: .retry,
            confidence: 0.6,
            reasoning: "Still unclear.",
            personUpright: false,
            appearsAlert: false
        )))
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

    func testMissingProxyTokenShowsConfigMessage() async {
        let client = FakeClient(result: .failure(ClaudeAPIError.missingProxyToken))
        let verifier = VisionVerifier(client: client)
        verifier.scheduler = scheduler
        enterVerifyingState()
        let attempt = makeAttempt()

        await verifier.verify(attempt: attempt, baseline: baseline, context: context)

        XCTAssertTrue(scheduler.lastCaptureError?.contains("Secrets.swift") == true)
    }

    func testResetForNewFireClearsCounter() async {
        let client = FakeClient(result: .success(makeResult(verdict: .retry)))
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

    // MARK: - State-machine + audit-trail integrity

    /// verify() must NOT call Claude if scheduler isn't in .capturing. Prevents
    /// burned credits + silently-refused scheduler transitions.
    func testVerifyBailsBeforeClaudeSpendWhenSchedulerNotInCapturing() async {
        let recorder = RecordingClient()
        let verifier = VisionVerifier(client: recorder)
        verifier.scheduler = scheduler
        // Scheduler is .idle (never entered .ringing/.capturing)
        let attempt = makeAttempt()

        await verifier.verify(attempt: attempt, baseline: baseline, context: context)

        XCTAssertEqual(recorder.callCount, 0, "verify() must NOT reach Claude when scheduler.phase != .capturing")
        XCTAssertEqual(scheduler.phase, .idle)
        XCTAssertEqual(attempt.verdictEnum, .captured, "attempt verdict must be unchanged when verify bails early")
    }

    /// finish() catch-all for unexpected verdicts must return to ringing rather
    /// than pinning the alarm in `.verifying`. Our current callers only emit
    /// `.verified` / `.rejected` / (RETRY via handleResult), but the defensive
    /// branch guards against a future refactor that introduces a new path.
    func testUnexpectedVerdictFallbackReturnsToRinging() async {
        let client = FakeClient(result: .success(makeResult(
            verdict: .rejected,
            confidence: 0.3,
            reasoning: "Rejected.",
            sameLocation: false
        )))
        let verifier = VisionVerifier(client: client)
        verifier.scheduler = scheduler
        enterVerifyingState()
        let attempt = makeAttempt()

        await verifier.verify(attempt: attempt, baseline: baseline, context: context)

        XCTAssertNotEqual(scheduler.phase, .verifying, "state machine must never leave alarm pinned in .verifying")
    }

    /// Anti-spoof re-entry must carry `currentAntiSpoofInstruction` into the
    /// second Claude call. Load-bearing for the product value prop: if the
    /// instruction isn't threaded through, the gesture verification is defeated.
    func testAntiSpoofInstructionCarriesIntoSecondClaudeCall() async {
        let retryResult = makeResult(
            verdict: .retry,
            confidence: 0.62,
            reasoning: "Unclear posture.",
            personUpright: false,
            appearsAlert: false
        )
        let verifiedResult = makeResult(verdict: .verified, reasoning: "Clear now.")
        let spy = InstructionSpyClient(results: [retryResult, verifiedResult])
        let verifier = VisionVerifier(client: spy)
        verifier.scheduler = scheduler
        enterVerifyingState()
        let attempt = makeAttempt()

        // First call — expect RETRY → anti-spoof prompt + instruction recorded
        await verifier.verify(attempt: attempt, baseline: baseline, context: context)
        guard case .antiSpoofPrompt = scheduler.phase else {
            return XCTFail("expected .antiSpoofPrompt after first RETRY")
        }
        XCTAssertEqual(spy.capturedInstructions.count, 1, "first call must have fired")
        XCTAssertNil(spy.capturedInstructions.first ?? "sentinel",
                     "first Claude call must carry antiSpoofInstruction=nil (no retry yet)")
        // Capture the chosen instruction now — the subsequent VERIFIED verdict calls
        // resetForNewFire() which clears currentAntiSpoofInstruction.
        let chosenInstruction = verifier.currentAntiSpoofInstruction
        XCTAssertNotNil(chosenInstruction, "RETRY must pick an instruction from the bank")

        // User taps "I'm ready" → re-enters capturing → re-invokes verify
        scheduler.beginCapturing()
        let retryAttempt = makeAttempt()
        await verifier.verify(attempt: retryAttempt, baseline: baseline, context: context)

        XCTAssertEqual(spy.capturedInstructions.count, 2, "second Claude call must have fired")
        XCTAssertEqual(spy.capturedInstructions.last ?? nil, chosenInstruction,
                       "second call's instruction must match the instruction chosen at RETRY time — this is the load-bearing anti-spoof invariant")
    }

    // MARK: - Layer 2 memory integration

    func testVerifyWithoutMemoryStoreCallsClientWithNilMemoryContext() async {
        let fake = RecordingClient(verdict: .verified)
        let verifier = VisionVerifier(client: fake)
        verifier.scheduler = scheduler
        verifier.memoryStore = nil
        let attempt = makeAttempt()
        context.insert(attempt)
        scheduler.fireNow()
        scheduler.beginCapturing()
        await verifier.verify(attempt: attempt, baseline: baseline, context: context)
        XCTAssertNil(fake.lastMemoryContext)
    }

    func testVerifyWithEmptyMemoryStoreStillCallsClientWithNilMemoryContext() async throws {
        let tmp = tempMemoryStoreRoot()
        let store = MemoryStore(configuration: .init(rootDirectory: tmp, userUUID: UUID().uuidString))
        try await store.bootstrapIfNeeded()
        let fake = RecordingClient(verdict: .verified)
        let verifier = VisionVerifier(client: fake)
        verifier.scheduler = scheduler
        verifier.memoryStore = store
        let attempt = makeAttempt()
        context.insert(attempt)
        scheduler.fireNow()
        scheduler.beginCapturing()
        await verifier.verify(attempt: attempt, baseline: baseline, context: context)
        XCTAssertNil(fake.lastMemoryContext,
                     "Empty snapshot → builder returns nil → client sees nil memoryContext")
    }

    func testVerifyWithPopulatedMemoryStorePassesRenderedBlock() async throws {
        let tmp = tempMemoryStoreRoot()
        let store = MemoryStore(configuration: .init(rootDirectory: tmp, userUUID: UUID().uuidString))
        try await store.bootstrapIfNeeded()
        try await store.rewriteProfile("PROFILE_MARKER")
        let fake = RecordingClient(verdict: .verified)
        let verifier = VisionVerifier(client: fake)
        verifier.scheduler = scheduler
        verifier.memoryStore = store
        let attempt = makeAttempt()
        context.insert(attempt)
        scheduler.fireNow()
        scheduler.beginCapturing()
        await verifier.verify(attempt: attempt, baseline: baseline, context: context)
        XCTAssertNotNil(fake.lastMemoryContext)
        XCTAssertTrue(fake.lastMemoryContext!.contains("PROFILE_MARKER"))
    }

    func testVerifiedWithMemoryUpdateWritesHistoryAndProfile() async throws {
        let tmp = tempMemoryStoreRoot()
        let store = MemoryStore(configuration: .init(rootDirectory: tmp, userUUID: UUID().uuidString))
        try await store.bootstrapIfNeeded()
        let update = VerificationResult.MemoryUpdate(
            profileDelta: "updated profile",
            historyNote: "weekend fast"
        )
        let fake = RecordingClient(verdict: .verified, memoryUpdate: update)
        let verifier = VisionVerifier(client: fake)
        verifier.scheduler = scheduler
        verifier.memoryStore = store
        let attempt = makeAttempt()
        context.insert(attempt)
        scheduler.fireNow()
        scheduler.beginCapturing()
        await verifier.verify(attempt: attempt, baseline: baseline, context: context)
        // Wait for the detached Task.
        try await Task.sleep(nanoseconds: 300_000_000)
        let snapshot = try await store.read()
        XCTAssertEqual(snapshot.profile, "updated profile")
        XCTAssertEqual(snapshot.recentHistory.first?.note, "weekend fast")
        // Verdict must reflect the Claude response's verdict, NOT the stale
        // "CAPTURED" value that attempt.verdict holds at memory-write time.
        XCTAssertEqual(snapshot.recentHistory.first?.verdict, "VERIFIED",
                       "Layer 2 history row must record the Claude verdict, not the stale pre-verify attempt.verdict")
        XCTAssertEqual(snapshot.recentHistory.first?.retryCount, 0,
                       "Verified on first try → retryCount = 0")
    }

    func testRetryVerdictWritesRetryRowWithBumpedRetryCount() async throws {
        let tmp = tempMemoryStoreRoot()
        let store = MemoryStore(configuration: .init(rootDirectory: tmp, userUUID: UUID().uuidString))
        try await store.bootstrapIfNeeded()
        let update = VerificationResult.MemoryUpdate(
            profileDelta: nil,
            historyNote: "groggy morning"
        )
        let fake = RecordingClient(verdict: .retry, memoryUpdate: update)
        let verifier = VisionVerifier(client: fake)
        verifier.scheduler = scheduler
        verifier.memoryStore = store
        let attempt = makeAttempt()
        // Simulate "this is the first call of this fire" — retryCount starts at 0,
        // updatePersistedAttempt will bump it to 1 when it runs after the switch.
        // Memory-write must reflect THAT future-bumped value, not the pre-bump 0.
        XCTAssertEqual(attempt.retryCount, 0)
        context.insert(attempt)
        scheduler.fireNow()
        scheduler.beginCapturing()
        await verifier.verify(attempt: attempt, baseline: baseline, context: context)
        try await Task.sleep(nanoseconds: 300_000_000)
        let snapshot = try await store.read()
        XCTAssertEqual(snapshot.recentHistory.first?.verdict, "RETRY",
                       "Layer 2 history row must record RETRY when Claude returned RETRY")
        XCTAssertEqual(snapshot.recentHistory.first?.retryCount, 1,
                       "RETRY must increment retryCount in the persisted history row to match updatePersistedAttempt")
        XCTAssertEqual(snapshot.recentHistory.first?.note, "groggy morning")
    }

    func testVerifiedWithoutMemoryUpdateDoesNotWrite() async throws {
        let tmp = tempMemoryStoreRoot()
        let store = MemoryStore(configuration: .init(rootDirectory: tmp, userUUID: UUID().uuidString))
        try await store.bootstrapIfNeeded()
        let fake = RecordingClient(verdict: .verified, memoryUpdate: nil)
        let verifier = VisionVerifier(client: fake)
        verifier.scheduler = scheduler
        verifier.memoryStore = store
        let attempt = makeAttempt()
        context.insert(attempt)
        scheduler.fireNow()
        scheduler.beginCapturing()
        await verifier.verify(attempt: attempt, baseline: baseline, context: context)
        try await Task.sleep(nanoseconds: 300_000_000)
        let snapshot = try await store.read()
        XCTAssertNil(snapshot.profile)
        XCTAssertTrue(snapshot.recentHistory.isEmpty)
    }

    private func tempMemoryStoreRoot() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("verifier-mem-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Fake client

    private final class FakeClient: ClaudeVisionClient {
        let result: Result<VerificationResult, Error>
        init(result: Result<VerificationResult, Error>) { self.result = result }
        func verify(baselineJPEG: Data, stillJPEG: Data, baselineLocation: String, antiSpoofInstruction: String?, memoryContext: String?) async throws -> VerificationResult {
            switch result {
            case .success(let r): return r
            case .failure(let e): throw e
            }
        }
    }

    /// Records every verify() invocation so tests can assert call-count invariants.
    /// `lastMemoryContext` is read by Layer 2 B.3 tests to assert the memory block
    /// threads through VisionVerifier. Verdict + memoryUpdate are init-parameterized
    /// so a single class covers both the REJECTED call-count paths and the VERIFIED
    /// memory-integration paths. Default `verdict: .rejected` keeps existing callers
    /// (`RecordingClient()`) working unchanged.
    private final class RecordingClient: ClaudeVisionClient {
        var callCount = 0
        var lastMemoryContext: String?
        let verdict: VerificationResult.Verdict
        let memoryUpdate: VerificationResult.MemoryUpdate?

        init(verdict: VerificationResult.Verdict = .rejected, memoryUpdate: VerificationResult.MemoryUpdate? = nil) {
            self.verdict = verdict
            self.memoryUpdate = memoryUpdate
        }

        func verify(baselineJPEG: Data, stillJPEG: Data, baselineLocation: String, antiSpoofInstruction: String?, memoryContext: String?) async throws -> VerificationResult {
            callCount += 1
            lastMemoryContext = memoryContext
            return VerificationResult(
                sameLocation: verdict == .verified, personUpright: verdict == .verified,
                eyesOpen: verdict == .verified, appearsAlert: verdict == .verified,
                lightingSuggestsRoomLit: verdict == .verified,
                confidence: verdict == .verified ? 0.9 : 0.5,
                reasoning: "recorder-stub",
                spoofingRuledOut: nil,
                verdict: verdict,
                memoryUpdate: memoryUpdate
            )
        }
    }

    /// Returns a different result per call and records the antiSpoofInstruction
    /// argument of each invocation. Lets us assert the instruction threads through
    /// the RETRY → antiSpoofPrompt → re-capture → verify chain.
    private final class InstructionSpyClient: ClaudeVisionClient {
        var results: [VerificationResult]
        var capturedInstructions: [String?] = []
        init(results: [VerificationResult]) { self.results = results }
        func verify(baselineJPEG: Data, stillJPEG: Data, baselineLocation: String, antiSpoofInstruction: String?, memoryContext: String?) async throws -> VerificationResult {
            capturedInstructions.append(antiSpoofInstruction)
            guard !results.isEmpty else {
                throw ClaudeAPIError.emptyResponse
            }
            return results.removeFirst()
        }
    }
}
