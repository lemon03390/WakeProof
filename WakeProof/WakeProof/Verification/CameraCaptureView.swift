//
//  CameraCaptureView.swift
//  WakeProof
//
//  Wake-time capture: a short (≤2 s) video plus a middle-frame still extracted
//  for the vision-verification prompt. Both outputs are persisted locally first;
//  vision API is invoked downstream from the persisted artifacts.
//
//  Simulator: falls through to a stub that injects a dummy result so home-flow
//  UI iteration doesn't dead-end at an unavailable camera. Device path is unaffected.
//
//  Device path (Phase 8 rewrite): AVCaptureSession-backed `CameraRecorderViewController`
//  replaces the prior UIImagePickerController. Why:
//    1. iPhone 17 Pro / iOS 26 + UIImagePickerController video mode failed with
//       repeated `Fig` errors -12710 / -17281 because BackTriple isn't supported by
//       the picker (auto-fallback to BackAuto then asserts). AVCaptureSession with
//       an explicit `.builtInWideAngleCamera` device avoids the picker's broken
//       device-selection path entirely.
//    2. UIImagePickerController forces its own audio session category (`.record`)
//       which silences the alarm sound during recording. AVCaptureSession lets us
//       keep `.playAndRecord` + `.mixWithOthers` so the alarm continues ringing
//       through the 2-second capture (preserves wake-up pressure).
//    3. We can auto-record + auto-stop after 2 seconds without forcing the user
//       to tap "Record" then "Stop" — fewer taps, more demo-friendly.
//

import AVFoundation
import SwiftUI
import UIKit
import os

struct CameraCaptureResult {
    let stillImage: UIImage
    let videoURL: URL
}

enum CameraCaptureError: LocalizedError {
    case cameraUnavailable
    case sessionConfigFailed(underlying: Error)
    case recordingFailed(underlying: Error)
    case noVideoURLReturned
    case frameExtractionFailed(underlying: Error)
    case dismissedWhileBackgrounded

    var errorDescription: String? {
        switch self {
        case .cameraUnavailable:          return "Camera unavailable. Try restarting WakeProof."
        case .sessionConfigFailed:        return "Couldn't start camera. Try once more — if it persists, restart WakeProof."
        case .recordingFailed:            return "Recording failed. Tap \"Prove you're awake\" to retry."
        case .dismissedWhileBackgrounded: return "Camera closed while app was backgrounded. Try again."
        case .frameExtractionFailed:      return "Couldn't read the captured video. Try again — good light, face visible."
        case .noVideoURLReturned:         return "Capture failed. Try again."
        }
    }
}

struct CameraCaptureView: View {

    let onCaptured: (CameraCaptureResult) -> Void
    let onCancelled: () -> Void
    let onFailed: (CameraCaptureError) -> Void

    var body: some View {
        #if targetEnvironment(simulator)
        SimulatorCameraStubView(onProceed: { onCaptured(Self.fakeResult()) },
                                onCancel: onCancelled)
        #else
        DeviceCameraRecorder(onCaptured: onCaptured,
                             onCancelled: onCancelled,
                             onFailed: onFailed)
            .ignoresSafeArea()
        #endif
    }

    #if targetEnvironment(simulator)
    /// Synthetic result so simulator demos still exercise the persistence + dismiss path.
    private static func fakeResult() -> CameraCaptureResult {
        let size = CGSize(width: 400, height: 400)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.systemGray.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        // Simulator scratch path. Real device uses tmp → CameraCaptureFlow copies into Documents.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("simulator-stub-\(UUID().uuidString).mov")
        FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: nil)
        return CameraCaptureResult(stillImage: image, videoURL: url)
    }
    #endif
}

// MARK: - Simulator stub

