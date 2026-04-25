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
    /// M5 (Wave 2.6): set when `BedtimeSettings.save` returns false, so the user
    /// sees an inline warning instead of advancing past a silent persistence failure.
    /// Cleared on each tap of Save & continue — a successful retry dismisses it.
    @State private var saveFailureMessage: String? = nil
    /// Set to true when save succeeds — shows the contract-active card for ~2s
    /// before handing off to the next onboarding step.
    @State private var contractConfirmed: Bool = false

    var body: some View {
        if contractConfirmed {
            contractConfirmationCard
        } else {
            bedtimePickerContent
        }
    }

    // MARK: - Bedtime picker

    private var bedtimePickerContent: some View {
        VStack(spacing: WPSpacing.xl) {
            Spacer()
            Text("When do you sleep?")
                .wpFont(.title1)
                .foregroundStyle(Color.wpCream50)
                .multilineTextAlignment(.center)
            Text("Claude will prepare your morning briefing overnight — analyzing sleep patterns and adjusting for what it has learned about your wake-ups. Skip if you'd rather not.")
                .wpFont(.body)
                .foregroundStyle(Color.wpCream50.opacity(0.75))
                .multilineTextAlignment(.center)
            Spacer()

            Toggle(isOn: $isEnabled) { Text("Turn on overnight briefings") }
                .foregroundStyle(Color.wpCream50)
                .tint(Color.wpCream50)

            if isEnabled {
                HStack {
                    Text("Bedtime")
                        .wpFont(.body)
                        .foregroundStyle(Color.wpCream50)
                    Spacer()
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
                    .labelsHidden()
                    .tint(Color.wpCream50)
                    // Phase 8 device-test fix: the compact DatePicker's time
                    // bubble draws its text via system .label color resolved
                    // against the system colorScheme — even when the parent
                    // forces .preferredColorScheme(.dark), the picker's internal
                    // host can resolve to .light, yielding dark text against
                    // a darker bubble (illegible on warm-charcoal). Forcing
                    // .environment(\.colorScheme, .dark) explicitly on the
                    // DatePicker subtree guarantees iOS resolves .label to
                    // its dark-mode value (white). Combined with .tint, the
                    // bubble text reads cream-white against system grey.
                    .environment(\.colorScheme, .dark)
                }
            }

            if let saveFailureMessage {
                Text(saveFailureMessage)
                    .wpFont(.footnote)
                    .foregroundStyle(Color.wpAttempted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            VStack(spacing: WPSpacing.sm) {
                Button("Save & continue") {
                    saveFailureMessage = nil
                    settings.isEnabled = isEnabled
                    // M5: act on the Bool. If save fails (encode error / defaults
                    // write rejected), surface an inline warning rather than
                    // letting the user proceed thinking bedtime was persisted.
                    if settings.save() {
                        contractConfirmed = true
                    } else {
                        saveFailureMessage = "Couldn't save bedtime — try once more."
                    }
                }
                .buttonStyle(.primaryWhite)

                Button("Skip — use default 23:00", action: onAdvance)
                    .foregroundStyle(Color.wpCream50.opacity(0.6))
            }
        }
    }

    // MARK: - Contract-active confirmation
    //
    // User-driven advance via the "Enter WakeProof" button — no auto-dismiss.
    // The plan calls for this button so the commitment-contract transition
    // is an explicit acknowledgement (matches iOS norms for confirmation
    // steps; auto-advance would also have required a `try? await Task.sleep`
    // pattern that violates the CLAUDE.md auto-promoted rule banning `try?`
    // — `Task.sleep` throws `CancellationError` on teardown, and `try?` would
    // silently advance even after the view was gone).

    private var contractConfirmationCard: some View {
        VStack(spacing: WPSpacing.xl) {
            Spacer()
            WPCard(padding: WPSpacing.xl) {
                VStack(spacing: WPSpacing.md) {
                    Text("Your contract is active — tomorrow at \(formattedBedtime), Claude will be waiting.")
                        .wpFont(.body)
                        .foregroundStyle(Color.wpCream50.opacity(0.75))
                        .multilineTextAlignment(.center)
                }
            }
            .environment(\.colorScheme, .dark)

            Button("Enter WakeProof", action: onAdvance)
                .buttonStyle(.primaryWhite)

            Spacer()
        }
    }

    /// Formats the saved bedtime hour/minute as a locale-appropriate time string.
    private var formattedBedtime: String {
        guard let date = Calendar.current.date(
            from: DateComponents(hour: settings.hour, minute: settings.minute)
        ) else {
            return "\(settings.hour):\(String(format: "%02d", settings.minute))"
        }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }
}
