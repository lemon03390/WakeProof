//
//  AlarmScheduler.swift
//  WakeProof
//
//  Owns the user's wake-window configuration and fires the alarm at window-start.
//  Two-path fire mechanism for overnight reliability:
//    1. Task.sleep while the process is alive (AudioSessionKeepalive keeps us alive)
//    2. UNCalendarNotificationTrigger as a belt-and-suspenders backup so a suspended
//       process still gets the user's attention.
//  Whichever path wins, fire() converges on a single entry point (guarded against
//  double-fire). Audio playback is owned by AudioSessionKeepalive via the onFire
//  closure wired at the app root — this file stays audio-agnostic.
//

import Foundation
import Observation
import UserNotifications
import os

/// Four-phase state machine for the alarm. A single ZStack overlay at the root swaps between
/// the phase-specific views. .verifying and .antiSpoofPrompt were added in Day 3; the comment
/// about nested fullScreenCover regressions still applies and the ZStack pattern prevents them.
///
/// Wave 5 G1 (§12.4-G1): `.disableChallenge` is the mirror surface of the morning ring —
/// the user is asking to flip `window.isEnabled = false`, and the same vision-verification
/// flow as a wake gates the transition. Zero associated values so synthesized Equatable
/// conformance keeps working.
enum AlarmPhase: Equatable {
    case idle
    case ringing
    case capturing
    case verifying
    case antiSpoofPrompt(instruction: String)
    case disableChallenge
}

/// Wave 5 G1: outcome of `AlarmScheduler.requestDisable` so the caller (the Toggle
/// proxy Binding in `AlarmSchedulerView`) can decide whether to flip `isEnabled`
/// directly or transition into `.disableChallenge`. Intentionally a two-case enum
/// rather than a Bool so a future third path (e.g. "refused — emergency lockout
/// active") can be added without breaking call-site switches.
enum DisableRequestOutcome: Equatable {
    case allowed
    case challengeRequired
}

@Observable
@MainActor
final class AlarmScheduler {

    // MARK: - Observable state

    private(set) var window: WakeWindow
    private(set) var phase: AlarmPhase = .idle
    private(set) var nextFireAt: Date?
    /// The Date at which the currently-active alarm fired. Persisted across app launches
    /// via UserDefaults so a force-quit during `.ringing` leaves a recoverable marker —
    /// the app can then log an UNRESOLVED WakeAttempt on next launch instead of pretending
    /// nothing happened.
    private(set) var lastFireAt: Date? {
        didSet { persistLastFireAt() }
    }
    /// Last capture-attempt error, surfaced in AlarmRingingView after the user bails out of
    /// or fails the camera flow. Cleared when a new capture begins or the alarm resets.
    private(set) var lastCaptureError: String?

    // MARK: - Dependencies (late-bound; wired by the app root at startup)

    /// Invoked at fire-time. The Date argument is the actual fire instant — callers must
    /// use this rather than `nextFireAt`, which `fire()` re-points at tomorrow before the
    /// alarm's downstream UI even draws.
    var onFire: ((Date) -> Void)?

    /// Invoked when the scheduler decides a WakeAttempt row should be persisted. The closure
    /// is owned by WakeProofApp so AlarmScheduler stays free of ModelContext coupling.
    ///
    /// Wave 2.4 B4 fix: the closure now `throws`. Callers (WakeProofApp) propagate any
    /// `ModelContext.save()` failure up so `recordAttempt` can enqueue a retry into
    /// `PendingWakeAttemptQueue`. Previously the closure was `@MainActor (Verdict, Date) -> Void`
    /// with an internal `try?` + `context.rollback()` + log, which swallowed save failures —
    /// the audit-trail row vanished and the scheduler's lastFireAt had already been cleared
    /// in `handleRingCeiling()`, leaving next-launch recovery unable to detect the loss.
    var persistAttempt: ((WakeAttempt.Verdict, Date) throws -> Void)?

    /// Wave 2.4 B4 fix: queue that survives audit-row persist failures across launches.
    /// Default resolves to the shared UserDefaults queue; tests inject a mock.
    var pendingAttemptQueue: PendingWakeAttemptQueue = PendingWakeAttemptQueue()

    // MARK: - Private

