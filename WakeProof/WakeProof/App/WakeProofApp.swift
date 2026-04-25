//
//  WakeProofApp.swift
//  WakeProof
//
//  App entry point. Wires up the top-level state containers and decides whether
//  to show onboarding, the alarm scheduler home, or the ringing alarm modal.
//

import BackgroundTasks
import SwiftData
import SwiftUI
import os

@main
struct WakeProofApp: App {

    @State private var permissions = PermissionsManager()
    @State private var audioKeepalive = AudioSessionKeepalive.shared
    @State private var scheduler = AlarmScheduler()
    @State private var soundEngine = AlarmSoundEngine()
    @State private var visionVerifier = VisionVerifier()
    @State private var weeklyCoach = WeeklyCoach()
    /// Wave 5 H3: derives current + best streak from the existing
    /// WakeAttempt history. Instantiated here so RootView and
    /// AlarmSchedulerView share one @Observable instance via
    /// `.environment(_:)`. Initial value is (0, 0) until bootstrap's
    /// first recompute lands — the badge's `shouldRender` gate hides it
    /// during that millisecond, so there's no flash.
    @State private var streakService = StreakService()
    /// One-shot guard so .task running on every RootView re-mount (multi-scene attach,
    /// SwiftUI identity churn) doesn't repeatedly cancel + reschedule the fire pipeline.
    @State private var didBootstrap = false

    // Non-Observable actor services — held as `private let` rather than `@State` because
    // they provide no SwiftUI-observable surface. A @State wrapper around a value-type
    // actor-reference adds binding machinery we never use.
    private let memoryStore = MemoryStore()
    // Primary path (B.5): Managed Agents. `NoopBriefingSource` is retained in the
    // codebase for previews and rollback — see NoopBriefingSource.swift header.
    private let briefingSource = ManagedAgentBriefingSource()
    private let sleepReader = HealthKitSleepReader()
    private let overnightScheduler: OvernightScheduler

    private static let logger = Logger(subsystem: LogSubsystem.app, category: "root")
    /// Weak bridge between `init()`'s synchronously-registered BGTask launch handler and
    /// the scheduler instance. `nonisolated static` so the handler closure can capture
    /// it without reaching into `self` (which the closure can't safely hold at register
    /// time — the runtime invokes it during cold-launch before any instance lifetime
    /// guarantees). Weak so the box itself never keeps the scheduler alive past app
    /// teardown; live reference is held by `WakeProofApp.overnightScheduler`.
    private static let schedulerBox = OvernightSchedulerBox()
    let modelContainer: ModelContainer

    init() {
        do {
            modelContainer = try ModelContainer(
                for: BaselinePhoto.self, WakeAttempt.self, MorningBriefing.self
            )
        } catch {
            // Log before the fatal so crash reports carry the decoded reason rather than
            // just a stack trace. Recoverable storage-init UI is out of scope here; this
            // is a fail-fast programmer-error path (schema mismatch, disk full at install).
            Self.logger.critical("ModelContainer init failed: \(error.localizedDescription, privacy: .public)")
            fatalError("Failed to initialize SwiftData ModelContainer: \(error)")
        }

        // Build scheduler synchronously so it's ready for RootView at first render.
        // Phase B.5 wired `ManagedAgentBriefingSource` (primary path, chosen by the
        // B.3 decision gate) as the live source — each bedtime starts a real Managed
        // Agents session; each wake fetches the final agent.message.
        // SQ3 (Stage 4): dropped `modelContainer:` argument — unused inside the
        // scheduler actor after the R5 DTO refactor. Main-actor ModelContext work
        // happens in RootView's onChange handler; the scheduler produces Sendable
        // BriefingDTOs instead.
        let scheduler = OvernightScheduler(
            source: briefingSource,
            sleepReader: sleepReader,
            memoryStore: memoryStore
        )
        self.overnightScheduler = scheduler
        Self.schedulerBox.value = scheduler
        Self.logger.info("OvernightScheduler wired with ManagedAgentBriefingSource (primary path)")

        // BGTaskScheduler requires identifier registration before
        // `application(_:didFinishLaunchingWithOptions:)` returns. `.task { bootstrapIfNeeded }`
        // fires AFTER first scene attach, which is well past launch completion — iOS has
        // already crashed the app by then on any early BGTask fire. Registering here in
        // init() is the crash-safety guarantee (plan's R1 fix).
        let box = Self.schedulerBox
        OvernightScheduler.registerBackgroundTask { task in
            Task {
                guard let scheduler = box.value else {
                    Self.logger.warning("BGTask fired before scheduler ready; completing as failure so iOS retries")
                    task.setTaskCompleted(success: false)
                    return
                }
                await scheduler.handleBackgroundRefresh(task)
            }
        }
        Self.logger.info("BGTaskScheduler registered identifier=\(OvernightScheduler.backgroundTaskIdentifier, privacy: .public)")
    }

