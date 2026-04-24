import XCTest
import SwiftUI
@testable import WakeProof

/// Gradients can't be introspected via SwiftUI public API, so these smoke
/// tests verify construction doesn't trap and the extension surface exists.
/// Visual correctness is verified via the preview/colors-accent-gradient.html
/// reference card and SwiftUI #Preview in the consuming components.
final class GradientTests: XCTestCase {
    func testPrimaryGradientExists() {
        let gradient = LinearGradient.wpPrimary
        XCTAssertNotNil(gradient)
    }
    func testSunriseGradientExists() {
        let gradient = LinearGradient.wpSunrise
        XCTAssertNotNil(gradient)
    }
}
