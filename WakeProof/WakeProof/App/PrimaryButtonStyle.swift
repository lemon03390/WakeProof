//
//  PrimaryButtonStyle.swift
//  WakeProof
//
//  Shared pill button style used by every "next-step" CTA across onboarding,
//  baseline capture, and the alarm-ringing screen. Migrated to design-system
//  tokens per Phase 1 UI rewrite — variants keep their names for call-site
//  stability but their fills / radii / fonts now come from Color+WakeProof,
//  WPRadius, WPFont, and WPShadow.
//
//  Variant map:
//   - primaryWhite   → cream-50 fill, char-900 text, .sm elevation; default CTA on dark hero.
//   - primaryConfirm → wpVerified fill, cream-50 text, .sm elevation; baseline-save only.
//   - primaryMuted   → cream-50 opacity-0.4 fill, char-900 opacity-0.5 text, NO elevation;
//                      disabled state — no shadow so the button doesn't signal interactivity.
//   - primaryAlarm   → wpPrimary 135° gradient fill, cream-50 text, pill radius, .accent
//                      coral-glow elevation; the single alarm-dismissal CTA. Label font
//                      is WPFont.title3 (22pt) — slightly larger than the prior `.title3`
//                      semantic (20pt) to match the design-system title3 token exactly.
//
//  Accessibility note (Dynamic Type): variants use WPFont.* fonts which return
//  `Font.system(size: N, weight: W)` — fixed-size, NOT scaling with the user's
//  Dynamic Type preference. This is intentional alignment with the CSS pixel
//  scale but represents an accessibility tradeoff. A follow-up task should
//  audit whether to wrap WPFont in `.relativeTo:` semantic styles before App
//  Store submission. See `Typography.swift`.
//

import SwiftUI

struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = .wpCream50
    var foreground: Color = .wpChar900
    var gradient: LinearGradient? = nil
    var cornerRadius: CGFloat = WPRadius.md
    var font: Font = WPFont.body.font.bold()
    var isProminent: Bool = false
    /// Shadow elevation. Default `.sm` for ordinary CTAs; `nil` for muted /
    /// disabled buttons so they don't signal interactivity. `isProminent`
    /// overrides this to `.accent` for the alarm CTA glow.
    var elevation: WPElevation? = .sm

    func makeBody(configuration: Configuration) -> some View {
        let base = configuration.label
            .font(font)
            .frame(maxWidth: .infinity)
            .padding()
            .background(background)
            .foregroundStyle(foreground)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .opacity(buttonOpacity(pressed: configuration.isPressed))
            .scaleEffect(configuration.isPressed && isProminent ? 0.98 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)

        return Group {
            if isProminent {
                base.wpShadow(.accent)
            } else if let elevation {
                base.wpShadow(elevation)
            } else {
                base
            }
        }
    }

    @ViewBuilder
    private var background: some View {
        if let gradient {
            gradient
        } else {
            tint
        }
    }

    private func buttonOpacity(pressed: Bool) -> Double {
        pressed ? 0.85 : 1.0
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    /// Cream-50 pill. Default CTA on dark hero surfaces ("Start your day",
    /// onboarding next-step buttons, verifying-success dismiss).
    static var primaryWhite: PrimaryButtonStyle { PrimaryButtonStyle() }

    /// Verified-green confirmation CTA. Used on baseline-save only — the
    /// moment the contract is actually committed.
    static var primaryConfirm: PrimaryButtonStyle {
        PrimaryButtonStyle(tint: .wpVerified, foreground: .wpCream50)
    }

    /// Disabled / inactive form. Renders the same shape but visually muted.
    /// `elevation: nil` so the disabled button doesn't carry a subtle
    /// elevation shadow that would falsely signal interactivity (regression
    /// caught during Phase 1 review).
    static var primaryMuted: PrimaryButtonStyle {
        PrimaryButtonStyle(
            tint: Color.wpCream50.opacity(0.4),
            foreground: .wpChar900.opacity(0.5),
            elevation: nil
        )
    }

    /// Pill CTA for the alarm-ringing screen ("Prove you're awake") and
    /// disable-challenge capture step. Signature 135° gradient + coral glow.
    /// Label font is `WPFont.title3` (22pt semibold + .bold() override) —
    /// 2pt larger than the prior `.title3` semantic (20pt) to match the
    /// design-system title3 token exactly. Visual sign-off on the alarm
    /// CTA required during Phase 6 device UAT.
    static var primaryAlarm: PrimaryButtonStyle {
        PrimaryButtonStyle(
            foreground: .wpCream50,
            gradient: .wpPrimary,
            cornerRadius: WPRadius.pill,
            font: WPFont.title3.font.bold(),
            isProminent: true
        )
    }
}

#if DEBUG
#Preview("All variants on cream") {
    VStack(spacing: WPSpacing.md) {
        Button("Primary white") {}.buttonStyle(.primaryWhite)
        Button("Primary confirm") {}.buttonStyle(.primaryConfirm)
        Button("Primary muted") {}.buttonStyle(.primaryMuted).disabled(true)
        Button("Prove you're awake") {}.buttonStyle(.primaryAlarm)
    }
    .padding(WPSpacing.xl2)
    .background(Color.wpCream100)
}

#Preview("Alarm CTA on warm-charcoal hero") {
    VStack {
        Spacer()
        Button("Prove you're awake") {}.buttonStyle(.primaryAlarm)
            .padding(.horizontal, WPSpacing.xl2)
        Spacer().frame(height: WPSpacing.xl2)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.wpChar900)
    .preferredColorScheme(.dark)
}
#endif
