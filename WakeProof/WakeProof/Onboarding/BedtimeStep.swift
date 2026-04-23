//
//  BedtimeStep.swift
//  WakeProof
//
//  New onboarding step (between .health and .baseline) that asks the user
//  when they plan to sleep. Skippable; the overnight-agent feature works
//  with the default 23:00 bedtime and can be revisited in Settings later.
//

import SwiftUI

struct BedtimeStep: View {
    let onAdvance: () -> Void

    @State private var settings: BedtimeSettings = BedtimeSettings.load()
    @State private var isEnabled: Bool = BedtimeSettings.load().isEnabled

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Text("When do you sleep?")
                .font(.system(size: 34, weight: .bold))
                .multilineTextAlignment(.center)
            Text("Claude will prepare your morning briefing overnight — analyzing sleep patterns and adjusting for what it has learned about your wake-ups. Skip if you'd rather not.")
                .font(.body)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
            Spacer()

            Toggle(isOn: $isEnabled) { Text("Turn on overnight briefings") }
                .foregroundStyle(.white)
                .tint(.white)

            if isEnabled {
                DatePicker(
                    "Bedtime",
                    selection: Binding<Date>(
                        get: {
                            Calendar.current.date(from: DateComponents(hour: settings.hour, minute: settings.minute)) ?? .now
                        },
                        set: { date in
                            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                            settings.hour = c.hour ?? 23
                            settings.minute = c.minute ?? 0
                        }
                    ),
                    displayedComponents: .hourAndMinute
                )
                .foregroundStyle(.white)
                .tint(.white)
            }

            VStack(spacing: 12) {
                Button("Save & continue") {
                    settings.isEnabled = isEnabled
                    settings.save()
                    onAdvance()
                }
                .buttonStyle(.primaryWhite)

                Button("Skip — use default 23:00", action: onAdvance)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }
}
