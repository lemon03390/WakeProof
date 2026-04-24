//
//  WPStreakBadge.swift
//  WakeProof
//
//  Evolved replacement for Alarm/StreakBadgeView. Preserves the public
//  `shouldRender(currentStreak:bestStreak:)` static API so call sites don't
//  branch during Phase 6 migration. Visual: wpVerified-filled capsule when
//  currentStreak > 0; wpChar500-outline capsule with "Streak reset" copy
//  when currentStreak == 0 and bestStreak > 0 (dormant). Phase 6 Task 6.5
//  deletes the old StreakBadgeView.swift once AlarmSchedulerView's call
//  sites migrate to this component.
//
//  shouldRender semantics mirror the shipped StreakBadgeView.shouldRender
//  exactly — both return `currentStreak > 0 || bestStreak > 0`. No
//  additional negative guard: negative inputs are caller-side invariant
//  violations that produce false naturally (N < 0 is never > 0). The
//  cross-check in ComponentSmokeTests enforces agreement across 7 cases.
//

import SwiftUI

struct WPStreakBadge: View {
    let currentStreak: Int
    let bestStreak: Int

    /// Section-visibility helper. Semantics are identical to the shipped
    /// `StreakBadgeView.shouldRender(currentStreak:bestStreak:)`.
    /// Returns false when both are zero (fresh install) or when both are
    /// negative (defensive: -1 > 0 is false, so result is false naturally).
    /// Returns true whenever the user has any streak history to show.
    static func shouldRender(currentStreak: Int, bestStreak: Int) -> Bool {
        currentStreak > 0 || bestStreak > 0
    }

    var body: some View {
        HStack(spacing: WPSpacing.sm) {
            if currentStreak > 0 {
                activeBadge
            } else {
                dormantBadge
            }
            if bestStreak > currentStreak {
                Text("Best: \(bestStreak) day\(bestStreak == 1 ? "" : "s")")
                    .wpFont(.footnote)
                    .foregroundStyle(Color.wpChar500)
            }
        }
    }

    private var activeBadge: some View {
        HStack(spacing: WPSpacing.xs1) {
            Text("\(currentStreak)")
                .wpFont(.title3)
                .monospacedDigit()
            Text("day\(currentStreak == 1 ? "" : "s")")
                .wpFont(.subhead)
        }
        .foregroundStyle(Color.wpCream50)
        .padding(.horizontal, WPSpacing.md)
        .padding(.vertical, WPSpacing.xs2)
        .background(Color.wpVerified)
        .clipShape(Capsule())
    }

    private var dormantBadge: some View {
        HStack(spacing: WPSpacing.xs1) {
            Text("Streak reset")
                .wpFont(.subhead)
        }
        .foregroundStyle(Color.wpChar500)
        .padding(.horizontal, WPSpacing.md)
        .padding(.vertical, WPSpacing.xs2)
        .overlay(Capsule().stroke(Color.wpChar500, lineWidth: 1))
    }
}

#Preview("Active streak") {
    WPStreakBadge(currentStreak: 4, bestStreak: 4)
        .padding()
        .background(Color.wpCream100)
}

#Preview("Active + best above") {
    WPStreakBadge(currentStreak: 2, bestStreak: 7)
        .padding()
        .background(Color.wpCream100)
}

#Preview("Dormant") {
    WPStreakBadge(currentStreak: 0, bestStreak: 5)
        .padding()
        .background(Color.wpCream100)
}
