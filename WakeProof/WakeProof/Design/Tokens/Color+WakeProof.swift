//
//  Color+WakeProof.swift
//  WakeProof
//
//  Brand color tokens transcribed literally from docs/design-system/colors_and_type.css.
//  Source of truth for palette. Do not invent new colors in this file — new tokens must
//  first be added to the CSS source and design-system preview cards, then mirrored here.
//  SKILL.md § "SwiftUI color transcription" shows the same snippet with 3-decimal
//  rounding; this file uses `/255.0` for byte-exact hex correspondence.
//

import SwiftUI

extension Color {
    // Cream surface — the icon's background. NOT pure white.
    static let wpCream50  = Color(red: 0xFE / 255.0, green: 0xF8 / 255.0, blue: 0xED / 255.0)  // #FEF8ED
    static let wpCream100 = Color(red: 0xFB / 255.0, green: 0xEE / 255.0, blue: 0xDB / 255.0)  // #FBEEDB
    static let wpCream200 = Color(red: 0xF5 / 255.0, green: 0xE3 / 255.0, blue: 0xC7 / 255.0)  // #F5E3C7

    // Warm charcoal — the icon's dark mark. NOT pure black.
    static let wpChar950 = Color(red: 0x1A / 255.0, green: 0x12 / 255.0, blue: 0x0C / 255.0)   // #1A120C
    static let wpChar900 = Color(red: 0x2B / 255.0, green: 0x1F / 255.0, blue: 0x17 / 255.0)   // #2B1F17
    static let wpChar800 = Color(red: 0x3D / 255.0, green: 0x2D / 255.0, blue: 0x22 / 255.0)   // #3D2D22
    static let wpChar500 = Color(red: 0x8A / 255.0, green: 0x6B / 255.0, blue: 0x55 / 255.0)   // #8A6B55
    static let wpChar300 = Color(red: 0xB8 / 255.0, green: 0x9A / 255.0, blue: 0x82 / 255.0)   // #B89A82

    // Accent — the icon's orange→coral gradient stops.
    static let wpOrange = Color(red: 0xFF / 255.0, green: 0xA0 / 255.0, blue: 0x47 / 255.0)    // #FFA047
    static let wpCoral  = Color(red: 0xF5 / 255.0, green: 0x4F / 255.0, blue: 0x4F / 255.0)    // #F54F4F

    // Semantic supports — warm-shifted, no cold blues/greens.
    static let wpVerified  = Color(red: 0x4E / 255.0, green: 0x8F / 255.0, blue: 0x47 / 255.0) // #4E8F47
    static let wpAttempted = Color(red: 0xE0 / 255.0, green: 0x7A / 255.0, blue: 0x2E / 255.0) // #E07A2E
}
