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
            Color.black.ignoresSafeArea()
            VStack(spacing: 24) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 80))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, options: .repeating)
                Text("Verifying you're awake…")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                if verifier.currentAttemptIndex > 1 {
                    Text("Retry \(verifier.currentAttemptIndex - 1) of 1")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                }
                if let err = verifier.lastError {
                    Text(err)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }
        }
    }
}
