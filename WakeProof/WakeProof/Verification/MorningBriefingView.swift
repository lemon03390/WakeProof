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

    /// Wave 5 H5 (§12.3-H5): the current streak count, piped in from
    /// `StreakService.currentStreak` via WakeProofApp's RootView. Used only
    /// to drive the opt-in Share button's visibility gate and the hero
    /// number on the rendered share card. Zero / negative values suppress
    /// the Share button entirely (see `ShareCardModel.shouldShowShareButton`).
    let currentStreak: Int

    let onDismiss: () -> Void

    /// Wave 5 H5: opt-in toggle read from UserDefaults via @AppStorage. Default
    /// `false` — per HOOK_S4_5, the Share button must NOT appear until the
    /// user explicitly enables it. The toggle lives in AlarmSchedulerView
    /// under a "Sharing" section, not inside this view — the briefing cover
    /// is a transient surface; settings belong in the long-lived scheduler
    /// form. Key uses the reverse-DNS style matching the bundle identifier
    /// so any future export/reset tooling can grep WakeProof keys cleanly.
    @AppStorage(ShareCardModel.shareCardEnabledKey) private var shareCardEnabled: Bool = false

    /// Stage 8 IMPORTANT 3 fix: surface ShareLink render failure in the DEBUG
    /// diagnostic reason-tag so demo-prep logs aren't ambiguous between "user
    /// opted out / streak < 1 / non-success morning" and "ImageRenderer returned
    /// nil". Set inside `makeShareImage()` when it returns nil; read by
    /// `reasonTag`. Single-shot latch — once failed this morning, we want the
    /// reason to stay visible until the briefing cover dismisses.
    @State private var shareCardFailed: Bool = false

    /// P-I5 (Wave 2.2, 2026-04-26): cache the rendered share image so it isn't
    /// re-rasterised on every body re-evaluation during the sunrise reveal
    /// animation. `ImageRenderer.uiImage` for a 1080x1920 PNG costs 30–60 ms on
    /// iPhone 12-class hardware; the briefing cover's `revealOpacity`
    /// transitions from 0→1 over 1.2 s easeOut, triggering many re-renders that
    /// would each pay that cost. We render once on .onAppear (after streak +
    /// observation are known) and reference the cached value in body.
    @State private var cachedShareImage: Image?

    /// Task 4.1: drives the sunrise gradient opacity on VERIFIED — starts at 0
    /// and animates to 1 over 1200ms easeOut on .onAppear, creating a warm
    /// background reveal rather than a jarring hard-cut to the gradient.
    @State private var revealOpacity: Double = 0

    /// Task 4.2: commitment-note spring-in. Starts offset 24pt below natural
    /// position and fully transparent; animates to zero offset and full opacity
    /// with a spring (response 0.5s, damping 0.7) delayed 400ms after .onAppear
    /// so the sunrise has established before the note rises into frame.
    @State private var commitmentNoteOffset: CGFloat = 24
    @State private var commitmentNoteOpacity: Double = 0

    /// Task 4.3: observation block ceremony fade-in. Starts fully transparent
    /// and fades to 1 over 600ms easeOut delayed 900ms after .onAppear — the
    /// tail of the animation sequence, after sunrise (1.2s total) and commitment
    /// note (400ms spring, lands ~900ms) have both resolved.
    @State private var observationOpacity: Double = 0

    /// Task 4.4: haptic feedback trigger for the "Start your day" dismiss action.
    /// Toggled on button tap before calling onDismiss() so .sensoryFeedback fires
    /// the success pulse at the moment the user commits — the haptic confirms
    /// the contract is fulfilled. Bool toggle is the canonical trigger pattern
    /// for .sensoryFeedback because the value change is what drives the feedback,
    /// not the value itself.
    @State private var dismissedTrigger: Bool = false

    private static let logger = Logger(subsystem: LogSubsystem.overnight, category: "briefing-view")

    var body: some View {
        ZStack {
            // Task 4.1: VERIFIED gets the sunrise gradient (opacity-animated in
            // from .onAppear); all other cases use wpChar900 — warm charcoal,
            // never pure black per design-system non-negotiable #1.
            if case .success = result {
                // The withAnimation(.easeOut(duration: 1.2)) call in .onAppear
                // owns the transition curve; no implicit .animation modifier
                // here, otherwise a future revealOpacity reset (e.g. on
                // re-presentation) would dual-drive against withAnimation's
                // explicit transaction.
                LinearGradient.wpSunrise
                    .ignoresSafeArea()
                    .opacity(revealOpacity)
            } else {
                Color.wpChar900.ignoresSafeArea()
            }
            VStack(spacing: WPSpacing.xl) {
                Spacer()
                Text("Good morning")
                    .wpFont(.display)
                    .foregroundStyle(Color.wpCream50)
                Text(Date.now.formatted(date: .complete, time: .omitted))
                    .wpFont(.title3)
                    .foregroundStyle(Color.wpCream50.opacity(0.7))
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
                        .wpFont(.title2)
                        .foregroundStyle(Color.wpCream50.opacity(0.95))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, WPSpacing.xl)
                        .padding(.top, WPSpacing.md)
                        .offset(y: commitmentNoteOffset)
                        .opacity(commitmentNoteOpacity)
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
                    VStack(spacing: WPSpacing.xs2) {
                        Text("Claude noticed")
                            .wpFont(.caption)
                            .foregroundStyle(Color.wpCream50.opacity(0.65))
                        Text(observation)
                            .wpFont(.footnote)
                            .italic()
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Color.wpCream50.opacity(0.65))
                            // .lineLimit(nil) + .fixedSize together guarantee
                            // unlimited vertical growth for CJK / EN observation
                            // strings (30-60 chars per H1 prompt). Either alone
                            // can silently truncate on iPhone SE.
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, WPSpacing.xl4)
                    }
                    .padding(.top, WPSpacing.md)
                    .opacity(observationOpacity)
                }
                #if DEBUG
                // Diagnostic surface for demo prep: the reason code lets you
                // tell at a glance whether the pipeline rendered real prose
                // or fell through to a failure branch. Hidden in release so
                // users never see "reason:" text. caption2.monospaced() is
                // intentional: monospaced diagnostic — no WPFont equivalent.
                if let reasonTag {
                    Text(reasonTag)
                        .font(.caption2.monospaced())
                        .foregroundStyle(Color.wpCream50.opacity(0.35))
                        .padding(.top, WPSpacing.xs1)
                }
                #endif
                Spacer()
                Button("Start your day") {
                    dismissedTrigger.toggle()
                    onDismiss()
                }
                .buttonStyle(.primaryWhite)
                .padding(.bottom, WPSpacing.xs2)
                .sensoryFeedback(.success, trigger: dismissedTrigger)

                // Wave 5 H5: opt-in Share button. Gated by three AND-ed
                // conditions via `ShareCardModel.shouldShowShareButton`:
                //   1. User enabled sharing (default off — HOOK_S4_5).
                //   2. Current streak >= 1 (zero-streak cards are awkward).
                //   3. Verification this morning was a success — the briefing
                //      card is a celebration surface; sharing a non-success
                //      morning would feel off-tone.
                // The ShareLink takes the rendered `Image` directly — no
                // Photos permission needed, the system sandbox share sheet
                // handles destination selection. Renderer runs on-demand per
                // tap via `makeShareImage()`; it's not expensive enough to
                // warrant caching, and a stale cache would be worse than a
                // 50ms re-render on tap.
                // P-I5 (Wave 2.2): use cached share image populated in .onAppear
                // rather than calling makeShareImage() each body re-eval. The
                // cache is populated only when all share gates pass, so the
                // `let shareImage = cachedShareImage` unwrap is the gate.
                if ShareCardModel.shouldShowShareButton(
                    enabled: shareCardEnabled,
                    streak: currentStreak,
                    observation: observation
                ),
                   case .success = result,
                   let shareImage = cachedShareImage
                {
                    ShareLink(
                        item: shareImage,
                        preview: SharePreview(
                            "WakeProof streak",
                            image: shareImage
                        )
                    ) {
                        Text(ShareCardModel.shareButtonCopy)
                            .wpFont(.callout)
                            .foregroundStyle(Color.wpCream50.opacity(0.55))
                            .underline()
                    }
                    .padding(.bottom, WPSpacing.xl3)
                } else {
                    // Explicit placeholder spacer so the "Start your day"
                    // button lifts off the bottom edge when the Share row is
                    // absent. Using WPSpacing.xl2 (32pt) so the layout offset
                    // matches the ShareLink presence (simpler to eyeball in
                    // the preview grid).
                    Color.clear.frame(height: WPSpacing.xl2)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            Self.logger.info("MorningBriefingView appeared resultTag=\(Self.tag(result), privacy: .public)")
            // P-I5 (Wave 2.2): cache the share image once so the body
            // re-renders during the sunrise reveal don't trigger fresh raster
            // work. Only render if the gate currently passes — re-evaluation
            // when streak / observation change is rare (post-onAppear data is
            // stable for the lifetime of the cover).
            if cachedShareImage == nil,
               case .success = result,
               ShareCardModel.shouldShowShareButton(
                enabled: shareCardEnabled,
                streak: currentStreak,
                observation: observation
               )
            {
                cachedShareImage = makeShareImage()
            }
            // Task 4.1: trigger the sunrise reveal on VERIFIED. Non-success
            // paths have a solid wpChar900 background so the opacity change
            // is a no-op for them — the `if case .success` branch never
            // renders on those paths, so revealOpacity assignment is harmless.
            withAnimation(.easeOut(duration: 1.2)) {
                revealOpacity = 1
            }
            // Task 4.2: commitment-note springs in 400ms after appear — sunrise
            // establishes warmth first (1.2s total), note rises into it at 400ms
            // and lands at ~900ms (spring response 0.5s + 400ms delay).
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7).delay(0.4)) {
                commitmentNoteOffset = 0
                commitmentNoteOpacity = 1
            }
            // Task 4.3: observation fades in at 900ms — after sunrise (1.2s) and
            // commitment note (lands ~900ms) have resolved, the observation
            // ceremony completes the sequence at 1.5s+ total.
            withAnimation(.easeOut(duration: 0.6).delay(0.9)) {
                observationOpacity = 1
            }
        }
    }

    /// Wave 5 H5: render the share card offscreen into a SwiftUI `Image` so
    /// `ShareLink` can hand it to the system share sheet. Uses the
    /// `ImageRenderer.uiImage` path (returns `UIImage?`) then rewraps the
    /// result as a SwiftUI `Image` — this yields a raster image that encodes
    /// to PNG on share, which is what IG Story / WhatsApp ingest cleanly.
    ///
    /// Returns nil when:
    ///  - `ImageRenderer.uiImage` returned nil (iOS 17 occasional quirk when
    ///    the underlying render context fails). In that case the caller's
    ///    `guard let` hides the ShareLink rather than presenting a broken
    ///    button — consistent with the "no placeholder, just hide" rule in
    ///    the scope doc.
    ///
    /// Stage 8 IMPORTANT 3 fix: render failure is now an observability
    /// signal that warrants attention. Logged at `.fault` (previously
    /// `.error`) so demo-prep logs surface it prominently, and the
    /// `shareCardFailed` flag is flipped (via a deferred Task to avoid
    /// mutating `@State` mid-body-evaluation) so the DEBUG reason-tag can
    /// disambiguate this from "user opted out" / "streak < 1" / "non-success
    /// morning" branches.
    @MainActor
    private func makeShareImage() -> Image? {
        let card = ShareCardView(streak: currentStreak, observation: observation)
        let renderer = ImageRenderer(content: card)
        // scale=1 because the canvas is already at native (1080x1920) pixel
        // resolution. Setting scale=2 would produce a 2160x3840 image which
        // IG Story would downscale anyway — wasted bytes on the share hop.
        renderer.scale = 1
        guard let uiImage = renderer.uiImage else {
            Self.logger.fault("ShareCard render: ImageRenderer.uiImage returned nil — Share button hidden")
            // Defer the @State write to after body evaluation so SwiftUI
            // doesn't issue a "modifying state during view update" warning.
            // MainActor hop is already on the main actor, so the Task
            // resolves on the next runloop turn.
            Task { @MainActor in
                shareCardFailed = true
            }
            return nil
        }
        return Image(uiImage: uiImage)
    }

    @ViewBuilder
    private var content: some View {
        switch result {
        case .success(let dto):
            // Happy path: render the prose. `briefingText` is guaranteed
            // non-empty by B5.3's parseAgentReply validation.
            Text(dto.briefingText)
                .wpFont(.title3)
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.wpCream50.opacity(0.9))
                .padding(.horizontal, 28)
        case .noSession, .none:
            // Fresh install / bedtime never armed. The encouragement copy is
            // intentional: we're telling the user how to get tomorrow's
            // briefing, not apologising for tonight's absence.
            VStack(spacing: 8) {
                Text("No briefing this morning")
                    .wpFont(.title3)
                    .foregroundStyle(Color.wpCream50.opacity(0.7))
                Text("Sleep well tonight — Claude will prepare one.")
                    .wpFont(.callout)
                    .foregroundStyle(Color.wpCream50.opacity(0.5))
            }
        case .failure(_, let message):
            // Pipeline wired, something went wrong. `message` is copy from
            // `OvernightScheduler.classify(fetchError:)` which already speaks
            // in second-person to the user.
            VStack(spacing: 8) {
                Text("Briefing unavailable")
                    .wpFont(.title3)
                    .foregroundStyle(Color.wpCream50.opacity(0.7))
                Text(message)
                    .wpFont(.callout)
                    .foregroundStyle(Color.wpCream50.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }
        }
    }

    #if DEBUG
    private var reasonTag: String? {
        // Stage 8 IMPORTANT 3 fix: append the share-card render failure suffix
        // when ImageRenderer came back nil this morning. Demo-prep logs can now
        // tell at a glance whether the Share button's absence is "user opted
        // out / streak < 1 / non-success" vs "render broke" — previously the
        // two cases collapsed into the same silent hide.
        let base: String
        switch result {
        case .success: base = "reason: success"
        case .noSession: base = "reason: noSession"
        case .failure(let reason, _): base = "reason: failure.\(reason.rawValue)"
        case .none: base = "reason: nil"
        }
        return shareCardFailed ? "\(base) | shareCardRenderFailed" : base
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
            currentStreak: 7,
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
    MorningBriefingView(
        result: .noSession,
        observation: nil,
        commitmentNote: nil,
        currentStreak: 0,
        onDismiss: {}
    )
}

#Preview("Transport failure") {
    MorningBriefingView(
        result: .failure(reason: .fetchTransportFailed,
                         message: "Couldn't reach Claude tonight — your alarm still verified. Try tomorrow."),
        observation: nil,
        commitmentNote: nil,
        currentStreak: 3,
        onDismiss: {}
    )
}

#Preview("Nil result (defensive)") {
    MorningBriefingView(
        result: nil,
        observation: nil,
        commitmentNote: nil,
        currentStreak: 0,
        onDismiss: {}
    )
}
