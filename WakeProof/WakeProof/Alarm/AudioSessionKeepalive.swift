//
//  AudioSessionKeepalive.swift
//  WakeProof
//
//  Keeps an AVAudioSession alive in the background so the app can produce
//  audio at alarm time even with the screen locked. This is the Alarmy-style
//  workaround for iOS's lack of a public Alarm API.
//
//  This file exists primarily for the Day 1 GO/NO-GO test. If the test fails,
//  the whole architecture pivots to a Shortcuts-based hybrid approach.
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
final class AudioSessionKeepalive {

    // MARK: - Public

    static let shared = AudioSessionKeepalive()

    private(set) var isActive: Bool = false
    private(set) var lastError: String?

    /// Activate the audio session with .playback category and start looping silence.
    /// Call this on app launch, before any alarm schedule is relevant.
    func start() {
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
        scheduleUnattendedTestTone()
    }

    /// Schedule a one-shot audible test tone 30 minutes after launch. This is the
    /// hands-off validation that the foreground audio session survives lock + background.
    /// Weak self avoids the singleton retaining the Task across the sleep window.
    private func scheduleUnattendedTestTone() {
        Task { [weak self] in
            let intervalSeconds: Double = 30 * 60
            let firesAt = Date().addingTimeInterval(intervalSeconds)
            self?.logger.info("30-min test tone scheduled for \(firesAt.ISO8601Format(), privacy: .public)")
            try? await Task.sleep(for: .seconds(intervalSeconds))
            self?.logger.info("30-min mark reached — firing test tone")
            self?.triggerTestTone()
        }
    }

    /// Stop the keepalive. Use when the user explicitly disables alarms.
    func stop() {
        silentPlayer?.stop()
        silentPlayer = nil
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            logger.error("Failed to deactivate audio session: \(error.localizedDescription, privacy: .public)")
        }
        isActive = false
    }

    /// Play a short audible tone — used for the Day 1 GO/NO-GO test to confirm
    /// the audio session survived a long background period.
    func triggerTestTone() {
        guard let url = Bundle.main.url(forResource: "test-tone", withExtension: "m4a") else {
            logger.error("test-tone.m4a missing from bundle")
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.volume = 1.0
            player.play()
            testTonePlayer = player // retain
            logger.info("Test tone triggered at \(Date().ISO8601Format(), privacy: .public)")
        } catch {
            logger.error("Failed to play test tone: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Private

    private let logger = Logger(subsystem: "com.wakeproof.audio", category: "session")
    private var silentPlayer: AVAudioPlayer?
    private var testTonePlayer: AVAudioPlayer?

    private init() {}

    private func startSilentLoop() throws {
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
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
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
                self.logger.info("Audio session interruption ENDED — reactivating")
                do {
                    try AVAudioSession.sharedInstance().setActive(true, options: [])
                    try self.startSilentLoop()
                } catch {
                    self.logger.error("Failed to reactivate after interruption: \(error.localizedDescription, privacy: .public)")
                }
            @unknown default:
                break
            }
        }

        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            self?.logger.info("Audio route changed at \(Date().ISO8601Format(), privacy: .public)")
        }
    }

    // MARK: - Alarm playback (alarm-core Phase B)

    private var alarmPlayer: AVAudioPlayer?

    /// Begin looping an alarm sound at moderate initial volume. Caller drives escalation via setAlarmVolume.
    func playAlarmSound(url: URL) {
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1
            player.volume = 0.3
            guard player.prepareToPlay(), player.play() else {
                logger.error("Alarm player refused to start for \(url.lastPathComponent, privacy: .public)")
                return
            }
            alarmPlayer = player
            logger.info("Alarm sound started at \(Date().ISO8601Format(), privacy: .public)")
        } catch {
            logger.error("Failed to start alarm sound: \(error.localizedDescription, privacy: .public)")
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
