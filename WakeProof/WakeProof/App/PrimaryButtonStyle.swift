//
//  PrimaryButtonStyle.swift
//  WakeProof
//
//  Shared pill button style used by every "next-step" CTA across onboarding,
//  baseline capture, and the alarm-ringing screen. Standardising here locks
//  visual consistency before the verification UI multiplies the call sites.
//

import SwiftUI

struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = .white
    var foreground: Color = .black
    var cornerRadius: CGFloat = 12
    var font: Font = .body.bold()
    var isProminent: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(font)
            .frame(maxWidth: .infinity)
            .padding()
            .background(tint)
            .foregroundStyle(foreground)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .opacity(buttonOpacity(pressed: configuration.isPressed))
            .scaleEffect(configuration.isPressed && isProminent ? 0.98 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private func buttonOpacity(pressed: Bool) -> Double {
        pressed ? 0.85 : 1.0
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    /// White pill on black background. Default CTA.
    static var primaryWhite: PrimaryButtonStyle { PrimaryButtonStyle() }

    /// Green confirmation CTA used on the baseline-save action.
    static var primaryConfirm: PrimaryButtonStyle {
        PrimaryButtonStyle(tint: .green, foreground: .black)
    }

    /// Disabled / inactive form. Renders the same shape but visually muted.
    static var primaryMuted: PrimaryButtonStyle {
        PrimaryButtonStyle(tint: Color.white.opacity(0.4), foreground: .black)
    }

    /// Larger CTA used on the alarm-ringing screen ("Prove you're awake").
    static var primaryAlarm: PrimaryButtonStyle {
        PrimaryButtonStyle(cornerRadius: 16, font: .title3.bold(), isProminent: true)
    }
}
