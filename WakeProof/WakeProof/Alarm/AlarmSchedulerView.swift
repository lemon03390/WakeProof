//
//  AlarmSchedulerView.swift
//  WakeProof
//
//  The post-onboarding home screen: configure the wake window, toggle the alarm,
//  and (DEBUG) fire immediately for demo video capture.
//

import SwiftUI

struct AlarmSchedulerView: View {

    @Environment(AlarmScheduler.self) private var scheduler

    @State private var startTime: Date = .now
    @State private var endTime: Date = .now
    @State private var isEnabled: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Wake window") {
                    DatePicker("Start", selection: $startTime, displayedComponents: .hourAndMinute)
                    DatePicker("End", selection: $endTime, displayedComponents: .hourAndMinute)
                    Toggle("Alarm enabled", isOn: $isEnabled)
                }

                Section {
                    Button("Save & schedule") { save() }
                        .disabled(endTime <= startTime)
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

    private func loadFromScheduler() {
        let w = scheduler.window
        startTime = composeTime(hour: w.startHour, minute: w.startMinute)
        endTime = composeTime(hour: w.endHour, minute: w.endMinute)
        isEnabled = w.isEnabled
    }

    private func save() {
        let startComponents = Calendar.current.dateComponents([.hour, .minute], from: startTime)
        let endComponents = Calendar.current.dateComponents([.hour, .minute], from: endTime)
        let w = WakeWindow(
            startHour: startComponents.hour ?? 6,
            startMinute: startComponents.minute ?? 30,
            endHour: endComponents.hour ?? 7,
            endMinute: endComponents.minute ?? 0,
            isEnabled: isEnabled
        )
        scheduler.updateWindow(w)
    }

    private func composeTime(hour: Int, minute: Int) -> Date {
        var c = Calendar.current.dateComponents([.year, .month, .day], from: .now)
        c.hour = hour; c.minute = minute
        return Calendar.current.date(from: c) ?? .now
    }
}
