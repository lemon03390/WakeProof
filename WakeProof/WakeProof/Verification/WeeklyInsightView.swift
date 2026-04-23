//
//  WeeklyInsightView.swift
//  WakeProof
//
//  SwiftUI panel showing the weekly coach insight. Collapsible. Rendered in the
//  AlarmSchedulerView home screen.
//

import SwiftUI

struct WeeklyInsightView: View {
    let insight: WeeklyCoach.Insight?
    let generatedAt: Date?

    @State private var expanded: Bool = false

    /// Treats a present-but-empty `insightText` as "no insight" so we don't render
    /// a blank expanded panel when Claude's JSON had a whitespace-only string.
    private var displayableInsight: WeeklyCoach.Insight? {
        guard let insight,
              !insight.insightText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return insight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "sparkles")
                Text("This week's insight")
                    .font(.headline)
                Spacer()
                if displayableInsight != nil {
                    Button(action: { expanded.toggle() }) {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    }
                    .accessibilityLabel(expanded ? "Collapse insight" : "Expand insight")
                }
            }

            if let insight = displayableInsight {
                if expanded {
                    Text(insight.insightText)
                        .font(.body)
                        .foregroundStyle(.primary.opacity(0.9))
                    if let pattern = insight.patternNoticed {
                        Text("Pattern: \(pattern)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let suggestion = insight.suggestedAction {
                        Text("Try: \(suggestion)")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    if let generatedAt {
                        Text("Generated \(generatedAt.formatted(.relative(presentation: .named)))")
                            .font(.caption2)
                            .foregroundStyle(.secondary.opacity(0.7))
                    }
                    Text("Produced by Opus 4.7's 1M-context")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    Text(insight.insightText)
                        .font(.subheadline)
                        .lineLimit(2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No insight yet — run `scripts/generate-weekly-insight.py` after 14 days of seed data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

#Preview("Expanded") {
    WeeklyInsightView(
        insight: .init(
            insightText: "Your Mondays consistently take an extra verification attempt. Tuesdays through Sundays verify on the first try. Try shifting Sunday bedtime forward by 30 minutes.",
            patternNoticed: "Mondays retry-heavy",
            suggestedAction: "Earlier Sunday bedtime"
        ),
        generatedAt: .now.addingTimeInterval(-3600)
    )
    .padding()
}

#Preview("Missing") {
    WeeklyInsightView(insight: nil, generatedAt: nil)
        .padding()
}
