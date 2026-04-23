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
    private let sleepReader: HealthKitSleepReader
    private let memoryStore: MemoryStore
    private let modelContainer: ModelContainer
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.wakeproof.overnight", category: "scheduler")

    init(
        source: any OvernightBriefingSource,
        sleepReader: HealthKitSleepReader,
        memoryStore: MemoryStore,
        modelContainer: ModelContainer,
        defaults: UserDefaults = .standard
    ) {
        self.source = source
        self.sleepReader = sleepReader
        self.memoryStore = memoryStore
        self.modelContainer = modelContainer
        self.defaults = defaults
    }

    // MARK: - Lifecycle entry points

    /// Kick off tonight's session. Called from WakeProofApp when BedtimeSettings
    /// is enabled and the clock crosses the configured bedtime. Failure here
    /// logs and returns — the morning briefing is a best-effort feature, so a
    /// nightly failure must never block the core alarm flow.
    func startOvernightSession() async {
        logger.info("startOvernightSession: begin")
        do {
            let sleep = await readSleepSafely()
            let snap = await readMemorySafely()
            let handle = try await source.planOvernight(sleep: sleep, memoryProfile: snap.profile)
            defaults.set(handle, forKey: Self.activeHandleKey)
            logger.info("startOvernightSession: session open handle=\(handle.prefix(8), privacy: .private)")
            scheduleNextBackgroundRefresh()
        } catch {
            logger.error("startOvernightSession failed: \(error.localizedDescription, privacy: .public)")
        }
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
    func handleBackgroundRefresh(_ task: BGProcessingTask) async {
        // (1) expirationHandler FIRST. The handler runs on an unspecified
        // queue from BackgroundTasks; hop onto the scheduler actor to log
        // safely (`logger` is sendable, but keeping the actor hop avoids
        // an accidental isolation gap if we later read other state here).
        task.expirationHandler = { [weak self] in
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
            task.setTaskCompleted(success: true)
            return
        }
        // (3) Only re-queue while an active session exists. After finalizeBriefing
        // clears the handle, the pipeline stops until next bedtime.
        scheduleNextBackgroundRefresh()
        // (4) The work itself.
        do {
            let sleep = await readSleepSafely()
            let briefingReady = try await source.pokeIfNeeded(handle: handle, sleep: sleep)
            logger.info("handleBackgroundRefresh: pokeIfNeeded done briefingReady=\(briefingReady, privacy: .public)")
            task.setTaskCompleted(success: true)
        } catch {
            logger.error("handleBackgroundRefresh failed: \(error.localizedDescription, privacy: .public)")
            task.setTaskCompleted(success: false)
        }
    }

    /// Called at wake time after VERIFIED. Pulls the briefing from the source,
    /// persists a `MorningBriefing` row to SwiftData, applies any memoryUpdate,
    /// tears down the source (terminates Managed Agent session), and clears
    /// the active-handle flag.
    ///
    /// Returns nil when there is no active session (fresh install, previously
    /// finalized, or prior bedtime wasn't reached). The UI gracefully handles
    /// nil — `MorningBriefingView` shows nothing rather than a placeholder.
    func finalizeBriefing(forWakeDate wakeDate: Date) async -> MorningBriefing? {
        guard let handle = defaults.string(forKey: Self.activeHandleKey) else {
            logger.info("finalizeBriefing: no active handle, nothing to finalize")
            return nil
        }
        do {
            let (text, memoryUpdate) = try await source.fetchBriefing(handle: handle)
            let context = ModelContext(modelContainer)
            let briefing = MorningBriefing(
                forWakeDate: wakeDate,
                briefingText: text,
                sourceSessionID: handle
            )
            context.insert(briefing)
            try context.save()
            logger.info("finalizeBriefing: briefing inserted chars=\(text.count, privacy: .public)")
            if let memoryUpdate {
                // Previously `try?` swallowed rewrite failures then unconditionally set
                // the flag — so `memoryUpdateApplied` lied when a disk-full or invalid-
                // UUID error hit. CLAUDE.md promoted rule #2 forbids silent catch; wrap
                // in do/catch so the flag reflects reality and a failure logs visibly.
                // The briefing itself is still returned — it's the user-facing artefact
                // and memory is ancillary, so a memory-store hiccup must not mask the
                // briefing on the morning cover. The `try? context.save()` on the flag
                // update is acceptable: save failure on the flag is recoverable — the
                // main concern was silent profile-write drops.
                do {
                    try await memoryStore.rewriteProfile(memoryUpdate)
                    briefing.memoryUpdateApplied = true
                    try? context.save()
                    logger.info("finalizeBriefing: memory update applied chars=\(memoryUpdate.count, privacy: .public)")
                } catch {
                    logger.warning("finalizeBriefing: memory rewrite failed; briefing kept, flag stays false: \(error.localizedDescription, privacy: .public)")
                }
            }
            await source.cleanup(handle: handle)
            defaults.removeObject(forKey: Self.activeHandleKey)
            return briefing
        } catch {
            logger.error("finalizeBriefing failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
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
                Logger(subsystem: "com.wakeproof.overnight", category: "scheduler")
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
