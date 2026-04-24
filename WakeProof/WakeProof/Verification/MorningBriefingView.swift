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

    /// Wave 5 H1 (§12.3-H1): Claude Opus 4.7's observation from this morning's
    /// verification. Nil when (a) the verify was REJECTED / RETRY (observation
    /// is only persisted on VERIFIED), (b) Claude emitted no observation on
    /// this call, or (c) we're on a pre-H1 attempt row. Hidden entirely when
    /// nil so the view doesn't grow a dead block — rendered below the main
    /// content under a "Claude noticed" label to deliver HOOK_S4_2 /
    /// HOOK_S7_5 variable-reward insight.
    let observation: String?

    /// Wave 5 H2 (§12.3-H2): the pre-sleep commitment note the user typed when
    /// they armed the alarm — "the first thing tomorrow-you needs to do". This
    /// is the user's own voice to themselves and takes visual prominence over
    /// Claude's observation (the note is BIG, 28pt semibold; the observation
    /// stays small-italic). Nil when the user left the field empty. Sourced
    /// from `scheduler.window.commitmentNote` via RootView's plumbing — the
    /// snapshot is passed in rather than read from the WakeAttempt row because
    /// the note lives with the current wake intent, not the per-fire record.
    let commitmentNote: String?
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
                // Wave 5 H2: the user's pre-sleep commitment note in LARGE type.
                // Sits between "Good morning"/date and the briefing content so
                // the user sees their own sentence first thing — before Claude's
                // prose, before any briefing failure branch. Only renders when
                // non-nil and non-empty (empty post-trim won't happen because
                // the save() path coerces whitespace-only to nil, but the check
                // is defensive for any future callers that forget). 28pt
                // semibold at 0.95 opacity is deliberately heavier than the
                // briefing text (title3 / 0.9 opacity) — this is "you told
                // yourself to do this", the briefing is context.
                if let commitmentNote, !commitmentNote.isEmpty {
                    Text(commitmentNote)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .padding(.top, 16)
                }
                Spacer()
                content
                // Wave 5 H1: optional observation block below the briefing content.
                // Hidden when nil (most paths — REJECTED/RETRY never sets it, and
                // Claude may omit it on a given VERIFIED). When present, labelled
                // "Claude noticed" with the observation itself in italic, dimmer
                // opacity so it reads as a secondary note rather than competing
                // with the briefing's headline prose.
                if let observation, !observation.isEmpty {
                    VStack(spacing: 8) {
                        Text("Claude noticed")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.65))
                        Text(observation)
                            .font(.footnote)
                            .italic()
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white.opacity(0.65))
                            .padding(.horizontal, 28)
                    }
                    .padding(.top, 16)
                }
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
    // P19 (Stage 6 Wave 2): BriefingDTO is now failable on empty text. The
    // preview passes a non-empty string so construction is guaranteed; we
    // use an `if let` unwrap to satisfy the compiler without reaching for
    // the banned force-unwrap. A nil here would indicate the preview string
    // was accidentally blanked — a visible broken preview is the right
    // diagnostic rather than a crash in SwiftUI's preview process.
    if let dto = BriefingDTO(
        briefingText: "You slept 7h 15m — steady HR overnight. Expect a smooth verification today. Hydrate early; you were lighter on water yesterday evening.",
        forWakeDate: .now,
        sourceSessionID: "sesn_preview",
        memoryUpdateApplied: false
    ) {
        MorningBriefingView(
            result: .success(dto),
            observation: "window light 30 minutes earlier than last Tuesday",
            commitmentNote: "Call Mom back",
            onDismiss: {}
        )
    } else {
        // Deliberately visible — if the preview text is ever emptied, the
        // missing view surfaces the typo rather than silently passing a nil
        // DTO into a `.success` case that construction invariant rejects.
        Text("Preview broken: BriefingDTO construction returned nil — check briefingText isn't empty")
    }
}

#Preview("No session") {
    MorningBriefingView(result: .noSession, observation: nil, commitmentNote: nil, onDismiss: {})
}

#Preview("Transport failure") {
    MorningBriefingView(
        result: .failure(reason: .fetchTransportFailed,
                         message: "Couldn't reach Claude tonight — your alarm still verified. Try tomorrow."),
        observation: nil,
        commitmentNote: nil,
        onDismiss: {}
    )
}

#Preview("Nil result (defensive)") {
    MorningBriefingView(result: nil, observation: nil, commitmentNote: nil, onDismiss: {})
}
