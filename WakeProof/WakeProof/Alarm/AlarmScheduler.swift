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

@Observable
@MainActor
final class AlarmScheduler {

    // MARK: - Observable state

    private(set) var window: WakeWindow
    private(set) var isRinging: Bool = false
    private(set) var nextFireAt: Date?

    // MARK: - Dependencies (late-bound; Phase B wires these)

    /// Set by the app at startup once AudioSessionKeepalive + AlarmSoundEngine are available.
    var onFire: (() -> Void)?

    // MARK: - Private

    private let logger = Logger(subsystem: "com.wakeproof.alarm", category: "scheduler")
    private let notificationCenter = UNUserNotificationCenter.current()
    private let backupNotificationIdentifier = "com.wakeproof.alarm.next"
    private var fireTask: Task<Void, Never>?
    private var backupScheduleTask: Task<Void, Never>?

    /// Loading the window from UserDefaults in init is intentional: the owning
    /// `@State private var scheduler = AlarmScheduler()` in WakeProofApp means this
    /// init runs exactly once per scene, not on every view redraw. SwiftUI `@State`
    /// preserves the reference across redraws for class types.
    init() {
        self.window = WakeWindow.load()
    }

    // MARK: - Public API

    func updateWindow(_ new: WakeWindow) {
        window = new
        window.save()
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
        let interval = fireAt.timeIntervalSinceNow
        logger.info("Alarm scheduled for \(fireAt.ISO8601Format(), privacy: .public) (in \(interval, privacy: .public)s)")
        fireTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.fire() }
        }
        // Store the scheduling Task handle: if cancel() runs before notificationCenter.add()
        // resolves, we must cancel this Task too — otherwise a stale request lands after cancel.
        backupScheduleTask = Task { [weak self] in await self?.scheduleBackupNotification(fireAt: fireAt) }
    }

    func cancel() {
        fireTask?.cancel()
        fireTask = nil
        backupScheduleTask?.cancel()
        backupScheduleTask = nil
        nextFireAt = nil
        notificationCenter.removePendingNotificationRequests(withIdentifiers: [backupNotificationIdentifier])
        notificationCenter.removeDeliveredNotifications(withIdentifiers: [backupNotificationIdentifier])
    }

    /// Demo-friendly manual trigger. Used by DEBUG "Fire now" button and by tests.
    func fireNow() {
        logger.info("Manual fireNow() invoked")
        fire()
    }

    func stopRinging() {
        isRinging = false
        logger.info("Ringing cleared")
    }

    /// Call from SwiftUI `.onChange(of: scenePhase)` when the app becomes active.
    /// Catches the case where Task.sleep was suspended past its fire time (OS froze the
    /// process overnight) — the backup notification will have beeped, but our in-process
    /// ringing UI needs a nudge to catch up.
    func reconcileAfterForeground() {
        guard !isRinging, let expected = nextFireAt else { return }
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
        guard !isRinging else {
            logger.info("fire() skipped — already ringing")
            return
        }
        // Clear any delivered backup notification so its iOS-side sound (up to 30 s) doesn't
        // overlap the in-app alarm we're about to start. Pending requests get removed as well
        // as a belt-and-suspenders cleanup before the next-day scheduling below.
        notificationCenter.removeDeliveredNotifications(withIdentifiers: [backupNotificationIdentifier])
        logger.info("Alarm firing at \(Date().ISO8601Format(), privacy: .public)")
        isRinging = true
        onFire?()
        // Re-schedule the next day's fire. Cheap: this just sets up another Task.sleep
        // plus a backup notification for tomorrow.
        scheduleNextFireIfEnabled()
    }

    private func scheduleBackupNotification(fireAt: Date) async {
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
        let triggerComponents = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: fireAt
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: triggerComponents, repeats: false)
        let request = UNNotificationRequest(identifier: backupNotificationIdentifier, content: content, trigger: trigger)
        do {
            try await notificationCenter.add(request)
            // UNUserNotificationCenter.add is not a cooperative cancellation point — a cancel()
            // that races with an in-flight add() will see the request land AFTER its
            // removePendingNotificationRequests ran, leaving a stale pending request. Re-check
            // Task.isCancelled post-resolve and self-heal.
            if Task.isCancelled {
                notificationCenter.removePendingNotificationRequests(withIdentifiers: [backupNotificationIdentifier])
                logger.info("Backup notification self-healed after late-resolve cancel")
                return
            }
            logger.info("Backup notification scheduled for \(fireAt.ISO8601Format(), privacy: .public)")
        } catch {
            logger.error("Failed to schedule backup notification: \(error.localizedDescription, privacy: .public)")
        }
    }
}
