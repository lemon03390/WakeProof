import XCTest
import SwiftUI
@testable import WakeProof

/// Component construction + public-API smoke. `WPStreakBadge.shouldRender`
/// MUST behave identically to the existing `StreakBadgeView.shouldRender`
/// so the AlarmSchedulerView call site can swap callers without branching.
final class ComponentSmokeTests: XCTestCase {
    // ── WPStreakBadge.shouldRender contract ─────────────────────────────
    func testShouldRender_bothZero_false() {
        XCTAssertFalse(WPStreakBadge.shouldRender(currentStreak: 0, bestStreak: 0))
    }

    func testShouldRender_currentPositive_true() {
        XCTAssertTrue(WPStreakBadge.shouldRender(currentStreak: 3, bestStreak: 3))
        XCTAssertTrue(WPStreakBadge.shouldRender(currentStreak: 1, bestStreak: 5))
    }

    func testShouldRender_currentZeroBestPositive_true() {
        XCTAssertTrue(WPStreakBadge.shouldRender(currentStreak: 0, bestStreak: 5))
    }

    func testShouldRender_negativeDefensive_false() {
        XCTAssertFalse(WPStreakBadge.shouldRender(currentStreak: -1, bestStreak: -1))
    }

    // ── Construction smoke ──────────────────────────────────────────────
    func testWPCardConstructs() {
        _ = WPCard { Text("x") }
    }

    func testWPSectionConstructs() {
        _ = WPSection("S") { Text("x") }
    }

    func testWPMetricCardConstructs() {
        _ = WPMetricCard(value: "12", label: "mornings")
        _ = WPMetricCard(value: "12", label: "mornings", accent: true)
    }

    func testWPHeroTimeDisplayConstructs() {
        _ = WPHeroTimeDisplay(style: .large)
        _ = WPHeroTimeDisplay(style: .medium, foreground: .wpChar900)
    }

    func testWPStreakBadgeConstructs() {
        _ = WPStreakBadge(currentStreak: 3, bestStreak: 5)
    }

    /// Cross-check: the new shouldRender static must agree with the shipped
    /// StreakBadgeView.shouldRender for every test case. Phase 6 will delete
    /// StreakBadgeView once call sites migrate; until then both must agree.
    ///
    /// NOTE: This validates only the `shouldRender(...)` static function.
    /// Render-branch parity (the body's 3-way ladder: active → dormant →
    /// nothing) is not covered here; visual inspection via #Preview and
    /// Phase 3 UAT serve as that gate.
    func testShouldRender_agreesWithShippedStreakBadgeView() {
        let cases: [(Int, Int)] = [
            (0, 0), (1, 1), (3, 5), (0, 5), (-1, -1),
            (5, 0),   // best > current with current high — preserved 'best' floor
            (0, 1)    // tiniest dormant
        ]
        for (current, best) in cases {
            XCTAssertEqual(
                WPStreakBadge.shouldRender(currentStreak: current, bestStreak: best),
                StreakBadgeView.shouldRender(currentStreak: current, bestStreak: best),
                "Disagreement at (current: \(current), best: \(best))"
            )
        }
    }
}
