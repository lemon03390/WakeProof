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
@MainActor
final class PermissionsManager {

    enum Status {
        case notRequested
        case granted
        case denied
        case undetermined // iOS said "not yet" or did not disclose; treat as retry-able
        case failed       // a non-user-driven failure (hardware, transient API error)
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
        // Apple's HKObjectType identifier lookups are documented to never return nil for
        // these constants, but force-unwrapping violates the project no-! rule and would
        // crash on any future renamed identifier.
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis),
              let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate),
              let restingHRType = HKObjectType.quantityType(forIdentifier: .restingHeartRate) else {
            logger.error("HealthKit type identifiers not resolvable on this OS — marking failed")
            healthKit = .failed
            return
        }
        let readTypes: Set<HKObjectType> = [sleepType, heartRateType, restingHRType]
        do {
            try await healthStore.requestAuthorization(toShare: [], read: readTypes)
            // HealthKit deliberately does not disclose read-only authorization status — for
            // reads, `authorizationStatus(for:)` always returns `.sharingDenied` regardless of
            // the user's actual choice. Treating that as `.denied` was a UX lie. Map to
            // `.undetermined` instead and rely on first-read success/failure to disambiguate.
            healthKit = .undetermined
            logger.info("HealthKit auth dialog completed; read status undisclosed by API")
        } catch {
            logger.error("HealthKit request failed: \(error.localizedDescription, privacy: .public)")
            healthKit = .failed
        }
    }

    func requestMotion() async {
        guard CMMotionActivityManager.isActivityAvailable() else {
            motion = .denied
            return
        }
        // CMMotionActivityManager has no explicit request API — a first query triggers the prompt.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            motionManager.queryActivityStarting(from: Date().addingTimeInterval(-60), to: Date(), to: .main) { [weak self] _, error in
                // queue: .main hands the callback to OperationQueue.main, which executes on
                // the main thread; bridge into MainActor isolation so observable state mutations
                // happen on the same actor that PermissionsManager itself is bound to.
                MainActor.assumeIsolated {
                    guard let self else {
                        continuation.resume()
                        return
                    }
                    if let error = error as NSError? {
                        if error.domain == CMErrorDomain,
                           error.code == Int(CMErrorMotionActivityNotAuthorized.rawValue) {
                            self.motion = .denied
                            self.logger.info("Motion: user denied authorization")
                        } else {
                            self.motion = .failed
                            self.logger.error("Motion query failed (non-auth): domain=\(error.domain, privacy: .public) code=\(error.code, privacy: .public) — \(error.localizedDescription, privacy: .public)")
                        }
                    } else {
                        self.motion = .granted
                        self.logger.info("Motion: granted")
                    }
                    continuation.resume()
                }
            }
        }
    }
}
