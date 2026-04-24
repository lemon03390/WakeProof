//
//  Shadows.swift
//  WakeProof
//
//  Warm-tinted elevation per docs/design-system/README.md § "Elevation".
//  All shadow colors are rgba(43, 31, 23, α) — NEVER black. `.accent`
//  uses coral α=0.25 for the signature primaryAlarm glow.
//

import SwiftUI

enum WPElevation {
    case sm, md, lg, accent
}

struct WPShadowModifier: ViewModifier {
    let elevation: WPElevation

    func body(content: Content) -> some View {
        switch elevation {
        case .sm:
            content
                .shadow(color: .wpChar900.opacity(0.06), radius: 2, x: 0, y: 1)
        case .md:
            content
                .shadow(color: .wpChar900.opacity(0.08), radius: 14, x: 0, y: 4)
        case .lg:
            content
                .shadow(color: .wpChar900.opacity(0.12), radius: 32, x: 0, y: 12)
        case .accent:
            content
                .shadow(color: .wpCoral.opacity(0.25), radius: 24, x: 0, y: 8)
        }
    }
}

extension View {
    /// Applies a warm-tinted elevation per the design-system elevation
    /// ladder. `.accent` is reserved for the primaryAlarm CTA glow.
    func wpShadow(_ elevation: WPElevation) -> some View {
        self.modifier(WPShadowModifier(elevation: elevation))
    }
}
