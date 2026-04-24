//
//  OvernightSchedulerTests.swift
//  WakeProofTests
//
//  Scheduler tests use a recording-fake OvernightBriefingSource that captures
//  every call (with its arguments) and can be programmed to return canned
//  values. The real HealthKitSleepReader is used unchanged — on the test
//  simulator it either reports HealthKit unavailable (returns `.empty`) or
//  fails the inner query (scheduler's `try?` catches and also falls back to
//  `.empty`), so the test surface is deterministic regardless.
//
//  `handleBackgroundRefresh` is NOT tested here — iOS forbids constructing
//  real `BGProcessingTask` instances in unit tests (the initialiser is
//  unavailable). Task B.6's compressed-night debug button exercises that
//  path end-to-end on device.
//

import BackgroundTasks
import SwiftData
import XCTest
@testable import WakeProof

final class OvernightSchedulerTests: XCTestCase {

    // MARK: - BGTask launch-handler registration
    //
    // Phase B.1 moved BGTaskScheduler registration into `WakeProofApp.init()`.
    // Since the unit-test target is hosted by `WakeProof.app` (TEST_HOST set in
    // the project), the app's `init()` runs when the test process launches and
    // registers the identifier before any test can. `register(forTaskWithIdentifier:)`
    // raises NSInternalInconsistencyException on duplicate registration, so the
    // tests must NOT call `register(...)` again — previously this was a stub
    // here for Phase A where init() didn't wire it yet.

    // MARK: - Recording fake source

    /// Records every OvernightBriefingSource call. Tests assert on the
    /// recorded `calls` array. `nextHandle`, `fetchResult`, and
    /// `pokeResult` can be rewritten per-test to program return values.
    actor RecordingSource: OvernightBriefingSource {

        struct PlanCall: Equatable {
            let sleep: SleepSnapshot
            let memoryProfile: String?
        }

        struct PokeCall: Equatable {
            let handle: String
            let sleep: SleepSnapshot
        }

        private(set) var planCalls: [PlanCall] = []
        private(set) var pokeCalls: [PokeCall] = []
        private(set) var fetchCalls: [String] = []
        private(set) var cleanupCalls: [String] = []

        var nextHandle: String = "handle-default"
        var fetchResult: (text: String, memoryUpdate: String?) = ("default briefing", nil)
        var pokeResult: Bool = true
        var planThrows: Error?
        var fetchThrows: Error?
        /// P6 (Stage 6 Wave 1): programmable throw for the poke path so tests
        /// can exercise handleRefresh's catch branch which surfaces via
        /// `_lastRefreshError`.
        var pokeThrows: Error?
        /// P9 (Stage 6 Wave 1): programmable throw for the cleanup path so
        /// tests can exercise the retain-vs-abandon logic.
        var cleanupThrows: Error?
        /// P9: count of cleanup invocations that *should have thrown* — because
        /// the non-throwing `cleanup` just forwards to `cleanupThrowing` and
        /// swallows, tests that need to distinguish success from retained-handle
        /// outcomes read this counter.
        private(set) var cleanupThrowingCalls: Int = 0

        func planOvernight(sleep: SleepSnapshot, memoryProfile: String?) async throws -> String {
            planCalls.append(PlanCall(sleep: sleep, memoryProfile: memoryProfile))
            if let planThrows { throw planThrows }
            return nextHandle
        }

        func pokeIfNeeded(handle: String, sleep: SleepSnapshot) async throws -> Bool {
            pokeCalls.append(PokeCall(handle: handle, sleep: sleep))
            if let pokeThrows { throw pokeThrows }
            return pokeResult
        }

        func fetchBriefing(handle: String) async throws -> (text: String, memoryUpdate: String?) {
            fetchCalls.append(handle)
            if let fetchThrows { throw fetchThrows }
            return fetchResult
        }

        func cleanup(handle: String) async {
            cleanupCalls.append(handle)
            // Record attempts but the non-throwing variant must not surface
            // errors — protocol contract preserved.
        }

        /// P9 (Stage 6 Wave 1): override the protocol's default-implementation
        /// forwarding so tests can programme this fake to actually throw. The
        /// default protocol extension forwards `cleanupThrowing` → `cleanup`
        /// (non-throwing), which would never exercise the scheduler's retain
        /// path. By overriding explicitly we get full control.
        func cleanupThrowing(handle: String) async throws {
            cleanupCalls.append(handle)
            cleanupThrowingCalls += 1
            if let cleanupThrows { throw cleanupThrows }
        }

        // Test setters — need to be inside the actor so mutation is isolated.
        func setNextHandle(_ handle: String) { self.nextHandle = handle }
        func setFetchResult(_ result: (text: String, memoryUpdate: String?)) { self.fetchResult = result }
        func setFetchThrows(_ error: Error?) { self.fetchThrows = error }
        func setPlanThrows(_ error: Error?) { self.planThrows = error }
        func setPokeThrows(_ error: Error?) { self.pokeThrows = error }
        func setCleanupThrows(_ error: Error?) { self.cleanupThrows = error }
    }