    var body: some Scene {
        WindowGroup {
            // `overnightScheduler` is passed as a constructor parameter rather than via
            // SwiftUI's `.environment(_:)` because it's an `actor` (not `@Observable`) —
            // same constraint as MemoryStore. Downstream views either read it here in
            // RootView's closure, or access it through RootView's state-transition hook.
            RootView(overnightScheduler: overnightScheduler)
                .environment(permissions)
                .environment(audioKeepalive)
                .environment(scheduler)
                .environment(soundEngine)
                .environment(visionVerifier)
                .environment(weeklyCoach)
                .environment(streakService)
                // NOTE: MemoryStore + OvernightScheduler are Swift `actor`s, not `Observable`,
                // so SwiftUI's .environment(_:) refuses them. MemoryStore reaches views via
                // `visionVerifier.memoryStore`; OvernightScheduler is passed directly to
                // RootView above.
                .task { bootstrapIfNeeded() }
        }
        .modelContainer(modelContainer)
    }

    private func bootstrapIfNeeded() {
        guard !didBootstrap else { return }
        didBootstrap = true
        audioKeepalive.start()
        wireSchedulerCallbacks()

        // Wave 5 G1 (§12.4-G1): defensive backfill for the 24h grace window.
        // Users who onboarded BEFORE the G1 code shipped (baseline already
        // persisted, no `firstInstallAtKey` on disk) get a fresh 24h grace
        // clock on first G1-aware launch — see the `recordFirstInstallIfNeeded`
        // docstring for why this is deliberate rather than "grandfathered
        // in as post-grace". New users who complete onboarding after G1
        // ships have the timestamp written earlier (from
        // OnboardingFlowView.persistBaseline) so this call is idempotent.
        AlarmScheduler.recordFirstInstallIfNeeded()
        // Late-bind the scheduler into the verifier so VisionVerifier.verify(...) can drive
        // phase transitions on VERIFIED / REJECTED / RETRY without the verifier holding a
        // non-optional scheduler reference (which would couple it at test-time).
        visionVerifier.scheduler = scheduler

        // Recover any fire that started in a prior session but never resolved (force-quit
        // during ring). Persists an UNRESOLVED WakeAttempt so the audit trail records the
        // missed wake instead of silently forgetting it.
        scheduler.recoverUnresolvedFireIfNeeded()
        scheduler.scheduleNextFireIfEnabled()

        // Wave 2.4 B4 fix: flush any pending WakeAttempt rows queued from previous
        // launches whose SwiftData save failed. Must run AFTER persistAttempt is wired
        // (done by wireSchedulerCallbacks above) so the flush's retry attempts can
        // reach ModelContext. Runs in a MainActor Task because AlarmScheduler is
        // @MainActor-isolated and persistAttempt reads the captured mainContext.
        Task { @MainActor [scheduler] in
            await scheduler.flushPendingAttempts()
        }

        // Wave 5 H3: prime the streak badge from the existing WakeAttempt
        // history. AlarmSchedulerView also recomputes on appear, but priming
        // here means RootView's first render sees an accurate streak if the
        // user launches the app and immediately sees the scheduler screen.
        // The fetch runs on the main context (@MainActor) so `@Model`
        // instances stay on their owning actor per SwiftData's contract.
        recomputeStreakFromStore()

        // Single serialized Task for the three steps that must run in order
        // (M1 + R7 fix): (1) MemoryStore bootstrap → expose store to verifier,
        // (2) stale-handle cleanup → *awaited* so the auto-trigger below sees
        // the post-cleanup UserDefaults state, (3) auto-trigger overnight
        // session if bedtime just passed.
        //
        // Previously: three separate `Task { ... }` blocks with no ordering
        // guarantee. Auto-trigger could fire before memoryStore bootstrap
        // completed (→ verifier's memoryStore stayed nil on the first verify),
        // or before cleanupStale terminated the previous day's session (→
        // auto-trigger saw the stale handle and skipped, leaving us with no
        // overnight session AND a now-terminated-by-cleanup Managed Agent).
        Task { @MainActor in
            await self.bootstrapMemoryStore()
            await self.cleanupStaleOvernightSessionIfNeeded()
            await self.autoTriggerOvernightSessionIfNeeded()
        }
    }

