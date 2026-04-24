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
enum AlarmPhase: Equatable {
    case idle
    case ringing
    case capturing
    case verifying
    case antiSpoofPrompt(instruction: String)
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
    private let backupNotificationIdentifier = "com.wakeproof.alarm.next"
    private static let lastFireAtDefaultsKey = "com.wakeproof.alarm.lastFireAt"
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

    func updateWindow(_ new: WakeWindow) {
        window = new
        if !window.save() {
            // WakeWindow.save() now returns Bool; surface failure rather than silently
            // proceeding with a window the user can't trust will persist.
            lastCaptureError = "Couldn't save the wake window. The alarm will use the previous setting."
        }
        scheduleNextFireIfEnabled()
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
        // Generation bumping happens in scheduleNextFireIfEnabled, not here — Task.isCancelled
        // is sufficient when cancel runs without a follow-up schedule.
        notificationCenter.removePendingNotificationRequests(withIdentifiers: [backupNotificationIdentifier])
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
        lastCaptureError = nil
        phase = .capturing
        logger.info("Phase → capturing")
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
        // Re-schedule the next day's fire. Cheap: this just sets up another Task.sleep
        // plus a backup notification for tomorrow.
        scheduleNextFireIfEnabled()
    }

    private func scheduleBackupNotification(fireAt: Date, generation: UInt64) async {
        let settings = await notificationCenter.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            logger.warning("Backup notification skipped — notifications not authorized (status=\(settings.authorizationStatus.rawValue, privacy: .public))")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "WakeProof"
        content.body = "Time to prove you're awake."
        // Custom notification sounds must be CAF/AIFF/WAV — .m4a is silently rejected. We ship
        // alarm.caf (Int16 PCM) alongside alarm.m4a; the m4a is used by in-app AVAudioPlayer,
        // the caf is used here for the notification banner sound. iOS caps this at 30 seconds.
        content.sound = UNNotificationSound(named: UNNotificationSoundName("alarm.caf"))
        content.interruptionLevel = .timeSensitive
        // Sub-day fires use UNTimeIntervalNotificationTrigger so an overnight timezone change
        // doesn't shift the wall-clock target. Day-spanning fires fall back to calendar
        // matching, which Apple still re-evaluates against the active TZ at delivery, but
        // that's the right default semantic for "wake me at 6:30 wherever I am tomorrow".
        let interval = fireAt.timeIntervalSinceNow
        let trigger: UNNotificationTrigger
        if interval > 0, interval <= 23 * 60 * 60 {
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        } else {
            let triggerComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: fireAt
            )
            trigger = UNCalendarNotificationTrigger(dateMatching: triggerComponents, repeats: false)
        }
        let request = UNNotificationRequest(identifier: backupNotificationIdentifier, content: content, trigger: trigger)
        do {
            try await notificationCenter.add(request)
            // UNUserNotificationCenter.add is not a cooperative cancellation point. Two ways
            // a stale request can land after we no longer want it:
            //   1. The cooperative cancel() ran before resolve.
            //   2. fire() (or another scheduleNextFireIfEnabled) ran and bumped the generation.
            // Both collapse to "my generation is no longer the active one".
            if Task.isCancelled || generation != schedulingGeneration {
                notificationCenter.removePendingNotificationRequests(withIdentifiers: [backupNotificationIdentifier])
                logger.info("Backup notification self-healed after late-resolve (gen=\(generation, privacy: .public) current=\(self.schedulingGeneration, privacy: .public))")
                return
            }
            logger.info("Backup notification scheduled for \(fireAt.ISO8601Format(), privacy: .public)")
        } catch {
            logger.error("Failed to schedule backup notification: \(error.localizedDescription, privacy: .public)")
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
                var bumped = row
                bumped.retryCount += 1
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
        let queue = pendingAttemptQueue
        Task.detached {
            await queue.enqueue(pending)
        }
    }
}
