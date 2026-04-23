//
//  MorningBriefingView.swift
//  WakeProof
//
//  Shown right after the alarm VERIFIED transition. Displays the overnight
//  agent / synthesis-client briefing that was pre-computed during sleep.
//  Falls back to a "no briefing yet" card when the scheduler wasn't armed
//  or when the source hasn't produced content yet (first install).
//

import SwiftUI
import os

struct MorningBriefingView: View {

    let briefing: MorningBriefing?
    let onDismiss: () -> Void

    private static let logger = Logger(subsystem: "com.wakeproof.overnight", category: "briefing-view")

    /// True when there's something useful to show — briefing exists AND
    /// its text isn't empty/whitespace. The empty-text branch exists
    /// because parseAgentReply can return "" when the agent's reply
    /// contains the BRIEFING: marker but no content after it.
    private var hasContent: Bool {
        guard let briefing else { return false }
        return !briefing.briefingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 24) {
                Spacer()
                Text("Good morning")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(.white)
                Text(Date.now.formatted(date: .complete, time: .omitted))
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                if hasContent, let briefing {
                    Text(briefing.briefingText)
                        .font(.title3)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 28)
                } else {
                    VStack(spacing: 8) {
                        Text("No briefing this morning")
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.7))
                        Text("Sleep well tonight — Claude will prepare one.")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                Spacer()
                Button("Start your day", action: onDismiss)
                    .buttonStyle(.primaryWhite)
                    .padding(.bottom, 40)
            }
        }
        .onAppear {
            Self.logger.info("MorningBriefingView appeared hasContent=\(hasContent, privacy: .public) generatedAt=\(briefing?.generatedAt.ISO8601Format() ?? "nil", privacy: .public)")
        }
    }
}

#Preview("With briefing") {
    MorningBriefingView(
        briefing: MorningBriefing(
            forWakeDate: .now,
            briefingText: "You slept 7h 15m — steady HR overnight. Expect a smooth verification today. Hydrate early; you were lighter on water yesterday evening."
        ),
        onDismiss: {}
    )
}

#Preview("No briefing") {
    MorningBriefingView(briefing: nil, onDismiss: {})
}
