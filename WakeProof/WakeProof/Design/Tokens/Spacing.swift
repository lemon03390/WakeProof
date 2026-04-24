//
//  Spacing.swift
//  WakeProof
//
//  4pt base grid per docs/design-system/colors_and_type.css § "Spacing scale".
//  Screen padding is WPSpacing.xl2 (32pt). Section gap is WPSpacing.xl (24pt)
//  matching the VStack(spacing: 24) usage throughout existing Swift code.
//

import CoreGraphics

enum WPSpacing {
    static let xs1: CGFloat = 4
    static let xs2: CGFloat = 8
    static let sm:  CGFloat = 12
    static let md:  CGFloat = 16  // base row padding
    static let lg:  CGFloat = 20
    static let xl:  CGFloat = 24  // section gap
    static let xl2: CGFloat = 32  // screen padding
    static let xl3: CGFloat = 40
    static let xl4: CGFloat = 48
    static let xl5: CGFloat = 64  // hero top space
}
