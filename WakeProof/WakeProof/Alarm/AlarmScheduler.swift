//
//  AlarmScheduler.swift
//  WakeProof
//
//  Owns the user's wake-window configuration and the Task that fires the
//  alarm at window-start. Does not play audio directly — `playAlarmSound`
//  is a method on AudioSessionKeepalive added in Phase B. This separation
//  keeps the audio-critical file append-only during Phase 6.
//

import Foundation
import Observation
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
    private var fireTask: Task<Void, Never>?

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
    }

    func cancel() {
        fireTask?.cancel()
        fireTask = nil
        nextFireAt = nil
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

    // MARK: - Private

    private func fire() {
        logger.info("Alarm firing at \(Date().ISO8601Format(), privacy: .public)")
        isRinging = true
        onFire?()
        // Re-schedule the next day's fire. Cheap: this just sets up another Task.sleep.
        scheduleNextFireIfEnabled()
    }
}