#if targetEnvironment(simulator)
private struct SimulatorCameraStubView: View {
    let onProceed: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.wpChar900.ignoresSafeArea()
            VStack(spacing: WPSpacing.xl) {
                Image(systemName: "camera.metering.unknown")
                    .font(.system(size: 64))
                    .foregroundStyle(Color.wpCream50.opacity(0.7))
                Text("Simulator has no camera")
                    .wpFont(.title3)
                    .foregroundStyle(Color.wpCream50)
                Text("Verification is stubbed here. On a real device this is the 2-second video capture screen.")
                    .wpFont(.callout)
                    .foregroundStyle(Color.wpCream50.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, WPSpacing.xl2)
                VStack(spacing: WPSpacing.sm) {
                    Button("Inject stub verification") { onProceed() }
                        .buttonStyle(.borderedProminent)
                    Button("Cancel", role: .cancel) { onCancel() }
                        .foregroundStyle(Color.wpCream50)
                }
                .padding(.top, WPSpacing.md)
            }
        }
        .preferredColorScheme(.dark)
    }
}
#endif

// MARK: - Device camera (AVCaptureSession-backed recorder)

#if !targetEnvironment(simulator)
private struct DeviceCameraRecorder: UIViewControllerRepresentable {

    let onCaptured: (CameraCaptureResult) -> Void
    let onCancelled: () -> Void
    let onFailed: (CameraCaptureError) -> Void

    func makeUIViewController(context: Context) -> CameraRecorderViewController {
        let vc = CameraRecorderViewController()
        vc.onCaptured = onCaptured
        vc.onCancelled = onCancelled
        vc.onFailed = onFailed
        return vc
    }

    func updateUIViewController(_ uiViewController: CameraRecorderViewController, context: Context) {
        // Callbacks captured at make; no per-update work.
    }
}

/// AVCaptureSession-backed recorder. Auto-starts a 2-second recording when the
/// camera session is ready, extracts a middle frame from the resulting movie,
/// and reports back via the SwiftUI `CameraCaptureView` callbacks.
///
/// Why a custom VC instead of UIImagePickerController:
///   - iPhone 17 Pro / iOS 26 + picker video mode fails with `Fig` errors
///     (-12710 / -17281) because BackTriple isn't a picker-supported device;
///     explicit `.builtInWideAngleCamera` discovery sidesteps the picker's
///     broken auto-selection path.
///   - The picker forces audio session category `.record`, silencing the alarm.
///     AVCaptureSession leaves us in control of the audio session — we set
///     `.playAndRecord` + `.mixWithOthers` so the alarm sound continues
///     through the 2-second capture, preserving wake-up pressure.
///   - Auto-record + auto-stop = fewer taps than the picker's
///     "tap-record-then-tap-stop" flow.
///
/// Threading discipline:
///   - AVCaptureSession config + start/stop runs on a private serial queue
///     (per Apple's `AVCaptureSession` docs — main-thread `startRunning` blocks).
///   - All UI mutations (preview layer, overlay state, callback invocations)
///     hop back to MainActor.
///   - Terminal callbacks fire exactly once via `reportTerminal(...)` latch,
///     preventing re-entrant callbacks if teardown races with a delegate
///     completion.
@MainActor
private final class CameraRecorderViewController: UIViewController {

    /// Single source of truth for the unwired-callback log. All three
    /// callback defaults reference this, so a category rename happens
    /// in one place rather than three.
    private static let unwiredLog = Logger(subsystem: LogSubsystem.verification, category: "cameraRecorder")

    var onCaptured: (CameraCaptureResult) -> Void = { _ in
        Self.unwiredLog.fault("onCaptured fired but no handler wired — alarm will hang in .capturing")
    }
    var onCancelled: () -> Void = {
        Self.unwiredLog.fault("onCancelled fired but no handler wired — alarm will hang in .capturing")
    }
    var onFailed: (CameraCaptureError) -> Void = { _ in
        Self.unwiredLog.fault("onFailed fired but no handler wired — alarm will hang in .capturing")
    }

    /// Recording duration. 2.0s matches the docs/technical-decisions.md design
    /// intent. Constant rather than parameterised because the downstream
    /// validator's ≥1s minimum + the H1 vision prompt's tuning both assume
    /// this clip length.
    private static let recordingDuration: TimeInterval = 2.0

    private let logger = Logger(subsystem: LogSubsystem.verification, category: "cameraRecorder")
    private let sessionQueue = DispatchQueue(label: "com.wakeproof.camera-session", qos: .userInitiated)