    /// P17 (Stage 6 Wave 2): source that suspends `pokeIfNeeded` on a
    /// CheckedContinuation so the test can fire expiration WHILE the actor
    /// is blocked inside poke. All other protocol methods are no-ops — this
    /// fake is purpose-built for the expiration-race test.
    ///
    /// The flag-based "entered" signal lets the test spin until the actor
    /// has definitely suspended inside the continuation — without it, the
    /// test could race the scheduler's executor and fire expiration before
    /// poke even started.
    actor BlockingPokeSource: OvernightBriefingSource {
        private(set) var pokeEntered: Bool = false
        private var continuation: CheckedContinuation<Void, Never>?

        func planOvernight(sleep: SleepSnapshot, memoryProfile: String?) async throws -> String {
            "unused-in-p17-test"
        }

        func pokeIfNeeded(handle: String, sleep: SleepSnapshot) async throws -> Bool {
            pokeEntered = true
            await withCheckedContinuation { cont in
                self.continuation = cont
            }
            return false
        }

        func fetchBriefing(handle: String) async throws -> (text: String, memoryUpdate: String?) {
            ("unused-in-p17-test", nil)
        }

        func cleanup(handle: String) async {
            // no-op
        }

        /// Test helper — resume the continuation so the scheduler's
        /// `pokeIfNeeded` await returns and the actor proceeds through the
        /// post-await latch check.
        func resumePoke() {
            continuation?.resume()
            continuation = nil
        }
    }

    // MARK: - Test plumbing

