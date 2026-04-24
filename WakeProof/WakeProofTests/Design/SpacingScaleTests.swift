import XCTest
@testable import WakeProof

/// Spacing scale is a 4pt base grid per design-system §Spacing & radii.
/// Tests assert the published values match the CSS source of truth so
/// SwiftUI and the HTML preview cards stay in lockstep.
final class SpacingScaleTests: XCTestCase {
    func testScaleMatchesCSSSource() {
        XCTAssertEqual(WPSpacing.xs1, 4)
        XCTAssertEqual(WPSpacing.xs2, 8)
        XCTAssertEqual(WPSpacing.sm,  12)
        XCTAssertEqual(WPSpacing.md,  16)
        XCTAssertEqual(WPSpacing.lg,  20)
        XCTAssertEqual(WPSpacing.xl,  24)
        XCTAssertEqual(WPSpacing.xl2, 32)
        XCTAssertEqual(WPSpacing.xl3, 40)
        XCTAssertEqual(WPSpacing.xl4, 48)
        XCTAssertEqual(WPSpacing.xl5, 64)
    }

    func testAllValuesAreMultiplesOfFour() {
        let values: [CGFloat] = [
            WPSpacing.xs1, WPSpacing.xs2, WPSpacing.sm, WPSpacing.md,
            WPSpacing.lg, WPSpacing.xl, WPSpacing.xl2, WPSpacing.xl3,
            WPSpacing.xl4, WPSpacing.xl5
        ]
        for v in values {
            XCTAssertEqual(v.truncatingRemainder(dividingBy: 4), 0, "\(v) is not a multiple of 4")
        }
    }
}
