//
//  BaselinePhotoView.swift
//  WakeProof
//
//  Final onboarding step: capture the reference photo at the user's chosen awake-location.
//  Day 1 deliverable — this view, the permission flow, and the audio keepalive are the
//  three things that must work end-to-end by end of Apr 22 HKT.
//

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
            // Rendered above the preview image ONLY before capture — once the
            // user has captured a photo they've already acted on the
            // instruction, so we hide the explainer and give the preview
            // image its full vertical real estate (the user needs to actually
            // see whether the photo is good enough to commit to).
            // On dark surface WPCard uses wpChar800 fill.
            if capturedImage == nil {
                WPCard(padding: WPSpacing.md) {
                    Text("Pick the spot in your home where you will physically be when you successfully wake up — kitchen counter, bathroom sink, your desk. Capture it now in the lighting you'll see it in tomorrow morning.")
                        .wpFont(.body)
                        .foregroundStyle(Color.wpCream50.opacity(0.75))
                        .multilineTextAlignment(.leading)
                }
                .environment(\.colorScheme, .dark)
            }

            if let capturedImage {
                // 480pt max (was 260pt — too small for the user to confidently
                // judge whether the framing / lighting is good enough to lock
                // in as the wake-location). The explainer above hides post-
                // capture so this larger preview fits comfortably on iPhone
                // SE through Pro Max.
                Image(uiImage: capturedImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 480)
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
        .fullScreenCover(isPresented: $showCamera) {
            // Phase 8 device-test fix: BaselineCameraView replaces the prior
            // UIImagePickerController-based CameraPicker. The picker
            // letterboxed the preview (top/bottom black bars + system
            // toolbar strip) on non-camera-aspect screens; AVCaptureSession
            // with .resizeAspectFill fills the screen edge-to-edge. Also
            // gives us framework parity with the alarm-time
            // CameraCaptureView (same selfie format, same chrome shape, same
            // session-config order).
            //
            // .fullScreenCover instead of .sheet so the camera takes over
            // the screen without a sheet drag-handle competing with the
            // shutter button at the bottom.
            BaselineCameraView(
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

    /// P-I8 (Wave 2.2, 2026-04-26): JPEG encoding moved off the main thread.
    /// `image.jpegData(compressionQuality: 0.8)` for an 18 MP TrueDepth still
    /// blocks 50–150 ms on iPhone 17 Pro — visible jank on the baseline-confirm
    /// tap. Detached task encodes off-main, then hands back to MainActor for
    /// the BaselinePhoto construction + onCaptured callback.
    private func handleSave() {
        guard let image = capturedImage else {
            errorMessage = "Capture a baseline photo before continuing."
            logger.warning("Save tapped with no captured image")
            return
        }
        let label = locationLabel.isEmpty ? "wake-location" : locationLabel
        Task {
            // Detach so the encode runs on a background QoS — UIImage is
            // thread-safe for read-only operations, and jpegData copies bytes
            // out, so no main-actor invariant is violated.
            let data: Data? = await Task.detached(priority: .userInitiated) {
                image.jpegData(compressionQuality: 0.8)
            }.value
            await MainActor.run {
                guard let data else {
                    errorMessage = "Couldn't encode the photo. Try retaking."
                    logger.error("JPEG encoding returned nil for baseline image")
                    return
                }
                let photo = BaselinePhoto(imageData: data, locationLabel: label)
                onCaptured(photo)
            }
        }
    }
}

// CameraPicker (UIImagePickerController-based) removed in Phase 8 in favour
// of BaselineCameraView (AVCaptureSession-based). See BaselineCameraView.swift.
