import XCTest
import SwiftUI
@testable import WakeProof

/// Typography enum surfaces every role the CSS source defines (hero-xl,
/// hero, display, title-1..3, headline, body, callout, subhead, footnote,
/// caption). Hero and display roles use SF Pro Rounded via
/// `.system(design: .rounded)`; body roles use the system default.
/// Font internal structure isn't publicly introspectable — these tests
/// verify the enum exists with all expected cases and returns non-nil Font.
final class TypographyTests: XCTestCase {
    func testAllRolesResolveToFont() {
        let roles: [WPFont] = [
            .heroXL, .hero, .display, .title1, .title2, .title3,
            .headline, .body, .callout, .subhead, .footnote, .caption
        ]
        for role in roles {
            _ = role.font  // just verify property access doesn't trap
        }
    }

    /// Catches "added a WPFont case but forgot to add it to the
    /// testAllRolesResolveToFont roles array" — the only real failure mode
    /// the first test can't cover on its own. Uses CaseIterable so the
    /// check stays in sync with the enum without a manually maintained list.
    func testAllRolesCoveredByFontSwitch() {
        XCTAssertEqual(WPFont.allCases.count, 12,
            "WPFont has \(WPFont.allCases.count) cases — update testAllRolesResolveToFont roles array and this test's expected count together when adding or removing a role.")
    }
}
