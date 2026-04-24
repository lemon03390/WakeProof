//
//  Gradient+WakeProof.swift
//  WakeProof
//
//  Signature gradients. `wpPrimary` is the 135° orange→coral used for the
//  primaryAlarm CTA, hero numerals, and the MorningBriefing H1 observation
//  mark. `wpSunrise` is the 180° 4-stop reveal gradient reserved for the
//  MorningBriefingView verified-verdict sunrise ceremony — do not use
//  wpSunrise anywhere else.
//
//  Sunrise hex values transcribed from docs/design-system/colors_and_type.css
//  line 48 (`--wp-gradient-sunrise`). Stops 1 (#6E3824 rust) and 2 (#F38B4D
//  warm-peach) appear only in this gradient and are inlined rather than
//  promoted to `Color+WakeProof.swift`.
//
//  Doc-drift note: docs/design-system/README.md line 143 shows #1A120C at
//  sunrise stop 0. This is stale; CSS is canonical per SKILL.md and specifies
//  #2B1F17 (wpChar900). Reconcile README in a follow-up doc PR; this code
//  follows CSS.
//

import SwiftUI

extension LinearGradient {
    /// 135° orange → coral. Primary alarm CTA, hero numerals, streak-digit
    /// fill, WakeProof wordmark on onboarding. NOT for backgrounds, NOT for
    /// long runs of text (use `wpCoral` solid for those).
    ///
    /// Known angle limitation: SwiftUI `LinearGradient` with `.topLeading` /
    /// `.bottomTrailing` renders a true 135° only on square frames. On a
    /// full-width pill CTA (~390×56pt) the diagonal flattens toward horizontal
    /// because the gradient stretches corner-to-corner. The CSS source
    /// specifies `135deg`; this SwiftUI approximation is visually close on
    /// typical hero numerals and pill buttons, but demo-critical surfaces
    /// (primaryAlarm) require on-device sign-off during Phase 6 UAT.
    static let wpPrimary = LinearGradient(
        colors: [.wpOrange, .wpCoral],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// 180° 4-stop sunrise reveal. Reserved for MorningBriefingView's
    /// VERIFIED verdict transition — 1200ms vertical wipe from warm-char
    /// to cream via rust and warm-peach. Stops match CSS source exactly:
    /// wpChar900 (0x2B1F17) 0% → rust (0x6E3824) 45% → peach (0xF38B4D) 85%
    /// → wpCream100 (0xFBEEDB) 100%.
    static let wpSunrise = LinearGradient(
        stops: [
            .init(color: .wpChar900, location: 0.00),
            .init(color: Color(red: 0x6E / 255.0, green: 0x38 / 255.0, blue: 0x24 / 255.0), location: 0.45),
            .init(color: Color(red: 0xF3 / 255.0, green: 0x8B / 255.0, blue: 0x4D / 255.0), location: 0.85),
            .init(color: .wpCream100, location: 1.00)
        ],
        startPoint: .top,
        endPoint: .bottom
    )
}
