import XCTest
import SwiftUI
@testable import WakeProof

/// SwiftUI's `.shadow()` modifier produces a `ModifiedContent` that isn't
/// publicly introspectable, so these are construction-and-exhaustiveness
/// smoke tests in the same shape as TypographyTests:
///   1. Every WPElevation case can be applied to a view without trapping.
///   2. CaseIterable count guards against "added a case but forgot to add
///      a switch arm in WPShadowModifier" — adding a case without a switch
///      arm would be a compile error, but adding one without updating the
///      test count signals the contributor to verify visual coverage too.
final class ShadowsTests: XCTestCase {
    func testAllElevationsApplyWithoutTrap() {
        let elevations: [WPElevation] = [.sm, .md, .lg, .accent]
        for elevation in elevations {
            _ = Color.clear.wpShadow(elevation)
        }
    }

    func testAllElevationsCovered() {
        XCTAssertEqual(WPElevation.allCases.count, 4,
            "WPElevation has \(WPElevation.allCases.count) cases — update testAllElevationsApplyWithoutTrap and this expected count together when adding or removing an elevation.")
    }
}
