//
//  AlarmSoundEngine.swift
//  WakeProof
//
//  Escalation policy: how alarm volume and sound selection evolve while the
//  user is dragging their feet. Decoupled from AudioSessionKeepalive so the
//  audio-critical file stays append-only. This engine only asks the keepalive
//  to mutate volume; it never touches AVAudioPlayer directly.
//

import Foundation
import Observation
import os

@Observable
@MainActor
final class AlarmSoundEngine {

    /// Max wall-clock duration the alarm is allowed to ring before we hard-stop.
    /// Rationale: if the capture flow silently fails (extraction error, camera crash,
    /// or the user simply ignores the alarm), the self-commitment promise of "can't be
    /// bypassed" devolves into "device blares at full volume forever" which is worse.
    /// The ceiling trades a correctness gap (user can wait out the alarm) for a
    /// reliability floor (we never deadlock a demo device).
    static let ringCeiling: Duration = .seconds(10 * 60)

    private let logger = Logger(subsystem: LogSubsystem.alarm, category: "soundEngine")
    private var escalationTask: Task<Void, Never>?
    private var ceilingTask: Task<Void, Never>?

    /// Begins the escalation loop and arms the ring-ceiling safety net.
    ///
    /// - Parameters:
    ///   - setVolume: invoked at each ramp step; caller maps this to the AVAudioPlayer.
    ///   - onCeilingReached: invoked (on MainActor) if the alarm is still running at
    ///     the ceiling. Expected to stop audio + clear ringing state + log a WakeAttempt.
    func start(
        setVolume: @MainActor @escaping (Float) -> Void,
        onCeilingReached: @MainActor @escaping () -> Void
    ) {
        stop()
        logger.info("Escalation started at \(Date().ISO8601Format(), privacy: .public)")
        escalationTask = Task { [weak self] in
            // Ramp 0.3 → 1.0 over 60 s in 12 steps.
            let steps = 12
            let startVolume: Float = 0.3
            let endVolume: Float = 1.0
            let stepInterval: Double = 60.0 / Double(steps)
            for i in 0...steps {
                guard !Task.isCancelled else { return }
                let t = Float(i) / Float(steps)
                let v = startVolume + (endVolume - startVolume) * t
                // Re-check cancellation right before the actor hop — without this, a stop()
                // racing the loop can let setVolume run on a player the keepalive already cleared.
                guard !Task.isCancelled else { return }
                await MainActor.run { setVolume(v) }
                self?.logger.debug("Ramp step \(i, privacy: .public) → volume \(v, privacy: .public)")
                do {
                    try await Task.sleep(for: .seconds(stepInterval))
                } catch is CancellationError {
                    return
                } catch {
                    self?.logger.warning("Ramp sleep threw non-cancellation: \(error.localizedDescription, privacy: .public) — aborting ramp")
                    return
                }
            }
        }
        ceilingTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.ringCeiling)
            } catch is CancellationError {
                return
            } catch {
                self?.logger.warning("Ceiling sleep threw non-cancellation: \(error.localizedDescription, privacy: .public)")
                return
            }
            guard !Task.isCancelled, let self else { return }
            await MainActor.run {
                self.logger.warning("Ring ceiling reached (\(Self.ringCeiling, privacy: .public)) — forcing alarm stop")
                onCeilingReached()
            }
        }
    }

    func stop() {
        escalationTask?.cancel()
        escalationTask = nil
        ceilingTask?.cancel()
        ceilingTask = nil
        logger.info("Escalation stopped")
    }

    /// B6 fix: cancels ONLY the escalation ramp task, leaving the ring-ceiling safety net
    /// armed. Called when UI wants to externally override volume (e.g. dip to 0.2 during
    /// verification) without the ramp's next tick overwriting our externally-set value.
    ///
    /// Intentionally one-way: once paused for a fire, we don't resume. A failed
    /// verification transitions the alarm back to `.ringing` with volume restored to 1.0
    /// and we want to stay at 1.0 rather than re-ramping from 0.3 — the user has
    /// already engaged at least once, full-attention is warranted for the retry.
    func pauseRamp() {
        escalationTask?.cancel()
        escalationTask = nil
        logger.info("Ramp paused (ceiling still armed)")
    }
}
