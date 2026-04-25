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

    /// UAT 缺點 1 (Wave 3.5, 2026-04-26): half-awake users staring at "Verifying
    /// you're awake…" for 5–10 seconds with no progress signal start to wonder
    /// if it's stuck and may force-quit. A progressive copy that updates after
    /// 5s / 10s reassures them the check is in flight without claiming a fake
    /// percentage. The Claude vision call typically returns in 5–8s; the
    /// 10s+ branch covers slow networks.
    @State private var elapsed: TimeInterval = 0

    private var progressCopy: String {
        switch elapsed {
        case ..<5:
            return "Verifying you're awake…"
        case 5..<10:
            return "Comparing your photo to your baseline…"
        default:
            return "Almost there — Claude is finalising the verdict…"
        }
    }

    var body: some View {
        ZStack {
            Color.wpChar900.ignoresSafeArea()
            VStack(spacing: WPSpacing.xl) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 80))
                    .foregroundStyle(Color.wpCream50)
                    .symbolEffect(.pulse, options: .repeating)
                Text(progressCopy)
                    .wpFont(.title2)
                    .foregroundStyle(Color.wpCream50)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, WPSpacing.xl2)
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
        .task {
            // Tick `elapsed` once per second so the progressCopy switch
            // re-evaluates. Cancellation on view teardown is automatic via
            // `.task` semantics; no manual cleanup needed.
            let start = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                elapsed = Date().timeIntervalSince(start)
            }
        }
    }
}
