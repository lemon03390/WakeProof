//
//  VisionVerifierTests.swift
//  WakeProofTests
//

import XCTest
import SwiftData
import UIKit
@testable import WakeProof

// M11 (Wave 2.5): tests in this file use `Data([0xFF, 0xD8, 0xFF])` for baseline /
// still image data — a JPEG SOI (Start of Image) marker only, NOT a valid decodable
// image. This bypasses any UIImage-round-trip validation that future camera-pipeline
// code might add. Unit tests here are about VisionVerifier's state-machine and memory
// integration; they aren't meant to exercise image-decoding correctness. Actual
// image-validation coverage lives in device-only tests (see docs/device-test-protocol.md
// and docs/go-no-go-audio-test.md).
@MainActor
final class VisionVerifierTests: XCTestCase {

    /// In-memory `ModelContainer` so tests don't touch the on-device SwiftData store.
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }
    private var scheduler: AlarmScheduler!
    private var baseline: BaselinePhoto!
    /// R15 (Wave 2.5): per-run UserDefaults suite so the scheduler's lastFireAt
    /// marker (and any UserDefaults-backed queue state) doesn't bleed into `.standard`.
    private var suiteDefaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: BaselinePhoto.self, WakeAttempt.self, configurations: config)
        suiteName = "com.wakeproof.tests.visionverifier.\(UUID().uuidString)"
        suiteDefaults = UserDefaults(suiteName: suiteName)
        suiteDefaults.removePersistentDomain(forName: suiteName)
        scheduler = AlarmScheduler(defaults: suiteDefaults)
        baseline = BaselinePhoto(imageData: Data([0xFF, 0xD8, 0xFF]), locationLabel: "kitchen")
        context.insert(baseline)
    }

    override func tearDown() async throws {
        scheduler.cancel()
        suiteDefaults?.removePersistentDomain(forName: suiteName)
        suiteDefaults = nil
        suiteName = nil
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
        // M10 (Wave 2.5): network / transport errors inside VisionVerifier land in
        // `handleAPIError`, which calls `finish` WITHOUT bumping `currentAttemptIndex`
        // (the counter is only bumped in handleResult where Claude actually returned
        // a verdict). Verify the one-retry budget is intact so the user's legitimate
        // next "Prove you're awake" tap gets a fair first-try verdict rather than
        // hitting the second-RETRY coercion path. Same invariant applies to any of
        // `missingProxyToken / timeout / transportFailed / httpError / decodingFailed`.
        XCTAssertEqual(verifier.currentAttemptIndex, 0,
                       "network/config errors must NOT consume retry budget — handleAPIError skips the counter bump")
    }

    /// M10 follow-up: after a network error, a fresh `verify()` on a NEW fake that
    /// returns VERIFIED must succeed with verdict VERIFIED. Locks in the "retry budget
    /// intact" invariant at the end-to-end level rather than only probing the counter.
    /// Uses `.timeout` (vs. the config-message error above) to avoid the missing-token
    /// UI text leaking into the follow-up state.
    func testNetworkErrorThenSuccessReachesVerifiedVerdict() async {
        enterVerifyingState()
        let attempt = makeAttempt()

        // First call: transport/network error — network error maps to REJECTED, returns
        // alarm to .ringing. Counter stays at 0 (M10 invariant above).
        let errClient = FakeClient(result: .failure(ClaudeAPIError.timeout))
        let verifier = VisionVerifier(client: errClient)
        verifier.scheduler = scheduler
        await verifier.verify(attempt: attempt, baseline: baseline, context: context)
        XCTAssertEqual(verifier.currentAttemptIndex, 0, "network error must not consume retry budget")
        XCTAssertEqual(scheduler.phase, .ringing)

        // User taps "Prove you're awake" again → fresh capture with new attempt → VERIFIED.
        // Construct a second verifier with a success client (FakeClient takes its result at
        // init; simpler than a mutable pre-loaded array for a two-call sequence).
        let okClient = FakeClient(result: .success(makeResult(verdict: .verified, reasoning: "Clear now.")))
        let verifier2 = VisionVerifier(client: okClient)
        verifier2.scheduler = scheduler
        scheduler.beginCapturing()
        let attempt2 = makeAttempt()
        await verifier2.verify(attempt: attempt2, baseline: baseline, context: context)

        XCTAssertEqual(attempt2.verdictEnum, .verified,
                       "the second verify on an intact retry budget must reach VERIFIED — otherwise transient networks defeat the flow")
        XCTAssertEqual(scheduler.phase, .idle, "VERIFIED must finish the alarm")
    }

    /// L14 (Wave 2.5): when Claude returns `memory_update: {}` (both inner fields nil,
    /// but the envelope is non-nil), the production code in VisionVerifier still writes
    /// a history row with verdict+confidence+retryCount but an empty `note`. That row
    /// carries calibration signal (the fact that a VERIFIED was confident on this user)
    /// so it's intentional behavior, not a bug — this test pins it so a refactor that
    /// accidentally suppresses the row (e.g. "skip write when both inner fields nil")
    /// gets caught.
    func testEmptyMemoryUpdateStillAppendsHistoryRow() async throws {
        let tmp = tempMemoryStoreRoot()
        let store = MemoryStore(configuration: .init(rootDirectory: tmp, userUUID: UUID().uuidString))
        try await store.bootstrapIfNeeded()

        // Both inner fields nil — equivalent to `memory_update: {}` in the wire JSON.
        let update = VerificationResult.MemoryUpdate(profileDelta: nil, historyNote: nil)
        let fake = RecordingClient(verdict: .verified, memoryUpdate: update)
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
        XCTAssertEqual(snapshot.recentHistory.count, 1,
                       "empty memory_update {} still appends a history row — carries verdict/confidence/retryCount calibration signal")
        XCTAssertNil(snapshot.recentHistory.first?.note,
                     "note field must be nil when historyNote was absent in memory_update")
        XCTAssertNil(snapshot.profile,
                     "profile must NOT be rewritten when profileDelta was nil (even on VERIFIED)")
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
        let recorder = RecordingClient(verdict: .rejected)
        let verifier = VisionVerifier(client: recorder)
        verifier.scheduler = scheduler
        // Scheduler is .idle (never entered .ringing/.capturing)
        let attempt = makeAttempt()

        await verifier.verify(attempt: attempt, baseline: baseline, context: context)

        XCTAssertEqual(recorder.callCount, 0, "verify() must NOT reach Claude when scheduler.phase != .capturing")
        XCTAssertEqual(scheduler.phase, .idle)
        XCTAssertEqual(attempt.verdictEnum, .captured, "attempt verdict must be unchanged when verify bails early")
    }

    // M9 (Wave 2.5): `testUnexpectedVerdictFallbackReturnsToRinging` was deleted
    // here because its name advertised coverage of the catch-all defensive branch
    // in finish() / handleResult, but its body used `.rejected` — identical to
    // `testRejectedVerdictReturnsToRingingWithError` above. See the matching
    // comment in VisionVerifier.swift (handleResult's `.captured, .timeout,
    // .unresolved` branch) — that branch is unreachable by current
    // `VerificationResult.Verdict` cases and ships a `Logger.fault` as an audit
    // trail if VerdictEnum ever grows. Adding a test that could actually exercise
    // the branch would require constructing a `VerificationResult.Verdict` case
    // that doesn't exist yet, which defeats the point of the defensive fallback.

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

    // MARK: - P14: requiresReinstall signal on MemoryStoreError.invalidUserUUID

    /// P14 (Stage 6 Wave 2): the previous catch-all on `memoryStore.read()`
    /// swallowed `MemoryStoreError.invalidUserUUID` the same way it swallowed
    /// "file not found" (fresh install). That error is security-relevant —
    /// it fires when the UserDefaults-backed UUID was externally mutated
    /// (path-traversal guard refused to open the directory). Conflating the
    /// two meant a tampered UUID silently degraded to "verify without
    /// memory" with no user-visible signal.
    ///
    /// The fix splits the catch: `.invalidUserUUID` sets
    /// `verifier.requiresReinstall = true` (AlarmSchedulerView's systemBanner
    /// reads it as highest priority); all other errors keep the old behavior
    /// (log + nil memoryContext, proceed with verification).
    func testInvalidUserUUIDSetsRequiresReinstallFlag() async throws {
        // Construct a MemoryStore with an invalid UUID so `userDirectoryURL()`
        // throws `MemoryStoreError.invalidUserUUID`. The store itself is real;
        // we just seed an out-of-shape UUID to trip the guard.
        let tmp = tempMemoryStoreRoot()
        let tamperedStore = MemoryStore(configuration: .init(
            rootDirectory: tmp,
            userUUID: "../../etc/passwd"  // triggers MemoryStoreError.invalidUserUUID
        ))
        let fake = RecordingClient(verdict: .verified)
        let verifier = VisionVerifier(client: fake)
        verifier.scheduler = scheduler
        verifier.memoryStore = tamperedStore

        // Precondition: flag starts false on a fresh verifier.
        XCTAssertFalse(verifier.requiresReinstall, "fresh verifier must not have the flag set")

        let attempt = makeAttempt()
        context.insert(attempt)
        scheduler.fireNow()
        scheduler.beginCapturing()
        await verifier.verify(attempt: attempt, baseline: baseline, context: context)

        // Post: the specific error flipped the @Observable flag.
        XCTAssertTrue(verifier.requiresReinstall,
                      "invalidUserUUID must flip requiresReinstall so AlarmSchedulerView's banner surfaces the security warning")
        // Verification must STILL have proceeded (memory is ancillary — a
        // broken memory store must not brick the alarm).
        XCTAssertEqual(fake.callCount, 1,
                       "invalidUserUUID must not block the vision call — memory is ancillary; alarm must keep working")
        // And memoryContext must be nil since the read failed.
        XCTAssertNil(fake.lastMemoryContext,
                     "invalidUserUUID path must skip memoryContext injection")
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

    // MARK: - R1: profile rewrite gate on VERIFIED verdict

    /// The profile represents durable TRUTH about this user — only rewrite when
    /// we believe the verdict (VERIFIED). REJECTED/RETRY still append a history
    /// row (useful calibration signal) but must NOT override the profile:
    /// otherwise a failed spoof attempt, where Claude was fooled into emitting a
    /// profile_delta while correctly REJECTING the photo, would pollute durable
    /// state. Seed the store with a known profile; fire REJECTED + profileDelta;
    /// assert the profile is unchanged but the history row landed.
    func testRejectedVerdictDoesNotRewriteProfileEvenWithMemoryUpdate() async throws {
        let tmp = tempMemoryStoreRoot()
        let store = MemoryStore(configuration: .init(rootDirectory: tmp, userUUID: UUID().uuidString))
        try await store.bootstrapIfNeeded()
        try await store.rewriteProfile("SEED_PROFILE")

        let update = VerificationResult.MemoryUpdate(
            profileDelta: "EVIL OVERRIDE",
            historyNote: "attempted spoof"
        )
        let fake = RecordingClient(verdict: .rejected, memoryUpdate: update)
        let verifier = VisionVerifier(client: fake)
        verifier.scheduler = scheduler
        verifier.memoryStore = store
        enterVerifyingState()
        let attempt = makeAttempt()
        await verifier.verify(attempt: attempt, baseline: baseline, context: context)
        try await Task.sleep(nanoseconds: 300_000_000)

        let snapshot = try await store.read()
        XCTAssertEqual(snapshot.profile, "SEED_PROFILE",
                       "REJECTED verdict must NOT rewrite profile — prevents failed-spoof pollution (R1 fix)")
        XCTAssertEqual(snapshot.recentHistory.first?.note, "attempted spoof",
                       "history row must still land — it's a useful calibration signal even when verdict was REJECTED")
        XCTAssertEqual(snapshot.recentHistory.first?.verdict, "REJECTED")
    }

    // MARK: - R9: second-RETRY memory row reflects coerced REJECTED verdict

    /// handleResult's switch coerces a second RETRY verdict to REJECTED (one
    /// anti-spoof attempt per fire). Before the R9 fix, memory wrote the raw
    /// Claude verdict (RETRY) while updatePersistedAttempt wrote the coerced one
    /// (REJECTED), so history.jsonl and the SwiftData WakeAttempt diverged on
    /// the second-RETRY path. Simulate that path: first RETRY → antiSpoofPrompt
    /// → second RETRY → coerced REJECTED. Both the SwiftData verdict and the
    /// memory history row must say REJECTED.
    func testSecondRetryCoercedMemoryRowReflectsFinalRejection() async throws {
        let tmp = tempMemoryStoreRoot()
        let store = MemoryStore(configuration: .init(rootDirectory: tmp, userUUID: UUID().uuidString))
        try await store.bootstrapIfNeeded()

        // Both calls return RETRY + a memoryUpdate. Second call gets coerced to REJECTED.
        let update = VerificationResult.MemoryUpdate(profileDelta: nil, historyNote: "still unclear")
        let retryResult = makeResult(
            verdict: .retry,
            confidence: 0.6,
            reasoning: "Still unclear.",
            personUpright: false,
            appearsAlert: false
        )
        let coercedResult = VerificationResult(
            sameLocation: retryResult.sameLocation,
            personUpright: retryResult.personUpright,
            eyesOpen: retryResult.eyesOpen,
            appearsAlert: retryResult.appearsAlert,
            lightingSuggestsRoomLit: retryResult.lightingSuggestsRoomLit,
            confidence: retryResult.confidence,
            reasoning: retryResult.reasoning,
            spoofingRuledOut: retryResult.spoofingRuledOut,
            verdict: retryResult.verdict,
            memoryUpdate: update
        )
        let sequencedClient = SequencedClient(results: [coercedResult, coercedResult])
        let verifier = VisionVerifier(client: sequencedClient)
        verifier.scheduler = scheduler
        verifier.memoryStore = store
        enterVerifyingState()
        let firstAttempt = makeAttempt()

        // First call: RETRY → antiSpoofPrompt
        await verifier.verify(attempt: firstAttempt, baseline: baseline, context: context)
        guard case .antiSpoofPrompt = scheduler.phase else {
            return XCTFail("expected .antiSpoofPrompt after first RETRY, got \(scheduler.phase)")
        }

        // User taps "I'm ready" → re-enters capturing → fresh attempt
        scheduler.beginCapturing()
        let secondAttempt = makeAttempt()
        // Second call: RETRY again → coerced to REJECTED by handleResult
        await verifier.verify(attempt: secondAttempt, baseline: baseline, context: context)
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(secondAttempt.verdictEnum, .rejected,
                       "second RETRY must coerce the SwiftData row to REJECTED")

        let snapshot = try await store.read()
        // Two history rows were written (one per verify call). Both should exist.
        XCTAssertEqual(snapshot.recentHistory.count, 2,
                       "both verify calls should have written a memory history row")
        // The most-recent row must reflect the coerced REJECTED, not the raw RETRY.
        XCTAssertEqual(snapshot.recentHistory.last?.verdict, "REJECTED",
                       "coerced second-RETRY memory row must record REJECTED (R9 fix) — agrees with SwiftData")
    }

    /// SequencedClient returns the next result in order on each call. Lets tests
    /// drive the RETRY → re-verify → coerced-REJECTED path by pre-loading both
    /// results. Unlike InstructionSpyClient this variant doesn't record inputs —
    /// it exists solely to feed a two-call verdict sequence.
    private final class SequencedClient: ClaudeVisionClient {
        var results: [VerificationResult]
        init(results: [VerificationResult]) { self.results = results }
        func verify(baselineJPEG: Data, stillJPEG: Data, baselineLocation: String, antiSpoofInstruction: String?, memoryContext: String?) async throws -> VerificationResult {
            guard !results.isEmpty else { throw ClaudeAPIError.emptyResponse }
            return results.removeFirst()
        }
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
    /// memory-integration paths. Callers must pass `verdict` explicitly — no default —
    /// so a future test doesn't accidentally rely on an implicit .rejected default that
    /// hides intent.
    /// @MainActor: the class has mutable state (callCount, lastMemoryContext) that's
    /// read by the main-actor test body; @MainActor-annotating the class documents
    /// the test-only isolation invariant (all accesses stay on the main actor).
    @MainActor
    private final class RecordingClient: ClaudeVisionClient {
        var callCount = 0
        var lastMemoryContext: String?
        let verdict: VerificationResult.Verdict
        let memoryUpdate: VerificationResult.MemoryUpdate?

        init(verdict: VerificationResult.Verdict, memoryUpdate: VerificationResult.MemoryUpdate? = nil) {
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
    /// @MainActor: mutable `results` + `capturedInstructions` are accessed by the
    /// main-actor test body; annotation documents the test-only isolation invariant.
    @MainActor
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
