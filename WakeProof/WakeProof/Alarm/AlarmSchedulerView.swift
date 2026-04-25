//
//  AlarmSchedulerView.swift
//  WakeProof
//
//  The post-onboarding home screen: configure the wake window, toggle the alarm,
//  and (DEBUG) fire immediately for demo video capture.
//
//  UI 3.1: Rewritten from Form to NavigationStack { ScrollView { VStack } }
//  using design-system components (WPSection, WPCard, WPHeroTimeDisplay,
//  WPStreakBadge). All Wave 5 wiring preserved byte-identically — no business
//  logic was changed: G1 proxy Binding, H2 commitment-note truncation,
//  H3 streak recompute, H5 share toggle, DEBUG bypass.
//

import SwiftData
import SwiftUI
import os

struct AlarmSchedulerView: View {

    /// `actor` reference — passed by constructor because SwiftUI's `.environment(_:)`
    /// refuses non-`@Observable` types. See WakeProofApp.body for the rationale.
    /// Only the DEBUG buttons read this; the release build never touches it.
    let overnightScheduler: OvernightScheduler

    @Environment(AlarmScheduler.self) private var scheduler
    @Environment(AudioSessionKeepalive.self) private var audioKeepalive
    @Environment(PermissionsManager.self) private var permissions
    @Environment(WeeklyCoach.self) private var weeklyCoach
    /// P14 (Stage 6 Wave 2): surfaces `VisionVerifier.requiresReinstall` to
    /// the systemBanner so an `invalidUserUUID` MemoryStore read gets a user-
    /// visible warning. Previously that error was silently swallowed in the
    /// verify-time catch, indistinguishable from a fresh-install empty-memory
    /// case. VisionVerifier is already wired into the app via
    /// `.environment(visionVerifier)` — we just read the flag here.
    @Environment(VisionVerifier.self) private var visionVerifier
    /// Wave 5 H3 (§12.3-H3): injected from WakeProofApp so the badge and
    /// calendar read a single source of derived streak state. Recomputes on
    /// view appear so a navigation-back-and-forth reflects any attempts
    /// added since the last render (e.g. a VERIFIED verify that completed in
    /// between).
    @Environment(StreakService.self) private var streakService

    /// Wave 5 H3: the full WakeAttempt history drives both the streak-service
    /// recompute and the StreakCalendarView grid. No filter / no sort — the
    /// service and the grid do their own day-keyed aggregation, and a
    /// full-history scan stays cheap on-device (a few hundred rows at most).
    /// `@Query` gets auto-invalidated by SwiftData on any WakeAttempt mutation,
    /// so the badge reacts to each VERIFIED transition without extra plumbing.
    @Query private var wakeAttempts: [WakeAttempt]

    @State private var startTime: Date = .now
    @State private var isEnabled: Bool = false

    /// Wave 5 H2 (§12.3-H2): optional pre-sleep commitment note, surfaced on
    /// MorningBriefingView post-verified as the user's self-authored anchor
    /// (HOOK_S0_6 / HOOK_S2_5 / HOOK_S7_5). Stored as `String` (not `String?`)
    /// because TextField binds cleanly to non-optional; empty-after-trim →
    /// persists as nil in `save()` so the downstream briefing render treats
    /// "unset" and "cleared" the same way. Loaded from `scheduler.window.commitmentNote`
    /// on appear so the TextField reflects the previously-saved note.
    @State private var commitmentNote: String = ""

    /// R9 fix: mirrors the actor-local error from OvernightScheduler so the
    /// banner can surface "overnight analysis couldn't start tonight — we'll
    /// retry next launch". Refreshed on view appear. A successful
    /// `startOvernightSession` clears the actor's copy; we refresh on next
    /// app-active bounce so the banner clears without a manual reload.
    ///
    /// SQ5 (Stage 4): renamed from `overnightStartError` to match the scheduler
    /// actor's accessor (`lastSessionStartError()`). AlarmSchedulerView is
    /// already scoped to the overnight domain — the `overnight` prefix was
    /// redundant and made grep harder when tracing the value through storage →
    /// accessor → View.
    @State private var lastSessionStartError: String?