    /// (1/3) Bootstrap the on-disk memory store and late-bind it into the
    /// VisionVerifier. Run inside the bootstrap serial Task so the subsequent
    /// steps observe the store as either wired (bootstrap succeeded) or nil
    /// (bootstrap failed — verify() handles nil-store as memory-less mode).
    ///
    /// Wave 2.4 R14: after the store is wired, flush any pending memory writes
    /// queued from previous launches. Must be after assignment so VisionVerifier's
    /// `memoryStore` reference is non-nil; otherwise flushMemoryWriteQueue early-
    /// returns with "no memoryStore wired" and the backlog grows indefinitely.
    private func bootstrapMemoryStore() async {
        do {
            try await memoryStore.bootstrapIfNeeded()
            // Only expose the store to the verifier AFTER bootstrap completes so
            // the first verify() call can never win the directory-creation race.
            // (The actor's read() handles missing-dir gracefully via .empty, but
            // moving the assignment here makes the invariant visible in the code
            // shape — S6 in memory-tool-findings.md.)
            visionVerifier.memoryStore = memoryStore
            await visionVerifier.flushMemoryWriteQueue()
        } catch {
            Self.logger.error("MemoryStore bootstrap failed: \(error.localizedDescription, privacy: .public)")
            // Bootstrap failed — do NOT expose the store. read() would still work
            // (it early-returns .empty on missing dir), but writes would fail
            // repeatedly — better to run memory-less for this launch.
        }
    }

    /// (2/3) Launch-time stale-handle cleanup. C.1 cost-containment: Managed
    /// Agents charges $0.08/hr while a session is running; a crash during the
    /// night leaves the session meter running until its 24h ceiling. Catching
    /// it on next launch caps the cost at "time until next launch" instead.
    ///
    /// R7 fix: this is now *awaited* rather than spawned as a fire-and-forget
    /// Task, so the auto-trigger step below observes the cleared
    /// UserDefaults handle and decides correctly whether to open a new
    /// session. Previously the two steps raced: cleanup could still be in
    /// flight when the trigger read `activeHandleKey`, producing non-
    /// deterministic "skip vs. proceed" outcomes depending on scheduling.
    private func cleanupStaleOvernightSessionIfNeeded() async {
        guard let staleHandle = UserDefaults.standard.string(forKey: OvernightScheduler.activeHandleKey) else {
            return
        }
        Self.logger.warning("Found stale overnight handle on launch; attempting cleanup")
        await overnightScheduler.cleanupStale(handle: staleHandle)
    }

