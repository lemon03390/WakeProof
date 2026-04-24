//
//  ShareCardView.swift
//  WakeProof
//
//  Wave 5 H5 (§12.3-H5): the 1080x1920 portrait share card. Rendered offscreen
//  via SwiftUI's `ImageRenderer` and handed to `ShareLink` as an `Image` so
//  the user can push it to Photos / IG Story / WhatsApp without any Photos
//  permission prompt (sandbox sharing sheet handles it).
//
//  Layout rationale (§12.3-H5 "minimalist card"):
//   - Solid black background mirroring MorningBriefingView — the shared
//     artefact visually continues from the in-app morning surface.
//   - Large streak number is the hero. 300pt bold is deliberately oversized
//     so a user skimming a cluttered IG feed reads the number before
//     anything else.
//   - "day streak" caption at 60pt sits under the number.
//   - Observation (if present) sits mid-canvas, italic at 54pt, 2-line cap,
//     horizontally padded. Max 2 lines so a long Claude observation doesn't
//     overflow into the mark area; the 2-line truncation is acceptable
//     because the card is a teaser, not a transcript.
//   - "WakeProof" mark in the bottom-right at 36pt semibold, 0.5 opacity.
//     Low opacity so the mark reads as a watermark rather than an ad; the
//     user's streak number must dominate the visual weight.
//
//  Rendering contract:
//   - The view MUST be used with `ImageRenderer(content: ShareCardView(...))`
//     on the main actor. `ImageRenderer.uiImage` returns nil if invoked
//     off-main-actor on iOS 17 — the MorningBriefingView integration calls
//     it from within a SwiftUI body context, which is @MainActor.
//   - The view is sized explicitly to `ShareCardModel.canvasSize` via a
//     `.frame(width:height:)` modifier inside the view itself, so the
//     caller doesn't need to remember to pin the frame. `ImageRenderer`
//     renders at the view's intrinsic size, so the frame IS the canvas.
//

import SwiftUI

struct ShareCardView: View {
    /// The current streak count to render as the hero. Must be >= 1 per the
    /// gate in `ShareCardModel.shouldShowShareButton` — passing 0 renders a
    /// visually awkward "0" card, which the gate prevents upstream.
    let streak: Int

    /// Claude Opus 4.7's observation from this morning's verification (H1).
    /// Nil when Claude didn't emit one or when the attempt predates H1; the
    /// view hides the observation block entirely rather than showing an
    /// empty line — we don't want a "card with a missing row" shape.
    let observation: String?

    var body: some View {
        ZStack {
            // Solid-black background fills the full canvas. Using Color.black
            // rather than .background(Color.black) because ShareCardView is
            // the render root — there is no parent; the background IS this
            // rectangle.
            Color.black

            VStack(spacing: 0) {
                Spacer()

                // Hero: streak number. 300pt bold with ultra-tight line spacing
                // so the digit sits as a solid block rather than floating.
                Text("\(streak)")
                    .font(.system(size: 300, weight: .bold))
                    .foregroundStyle(.white)

                // Caption underneath. 60pt, 0.7 opacity so the eye lands on
                // the number first and the label reads as supporting text.
                Text(ShareCardModel.streakCaption)
                    .font(.system(size: 60))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.top, 8)

                // Gap between the caption and the observation. Sized by
                // Spacer ratio rather than fixed pt so the layout adapts if
                // the observation block is absent — Spacer's even
                // distribution puts the observation near vertical centre.
                Spacer()

                // Observation block (H1 Claude prose). Only renders when
                // non-nil and non-empty. Italic + 0.85 opacity so it reads
                // as a quote / secondary note rather than competing with
                // the hero number.
                if let observation, !observation.isEmpty {
                    Text(observation)
                        .font(.system(size: 54))
                        .italic()
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .padding(.horizontal, 80)
                }

                Spacer()
            }
            .padding(.horizontal, 80)

            // Bottom-right WakeProof mark. Low opacity (0.5) so it reads as
            // a watermark. Positioned with VStack/HStack Spacer + trailing
            // padding rather than overlay(alignment:) so the exact 60pt
            // margin is explicit in the layout code.
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Text(ShareCardModel.markLabel)
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .padding(.trailing, 60)
            .padding(.bottom, 60)
        }
        .frame(width: ShareCardModel.canvasWidth, height: ShareCardModel.canvasHeight)
    }
}

#Preview("Streak 7, with observation") {
    ShareCardView(
        streak: 7,
        observation: "window light 30 minutes earlier than last Tuesday"
    )
}

#Preview("Streak 1, no observation") {
    ShareCardView(streak: 1, observation: nil)
}

#Preview("Streak 99, long observation (truncates to 2 lines)") {
    ShareCardView(
        streak: 99,
        observation: "You've been consistent about the same kitchen baseline for seven weeks running — the light pattern Claude matches today is virtually identical to the morning of your first verify."
    )
}