    private let logger = Logger(subsystem: LogSubsystem.alarm, category: "scheduler")
    private let notificationCenter = UNUserNotificationCenter.current()
    /// G3 (Wave 5): three chained backup notifications at fireAt + 0s / +90s / +180s.
    /// See docs/self-sabotage-defense-analysis.md §7.2 + §12.4-G3. The force-quit
    /// narrative requires that killing the app mid-ring still leaves timed beeps on
    /// the phone — one beep is one beep; three beeps across 3 minutes is a meaningful
    /// self-imposed cost. Identifiers are deliberately namespaced under `.backup.N`
    /// so they don't collide with the pre-G3 `com.wakeproof.alarm.next` identifier
    /// from earlier schema versions (if any survived into a user's pending tray
    /// they're harmless stragglers, not duplicates of ours).
    static let backupNotificationIdentifiers = [
        "com.wakeproof.alarm.next.backup.1",
        "com.wakeproof.alarm.next.backup.2",
        "com.wakeproof.alarm.next.backup.3",
    ]
    /// Offsets in seconds from `fireAt` for each backup. Zipped with
    /// `backupNotificationIdentifiers` + `backupNotificationBodies` to build
    /// one UNNotificationRequest per iteration — keeps the scheduling loop
    /// self-evident and the three arrays obviously parallel.
    static let backupOffsetsSeconds: [TimeInterval] = [0, 90, 180]
    /// Body copy per backup. Title stays "WakeProof" for all three; only the body
    /// escalates in urgency to reinforce the contract language without breaking
    /// brand voice. English-only per CLAUDE.md — localization is post-hackathon.
    static let backupNotificationBodies = [
        "Time to prove you're awake.",
        "Still sleeping? WakeProof needs your photo.",
        "Your commitment expires soon.",
    ]
    private static let lastFireAtDefaultsKey = "com.wakeproof.alarm.lastFireAt"

    // MARK: - Wave 5 G1: disable-challenge grace period

    /// Wave 5 G1 (§12.4-G1): UserDefaults key that records the moment the user
    /// first committed to WakeProof (successful BaselinePhoto persist, or a
    /// defensive backfill on the first G1-aware launch if a baseline already
    /// existed). The 24h grace window is measured from this timestamp so
    /// onboarding-era users can recover from a wrong-baseline setup without
    /// being gated by the vision-verification challenge.
    static let firstInstallAtKey = "com.wakeproof.firstInstallAt"

    /// Wave 5 G1: user-defaults key driving the DEBUG-only "bypass disable
    /// challenge" toggle. Release builds MUST NOT consult this key (see
    /// `isDisableChallengeBypassActive` for the `#if DEBUG` wrap). Mirrors
    /// the `@AppStorage` binding in `AlarmSchedulerView` so UI + scheduler
    /// read the same source of truth without extra plumbing.
    static let disableChallengeBypassKey = "com.wakeproof.disableChallengeBypass"

    /// Wave 5 G1: 24h grace window after first install. Length is pinned by
    /// spec (§7.1 "Nuances" / §12.4-G1); tests reference the same constant so
    /// a deliberate doc-plus-code change is required to shift it.
    static let graceWindow: TimeInterval = 24 * 60 * 60

    /// Wave 5 G1: is `now` inside the 24h grace window relative to the
    /// recorded `firstInstallAt` timestamp? Absent timestamp is treated as
    /// "grace active" so a user who launched the app once before the G1
    /// release ships (no `firstInstallAtKey` on disk) still gets a
    /// one-time safety net — the `recordFirstInstallIfNeeded` backfill
    /// inside `bootstrapIfNeeded` lands the timestamp moments later, so
    /// this absent-case branch is only taken once per install.
    static func isInGracePeriod(now: Date = .now, defaults: UserDefaults = .standard) -> Bool {
        guard let firstInstall = defaults.object(forKey: firstInstallAtKey) as? Date else {
            return true
        }
        return now.timeIntervalSince(firstInstall) < graceWindow
    }