    private let captureSession = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasReportedTerminalOutcome = false
    /// Strong reference to the recording delegate. AVFoundation only weakly
    /// retains `AVCaptureFileOutputRecordingDelegate`, so a struct or local
    /// would dealloc before `didFinishRecordingTo` fires.
    private var recordingDelegate: RecordingDelegate?
    /// Output URL the session writes to. Stored so the cancel path can clean
    /// up the in-flight file. Set to nil on the success path to transfer
    /// ownership to CameraCaptureFlow (which moves the file into Documents)
    /// — the nil acts as a "do not delete" signal to discardOutputFileIfNeeded.
    private var outputURL: URL?

    // MARK: - UIViewController lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .wpChar900
        installCancelButton()
        installRecordingIndicator()
        // Detect "user backgrounded the app mid-capture, then returned" —
        // without this the VC stays on screen with no callback firing.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        // SwiftUI may tear down the UIViewControllerRepresentable without going
        // through cancel/success — most commonly via the CameraCaptureFlow
        // 30s watchdog firing returnToRingingWith(...) mid-recording. Without
        // explicit teardown the AVCaptureSession keeps running and the orange
        // mic indicator stays on indefinitely.
        //
        // Two cleanups required, both safe in deinit (last-reference, no
        // re-entrancy):
        //   1. captureSession.stopRunning on sessionQueue
        //   2. AVAudioSession category restored to .playback so the mic
        //      indicator clears (even if normal restoreAudioSession() path
        //      didn't run).
        let session = captureSession
        sessionQueue.async {
            if session.isRunning {
                session.stopRunning()
            }
        }
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback, mode: .default, options: [.mixWithOthers]
            )
        } catch {
            Self.unwiredLog.warning("deinit audio category restore failed: \(error.localizedDescription, privacy: .public). Mic indicator may stay visible until next interruption.")
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Audio session reconfigure + capture session config both run on
        // sessionQueue — keeps the mediaserverd XPC traffic off the main
        // thread (would otherwise jank the view-appear animation on a slow
        // wake-up) and preserves the ordering invariant (audio category
        // must be active before AVCaptureSession adds its mic input).
        sessionQueue.async { [weak self] in
            self?.configureAudioSession()
            self?.configureAndStartSession()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Guard the assign so a layout-pass without a bounds change doesn't
        // mark the layer dirty and trigger an unnecessary compositing pass.
        if let previewLayer, previewLayer.frame != view.bounds {
            previewLayer.frame = view.bounds
        }
    }

    // MARK: - Audio session

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // .playAndRecord with .mixWithOthers lets the alarm sound (driven
            // by AudioSessionKeepalive's playback player) continue while the
            // capture session opens the microphone. Without .mixWithOthers
            // iOS silences other audio when a record-capable category becomes
            // active. .defaultToSpeaker forces output to the speaker so the
            // alarm sound is audible during recording (otherwise iOS routes
            // playback to the receiver during a record-capable session).
            try session.setCategory(
                .playAndRecord,
                mode: .videoRecording,
                options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothHFP]
            )
            try session.setActive(true, options: [])
            logger.info("Audio session reconfigured: .playAndRecord + .mixWithOthers for capture")
        } catch {
            logger.error("Audio session reconfigure failed: \(error.localizedDescription, privacy: .public)")
            // Non-fatal: capture can still proceed; alarm may go silent
            // during recording, which is the prior UIImagePickerController
            // behaviour. Surfacing as a recordingFailed would over-alert.
        }
    }

    /// Restore the audio session category via AudioSessionKeepalive's
    /// dedicated `restoreCategory()` helper so the wp* baseline lives in
    /// one place. Falling back to the keepalive's interruption-end handler
    /// on throw is acceptable — the next .interruptionEnded event will
    /// re-establish .playback. Hops to MainActor because the singleton is
    /// @MainActor-isolated.
    private func restoreAudioSession() {
        Task { @MainActor in
            do {
                try AudioSessionKeepalive.shared.restoreCategory()
                Self.unwiredLog.info("Audio session restored to keepalive baseline")
            } catch {
                Self.unwiredLog.warning("Audio session restore failed: \(error.localizedDescription, privacy: .public). Keepalive's interruption-end handler will retry on next event.")
            }
        }
    }

    // MARK: - Session configuration (sessionQueue)

    private func configureAndStartSession() {
        // Defense-in-depth: onboarding's PermissionsManager is supposed to
        // grant camera before any wake fires, but a user who revoked
        // camera in Settings would otherwise see a misleading
        // "Camera unavailable" error. Surface microphoneUnavailable /
        // cameraUnavailable explicitly so the AlarmRingingView banner
        // points at the right Settings path.
        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        guard cameraStatus == .authorized else {
            logger.error("Camera not authorized (status=\(cameraStatus.rawValue, privacy: .public))")
            DispatchQueue.main.async { [weak self] in
                self?.reportTerminal { self?.onFailed(.cameraUnavailable) }
            }
            return
        }
        // Microphone is soft-required (recording falls through to video-only
        // if the input fails to add). But if the user explicitly revoked it,
        // surface the dedicated error so the banner can point at the right
        // Settings path. .notDetermined falls through — AVCaptureSession will
        // prompt at first capture.
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if micStatus == .denied || micStatus == .restricted {
            logger.warning("Microphone explicitly denied (status=\(micStatus.rawValue, privacy: .public)) — proceeding video-only")
            // Not a hard fail: we can still record video. The downstream
            // verifier doesn't use the audio track. Just don't try to add
            // the mic input below.
        }

        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        // .medium is sufficient for the vision prompt's face-in-frame check
        // and cuts the .mov size by ~80% vs .high (480p ~1Mbps vs 1080p
        // ~15Mbps), reducing both AVAssetImageGenerator decode time and the
        // downstream upload payload to Claude. Adjust to .high if the vision
        // team determines spoofing detection benefits from higher resolution.
        captureSession.sessionPreset = .medium

        // Camera input — explicit .builtInWideAngleCamera + .back avoids the
        // BackTriple discovery path that crashes UIImagePickerController on
        // iPhone 17 Pro / iOS 26. No front-camera fallback: every iPhone
        // capable of running iOS 17+ has a rear wide-angle camera; the
        // .front fallback was unreachable dead code.
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            logger.error("No wide-angle camera available")
            DispatchQueue.main.async { [weak self] in
                self?.reportTerminal { self?.onFailed(.cameraUnavailable) }
            }
            return
        }
        do {
            let videoInput = try AVCaptureDeviceInput(device: camera)
            guard captureSession.canAddInput(videoInput) else {
                logger.error("Cannot add video input")
                DispatchQueue.main.async { [weak self] in
                    self?.reportTerminal { self?.onFailed(.cameraUnavailable) }
                }
                return
            }
            captureSession.addInput(videoInput)
        } catch {
            logger.error("Video input init failed: \(error.localizedDescription, privacy: .public)")
            DispatchQueue.main.async { [weak self] in
                self?.reportTerminal { self?.onFailed(.sessionConfigFailed(underlying: error)) }
            }
            return
        }

        // Microphone input. Skipped entirely when the user explicitly denied
        // (per the status check above); otherwise added if available, with
        // soft-failure on init errors. The downstream verifier doesn't use
        // the audio track so video-only is acceptable.
        if micStatus != .denied, micStatus != .restricted,
           let mic = AVCaptureDevice.default(for: .audio) {
            do {
                let audioInput = try AVCaptureDeviceInput(device: mic)
                if captureSession.canAddInput(audioInput) {
                    captureSession.addInput(audioInput)
                } else {
                    logger.warning("Cannot add audio input — recording video-only")
                }
            } catch {
                logger.warning("Audio input init failed (\(error.localizedDescription, privacy: .public)) — recording video-only")
            }
        } else {
            logger.warning("Skipping audio input (status=\(micStatus.rawValue, privacy: .public)) — recording video-only")
        }

        // Movie file output.
        guard captureSession.canAddOutput(movieOutput) else {
            logger.error("Cannot add movie output")
            DispatchQueue.main.async { [weak self] in
                self?.reportTerminal { self?.onFailed(.cameraUnavailable) }
            }
            return
        }
        captureSession.addOutput(movieOutput)

        // Start running. Once running, hop to main to install the preview
        // layer + kick off the auto-record sequence.
        captureSession.startRunning()
        DispatchQueue.main.async { [weak self] in
            self?.installPreviewLayer()
            self?.startRecording()
        }
    }

    // MARK: - Preview layer + overlay (MainActor)

    private func installPreviewLayer() {
        let layer = AVCaptureVideoPreviewLayer(session: captureSession)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.insertSublayer(layer, at: 0)
        previewLayer = layer
    }

    private lazy var cancelButton: UIButton = {
        let button = UIButton(type: .system)
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "xmark.circle.fill",
                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 32, weight: .regular))
        config.baseForegroundColor = UIColor.wpCream50.withAlphaComponent(0.85)
        button.configuration = config
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(handleCancelTap), for: .touchUpInside)
        return button
    }()

    private lazy var recordingIndicator: UIView = {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        // Warm-charcoal scrim instead of black so the indicator stays
        // on-brand against the camera preview.
        container.backgroundColor = UIColor.wpChar900.withAlphaComponent(0.5)
        container.layer.cornerRadius = 14
        let dot = UIView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.backgroundColor = .wpCoral
        dot.layer.cornerRadius = 5
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Recording…"
        label.textColor = .wpCream50
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        container.addSubview(dot)
        container.addSubview(label)
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            dot.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            container.heightAnchor.constraint(equalToConstant: 28)
        ])
        // Pulse the dot so the user has a visual heartbeat.
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.3
        pulse.duration = 0.6
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        dot.layer.add(pulse, forKey: "pulse")
        return container
    }()

    private func installCancelButton() {
        view.addSubview(cancelButton)
        NSLayoutConstraint.activate([
            cancelButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            cancelButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16)
        ])
    }

    private func installRecordingIndicator() {
        view.addSubview(recordingIndicator)
        NSLayoutConstraint.activate([
            recordingIndicator.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            recordingIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        ])
        recordingIndicator.isHidden = true
    }

    // MARK: - Recording flow

    private func startRecording() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wakeproof-capture-\(UUID().uuidString).mov")
        outputURL = url
        let delegate = RecordingDelegate { [weak self] result in
            // Bridge the file-output's background callback back to MainActor.
            Task { @MainActor [weak self] in
                self?.handleRecordingFinished(result: result)
            }
        }
        recordingDelegate = delegate
        recordingIndicator.isHidden = false
        movieOutput.startRecording(to: url, recordingDelegate: delegate)
        logger.info("startRecording → \(url.lastPathComponent, privacy: .public)")

        // Auto-stop after the configured duration. weak self so a
        // cancel-then-tap sequence doesn't keep the VC alive.
        Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(Self.recordingDuration))
            } catch is CancellationError {
                // View torn down or recording already stopped — caller no
                // longer needs the auto-stop. Returning here also avoids a
                // benign-but-noisy stopRecording on a stale VC reference.
                return
            } catch {
                self?.logger.warning("Auto-stop sleep threw non-cancellation error: \(error.localizedDescription, privacy: .public). Stopping anyway to avoid runaway recording.")
            }
            guard let self else { return }
            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
            }
        }
    }

    private func handleRecordingFinished(result: Result<URL, CameraCaptureError>) {
        recordingIndicator.isHidden = true
        switch result {
        case .success(let url):
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.tearDownSession() }
                do {
                    let still = try await Self.extractMiddleFrame(videoURL: url)
                    // Nil out before tearDown so discardOutputFileIfNeeded
                    // (called from a parallel cancel race) doesn't delete the
                    // file CameraCaptureFlow.persist now owns.
                    self.outputURL = nil
                    self.reportTerminal {
                        self.onCaptured(CameraCaptureResult(stillImage: still, videoURL: url))
                    }
                } catch {
                    self.logger.error("Frame extraction failed: \(error.localizedDescription, privacy: .public)")
                    self.discardOutputFileIfNeeded()
                    self.reportTerminal {
                        self.onFailed(.frameExtractionFailed(underlying: error))
                    }
                }
            }
        case .failure(let error):
            discardOutputFileIfNeeded()
            tearDownSession()
            reportTerminal { onFailed(error) }
        }
    }

    private func tearDownSession() {
        sessionQueue.async { [captureSession] in
            if captureSession.isRunning {
                captureSession.stopRunning()
            }
        }
        restoreAudioSession()
        recordingDelegate = nil
    }

    /// Best-effort tmp file cleanup. Called on every non-success terminal
    /// path (cancel + failure) since the success path transfers ownership
    /// to CameraCaptureFlow.persist by setting outputURL = nil first.
    /// Operates directly with try/catch on removeItem rather than a
    /// fileExists pre-check (TOCTOU-safe + simpler).
    private func discardOutputFileIfNeeded() {
        guard let url = outputURL else { return }
        outputURL = nil
        do {
            try FileManager.default.removeItem(at: url)
            logger.info("Cleaned up tmp capture file \(url.lastPathComponent, privacy: .public)")
        } catch let error as NSError where error.code == NSFileNoSuchFileError {
            // File never existed or was already gone — nothing to clean.
        } catch {
            logger.warning("Failed to clean up tmp capture file \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public). iOS will reclaim it eventually.")
        }
    }

    @objc private func handleCancelTap() {
        if movieOutput.isRecording {
            // stopRecording fires fileOutput(_:didFinishRecordingTo:) shortly
            // after; the reportTerminal latch ensures whichever side claims
            // first wins. Discarding the file here covers the cancel-then-
            // success-callback race so we don't leave a half-written .mov.
            movieOutput.stopRecording()
        }
        discardOutputFileIfNeeded()
        tearDownSession()
        reportTerminal { onCancelled() }
    }

    @objc private func handleAppDidBecomeActive() {
        // captureSession.isRunning false + recording false means teardown ran
        // (our own paths nil-out their work) — combined with !hasReportedTerminalOutcome
        // this means the app backgrounded mid-capture and our terminal callbacks
        // never fired.
        guard !hasReportedTerminalOutcome,
              !movieOutput.isRecording,
              !captureSession.isRunning else { return }
        logger.warning("App returned to foreground but capture session isn't running — reporting dismissedWhileBackgrounded")
        reportTerminal { onFailed(.dismissedWhileBackgrounded) }
    }

    private func reportTerminal(_ block: () -> Void) {
        guard !hasReportedTerminalOutcome else { return }
        hasReportedTerminalOutcome = true
        block()
    }

    // MARK: - Frame extraction

    /// Extract a frame at ~75% of the clip (never at t=0 for very-short videos — the early
    /// pre-roll can be black or out-of-focus, which would poison the vision call).
    private static func extractMiddleFrame(videoURL: URL) async throws -> UIImage {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let duration = try await asset.load(.duration)
        let targetSeconds = max(0.3, duration.seconds * 0.75)
        let timescale = max(duration.timescale, 600)
        let target = CMTime(seconds: targetSeconds, preferredTimescale: timescale)
        let cgImage = try await generator.image(at: target).image
        return UIImage(cgImage: cgImage)
    }
}

