//
//  Shadows.swift
//  WakeProof
//
//  Warm-tinted elevation per docs/design-system/README.md § "Elevation".
//  All structural-level shadow colors are rgba(43, 31, 23, α) (.wpChar900) —
//  NEVER black. `.accent` uses coral α=0.25 for the signature primaryAlarm
//  glow. Structural levels (sm/md/lg) are dual-layer to match the CSS source
//  in `colors_and_type.css` lines 74-76: a wide soft layer plus a tight
//  sharp underlayer that keeps card edges from looking blurry on cream.
//  SwiftUI shadow modifiers chain additively, so the second `.shadow()`
//  call on the same view composites under the first.
//

import SwiftUI

enum WPElevation: CaseIterable {
    case sm, md, lg, accent
}

struct WPShadowModifier: ViewModifier {
    let elevation: WPElevation

    func body(content: Content) -> some View {
        switch elevation {
        case .sm:
            // CSS: 0 1px 2px α0.06, 0 1px 1px α0.04
            content
                .shadow(color: .wpChar900.opacity(0.06), radius: 2, x: 0, y: 1)
                .shadow(color: .wpChar900.opacity(0.04), radius: 1, x: 0, y: 1)
        case .md:
            // CSS: 0 4px 14px α0.08, 0 2px 4px α0.04
            content
                .shadow(color: .wpChar900.opacity(0.08), radius: 14, x: 0, y: 4)
                .shadow(color: .wpChar900.opacity(0.04), radius: 4,  x: 0, y: 2)
        case .lg:
            // CSS: 0 12px 32px α0.12, 0 4px 8px α0.06
            content
                .shadow(color: .wpChar900.opacity(0.12), radius: 32, x: 0, y: 12)
                .shadow(color: .wpChar900.opacity(0.06), radius: 8,  x: 0, y: 4)
        case .accent:
            // CSS: 0 8px 24px coral α0.25 (single-layer in source)
            content
                .shadow(color: .wpCoral.opacity(0.25), radius: 24, x: 0, y: 8)
        }
    }
}

extension View {
    /// Applies a warm-tinted elevation per the design-system elevation
    /// ladder. `.accent` is reserved for the primaryAlarm CTA glow; do not
    /// use it on cards or non-CTA surfaces.
    ///
    /// Note: `wpChar900`-tinted shadows do not read on warm-charcoal
    /// surfaces (per README § "Borders, cards, transparency"). Dark hero
    /// views (AlarmRingingView, MorningBriefingView, DisableChallengeView)
    /// should use a 1px inset hairline instead — see WPCard's dark variant.
    func wpShadow(_ elevation: WPElevation) -> some View {
        self.modifier(WPShadowModifier(elevation: elevation))
    }
}
