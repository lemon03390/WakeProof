//
//  InvestmentDashboardView.swift
//  WakeProof
//
//  Wave 5 H4 (§12.3-H4): the "Your commitment" surface — a profile / settings
//  card surfacing the three accumulated-asset metrics the user has built up:
//  baseline age, count of verified mornings, count of Opus insights noted in
//  the on-disk memory file. Raises switching cost via tangible loss aversion
//  — replacing the app means abandoning data the user has invested in.
//
//  Hooked source signals:
//  - HOOK_S5_2 (數據資料投入防護網): surfacing accumulated data makes the
//    investment visible, which is what makes leaving feel like loss.
//  - HOOK_S7_8 (高頻投入與數據資產化): the same mornings that built the
//    streak also built a growing profile — this view makes the second
//    aspect concrete.
//
//  Architecture:
//  - Pure SwiftData query layer — no new @Model, no migration. Baselines and
//    WakeAttempts arrive via `@Query`; the Opus insight count comes async
//    from the actor-backed `MemoryStore`.
//  - `MemoryStore` is a Swift actor (not @Observable), so SwiftUI's
//    `.environment(_:)` refuses it. The live store reaches us via
//    `VisionVerifier.memoryStore`, matching the pattern used elsewhere
//    (the verifier is the only wired holder per WakeProofApp.body).
//  - Pure-logic helpers live on `InvestmentDashboardModel` so the date
//    formatting + empty-state decisions are testable without instantiating
//    a SwiftUI view.
//

import SwiftData
import SwiftUI
import os

struct InvestmentDashboardView: View {

    @Query private var baselines: [BaselinePhoto]
    @Query private var wakeAttempts: [WakeAttempt]

    /// Bridge to the actor-backed MemoryStore. VisionVerifier is the single
    /// holder wired by WakeProofApp.bootstrapIfNeeded; a nil `memoryStore`
    /// here simply means the count never resolves (we render "-") which is
    /// the same fresh-install semantic as a verified store with zero entries.
    /// See architecture note in file header.
    @Environment(VisionVerifier.self) private var visionVerifier

    /// Insights count is read from `MemoryStore.read()` which is an async
    /// throwing actor call. Three states encoded here:
    ///   - `nil`        → loading, or read failed. UI renders "-" placeholder.
    ///   - `.some(Int)` → successful read. UI renders the integer.
    /// We deliberately do not model "error" as a separate case per spec:
    /// a missing count is a soft metric, not worth a banner.
    @State private var insightsCount: Int?

    /// Injectable for tests / previews. Default `.now` at render; a
    /// constructor override lets tests feed a fixed date without resorting
    /// to snapshot testing (which is out of scope for H4 per spec).
    var now: Date = .now

    private let logger = Logger(subsystem: LogSubsystem.verification, category: "dashboard")

    var body: some View {
        ScrollView {
            VStack(spacing: WPSpacing.md) {
                // Metric 1: baseline age. Always rendered — on fresh install it
                // carries the prompt copy that tells the user what's missing.
                baselineCard

                // Metrics 2 + 3: gated on baseline presence. A fresh-install
                // user sees only the prompt card above; these two only make
                // sense once a baseline exists.
                if baselines.first != nil {
                    verifiedMorningsCard
                    insightsCard
                    framingLine
                }
            }
            .padding(.horizontal, WPSpacing.xl2)
            .padding(.vertical, WPSpacing.xl)
        }
        .background(Color.wpCream100)
        .navigationTitle("Your commitment")
        .navigationBarTitleDisplayMode(.inline)
        // Load the async Opus insights count. `.task` on the ScrollView binds
        // the lifetime to the view's presentation — a re-entry into the view
        // re-fires this, which is intentional: navigating back and forth
        // refreshes the count after a verify that landed while we were away.
        .task { await loadInsightsCount() }
    }

    // MARK: - Cards

    @ViewBuilder
    private var baselineCard: some View {
        if let baseline = baselines.first {
            WPMetricCard(
                value: InvestmentDashboardModel.baselineAgeText(
                    capturedAt: baseline.capturedAt,
                    now: now
                ),
                label: InvestmentDashboardModel.baselineSubHint(
                    locationLabel: baseline.locationLabel,
                    capturedAt: baseline.capturedAt
                )
            )
        } else {
            // No baseline → show only this card with the onboarding prompt.
            WPCard {
                Text(InvestmentDashboardModel.noBaselineCopy)
                    .wpFont(.body)
                    .foregroundStyle(Color.wpChar500)
                    .padding(.vertical, WPSpacing.xs1)
            }
        }
    }

    @ViewBuilder
    private var verifiedMorningsCard: some View {
        let count = InvestmentDashboardModel.verifiedCount(from: wakeAttempts)
        WPMetricCard(
            value: "\(count)",
            label: count == 0 ? "Verified mornings — tomorrow's your first" : "Verified mornings since baseline",
            accent: true
        )
    }

    @ViewBuilder
    private var insightsCard: some View {
        WPMetricCard(
            value: InvestmentDashboardModel.insightsCountText(insightsCount),
            label: (insightsCount ?? 0) == 0 && insightsCount != nil
                ? "Insights — Opus starts noticing after verified wakes"
                : "Insights Opus noticed about you"
        )
    }

