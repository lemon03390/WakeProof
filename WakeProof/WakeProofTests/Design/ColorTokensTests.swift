import XCTest
import SwiftUI
import UIKit
@testable import WakeProof

/// Verifies every `wp*` color token resolves to the documented hex value in
/// `docs/design-system/SKILL.md` § "SwiftUI color transcription" and
/// `colors_and_type.css`. sRGB components are unpacked via `UIColor(Color)`
/// and compared byte-wise with 0.01 accuracy (covers the 3-decimal rounding
/// in the source spec).
final class ColorTokensTests: XCTestCase {
    private func srgb(_ color: Color) -> (r: Double, g: Double, b: Double) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b))
    }

    private func assertHex(_ color: Color, _ r: Int, _ g: Int, _ b: Int, file: StaticString = #file, line: UInt = #line) {
        let rgb = srgb(color)
        XCTAssertEqual(rgb.r, Double(r) / 255.0, accuracy: 0.01, "red channel", file: file, line: line)
        XCTAssertEqual(rgb.g, Double(g) / 255.0, accuracy: 0.01, "green channel", file: file, line: line)
        XCTAssertEqual(rgb.b, Double(b) / 255.0, accuracy: 0.01, "blue channel", file: file, line: line)
    }

    func testCream100_FBEEDB()  { assertHex(.wpCream100, 0xFB, 0xEE, 0xDB) }
    func testCream50_FEF8ED()   { assertHex(.wpCream50,  0xFE, 0xF8, 0xED) }
    func testCream200_F5E3C7()  { assertHex(.wpCream200, 0xF5, 0xE3, 0xC7) }
    func testChar950_1A120C()   { assertHex(.wpChar950,  0x1A, 0x12, 0x0C) }
    func testChar900_2B1F17()   { assertHex(.wpChar900,  0x2B, 0x1F, 0x17) }
    func testChar800_3D2D22()   { assertHex(.wpChar800,  0x3D, 0x2D, 0x22) }
    func testChar500_8A6B55()   { assertHex(.wpChar500,  0x8A, 0x6B, 0x55) }
    func testChar300_B89A82()   { assertHex(.wpChar300,  0xB8, 0x9A, 0x82) }
    func testOrange_FFA047()    { assertHex(.wpOrange,   0xFF, 0xA0, 0x47) }
    func testCoral_F54F4F()     { assertHex(.wpCoral,    0xF5, 0x4F, 0x4F) }
    func testVerified_4E8F47()  { assertHex(.wpVerified, 0x4E, 0x8F, 0x47) }
    func testAttempted_E07A2E() { assertHex(.wpAttempted,0xE0, 0x7A, 0x2E) }
}