    /// Wave 5 G1: write `now` as the first-install timestamp if one isn't
    /// already on disk. Idempotent — repeat calls never overwrite. Called
    /// from two sites: (a) `OnboardingFlowView.persistBaseline` on the first
    /// successful BaselinePhoto persist; (b) `WakeProofApp.bootstrapIfNeeded`
    /// as a defensive backfill so users who onboarded BEFORE the G1 code
    /// shipped (baseline exists, no timestamp) get a fresh 24h grace clock
    /// the first time G1-aware code runs. The defensive backfill window
    /// effectively resets a pre-G1 user to "fresh install" for the purpose
    /// of the grace window — this is deliberate per §7.1 (existing users
    /// should not be locked out of disable at first exposure to G1).
    static func recordFirstInstallIfNeeded(now: Date = .now, defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: firstInstallAtKey) == nil else { return }
        defaults.set(now, forKey: firstInstallAtKey)
    }

    #if DEBUG
    /// DEBUG-only: is the user's bypass toggle active (UserDefaults key)
    /// OR the UI-test launch argument present? Release builds never
    /// compile this method so `requestDisable` can consult it without a
    /// runtime branch in production. The UI-test hook stays inside `#if
    /// DEBUG` as well — we never want a release build to honor a launch
    /// argument that silently defeats the contract.
    static func isDisableChallengeBypassActive(
        defaults: UserDefaults = .standard,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        if defaults.bool(forKey: disableChallengeBypassKey) {
            return true
        }
        if arguments.contains("-disableBypassForUIT") {
            return true
        }
        return false
    }
    #endif
    private var fireTask: Task<Void, Never>?
    private var backupScheduleTask: Task<Void, Never>?
    /// Monotonic counter incremented on every `scheduleNextFireIfEnabled` /
    /// `cancel`. Long-running async work captures the value at start and bails if it
    /// no longer matches — eliminates the late-resolve-after-cancel race that
    /// `Task.isCancelled` alone can't detect across re-scheduling.
    private var schedulingGeneration: UInt64 = 0

    /// R15 (Wave 2.5): injectable UserDefaults so tests use a per-run suite
    /// (`UserDefaults(suiteName:)`) instead of mutating `.standard` — which
    /// could otherwise leak into parallel tests or the next CI run on the same
    /// simulator. Production still uses `.standard`.
    private let defaults: UserDefaults

    /// Loading the window from UserDefaults in init is intentional: the owning
    /// `@State private var scheduler = AlarmScheduler()` in WakeProofApp means this
    /// init runs exactly once per scene, not on every view redraw. SwiftUI `@State`
    /// preserves the reference across redraws for class types.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.window = WakeWindow.load()
        self.lastFireAt = defaults.object(forKey: Self.lastFireAtDefaultsKey) as? Date
    }

    // MARK: - Public API

    /// Apply and persist a new wake window. Returns `true` on success; `false` if
    /// `WakeWindow.save()` failed (encode error / defaults write rejected).
    ///
    /// P5 (Stage 6 Wave 1): previously this routed a save failure to
    /// `lastCaptureError`, which AlarmRingingView surfaces but AlarmSchedulerView's
    /// "Save & schedule" button never renders — so a user tapping that button
    /// silently proceeded past a failed persist and would see the old window's
    /// fire time on "Next fire" with no warning. Mirroring `BedtimeSettings.save`
    /// / `BedtimeStep`'s Bool-return pattern (M5) lets AlarmSchedulerView render
    /// an inline warning like BedtimeStep does, instead of depending on a view
    /// surface the settings UI doesn't mount.
    ///
    /// Return-on-failure still reschedules — the in-memory `window` reflects the
    /// user's intent even if persistence failed; the alarm should fire with the
    /// new time for this session, and `BedtimeStep`-style inline warning tells
    /// the user to retry so the new window survives next launch.
    @discardableResult
    func updateWindow(_ new: WakeWindow) -> Bool {
        window = new
        let saved = window.save()
        scheduleNextFireIfEnabled()
        return saved
    }

    func scheduleNextFireIfEnabled() {
        cancel()
        guard window.isEnabled, let fireAt = window.nextFireDate() else {
            nextFireAt = nil
            logger.info("Scheduler idle — window disabled or invalid")
            return
        }
        nextFireAt = fireAt
        schedulingGeneration &+= 1
        let myGeneration = schedulingGeneration
        let interval = fireAt.timeIntervalSinceNow
        logger.info("Alarm scheduled for \(fireAt.ISO8601Format(), privacy: .public) (in \(interval, privacy: .public)s, gen=\(myGeneration, privacy: .public))")
        fireTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(interval))
            } catch is CancellationError {
                return
            } catch {
                self?.logger.warning("Fire task sleep threw non-cancellation: \(error.localizedDescription, privacy: .public)")
                return
            }
            guard !Task.isCancelled else { return }
            // L6 won't-fix (Wave 2.7): briefly strong `self` inside MainActor.run is a
            // theoretical race window during SwiftUI teardown mid-fire — the closure
            // unwraps `self`, pins it, and calls `self.fire()` all inside the
            // MainActor hop. A real race requires SwiftUI to tear down the scheduler
            // between the guard and the fire() call (tens of microseconds), which is
            // exceedingly unlikely for a `@State` scheduler on `WakeProofApp`. The
            // generation counter (`myGeneration == self.schedulingGeneration` check
            // below) already neutralizes stale invocations regardless of whether
            // self survived teardown. Restructuring to fully weak-chain the fire()
            // path would force split-state reads across two MainActor hops and
            // isn't worth the readability cost for a race we can't reproduce.
            await MainActor.run {
                guard let self else { return }
                // Re-check generation inside the actor hop — `cancel()` could have run between
                // the cancellation check and this resume.
                guard myGeneration == self.schedulingGeneration else {
                    self.logger.info("Fire task skipped — generation changed (\(myGeneration, privacy: .public) → \(self.schedulingGeneration, privacy: .public))")
                    return
                }
                self.fire()
            }
        }
        backupScheduleTask = Task { [weak self] in
            await self?.scheduleBackupNotification(fireAt: fireAt, generation: myGeneration)
        }
    }

    /// Cancels the scheduling pipeline (fire timer, backup notification, pending requests).
    /// Intentionally does NOT touch `phase` or `lastFireAt` — fire() calls
    /// `scheduleNextFireIfEnabled()` (which in turn calls cancel()) IMMEDIATELY after
    /// transitioning to .ringing, and resetting phase here would wipe the in-flight alarm
    /// state plus the audit-trail marker. The user-facing state machine is owned by
    /// stopRinging / handleRingCeiling / markCaptureCompleted; cancel() is purely the
    /// scheduler-pipeline reset.
    func cancel() {
        fireTask?.cancel()
        fireTask = nil
        backupScheduleTask?.cancel()
        backupScheduleTask = nil
        nextFireAt = nil
        // P3 (Stage 6 Wave 1): bump the scheduling generation unconditionally here.
        // Previously this lived only in `scheduleNextFireIfEnabled`, on the theory that
        // `Task.isCancelled` was sufficient — but a fire-task that had already passed
        // its `guard !Task.isCancelled` check before the `cancel()` call landed could
        // still reach the MainActor hop. At that point the generation check
        // (`myGeneration == self.schedulingGeneration`) would match, and the alarm
        // would fire despite the cancel. Bumping here invalidates every pre-cancel
        // fire task deterministically. `&+=` wraps safely; a 64-bit overflow at
        // one bump per fire is absurdly past device lifetime.
        schedulingGeneration &+= 1
        notificationCenter.removePendingNotificationRequests(withIdentifiers: Self.backupNotificationIdentifiers)
        // Intentionally NOT removing delivered notifications here — see fire(). Delivered
        // banners auto-dismiss when the user opens the app. Aggressive removal would kill
        // the iOS-side audible cue if the in-app alarm hasn't started yet.
    }

    /// Demo-friendly manual trigger. Used by DEBUG "Fire now" button and by tests.
    func fireNow() {
        logger.info("Manual fireNow() invoked")
        fire()
    }

    func stopRinging() {
        lastCaptureError = nil
        phase = .idle
        // The alarm has been resolved (success path called this via onSuccess). Clear the
        // unresolved-fire marker so the next launch doesn't log a phantom UNRESOLVED row.
        lastFireAt = nil
        logger.info("Ringing cleared (phase → idle)")
        // Stage 8 CRITICAL 2 fix: today's +90s/+180s backup chain uses the same
        // identifiers as tomorrow's would. Calling scheduleNextFireIfEnabled()
        // inside fire() would cancel them mid-flight, defeating G3's force-quit
        // durability (force-quit after the +0s banner → +90s/+180s never fire).
        // Terminal resolution (stopRinging / handleRingCeiling — which already
        // calls stopRinging) is the safe moment: today's fire is fully resolved
        // and tomorrow's schedule can be written without identifier collision.
        // Guarded so a disabled window (e.g. after disableChallengeSucceeded
        // called stopRinging indirectly via a future refactor) doesn't churn
        // the pipeline for nothing — scheduleNextFireIfEnabled itself no-ops
        // on disabled windows anyway, but the guard makes the intent explicit.
        if window.isEnabled {
            scheduleNextFireIfEnabled()
        }
    }

    /// Transition ringing → capturing when the user taps "Prove you're awake".
    func beginCapturing() {
        // Accept either the initial ringing→capturing entry OR the anti-spoof re-entry.
        let isValidSource: Bool
        switch phase {
        case .ringing: isValidSource = true
        case .antiSpoofPrompt: isValidSource = true
        default: isValidSource = false
        }
        guard isValidSource else {
            logger.warning("beginCapturing ignored — phase=\(String(describing: self.phase), privacy: .public)")
            return
        }
        // G3 (Wave 5): cancel the +90s / +180s chained backups the moment the user
        // enters the camera flow. Without this, a user who takes >90s in the capture
        // UI (perfectly plausible — anti-spoof re-prompts, lighting retries) gets the
        // second and third notification pings firing on top of an already-open UI,
        // which is annoying and (worse) breaks the contract language "WakeProof needs
        // your photo" when WakeProof is literally mid-photo. We don't call the full
        // `cancel()` because that tears down the fire task itself — wrong while we're
        // actively mid-fire; the +0s banner has already been delivered and the rest
        // are the ones we care about clearing.
        notificationCenter.removePendingNotificationRequests(withIdentifiers: Self.backupNotificationIdentifiers)
        lastCaptureError = nil
        phase = .capturing
        logger.info("Phase → capturing (pending backup notifications cleared)")
    }

    /// Transition capturing → ringing when the camera cancels, fails, or persistence fails.
    /// An `error` message surfaces as a banner on AlarmRingingView so the user knows why they're back.
    func returnToRingingWith(error: String?) {
        // Accept return from either capturing or verifying (network error mid-verify).
        let isValidSource: Bool
        switch phase {
        case .capturing: isValidSource = true
        case .verifying: isValidSource = true
        default: isValidSource = false
        }
        guard isValidSource else {
            logger.warning("returnToRingingWith ignored — phase=\(String(describing: self.phase), privacy: .public)")
            return
        }
        lastCaptureError = error
        phase = .ringing
        logger.info("Phase → ringing (error=\(error ?? "none", privacy: .public))")
    }

    /// Transition capturing → verifying when the camera flow successfully persists a WakeAttempt
    /// and VisionVerifier is about to call Claude. The ring audio stays on (volume reduction is
    /// an app-root concern so the scheduler stays audio-agnostic).
    func beginVerifying() {
        guard phase == .capturing else {
            logger.warning("beginVerifying ignored — phase=\(String(describing: self.phase), privacy: .public)")
            return
        }
        lastCaptureError = nil
        phase = .verifying
        logger.info("Phase → verifying")
    }

    /// Transition verifying → antiSpoofPrompt when Claude returns RETRY. The instruction is chosen
    /// by VisionVerifier from a fixed bank; the prompt view displays it to the user, who taps
    /// "I'm ready" to move back into .capturing.
    func beginAntiSpoofPrompt(instruction: String) {
        guard phase == .verifying else {
            logger.warning("beginAntiSpoofPrompt ignored — phase=\(String(describing: self.phase), privacy: .public)")
            return
        }
        lastCaptureError = nil
        phase = .antiSpoofPrompt(instruction: instruction)
        logger.info("Phase → antiSpoofPrompt (instruction=\(instruction, privacy: .public))")
    }

    /// Transition verifying → ringing when Claude returns REJECTED or a network error occurred.
    /// `error` surfaces on the ringing banner.
    func returnToRingingAfterVerifying(error: String?) {
        guard phase == .verifying else {
            logger.warning("returnToRingingAfterVerifying ignored — phase=\(String(describing: self.phase), privacy: .public)")
            return
        }
        lastCaptureError = error
        phase = .ringing
        logger.info("Phase → ringing after verifying (error=\(error ?? "none", privacy: .public))")
    }

    /// Transition verifying → idle when Claude returns VERIFIED. Wraps `stopRinging()` behind a
    /// source-phase guard so the method is named for intent (not just side-effect). `stopRinging`
    /// already clears `phase`, `lastFireAt`, and `lastCaptureError` — calling it is a single source
    /// of truth and avoids the `persistLastFireAt` didSet firing twice.
    func finishVerifyingVerified() {
        guard phase == .verifying else {
            logger.warning("finishVerifyingVerified ignored — phase=\(String(describing: self.phase), privacy: .public)")
            return
        }
        stopRinging()
        logger.info("Phase → idle after verified")
    }

    // MARK: - Wave 5 G1: disable-challenge transitions

    /// Wave 5 G1 (§12.4-G1): caller-owned entry point for "user wants to disable
    /// the alarm". Routes through the grace-period check and the DEBUG bypass
    /// (release builds ignore the bypass key entirely). Returns `.allowed` if the
    /// caller may flip `window.isEnabled = false` directly, `.challengeRequired`
    /// if the caller must hand off to the vision-verified disable-challenge flow.
    ///
    /// Deliberately does NOT mutate scheduler state — the caller decides whether
    /// to invoke `beginDisableChallenge()` or flip isEnabled locally. Keeps the
    /// policy (grace + bypass) separate from the transition, so tests can exercise
    /// the policy without engaging the state machine.
    func requestDisable(now: Date = .now) -> DisableRequestOutcome {
        #if DEBUG
        if Self.isDisableChallengeBypassActive(defaults: defaults) {
            logger.info("requestDisable: DEBUG bypass active — allowing direct disable")
            return .allowed
        }
        #endif
        if Self.isInGracePeriod(now: now, defaults: defaults) {
            logger.info("requestDisable: inside 24h grace — allowing direct disable")
            return .allowed
        }
        logger.info("requestDisable: post-grace — challenge required")
        return .challengeRequired
    }

    /// Wave 5 G1: transition .idle → .disableChallenge. Valid only from .idle —
    /// a user tapping the Toggle while the alarm is actively ringing is a
    /// programmer error and silently no-ops (the Toggle is hidden inside the
    /// scheduler view which isn't visible during .ringing).
    func beginDisableChallenge() {
        guard phase == .idle else {
            logger.warning("beginDisableChallenge ignored — phase=\(String(describing: self.phase), privacy: .public)")
            return
        }
        lastCaptureError = nil
        phase = .disableChallenge
        logger.info("Phase → disableChallenge")
    }

    /// Wave 5 G1: VERIFIED verdict on the disable challenge — flip
    /// `window.isEnabled = false`, persist, and re-schedule (which in turn
    /// cancels any pending fire because the window is now disabled). Mirrors
    /// `finishVerifyingVerified()`'s shape so the two success surfaces stay
    /// symmetric.
    ///
    /// Stage 8 CRITICAL 1 fix: a `WakeWindow.save()` failure is no longer
    /// dropped silently. Previously `_ = updateWindow(updated)` discarded
    /// the Bool return — on encode failure the in-memory flip to
    /// `isEnabled = false` had already happened (so the Toggle UI animated
    /// OFF), but UserDefaults still held `isEnabled = true`. The NEXT
    /// relaunch would re-arm the alarm silently — the exact silent-failure
    /// pattern CLAUDE.md forbids (8x repeat offense). The fix pre-saves
    /// via `WakeWindow.save()` directly; only on success do we propagate
    /// the flip to in-memory + re-schedule. Save failure routes through
    /// `disableChallengeFailed(error:)` so state stays consistent with
    /// "alarm stays enabled" (in-memory window keeps its previous
    /// `isEnabled = true`, Toggle stays ON, user sees a banner).
    func disableChallengeSucceeded() {
        guard phase == .disableChallenge else {
            logger.warning("disableChallengeSucceeded ignored — phase=\(String(describing: self.phase), privacy: .public)")
            return
        }
        var updated = window
        updated.isEnabled = false
        // Persist FIRST so a write-rejection doesn't leave us with a
        // flipped in-memory window but stale UserDefaults — the bug this
        // fix addresses. Only on success do we publish the flip through
        // in-memory state + the re-schedule pipeline.
        if updated.save() {
            window = updated
            scheduleNextFireIfEnabled()
            phase = .idle
            logger.info("Disable challenge verified — window disabled and persisted")
        } else {
            // Persist failed. Keep in-memory `window.isEnabled = true` so
            // the Toggle stays ON (the `.onChange(of: scheduler.window.isEnabled)`
            // observer in AlarmSchedulerView won't fire because the value
            // didn't change), and surface the error via the failed branch
            // so the user knows to retry.
            logger.error("Disable challenge verified but window.save() failed — alarm stays enabled")
            disableChallengeFailed(error: "Couldn't save — alarm stayed enabled. Try again.")
        }
    }

    /// Wave 5 G1: REJECTED / RETRY verdict on the disable challenge. Surface
    /// the reasoning via `lastCaptureError` so AlarmSchedulerView can decide
    /// how to render it (a future banner; today it's logged). Window stays
    /// enabled — evening-self didn't prove they're morning-self, so the
    /// contract holds.
    func disableChallengeFailed(error: String?) {
        guard phase == .disableChallenge else {
            logger.warning("disableChallengeFailed ignored — phase=\(String(describing: self.phase), privacy: .public)")
            return
        }
        lastCaptureError = error
        phase = .idle
        logger.info("Disable challenge failed — window.isEnabled kept true, error=\(error ?? "none", privacy: .public)")
    }

    /// Wave 5 G1: user cancelled the capture flow before it resolved to a
    /// verdict. Distinct from `disableChallengeFailed` so future UX can
    /// differentiate "claude said no" from "user backed out" if needed.
    /// Today both paths just return to .idle with the alarm still enabled.
    func cancelDisableChallenge() {
        guard phase == .disableChallenge else {
            logger.warning("cancelDisableChallenge ignored — phase=\(String(describing: self.phase), privacy: .public)")
            return
        }
        lastCaptureError = nil
        phase = .idle
        logger.info("Disable challenge cancelled — window.isEnabled kept true")
    }

    /// Called by `CameraCaptureFlow` when a capture succeeded and a WakeAttempt row was
    /// persisted. The scheduler clears its `lastFireAt` marker so launch-time recovery
    /// doesn't double-count this fire as unresolved.
    func markCaptureCompleted() {
        lastFireAt = nil
        logger.info("Capture marked completed — lastFireAt cleared")
    }

    /// Called from `AlarmSoundEngine.onCeilingReached` so the audit trail records the
    /// timeout, audio is stopped, and the unresolved-fire marker is cleared.
    func handleRingCeiling() {
        let firedAt = lastFireAt ?? Date()
        recordAttempt(.timeout, at: firedAt)
        lastFireAt = nil
        stopRinging()
    }

    /// Inserts an UNRESOLVED row for any fire that the previous app session began but never
    /// resolved (force-quit during ring). Call once at app launch from the app root.
    func recoverUnresolvedFireIfNeeded() {
        guard let firedAt = lastFireAt else { return }
        logger.warning("Recovering unresolved fire from previous session at \(firedAt.ISO8601Format(), privacy: .public)")
        recordAttempt(.unresolved, at: firedAt)
        lastFireAt = nil
    }

    /// Call from SwiftUI `.onChange(of: scenePhase)` when the app becomes active.
    /// Catches the case where Task.sleep was suspended past its fire time (OS froze the
    /// process overnight) — the backup notification will have beeped, but our in-process
    /// ringing UI needs a nudge to catch up.
    func reconcileAfterForeground() {
        guard phase == .idle, let expected = nextFireAt else { return }
        if Date() >= expected {
            logger.warning("Foreground reconcile: Task.sleep missed fire by \(Date().timeIntervalSince(expected), privacy: .public)s — firing now")
            fire()
        }
    }

    // MARK: - Private

    private func fire() {
        // Guard against double-fire: DEBUG fireNow() spam, re-entrance from onFire, or
        // scheduleNextFireIfEnabled() chaining. Without this, playAlarmSound would be
        // invoked twice concurrently and onFire closures would stack.
        guard phase == .idle else {
            logger.info("fire() skipped — phase=\(String(describing: self.phase), privacy: .public) not idle")
            return
        }
        let firedAt = Date()
        lastFireAt = firedAt    // persists via didSet so a force-quit leaves a recovery marker.
        // Cancel any in-flight backup-scheduling task for THIS fire — without this,
        // notificationCenter.add() can resolve after we've started ringing and land a stale
        // request that double-bangs the alarm.
        backupScheduleTask?.cancel()
        backupScheduleTask = nil
        logger.info("Alarm firing at \(firedAt.ISO8601Format(), privacy: .public)")
        lastCaptureError = nil
        phase = .ringing
        if onFire == nil {
            // Without onFire wired the ringing UI shows but no audio plays — silent contract
            // failure. Surface as a fault so this slips into the next morning's logs.
            logger.fault("fire() invoked but onFire handler not wired — alarm will be silent")
        }
        onFire?(firedAt)
        // Stage 8 CRITICAL 2 fix: DO NOT call scheduleNextFireIfEnabled() here.
        // Today's +0s/+90s/+180s backup chain shares identifiers with tomorrow's,
        // so rescheduling inside fire() cancels the still-pending tail (+90s,
        // +180s) mid-flight. A force-quit after the +0s banner lands would then
        // never see +90s/+180s — defeating G3's force-quit durability story.
        // Scheduling is now deferred to terminal resolution (stopRinging() +
        // handleRingCeiling() which already calls stopRinging). Launch-time
        // wiring in WakeProofApp.bootstrapIfNeeded also calls
        // scheduleNextFireIfEnabled, so a force-quit during ring still gets a
        // tomorrow schedule when the user reopens the app.
    }

    private func scheduleBackupNotification(fireAt: Date, generation: UInt64) async {
        let settings = await notificationCenter.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            logger.warning("Backup notifications skipped — not authorized (status=\(settings.authorizationStatus.rawValue, privacy: .public))")
            return
        }
        // G3 (Wave 5): three chained backups at fireAt + 0s / +90s / +180s. The auth check
        // + generation capture above happen ONCE — if auth is denied none of the three
        // schedule; if auth flips mid-loop we keep going (the user having granted moments
        // ago is the realistic window and partial scheduling is worse than full). The
        // three arrays are parallel by construction (see static declarations).
        let offsets = Self.backupOffsetsSeconds
        let identifiers = Self.backupNotificationIdentifiers
        let bodies = Self.backupNotificationBodies
        for (index, offset) in offsets.enumerated() {
            // Early-exit at the top of every iteration so we don't waste an .add() call
            // on a generation that's already stale. Self-heal of previously-landed
            // requests happens in the post-add branch below.
            if Task.isCancelled || generation != schedulingGeneration {
                notificationCenter.removePendingNotificationRequests(withIdentifiers: identifiers)
                logger.info("Backup chain aborted pre-add at index \(index, privacy: .public) — generation changed (gen=\(generation, privacy: .public) current=\(self.schedulingGeneration, privacy: .public))")
                return
            }
            let identifier = identifiers[index]
            let body = bodies[index]
            let content = UNMutableNotificationContent()
            content.title = "WakeProof"
            content.body = body
            // Custom notification sounds must be CAF/AIFF/WAV — .m4a is silently rejected. We ship
            // alarm.caf (Int16 PCM) alongside alarm.m4a; the m4a is used by in-app AVAudioPlayer,
            // the caf is used here for the notification banner sound. iOS caps this at 30 seconds.
            content.sound = UNNotificationSound(named: UNNotificationSoundName("alarm.caf"))
            content.interruptionLevel = .timeSensitive
            let targetDate = fireAt.addingTimeInterval(offset)
            // Sub-day fires use UNTimeIntervalNotificationTrigger so an overnight timezone change
            // doesn't shift the wall-clock target. Day-spanning fires fall back to calendar
            // matching, which Apple still re-evaluates against the active TZ at delivery, but
            // that's the right default semantic for "wake me at 6:30 wherever I am tomorrow".
            // UNTimeIntervalNotificationTrigger requires a strictly positive interval; if the
            // +0s / +90s entries have already passed by the time we get here (e.g. the process
            // was rehydrated post-fire) we fall back to calendar matching which iOS treats as
            // "fire ASAP at the next matching minute". Acceptable degradation for the tail
            // backups; the primary (+0s) is the one that matters for demo reliability.
            let interval = targetDate.timeIntervalSinceNow
            let trigger: UNNotificationTrigger
            if interval > 0, interval <= 23 * 60 * 60 {
                trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            } else {
                let triggerComponents = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute],
                    from: targetDate
                )
                trigger = UNCalendarNotificationTrigger(dateMatching: triggerComponents, repeats: false)
            }
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
            do {
                try await notificationCenter.add(request)
                // UNUserNotificationCenter.add is not a cooperative cancellation point. Two ways
                // a stale request can land after we no longer want it:
                //   1. The cooperative cancel() ran before resolve.
                //   2. fire() (or another scheduleNextFireIfEnabled) ran and bumped the generation.
                // Both collapse to "my generation is no longer the active one". When we detect
                // that, we rip out ALL three identifiers — partial state (e.g. the +0s landed but
                // the +90s was cancelled) is worse than no backup at all, because the ringing UI
                // + audio keepalive are still active and the inconsistent notification tail just
                // confuses the user.
                if Task.isCancelled || generation != schedulingGeneration {
                    notificationCenter.removePendingNotificationRequests(withIdentifiers: identifiers)
                    logger.info("Backup chain self-healed after late-resolve at index \(index, privacy: .public) (gen=\(generation, privacy: .public) current=\(self.schedulingGeneration, privacy: .public))")
                    return
                }
                logger.info("Backup notification \(index + 1, privacy: .public)/3 scheduled for \(targetDate.ISO8601Format(), privacy: .public)")
            } catch {
                // Loop continues: one iteration failing shouldn't prevent the others from
                // scheduling. E.g. if iOS is at the 64-pending-request cap on identifier 2,
                // we still want the +0s that landed to ring the phone.
                logger.error("Failed to schedule backup notification \(index + 1, privacy: .public)/3: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func persistLastFireAt() {
        if let lastFireAt {
            defaults.set(lastFireAt, forKey: Self.lastFireAtDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.lastFireAtDefaultsKey)
        }
    }

    /// Single sink for all WakeAttempt persistence calls. Centralises the unwired-closure
    /// fault-log so a future third caller can't forget it.
    ///
    /// Wave 2.4 B4 fix: save failures now enqueue into PendingWakeAttemptQueue so the row
    /// survives across launches instead of being silently swallowed by rollback+log. The
    /// enqueue happens inside a detached Task because the queue is an `actor` and we must
    /// not block the MainActor call-site; this is safe because the closure's throwing
    /// contract gives us the failure signal synchronously — only the recovery hop goes async.
    private func recordAttempt(_ verdict: WakeAttempt.Verdict, at firedAt: Date, source: String = #function) {
        guard let persistAttempt else {
            logger.fault("\(source, privacy: .public): persistAttempt closure not wired — \(verdict.rawValue, privacy: .public) row dropped")
            // Even with no closure wired, enqueue the row so a later hot-patch that wires
            // the closure + triggers flushPendingAttempts can still land it. This is the
            // most conservative choice: audit rows are the product's self-commitment
            // contract; losing one because of a test-time mis-wiring would undermine the
            // whole value prop.
            enqueuePendingAttempt(verdict: verdict, scheduledFor: firedAt)
            return
        }
        do {
            try persistAttempt(verdict, firedAt)
        } catch {
            logger.error("\(source, privacy: .public): persistAttempt threw for verdict=\(verdict.rawValue, privacy: .public) — enqueuing for retry: \(error.localizedDescription, privacy: .public)")
            enqueuePendingAttempt(verdict: verdict, scheduledFor: firedAt)
        }
    }

    /// External entry point used by WakeProofApp.persistAttempt closure when the save
    /// itself failed but the scheduler can't learn of it through the closure-throw path
    /// (e.g. future code paths that fire-and-forget). Also used by recordAttempt's own
    /// catch block.
    func markAttemptPersistFailed(verdict: WakeAttempt.Verdict, scheduledFor: Date) {
        enqueuePendingAttempt(verdict: verdict, scheduledFor: scheduledFor)
    }

    /// Flush any queued pending WakeAttempt rows. Called from WakeProofApp.bootstrapIfNeeded
    /// BEFORE new attempts are expected so tonight's row doesn't jostle with a pre-existing
    /// backlog. Flushes serially via the persistAttempt closure — whichever entries succeed
    /// drop out of the queue; the rest stay for the next launch with retryCount bumped.
    func flushPendingAttempts() async {
        guard let persistAttempt else {
            logger.warning("flushPendingAttempts: persistAttempt closure not wired — leaving queue intact until next launch")
            return
        }
        let pending = await pendingAttemptQueue.snapshot()
        guard !pending.isEmpty else { return }
        logger.info("flushPendingAttempts: attempting to flush \(pending.count, privacy: .public) queued rows")

        var survivors: [PendingWakeAttempt] = []
        for row in pending {
            let verdict = WakeAttempt.Verdict(legacyRawValue: row.verdictRawValue)
            do {
                try persistAttempt(verdict, row.scheduledFor)
                logger.info("flushPendingAttempts: flushed verdict=\(row.verdictRawValue, privacy: .public) retryCount=\(row.retryCount, privacy: .public)")
            } catch {
                // P20 (Stage 6 Wave 2): `bumpingRetry()` returns a new instance
                // with retryCount+1 — the struct is now fully immutable (let
                // retryCount) so the previous `var bumped = row; bumped.retryCount += 1`
                // pattern no longer compiles.
                let bumped = row.bumpingRetry()
                logger.warning("flushPendingAttempts: retry \(bumped.retryCount, privacy: .public) for verdict=\(row.verdictRawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                survivors.append(bumped)
            }
        }
        await pendingAttemptQueue.replace(with: survivors)
    }

    private func enqueuePendingAttempt(verdict: WakeAttempt.Verdict, scheduledFor: Date) {
        let pending = PendingWakeAttempt(
            verdictRawValue: verdict.rawValue,
            scheduledFor: scheduledFor
        )
        // P8 (Stage 6 Wave 1): switch from `Task.detached { await queue.enqueue(...) }`
        // to the synchronous `enqueueSync` path. The prior pattern was fire-and-forget:
        // if the app was torn down (iOS kill / force-quit / scene discard) BETWEEN
        // the detach and the actor receiving the message, the enqueue never landed
        // and the row was lost — defeating the B4 intent that these rows exist
        // SPECIFICALLY to prevent silent data loss. `enqueueSync` uses an
        // `OSAllocatedUnfairLock`-guarded UserDefaults write that completes before
        // this method returns, so tear-down right after this call still leaves
        // the row on disk for next-launch recovery.
        pendingAttemptQueue.enqueueSync(pending)
    }
}
