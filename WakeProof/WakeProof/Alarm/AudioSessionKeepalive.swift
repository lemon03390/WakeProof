//
//  AudioSessionKeepalive.swift
//  WakeProof
//
//  Keeps an AVAudioSession alive in the background so the app can produce
//  audio at alarm time even with the screen locked. Works around iOS's lack
//  of a public Alarm API by playing a silent loop under the .playback category.
//
//  Requires:
//  - Background Modes > Audio, AirPlay, and Picture in Picture enabled in target capabilities
//  - A silent audio loop file (1–30s of silence) in the bundle, named "silence.m4a"
//
//  Reference: https://developer.apple.com/documentation/avfaudio/avaudiosession
//

import AVFoundation
import Foundation
import os

@Observable
@MainActor
final class AudioSessionKeepalive {

    // MARK: - Public

    static let shared = AudioSessionKeepalive()

    private(set) var isActive: Bool = false
    private(set) var lastError: String?

    /// Activate the audio session with .playback category and start looping silence.
    /// Idempotent — repeated calls (SwiftUI `.task` re-firing on view re-mount) won't
    /// stack interruption observers or duplicate the silent player.
    func start() {
        if isActive {
            logger.debug("start() called while already active — no-op")
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playback,
                mode: .default,
                options: [.mixWithOthers]
            )
            try session.setActive(true, options: [])

            logger.info("Audio session activated. category=\(session.category.rawValue, privacy: .public) isOtherAudioPlaying=\(session.isOtherAudioPlaying)")

            try startSilentLoop()
            isActive = true
            lastError = nil
        } catch {
            lastError = "Failed to activate audio session: \(error.localizedDescription)"
            logger.error("\(self.lastError ?? "", privacy: .public)")
            isActive = false
        }

