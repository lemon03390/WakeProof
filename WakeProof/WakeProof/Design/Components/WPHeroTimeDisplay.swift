//
//  WPHeroTimeDisplay.swift
//  WakeProof
//
//  Ticking time display driven by `TimelineView(.periodic(from: .now, by: 1))`.
//  Two styles: `.large` (88pt, alarm-ring hero), `.medium` (64pt, home
//  hero). Both use SF Pro Rounded via WPFont.heroXL / .hero and
//  `.monospacedDigit()` so the colon+digits don't jitter as seconds tick.
//
//  Foreground defaults to wpCream50 (assumes dark hero surface). Pass
//  `foreground: .wpChar900` for cream surfaces (e.g. home).
//

import SwiftUI

struct WPHeroTimeDisplay: View {
    enum Style { case large, medium }

    let style: Style
    let foreground: Color

    init(style: Style = .large, foreground: Color = .wpCream50) {
        self.style = style
        self.foreground = foreground
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(context.date.formatted(date: .omitted, time: .shortened))
                .wpFont(style == .large ? .heroXL : .hero)
                .monospacedDigit()
                .foregroundStyle(foreground)
                // 12-hour locales render time as e.g. "10:30 AM" — at 88pt
                // SF Pro Rounded the AM/PM suffix overflows on standard iPhone
                // widths (iPhone 17 Pro 402pt minus 32pt screen padding leaves
                // ~338pt, while "10:30 AM" wants ~350pt). lineLimit(1) +
                // minimumScaleFactor(0.5) lets SwiftUI shrink to fit on a
                // single line rather than wrapping. 0.5 is generous: even
                // worst-case "12:30 PM" never needs more than ~0.85x scale.
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
    }
}

#Preview("Large on dark") {
    WPHeroTimeDisplay(style: .large)
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color.wpChar900)
        .preferredColorScheme(.dark)
}

#Preview("Medium on cream") {
    WPHeroTimeDisplay(style: .medium, foreground: .wpChar900)
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color.wpCream100)
}
