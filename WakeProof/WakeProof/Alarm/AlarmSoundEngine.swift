//
//  AlarmSoundEngine.swift
//  WakeProof
//
//  Escalation policy: how alarm volume evolves while the user is dragging
//  their feet. Decoupled from AudioSessionKeepalive so the audio-critical
//  file stays append-only. This engine only asks the keepalive to mutate
//  volume; it never touches AVAudioPlayer directly.
//
//  Phase 8 product fix: the ring ceiling (auto-stop after 10 minutes) was
//  REMOVED. A self-commitment alarm whose whole pitch is "an alarm your
//  future self can't unsign" cannot ALSO contain a 10-minute escape hatch
//  — sleep-deprived users (the exact users this product targets) miss the
//  window and silently sleep through. The alarm now rings until the user
//  completes Proof or force-quits the app (which itself breaks the streak,
//  preserving the contract's accountability surface).
//
//  Volume reaches 1.0 after 60s and stays there indefinitely. There is no
//  software ceiling — the only natural terminations are:
//    1. user completes Proof → AlarmScheduler.markCaptureCompleted() → stop()
//    2. user force-quits → process death stops audio at the OS level
//    3. battery dies → device powers down
//

import Foundation
import Observation
import os

@Observable
@MainActor
final class AlarmSoundEngine {

    private let logger = Logger(subsystem: LogSubsystem.alarm, category: "soundEngine")
    private var escalationTask: Task<Void, Never>?

    /// Begins the escalation ramp. The alarm itself loops indefinitely at
    /// the AVAudioPlayer level (numberOfLoops = -1); this engine only drives
    /// the volume curve and exits once max volume is reached.
    ///
    /// - Parameter setVolume: invoked at each ramp step; caller maps this
    ///   to the AVAudioPlayer.
    func start(setVolume: @MainActor @escaping (Float) -> Void) {
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
            // Ramp complete — volume stays at 1.0 (last setVolume call). The
            // AVAudioPlayer loops indefinitely at the keepalive layer; no
            // ceiling task here, by design (see file header).
        }
    }

    func stop() {
        escalationTask?.cancel()
        escalationTask = nil
        logger.info("Escalation stopped")
    }

    /// Cancels ONLY the escalation ramp task (B6 fix). Called when UI wants
    /// to externally override volume (e.g. dip to 0.2 during verification)
    /// without the ramp's next tick overwriting the externally-set value.
    ///
    /// Intentionally one-way: once paused for a fire, we don't resume. A
    /// failed verification transitions the alarm back to `.ringing` with
    /// volume restored to 1.0 and we stay at 1.0 rather than re-ramping
    /// from 0.3 — the user has already engaged at least once, full-volume
    /// attention is warranted on the retry path.
    func pauseRamp() {
        escalationTask?.cancel()
        escalationTask = nil
        logger.info("Ramp paused")
    }
}
