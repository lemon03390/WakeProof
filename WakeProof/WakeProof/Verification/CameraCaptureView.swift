//
//  CameraCaptureView.swift
//  WakeProof
//
//  Wake-time capture: a short (≤2 s) video plus a middle-frame still extracted
//  for the Opus 4.7 vision prompt on Day 3. For Day 2 we only persist both
//  outputs locally; no API call yet.
//
//  On simulator: falls through to a stub that injects a dummy result so
//  home-flow UI iteration doesn't dead-end at an unavailable camera. Device
//  path is unaffected.
//
//  Device path uses a CameraHostController (plain UIViewController) that, once
//  appeared, presents UIImagePickerController MODALLY. Embedding the picker
//  directly as a SwiftUI representable's wrapped VC violates Apple's rule
//  ("must present modally, must not install as subview") — when we tried that,
//  the camera framework initialized but the UI never rendered. The host VC
//  gives the picker a proper modal presentation parent.
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

enum CameraCaptureError: Error {
    case noVideoURLReturned
    case frameExtractionFailed(underlying: Error)
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
            Color.black.ignoresSafeArea()
            VStack(spacing: 24) {
                Image(systemName: "camera.metering.unknown")
                    .font(.system(size: 64))
                    .foregroundStyle(.white.opacity(0.7))
                Text("Simulator has no camera")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                Text("Verification is stubbed here. On a real device this is the 2-second video capture screen.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                VStack(spacing: 12) {
                    Button("Inject stub verification") { onProceed() }
                        .buttonStyle(.borderedProminent)
                    Button("Cancel", role: .cancel) { onCancel() }
                        .foregroundStyle(.white)
                }
                .padding(.top, 16)
            }
        }
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
@MainActor
private final class CameraHostController: UIViewController,
                                           UIImagePickerControllerDelegate,
                                           UINavigationControllerDelegate {

    var onCaptured: ((CameraCaptureResult) -> Void)?
    var onCancelled: (() -> Void)?
    var onFailed: ((CameraCaptureError) -> Void)?

    private let logger = Logger(subsystem: "com.wakeproof.verification", category: "cameraHost")
    private var didPresentPicker = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
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
            onFailed?(.noVideoURLReturned)
            return
        }
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        // mediaTypes MUST be set before cameraCaptureMode. UIImagePickerController validates
        // cameraCaptureMode against the currently-configured mediaTypes at assignment time —
        // setting .video while mediaTypes is still the default [public.image] throws.
        picker.mediaTypes = [UTType.movie.identifier]
        picker.cameraCaptureMode = .video
        picker.videoMaximumDuration = 2.0
        picker.videoQuality = .typeMedium
        picker.delegate = self
        picker.modalPresentationStyle = .fullScreen
        logger.info("Presenting UIImagePickerController modally")
        present(picker, animated: true)
    }

    // MARK: - UIImagePickerControllerDelegate

    func imagePickerController(_ picker: UIImagePickerController,
                               didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        guard let videoURL = info[.mediaURL] as? URL else {
            logger.error("Picker finished with no mediaURL; cannot proceed")
            onFailed?(.noVideoURLReturned)
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let still = try await Self.extractMiddleFrame(videoURL: videoURL)
                self.onCaptured?(CameraCaptureResult(stillImage: still, videoURL: videoURL))
            } catch {
                self.logger.error("Middle-frame extraction failed: \(error.localizedDescription, privacy: .public)")
                self.onFailed?(.frameExtractionFailed(underlying: error))
            }
        }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
        onCancelled?()
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
