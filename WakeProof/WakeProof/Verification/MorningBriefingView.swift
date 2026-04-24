//
//  MorningBriefingView.swift
//  WakeProof
//
//  Shown right after the alarm VERIFIED transition. Displays the overnight
//  agent / synthesis-client briefing that was pre-computed during sleep.
//
//  B5 refactor: the view now takes a `BriefingResult?` rather than a raw
//  `MorningBriefing?`. The three outcomes (success / noSession / failure)
//  render distinct copy so users / demo judges can distinguish "you never
//  armed bedtime" from "Claude hiccuped tonight" — previously both showed the
//  same "Sleep well tonight — Claude will prepare one" encouragement, which
//  made a network hiccup indistinguishable from a never-configured pipeline.
//

import SwiftUI
import os

struct MorningBriefingView: View {

    /// B5: the scheduler returns a `BriefingResult`; the result is latched in
    /// WakeProofApp's RootView and passed down here. Nil means the view hasn't
    /// received a finalize outcome yet (defensive — rarely visible because the
    /// cover isn't presented until the result is set).
    let result: BriefingResult?
    let onDismiss: () -> Void

    private static let logger = Logger(subsystem: LogSubsystem.overnight, category: "briefing-view")

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
                content
                #if DEBUG
                // Diagnostic surface for demo prep: the reason code lets you
                // tell at a glance whether the pipeline rendered real prose
                // or fell through to a failure branch. Hidden in release so
                // users never see "reason:" text.
                if let reasonTag {
                    Text(reasonTag)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.white.opacity(0.35))
                        .padding(.top, 4)
                }
                #endif
                Spacer()
                Button("Start your day", action: onDismiss)
                    .buttonStyle(.primaryWhite)
                    .padding(.bottom, 40)
            }
        }
        .onAppear {
            Self.logger.info("MorningBriefingView appeared resultTag=\(Self.tag(result), privacy: .public)")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch result {
        case .success(let dto):
            // Happy path: render the prose. `briefingText` is guaranteed
            // non-empty by B5.3's parseAgentReply validation.
            Text(dto.briefingText)
                .font(.title3)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 28)
        case .noSession, .none:
            // Fresh install / bedtime never armed. The encouragement copy is
            // intentional: we're telling the user how to get tomorrow's
            // briefing, not apologising for tonight's absence.
            VStack(spacing: 8) {
                Text("No briefing this morning")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))
                Text("Sleep well tonight — Claude will prepare one.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.5))
            }
        case .failure(_, let message):
            // Pipeline wired, something went wrong. `message` is copy from
            // `OvernightScheduler.classify(fetchError:)` which already speaks
            // in second-person to the user.
            VStack(spacing: 8) {
                Text("Briefing unavailable")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }
        }
    }

    #if DEBUG
    private var reasonTag: String? {
        switch result {
        case .success: return "reason: success"
        case .noSession: return "reason: noSession"
        case .failure(let reason, _): return "reason: failure.\(reason.rawValue)"
        case .none: return "reason: nil"
        }
    }
    #endif

    /// One-liner tag for logs; mirrors the DEBUG overlay but does NOT include
    /// the user-visible failure message (which may carry PII-adjacent content
    /// from the OvernightAgentError chain).
    private static func tag(_ result: BriefingResult?) -> String {
        switch result {
        case .success: return "success"
        case .noSession: return "noSession"
        case .failure(let reason, _): return "failure.\(reason.rawValue)"
        case .none: return "nil"
        }
    }
}

#Preview("Success") {
    MorningBriefingView(
        result: .success(BriefingDTO(
            briefingText: "You slept 7h 15m — steady HR overnight. Expect a smooth verification today. Hydrate early; you were lighter on water yesterday evening.",
            forWakeDate: .now,
            sourceSessionID: "sesn_preview",
            memoryUpdateApplied: false
        )),
        onDismiss: {}
    )
}

#Preview("No session") {
    MorningBriefingView(result: .noSession, onDismiss: {})
}

#Preview("Transport failure") {
    MorningBriefingView(
        result: .failure(reason: .fetchTransportFailed,
                         message: "Couldn't reach Claude tonight — your alarm still verified. Try tomorrow."),
        onDismiss: {}
    )
}

#Preview("Nil result (defensive)") {
    MorningBriefingView(result: nil, onDismiss: {})
}