    private var suiteDefaults: UserDefaults!
    private let suiteName = "com.wakeproof.tests.scheduler"
    private var memoryRoot: URL!
    private var container: ModelContainer!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteDefaults = UserDefaults(suiteName: suiteName)
        suiteDefaults.removePersistentDomain(forName: suiteName)
        memoryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wakeproof-scheduler-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: memoryRoot, withIntermediateDirectories: true)
        let schema = Schema([BaselinePhoto.self, WakeAttempt.self, MorningBriefing.self])
        let config = ModelConfiguration("scheduler-tests", schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [config])
    }

    override func tearDownWithError() throws {
        suiteDefaults?.removePersistentDomain(forName: suiteName)
        suiteDefaults = nil
        if let memoryRoot, FileManager.default.fileExists(atPath: memoryRoot.path) {
            try? FileManager.default.removeItem(at: memoryRoot)
        }
        memoryRoot = nil
        container = nil
        try super.tearDownWithError()
    }

    private func makeMemoryStore(uuid: String = UUID().uuidString) -> MemoryStore {
        MemoryStore(configuration: .init(
            rootDirectory: memoryRoot,
            userUUID: uuid,
            historyReadLimit: 5,
            profileMaxBytes: 16 * 1024
        ))
    }

    private func makeScheduler(
        source: RecordingSource,
        memoryStore: MemoryStore? = nil,
        sleepReader: any SleepReading = FakeSleepReader()
    ) -> OvernightScheduler {
        OvernightScheduler(
            source: source,
            sleepReader: sleepReader,
            memoryStore: memoryStore ?? makeMemoryStore(),
            defaults: suiteDefaults
        )
    }

    // MARK: - startOvernightSession

    func testStartOvernightSessionCallsPlanOvernightAndPersistsHandle() async throws {
        let source = RecordingSource()
        await source.setNextHandle("session-alpha")
        let scheduler = makeScheduler(source: source)

        await scheduler.startOvernightSession()

        let planCalls = await source.planCalls
        XCTAssertEqual(planCalls.count, 1, "planOvernight must be called exactly once per bedtime trigger")
        XCTAssertEqual(suiteDefaults.string(forKey: OvernightScheduler.activeHandleKey), "session-alpha")
    }

    /// R11 (Wave 2.5): previously this test relied on "simulator has no HealthKit
    /// data → HealthKitSleepReader returns empty snapshot" — an implicit assumption
    /// that would break on a future iOS change or a real-device CI run. Fixed by
    /// swapping in a `FakeSleepReader` (see `FakeSleepReader.swift`) with a known
    /// non-empty snapshot, then asserting the exact values flow through to the
    /// agent session's seed message. Tests both the sleep-plumbing AND the memory-
    /// plumbing in the same call.
    func testStartOvernightSessionPassesSleepAndMemoryCorrectly() async throws {
        // Seed the memory store with a profile so the scheduler forwards it.
        let uuid = UUID().uuidString
        let memoryStore = makeMemoryStore(uuid: uuid)
        try await memoryStore.rewriteProfile("## Observations\nUser sleeps best on weekends.")

        // Seed a deterministic non-empty SleepSnapshot so we can assert exact values.
        let windowStart = Date(timeIntervalSince1970: 1_745_500_000)
        let windowEnd = windowStart.addingTimeInterval(12 * 3600)
        let seededSleep = SleepSnapshot(
            totalInBedMinutes: 465,
            awakeMinutes: 12,
            heartRateAvg: 58.5,
            heartRateMin: 48.0,
            heartRateMax: 74.0,
            heartRateSampleCount: 88,
            hasAppleWatchData: true,
            windowStart: windowStart,
            windowEnd: windowEnd
        )
        let fakeReader = FakeSleepReader(result: .success(seededSleep))

        let source = RecordingSource()
        await source.setNextHandle("session-beta")
        let scheduler = makeScheduler(source: source, memoryStore: memoryStore, sleepReader: fakeReader)

        await scheduler.startOvernightSession()

        let planCalls = await source.planCalls
        XCTAssertEqual(planCalls.count, 1)

        // Assert every seeded field flowed through untouched — no accidental
        // re-shaping between `sleepReader.lastNightSleep()` and `source.planOvernight`.
        let sleep = try XCTUnwrap(planCalls.first?.sleep, "planOvernight must be called with a SleepSnapshot, not nil")
        XCTAssertEqual(sleep.totalInBedMinutes, 465)
        XCTAssertEqual(sleep.awakeMinutes, 12)
        XCTAssertEqual(sleep.heartRateAvg, 58.5)
        XCTAssertEqual(sleep.heartRateMin, 48.0)
        XCTAssertEqual(sleep.heartRateMax, 74.0)
        XCTAssertEqual(sleep.heartRateSampleCount, 88)
        XCTAssertEqual(sleep.hasAppleWatchData, true)
        XCTAssertEqual(sleep.windowStart, windowStart)
        XCTAssertEqual(sleep.windowEnd, windowEnd)
        XCTAssertEqual(sleep.isEmpty, false, "seeded non-empty snapshot must not be flagged empty")

        XCTAssertEqual(planCalls.first?.memoryProfile?.contains("sleeps best on weekends"), true,
                       "memory profile must flow from MemoryStore into planOvernight")
    }

    // MARK: - finalizeBriefing

    /// Helper: assert a `BriefingResult` is `.success` and return the DTO. Fails
    /// the test with a descriptive message on any other case so tests don't
    /// silently pass on `.failure` when they expected `.success`.
    private func unwrapSuccess(_ result: BriefingResult, file: StaticString = #filePath, line: UInt = #line) -> BriefingDTO? {
        switch result {
        case .success(let dto): return dto
        case .noSession:
            XCTFail("Expected .success but got .noSession", file: file, line: line)
            return nil
        case .failure(let reason, let message):
            XCTFail("Expected .success but got .failure(reason=\(reason.rawValue), message=\(message))", file: file, line: line)
            return nil
        }
    }

    func testFinalizeBriefingReturnsDTOAndClearsHandle() async throws {
        // B5 fix: finalizeBriefing returns a `BriefingResult` enum with a
        // `.success(BriefingDTO)` case on the happy path. Enum lets the UI
        // distinguish three outcomes (success / noSession / failure) that the
        // previous `BriefingDTO?` conflated into one "no briefing" bucket.
        suiteDefaults.set("active-handle-xyz", forKey: OvernightScheduler.activeHandleKey)
        let source = RecordingSource()
        await source.setFetchResult((text: "Good morning — you logged 7.5h.", memoryUpdate: nil))
        let scheduler = makeScheduler(source: source)

        let wakeDate = Date(timeIntervalSince1970: 1_745_550_000)
        let result = await scheduler.finalizeBriefing(forWakeDate: wakeDate)

        let dto = unwrapSuccess(result)
        XCTAssertEqual(dto?.briefingText, "Good morning — you logged 7.5h.")
        XCTAssertEqual(dto?.forWakeDate, wakeDate)
        XCTAssertEqual(dto?.sourceSessionID, "active-handle-xyz")
        XCTAssertFalse(dto?.memoryUpdateApplied ?? true, "no memoryUpdate returned → flag stays false")

        // Handle must be cleared.
        XCTAssertNil(suiteDefaults.string(forKey: OvernightScheduler.activeHandleKey))

        // Cleanup must have been called on the source.
        let cleanupCalls = await source.cleanupCalls
        XCTAssertEqual(cleanupCalls, ["active-handle-xyz"])
    }

    func testFinalizeBriefingReturnsNoSessionWhenNoHandle() async throws {
        // B5 fix: the "no active handle" case now returns `.noSession`
        // explicitly rather than nil — the UI renders distinct copy for this
        // vs. an actual failure.
        let source = RecordingSource()
        let scheduler = makeScheduler(source: source)

        // No handle pre-set in suiteDefaults.
        let result = await scheduler.finalizeBriefing(forWakeDate: .now)

        switch result {
        case .noSession: break // expected
        case .success, .failure:
            XCTFail("Expected .noSession, got \(result)")
        }

        // No source methods should have been touched.
        let fetchCalls = await source.fetchCalls
        let cleanupCalls = await source.cleanupCalls
        XCTAssertTrue(fetchCalls.isEmpty)
        XCTAssertTrue(cleanupCalls.isEmpty)
    }

    func testFinalizeBriefingWithMemoryRewriteFailureLeavesFlagFalse() async throws {
        // Drive MemoryStore.rewriteProfile to throw MemoryStoreError.invalidUserUUID
        // via a non-UUID-shaped userUUID (the path-traversal guard in userDirectoryURL).
        // The C.3 fix wrapped rewriteProfile in do/catch; previously `try?` swallowed the
        // error and `memoryUpdateApplied = true` ran unconditionally, making the flag lie.
        // Invariant: the briefing is still returned as `.success` (it's the user-facing
        // artefact and memory is ancillary), but the flag reflects the actual memory
        // write outcome.
        suiteDefaults.set("active-handle-delta", forKey: OvernightScheduler.activeHandleKey)
        let memoryStore = makeMemoryStore(uuid: "../evil")
        let source = RecordingSource()
        await source.setFetchResult((text: "Briefing prose.", memoryUpdate: "## New profile\nSomething."))
        let scheduler = makeScheduler(source: source, memoryStore: memoryStore)

        let result = await scheduler.finalizeBriefing(forWakeDate: .now)

        let dto = unwrapSuccess(result)
        XCTAssertEqual(dto?.briefingText, "Briefing prose.")
        XCTAssertFalse(dto?.memoryUpdateApplied ?? true,
                       "rewriteProfile threw → flag must stay false (no silent lies)")

        // Handle is still cleared and cleanup still runs — memory is ancillary, not
        // a blocker for the finalize happy path.
        XCTAssertNil(suiteDefaults.string(forKey: OvernightScheduler.activeHandleKey))
        let cleanupCalls = await source.cleanupCalls
        XCTAssertEqual(cleanupCalls, ["active-handle-delta"])
    }

    func testFinalizeBriefingAppliesMemoryUpdateWhenPresent() async throws {
        suiteDefaults.set("active-handle-gamma", forKey: OvernightScheduler.activeHandleKey)
        let uuid = UUID().uuidString
        let memoryStore = makeMemoryStore(uuid: uuid)
        try await memoryStore.rewriteProfile("## Old profile\nStale notes.")
        let source = RecordingSource()
        let newProfile = "## Updated profile\nUser wakes more easily after Wednesday runs."
        await source.setFetchResult((text: "Today's briefing.", memoryUpdate: newProfile))
        let scheduler = makeScheduler(source: source, memoryStore: memoryStore)

        let result = await scheduler.finalizeBriefing(forWakeDate: .now)

        let dto = unwrapSuccess(result)
        XCTAssertTrue(dto?.memoryUpdateApplied ?? false, "memoryUpdate present → flag should be true")

        let snap = try await memoryStore.read()
        XCTAssertEqual(snap.profile, newProfile, "MemoryStore must now hold the new profile")
    }

    // MARK: - B5: fetch failure cleanup + classification

    /// B5.2 fix: every failure path in finalizeBriefing must call
    /// `source.cleanup(handle:)` AND clear the UserDefaults handle. Previously
    /// the `catch { return nil }` branch left the session running at $0.08/hr
    /// until next app launch. Test: seed a fetch-throwing source, assert
    /// handle is cleared + cleanup was called with the correct handle.
    func testFinalizeBriefingTransportFailureCleansUpSession() async throws {
        suiteDefaults.set("session-transport-fail", forKey: OvernightScheduler.activeHandleKey)
        let source = RecordingSource()
        await source.setFetchThrows(OvernightAgentError.transportFailed(underlying: SampleError.boom))
        let scheduler = makeScheduler(source: source)

        let result = await scheduler.finalizeBriefing(forWakeDate: .now)

        switch result {
        case .failure(let reason, _):
            XCTAssertEqual(reason, .fetchTransportFailed,
                           "transportFailed must classify as .fetchTransportFailed for UI copy routing")
        case .success, .noSession:
            XCTFail("Expected .failure, got \(result)")
        }

        // Cost-containment invariant: session must be terminated + handle cleared.
        XCTAssertNil(suiteDefaults.string(forKey: OvernightScheduler.activeHandleKey),
                     "failure path must clear handle — leaving it strands next launch on stale-cleanup")
        let cleanupCalls = await source.cleanupCalls
        XCTAssertEqual(cleanupCalls, ["session-transport-fail"],
                       "failure path must cleanup the session or it runs at $0.08/hr for hours")
    }

    func testFinalizeBriefingHTTPErrorClassifiesCorrectly() async throws {
        suiteDefaults.set("session-http-fail", forKey: OvernightScheduler.activeHandleKey)
        let source = RecordingSource()
        await source.setFetchThrows(OvernightAgentError.httpError(status: 503, snippet: "upstream unavailable"))
        let scheduler = makeScheduler(source: source)

        let result = await scheduler.finalizeBriefing(forWakeDate: .now)

        switch result {
        case .failure(let reason, let message):
            XCTAssertEqual(reason, .fetchHTTPError)
            XCTAssertTrue(message.contains("503"),
                          "HTTP-error UI copy must include the status code so users can screenshot support requests")
        case .success, .noSession:
            XCTFail("Expected .failure, got \(result)")
        }

        XCTAssertNil(suiteDefaults.string(forKey: OvernightScheduler.activeHandleKey))
    }

    func testFinalizeBriefingEmptyResponseClassifiesCorrectly() async throws {
        // B5.3: parseAgentReply throws emptyBriefingResponse on whitespace-only
        // content. Scheduler must map to .agentEmptyResponse and cleanup.
        suiteDefaults.set("session-empty", forKey: OvernightScheduler.activeHandleKey)
        let source = RecordingSource()
        await source.setFetchThrows(OvernightAgentError.emptyBriefingResponse)
        let scheduler = makeScheduler(source: source)

        let result = await scheduler.finalizeBriefing(forWakeDate: .now)

        switch result {
        case .failure(let reason, _):
            XCTAssertEqual(reason, .agentEmptyResponse)
        case .success, .noSession:
            XCTFail("Expected .failure, got \(result)")
        }

        XCTAssertNil(suiteDefaults.string(forKey: OvernightScheduler.activeHandleKey))
        let cleanupCalls = await source.cleanupCalls
        XCTAssertEqual(cleanupCalls, ["session-empty"])
    }

    func testFinalizeBriefingDecodingFailureClassifiesAsParseFailed() async throws {
        suiteDefaults.set("session-parse-fail", forKey: OvernightScheduler.activeHandleKey)
        let source = RecordingSource()
        await source.setFetchThrows(OvernightAgentError.decodingFailed(underlying: SampleError.boom))
        let scheduler = makeScheduler(source: source)

        let result = await scheduler.finalizeBriefing(forWakeDate: .now)

        switch result {
        case .failure(let reason, _):
            XCTAssertEqual(reason, .parseFailed)
        case .success, .noSession:
            XCTFail("Expected .failure, got \(result)")
        }

        XCTAssertNil(suiteDefaults.string(forKey: OvernightScheduler.activeHandleKey))
    }

    // MARK: - R9: lastSessionStartError surfacing

    /// R9 fix: startOvernightSession's catch branch was `logger.error(...)` and
    /// no UI surface — a silently-dying Layer 3 pipeline was indistinguishable
    /// from a healthy one. Now the scheduler retains the most recent start
    /// error and exposes it via `lastSessionStartError()`; AlarmSchedulerView
    /// reads and surfaces in its systemBanner.
    func testLastSessionStartErrorInitiallyNil() async throws {
        let source = RecordingSource()
        let scheduler = makeScheduler(source: source)

        let err = await scheduler.lastSessionStartError()
        XCTAssertNil(err, "no start attempt made yet → no error should be surfaced")
    }

    func testLastSessionStartErrorSurfacesPlanFailure() async throws {
        let source = RecordingSource()
        await source.setPlanThrows(OvernightAgentError.transportFailed(underlying: SampleError.boom))
        let scheduler = makeScheduler(source: source)

        await scheduler.startOvernightSession()

        let err = await scheduler.lastSessionStartError()
        XCTAssertNotNil(err,
                        "plan failure must surface via lastSessionStartError so UI can banner it")
    }

    func testLastSessionStartErrorClearedAfterSuccessfulRetry() async throws {
        // First attempt: force planOvernight to throw.
        let source = RecordingSource()
        await source.setPlanThrows(OvernightAgentError.transportFailed(underlying: SampleError.boom))
        let scheduler = makeScheduler(source: source)
        await scheduler.startOvernightSession()
        let firstErr = await scheduler.lastSessionStartError()
        XCTAssertNotNil(firstErr)

        // Reset: remove the thrown error so the next call succeeds.
        await source.setPlanThrows(nil)
        await source.setNextHandle("recovered-session-handle")
        await scheduler.startOvernightSession()

        let err = await scheduler.lastSessionStartError()
        XCTAssertNil(err,
                     "successful retry must clear the banner error — otherwise stale banners linger after recovery")
    }

    /// Named error type for forcing throws in tests. Deliberately not
    /// generic — the cleanup-verification assertions care about the scheduler's
    /// handling, not the wrapped error's type.
    private enum SampleError: Error { case boom }

    // MARK: - B3: re-entrancy guard in startOvernightSession

    /// B3 fix: two callers (auto-trigger + DEBUG button) previously raced the
    /// pre-actor `defaults.string(forKey:) == nil` check — both could pass and
    /// both enter the actor serially, both call `planOvernight`, and orphan
    /// the earlier session at $0.08/hr until its 24h ceiling. The fix is a
    /// post-actor re-check (UserDefaults) + `sessionCreationInFlight` flag.
    /// Assert: if a session is already open, a second call is a no-op.
    func testStartOvernightSessionSkipsWhenActiveHandleAlreadySet() async throws {
        // Pre-seed the handle key — simulating "a session is already open".
        suiteDefaults.set("pre-existing-handle", forKey: OvernightScheduler.activeHandleKey)
        let source = RecordingSource()
        await source.setNextHandle("would-be-new-handle")
        let scheduler = makeScheduler(source: source)

        await scheduler.startOvernightSession()

        // planOvernight must NOT have been called — the re-check caught the
        // active handle and short-circuited before any API call.
        let planCalls = await source.planCalls
        XCTAssertEqual(planCalls.count, 0,
                       "second concurrent startOvernightSession must not call planOvernight (would orphan the earlier session)")
        // The pre-existing handle is still intact.
        XCTAssertEqual(suiteDefaults.string(forKey: OvernightScheduler.activeHandleKey),
                       "pre-existing-handle",
                       "pre-existing handle must NOT be overwritten by a concurrent caller")
    }

    // MARK: - R12: BGProcessingTask completion-latch ordering

    /// R12 (Wave 2.5): non-expired path — the handler pokes the source, completes
    /// successfully, and iOS never fires the expirationHandler. Assert exactly one
    /// `setTaskCompleted(true)` call.
    ///
    /// Previously `handleBackgroundRefresh` had zero automated coverage; the C.3/C.4
    /// completion-latch ordering fixes lived in a code path exercised only via a
    /// DEBUG button and manual on-device testing. Now the `BGProcessingTaskLike`
    /// protocol (see OvernightScheduler.swift) lets us inject a `FakeBGProcessingTask`
    /// and drive this deterministically.
    func testBGRefreshNormalPathCallsSetTaskCompletedOnce() async throws {
        suiteDefaults.set("bg-test-handle", forKey: OvernightScheduler.activeHandleKey)
        let source = RecordingSource()
        let scheduler = makeScheduler(source: source)

        let fakeTask = FakeBGProcessingTask()
        await scheduler.handleRefresh(task: fakeTask)

        XCTAssertEqual(fakeTask.completionCalls.count, 1,
                       "non-expired path must call setTaskCompleted exactly once")
        XCTAssertEqual(fakeTask.completionCalls.first, true,
                       "non-expired success path records setTaskCompleted(true)")
    }

    /// R12 (Wave 2.5): early-expiration path — iOS fires the expirationHandler
    /// synchronously before `handleRefresh` does any real work. The latch should
    /// claim for the expiration handler; assert exactly one `setTaskCompleted(false)`
    /// and zero double-completion crashes.
    ///
    /// Implementation note: we install a RecordingSource that blocks planOvernight
    /// indefinitely (so handleRefresh is still running when we fire expiration),
    /// but we don't actually need that here — the scheduler's handleRefresh no-session
    /// branch handles the "no active handle" case and invokes setTaskCompleted(true)
    /// immediately. To actually race the expiration we install an active handle
    /// plus use the RecordingSource's pokeIfNeeded to block until we're ready.
    ///
    /// Simpler approach: fire expiration AFTER handleRefresh returns — this simulates
    /// a "phantom" expiration the BackgroundTasks queue can deliver after the task is
    /// already complete. The latch's `claim()` must return false so the handler's
    /// setTaskCompleted never fires a second time.
    func testBGRefreshPhantomExpirationDoesNotDoubleComplete() async throws {
        suiteDefaults.set("bg-test-handle", forKey: OvernightScheduler.activeHandleKey)
        let source = RecordingSource()
        let scheduler = makeScheduler(source: source)

        let fakeTask = FakeBGProcessingTask()
        await scheduler.handleRefresh(task: fakeTask)
        // After handleRefresh returns, actor's path has claimed the latch.
        XCTAssertEqual(fakeTask.completionCalls.count, 1)

        // Simulate iOS queuing a late expirationHandler fire — this can happen because
        // the handler runs on an unspecified queue and the BackgroundTasks framework
        // doesn't guarantee it is cancelled cleanly after setTaskCompleted.
        fakeTask.fireExpiration()

        // The latch MUST prevent a second setTaskCompleted call. If this assertion
        // fires, the completion-latch ordering regressed and the app would crash with
        // NSInternalInconsistencyException on the next BG fire on device.
        XCTAssertEqual(fakeTask.completionCalls.count, 1,
                       "expiration after actor-path completion must NOT produce a second setTaskCompleted (latch guards against double-claim)")
    }

    /// P17 (Stage 6 Wave 2): real race — expiration fires DURING an active
    /// await in `handleRefresh`, not after it returns. The previous
    /// `testBGRefreshPhantomExpirationDoesNotDoubleComplete` was a weaker
    /// check: it fired expiration AFTER `handleRefresh` had already returned,
    /// which only exercises the "latch already claimed, handler no-ops" path.
    /// The true race is iOS firing the expirationHandler WHILE the actor is
    /// suspended inside pokeIfNeeded — the handler claims the latch first,
    /// calls `setTaskCompleted(false)`, then the actor resumes and its
    /// `latch.claim()` correctly returns false so its own
    /// `setTaskCompleted(true)` is skipped.
    ///
    /// Implementation: `BlockingPokeSource` has a `CheckedContinuation`
    /// programmed so `pokeIfNeeded` blocks on the first call. The test:
    ///   1. Start `handleRefresh` as a Task (don't await).
    ///   2. Wait for the source to record that poke entered.
    ///   3. Fire the fakeTask's expirationHandler.
    ///   4. Resume the continuation so pokeIfNeeded returns.
    ///   5. Await the handleRefresh Task.
    ///   6. Assert exactly one completion call, and it's `false` (expiration's).
    func testBGRefreshExpirationDuringActivePokeCompletesOnlyOnce() async throws {
        suiteDefaults.set("bg-race-handle", forKey: OvernightScheduler.activeHandleKey)
        let blockingSource = BlockingPokeSource()
        // Construct the scheduler directly because `makeScheduler` is typed
        // to `RecordingSource`. Passing BlockingPokeSource through the
        // protocol-typed init preserves the protocol conformance without
        // widening the test helper's signature for one exceptional case.
        let scheduler = OvernightScheduler(
            source: blockingSource,
            sleepReader: FakeSleepReader(),
            memoryStore: makeMemoryStore(),
            defaults: suiteDefaults
        )

        let fakeTask = FakeBGProcessingTask()

        // (1) Start handleRefresh without awaiting — the actor suspends inside
        // pokeIfNeeded's continuation.
        let refreshTask = Task {
            await scheduler.handleRefresh(task: fakeTask)
        }

        // (2) Wait for poke to enter. Poll on the source's `pokeEntered` flag
        // with a bounded timeout so a stuck test fails loudly instead of
        // hanging. Worth emphasizing: polling HERE is fine — we're trying to
        // race with the scheduler's executor. The `await Task.sleep` yields
        // so the scheduler gets CPU.
        var spins = 0
        while !(await blockingSource.pokeEntered), spins < 200 {
            try await Task.sleep(nanoseconds: 5_000_000) // 5 ms
            spins += 1
        }
        let entered = await blockingSource.pokeEntered
        XCTAssertTrue(entered, "poke should have entered by now — scheduler is suspended inside our continuation")

        // (3) Fire expiration while the actor is still suspended. This is the
        // critical race: the handler must claim the latch, call
        // setTaskCompleted(false), and leave the actor's eventual resumption
        // with `latch.claim()` returning false.
        fakeTask.fireExpiration()

        // (4) Resume the continuation so pokeIfNeeded returns, letting the
        // actor continue through to its own `latch.claim()` check.
        await blockingSource.resumePoke()

        // (5) Drain the refresh Task.
        await refreshTask.value

        // (6) Assertions — exactly one completion call, and it's the
        // expiration's false. If the actor's post-await setTaskCompleted
        // ever fires, `completionCalls.count` would be 2 and this test
        // would catch the double-complete regression that would crash on
        // device with NSInternalInconsistencyException.
        XCTAssertEqual(fakeTask.completionCalls.count, 1,
                       "expiration during active poke must yield exactly one setTaskCompleted call — latch prevents double-claim")
        XCTAssertEqual(fakeTask.completionCalls.first, false,
                       "the single completion must be the expiration's setTaskCompleted(false); actor's post-await path must observe latch.isClaimed and skip its own call")
    }

    /// R12 (Wave 2.5): "no active handle" path — the handler sees no session and
    /// completes with success=true (signalling to iOS "nothing to do, succeed
    /// cleanly"). The same completion-latch guarantee applies: exactly one call.
    func testBGRefreshNoActiveHandleCompletesSuccessfullyOnce() async throws {
        // NO handle pre-set → scheduler takes the "pipeline stopped" branch.
        let source = RecordingSource()
        let scheduler = makeScheduler(source: source)

        let fakeTask = FakeBGProcessingTask()
        await scheduler.handleRefresh(task: fakeTask)

        XCTAssertEqual(fakeTask.completionCalls.count, 1,
                       "no-handle branch must still call setTaskCompleted exactly once — the task must be released back to iOS")
        XCTAssertEqual(fakeTask.completionCalls.first, true,
                       "no-handle branch is a clean exit — records success=true so iOS doesn't flag it as a pipeline error")

        // pokeIfNeeded must NOT have been called on the source — the "no handle"
        // branch short-circuits before the work block.
        let pokeCalls = await source.pokeCalls
        XCTAssertTrue(pokeCalls.isEmpty,
                      "no-handle branch must not spend Claude credits on poke")
    }

    // MARK: - cleanupStale

    func testCleanupStaleCallsSourceAndClearsDefaults() async throws {
        suiteDefaults.set("zombie-handle", forKey: OvernightScheduler.activeHandleKey)
        let source = RecordingSource()
        let scheduler = makeScheduler(source: source)

        await scheduler.cleanupStale(handle: "zombie-handle")

        let cleanupCalls = await source.cleanupCalls
        XCTAssertEqual(cleanupCalls, ["zombie-handle"])
        XCTAssertNil(suiteDefaults.string(forKey: OvernightScheduler.activeHandleKey))
    }

    // MARK: - P2: startOvernightSession clears banner when session already open

    /// P2 (Stage 6 Wave 1): when re-launch sees an active-handle already set,
    /// `startOvernightSession` early-returns — but previously it did NOT clear
    /// `_lastSessionStartError`, so yesterday's failure banner persisted even
    /// though tonight's session is live. This test seeds a failure, then seeds
    /// an active handle + re-invokes start, and asserts the banner was cleared.
    func testStartOvernightSessionClearsBannerWhenSessionAlreadyOpen() async throws {
        // First call: throws → banner set.
        let source = RecordingSource()
        await source.setPlanThrows(OvernightAgentError.transportFailed(underlying: SampleError.boom))
        let scheduler = makeScheduler(source: source)
        await scheduler.startOvernightSession()
        let preErr = await scheduler.lastSessionStartError()
        XCTAssertNotNil(preErr, "precondition: banner must be set after the first failed start")

        // Simulate the scenario: a successor session opened (e.g. BGTask-driven
        // re-engagement landed a handle overnight), and now foreground re-launch
        // calls startOvernightSession. The early-return path must clear the
        // stale banner.
        suiteDefaults.set("inherited-session", forKey: OvernightScheduler.activeHandleKey)
        await scheduler.startOvernightSession()

        let err = await scheduler.lastSessionStartError()
        XCTAssertNil(err, "session-already-open early-return MUST clear the stale banner — leaving it lies to the user")
        // The pre-existing handle is still intact.
        XCTAssertEqual(suiteDefaults.string(forKey: OvernightScheduler.activeHandleKey), "inherited-session")
    }

    // MARK: - P6: refresh error surfacing

    /// P6 (Stage 6 Wave 1): `handleRefresh` catch branch previously only logged.
    /// Now it sets `_lastRefreshError` so AlarmSchedulerView can surface a banner
    /// before the morning briefing's transport-error copy. Assert the poke-throw
    /// case populates the new field via `lastRefreshError()`.
    func testHandleRefreshSurfacesPokeFailureViaLastRefreshError() async throws {
        suiteDefaults.set("bg-test-handle-p6", forKey: OvernightScheduler.activeHandleKey)
        let source = RecordingSource()
        await source.setPokeThrows(OvernightAgentError.transportFailed(underlying: SampleError.boom))
        let scheduler = makeScheduler(source: source)

        let fakeTask = FakeBGProcessingTask()
        await scheduler.handleRefresh(task: fakeTask)

        // Pre-fix: this assertion failed because `_lastRefreshError` didn't exist.
        let refreshErr = await scheduler.lastRefreshError()
        XCTAssertNotNil(refreshErr,
                        "handleRefresh catch branch MUST populate lastRefreshError so the UI can banner it BEFORE the morning's transport-error copy")
        // Composite accessor also returns it (no start error in this scenario).
        let compositeErr = await scheduler.lastOvernightError()
        XCTAssertEqual(compositeErr, refreshErr,
                       "composite lastOvernightError must surface refreshError when startError is nil")

        // Successful next refresh clears the banner. Re-seed the handle in case
        // a concurrent cleanup Task from the prior refresh's cost-safety path
        // cleared it (P7 spawns a cleanupStale Task when BGTaskScheduler.submit
        // throws AND a handle is set). Polling-wait up to ~500ms then re-seed
        // so the second handleRefresh reliably takes the "handle present" branch
        // where the success-path clear lives.
        await source.setPokeThrows(nil)
        // Give any in-flight cleanup Task room to settle, then re-seed.
        try? await Task.sleep(nanoseconds: 200_000_000)
        suiteDefaults.set("bg-test-handle-p6-recovery", forKey: OvernightScheduler.activeHandleKey)
        let secondFakeTask = FakeBGProcessingTask()
        await scheduler.handleRefresh(task: secondFakeTask)
        let afterRecoveryErr = await scheduler.lastRefreshError()
        XCTAssertNil(afterRecoveryErr, "successful refresh MUST clear prior refresh error — else stale banner lingers")
    }

    /// P6: the composite `lastOvernightError()` accessor prefers `_lastSessionStartError`
    /// over `_lastRefreshError` when both are set. Rationale: a session that never
    /// opened is more directly actionable than one that opened then refreshed badly.
    func testLastOvernightErrorPrefersStartErrorOverRefreshError() async throws {
        suiteDefaults.set("handle-p6-both", forKey: OvernightScheduler.activeHandleKey)
        let source = RecordingSource()
        await source.setPokeThrows(OvernightAgentError.timeout)
        let scheduler = makeScheduler(source: source)

        // Seed a refresh error first.
        let fakeTask = FakeBGProcessingTask()
        await scheduler.handleRefresh(task: fakeTask)
        let seededRefreshErr = await scheduler.lastRefreshError()
        XCTAssertNotNil(seededRefreshErr, "precondition")

        // Now manufacture a start error on a FRESH scheduler with no handle
        // (so startOvernightSession actually tries to open). Re-use the same
        // mechanism as testLastSessionStartErrorSurfacesPlanFailure.
        // Since the scheduler actor keeps both fields independently, a start
        // error added AFTER a refresh error should take precedence in the
        // composite.
        suiteDefaults.removeObject(forKey: OvernightScheduler.activeHandleKey)
        await source.setPlanThrows(OvernightAgentError.httpError(status: 503, snippet: "x"))
        await source.setPokeThrows(nil)
        await scheduler.startOvernightSession()

        let composite = await scheduler.lastOvernightError()
        let startErr = await scheduler.lastSessionStartError()
        XCTAssertEqual(composite, startErr,
                       "composite must return startError when both present — start failure is more directly actionable")
    }

    // MARK: - P9: cleanup failure retry semantics

    /// P9 (Stage 6 Wave 1): if `source.cleanupThrowing` fails, the scheduler
    /// must RETAIN the handle + bump the termination-attempts counter rather
    /// than silently clearing the handle (which leaves an orphan session running
    /// at $0.08/hr up to the 24h Anthropic ceiling). This test exercises the
    /// retain path via `finalizeBriefing` — fetchBriefing succeeds, cleanup
    /// throws, scheduler retains handle and records attempt 1.
    func testCleanupFailurePreservesHandleUntilMaxRetries() async throws {
        suiteDefaults.set("handle-p9-retain", forKey: OvernightScheduler.activeHandleKey)
        let source = RecordingSource()
        await source.setFetchResult((text: "briefing prose", memoryUpdate: nil))
        await source.setCleanupThrows(OvernightAgentError.httpError(status: 503, snippet: "delete unavailable"))
        let scheduler = makeScheduler(source: source)

        let result = await scheduler.finalizeBriefing(forWakeDate: .now)

        // fetchBriefing succeeded so the result is still .success — briefing is
        // captured upstream; retention is purely cost-safety.
        _ = unwrapSuccess(result)

        // The cleanup throw must cause retention.
        XCTAssertEqual(suiteDefaults.string(forKey: OvernightScheduler.activeHandleKey), "handle-p9-retain",
                       "cleanup failure MUST retain the handle — clearing it strands Anthropic's meter at $0.08/hr for up to 24h")
        XCTAssertEqual(suiteDefaults.integer(forKey: OvernightScheduler.terminationAttemptsKey), 1,
                       "first cleanup failure must bump counter to 1")

        // Cleanup was attempted.
        let throwingCalls = await source.cleanupThrowingCalls
        XCTAssertEqual(throwingCalls, 1, "cleanupThrowing must have been invoked once")
    }

    /// P9: after `maxTerminationAttempts` failures, the scheduler abandons the
    /// handle (force-clears) and resets the counter. A `.fault` log fires but
    /// we don't assert on logger output — just the resulting UserDefaults state.
    func testCleanupFailureAfterMaxRetriesAbandonsHandle() async throws {
        suiteDefaults.set("handle-p9-abandon", forKey: OvernightScheduler.activeHandleKey)
        let source = RecordingSource()
        await source.setCleanupThrows(OvernightAgentError.httpError(status: 500, snippet: "persistent"))
        let scheduler = makeScheduler(source: source)

        // Call cleanupStale repeatedly. Each failure bumps the counter. On the
        // maxTerminationAttempts'th failure the handle is abandoned.
        for _ in 0..<OvernightScheduler.maxTerminationAttempts {
            // Each iteration simulates a bootstrap-time cleanupStale pass.
            // Handle is re-seeded by the previous iteration (if retained) OR
            // was never cleared; for the last iteration the retain path should
            // flip to abandon.
            if let handle = suiteDefaults.string(forKey: OvernightScheduler.activeHandleKey) {
                await scheduler.cleanupStale(handle: handle)
            }
        }

        XCTAssertNil(suiteDefaults.string(forKey: OvernightScheduler.activeHandleKey),
                     "after maxTerminationAttempts failed cleanups, handle must be force-cleared so bootstrap doesn't loop on the same dead session")
        XCTAssertEqual(suiteDefaults.integer(forKey: OvernightScheduler.terminationAttemptsKey), 0,
                       "counter must reset on abandon so a future session's failure starts fresh at 1")

        // Sanity: the attempted cleanup count equals the retry cap.
        let throwingCalls = await source.cleanupThrowingCalls
        XCTAssertEqual(throwingCalls, OvernightScheduler.maxTerminationAttempts,
                       "cleanupThrowing should have been called once per retry pass")
    }

    /// P9: successful cleanup resets the counter to zero, so a future failure
    /// starts fresh at 1 rather than at whatever the prior session left behind.
    func testSuccessfulCleanupResetsRetryCounter() async throws {
        // Seed a counter from a prior session.
        suiteDefaults.set(3, forKey: OvernightScheduler.terminationAttemptsKey)
        suiteDefaults.set("handle-p9-reset", forKey: OvernightScheduler.activeHandleKey)
        let source = RecordingSource()
        // No cleanupThrows → cleanupThrowing succeeds.
        let scheduler = makeScheduler(source: source)

        await scheduler.cleanupStale(handle: "handle-p9-reset")

        XCTAssertNil(suiteDefaults.string(forKey: OvernightScheduler.activeHandleKey),
                     "successful cleanup must clear the handle")
        XCTAssertEqual(suiteDefaults.integer(forKey: OvernightScheduler.terminationAttemptsKey), 0,
                       "successful cleanup must reset the counter — else a lingering count from a prior session distorts future budget decisions")
    }
}
