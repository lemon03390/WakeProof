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
//  Device path: CameraHostController (plain UIViewController) presents
//  UIImagePickerController MODALLY. Embedding the picker as a SwiftUI representable's
//  wrapped VC violates Apple's "must present modally, must not install as subview"
//  rule — the camera framework initializes but the UI never renders.
//

import AVFoundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import os

struct CameraCaptureResult {
    let stillImage: UIImage
    let videoURL: URL
}

enum CameraCaptureError: LocalizedError {
    case cameraUnavailable
    case noVideoURLReturned
    case frameExtractionFailed(underlying: Error)
    case dismissedWhileBackgrounded

    var errorDescription: String? {
        switch self {
        case .cameraUnavailable:         return "Camera unavailable. Try restarting WakeProof."
        case .dismissedWhileBackgrounded: return "Camera closed while app was backgrounded. Try again."
        case .frameExtractionFailed:     return "Couldn't read the captured video. Try again — good light, face visible."
        case .noVideoURLReturned:        return "Capture failed. Try again."
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
        DeviceCameraPicker(onCaptured: onCaptured,
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

// MARK: - Device camera (modal-presenting host)

#if !targetEnvironment(simulator)
private struct DeviceCameraPicker: UIViewControllerRepresentable {

    let onCaptured: (CameraCaptureResult) -> Void
    let onCancelled: () -> Void
    let onFailed: (CameraCaptureError) -> Void

    func makeUIViewController(context: Context) -> CameraHostController {
        let host = CameraHostController()
        host.onCaptured = onCaptured
        host.onCancelled = onCancelled
        host.onFailed = onFailed
        return host
    }

    func updateUIViewController(_ uiViewController: CameraHostController, context: Context) {
        // Callbacks captured at makeUIViewController; no per-update work.
    }
}

/// Plain UIViewController that hosts UIImagePickerController as a MODAL presentation.
/// Required because UIImagePickerController must be presented, not embedded — embedding
/// initializes the camera framework but never renders the picker UI.
///
/// Callbacks are non-optional with logger-fallback defaults. An unwired callback would
/// silently strand the alarm in `.capturing`; an explicit logger fallback at least leaves
/// a trail in Console.app.
@MainActor
private final class CameraHostController: UIViewController,
                                           UIImagePickerControllerDelegate,
                                           UINavigationControllerDelegate {

    var onCaptured: (CameraCaptureResult) -> Void = { _ in
        Logger(subsystem: LogSubsystem.verification, category: "cameraHost")
            .fault("onCaptured fired but no handler wired — alarm will hang in .capturing")
    }
    var onCancelled: () -> Void = {
        Logger(subsystem: LogSubsystem.verification, category: "cameraHost")
            .fault("onCancelled fired but no handler wired — alarm will hang in .capturing")
    }
    var onFailed: (CameraCaptureError) -> Void = { _ in
        Logger(subsystem: LogSubsystem.verification, category: "cameraHost")
            .fault("onFailed fired but no handler wired — alarm will hang in .capturing")
    }

    private let logger = Logger(subsystem: LogSubsystem.verification, category: "cameraHost")
    private var didPresentPicker = false
    private var hasReportedTerminalOutcome = false
    /// Set when the picker handed us a video and we kicked off frame extraction. While true,
    /// the foreground-return handler must NOT report `.dismissedWhileBackgrounded` — the
    /// picker is gone because it dismissed itself on success, not because the app died in
    /// the background. Without this flag, a foreground race could pre-empt the success path.
    private var processingCaptureResult = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        // Detect the case where iOS dismissed the picker while the app was backgrounded
        // (rare for full-screen modal but documented). Without this, the host VC remains on
        // screen with a black void and no callback fires — user must force-quit to escape.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleAppDidBecomeActive() {
        guard didPresentPicker,
              presentedViewController == nil,
              !hasReportedTerminalOutcome,
              !processingCaptureResult else { return }
        logger.warning("App returned to foreground but picker is gone — reporting dismissedWhileBackgrounded")
        reportTerminal { onFailed(.dismissedWhileBackgrounded) }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didPresentPicker else { return }
        didPresentPicker = true
        presentPicker()
    }

    private func presentPicker() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            logger.error("Camera source unavailable on this device — reporting failure")
            reportTerminal { onFailed(.cameraUnavailable) }
            return
        }
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        // mediaTypes MUST be set before cameraCaptureMode. UIImagePickerController validates
        // cameraCaptureMode against the currently-configured mediaTypes at assignment time —
        // setting .video while mediaTypes is still the default [public.image] throws.
        picker.mediaTypes = [UTType.movie.identifier]
        picker.cameraCaptureMode = .video
        // No hard max on iOS 26: the `videoMaximumDuration = 2.0` auto-cap path
        // triggers AVFoundation error -11810 ("The recording reached the maximum
        // allowable length") and recovery salvages only ~0.4 s of the intended
        // clip — the downstream duration-floor validator (≥1 s) then rejects it.
        // Letting the user manually tap stop avoids the auto-cap code path
        // entirely. The 2-sec design intent (Decision 2 in docs/technical-decisions.md)
        // is preserved by the validator's ≥1-s minimum and by user habit —
        // just not by the broken iOS hard cap.
        picker.videoQuality = .typeMedium
        // Prefer rear, but fall back to front if the device exposes only one camera (older
        // iPad models, hardware fault). Setting an unavailable device throws.
        if UIImagePickerController.isCameraDeviceAvailable(.rear) {
            picker.cameraDevice = .rear
        } else if UIImagePickerController.isCameraDeviceAvailable(.front) {
            picker.cameraDevice = .front
        } else {
            logger.error("Neither rear nor front camera available")
            reportTerminal { onFailed(.cameraUnavailable) }
            return
        }
        picker.delegate = self
        picker.modalPresentationStyle = .fullScreen
        logger.info("Presenting UIImagePickerController modally with cameraDevice=\(String(describing: picker.cameraDevice), privacy: .public)")
        present(picker, animated: true)
    }

    private func reportTerminal(_ block: () -> Void) {
        guard !hasReportedTerminalOutcome else { return }
        hasReportedTerminalOutcome = true
        block()
    }

    // MARK: - UIImagePickerControllerDelegate

    func imagePickerController(_ picker: UIImagePickerController,
                               didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        guard let videoURL = info[.mediaURL] as? URL else {
            logger.error("Picker finished with no mediaURL; cannot proceed")
            reportTerminal { onFailed(.noVideoURLReturned) }
            return
        }
        // Mark in-flight BEFORE the await so handleAppDidBecomeActive (which can fire any
        // time after picker.dismiss) doesn't pre-empt our success path with a false
        // "dismissedWhileBackgrounded".
        processingCaptureResult = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.processingCaptureResult = false }
            do {
                let still = try await Self.extractMiddleFrame(videoURL: videoURL)
                self.reportTerminal { self.onCaptured(CameraCaptureResult(stillImage: still, videoURL: videoURL)) }
            } catch {
                self.logger.error("Middle-frame extraction failed: \(error.localizedDescription, privacy: .public)")
                self.reportTerminal { self.onFailed(.frameExtractionFailed(underlying: error)) }
            }
        }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
        reportTerminal { onCancelled() }
    }

    /// Extract a frame at ~75% of the clip (never at t=0 for very-short videos — the early
    /// pre-roll can be black or out-of-focus, which would poison the Day 3 vision call).
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
#endif
