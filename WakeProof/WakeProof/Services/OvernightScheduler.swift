//
//  OvernightScheduler.swift
//  WakeProof
//
//  Layer 3 orchestration. Plugs into a briefing source (Managed Agent or
//  nightly synthesis) via the OvernightBriefingSource protocol. Handles
//  bedtime → session open, BGProcessingTask wake-ups, and the briefing
//  fetch at alarm time. Implementation is path-agnostic — Phase B.5 picks
//  the concrete source based on the B.3 decision-gate outcome.
//

import BackgroundTasks
import Foundation
import SwiftData
import os

/// Abstraction the scheduler drives. Conformers MUST be actors so the
/// scheduler's boundary with the briefing source serialises naturally.
protocol OvernightBriefingSource: Actor {

    /// Open the session (primary path) or store initial data for
    /// BGProcessingTask-based synthesis (fallback path). Returns an opaque
    /// handle the scheduler persists in UserDefaults.
    func planOvernight(sleep: SleepSnapshot, memoryProfile: String?) async throws -> String

    /// Called from BGProcessingTask wake-ups. Returns true if a briefing is
    /// ready (scheduler can skip further refreshes), false if more work
    /// is expected tonight.
    func pokeIfNeeded(handle: String, sleep: SleepSnapshot) async throws -> Bool

    /// At alarm time — returns the briefing prose + optional memory update
    /// (a full-profile rewrite markdown, or nil to leave the profile as-is).
    func fetchBriefing(handle: String) async throws -> (text: String, memoryUpdate: String?)

    /// Best-effort cleanup. On primary path this terminates the running
    /// Managed Agent session (stops the $0.08/hr meter); on fallback this
    /// is a no-op.
    func cleanup(handle: String) async
}