    /// P5 (Stage 6 Wave 1): inline warning shown when the Save & schedule button
    /// tap hit a `WakeWindow.save()` failure. Mirrors BedtimeStep's `saveFailureMessage`
    /// pattern — cleared on the next save tap so a successful retry dismisses the
    /// warning without the user having to navigate away. Appearance-only state
    /// (no UserDefaults persistence) because the alarm scheduler's in-memory
    /// window already reflects the user's intent; the warning is just the nudge
    /// to retry so the setting survives next launch.
    @State private var windowSaveFailureMessage: String?

    /// P10 (Stage 6 Wave 2): cumulative count of memory-write rows dropped
    /// after exhausting the `PendingMemoryWriteQueue.maxRetryAttempts` cap.
    /// Sourced from UserDefaults on view appear so the banner reflects every
    /// drop since install (not just this session). Surfaces at the lowest
    /// priority in `systemBanner` — the alarm itself isn't affected, only
    /// Layer 2 memory fidelity.
    @State private var droppedMemoryWrites: Int = 0

    /// Wave 5 H5 (§12.3-H5): opt-in gate for the Share button on
    /// MorningBriefingView. Default `false` — per HOOK_S4_5, forced sharing
    /// is an autonomy violation that correlates with app-abandonment. The
    /// toggle in the Form's "Sharing" section below binds to this.
    /// @AppStorage key matches MorningBriefingView's matching @AppStorage so
    /// both surfaces read the same UserDefaults bool without any plumbing.
    @AppStorage(ShareCardModel.shareCardEnabledKey) private var shareCardEnabled: Bool = false

    /// Wave 5 G1 (§12.4-G1): DEBUG-only toggle that lets demo recordings flip
    /// the alarm off without the vision-verified challenge. The underlying
    /// UserDefaults key is consumed by `AlarmScheduler.requestDisable` inside a
    /// `#if DEBUG` guard — release builds never read the value. The `@AppStorage`
    /// wrapper on the view side stays compiled in both configurations because
    /// `#if DEBUG` around a stored-property wrapper declaration is finicky and
    /// we want a single source of truth per key; the Toggle that renders it
    /// IS wrapped in `#if DEBUG`, so release UI can't flip the bit in practice.
    @AppStorage(AlarmScheduler.disableChallengeBypassKey) private var disableChallengeBypassEnabled: Bool = false

    private let logger = Logger(subsystem: LogSubsystem.alarm, category: "schedulerView")

