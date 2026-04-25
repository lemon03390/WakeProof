//
//  WPMetricCard.swift
//  WakeProof
//
//  Large-numeral + small-label atom used by InvestmentDashboardView and
//  any future analytics surface. `accent: true` applies the wpPrimary
//  gradient fill to the numeral via `.foregroundStyle(LinearGradient.wpPrimary)`;
//  the gradient angle limitation noted in `Gradient+WakeProof.swift` applies
//  here too — on a square numeral the angle reads true 135°, on a wider
//  layout it skews. Visual sign-off in Phase 6 UAT.
//

import SwiftUI

struct WPMetricCard: View {
    let value: String
    let label: String
    let accent: Bool

    init(value: String, label: String, accent: Bool = false) {
        self.value = value
        self.label = label
        self.accent = accent
    }

    var body: some View {
        WPCard {
            VStack(alignment: .leading, spacing: WPSpacing.xs2) {
                valueView
                    .monospacedDigit()
                Text(label)
                    .wpFont(.subhead)
                    .foregroundStyle(Color.wpChar500)
            }
            // Combine into one VoiceOver focus stop so the announcement reads
            // as a cohesive metric ("12. Verified mornings.") rather than two
            // separate elements with a pause between numeral and label.
            // Replaces the prior accessibilityElement on InvestmentDashboardView's
            // hand-rolled metricRow which was lost in the WPMetricCard migration.
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(value). \(label)")
        }
    }

    @ViewBuilder
    private var valueView: some View {
        if accent {
            Text(value)
                .wpFont(.display)
                .foregroundStyle(LinearGradient.wpPrimary)
        } else {
            Text(value)
                .wpFont(.display)
                .foregroundStyle(Color.wpChar900)
        }
    }
}

#Preview {
    HStack(spacing: WPSpacing.md) {
        WPMetricCard(value: "12", label: "Verified mornings", accent: true)
        WPMetricCard(value: "3", label: "Insights collected")
    }
    .padding()
    .background(Color.wpCream100)
}
