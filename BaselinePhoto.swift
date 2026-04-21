//
//  BaselinePhoto.swift
//  WakeProof
//
//  The reference photo captured at the user's awake-location during onboarding.
//  This image is sent to Opus 4.7 alongside every live wake-attempt photo for comparison.
//

import Foundation
import SwiftData

@Model
final class BaselinePhoto {
    /// JPEG-compressed image data stored directly in the model.
    /// Local-first: we never upload this to a server.
    var imageData: Data

    /// Free-text label the user picks ("kitchen", "bathroom sink", "desk").
    var locationLabel: String

    /// When captured.
    var capturedAt: Date

    /// Camera position used for capture — the wake-attempt camera must use the same.
    var cameraPosition: CameraPosition

    init(
        imageData: Data,
        locationLabel: String,
        capturedAt: Date = .now,
        cameraPosition: CameraPosition = .back
    ) {
        self.imageData = imageData
        self.locationLabel = locationLabel
        self.capturedAt = capturedAt
        self.cameraPosition = cameraPosition
    }
}

enum CameraPosition: String, Codable {
    case front
    case back
}
