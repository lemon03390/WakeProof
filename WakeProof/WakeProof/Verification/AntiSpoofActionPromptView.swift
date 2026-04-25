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
            Color.wpChar900.ignoresSafeArea()
            VStack(spacing: WPSpacing.xl) {
                Spacer()
                Text("Now:")
                    .wpFont(.title3)
                    .foregroundStyle(Color.wpCream50.opacity(0.7))
                Text(instruction)
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.wpCoral)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, WPSpacing.xl)
                Text("When you're ready, tap to re-capture.")
                    .wpFont(.subhead)
                    .foregroundStyle(Color.wpCream50.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, WPSpacing.xl2)
                Spacer()
                Button("I'm ready", action: onReady)
                    .buttonStyle(.primaryAlarm)
                    .padding(.horizontal, WPSpacing.xl2)
                    .padding(.bottom, WPSpacing.xl3)
            }
        }
        .preferredColorScheme(.dark)
    }
}
