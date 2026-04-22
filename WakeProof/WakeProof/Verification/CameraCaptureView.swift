//
//  CameraCaptureView.swift
//  WakeProof
//
//  Wake-time capture: a short (≤2 s) video plus a middle-frame still extracted
//  for the Opus 4.7 vision prompt on Day 3. For Day 2 we only persist both
//  outputs locally; no API call yet.
//

import AVFoundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct CameraCaptureResult {
    let stillImage: UIImage
    let videoURL: URL
}

struct CameraCaptureView: UIViewControllerRepresentable {

    let onCaptured: (CameraCaptureResult) -> Void
    let onCancelled: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            picker.sourceType = .camera
            picker.cameraCaptureMode = .video
        } else {
            picker.sourceType = .photoLibrary
        }
        picker.mediaTypes = [UTType.movie.identifier]
        picker.videoMaximumDuration = 2.0
        picker.videoQuality = .typeMedium
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraCaptureView
        init(_ parent: CameraCaptureView) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            picker.dismiss(animated: true)
            guard let videoURL = info[.mediaURL] as? URL else {
                parent.onCancelled()
                return
            }
            Task { [weak self] in
                guard let self else { return }
                do {
                    let still = try await Self.extractMiddleFrame(videoURL: videoURL)
                    await MainActor.run {
                        self.parent.onCaptured(CameraCaptureResult(stillImage: still, videoURL: videoURL))
                    }
                } catch {
                    await MainActor.run { self.parent.onCancelled() }
                }
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
            parent.onCancelled()
        }

        private static func extractMiddleFrame(videoURL: URL) async throws -> UIImage {
            let asset = AVURLAsset(url: videoURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            let duration = try await asset.load(.duration)
            let midpoint = CMTime(seconds: duration.seconds / 2, preferredTimescale: duration.timescale)
            let cgImage = try await generator.image(at: midpoint).image
            return UIImage(cgImage: cgImage)
        }
    }
}