actor OvernightScheduler {

    /// BGTaskScheduler identifier. Must match the value in the app's
    /// `BGTaskSchedulerPermittedIdentifiers` Info.plist array (added in B.1).
    static let backgroundTaskIdentifier = "com.wakeproof.overnight.refresh"

    /// UserDefaults key for the active overnight-session handle. Exposed so
    /// launch-time recovery (`cleanupStale`) can read it before the scheduler
    /// actor is constructed.
    static let activeHandleKey = "com.wakeproof.overnight.activeHandle"

    private let source: any OvernightBriefingSource
    // R11 (Wave 2.5): typed as `any SleepReading` so tests can swap in `FakeSleepReader`
    // instead of relying on "simulator has no HealthKit data → empty snapshot" quirks.
    // Production still passes the concrete `HealthKitSleepReader()` at the WakeProofApp
    // wire-up site.
    private let sleepReader: any SleepReading
    private let memoryStore: MemoryStore
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: LogSubsystem.overnight, category: "scheduler")

    /// Re-entrancy guard for `startOvernightSession` (B3 fix). Set atomically on
    /// entry; cleared on return. Prevents two concurrent callers (auto-trigger +
    /// DEBUG button, or launch-path + bedtime-timer) from both passing the
    /// "no active handle" guard and both opening fresh Managed Agent sessions
    /// at $0.08/hr each.
    private var sessionCreationInFlight: Bool = false

    /// R9 fix: surfaces the error from the most recent failed
    /// `startOvernightSession` call so the UI (AlarmSchedulerView banner) can
    /// tell the user "tonight's overnight analysis couldn't start — we'll
    /// retry". Previously the catch branch only logged, so a pipeline that
    /// silently stopped working looked identical to a correctly-armed one.
    /// Cleared on the next successful start.
    private var _lastSessionStartError: String?

    /// SQ3 (Stage 4): `modelContainer` parameter was removed. After the R5 DTO
    /// refactor, SwiftData `ModelContext` construction moved to the main actor's
    /// `onChange` handler; nothing inside the scheduler actor used the container.
    /// Call sites updated: `WakeProofApp.init()` + `OvernightSchedulerTests.makeScheduler`.
    init(
        source: any OvernightBriefingSource,
        sleepReader: any SleepReading,
        memoryStore: MemoryStore,
        defaults: UserDefaults = .standard
    ) {
        self.source = source
        self.sleepReader = sleepReader
        self.memoryStore = memoryStore
        self.defaults = defaults
    }

    // MARK: - Lifecycle entry points

    /// Kick off tonight's session. Called from WakeProofApp when BedtimeSettings
    /// is enabled and the clock crosses the configured bedtime. Failure here
    /// logs and returns — the morning briefing is a best-effort feature, so a
    /// nightly failure must never block the core alarm flow.
    ///
    /// B3 fix: the call sites in WakeProofApp and AlarmSchedulerView previously
    /// checked `defaults.string(forKey:) == nil` *before* entering the actor,
    /// which is a TOCTOU window — two callers could both pass the pre-check, both
    /// hop into the actor serially, and both create a fresh Managed Agent session
    /// (orphaning the earlier one, which then burns $0.08/hr until its 24h ceiling).
    /// This method is now the single source of truth for "should a session open":
    /// callers may call freely and the actor resolves contention.
    func startOvernightSession() async {
        // Two-layer guard (B3):
        //   (1) `sessionCreationInFlight` — swallows concurrent calls that land
        //       while this method is suspended at `source.planOvernight`. The
        //       actor's serial executor ensures atomic set/check here.
        //   (2) `defaults.string(forKey: activeHandleKey)` re-check — catches the
        //       "previous session already succeeded" case (e.g. BGTask ran
        //       overnight, or a prior auto-trigger completed before this one).
        if sessionCreationInFlight {
            logger.info("startOvernightSession: creation already in flight on this actor — skipping")
            return
        }
        if let existing = defaults.string(forKey: Self.activeHandleKey) {
            logger.info("startOvernightSession: session already open (handle=\(existing.prefix(8), privacy: .private)) — skipping")
            return
        }
        sessionCreationInFlight = true
        defer { sessionCreationInFlight = false }

        logger.info("startOvernightSession: begin")
        do {
            let sleep = await readSleepSafely()
            let snap = await readMemorySafely()
            // Re-check AFTER the awaits above — a concurrent caller could have
            // completed a full planOvernight + defaults.set while we were
            // suspended. Without this, both callers would still race to
            // defaults.set, overwriting each other's handle and orphaning the
            // first session. The `sessionCreationInFlight` flag caps at two
            // callers in flight (one here, one waiting at the top guard); this
            // re-check catches the case where our own defer ran between a prior
            // success and our suspension resume.
            if let existing = defaults.string(forKey: Self.activeHandleKey) {
                logger.info("startOvernightSession: concurrent session arrived while suspended (handle=\(existing.prefix(8), privacy: .private)); abandoning ours")
                return
            }
            let handle = try await source.planOvernight(sleep: sleep, memoryProfile: snap.profile)
            // Post-plan re-check: the previous re-check occurred before planOvernight's
            // await suspension. Closing the last remaining window means another in-flight
            // creator cannot have landed a handle under us; if one did, we now hold an
            // orphan we must terminate rather than pave over.
            if let existing = defaults.string(forKey: Self.activeHandleKey) {
                logger.warning("startOvernightSession: post-plan conflict (existing=\(existing.prefix(8), privacy: .private) mine=\(handle.prefix(8), privacy: .private)); terminating mine to avoid orphan")
                await source.cleanup(handle: handle)
                return
            }
            defaults.set(handle, forKey: Self.activeHandleKey)
            // R9 fix: successful start clears any previous failure banner. A
            // stale error on the UI after a successful retry would be worse
            // than no banner at all — users would still think the pipeline
            // was broken.
            _lastSessionStartError = nil
            logger.info("startOvernightSession: session open handle=\(handle.prefix(8), privacy: .private)")
            scheduleNextBackgroundRefresh()
        } catch {
            // R9 fix: expose the failure for banner surfacing. The error
            // description is user-visible — OvernightAgentError.errorDescription
            // values are already written as short user-friendly strings.
            _lastSessionStartError = error.localizedDescription
            logger.error("startOvernightSession failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// R9 fix: surfaced as an async read (actor-local property) so MainActor
    /// callers can read it via `await`. AlarmSchedulerView polls this on view
    /// appear / on each state change; a more elaborate push-based observer is
    /// unwarranted when the banner only refreshes on user-visible boundaries.
    func lastSessionStartError() async -> String? {
        _lastSessionStartError
    }

    /// BGProcessingTask handler. **Order is load-bearing** (R1 in plan review):
    /// (1) expirationHandler first — iOS can reclaim the task at any moment
    ///     and we need a reasoner for "time ran out" rather than revocation.
    /// (2) Bail fast if there is no active handle — crucial termination condition
    ///     for the BGTask chain. After `finalizeBriefing` clears the handle the
    ///     pipeline must stop re-queuing; previously we submitted tomorrow's task
    ///     BEFORE checking the guard, which kept the chain alive forever (C.3 fix).
    /// (3) scheduleNextBackgroundRefresh — only while a session is active.
    /// (4) the work itself — poke the source with fresh HealthKit data.
    ///
    /// R12 (Wave 2.5): public entry adapts the real `BGProcessingTask` to the
    /// `BGProcessingTaskLike` protocol so the testable `handleRefresh(task:)` helper
    /// can be driven by a fake in unit tests. iOS forbids constructing real
    /// `BGProcessingTask` instances; the adapter pattern means the critical path
    /// (completion-latch ordering) gets automated coverage.
    func handleBackgroundRefresh(_ task: BGProcessingTask) async {
        await handleRefresh(task: RealBGProcessingTask(task))
    }

    /// R12 (Wave 2.5): testable BGTask-shape. Accepts any conformer so unit tests
    /// can pass a `FakeBGProcessingTask` that records `setTaskCompleted` calls and
    /// lets the test trigger `expirationHandler()` manually. All the completion-
    /// latch logic moved here from `handleBackgroundRefresh` verbatim.
    ///
    /// B2 fix (carried over): `task.expirationHandler` is invoked by BackgroundTasks
    /// on an unspecified queue — it may fire *while* this actor is suspended at an
    /// `await`. Calling `task.setTaskCompleted(success:)` twice (once from the
    /// expiration handler, once from the actor's own resumed path) raises
    /// `NSInternalInconsistencyException` and crashes the app on the next
    /// background-refresh fire. The `CompletionLatch` (backed by `OSAllocatedUnfairLock<Bool>`,
    /// shared across the actor-vs-handler boundary) resolves this: whoever claims the
    /// latch first wins the right to call `setTaskCompleted`; the loser short-circuits.
    /// The actor's resumption path additionally checks `latch.isClaimed` after each
    /// await so it exits the pipeline BEFORE doing further work against a task that's
    /// already been marked complete.
    func handleRefresh(task: some BGProcessingTaskLike) async {
        // Shared completion-state between the expiration handler (non-actor
        // queue) and the actor's own resumption path. Declared as a local
        // `let` because each handleBackgroundRefresh invocation owns its own
        // BGProcessingTask — no cross-invocation state.
        let latch = CompletionLatch()

        // (1) expirationHandler FIRST. The handler runs on an unspecified
        // queue from BackgroundTasks. It must (a) claim the latch so the
        // actor's normal-exit path no-ops its setTaskCompleted call, and
        // (b) actually call setTaskCompleted(false). The `[latch]` capture
        // retains the lock across the handler closure; `weak self` avoids
        // a strong scheduler ref outliving the task.
        task.expirationHandler = { [weak self, latch] in
            guard latch.claim() else {
                // Actor's normal path already claimed; handler must no-op.
                return
            }
            Task { [weak self] in
                await self?.logExpiration()
            }
            task.setTaskCompleted(success: false)
        }

        // (2) No active handle → pipeline is stopped, exit silently. Do NOT
        // re-queue: finalizeBriefing clears the handle on VERIFIED, and if a
        // late BGTask fires after that we want the chain to terminate rather
        // than burn a task every 2h for nothing (Phase C review #2).
        guard let handle = defaults.string(forKey: Self.activeHandleKey) else {
            logger.warning("handleBackgroundRefresh: no active handle (pipeline stopped); completing")
            if latch.claim() {
                task.setTaskCompleted(success: true)
            } else {
                logger.warning("handleBackgroundRefresh: expiration raced no-handle path")
            }
            return
        }
        // (3) Only re-queue while an active session exists. After finalizeBriefing
        // clears the handle, the pipeline stops until next bedtime.
        scheduleNextBackgroundRefresh()
        // (4) The work itself.
        do {
            let sleep = await readSleepSafely()
            // Early exit if expiration fired during the sleep read. Prevents
            // burning a Managed Agent poke on a task that's already been
            // marked complete — Claude credits matter and the poke wouldn't
            // be reportable anyway.
            if latch.isClaimed {
                logger.warning("handleBackgroundRefresh: expiration fired during sleep read; aborting poke")
                return
            }
            let briefingReady = try await source.pokeIfNeeded(handle: handle, sleep: sleep)
            logger.info("handleBackgroundRefresh: pokeIfNeeded done briefingReady=\(briefingReady, privacy: .public)")
            if latch.claim() {
                task.setTaskCompleted(success: true)
            } else {
                logger.warning("handleBackgroundRefresh: expiration raced after pokeIfNeeded")
            }
        } catch {
            logger.error("handleBackgroundRefresh failed: \(error.localizedDescription, privacy: .public)")
            if latch.claim() {
                task.setTaskCompleted(success: false)
            } else {
                logger.warning("handleBackgroundRefresh: expiration raced on failure path")
            }
        }
    }

    /// Called at wake time after VERIFIED. Pulls the briefing from the source,
    /// applies any memoryUpdate, tears down the source (terminates Managed Agent
    /// session), clears the active-handle flag, and returns a `BriefingResult`
    /// that distinguishes success / no-session / failure for the UI layer.
    ///
    /// B5.2 fix: EVERY failure path below calls `source.cleanup(handle:)` and
    /// clears the active-handle UserDefaults key. Previously the top-level
    /// `catch { return nil }` left the session running at $0.08/hr until the
    /// next app launch's `cleanupStaleOvernightSessionIfNeeded` caught it —
    /// effectively up to 24h of cost-leak per failed fetch.
    ///
    /// B5 fix: returns `BriefingResult` (enum) rather than `BriefingDTO?`. The
    /// nil vs. DTO distinction previously collapsed "no session" + "fetch
    /// threw" + "agent returned empty" into one bucket the UI rendered as a
    /// fresh-install card. Each branch now carries a distinct failure reason
    /// and user-visible message so MorningBriefingView can explain what went
    /// wrong rather than pretending the pipeline was never wired.
    ///
    /// R5 fix (carried over): the DTO shape decouples on-actor work (fetch +
    /// memory update) from main-actor work (materialise into `mainContext`).
    /// See WakeProofApp RootView's onChange handler for the main-actor side.
    func finalizeBriefing(forWakeDate wakeDate: Date) async -> BriefingResult {
        guard let handle = defaults.string(forKey: Self.activeHandleKey) else {
            logger.info("finalizeBriefing: no active handle, nothing to finalize")
            return .noSession
        }
        let text: String
        let memoryUpdate: String?
        do {
            let fetched = try await source.fetchBriefing(handle: handle)
            text = fetched.text
            memoryUpdate = fetched.memoryUpdate
            logger.info("finalizeBriefing: briefing fetched chars=\(text.count, privacy: .public)")
        } catch {
            // B5.2 cleanup invariant: release the session on every failure
            // path. `source.cleanup` is best-effort and its own errors are
            // already swallowed + logged inside ManagedAgentBriefingSource.
            await source.cleanup(handle: handle)
            defaults.removeObject(forKey: Self.activeHandleKey)
            let (reason, message) = Self.classify(fetchError: error)
            logger.error("finalizeBriefing failed: reason=\(reason.rawValue, privacy: .public) err=\(error.localizedDescription, privacy: .public)")
            return .failure(reason: reason, message: message)
        }

        var memoryUpdateApplied = false
        if let memoryUpdate {
            // Previously `try?` swallowed rewrite failures then unconditionally set
            // the flag — so `memoryUpdateApplied` lied when a disk-full or invalid-
            // UUID error hit. CLAUDE.md promoted rule #2 forbids silent catch; wrap
            // in do/catch so the flag reflects reality and a failure logs visibly.
            // The DTO (and thus the briefing) is still returned — it's the
            // user-facing artefact and memory is ancillary, so a memory-store
            // hiccup must not mask the briefing on the morning cover.
            do {
                try await memoryStore.rewriteProfile(memoryUpdate)
                memoryUpdateApplied = true
                logger.info("finalizeBriefing: memory update applied chars=\(memoryUpdate.count, privacy: .public)")
            } catch {
                logger.warning("finalizeBriefing: memory rewrite failed; briefing kept, flag stays false: \(error.localizedDescription, privacy: .public)")
            }
        }
        await source.cleanup(handle: handle)
        defaults.removeObject(forKey: Self.activeHandleKey)
        return .success(BriefingDTO(
            briefingText: text,
            forWakeDate: wakeDate,
            sourceSessionID: handle,
            memoryUpdateApplied: memoryUpdateApplied
        ))
    }

    /// B5.2 helper: map a `fetchBriefing` error to a `BriefingFailureReason` +
    /// user-visible message. The specific OvernightAgentError cases the
    /// ManagedAgentBriefingSource surfaces fall into three user-perceived
    /// buckets: transport (couldn't reach Claude at all), HTTP (reached the
    /// proxy but got a non-2xx), and content (reached Claude but the reply
    /// was empty or malformed). Anything else defaults to `.parseFailed` with
    /// a generic message — callers should never lose the underlying
    /// localizedDescription, which gets logged one line above.
    ///
    /// Keeping this map inside the scheduler (rather than on OvernightAgentError
    /// itself) isolates the UI-copy decisions here — the client library stays
    /// free of end-user language concerns.
    private static func classify(fetchError error: Error) -> (BriefingFailureReason, String) {
        if let agentError = error as? OvernightAgentError {
            switch agentError {
            case .transportFailed, .timeout, .missingProxyToken, .invalidURL:
                return (.fetchTransportFailed,
                        "Couldn't reach Claude tonight — your alarm still verified. Try tomorrow.")
            case .httpError(let status, _):
                return (.fetchHTTPError,
                        "Claude had a hiccup (HTTP \(status)). Your alarm verified fine.")
            case .emptyBriefingResponse,
                 // M7 (Wave 2.6): Both "no agent.message in events" and
                 // "agent.message existed but had no text block" collapse to
                 // the same user-perceived outcome ("Claude didn't produce a
                 // briefing") even though the internal distinction helps the
                 // log/metrics layer tell "agent didn't respond" from "agent
                 // responded with tool_use only". Grouping here keeps the UI
                 // copy simple; the log line one level up already carries the
                 // specific agentError.localizedDescription for post-mortem.
                 .noAgentResponse,
                 .agentMessageMissingTextBlock:
                return (.agentEmptyResponse,
                        "Claude's briefing came back empty. Your alarm verified fine.")
            case .missingResourceID, .decodingFailed:
                return (.parseFailed,
                        "Claude's briefing didn't parse cleanly. Your alarm verified fine.")
            }
        }
        // Unknown error type: classify as parseFailed — generic enough to be
        // safe, distinct enough from the transport/HTTP buckets that logs stay
        // useful for post-mortem.
        return (.parseFailed, "Claude's briefing couldn't be retrieved. Your alarm verified fine.")
    }

    /// Launch-time cleanup — if UserDefaults holds a stale handle from a
    /// crashed prior session, best-effort terminate the source and clear the
    /// handle. Called by WakeProofApp.bootstrapIfNeeded when the scheduler
    /// detects a handle that pre-dates tonight's bedtime.
    ///
    /// Rationale (from C.1 plan review): Managed Agents charge $0.08/hr for
    /// running sessions. A force-quit during the night leaves the session
    /// running until its 24h ceiling — this entry point caps the cost at
    /// "time until next launch" instead.
    func cleanupStale(handle: String) async {
        logger.warning("cleanupStale: terminating stale handle=\(handle.prefix(8), privacy: .private)")
        await source.cleanup(handle: handle)
        defaults.removeObject(forKey: Self.activeHandleKey)
    }

    // MARK: - Background-task registration

    /// Register the BGProcessingTask identifier at app launch. **Must be
    /// called from `WakeProofApp.init()`**, not from `.task { bootstrapIfNeeded }`
    /// — iOS requires registration before `application(_:didFinishLaunching
    /// WithOptions:)` returns, and `.task` runs only after the first scene
    /// attaches (well past launch completion). An early cold-launch BGTask
    /// fire without a registered identifier crashes the app.
    ///
    /// `nonisolated static` because the launch handler needs to be installed
    /// synchronously during init, before any actor-hop could even happen.
    ///
    /// `BGTaskScheduler.register`'s `launchHandler` is typed `(BGTask) -> Void`;
    /// this wrapper narrows it to the concrete `BGProcessingTask` — the
    /// identifier is reserved for processing tasks in Info.plist, so the cast
    /// is safe. Defensive guard logs if a different subclass ever arrives
    /// (would indicate a plist-ID mismatch / misconfiguration).
    nonisolated static func registerBackgroundTask(onHandle: @escaping (BGProcessingTask) -> Void) {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: backgroundTaskIdentifier,
            using: nil
        ) { task in
            guard let processing = task as? BGProcessingTask else {
                Logger(subsystem: LogSubsystem.overnight, category: "scheduler")
                    .error("registerBackgroundTask: received unexpected BGTask subclass \(type(of: task), privacy: .public); marking failed")
                task.setTaskCompleted(success: false)
                return
            }
            onHandle(processing)
        }
    }

    // MARK: - Private

    /// Thin wrapper over `sleepReader.lastNightSleep()` that swallows every
    /// error path back to `SleepSnapshot.empty`. Written as a helper (rather
    /// than inline `(try? ...) ?? .empty`) because `.empty` is main-actor
    /// isolated by the project's default-actor-isolation setting, and
    /// autoclosure-ed nil-coalescing can't reach a main-actor property from
    /// the scheduler actor's async context without an explicit hop.
    private func readSleepSafely() async -> SleepSnapshot {
        do {
            return try await sleepReader.lastNightSleep()
        } catch {
            logger.warning("readSleepSafely: reader failed, using empty snapshot: \(error.localizedDescription, privacy: .public)")
            return await SleepSnapshot.empty
        }
    }

    private func readMemorySafely() async -> MemorySnapshot {
        do {
            return try await memoryStore.read()
        } catch {
            logger.warning("readMemorySafely: store failed, using empty snapshot: \(error.localizedDescription, privacy: .public)")
            return await MemorySnapshot.empty
        }
    }

    private func scheduleNextBackgroundRefresh() {
        let request = BGProcessingTaskRequest(identifier: Self.backgroundTaskIdentifier)
        request.requiresExternalPower = false
        request.requiresNetworkConnectivity = true
        // 2h hint — iOS is best-effort; it may fire later (often never until
        // midnight-ish if the device is idle). The hint just tells iOS "not
        // sooner than X"; the actual scheduling depends on system load.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 2 * 3600)
        do {
            try BGTaskScheduler.shared.submit(request)
            logger.info("scheduleNextBackgroundRefresh: submitted earliest=\(request.earliestBeginDate?.ISO8601Format() ?? "nil", privacy: .public)")
        } catch {
            logger.error("scheduleNextBackgroundRefresh: submit failed \(error.localizedDescription, privacy: .public)")
        }
    }

    private func logExpiration() {
        logger.warning("BGProcessingTask expired before completion")
    }
}

/// R12 (Wave 2.5): minimal protocol exposing the BGProcessingTask surface the
/// scheduler actually uses — `setTaskCompleted(success:)` and the
/// `expirationHandler` settable property. Tests inject a `FakeBGProcessingTask`
/// that records calls; production wraps the real `BGProcessingTask` via
/// `RealBGProcessingTask`. iOS forbids constructing real `BGProcessingTask`
/// instances from a unit test, so the adapter pattern is the only way to get
/// automated coverage over the completion-latch logic.
///
/// `identifier` is a read-only `String` to match the real task's surface; tests
/// don't assert on it today but keeping it available preserves forward flexibility.
protocol BGProcessingTaskLike: AnyObject {
    var identifier: String { get }
    func setTaskCompleted(success: Bool)
    var expirationHandler: (() -> Void)? { get set }
}

/// R12 (Wave 2.5): thin adapter wrapping the real `BGProcessingTask` so
/// `handleRefresh(task:)` can accept `BGProcessingTaskLike`. The real
/// `BGProcessingTask` already exposes `setTaskCompleted(success:)` and
/// `expirationHandler` directly — this wrapper forwards both.
final class RealBGProcessingTask: BGProcessingTaskLike {
    private let task: BGProcessingTask
    init(_ task: BGProcessingTask) { self.task = task }
    var identifier: String { task.identifier }
    func setTaskCompleted(success: Bool) { task.setTaskCompleted(success: success) }
    var expirationHandler: (() -> Void)? {
        get { task.expirationHandler }
        set { task.expirationHandler = newValue }
    }
}

/// Single-use latch that guards `BGProcessingTask.setTaskCompleted` against a
/// double-claim race between (a) the BackgroundTasks-queue `expirationHandler`
/// and (b) the scheduler actor's post-await resumption. Whoever calls `claim()`
/// first gets `true` and owns the right to call `setTaskCompleted`; any later
/// caller gets `false` and must no-op.
///
/// Why `OSAllocatedUnfairLock<Bool>` rather than a Swift actor: the
/// expirationHandler must synchronously decide whether to call
/// `setTaskCompleted` — there is no async suspension tolerance because iOS may
/// reclaim the task microseconds after the handler runs. An actor-hop would
/// miss the window. `OSAllocatedUnfairLock` (iOS 16+) is a thin wrapper over
/// `os_unfair_lock_t` with an explicit initial-state parameter, making the
/// "unclaimed=false, claimed=true" semantics visible at the type level.
///
/// Declared as a reference-type class so the actor body and the
/// `expirationHandler` closure (running on BackgroundTasks' queue) share the
/// same instance. Every method and stored property is `nonisolated` to escape
/// the project's MainActor default — this type must be callable from any
/// queue (BackgroundTasks', the scheduler actor's executor, or the main
/// actor) without hops. `Sendable` because the one mutable state cell is
/// guarded by `OSAllocatedUnfairLock` (itself Sendable when wrapping a
/// Sendable value).
final class CompletionLatch: Sendable {
    nonisolated private let lock = OSAllocatedUnfairLock<Bool>(initialState: false)

    nonisolated init() {}

    /// Attempt to claim the latch. Returns `true` on first call, `false`
    /// thereafter. Thread-safe.
    nonisolated func claim() -> Bool {
        lock.withLock { claimed in
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }

    /// Observe the latch's current state without claiming. Used for early-exit
    /// decisions in the actor's resumption path — avoids the scheduler doing
    /// further work against a task whose completion the expiration handler has
    /// already claimed. This is advisory; any post-check claim still has to
    /// go through `claim()` to actually call setTaskCompleted.
    nonisolated var isClaimed: Bool {
        lock.withLock { $0 }
    }
}
