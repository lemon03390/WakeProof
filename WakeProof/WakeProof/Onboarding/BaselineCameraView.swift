//
//  BaselineCameraView.swift
//  WakeProof
//
//  AVCaptureSession + AVCapturePhotoOutput-backed still capture for the
//  onboarding baseline. Replaces the prior `CameraPicker`
//  (UIImagePickerController) which letterboxed the preview on non-camera-
//  aspect screens — black bars top + bottom + a system toolbar strip.
//
//  Architecture mirrors the alarm-time `CameraRecorderViewController`
//  (in CameraCaptureView.swift) — same threading discipline, same
//  background-then-main hop pattern, same explicit configuration commit
//  before startRunning, same cancel-button + live preview chrome — but
//  uses `AVCapturePhotoOutput` for full-resolution stills (rather than
//  `AVCaptureMovieFileOutput` for video frames). Onboarding doesn't need
//  audio capture, doesn't compete with an active alarm audio session,
//  and doesn't need the auto-record-then-auto-stop UX — the user just
//  taps a shutter button when the framing is right.
//

import AVFoundation
import SwiftUI
import UIKit
import os

struct BaselineCameraView: UIViewControllerRepresentable {

    @Binding var image: UIImage?
    let onCameraUnavailable: () -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> BaselineCameraViewController {
        let vc = BaselineCameraViewController()
        vc.onCaptured = { captured in
            image = captured
            dismiss()
        }
        vc.onCancelled = { dismiss() }
        vc.onCameraUnavailable = {
            onCameraUnavailable()
            dismiss()
        }
        return vc
    }

    func updateUIViewController(_ uiViewController: BaselineCameraViewController, context: Context) {}
}

/// Still-photo capture VC. Front-facing wide-angle camera by default
/// (matches the alarm-time selfie format so Claude compares apples-to-
/// apples between baseline and morning verifications).
@MainActor
final class BaselineCameraViewController: UIViewController {

    var onCaptured: ((UIImage) -> Void)?
    var onCancelled: (() -> Void)?
    var onCameraUnavailable: (() -> Void)?

    private let logger = Logger(subsystem: LogSubsystem.onboarding, category: "baselineCamera")
    private let sessionQueue = DispatchQueue(label: "com.wakeproof.baseline-camera-session", qos: .userInitiated)

    private let captureSession = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var photoDelegate: PhotoDelegate?
    private var hasReportedTerminal = false

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .wpChar900
        installCancelButton()
        installShutterButton()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        sessionQueue.async { [weak self] in
            self?.configureAndStartSession()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let previewLayer, previewLayer.frame != view.bounds {
            previewLayer.frame = view.bounds
        }
    }

    deinit {
        // Mirror the CameraRecorderViewController teardown discipline:
        // SwiftUI may dismiss the sheet without going through cancel/success
        // (e.g. parent state change, drag-down). Stop the session so the
        // green camera-active dot in the status bar clears.
        let session = captureSession
        sessionQueue.async {
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    // MARK: - Session configuration (sessionQueue)

    private func configureAndStartSession() {
        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        guard cameraStatus == .authorized else {
            logger.error("Camera not authorized (status=\(cameraStatus.rawValue, privacy: .public))")
            DispatchQueue.main.async { [weak self] in
                self?.reportTerminal { self?.onCameraUnavailable?() }
            }
            return
        }

        captureSession.beginConfiguration()
        // Idempotent commit helper — every early-return below also commits
        // before bailing. Apple throws NSGenericException if startRunning
        // fires while configuration is still open (the same crash that hit
        // CameraRecorderViewController in 23dec2b → 0beef79).
        var didCommit = false
        func commit() {
            guard !didCommit else { return }
            didCommit = true
            captureSession.commitConfiguration()
        }

        // .photo preset gives the highest still-image resolution iOS
        // supports for the active camera. Worth the bytes — baseline is
        // captured ONCE and used as the visual reference for every future
        // verification, so resolution matters.
        captureSession.sessionPreset = .photo

        // Front camera default (selfie format, parity with the alarm
        // CameraCaptureView). Rear fallback only if the device has no
        // front camera (older iPad — every iPhone since iPhone X has both).
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            logger.error("No wide-angle camera available")
            commit()
            DispatchQueue.main.async { [weak self] in
                self?.reportTerminal { self?.onCameraUnavailable?() }
            }
            return
        }
        do {
            let videoInput = try AVCaptureDeviceInput(device: camera)
            guard captureSession.canAddInput(videoInput) else {
                logger.error("Cannot add video input")
                commit()
                DispatchQueue.main.async { [weak self] in
                    self?.reportTerminal { self?.onCameraUnavailable?() }
                }
                return
            }
            captureSession.addInput(videoInput)
        } catch {
            logger.error("Video input init failed: \(error.localizedDescription, privacy: .public)")
            commit()
            DispatchQueue.main.async { [weak self] in
                self?.reportTerminal { self?.onCameraUnavailable?() }
            }
            return
        }

        // Photo output (NOT movie file output — baseline is a still).
        guard captureSession.canAddOutput(photoOutput) else {
            logger.error("Cannot add photo output")
            commit()
            DispatchQueue.main.async { [weak self] in
                self?.reportTerminal { self?.onCameraUnavailable?() }
            }
            return
        }
        captureSession.addOutput(photoOutput)

        commit()  // BEFORE startRunning per Apple's API contract.
        captureSession.startRunning()
        DispatchQueue.main.async { [weak self] in
            self?.installPreviewLayer()
        }
    }

    private func installPreviewLayer() {
        let layer = AVCaptureVideoPreviewLayer(session: captureSession)
        // .resizeAspectFill fills the screen (no letterbox) — the user
        // composes their wake-location with the FULL preview area, which
        // was the whole point of replacing UIImagePickerController.
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.insertSublayer(layer, at: 0)
        previewLayer = layer
    }

    // MARK: - Chrome (cancel + shutter)

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

    private lazy var shutterButton: UIButton = {
        let button = UIButton(type: .custom)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.backgroundColor = .wpCream50
        button.layer.cornerRadius = 36
        button.layer.borderColor = UIColor.wpCream50.withAlphaComponent(0.5).cgColor
        button.layer.borderWidth = 4
        button.addTarget(self, action: #selector(handleShutterTap), for: .touchUpInside)
        return button
    }()

    private func installCancelButton() {
        view.addSubview(cancelButton)
        NSLayoutConstraint.activate([
            cancelButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            cancelButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16)
        ])
    }

    private func installShutterButton() {
        view.addSubview(shutterButton)
        NSLayoutConstraint.activate([
            shutterButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -32),
            shutterButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            shutterButton.widthAnchor.constraint(equalToConstant: 72),
            shutterButton.heightAnchor.constraint(equalToConstant: 72)
        ])
    }

