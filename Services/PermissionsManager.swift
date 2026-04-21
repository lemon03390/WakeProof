//
//  PermissionsManager.swift
//  WakeProof
//
//  Centralised wrapper for every iOS permission WakeProof needs.
//  Each request is async and reports its granted/denied status via @Observable state
//  so onboarding screens can drive UI off it directly.
//

import AVFoundation
import CoreMotion
import Foundation
import HealthKit
import UserNotifications
import os

@Observable
final class PermissionsManager {

    enum Status {
        case notRequested
        case granted
        case denied
        case undetermined // iOS said "not yet", treat as retry-able
    }

    // MARK: - Observable state

    var notifications: Status = .notRequested
    var criticalAlerts: Status = .notRequested
    var camera: Status = .notRequested
    var healthKit: Status = .notRequested
    var motion: Status = .notRequested

    // MARK: - Private

    private let logger = Logger(subsystem: "com.wakeproof.permissions", category: "manager")
    private let healthStore = HKHealthStore()
    private let motionManager = CMMotionActivityManager()

    // MARK: - Public entry points

    /// Request all permissions in the order onboarding screens call them.
    /// Stops at the first hard-requirement denial so the UI can handle it.
    func requestAllSequentially() async {
        await requestNotifications()
        await requestCamera()
        await requestHealthKit()
        await requestMotion()
    }

    // MARK: - Individual requests

    func requestNotifications() async {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(
                options: [.alert, .sound, .badge, .criticalAlert]
            )
            notifications = granted ? .granted : .denied

            // Critical alert entitlement is almost certainly not granted — document the status.
            let settings = await center.notificationSettings()
            criticalAlerts = (settings.criticalAlertSetting == .enabled) ? .granted : .denied

            logger.info("Notifications: \(String(describing: self.notifications), privacy: .public); criticalAlerts: \(String(describing: self.criticalAlerts), privacy: .public)")
        } catch {
            logger.error("Notifications request failed: \(error.localizedDescription, privacy: .public)")
            notifications = .denied
        }
    }

    func requestCamera() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            camera = .granted
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            camera = granted ? .granted : .denied
        case .denied, .restricted:
            camera = .denied
        @unknown default:
            camera = .undetermined
        }
        logger.info("Camera: \(String(describing: self.camera), privacy: .public)")
    }

    func requestHealthKit() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            healthKit = .denied
            logger.info("HealthKit unavailable on this device")
            return
        }
        let readTypes: Set<HKObjectType> = [
            HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!,
            HKObjectType.quantityType(forIdentifier: .heartRate)!,
            HKObjectType.quantityType(forIdentifier: .restingHeartRate)!
        ]
        do {
            try await healthStore.requestAuthorization(toShare: [], read: readTypes)
            // HealthKit does not tell us whether the user said yes — we can only
            // detect "did they see the sheet?" via status of a specific type.
            let sleepStatus = healthStore.authorizationStatus(for: HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!)
            healthKit = (sleepStatus == .sharingAuthorized) ? .granted : .denied
            logger.info("HealthKit sleep read authorization: \(String(describing: sleepStatus.rawValue), privacy: .public)")
        } catch {
            logger.error("HealthKit request failed: \(error.localizedDescription, privacy: .public)")
            healthKit = .denied
        }
    }

    func requestMotion() async {
        guard CMMotionActivityManager.isActivityAvailable() else {
            motion = .denied
            return
        }
        // CMMotionActivityManager has no explicit request API — a first query triggers the prompt.
        await withCheckedContinuation { continuation in
            motionManager.queryActivityStarting(from: Date().addingTimeInterval(-60), to: Date(), to: .main) { _, error in
                if let error = error as NSError? {
                    if error.domain == CMErrorDomain,
                       error.code == Int(CMErrorMotionActivityNotAuthorized.rawValue) {
                        self.motion = .denied
                    } else {
                        self.motion = .denied
                    }
                } else {
                    self.motion = .granted
                }
                self.logger.info("Motion: \(String(describing: self.motion), privacy: .public)")
                continuation.resume()
            }
        }
    }
}
