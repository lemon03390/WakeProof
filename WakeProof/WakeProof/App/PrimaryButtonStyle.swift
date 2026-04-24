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
//   - primaryWhite   → cream-50 fill, char-900 text; default CTA on dark hero.
//   - primaryConfirm → wpVerified fill, cream-50 text; baseline-save only.
//   - primaryMuted   → cream-50 opacity-0.4 fill, char-900 opacity-0.5 text; disabled state.
//   - primaryAlarm   → wpPrimary 135° gradient fill, cream-50 text, pill radius,
//                      coral-accent shadow; the single alarm-dismissal CTA.
//

import SwiftUI

struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = .wpCream50
    var foreground: Color = .wpChar900
    var gradient: LinearGradient? = nil
    var cornerRadius: CGFloat = WPRadius.md
    var font: Font = WPFont.body.font.bold()
    var isProminent: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(font)
            .frame(maxWidth: .infinity)
            .padding()
            .background(background)
            .foregroundStyle(foreground)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .opacity(buttonOpacity(pressed: configuration.isPressed))
            .scaleEffect(configuration.isPressed && isProminent ? 0.98 : 1.0)
            .wpShadow(isProminent ? .accent : .sm)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
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
    static var primaryMuted: PrimaryButtonStyle {
        PrimaryButtonStyle(tint: Color.wpCream50.opacity(0.4), foreground: .wpChar900.opacity(0.5))
    }

    /// Pill CTA for the alarm-ringing screen ("Prove you're awake") and
    /// disable-challenge capture step. Signature 135° gradient + coral glow.
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
