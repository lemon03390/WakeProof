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
        VStack(alignment: .leading, spacing: WPSpacing.sm) {
            HStack {
                Image(systemName: "sparkles")
                Text("This week's insight")
                    .wpFont(.headline)
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
                        .wpFont(.body)
                        .foregroundStyle(Color.wpChar900)
                    if let pattern = insight.patternNoticed {
                        Text("Pattern: \(pattern)")
                            .wpFont(.caption)
                            .foregroundStyle(Color.wpChar500)
                    }
                    if let suggestion = insight.suggestedAction {
                        Text("Try: \(suggestion)")
                            .wpFont(.callout)
                            .foregroundStyle(Color.wpChar500)
                    }
                    if let generatedAt {
                        Text("Generated \(generatedAt.formatted(.relative(presentation: .named)))")
                            .wpFont(.footnote)
                            .foregroundStyle(Color.wpChar500)
                    }
                    Text("Produced by Opus 4.7's 1M-context")
                        .wpFont(.footnote)
                        .foregroundStyle(Color.wpChar300)
                } else {
                    Text(insight.insightText)
                        .wpFont(.subhead)
                        .lineLimit(2)
                        .foregroundStyle(Color.wpChar500)
                }
            } else {
                Text("No insight yet — run `scripts/generate-weekly-insight.py` after 14 days of seed data.")
                    .wpFont(.body)
                    .italic()
                    .foregroundStyle(Color.wpChar500)
            }
        }
        .padding(WPSpacing.md)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: WPRadius.md))
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
