//
//  ShareCardViewTests.swift
//  WakeProofTests
//
//  Wave 5 H5 (§12.3-H5): unit coverage for the pure-logic helpers on
//  `ShareCardModel`. The SwiftUI `ShareCardView` and `ImageRenderer` are NOT
//  exercised here — offscreen rendering is hard to pin deterministically
//  across simulator revs, and the spec rules out snapshot testing for H5 to
//  avoid fragility. Gate logic + copy constants cover the risk surface
//  (opt-in enforcement, streak threshold, pinned strings).
//

import XCTest
@testable import WakeProof

final class ShareCardViewTests: XCTestCase {

    // MARK: - Canvas dimensions

    /// The canvas size must stay 9:16 portrait. IG Story ingests 1080x1920
    /// natively — a drift here would silently letterbox the shared card on
    /// upload, which is the exact UX issue the minimalist design aims to
    /// avoid. Pinning as a ratio (rather than asserting the raw literals)
    /// so a future migration to a different base resolution still validates
    /// the aspect-ratio invariant.
    func testCanvasDimensionsAreNineByEightteenRatio() {
        XCTAssertEqual(ShareCardModel.canvasWidth, 1080)
        XCTAssertEqual(ShareCardModel.canvasHeight, 1920)
        // The ratio assertion: height / width == 16 / 9. Using a float
        // equality with tolerance so a 1px pixel-grid rounding wouldn't
        // break the test on a future canvas rescale.
        let ratio = ShareCardModel.canvasHeight / ShareCardModel.canvasWidth
        XCTAssertEqual(ratio, 16.0 / 9.0, accuracy: 0.0001)
        // Also assert the CGSize constant matches the raw pair — catches
        // a future edit where only one of the two literals is changed.
        XCTAssertEqual(ShareCardModel.canvasSize.width, ShareCardModel.canvasWidth)
        XCTAssertEqual(ShareCardModel.canvasSize.height, ShareCardModel.canvasHeight)
    }

    // MARK: - Share button visibility gate

    /// The opt-in contract (HOOK_S4_5): the button is hidden when the user
    /// has not enabled the feature, regardless of streak / observation.
    /// This is the strongest invariant of the gate — a regression here would
    /// be a privacy/autonomy incident.
    func testShareButtonHiddenWhenSettingOff() {
        // Every combination of streak / observation, always false when
        // enabled=false. Verify the three interesting streak points —
        // zero (no streak), one (minimum active), and a larger number.
        XCTAssertFalse(ShareCardModel.shouldShowShareButton(
            enabled: false, streak: 0, observation: nil
        ))
        XCTAssertFalse(ShareCardModel.shouldShowShareButton(
            enabled: false, streak: 1, observation: "hello"
        ))
        XCTAssertFalse(ShareCardModel.shouldShowShareButton(
            enabled: false, streak: 99, observation: "window light shifted"
        ))
    }

    /// Enabled + active streak + observation → the button renders. This is
    /// the canonical "happy path" case — the card has all three elements
    /// (number + caption + observation + mark).
    func testShareButtonShownWhenSettingOnAndStreakOneOrMore() {
        XCTAssertTrue(ShareCardModel.shouldShowShareButton(
            enabled: true, streak: 1, observation: "hello"
        ))
        XCTAssertTrue(ShareCardModel.shouldShowShareButton(
            enabled: true, streak: 42, observation: "kitchen looks brighter"
        ))
    }

    /// Zero streak must NOT render the button even when enabled. A "0-day
    /// streak" card is a weird artefact to share — it suggests the product
    /// failed rather than celebrated. The gate holds this line.
    func testShareButtonHiddenWhenStreakZero() {
        XCTAssertFalse(ShareCardModel.shouldShowShareButton(
            enabled: true, streak: 0, observation: nil
        ))
        XCTAssertFalse(ShareCardModel.shouldShowShareButton(
            enabled: true, streak: 0, observation: "observation present"
        ))
    }

    /// Observation-nil must NOT hide the button when the streak is active.
    /// Per spec: "streak alone is shareable". The card's view layer hides
    /// the observation block when nil, so the card still renders cleanly
    /// (just the number + mark).
    func testShareButtonShownWhenObservationNilButStreakNonZero() {
        XCTAssertTrue(ShareCardModel.shouldShowShareButton(
            enabled: true, streak: 5, observation: nil
        ))
        // Empty-string observation must behave identically to nil for the
        // gate (the view already guards on `!observation.isEmpty`).
        XCTAssertTrue(ShareCardModel.shouldShowShareButton(
            enabled: true, streak: 5, observation: ""
        ))
    }

    // MARK: - Copy constants

    /// Pinned copy — a silent edit here would ship to demo without surfacing
    /// in a review. "day streak" is the under-hero caption; "WakeProof" is
    /// the bottom-right mark; "Share this morning" is the button label in
    /// MorningBriefingView.
    func testCopyLinesAreLiteral() {
        XCTAssertEqual(ShareCardModel.streakCaption, "day streak")
        XCTAssertEqual(ShareCardModel.markLabel, "WakeProof")
        XCTAssertEqual(ShareCardModel.shareButtonCopy, "Share this morning")
    }

    // MARK: - Edge cases

    /// Negative streak (shouldn't happen per StreakService semantics, but the
    /// gate is the last line of defence) must NOT render the button —
    /// defensive-programming test. The `streak >= 1` check catches this.
    func testShareButtonHiddenWhenStreakNegative() {
        XCTAssertFalse(ShareCardModel.shouldShowShareButton(
            enabled: true, streak: -1, observation: "whatever"
        ))
    }
}
