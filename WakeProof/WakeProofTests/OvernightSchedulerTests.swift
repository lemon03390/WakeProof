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

        func planOvernight(sleep: SleepSnapshot, memoryProfile: String?) async throws -> String {
            planCalls.append(PlanCall(sleep: sleep, memoryProfile: memoryProfile))
            if let planThrows { throw planThrows }
            return nextHandle
        }

        func pokeIfNeeded(handle: String, sleep: SleepSnapshot) async throws -> Bool {
            pokeCalls.append(PokeCall(handle: handle, sleep: sleep))
            return pokeResult
        }

        func fetchBriefing(handle: String) async throws -> (text: String, memoryUpdate: String?) {
            fetchCalls.append(handle)
            if let fetchThrows { throw fetchThrows }
            return fetchResult
        }

        func cleanup(handle: String) async {
            cleanupCalls.append(handle)
        }

        // Test setters — need to be inside the actor so mutation is isolated.
        func setNextHandle(_ handle: String) { self.nextHandle = handle }
        func setFetchResult(_ result: (text: String, memoryUpdate: String?)) { self.fetchResult = result }
        func setFetchThrows(_ error: Error?) { self.fetchThrows = error }
        func setPlanThrows(_ error: Error?) { self.planThrows = error }
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

    private func makeScheduler(source: RecordingSource, memoryStore: MemoryStore? = nil) -> OvernightScheduler {
        OvernightScheduler(
            source: source,
            sleepReader: HealthKitSleepReader(),
            memoryStore: memoryStore ?? makeMemoryStore(),
            modelContainer: container,
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

    func testStartOvernightSessionPassesSleepAndMemoryCorrectly() async throws {
        // Seed the memory store with a profile so the scheduler forwards it.
        let uuid = UUID().uuidString
        let memoryStore = makeMemoryStore(uuid: uuid)
        try await memoryStore.rewriteProfile("## Observations\nUser sleeps best on weekends.")
        let source = RecordingSource()
        await source.setNextHandle("session-beta")
        let scheduler = makeScheduler(source: source, memoryStore: memoryStore)

        await scheduler.startOvernightSession()

        let planCalls = await source.planCalls
        XCTAssertEqual(planCalls.count, 1)
        // Sleep data on the test simulator has no authorised HealthKit access,
        // so the reader returns an empty-metrics snapshot (zero minutes, zero
        // samples) even though the window bounds are `Date.now - 12h` and
        // `Date.now`. Assert the metric fields are zero rather than comparing
        // to `SleepSnapshot.empty` (which carries 1970 window bounds).
        XCTAssertNotNil(planCalls.first?.sleep, "planOvernight must be called with a SleepSnapshot, not nil")
        XCTAssertEqual(planCalls.first?.sleep.totalInBedMinutes, 0,
                       "no HealthKit data on simulator → totalInBedMinutes is zero")
        XCTAssertEqual(planCalls.first?.sleep.heartRateSampleCount, 0,
                       "no HealthKit data on simulator → no HR samples")
        XCTAssertEqual(planCalls.first?.sleep.isEmpty, true,
                       "empty metrics → isEmpty is true")
        XCTAssertEqual(planCalls.first?.memoryProfile?.contains("sleeps best on weekends"), true,
                       "memory profile must flow from MemoryStore into planOvernight")
    }

    // MARK: - finalizeBriefing

    func testFinalizeBriefingReturnsDTOAndClearsHandle() async throws {
        // R5 fix: finalizeBriefing returns a `BriefingDTO` (Sendable value type)
        // rather than a `MorningBriefing @Model` instance. The main actor is the
        // one that materialises the model into mainContext — the scheduler no
        // longer owns a ModelContext. Assert on the DTO shape; the SwiftData
        // row is the main actor's responsibility (exercised in WakeProofApp).
        suiteDefaults.set("active-handle-xyz", forKey: OvernightScheduler.activeHandleKey)
        let source = RecordingSource()
        await source.setFetchResult((text: "Good morning — you logged 7.5h.", memoryUpdate: nil))
        let scheduler = makeScheduler(source: source)

        let wakeDate = Date(timeIntervalSince1970: 1_745_550_000)
        let dto = await scheduler.finalizeBriefing(forWakeDate: wakeDate)

        XCTAssertNotNil(dto)
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

    func testFinalizeBriefingReturnsNilWhenNoHandle() async throws {
        let source = RecordingSource()
        let scheduler = makeScheduler(source: source)

        // No handle pre-set in suiteDefaults.
        let dto = await scheduler.finalizeBriefing(forWakeDate: .now)

        XCTAssertNil(dto)

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
        // Invariant: the briefing DTO itself is still returned (it's the user-facing
        // artefact and memory is ancillary), but the flag reflects the actual memory
        // write outcome.
        suiteDefaults.set("active-handle-delta", forKey: OvernightScheduler.activeHandleKey)
        let memoryStore = makeMemoryStore(uuid: "../evil")
        let source = RecordingSource()
        await source.setFetchResult((text: "Briefing prose.", memoryUpdate: "## New profile\nSomething."))
        let scheduler = makeScheduler(source: source, memoryStore: memoryStore)

        let dto = await scheduler.finalizeBriefing(forWakeDate: .now)

        XCTAssertNotNil(dto, "briefing DTO must still be returned even if memory rewrite fails")
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

        let dto = await scheduler.finalizeBriefing(forWakeDate: .now)

        XCTAssertNotNil(dto)
        XCTAssertTrue(dto?.memoryUpdateApplied ?? false, "memoryUpdate present → flag should be true")

        let snap = try await memoryStore.read()
        XCTAssertEqual(snap.profile, newProfile, "MemoryStore must now hold the new profile")
    }

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
}