    /// (3/3) Auto-kick the overnight session when the user launches the app
    /// after their configured bedtime has already passed today. C.3 BLOCKING
    /// fix: without this, `startOvernightSession` had zero production call
    /// sites — the Layer 3 pipeline was dead code despite being wired
    /// end-to-end.
    ///
    /// "Bedtime passed recently" = within the last 12 hours. `nextBedtime(after:)`
    /// always returns a future date (today's if still upcoming, else tomorrow's),
    /// so the most recent bedtime is `nextBedtime - 24h`. If that was within the
    /// last 12h AND bedtime is enabled, start the session now. The 12h window
    /// intentionally undershoots a full day to avoid kicking a session in the
    /// afternoon after a missed bedtime — by then the morning briefing would be
    /// stale.
    ///
    /// B3 note: we no longer pre-check the active-handle UserDefaults here.
    /// `startOvernightSession` now holds the single source of truth for
    /// re-entrancy (`sessionCreationInFlight` + post-actor re-check). Leaving
    /// the pre-check here would re-introduce the TOCTOU window B3 aims to
    /// close.
    ///
    /// The real-bedtime-in-future path (user opens app earlier in the evening)
    /// still needs a proper scheduled Task to fire at 23:00; that's a Day-4
    /// follow-up. The launch-side trigger covers the demo case and the common
    /// "I opened the app as I went to bed" case.
    private func autoTriggerOvernightSessionIfNeeded() async {
        let settings = BedtimeSettings.load()
        guard settings.isEnabled else { return }
        guard let nextBedtime = settings.nextBedtime(after: .now) else { return }
        let mostRecentBedtime = nextBedtime.addingTimeInterval(-24 * 3600)
        let secondsSinceBedtime = Date.now.timeIntervalSince(mostRecentBedtime)
        guard secondsSinceBedtime > 0, secondsSinceBedtime < 12 * 3600 else { return }

        Self.logger.info("Auto-triggering startOvernightSession (bedtime was \(Int(secondsSinceBedtime / 60), privacy: .public)min ago)")
        await overnightScheduler.startOvernightSession()
    }

