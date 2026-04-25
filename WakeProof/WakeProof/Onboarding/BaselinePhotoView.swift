//
//  BaselinePhotoView.swift
//  WakeProof
//
//  Final onboarding step: capture the reference photo at the user's chosen awake-location.
//  Day 1 deliverable — this view, the permission flow, and the audio keepalive are the
//  three things that must work end-to-end by end of Apr 22 HKT.
//

import AVFoundation
import SwiftUI
import os

struct BaselinePhotoView: View {

    let onCaptured: (BaselinePhoto) -> Void

    @State private var locationLabel: String = ""
    @State private var capturedImage: UIImage?
    @State private var showCamera: Bool = false
    @State private var errorMessage: String?

    private let logger = Logger(subsystem: LogSubsystem.onboarding, category: "baseline")

    var body: some View {
        VStack(spacing: WPSpacing.lg) {
            Spacer()

            Text("Your wake-location")
                .wpFont(.title1)
                .foregroundStyle(Color.wpCream50)
                .multilineTextAlignment(.center)

            // Explainer card: location ritual + lighting guidance.
            // Rendered above the preview image so the user reads the instruction
            // before capturing — on dark surface WPCard uses wpChar800 fill.
            WPCard(padding: WPSpacing.md) {
                Text("Pick the spot in your home where you will physically be when you successfully wake up — kitchen counter, bathroom sink, your desk. Capture it now in the lighting you'll see it in tomorrow morning.")
                    .wpFont(.body)
                    .foregroundStyle(Color.wpCream50.opacity(0.75))
                    .multilineTextAlignment(.leading)
            }
            .environment(\.colorScheme, .dark)

            if let capturedImage {
                Image(uiImage: capturedImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }

            if let errorMessage {
                Text(errorMessage)
                    .wpFont(.callout)
                    .foregroundStyle(Color.wpAttempted)
                    .multilineTextAlignment(.center)
            }

            TextField("Label this spot", text: $locationLabel)
                .textFieldStyle(.roundedBorder)
                // .roundedBorder TextField on iOS uses a system-themed white
                // field on a dark hero surface — char-900 text reads as the
                // input value. wpChar900 instead of pure black per design-
                // system non-negotiable #1.
                .foregroundStyle(Color.wpChar900)

            Spacer()

            Button {
                errorMessage = nil
                showCamera = true
            } label: {
                Text(capturedImage == nil ? "Capture baseline" : "Retake")
            }
            .buttonStyle(.primaryWhite)

            if capturedImage != nil {
                Button(action: handleSave) {
                    Text("Save & continue")
                }
                .buttonStyle(locationLabel.isEmpty ? .primaryMuted : .primaryConfirm)
                .disabled(locationLabel.isEmpty)
            }
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker(
                image: $capturedImage,
                onCameraUnavailable: {
                    showCamera = false
                    // The trust contract requires a live capture; falling back to the Photo
                    // Library would let the user pick a pre-existing photo of any location,
                    // collapsing the verification premise. Hard-fail with explanation.
                    errorMessage = "WakeProof needs a working camera to capture your wake-location. The trust contract relies on a live photo — Photos library imports aren't accepted."
                    logger.warning("Baseline capture aborted — camera unavailable on device")
                }
            )
        }
    }

    private func handleSave() {
        guard let image = capturedImage else {
            errorMessage = "Capture a baseline photo before continuing."
            logger.warning("Save tapped with no captured image")
            return
        }
        guard let data = image.jpegData(compressionQuality: 0.8) else {
            errorMessage = "Couldn't encode the photo. Try retaking."
            logger.error("JPEG encoding returned nil for baseline image")
            return
        }
        let photo = BaselinePhoto(
            imageData: data,
            locationLabel: locationLabel.isEmpty ? "wake-location" : locationLabel
        )
        onCaptured(photo)
    }
}

// MARK: - Minimal camera picker

struct CameraPicker: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    let onCameraUnavailable: () -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIViewController {
        // Camera availability must be checked before constructing UIImagePickerController:
        // setting sourceType=.camera on a device without a camera throws. We return a placeholder
        // VC and signal the parent so it can dismiss the sheet and show its error banner.
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            DispatchQueue.main.async { onCameraUnavailable() }
            return UIViewController()
        }
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        // Same rear-then-front fallback as CameraCaptureView.CameraHostController; setting
        // an unavailable cameraDevice throws.
        if UIImagePickerController.isCameraDeviceAvailable(.rear) {
            picker.cameraDevice = .rear
        } else if UIImagePickerController.isCameraDeviceAvailable(.front) {
            picker.cameraDevice = .front
        }
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker

        init(_ parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                parent.image = image
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