        observeInterruptions()
    }

    /// Stop the keepalive. Use when the user explicitly disables alarms.
    func stop() {
        silentPlayer?.stop()
        silentPlayer = nil
        removeInterruptionObservers()
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            logger.error("Failed to deactivate audio session: \(error.localizedDescription, privacy: .public)")
        }
        isActive = false
    }

    // MARK: - Private

    private let logger = Logger(subsystem: "com.wakeproof.audio", category: "session")
    /// Nonisolated mirror of `logger` for closures that need to log from non-MainActor
    /// contexts without forcing a MainActor.assumeIsolated bridge (e.g. the route-change
    /// observer, which does no state mutation). Logger is thread-safe by Apple's contract.
    private nonisolated static let nonisolatedLogger = Logger(subsystem: "com.wakeproof.audio", category: "session")
    private var silentPlayer: AVAudioPlayer?
    /// Tokens returned by NotificationCenter.addObserver(forName:...). Stored so
    /// `removeInterruptionObservers()` can clean them up — without this, every `start()`
    /// call appended a new closure, and on `interruption.ended` ALL of them would run
    /// concurrently re-activating the session.
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?

    /// nonisolated so the static-let lazy initializer (which runs on the first-touch
    /// thread, not necessarily MainActor) can construct the singleton without a hop.
    /// The init body must do no MainActor-state mutation — the `precondition` enforces
    /// the implicit contract that the first access is from the main thread (i.e., from
    /// `@main` App.init), so any future addition of mutating work here will trap loudly
    /// rather than data-race silently.
    nonisolated private init() {
        precondition(Thread.isMainThread,
                     "AudioSessionKeepalive.shared first accessed off main thread — "
                     + "the init contract requires main-thread first-touch.")
    }

    private func startSilentLoop() throws {
        // Stop and release any prior player before allocating; otherwise interruption recovery
        // briefly contends two players over the same session before ARC reclaims the old one.
        silentPlayer?.stop()
        silentPlayer = nil
        guard let url = Bundle.main.url(forResource: "silence", withExtension: "m4a") else {
            throw KeepaliveError.missingSilenceAsset
        }
        let player = try AVAudioPlayer(contentsOf: url)
        player.numberOfLoops = -1 // infinite
        player.volume = 0.0 // inaudible but keeps session hot
        guard player.prepareToPlay(), player.play() else {
            throw KeepaliveError.playerRefusedToStart
        }
        silentPlayer = player
        logger.info("Silent loop started")
    }

    private func observeInterruptions() {
        // Defensive: if observers were somehow already installed, drop them first.
        removeInterruptionObservers()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            // queue: .main delivers on the main thread; MainActor.assumeIsolated bridges
            // that into the @MainActor concurrency domain. This is correct on iOS 17+ where
            // OperationQueue.main runs on the MainActor's executor, but the precondition
            // would trap if Apple ever decoupled them. Acceptable for this scope.
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let info = note.userInfo,
                      let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: rawType) else {
                    return
                }
                switch type {
                case .began:
                    self.logger.warning("Audio session interruption BEGAN at \(Date().ISO8601Format(), privacy: .public)")
                case .ended:
                    self.handleInterruptionEnded(info: info)
                @unknown default:
                    break
                }
            }
        }

        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { _ in
            // No state mutation here — just log. Use the nonisolated static logger so we
            // don't depend on the OperationQueue.main ↔ MainActor executor identity.
            Self.nonisolatedLogger.info("Audio route changed at \(Date().ISO8601Format(), privacy: .public)")
        }
    }

    private func removeInterruptionObservers() {
        if let token = interruptionObserver {
            NotificationCenter.default.removeObserver(token)
            interruptionObserver = nil
        }
        if let token = routeChangeObserver {
            NotificationCenter.default.removeObserver(token)
            routeChangeObserver = nil
        }
    }

    private func handleInterruptionEnded(info: [AnyHashable: Any]) {
        logger.info("Audio session interruption ENDED — reactivating")
        do {
            try AVAudioSession.sharedInstance().setActive(true, options: [])
            try startSilentLoop()
        } catch {
            logger.error("Failed to reactivate after interruption: \(error.localizedDescription, privacy: .public)")
            lastError = "Audio session interruption recovery failed: \(error.localizedDescription)"
            // startSilentLoop clears silentPlayer before re-allocating; if it throws partway,
            // observable state would still claim isActive==true while no player is running.
            // Flip to false so consumers see reality.
            isActive = false
        }

        // Alarm-class audio: the alarm player is paused by iOS during interruption.began.
        // We resume unconditionally (regardless of the system's ShouldResume hint) because
        // a sleeper letting their alarm get silenced by an incoming nightstand call is the
        // exact loophole the contract exists to close. We still log the system's hint so we
        // can tell the difference in Console when debugging.
        let optionsRaw = (info[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
        let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
        if let player = alarmPlayer, !player.isPlaying {
            logger.info("Resuming alarm player (system shouldResume hint=\(options.contains(.shouldResume), privacy: .public))")
            if player.play() {
                logger.info("Alarm player resumed after interruption.ended")
            } else {
                logger.error("Alarm player refused to resume after interruption.ended")
                lastError = "Alarm couldn't resume after interruption."
            }
        }
    }

    // MARK: - Alarm playback (separate player so the silent keepalive loop continues
    // unmodified while the alarm sound plays at full volume on top).

    private var alarmPlayer: AVAudioPlayer?

    /// Begin looping an alarm sound at moderate initial volume. Caller drives escalation via setAlarmVolume.
    /// Re-entrant safe: stops any prior alarm player so two AVAudioPlayers cannot fight over the session.
    func playAlarmSound(url: URL) {
        alarmPlayer?.stop()
        alarmPlayer = nil
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1
            player.volume = 0.3
            guard player.prepareToPlay(), player.play() else {
                let msg = "Alarm player refused to start for \(url.lastPathComponent)"
                logger.error("\(msg, privacy: .public)")
                lastError = msg
                return
            }
            alarmPlayer = player
            lastError = nil
            logger.info("Alarm sound started at \(Date().ISO8601Format(), privacy: .public)")
        } catch {
            let msg = "Failed to start alarm sound: \(error.localizedDescription)"
            logger.error("\(msg, privacy: .public)")
            lastError = msg
        }
    }

    func stopAlarmSound() {
        alarmPlayer?.stop()
        alarmPlayer = nil
        logger.info("Alarm sound stopped at \(Date().ISO8601Format(), privacy: .public)")
    }

    func setAlarmVolume(_ volume: Float) {
        alarmPlayer?.volume = max(0.0, min(1.0, volume))
    }

    enum KeepaliveError: Error {
        case missingSilenceAsset
        case playerRefusedToStart
    }
}