    /// Wave 5 H3: fetch WakeAttempt rows from the main context and hand them
    /// to StreakService for re-derivation. Called from `bootstrapIfNeeded`
    /// (so the badge is primed before any view renders) and from the
    /// VERIFIED transition in RootView (so a just-landed verify bumps the
    /// streak count without waiting for the @Query observer to tick).
    ///
    /// A fetch failure is non-fatal — the badge stays at (0, 0) and the
    /// next view-level `@Query` update will supply a fresh snapshot via
    /// `AlarmSchedulerView.onChange(of: wakeAttempts.count)`.
    private func recomputeStreakFromStore() {
        let context = modelContainer.mainContext
        do {
            let attempts = try context.fetch(FetchDescriptor<WakeAttempt>())
            streakService.recompute(from: attempts)
        } catch {
            Self.logger.error("Streak recompute fetch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Install the scheduler's late-bound callbacks. Each guard makes the call idempotent
    /// in case the scheduler instance is reused across SwiftUI identity churn.
    private func wireSchedulerCallbacks() {
        wireSchedulerOnFireIfNeeded()
        wireSchedulerPersistenceIfNeeded()
    }

    private func wireSchedulerOnFireIfNeeded() {
        guard scheduler.onFire == nil else { return }
        scheduler.onFire = { [audioKeepalive, soundEngine] firedAt in
            Self.logger.info("onFire received fire at \(firedAt.ISO8601Format(), privacy: .public)")
            // Phase 8 product fix: ring-ceiling subsystem removed. The alarm
            // now plays until the user completes Proof (markCaptureCompleted
            // → stop) or force-quits the app. See AlarmSoundEngine header
            // for the rationale; tl;dr a self-commitment alarm cannot
            // contain its own escape hatch without breaking the contract.
            guard let url = Bundle.main.url(forResource: "alarm", withExtension: "m4a") else {
                // R7 fix retained: if alarm.m4a is missing from the bundle
                // (build-config regression), we still start the soundEngine
                // so the ramp logger fires. Audio will be silent but the
                // ringing UI + verification flow still progress.
                Self.logger.fault("alarm.m4a missing from bundle — silent alarm")
                soundEngine.start(setVolume: { _ in /* no audio player to mutate */ })
                return
            }
            audioKeepalive.playAlarmSound(url: url)
            soundEngine.start(setVolume: { volume in
                audioKeepalive.setAlarmVolume(volume)
            })
        }
    }

    /// Wire the WakeAttempt persistence closure that the scheduler invokes on TIMEOUT and
    /// UNRESOLVED paths. The model context is captured here so AlarmScheduler stays free of
    /// SwiftData coupling.
    ///
    /// Wave 2.4 B4 fix: the closure now THROWS on save failure. Previously the catch
    /// branch did `context.rollback()` + `logger.error` and swallowed the outcome —
    /// AlarmScheduler's call-site couldn't tell success from failure, so the audit-trail
    /// row vanished while `lastFireAt` had already been cleared in handleRingCeiling().
    /// Propagating the throw lets `AlarmScheduler.recordAttempt` enqueue the failed row
    /// into `PendingWakeAttemptQueue` for a next-launch retry.
    private func wireSchedulerPersistenceIfNeeded() {
        guard scheduler.persistAttempt == nil else { return }
        let context = modelContainer.mainContext
        scheduler.persistAttempt = { verdict, scheduledFor in
            let attempt = WakeAttempt(scheduledAt: scheduledFor)
            attempt.verdict = verdict.rawValue
            attempt.dismissedAt = .now
            context.insert(attempt)
            do {
                try context.save()
                Self.logger.info("Persisted WakeAttempt verdict=\(verdict.rawValue, privacy: .public) scheduledFor=\(scheduledFor.ISO8601Format(), privacy: .public)")
            } catch {
                // Rollback before re-throw so the in-memory context doesn't carry the
                // uncommitted insert into the next save cycle. The re-throw hands the
                // error to AlarmScheduler.recordAttempt which enqueues to the retry queue.
                Self.logger.error("Failed to persist WakeAttempt verdict=\(verdict.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
                context.rollback()
                throw error
            }
        }
    }
}

// MARK: - Root

struct RootView: View {
    /// `actor` reference — held directly rather than through `@Environment` because
    /// SwiftUI environment requires `@Observable` types. See WakeProofApp.body for
    /// the rationale.
    let overnightScheduler: OvernightScheduler

    @Query private var baselines: [BaselinePhoto]

    /// Wave 5 H1 (§12.3-H1): pull the most recent VERIFIED WakeAttempt so we
    /// can surface its `observation` field in MorningBriefingView. The
    /// `#Predicate` filters by the persisted string verdict (not the enum —
    /// WakeAttempt stores the raw String so adding Verdict cases is
    /// migration-free; the enum exists only for safe reads). Descending order
    /// by `capturedAt` with the non-nil filter gives "the VERIFIED attempt
    /// from this morning" at index 0 whenever a verify just completed; older
    /// VERIFIED rows slip to index 1+. The briefing cover is only presented
    /// on the `(.verifying → .idle)` transition so the .first below IS the
    /// current morning's attempt in practice.
    @Query(
        filter: #Predicate<WakeAttempt> { $0.verdict == "VERIFIED" && $0.capturedAt != nil },
        sort: \WakeAttempt.capturedAt,
        order: .reverse
    )
    private var verifiedAttempts: [WakeAttempt]

    @Environment(AlarmScheduler.self) private var scheduler
    @Environment(AudioSessionKeepalive.self) private var audioKeepalive
    @Environment(AlarmSoundEngine.self) private var soundEngine
    @Environment(VisionVerifier.self) private var visionVerifier
    /// Wave 5 H3: streak service shared with AlarmSchedulerView. RootView
    /// triggers a recompute on the `(.verifying → .idle)` transition so the
    /// home-view badge is already up-to-date when the briefing cover
    /// dismisses and AlarmSchedulerView becomes visible again.
    @Environment(StreakService.self) private var streakService
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    /// B5: briefing finalized on the (.verifying → .idle) transition. Latched
    /// here so the fullScreenCover reads a stable reference even after its
    /// background Task resolves. The `BriefingResult` enum carries all three
    /// outcomes (success / noSession / failure) — the View branches to render
    /// distinct copy per reason. `MorningBriefing` SwiftData rows are still
    /// written on the success branch for audit trail / weekly-coach consumption.
    @State private var latestBriefingResult: BriefingResult?
    @State private var showBriefing = false

    private static let logger = Logger(subsystem: LogSubsystem.overnight, category: "briefing-view")

    var body: some View {
        ZStack {
            if baselines.isEmpty {
                OnboardingFlowView()
            } else {
                AlarmSchedulerView(overnightScheduler: overnightScheduler)
            }

            // Alarm overlay sits on top of whatever's below. Using a ZStack instead of a
            // fullScreenCover because on iOS 26, swapping cover content mid-presentation
            // (ringing → capturing) triggers SwiftUI's dismiss+re-present cycle, during
            // which the cover's binding setter fires false and cascades through stopRinging.
            // ZStack keeps everything in a single stable view tree; content swaps are free.
            if scheduler.phase != .idle {
                alarmPhaseContent
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: scheduler.phase)
        .fullScreenCover(isPresented: $showBriefing) {
            // Presented on VERIFIED. `latestBriefingResult` carries the
            // BriefingResult enum — MorningBriefingView branches on each case
            // (success / noSession / failure) to render distinct copy.
            //
            // Wave 5 H1: the latest VERIFIED WakeAttempt's observation (if any)
            // piggybacks on the same presentation. `verifiedAttempts.first`
            // is the most recent VERIFIED row per the @Query sort; at the
            // moment the cover opens it's this morning's attempt. Nil when
            // Claude didn't emit one, or when the pre-H1 row has no field.
            // Wave 5 H2: the user's pre-sleep commitment note piggybacks on
            // the same cover presentation. Read directly from
            // `scheduler.window.commitmentNote` at present-time — the value
            // snapshots into MorningBriefingView's `let` parameter so if the
            // user clears the note mid-morning after waking (e.g. they open
            // AlarmSchedulerView and delete the text before dismissing the
            // briefing), the cover keeps rendering the value that was in
            // effect when the alarm fired. The note lives with the current
            // wake intent, NOT the per-fire WakeAttempt row — deliberate:
            // tomorrow's note is tomorrow's intent.
            MorningBriefingView(
                result: latestBriefingResult,
                observation: verifiedAttempts.first?.observation,
                commitmentNote: scheduler.window.commitmentNote,
                // Wave 5 H5: pipe the streak service's current-day count
                // through so the opt-in Share button can gate on it AND the
                // rendered card can use it as the hero number. Read from
                // the @Environment service (same one driving the badge in
                // AlarmSchedulerView) so both surfaces agree. The service is
                // recomputed on the VERIFIED transition above — by the time
                // the cover presents, the count reflects this morning's
                // just-landed attempt.
                currentStreak: streakService.currentStreak
            ) {
                showBriefing = false
                latestBriefingResult = nil
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                // Catches the case where Task.sleep was suspended past its fire time overnight
                // — the backup notification will have beeped; this promotes the in-app ringing UI.
                scheduler.reconcileAfterForeground()
            }
        }
        .onChange(of: scheduler.phase) { oldPhase, newPhase in
            switch (oldPhase, newPhase) {
            case (.verifying, .idle):
                // VERIFIED path — alarm stops, verifier state resets.
                soundEngine.stop()
                audioKeepalive.stopAlarmSound()
                visionVerifier.resetForNewFire()
                // Wave 5 H3: recompute the streak now that the VERIFIED
                // WakeAttempt row has been written. Re-fetches the full
                // table from the main context so the service sees the
                // freshly-persisted row. AlarmSchedulerView's
                // `.onChange(of: wakeAttempts.count)` observer would also
                // catch this next time the view is visible, but the
                // recompute here means the streak is already correct when
                // the briefing cover dismisses — no stale-count flicker.
                Self.recomputeStreak(streakService: streakService, context: modelContext)
                // Surface the overnight briefing right after a successful verify. The
                // fetch runs in a detached Task so the scheduler's isolation boundary
                // is honoured; the main-actor hop afterwards drives the cover binding.
                // The whole thing is ancillary — a failure here surfaces a distinct
                // error card in MorningBriefingView (B5 fix) rather than the
                // misleading "no briefing" placeholder the previous code used.
                //
                // B5 fix: `BriefingResult` replaces `BriefingDTO?`. The enum carries
                // three outcomes (success / noSession / failure) so each case renders
                // distinct UI — a network hiccup no longer looks like a fresh
                // install.
                //
                // R5 fix (carried over): we materialise the SwiftData `@Model` from
                // the DTO on the main actor (container.mainContext) — the scheduler
                // actor only produces Sendable values across the isolation boundary.
                let scheduler = overnightScheduler
                let container = modelContext.container
                Task { @MainActor in
                    let result = await scheduler.finalizeBriefing(forWakeDate: .now)
                    switch result {
                    case .success(let dto):
                        // Success: persist a `MorningBriefing` row for audit /
                        // weekly-coach consumption, then show the cover. Persist
                        // failure is non-fatal — the in-memory latched DTO is
                        // enough to render this morning's cover; we just lose
                        // the historical row.
                        let briefing = MorningBriefing(
                            forWakeDate: dto.forWakeDate,
                            briefingText: dto.briefingText,
                            sourceSessionID: dto.sourceSessionID,
                            memoryUpdateApplied: dto.memoryUpdateApplied
                        )
                        let mainContext = container.mainContext
                        mainContext.insert(briefing)
                        do {
                            try mainContext.save()
                            Self.logger.info("VERIFIED transition: briefing inserted chars=\(dto.briefingText.count, privacy: .public)")
                        } catch {
                            Self.logger.error("VERIFIED transition: briefing persist failed: \(error.localizedDescription, privacy: .public)")
                            mainContext.rollback()
                        }
                    case .noSession:
                        Self.logger.info("VERIFIED transition: no briefing (no active session)")
                    case .failure(let reason, _):
                        // Preserve the failure for UI rendering. Intentionally do
                        // NOT persist a MorningBriefing row — the SwiftData table is
                        // reserved for real briefings the weekly coach can consume.
                        // The audit trail for failures lives in the Logger stream.
                        Self.logger.warning("VERIFIED transition: briefing failure reason=\(reason.rawValue, privacy: .public)")
                    }
                    latestBriefingResult = result
                    showBriefing = true
                }
            case (_, .verifying):
                // Reduce but do not mute during verification; Decision 2 failure-mode table says
                // a full mute makes the user think they already succeeded. Applies to both the
                // initial .capturing → .verifying hop AND the anti-spoof re-capture → .verifying hop.
                //
                // B6 fix: pauseRamp() BEFORE setAlarmVolume(0.2) so the ramp's next 5s tick
                // doesn't overwrite our externally-set volume back to the escalation curve
                // (which previously caused an audible sawtooth pattern during verification).
                soundEngine.pauseRamp()
                audioKeepalive.setAlarmVolume(0.2)
            case (.verifying, .ringing):
                // Verification failed (REJECTED or network error). Restore full volume and reset
                // the verifier so a user-initiated "Prove you're awake" retry starts with a fresh
                // two-attempt budget rather than carrying over the previous fire's state.
                // Ramp stays paused — user has engaged at least once, full-volume attention is
                // warranted on the retry path (no benefit to re-escalating from 0.3).
                audioKeepalive.setAlarmVolume(1.0)
                visionVerifier.resetForNewFire()
            // .verifying → .antiSpoofPrompt intentionally has no volume change: the anti-spoof
            // view keeps the ring volume at 0.2 (already reduced above) because the user is about
            // to re-capture in seconds. Adding a restore-then-reduce cycle would be a noticeable click.
            default:
                break
            }
        }
    }

    @ViewBuilder
    private var alarmPhaseContent: some View {
        switch scheduler.phase {
        case .idle:
            EmptyView()
        case .ringing:
            AlarmRingingView(onRequestCapture: { scheduler.beginCapturing() })
        case .capturing:
            CameraCaptureFlow(onSuccess: { attempt in
                // Hand the WakeAttempt to the verifier. Volume reduction + stop chain are
                // driven by the .onChange(of: scheduler.phase) handler below (keyed off the
                // .capturing → .verifying → .idle/.ringing transitions the verifier triggers).
                Task { @MainActor in
                    if let baseline = baselines.first {
                        await visionVerifier.verify(
                            attempt: attempt,
                            baseline: baseline,
                            context: modelContext
                        )
                    } else {
                        // No baseline means onboarding incomplete. RootView gates on
                        // baselines.isEmpty before showing the scheduler, so hitting this
                        // branch is a programmer error — surface it rather than hang.
                        scheduler.returnToRingingWith(error: "No baseline photo — re-run onboarding.")
                    }
                }
            })
        case .verifying:
            VerifyingView()
        case .antiSpoofPrompt(let instruction):
            // Wired directly to the A.6 view; B.3 may refine with additional context later.
            AntiSpoofActionPromptView(
                instruction: instruction,
                onReady: { scheduler.beginCapturing() }
            )
        case .disableChallenge:
            // Wave 5 G1 (§12.4-G1): disable-alarm mirror surface. The view owns
            // its own baseline lookup + verifier hand-off so the scheduler's
            // switch doesn't need to branch per phase — DisableChallengeView
            // internally routes to VisionVerifier.verifyDisableChallenge on
            // capture success, which drives the scheduler back to .idle.
            DisableChallengeView()
        }
    }

    /// Wave 5 H3: pull the WakeAttempt rows from the given main-actor model
    /// context and hand them to `StreakService`. Static so the VERIFIED
    /// transition handler can call it without closure-capturing `self`
    /// (which would thread through the Task to no benefit). The caller is
    /// already on the main actor — `@MainActor` on the helper enforces that
    /// at the compiler level.
    ///
    /// Non-fatal on fetch failure: the service's existing values stay, and
    /// AlarmSchedulerView's @Query observer will supply fresh data on next
    /// appearance.
    @MainActor
    private static func recomputeStreak(
        streakService: StreakService,
        context: ModelContext
    ) {
        do {
            let attempts = try context.fetch(FetchDescriptor<WakeAttempt>())
            streakService.recompute(from: attempts)
        } catch {
            logger.error("Post-VERIFIED streak recompute fetch failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - File-scope helpers

/// Weak bridge from the file-scope BGTask launch handler registered in
/// `WakeProofApp.init()` to the scheduler instance. Declared at file scope (not nested
/// inside the struct) so the launch-handler closure — which must be captured before
/// the struct has any stable instance identity — can reference it without a `self`
/// capture. Weak because this box should never extend the scheduler's lifetime.
///
/// L8 (Wave 2.7): `@unchecked Sendable` + `nonisolated(unsafe)` is the standard
/// Swift 6 migration pattern for single-assignment-at-init + ObjC-runtime-atomic
/// weak references. Invariant: `value` is assigned exactly once during
/// `WakeProofApp.init()` (synchronously, before any concurrent read path is
/// wired), and all subsequent reads happen on the MainActor (the BGTask launch
/// handler enters a `Task { }` which hops before touching `value`). Weak
/// reference reads/writes are atomic under the ObjC runtime, so the race-free
/// guarantee holds even without a lock. If future code ever mutates `value`
/// post-init, this annotation becomes unsound and the lock must be added.
final class OvernightSchedulerBox: @unchecked Sendable {
    nonisolated(unsafe) weak var value: OvernightScheduler?
}
