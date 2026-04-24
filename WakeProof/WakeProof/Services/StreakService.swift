//
//  StreakService.swift
//  WakeProof
//
//  Wave 5 H3 (§12.3-H3): derives the "current + best streak" loss-aversion
//  layer from the existing `WakeAttempt` history. No new @Model, no new
//  persistence payload — the service is a pure function of its input
//  `[WakeAttempt]` snapshot so drift from the authoritative audit trail is
//  architecturally impossible.
//
//  Source signals (§12.3-H3 ties):
//  - HOOK_S5_3 (progressive commitment): watching a number rise is a micro
//    investment reinforcing the contract.
//  - HOOK_S7_6 (continuity visual feedback): a visible calendar trail makes
//    a "break" concrete rather than abstract.
//
//  Day-boundary decision (locked, do NOT re-litigate):
//  - A day counts as VERIFIED if ANY WakeAttempt on that day has
//    `verdictEnum == .verified`. Multiple attempts (one REJECTED + one
//    VERIFIED) collapse to "verified" — the user did get up eventually.
//  - A day with ONLY non-verified attempts (REJECTED / RETRY / TIMEOUT /
//    UNRESOLVED / CAPTURED) is a break.
//  - A day with NO WakeAttempt rows at all is ALSO a break. A user who
//    didn't arm the alarm didn't uphold the contract. This is the
//    deliberately strict reading of "streak" — consistent with the spec's
//    §12.3-H3 framing.
//  - The calendar day is `Calendar.current.startOfDay(for: capturedAt ??
//    scheduledAt)`. We prefer capturedAt when present because it reflects
//    when the user actually verified; scheduledAt is the fallback for
//    TIMEOUT / UNRESOLVED rows that never produced a capture.
//
//  "Current streak" semantics:
//  - Walks backward from today if today is verified, else from yesterday.
//  - Why: today's alarm may not have fired yet. Requiring today to count
//    would collapse every user's streak to 0 for most of the morning.
//  - Stops at the first missing day. Returns the integer count.
//
//  "Best streak" semantics:
//  - Longest run of consecutive verified days anywhere in history.
//  - Do NOT persist this value (e.g. in UserDefaults). If the user
//    clears history (future feature) the value should honestly fall to 0 —
//    the contract is "what the audit trail says, not what we claim
//    happened" — same principle as §7.5 on memory integrity.
//

import Foundation
import Observation
import os

@Observable
@MainActor
final class StreakService {

    private(set) var currentStreak: Int = 0
    private(set) var bestStreak: Int = 0

    private let logger = Logger(subsystem: LogSubsystem.alarm, category: "streak")

    /// Re-derive current + best streak from an array of WakeAttempt snapshots.
    ///
    /// Intended call sites:
    /// 1. App bootstrap (`WakeProofApp.bootstrapIfNeeded`) with attempts
    ///    fetched from the main context.
    /// 2. After the `(.verifying → .idle)` VERIFIED transition, so the home
    ///    view's badge reflects the just-completed verify.
    ///
    /// Pure function of `attempts`, `now`, and `calendar` — deterministic and
    /// testable without stubbing `Date.now`. The `@Observable` property write
    /// happens as a single batched update at the end (both properties in one
    /// statement) so SwiftUI sees a consistent observed pair rather than
    /// `currentStreak=5, bestStreak=0` flickering to `currentStreak=5,
    /// bestStreak=7`.
    func recompute(
        from attempts: [WakeAttempt],
        now: Date = .now,
        calendar: Calendar = .current
    ) {
        // (1) Distill the attempts into the set of calendar days that count as
        // verified. Using a Set keeps membership O(1); `startOfDay` normalizes
        // all times on a given day to a single canonical Date regardless of
        // capturedAt vs. scheduledAt or minor clock drift.
        var verifiedDays = Set<Date>()
        for attempt in attempts where attempt.verdictEnum == .verified {
            let timestamp = attempt.capturedAt ?? attempt.scheduledAt
            verifiedDays.insert(calendar.startOfDay(for: timestamp))
        }

        // (2) Current streak: walk backward from today-or-yesterday.
        let computedCurrent = Self.computeCurrentStreak(
            verifiedDays: verifiedDays,
            now: now,
            calendar: calendar
        )

        // (3) Best streak: sort verified days ascending, then scan with a
        // running counter that resets on any gap > 1 day.
        let computedBest = Self.computeBestStreak(
            verifiedDays: verifiedDays,
            calendar: calendar
        )

        // Single write so observers see a consistent pair.
        self.currentStreak = computedCurrent
        self.bestStreak = computedBest

        logger.debug("recompute attempts=\(attempts.count, privacy: .public) verifiedDays=\(verifiedDays.count, privacy: .public) current=\(computedCurrent, privacy: .public) best=\(computedBest, privacy: .public)")
    }

    // MARK: - Pure helpers (static so tests can cover the algorithm directly)

    /// Current streak = consecutive verified days ending today-or-yesterday.
    /// If today is in the verified set → count today and walk backward.
    /// Else → walk backward starting from yesterday (today's alarm may just
    /// not have fired yet). Stop on the first day NOT in the set.
    static func computeCurrentStreak(
        verifiedDays: Set<Date>,
        now: Date,
        calendar: Calendar
    ) -> Int {
        let today = calendar.startOfDay(for: now)
        // Starting anchor: if today counts, start there; else rewind to
        // yesterday. If the `date(byAdding:.day,value:-1,to:today)` call
        // returns nil (shouldn't happen for a well-formed calendar), return 0
        // rather than force-unwrap — per CLAUDE.md's no-force-unwrap rule.
        var cursor: Date
        if verifiedDays.contains(today) {
            cursor = today
        } else {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else {
                return 0
            }
            cursor = yesterday
        }

        var count = 0
        while verifiedDays.contains(cursor) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else {
                break
            }
            cursor = previous
        }
        return count
    }

    /// Best streak = longest consecutive run anywhere in history.
    /// Sort the verified days ascending, walk forward, and reset a running
    /// counter on any gap > 1 day. Returns 0 for empty input.
    static func computeBestStreak(
        verifiedDays: Set<Date>,
        calendar: Calendar
    ) -> Int {
        guard !verifiedDays.isEmpty else { return 0 }

        let sorted = verifiedDays.sorted()
        var best = 1
        var runLength = 1

        for index in 1..<sorted.count {
            let previous = sorted[index - 1]
            let current = sorted[index]
            // `dateComponents([.day], from:to:)` returns the number of calendar
            // days between two startOfDay anchors — DST-safe by construction
            // because we never hand-roll 86400-second arithmetic.
            let dayDelta = calendar.dateComponents([.day], from: previous, to: current).day ?? 0
            if dayDelta == 1 {
                runLength += 1
                best = max(best, runLength)
            } else {
                runLength = 1
            }
        }
        return best
    }
}
