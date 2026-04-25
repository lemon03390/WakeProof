import XCTest
import SwiftUI
@testable import WakeProof

/// Component construction + public-API smoke for the WakeProof design system.
/// The cross-check test `testShouldRender_agreesWithShippedStreakBadgeView`
/// was removed in Phase 6 (UI 6.5) after `StreakBadgeView.swift` was deleted.
/// `WPStreakBadge` is now the canonical implementation; the migration is complete.
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
}