    @ViewBuilder
    private var framingLine: some View {
        let count = InvestmentDashboardModel.verifiedCount(from: wakeAttempts)
        Text(InvestmentDashboardModel.framingLine(verifiedCount: count))
            .wpFont(.title3)
            .foregroundStyle(Color.wpChar900)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, WPSpacing.xs2)
    }

    // MARK: - Async loading

    /// One-shot read of `MemoryStore.read()` on view appear. Leaves
    /// `insightsCount` as `nil` on any failure — the UI renders "-" and
    /// no error banner surfaces (soft metric per spec). We log through the
    /// verification/dashboard subsystem so a recurring read failure is
    /// still observable via Console.app without polluting the UI.
    private func loadInsightsCount() async {
        guard let store = visionVerifier.memoryStore else {
            // Stage 8 IMPORTANT 4 fix: escalated from `.info` to `.error`. An
            // unwired MemoryStore at view-appear time is an observability
            // issue — bootstrap (WakeProofApp.bootstrapMemoryStore) should
            // have assigned it before any view mounts. `.info` is routine
            // lifecycle; this is "something didn't happen that should have".
            // Banner stays absent per spec (soft metric), but Console.app
            // now surfaces the signal prominently.
            logger.error("MemoryStore not wired — insights count unresolvable; check bootstrap wiring")
            return
        }
        do {
            let snapshot = try await store.read()
            // Stage 8 MEDIUM 7 fix: dropped the redundant `await MainActor.run`
            // hop. `.task` on a SwiftUI view body runs on MainActor by
            // SwiftUI contract, and after `await memoryStore.read()` resumes,
            // the continuation is already back on MainActor. The explicit
            // MainActor.run wrapper was dead ceremony.
            self.insightsCount = snapshot.totalHistoryCount
        } catch {
            logger.error("MemoryStore read failed for dashboard: \(error.localizedDescription, privacy: .public)")
            // Intentionally leave insightsCount at nil — the dashboard is a
            // soft metric surface and a read failure shouldn't alarm the user.
        }
    }
}

// MARK: - Pure-logic helpers

/// Static helpers factored out of the View so the date-formatting and
/// empty-state decisions are unit-testable without instantiating a SwiftUI
/// view. Keep these referentially transparent — no environment reads, no
/// `Date.now` default parameters that would capture real time at call site.
enum InvestmentDashboardModel {

    /// The onboarding prompt string shown when no baseline exists yet.
    /// Exposed as a static constant (not a computed property) so tests can
    /// assert against the exact copy without running any branching.
    static let noBaselineCopy = "Capture your baseline to start collecting mornings"

    /// Render "Today" / "Yesterday" / "N days ago" from a baseline date.
    /// Future dates (user's clock jumped backward between capture and read)
    /// collapse to "Today" — showing "-5 days ago" would be confusing noise.
    static func baselineAgeText(
        capturedAt: Date,
        now: Date,
        calendar: Calendar = .current
    ) -> String {
        let days = calendar.dateComponents([.day], from: capturedAt, to: now).day ?? 0
        switch days {
        case ..<1:
            // Covers both same-day (days == 0) and the clock-skew future case.
            return "Today"
        case 1:
            return "Yesterday"
        default:
            return "\(days) days ago"
        }
    }

    /// Formatted "Location, dd MMM yyyy" sub-hint beneath the baseline age.
    /// Uses the abbreviated date style so the row stays short on narrow
    /// iPhone screens. `dateFormatter` is parameterised so tests can pin
    /// the locale and avoid flakiness across CI regions.
    static func baselineSubHint(
        locationLabel: String,
        capturedAt: Date,
        locale: Locale = .current
    ) -> String {
        var style = Date.FormatStyle.dateTime
            .year().month(.abbreviated).day()
        style.locale = locale
        let dateText = capturedAt.formatted(style)
        let trimmed = locationLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return dateText }
        return "\(trimmed), \(dateText)"
    }

    /// Count of VERIFIED WakeAttempts from an unfiltered input. Filter here
    /// (not in `@Query`) because the view already holds the full attempt
    /// array for rendering parity with StreakCalendarView; filtering twice
    /// at the query layer would be wasted work on already-main-context data.
    static func verifiedCount(from attempts: [WakeAttempt]) -> Int {
        attempts.reduce(into: 0) { count, attempt in
            if attempt.verdictEnum == .verified {
                count += 1
            }
        }
    }

    /// Rendering for the insights-count cell. Nil → placeholder "-"
    /// (loading or soft failure); otherwise the integer as a string.
    static func insightsCountText(_ value: Int?) -> String {
        guard let value else { return "-" }
        return "\(value)"
    }

    /// Whether the framing line below the metrics should render at all.
    /// Fresh-install users (no baseline) should not see "WakeProof has 0
    /// of your mornings" — that reads as a bug, not a feature.
    static func shouldShowFramingLine(hasBaseline: Bool) -> Bool {
        hasBaseline
    }

    /// The literal copy for the framing line. N = verified count. Kept as
    /// a static helper so the string is canon-tested and UI can't drift
    /// from the spec.
    static func framingLine(verifiedCount: Int) -> String {
        "Apple Clock doesn't know you. WakeProof has \(verifiedCount) of your mornings."
    }
}