// MARK: - Recording delegate

/// Plain NSObject delegate that bridges AVCaptureFileOutputRecordingDelegate's
/// callbacks into a single completion closure. Stored as a strong property on
/// the VC because AVFoundation weakly retains delegates.
private final class RecordingDelegate: NSObject, AVCaptureFileOutputRecordingDelegate {

    private let completion: (Result<URL, CameraCaptureError>) -> Void
    private let logger = Logger(subsystem: LogSubsystem.verification, category: "recordingDelegate")

    init(completion: @escaping (Result<URL, CameraCaptureError>) -> Void) {
        self.completion = completion
    }

    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        // AVCaptureMovieFileOutput can report an error even on a successful
        // recording (e.g. -11810 "max length reached"). Treat file existence
        // + non-zero size as the success signal; only fall through to
        // failure when the file is missing/empty.
        let size: Int
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: outputFileURL.path)
            size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        } catch let attrError {
            logger.error("attributesOfItem failed for \(outputFileURL.lastPathComponent, privacy: .public): \(attrError.localizedDescription, privacy: .public)")
            // If AVCapture also reported an error, surface that instead — it
            // describes the recording-time problem, while the attribute read
            // is a downstream symptom.
            if let error {
                completion(.failure(.recordingFailed(underlying: error)))
            } else {
                completion(.failure(.recordingFailed(underlying: attrError)))
            }
            return
        }
        if size > 0 {
            completion(.success(outputFileURL))
            return
        }
        if let error {
            completion(.failure(.recordingFailed(underlying: error)))
        } else {
            completion(.failure(.noVideoURLReturned))
        }
    }
}
#endif
