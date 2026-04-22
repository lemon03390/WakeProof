//
//  AntiSpoofActionPromptView.swift
//  WakeProof
//
//  Shown when Claude returns RETRY. The user is asked to perform a specific
//  random action (blink twice / show right hand / nod head) before re-capturing.
//  The next capture is then verified with the action included in the prompt so
//  Claude can confirm the action was performed — this is the load-bearing piece
//  against the photo-of-photo spoof. No cancel option — the alarm is unskippable.
//

import SwiftUI

struct AntiSpoofActionPromptView: View {

    let instruction: String
    let onReady: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 28) {
                Spacer()
                Text("Now:")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))
                Text(instruction)
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Text("When you're ready, tap to re-capture.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Spacer()
                Button("I'm ready", action: onReady)
                    .buttonStyle(.primaryAlarm)
                    .padding(.horizontal)
                    .padding(.bottom, 40)
            }
        }
    }
}