    // MARK: - Capture flow

    @objc private func handleShutterTap() {
        // Brief tap feedback so the user sees the shutter respond before the
        // delegate fires. opacity 0.5 → 1.0 over 80ms — matches PrimaryButtonStyle.
        UIView.animate(withDuration: 0.08, animations: {
            self.shutterButton.alpha = 0.5
        }) { _ in
            UIView.animate(withDuration: 0.08) {
                self.shutterButton.alpha = 1.0
            }
        }
        let delegate = PhotoDelegate { [weak self] result in
            Task { @MainActor [weak self] in
                self?.handlePhoto(result: result)
            }
        }
        photoDelegate = delegate  // Strong ref — AVFoundation only holds weakly.
        let settings = AVCapturePhotoSettings()
        photoOutput.capturePhoto(with: settings, delegate: delegate)
    }

    @objc private func handleCancelTap() {
        tearDownSession()
        reportTerminal { onCancelled?() }
    }

    private func handlePhoto(result: Result<UIImage, Error>) {
        switch result {
        case .success(let image):
            tearDownSession()
            reportTerminal { onCaptured?(image) }
        case .failure(let error):
            logger.error("Photo capture failed: \(error.localizedDescription, privacy: .public)")
            // Don't tear down — leave the session running so the user can retry.
            // The cancel button is still available if they want to abort.
        }
    }

    private func tearDownSession() {
        sessionQueue.async { [captureSession] in
            if captureSession.isRunning {
                captureSession.stopRunning()
            }
        }
        photoDelegate = nil
    }

    private func reportTerminal(_ block: () -> Void) {
        guard !hasReportedTerminal else { return }
        hasReportedTerminal = true
        block()
    }
}

// MARK: - Photo delegate

/// AVCapturePhotoCaptureDelegate bridges AVFoundation's callback into a
/// single completion closure. Stored as a strong property on the VC because
/// AVFoundation only weakly retains photo delegates.
private final class PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate {

    private let completion: (Result<UIImage, Error>) -> Void
    private let logger = Logger(subsystem: LogSubsystem.onboarding, category: "baselinePhotoDelegate")

    init(completion: @escaping (Result<UIImage, Error>) -> Void) {
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        if let error {
            completion(.failure(error))
            return
        }
        guard let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else {
            logger.error("photo.fileDataRepresentation() returned nil OR UIImage init failed")
            // Surface a real Error so the caller's switch hits .failure rather
            // than silently no-op'ing. NSError with a descriptive domain.
            completion(.failure(NSError(
                domain: "com.wakeproof.baseline-camera",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Couldn't decode the captured photo."]
            )))
            return
        }
        completion(.success(image))
    }
}
