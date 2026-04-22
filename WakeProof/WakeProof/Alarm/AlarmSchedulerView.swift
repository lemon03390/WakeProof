//
//  AlarmSchedulerView.swift
//  WakeProof
//
//  The post-onboarding home screen: configure the wake window, toggle the alarm,
//  and (DEBUG) fire immediately for demo video capture.
//

import SwiftUI
import os

struct AlarmSchedulerView: View {

    @Environment(AlarmScheduler.self) private var scheduler
    @Environment(AudioSessionKeepalive.self) private var audioKeepalive
    @Environment(PermissionsManager.self) private var permissions

    @State private var startTime: Date = .now
    @State private var isEnabled: Bool = false

    private let logger = Logger(subsystem: "com.wakeproof.alarm", category: "schedulerView")

    var body: some View {
        NavigationStack {
            Form {
                if let banner = systemBanner {
                    Section {
                        Text(banner)
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }

                Section("Wake window") {
                    DatePicker("Start", selection: $startTime, displayedComponents: .hourAndMinute)
                    Toggle("Alarm enabled", isOn: $isEnabled)
                }

                Section {
                    Button("Save & schedule") { save() }
                }

                if let next = scheduler.nextFireAt {
                    Section("Next fire") {
                        Text(next.formatted(date: .abbreviated, time: .standard))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }

                #if DEBUG
                Section("DEBUG") {
                    Button("Fire alarm now") { scheduler.fireNow() }
                        .foregroundStyle(.red)
                }
                #endif
            }
            .navigationTitle("WakeProof")
            .onAppear(perform: loadFromScheduler)
        }
    }

    /// Composite "the alarm contract is partially broken" banner. Surfaces the highest-impact
    /// problem first so the user knows what to fix; without this, denied notifications and
    /// dead audio sessions silently pretended the alarm was armed. Optional permissions land
    /// at the bottom — they degrade features but don't break the wake-up contract.
    private var systemBanner: String? {
        if permissions.notifications == .denied {
            return "Notifications are off — WakeProof can't reliably wake you. Open Settings → WakeProof → Notifications."
        }
        if let audioError = audioKeepalive.lastError {
            return "Audio session problem: \(audioError) The alarm may not survive lock screen."
        }
        // Motion / HealthKit failures don't break the alarm but disable optional features
        // (natural-wake window, last-night summary). Surface so the user knows why those
        // features are silent. `.failed` (transient/hardware) is more actionable than `.denied`.
        if permissions.motion == .failed {
            return "Motion data unavailable — natural-wake timing is off."
        }
        if permissions.healthKit == .failed {
            return "Apple Health unavailable — last-night summary won't appear."
        }
        return nil
    }

    private func loadFromScheduler() {
        let w = scheduler.window
        startTime = WakeWindow.composeTime(hour: w.startHour, minute: w.startMinute)
        isEnabled = w.isEnabled
    }

    private func save() {
        let startComponents = Calendar.current.dateComponents([.hour, .minute], from: startTime)
        let hour: Int
        let minute: Int
        if let h = startComponents.hour, let m = startComponents.minute {
            hour = h
            minute = m
        } else {
            // Calendar.dateComponents on a Date should always produce hour/minute. If it ever
            // doesn't, fall back to defaults but loudly — silent defaulting saved a 22:00
            // alarm as 06:30 in an earlier draft of this code.
            logger.error("DateComponents fallback fired for startTime=\(startTime, privacy: .public) — defaulting to 06:30")
            hour = 6
            minute = 30
        }
        let w = WakeWindow(
            startHour: hour,
            startMinute: minute,
            // End-time UI is intentionally absent — the model field is preserved for a
            // future flexibility-window feature; the previously-saved value is carried
            // forward so the JSON-encoded UserDefaults blob stays decodable.
            endHour: scheduler.window.endHour,
            endMinute: scheduler.window.endMinute,
            isEnabled: isEnabled
        )
        scheduler.updateWindow(w)
    }

}
