//
//  Radii.swift
//  WakeProof
//
//  Radius scale per docs/design-system/colors_and_type.css § "--wp-radius-*".
//  Form inputs = sm (10). Cards = lg (20). Hero surfaces = xl (28).
//  primaryAlarm CTA = pill (999). Standard buttons = md (14) — rounded
//  up from the shipped PrimaryButtonStyle's 12 for a softer read on cream.
//

import CoreGraphics

enum WPRadius {
    static let xs:   CGFloat = 6
    static let sm:   CGFloat = 10
    static let md:   CGFloat = 14
    static let lg:   CGFloat = 20
    static let xl:   CGFloat = 28
    static let pill: CGFloat = 999
}
