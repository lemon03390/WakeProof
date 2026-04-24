//
//  StreakBadgeView.swift
//  WakeProof
//
//  Wave 5 H3 (§12.3-H3): home-view streak badge. Extracted from
//  AlarmSchedulerView so the Form section logic stays lean and the rendering
//  rules below are reviewable in isolation.
//
//  Rendering decision table (ties to §12.3-H3 "surface the contract"):
//  - currentStreak > 0
//      → Large number + "N-day streak" + "Best: M days" subline.
//        Reinforces HOOK_S5_3 (progressive commitment) — the rising digit is
//        the visual cue.
//  - currentStreak == 0 AND bestStreak > 0
//      → "Streak reset — tomorrow's a fresh start." A user who had a streak
//        and broke it needs an acknowledgement (the break is felt, see
//        §12.3-H3 "Break handling") without a guilt spiral. This text is the
//        MINIMAL break-handling surface for Wave 5; the full re-capture-
//        baseline ritual is deferred post-hack per the item's scope
//        boundaries.
//  - currentStreak == 0 AND bestStreak == 0
//      → Hide the section entirely. A fresh install shouldn't see a "0-day
//        streak" placeholder — that feels like failure before the first
//        alarm has even rung.
//

import SwiftUI

struct StreakBadgeView: View {
    let currentStreak: Int
    let bestStreak: Int

    var body: some View {
        // The three render states are mutually exclusive. `@ViewBuilder` via
        // the computed var keeps the body flat; the caller (a Form Section)
        // only needs to check whether the section should render at all via
        // the static helper `shouldRender(...)` below.
        if currentStreak > 0 {
            activeBadge
        } else if bestStreak > 0 {
            resetMessage
        }
        // Empty state: render nothing. Intentional — the caller has already
        // checked `shouldRender(...)` in practice, but the View stays safe
        // if called directly with (0, 0) to avoid a subtle "rendered empty
        // Section with no content" SwiftUI glitch.
    }

    /// Section-visibility helper. Keep this in sync with the `if` ladder in
    /// `body` — the parent Form's `if StreakBadgeView.shouldRender(...)` wraps
    /// the Section so an empty (0, 0) state doesn't leave an empty Section
    /// with `Form`'s default row insets visible.
    static func shouldRender(currentStreak: Int, bestStreak: Int) -> Bool {
        currentStreak > 0 || bestStreak > 0
    }

    // MARK: - Branches

    @ViewBuilder
    private var activeBadge: some View {
        HStack(spacing: 16) {
            Text("\(currentStreak)")
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .accessibilityHidden(true)  // Combined below via accessibilityLabel
            VStack(alignment: .leading, spacing: 2) {
                Text(currentStreakLabel)
                    .font(.headline)
                if bestStreak > currentStreak {
                    // Only surface "Best: M days" when it's different from
                    // the current. If they're equal, "Best: 3 days" under
                    // "3-day streak" is redundant noise.
                    Text("Best: \(bestStreak) \(bestStreak == 1 ? "day" : "days")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var resetMessage: some View {
        // Single-line italic note. The "fresh start" framing deliberately
        // avoids "you failed" — HOOK_S7_6 (continuity feedback) is strongest
        // when the break is acknowledged but not shamed.
        Text("Streak reset — tomorrow's a fresh start.")
            .font(.subheadline)
            .italic()
            .foregroundStyle(.secondary)
    }

    // MARK: - Labels

    private var currentStreakLabel: String {
        currentStreak == 1 ? "1-day streak" : "\(currentStreak)-day streak"
    }

    private var accessibilityLabel: String {
        if bestStreak > currentStreak {
            return "\(currentStreakLabel). Best: \(bestStreak) \(bestStreak == 1 ? "day" : "days")."
        } else {
            return currentStreakLabel + "."
        }
    }
}
