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

    /// E-M7 (Wave 2.5): copy used by the interruption-began branch. Held in a
    /// constant so the `.ended` clear-path matches by reference rather than
    /// repeating a long string literal — a future copy edit can't cause the
    /// banner to stick on after interruption ends.
    private static let interruptionBannerMessage =
        "Audio interrupted (likely a phone call). Alarm should resume on call end."

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

    /// Restore the audio session category to the keepalive baseline
    /// (.playback + .mixWithOthers) without restarting the silent loop or
    /// touching active flags. Call this after temporarily reconfiguring the
    /// session — most importantly after an AVCaptureSession switches to
    /// .playAndRecord during camera capture. Without this restoration iOS
    /// keeps the orange-dot mic indicator visible until next foreground
    /// cycle, even though the app is no longer using the mic.
    ///
    /// Idempotent: safe to call from terminal callbacks even when the
    /// camera teardown order is uncertain. Throws so the caller can decide
    /// whether to log or recover; the keepalive's own interruption-end
    /// handler will retry on the next event if this throws.
    func restoreCategory() throws {
        try AVAudioSession.sharedInstance().setCategory(
            .playback,
            mode: .default,
            options: [.mixWithOthers]
        )
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

    private let logger = Logger(subsystem: LogSubsystem.audio, category: "session")
    /// Nonisolated mirror of `logger` for closures that need to log from non-MainActor
    /// contexts without forcing a MainActor.assumeIsolated bridge (e.g. the route-change
    /// observer, which does no state mutation). Logger is thread-safe by Apple's contract.
    private nonisolated static let nonisolatedLogger = Logger(subsystem: LogSubsystem.audio, category: "session")
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
            // L5 (Wave 2.7): previously used `MainActor.assumeIsolated` to bridge the
            // OperationQueue.main delivery into the @MainActor concurrency domain.
            // That relied on an undocumented Apple invariant (OperationQueue.main
            // shares the MainActor executor identity) — if iOS ever decoupled them,
            // assumeIsolated would TRAP on the exact audio-interruption path the
            // alarm's resume-after-phone-call recovery depends on (the loudest
            // possible regression: alarm doesn't resume after a nightstand call).
            // `Task { @MainActor in ... }` hops cooperatively, costs one scheduler
            // hop per interruption event (a handful per alarm at most), and can
            // never trap on an executor-identity mismatch. Cost is negligible
            // against the crash-safety upside.
            //
            // Sendable discipline: we extract the two Sendable-safe UInts
            // (interruption type + options raw) BEFORE the Task hop so the Task
            // closure never captures the non-Sendable `Notification` or the
            // `[AnyHashable: Any]` userInfo dictionary. The outer closure's
            // `[weak self]` makes `self` already-Optional here; we re-bind it
            // explicitly in the Task to avoid the Swift-6 "capture of captured var
            // self in concurrently-executing code" warning.
            let rawType = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) ?? 0
            let optionsRaw = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let type = AVAudioSession.InterruptionType(rawValue: rawType) else {
                    return
                }
                switch type {
                case .began:
                    self.logger.warning("Audio session interruption BEGAN")
                    // E-M7 (Wave 2.5): surface to AlarmSchedulerView's banner
                    // so a stuck `.ended` (rare iOS bug) doesn't leave the
                    // user with a silent alarm + no signal.
                    self.lastError = Self.interruptionBannerMessage
                case .ended:
                    // Clear our own interruption banner only — preserve any
                    // unrelated lastError set by another code path.
                    if self.lastError == Self.interruptionBannerMessage {
                        self.lastError = nil
                    }
                    self.handleInterruptionEnded(optionsRaw: optionsRaw)
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
            //
            // P-I7 (Wave 2.2, 2026-04-26): drop the per-event ISO8601Format()
            // call. `Logger` adds its own timestamp at log-emit time, so the
            // explicit format() was a redundant String allocation on every
            // route change. Over an 8-hour overnight session with frequent
            // Bluetooth pairings, the cost adds up. Logger's deferred
            // formatting on the literal is ~free.
            Self.nonisolatedLogger.info("Audio route changed")
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

    /// L5 (Wave 2.7): parameter changed from `info: [AnyHashable: Any]` to the
    /// already-extracted `optionsRaw: UInt` so the observer callback can hand us
    /// Sendable-safe values across the Task boundary (the full userInfo dict isn't
    /// Sendable under Swift 6 strict concurrency).
    private func handleInterruptionEnded(optionsRaw: UInt) {
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
    ///
    /// Phase 8 device-test fix: the silent-loop keepalive is supposed to keep
    /// the AVAudioSession active overnight, but iOS may silently invalidate
    /// the session under specific conditions (memory pressure, mediaserverd
    /// reset, prolonged background, edge-case interruption recovery failure).
    /// When that happens `player.play()` returns false and the alarm rings
    /// silently — the user sleeps through. Real overnight test reproduced
    /// this exact failure: alarm fired, banner showed "Alarm player refused
    /// to start for alarm.m4a", three G3 backup notifications also arrived
    /// silently (silent-mode iPhone), user woke up an hour late.
    ///
    /// Defensive re-arm: re-set category + setActive(true) before each
    /// playAlarmSound call. setCategory is idempotent (no-op when already
    /// .playback + .mixWithOthers), setActive(true) is also idempotent on an
    /// already-active session. Cost is one mediaserverd XPC on the alarm
    /// fire path (~10ms), which the user happily trades for "alarm actually
    /// rings" reliability.
    ///
    /// Retry-once fallback: if first play() returns false, await 100ms (give
    /// the session time to settle after re-arm) then retry. This catches the
    /// edge case where setActive returns success but the audio HW isn't yet
    /// routable. Two attempts is enough — beyond that something is genuinely
    /// broken and we want the lastError surfaced to the home banner.
    ///
    /// P-C1 / E-I12 (Wave 2.2, 2026-04-26): converted from sync `Thread.sleep`
    /// to `await Task.sleep`. The previous synchronous 100 ms block ran on
    /// @MainActor inside the alarm-fire path — which collides with SwiftUI's
    /// `.easeInOut(duration: 0.2)` phase-transition animation on @MainActor.
    /// 100 ms of frozen MainActor during a 200 ms animation = visible stutter
    /// + dropped frame at the most demo-critical moment. Async sleep yields
    /// MainActor while we wait for mediaserverd to settle.
    ///
    /// Callers must await — see WakeProofApp's `onFire` closure which now
    /// spawns a `Task { @MainActor in await audioKeepalive.playAlarmSound(...) }`.
    func playAlarmSound(url: URL) async {
        alarmPlayer?.stop()
        alarmPlayer = nil
        rearmSessionForAlarm()
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1
            player.volume = 0.5
            if player.prepareToPlay(), player.play() {
                alarmPlayer = player
                lastError = nil
                logger.info("Alarm sound started")
                return
            }
            // First attempt refused — re-arm + retry once. Common cause:
            // setActive returned true but the audio route wasn't yet
            // reconfigured (XPC race). 100ms gives mediaserverd time to
            // settle. Async sleep yields MainActor instead of blocking it.
            logger.warning("Alarm player.play() refused on first attempt — re-arming session for retry")
            rearmSessionForAlarm()
            try? await Task.sleep(for: .milliseconds(100))
            let retry = try AVAudioPlayer(contentsOf: url)
            retry.numberOfLoops = -1
            retry.volume = 0.5
            if retry.prepareToPlay(), retry.play() {
                alarmPlayer = retry
                lastError = nil
                logger.info("Alarm sound started on retry")
                return
            }
            let msg = "Alarm player refused to start for \(url.lastPathComponent) (after retry)"
            logger.error("\(msg, privacy: .public)")
            lastError = msg
        } catch {
            let msg = "Failed to start alarm sound: \(error.localizedDescription)"
            logger.error("\(msg, privacy: .public)")
            lastError = msg
        }
    }

    /// Defense-in-depth: reset category + reactivate the session before each
    /// alarm fire. The silent-loop keepalive is supposed to keep this hot,
    /// but real overnight tests showed iOS can silently invalidate the
    /// session — without re-arm, `player.play()` then refuses. Both calls
    /// are idempotent on an already-correct session. Logged at info level
    /// so a recurring re-arm pattern in Console signals a flaky keepalive
    /// worth deeper investigation.
    private func rearmSessionForAlarm() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true, options: [])
            logger.info("Audio session re-armed for alarm fire (category=\(session.category.rawValue, privacy: .public))")
        } catch {
            logger.error("Pre-alarm session re-arm failed: \(error.localizedDescription, privacy: .public). play() may refuse.")
            // Not fatal here — let playAlarmSound's main path attempt the
            // play and surface its own error if it fails. The error here
            // is observable in Console for post-mortem.
        }
    }

    func stopAlarmSound() {
        alarmPlayer?.stop()
        alarmPlayer = nil
        logger.info("Alarm sound stopped")
    }

    func setAlarmVolume(_ volume: Float) {
        // L9 (Wave 2.7): optional chaining on `alarmPlayer?.volume = ...` silently
        // no-ops when the player is nil (after stop). That's functionally fine —
        // there's nothing to mutate — but a nil player while setAlarmVolume is
        // still being called means the ramp task (AlarmSoundEngine) is outrunning
        // the stop path. Log the short-circuit so volume-ramp-after-stop timing
        // weirdness is diagnosable from Console without needing a debugger.
        if alarmPlayer == nil {
            // E-I13 (Wave 2.5, 2026-04-26): bumped from .debug to .warning. .debug
            // doesn't ship in production console output, so volume-ramp-after-stop
            // patterns were invisible to triage. .warning makes them surface in
            // device Console where a user-reported "alarm too quiet" can be
            // correlated with a ramp that ran while the player was nil.
            logger.warning("setAlarmVolume(\(volume, privacy: .public)) called but alarmPlayer is nil — ramp outrunning stop")
            return
        }
        alarmPlayer?.volume = max(0.0, min(1.0, volume))
    }

    enum KeepaliveError: Error {
        case missingSilenceAsset
        case playerRefusedToStart
    }
}