    var body: some View {
        NavigationStack {
            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(spacing: WPSpacing.xl) {

                    // MARK: — Banner strip
                    // Priority chain defined by `systemBanner` (reinstall >
                    // notifications > audio > HealthKit > overnight > memory).
                    // Rendered at the very top so the user sees the most urgent
                    // alarm-contract problem before interacting with controls.
                    if let banner = systemBanner {
                        WPCard(padding: WPSpacing.md) {
                            Text(banner)
                                .wpFont(.callout)
                                .foregroundStyle(Color.wpAttempted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    // MARK: — Fresh-install empty hero
                    // Renders only when the user hasn't yet armed an alarm AND
                    // has no attempt history — the home is otherwise dominated
                    // by a ticking clock with no context. The CTA scrolls to
                    // the wake-window section (id: "wake-window") so the user
                    // can complete their first contract without hunting for it.
                    if scheduler.nextFireAt == nil, wakeAttempts.isEmpty {
                        WPCard {
                            VStack(alignment: .leading, spacing: WPSpacing.md) {
                                Text("Your contract starts the night you set an alarm.")
                                    .wpFont(.title3)
                                    .foregroundStyle(Color.wpChar900)
                                Button("Set your first alarm") {
                                    withAnimation {
                                        scrollProxy.scrollTo("wake-window", anchor: .top)
                                    }
                                }
                                .buttonStyle(.primaryConfirm)
                            }
                        }
                    }

                    // MARK: — Hero block
                    // Live ticking clock, next-ring strip, streak badge.
                    VStack(spacing: WPSpacing.sm) {
                        WPHeroTimeDisplay(style: .medium, foreground: .wpChar900)
                            .frame(maxWidth: .infinity, alignment: .center)

                        if let next = scheduler.nextFireAt {
                            Text("Next ring \(next.formatted(date: .abbreviated, time: .shortened))")
                                .wpFont(.footnote)
                                .foregroundStyle(Color.wpChar500)
                        }

                        // Wave 5 H3: streak badge. Only renders when there's
                        // something meaningful to show — the helper
                        // `WPStreakBadge.shouldRender(...)` returns false for
                        // a fresh install (both streaks 0) so the badge is
                        // absent rather than showing a bleak "0-day streak".
                        // Wrapping in a NavigationLink makes the badge itself
                        // a one-tap entry to the calendar — discoverability
                        // win vs requiring scroll-to "View streak calendar".
                        if WPStreakBadge.shouldRender(
                            currentStreak: streakService.currentStreak,
                            bestStreak: streakService.bestStreak
                        ) {
                            NavigationLink {
                                StreakCalendarView(attempts: wakeAttempts)
                            } label: {
                                WPStreakBadge(
                                    currentStreak: streakService.currentStreak,
                                    bestStreak: streakService.bestStreak
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // MARK: — First thing tomorrow (commitment note, Wave 5 H2)
                    // Positioned above the wake-window controls so setting the
                    // time naturally flows into "and what will you do when you
                    // wake up". Char counter footnote right-aligned below field.
                    WPSection("First thing tomorrow") {
                        WPCard {
                            VStack(alignment: .leading, spacing: WPSpacing.xs2) {
                                TextField(
                                    "First thing tomorrow-you needs to do (optional)",
                                    text: $commitmentNote
                                )
                                .wpFont(.body)
                                .textFieldStyle(.plain)
                                .submitLabel(.done)
                                // Wave 5 H2: Cap using `.count` (grapheme-cluster
                                // measure) — matches user intuition for emoji / CJK,
                                // same measure used by the test invariant. Trim off
                                // the tail on overflow so the binding stays in-sync;
                                // IME pushes that exceed the cap truncate silently
                                // (expected — the TextField's visible content matches
                                // what will be saved).
                                .onChange(of: commitmentNote) { _, newValue in
                                    if newValue.count > WakeWindow.commitmentNoteMaxLength {
                                        commitmentNote = String(newValue.prefix(WakeWindow.commitmentNoteMaxLength))
                                    }
                                }
                                Text("\(commitmentNote.count)/\(WakeWindow.commitmentNoteMaxLength)")
                                    .wpFont(.footnote)
                                    .foregroundStyle(Color.wpChar500)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                        }
                    }

                    // MARK: — Wake window
                    // .id("wake-window") tags this section so the fresh-install
                    // empty hero CTA above can call scrollProxy.scrollTo() to
                    // bring it into view without the user hunting for it.
                    WPSection("Wake window") {
                        WPCard {
                            VStack(spacing: WPSpacing.xs2) {
                                DatePicker(
                                    "Start",
                                    selection: $startTime,
                                    displayedComponents: .hourAndMinute
                                )
                                .wpFont(.body)

                                Divider()

                                // Wave 5 G1 (§12.4-G1): the enabled toggle is no longer a
                                // plain Binding — flipping OFF goes through the scheduler's
                                // disable-challenge policy so evening-self can't silence
                                // the contract without the same proof as morning-self. Flipping
                                // ON is unchanged (the contract STARTS with user consent). The
                                // proxy's `set` block is responsible for either propagating
                                // the new value or calling `handleDisableRequest()`; in the
                                // challenge-required case it leaves `isEnabled` at its
                                // current value so the toggle visibly stays ON until the
                                // challenge resolves (see `.onChange(of: scheduler.window.isEnabled)`
                                // below which then syncs the local state).
                                Toggle("Alarm enabled", isOn: Binding(
                                    get: { isEnabled },
                                    set: { newValue in
                                        if newValue {
                                            // Enabling is just the local state flip — the
                                            // user still has to tap "Save & schedule" below
                                            // to persist. This matches the prior behavior
                                            // exactly; we only intercept the OFF path.
                                            isEnabled = true
                                        } else {
                                            handleDisableRequest()
                                        }
                                    }
                                ))
                                .wpFont(.body)
                            }
                        }
                    }
                    .id("wake-window")

                    // MARK: — Save & schedule
                    VStack(spacing: WPSpacing.xs2) {
                        Button("Save & schedule") { save() }
                            .buttonStyle(.primaryConfirm)

                        // P5 (Stage 6 Wave 1): inline warning rendered immediately
                        // under the button so the user sees the failure at the
                        // point of action. Cleared on the next successful save.
                        if let windowSaveFailureMessage {
                            Text(windowSaveFailureMessage)
                                .wpFont(.footnote)
                                .foregroundStyle(Color.wpAttempted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    // MARK: — Your contract (calendar + investment dashboard)
                    // Wave 5 H3 + H4: secondary surfaces that READ state. Promoted
                    // from buried Form list-rows to side-by-side WPCards so the
                    // "Your commitment" (H4 dashboard) is a first-class entry —
                    // the user sees baseline-age / verified-mornings / insights
                    // counts within a tap. Section title "Your contract" frames
                    // both cards as artifacts of the user's signed wake-up
                    // contract rather than gamification stats.
                    WPSection("Your contract") {
                        HStack(spacing: WPSpacing.md) {
                            NavigationLink {
                                InvestmentDashboardView()
                            } label: {
                                WPCard(padding: WPSpacing.md) {
                                    VStack(alignment: .leading, spacing: WPSpacing.xs2) {
                                        Image(systemName: "book.closed")
                                            .wpFont(.title3)
                                            .foregroundStyle(Color.wpCoral)
                                        Text("Your commitment").wpFont(.headline)
                                        Text("Baseline age, mornings, insights")
                                            .wpFont(.footnote)
                                            .foregroundStyle(Color.wpChar500)
                                    }
                                }
                            }
                            .buttonStyle(.plain)

                            NavigationLink {
                                StreakCalendarView(attempts: wakeAttempts)
                            } label: {
                                WPCard(padding: WPSpacing.md) {
                                    VStack(alignment: .leading, spacing: WPSpacing.xs2) {
                                        Image(systemName: "calendar")
                                            .wpFont(.title3)
                                            .foregroundStyle(Color.wpVerified)
                                        Text("Streak calendar").wpFont(.headline)
                                        Text("Every verified morning")
                                            .wpFont(.footnote)
                                            .foregroundStyle(Color.wpChar500)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // MARK: — Sharing (Wave 5 H5)
                    // Copy deliberately names "manual" to pre-empt the user's
                    // "does this auto-post?" question — per HOOK_S4_5, nothing
                    // is auto-posted and we want that to be unambiguous in the
                    // settings surface itself (not just the privacy policy).
                    WPSection("Sharing") {
                        WPCard {
                            VStack(alignment: .leading, spacing: WPSpacing.xs2) {
                                Toggle("Allow sharing wake cards", isOn: $shareCardEnabled)
                                    .wpFont(.body)
                                Text("Generate a minimalist image of your streak + Claude's observation to share manually. Nothing auto-posts.")
                                    .wpFont(.footnote)
                                    .foregroundStyle(Color.wpChar500)
                            }
                        }
                    }

                    // MARK: — DEBUG section
                    #if DEBUG
                    WPSection("Debug") {
                        WPCard {
                            VStack(alignment: .leading, spacing: WPSpacing.sm) {
                                // Wave 5 G1 (§12.4-G1): DEBUG-only bypass toggle. Lets demo
                                // recordings flip the alarm off without the challenge. Ethics
                                // boundary: this is a self-commitment-device — the bypass
                                // MUST NOT ship in release builds. The `#if DEBUG` wrap on
                                // the Section covers this UI, and `AlarmScheduler.isDisable
                                // ChallengeBypassActive` (which reads the backing UserDefaults
                                // key) is itself `#if DEBUG` so release builds cannot honor
                                // the flag even if a prior DEBUG build wrote to the key.
                                Toggle("Bypass disable challenge (DEV)", isOn: $disableChallengeBypassEnabled)
                                Divider()
                                Button("Fire alarm now") { scheduler.fireNow() }
                                    .foregroundStyle(.red)
                                Divider()
                                Button("Start overnight session now") {
                                    // B3: the scheduler now holds the single source of truth
                                    // for "is a session already open" (sessionCreationInFlight
                                    // + UserDefaults re-check on the actor). No pre-actor
                                    // TOCTOU guard needed; calling this repeatedly is safe.
                                    Task { await overnightScheduler.startOvernightSession() }
                                }
                                Divider()
                                Button("Finalize briefing now") {
                                    Task {
                                        // B5: finalizeBriefing now returns a `BriefingResult`
                                        // enum rather than `BriefingDTO?`. DEBUG logging
                                        // mirrors the three cases so you can tell at a
                                        // glance whether the pipeline succeeded, had no
                                        // session, or hit a failure path.
                                        let result = await overnightScheduler.finalizeBriefing(forWakeDate: .now)
                                        switch result {
                                        case .success(let dto):
                                            logger.info("Debug finalize: success briefingText=\(dto.briefingText, privacy: .public)")
                                        case .noSession:
                                            logger.info("Debug finalize: noSession (no active handle)")
                                        case .failure(let reason, let message):
                                            logger.info("Debug finalize: failure reason=\(reason.rawValue, privacy: .public) message=\(message, privacy: .public)")
                                        }
                                    }
                                }
                            }
                        }
                    }
                    #endif

                    // MARK: — Weekly insight
                    WPSection("Weekly insight") {
                        WeeklyInsightView(
                            insight: weeklyCoach.currentInsight,
                            generatedAt: weeklyCoach.generatedAt
                        )
                    }

                }
                .padding(.horizontal, WPSpacing.xl2)
                .padding(.top, WPSpacing.xl)
                .padding(.bottom, WPSpacing.xl4)
            }
            // .immediately rather than .interactively — Phase 8 device test
            // on iPhone 17 Pro showed users expect any scroll to dismiss the
            // commitment-note keyboard (matches iOS Mail / Notes default).
            // .interactively would require the user to drag DOWN onto the
            // keyboard, which they don't intuit on a scroll-list surface.
            .scrollDismissesKeyboard(.immediately)
            // Apply ignoresSafeArea ONLY to the cream background — extending
            // it past the home indicator. Applying it to the ScrollView itself
            // cancels iOS 16+'s automatic keyboard safe-area inset, which
            // would obscure the commitment-note TextField on focus
            // (especially on iPhone SE where vertical space is tightest).
            .background(
                Color.wpCream100.ignoresSafeArea(edges: .bottom)
            )
            .navigationTitle("WakeProof")
            // Single .onAppear merging three formerly-separate appearance
            // refresh actions. Order matters:
            //   1. loadFromScheduler — populates @State from scheduler.window
            //      so the form fields reflect the persisted contract before
            //      any user interaction.
            //   2. refreshDroppedMemoryCount (P10) — UserDefaults read; cheap.
            //      Drives the lowest-priority systemBanner. No actor hop needed.
            //   3. recomputeStreak (Wave 5 H3) — pure derivation from the
            //      @Query-backed `wakeAttempts`. The bootstrap in WakeProofApp
            //      runs the first recompute before this view appears, so this
            //      covers "navigated back from the calendar". The
            //      .onChange(of: wakeAttempts.count) below covers "a row was
            //      added while the view was visible".
            .onAppear {
                loadFromScheduler()
                refreshDroppedMemoryCount()
                recomputeStreak()
            }
            // R9: refresh the overnight error banner snapshot whenever the
            // view comes back into focus. Quick one-shot poll of the actor;
            // the property is actor-local so we have to hop.
            .task { await refreshOvernightStartError() }
            .onChange(of: wakeAttempts.count) { _, _ in
                recomputeStreak()
            }
            // Wave 5 G1 (§12.4-G1): sync the local `isEnabled` state whenever
            // the scheduler's source-of-truth flips. Two paths drive this:
            //   (1) The disable challenge resolves VERIFIED — scheduler's
            //       `disableChallengeSucceeded()` calls updateWindow(...) which
            //       flips `scheduler.window.isEnabled` to false, and this
            //       observer mirrors the change into the local @State so the
            //       Toggle visually flips.
            //   (2) The grace / DEBUG bypass path — `handleDisableRequest` flips
            //       the local state immediately so no observer work is needed,
            //       BUT `save()` below ALSO writes scheduler.window.isEnabled
            //       = false, so the observer would double-fire with a no-op
            //       (both sides already false). Cheap no-op is fine here.
            .onChange(of: scheduler.window.isEnabled) { _, newValue in
                isEnabled = newValue
            }
            }   // end ScrollViewReader
        }
    }

    /// Wave 5 H3: dispatch a streak recompute against the current @Query
    /// snapshot. Pure MainActor call — `StreakService.recompute(from:)` is
    /// deliberately @MainActor for the @Observable write contract, and the
    /// @Query-backed `wakeAttempts` is already on the main actor. No Task
    /// hop needed.
    private func recomputeStreak() {
        streakService.recompute(from: wakeAttempts)
    }

    /// R9 helper: pull the latest overnight-pipeline error from the scheduler
    /// actor. Called on `.task` so it runs once per view appearance, covering
    /// both "just came back from background" and "just navigated to this
    /// tab". Extracted as its own method so tests can exercise it without
    /// reaching into `body`.
    ///
    /// P6 + P7 (Stage 6 Wave 1): upgraded to the composite `lastOvernightError()`
    /// accessor which returns either the start error OR the refresh/submit
    /// error (start takes precedence). Previously this only covered start
    /// failures; a mid-night session death or a `BGTaskScheduler.submit`
    /// throw was invisible to the user until the morning briefing failed.
    /// The `@State` name stays `lastSessionStartError` for grep-stability with
    /// the R9-era layout; the semantics widened but the variable just mirrors
    /// whatever the composite accessor returns.
    private func refreshOvernightStartError() async {
        lastSessionStartError = await overnightScheduler.lastOvernightError()
    }

    /// P10 (Stage 6 Wave 2): pull the UserDefaults-backed dropped-count the
    /// retry queue maintains. Called `.onAppear` so the lowest-priority
    /// banner surfaces the count without requiring a full-view refresh.
    private func refreshDroppedMemoryCount() {
        droppedMemoryWrites = PendingMemoryWriteQueue.droppedCount()
    }

    /// Composite "the alarm contract is partially broken" banner. Surfaces the highest-impact
    /// problem first so the user knows what to fix; without this, denied notifications and
    /// dead audio sessions silently pretended the alarm was armed. Optional permissions land
    /// at the bottom — they degrade features but don't break the wake-up contract.
    ///
    /// Priority order:
    ///  1. P14 (Stage 6 Wave 2): `requiresReinstall` — the stored user UUID
    ///     was externally mutated. Highest priority because (a) it's
    ///     security-relevant (path-traversal guard tripped) and (b) the
    ///     remediation ("reinstall") is immediate and must not be buried
    ///     under lower-priority messages.
    ///  2. Notifications / audio — alarm-breaking.
    ///  3. HealthKit — disables summary.
    ///  4. Overnight pipeline (Layer 3 analysis) — briefing card degradation.
    ///  5. P10 (Stage 6 Wave 2): dropped memory writes — Layer 2 fidelity
    ///     degradation. Lowest priority because the alarm still works; memory
    ///     drift is ancillary, visible only to insight quality over time.
    private var systemBanner: String? {
        // P14 (Stage 6 Wave 2): reinstall warning pre-empts everything else.
        // If the UUID is out of shape, memory is effectively gone and the
        // user should know before the banner stack dilutes the signal.
        if visionVerifier.requiresReinstall {
            return "Security issue: reinstall WakeProof to regenerate identity."
        }
        if permissions.notifications == .denied {
            return "Notifications are off — WakeProof can't reliably wake you. Open Settings → WakeProof → Notifications."
        }
        if let audioError = audioKeepalive.lastError {
            return "Audio session problem: \(audioError) The alarm may not survive lock screen."
        }
        // HealthKit failure doesn't break the alarm but disables the last-night summary.
        // Surface so the user knows why the feature is silent. `.failed` (transient/hardware)
        // is more actionable than `.denied` (user chose no).
        if permissions.healthKit == .failed {
            return "Apple Health unavailable — last-night summary won't appear."
        }
        // R9: overnight session kickoff failed. Surfaces below the core-alarm
        // banners because a broken briefing doesn't prevent wake-up — the
        // alarm still fires, the user still verifies, they just don't get
        // Claude's morning prose. Message ends with the retry hint so the
        // user knows no manual action is required.
        if let overnightErr = lastSessionStartError {
            return "Overnight analysis couldn't start tonight: \(overnightErr). We'll retry next launch."
        }
        // P10 (Stage 6 Wave 2): memory calibration degradation. Lowest
        // priority because the alarm still works — but silently dropping
        // calibration rows over time degrades Claude's ability to profile
        // the user, so the banner surfaces the count so it's not invisible.
        if droppedMemoryWrites > 0 {
            return "Memory calibration degraded: \(droppedMemoryWrites) write\(droppedMemoryWrites == 1 ? "" : "s") dropped."
        }
        return nil
    }

    private func loadFromScheduler() {
        let w = scheduler.window
        startTime = WakeWindow.composeTime(hour: w.startHour, minute: w.startMinute)
        isEnabled = w.isEnabled
        // H2: mirror the persisted note (nil → empty string for the TextField's
        // non-optional binding). If the user had saved a note on a previous
        // launch, the field repopulates so they can see / edit / keep it.
        commitmentNote = w.commitmentNote ?? ""
    }

    /// Wave 5 G1 (§12.4-G1): Toggle-off handler. Asks the scheduler whether the
    /// direct-disable path is allowed (24h grace window OR DEBUG bypass);
    /// otherwise transitions to `.disableChallenge` and lets
    /// `DisableChallengeView` drive the vision-verified flow.
    ///
    /// On `.allowed`, we flip the local `isEnabled` state AND call `save()` so
    /// the scheduler's window actually persists the disable — the Toggle's
    /// visual state is just the view's; the commitment is the persisted
    /// `WakeWindow.isEnabled = false`. On `.challengeRequired`, we leave
    /// `isEnabled` at `true` so the Toggle reads "still on" until the
    /// challenge resolves (the `.onChange(of: scheduler.window.isEnabled)`
    /// observer below will sync the flip when VERIFIED lands).
    private func handleDisableRequest() {
        let outcome = scheduler.requestDisable()
        switch outcome {
        case .allowed:
            isEnabled = false
            save()
        case .challengeRequired:
            // Leave `isEnabled` at true visually; the scheduler will drive the
            // transition, and the observer syncs the state when the challenge
            // succeeds. If the challenge cancels / fails, nothing flips in the
            // window state, so the local `isEnabled=true` stays accurate.
            scheduler.beginDisableChallenge()
        }
    }

    private func save() {
        let startComponents = Calendar.current.dateComponents([.hour, .minute], from: startTime)
        let hour: Int
        let minute: Int
        if let h = startComponents.hour, let m = startComponents.minute {
            hour = h
            minute = m
        } else {
            // Calendar.dateComponents on a Date should always produce hour/minute. If it ever
            // doesn't, fall back to defaults but loudly — silent defaulting saved a 22:00
            // alarm as 06:30 in an earlier draft of this code.
            logger.error("DateComponents fallback fired for startTime=\(startTime, privacy: .public) — defaulting to 06:30")
            hour = 6
            minute = 30
        }
        // H2: trim the TextField value; an all-whitespace note is semantically
        // "none" (same as the user never typing anything). Persist as `nil`
        // rather than an empty / whitespace-only string so the briefing-render
        // branch treats cleared and never-set identically.
        let trimmedNote = commitmentNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let noteToPersist: String? = trimmedNote.isEmpty ? nil : trimmedNote
        let w = WakeWindow(
            startHour: hour,
            startMinute: minute,
            // End-time UI is intentionally absent — the model field is preserved for a
            // future flexibility-window feature; the previously-saved value is carried
            // forward so the JSON-encoded UserDefaults blob stays decodable.
            endHour: scheduler.window.endHour,
            endMinute: scheduler.window.endMinute,
            isEnabled: isEnabled,
            commitmentNote: noteToPersist
        )
        // P5 (Stage 6 Wave 1): consume the Bool return from `updateWindow`. On failure
        // show an inline warning so the user knows the setting didn't persist; on
        // success clear any prior warning so a retry dismisses it silently.
        if scheduler.updateWindow(w) {
            windowSaveFailureMessage = nil
        } else {
            windowSaveFailureMessage = "Couldn't save the wake window — try once more. The alarm is scheduled for this session but the setting won't survive a relaunch."
        }
    }

}

#if DEBUG
#Preview {
    Text("AlarmSchedulerView preview requires full @Environment harness; see WakeProofApp's RootView for the live render path.")
        .padding()
        .background(Color.wpCream100)
}
#endif
