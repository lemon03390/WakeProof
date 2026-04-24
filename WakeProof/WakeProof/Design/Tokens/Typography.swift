//
//  Typography.swift
//  WakeProof
//
//  Type scale per docs/design-system/colors_and_type.css § "Typography".
//  Hero / display roles use SF Pro Rounded (system, iOS 17+) via
//  `.system(design: .rounded)` per SKILL.md — Nunito is the web-only
//  fallback, NOT shipped on iOS. Body roles use the system default.
//
//  Hero numerals (heroXL, hero, display) should use .monospacedDigit()
//  at call-sites where the value ticks (streak counter, clock time) so
//  the tabular rendering doesn't jitter. See AlarmRingingView time display.
//

import SwiftUI

enum WPFont {
    case heroXL   // 88pt rounded — AlarmRingingView time
    case hero     // 64pt rounded — MorningBriefing H1
    case display  // 42pt rounded — Welcome title, large streak digit
    case title1   // 34pt — navigation titles
    case title2   // 28pt — commitment note emphasis
    case title3   // 22pt — section headings
    case headline // 17pt semibold
    case body     // 17pt regular
    case callout  // 16pt
    case subhead  // 15pt
    case footnote // 13pt
    case caption  // 12pt uppercase tracking

    var font: Font {
        switch self {
        case .heroXL:   return .system(size: 88, weight: .bold, design: .rounded)
        case .hero:     return .system(size: 64, weight: .bold, design: .rounded)
        case .display:  return .system(size: 42, weight: .bold, design: .rounded)
        case .title1:   return .system(size: 34, weight: .bold)
        case .title2:   return .system(size: 28, weight: .semibold)
        case .title3:   return .system(size: 22, weight: .semibold)
        case .headline: return .system(size: 17, weight: .semibold)
        case .body:     return .system(size: 17, weight: .regular)
        case .callout:  return .system(size: 16, weight: .regular)
        case .subhead:  return .system(size: 15, weight: .regular)
        case .footnote: return .system(size: 13, weight: .regular)
        case .caption:  return .system(size: 12, weight: .medium)
        }
    }
}

extension View {
    /// Applies a WPFont role's font. Use this at call sites instead of
    /// `.font(.system(size: N))` so the surface stays consistent with the
    /// design-system type scale.
    func wpFont(_ role: WPFont) -> some View {
        self.font(role.font)
    }
}
