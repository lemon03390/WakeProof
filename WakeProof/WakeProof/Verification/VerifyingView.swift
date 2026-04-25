//
//  VerifyingView.swift
//  WakeProof
//
//  The in-between UI: Claude is thinking, alarm volume is reduced but audible,
//  user is not given any action. No dismiss button — this view is intentionally
//  non-interactive. The verifier's state transition pops it.
//

import SwiftUI

struct VerifyingView: View {

    @Environment(VisionVerifier.self) private var verifier

    var body: some View {
        ZStack {
            Color.wpChar900.ignoresSafeArea()
            VStack(spacing: WPSpacing.xl) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 80))
                    .foregroundStyle(Color.wpCream50)
                    .symbolEffect(.pulse, options: .repeating)
                Text("Verifying you're awake…")
                    .wpFont(.title2)
                    .foregroundStyle(Color.wpCream50)
                if verifier.currentAttemptIndex > 1 {
                    Text("Retry \(verifier.currentAttemptIndex - 1) of 1")
                        .wpFont(.subhead)
                        .foregroundStyle(Color.wpCream50.opacity(0.7))
                }
                if let err = verifier.lastError {
                    Text(err)
                        .wpFont(.footnote)
                        .foregroundStyle(Color.wpAttempted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, WPSpacing.xl2)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
