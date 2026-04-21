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

struct BaselinePhotoView: View {

    let onCaptured: (BaselinePhoto) -> Void

    @State private var locationLabel: String = ""
    @State private var capturedImage: UIImage?
    @State private var showCamera: Bool = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Text("Your wake-location")
                .font(.system(size: 32, weight: .bold))
                .multilineTextAlignment(.center)

            Text("Pick the spot in your home where you will physically be when you successfully wake up — kitchen counter, bathroom sink, your desk. Capture it now in the lighting you'll see it in tomorrow morning.")
                .font(.body)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)

            if let capturedImage {
                Image(uiImage: capturedImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }

            TextField("Label this spot", text: $locationLabel)
                .textFieldStyle(.roundedBorder)
                .foregroundStyle(.black)

            Spacer()

            Button {
                showCamera = true
            } label: {
                Text(capturedImage == nil ? "Capture baseline" : "Retake")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.white)
                    .foregroundStyle(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            if capturedImage != nil {
                Button {
                    guard let image = capturedImage,
                          let data = image.jpegData(compressionQuality: 0.8) else { return }
                    let photo = BaselinePhoto(
                        imageData: data,
                        locationLabel: locationLabel.isEmpty ? "wake-location" : locationLabel
                    )
                    onCaptured(photo)
                } label: {
                    Text("Save & continue")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(locationLabel.isEmpty ? Color.white.opacity(0.4) : Color.green)
                        .foregroundStyle(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(locationLabel.isEmpty)
            }
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker(image: $capturedImage)
        }
    }
}

// MARK: - Minimal camera picker

struct CameraPicker: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.cameraDevice = .rear
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

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
