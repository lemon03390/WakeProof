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

    private let logger = Logger(subsystem: "com.wakeproof.alarm", category: "soundEngine")
    private var escalationTask: Task<Void, Never>?

    /// Begins the escalation loop. Caller is responsible for starting the actual
    /// audio playback on AudioSessionKeepalive before calling this.
    /// - Parameter setVolume: callback the engine invokes each ramp step.
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
                await MainActor.run { setVolume(v) }
                self?.logger.debug("Ramp step \(i, privacy: .public) → volume \(v, privacy: .public)")
                try? await Task.sleep(for: .seconds(stepInterval))
            }
        }
    }

    func stop() {
        escalationTask?.cancel()
        escalationTask = nil
        logger.info("Escalation stopped")
    }
}
