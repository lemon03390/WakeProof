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

/// Three-phase state machine for the alarm. A single fullScreenCover at the root swaps
/// between AlarmRingingView (phase == .ringing) and CameraCaptureFlow (phase == .capturing);
/// nested covers caused SwiftUI's outer-cover binding setter to fire during transitions,
/// dismissing everything when the user tapped "Prove you're awake".
enum AlarmPhase: Equatable {
    case idle
    case ringing
    case capturing
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

    // MARK: - Dependencies (late-bound; wired by WakeProofApp at startup)

    /// Invoked at fire-time. The Date argument is the actual fire instant — callers must
    /// use this rather than `nextFireAt`, which `fire()` re-points at tomorrow before the
    /// alarm's downstream UI even draws.
    var onFire: ((Date) -> Void)?

    /// Invoked when the scheduler decides a WakeAttempt row should be persisted. The closure
    /// is owned by WakeProofApp so AlarmScheduler stays free of ModelContext coupling.
    var persistAttempt: ((WakeAttempt.Verdict, Date) -> Void)?

    // MARK: - Private

    private let logger = Logger(subsystem: "com.wakeproof.alarm", category: "scheduler")
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

    /// Loading the window from UserDefaults in init is intentional: the owning
    /// `@State private var scheduler = AlarmScheduler()` in WakeProofApp means this
    /// init runs exactly once per scene, not on every view redraw. SwiftUI `@State`
    /// preserves the reference across redraws for class types.
    init() {
        self.window = WakeWindow.load()
        self.lastFireAt = UserDefaults.standard.object(forKey: Self.lastFireAtDefaultsKey) as? Date
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
        schedulingGeneration &+= 1
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
        guard phase == .ringing else {
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
        guard phase == .capturing else {
            logger.warning("returnToRingingWith ignored — phase=\(String(describing: self.phase), privacy: .public)")
            return
        }
        lastCaptureError = error
        phase = .ringing
        logger.info("Phase → ringing (error=\(error ?? "none", privacy: .public))")
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
        if persistAttempt == nil {
            // Symmetric with recoverUnresolvedFireIfNeeded — silently dropping a TIMEOUT
            // row defeats the audit-trail contract and would let a sleep-through go
            // unrecorded.
            logger.fault("handleRingCeiling: persistAttempt closure not wired — TIMEOUT row dropped")
        }
        persistAttempt?(.timeout, firedAt)
        lastFireAt = nil
        stopRinging()
    }

    /// Inserts UNRESOLVED rows for any fire that the previous app session began but never
    /// resolved (force-quit during ring). Call once at app launch from WakeProofApp.
    /// Surfaces a fault if `persistAttempt` is unwired at this point — silently dropping
    /// the recovery row would defeat the audit-trail contract that motivated this method.
    func recoverUnresolvedFireIfNeeded() {
        guard let firedAt = lastFireAt else { return }
        logger.warning("Recovering unresolved fire from previous session at \(firedAt.ISO8601Format(), privacy: .public)")
        if persistAttempt == nil {
            logger.fault("recoverUnresolvedFireIfNeeded: persistAttempt closure not wired — UNRESOLVED row dropped")
        }
        persistAttempt?(.unresolved, firedAt)
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
            UserDefaults.standard.set(lastFireAt, forKey: Self.lastFireAtDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.lastFireAtDefaultsKey)
        }
    }
}
