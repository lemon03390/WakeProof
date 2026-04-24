//
//  WPCard.swift
//  WakeProof
//
//  Flat-fill container with 20pt radius + warm-tinted shadow-md. Adapts
//  to color scheme: light mode uses cream-50 fill; dark mode uses char-800
//  with an inset 1px hairline at the top (shadows don't read on warm
//  charcoal — hairline catches the eye instead) per README.md § "Borders,
//  cards, transparency".
//

import SwiftUI

struct WPCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let padding: CGFloat
    let content: () -> Content

    init(padding: CGFloat = WPSpacing.xl2, @ViewBuilder content: @escaping () -> Content) {
        self.padding = padding
        self.content = content
    }

    var body: some View {
        // Order matters: clipShape BEFORE overlay so the hairline paints on
        // top of the clipped fill. Reversing this would clip the hairline
        // by the rounded corners and trim the visible line at both ends —
        // exactly where the hairline reads strongest.
        let clipped = content()
            .padding(padding)
            .frame(maxWidth: .infinity)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: WPRadius.lg))
            .overlay(alignment: .top) {
                if colorScheme == .dark {
                    Rectangle()
                        .fill(Color.wpCream50.opacity(0.06))
                        .frame(height: 1)
                }
            }

        // Per README § "Borders, cards, transparency": dark cards have NO
        // shadow (warm-tinted shadows don't read on warm-charcoal). The
        // hairline above does the visual edge work instead.
        return Group {
            if colorScheme == .light {
                clipped.wpShadow(.md)
            } else {
                clipped
            }
        }
    }

    private var background: Color {
        colorScheme == .light ? .wpCream50 : .wpChar800
    }
}

#Preview("Light") {
    WPCard {
        VStack(alignment: .leading, spacing: WPSpacing.md) {
            Text("Card title").wpFont(.title3)
            Text("Card body in a flat cream-50 surface with warm shadow.")
                .wpFont(.body)
                .foregroundStyle(Color.wpChar500)
        }
    }
    .padding()
    .background(Color.wpCream100)
}

#Preview("Dark") {
    WPCard {
        VStack(alignment: .leading, spacing: WPSpacing.md) {
            Text("Card title").wpFont(.title3)
            Text("Card body on warm-charcoal with an inset hairline.")
                .wpFont(.body)
                .foregroundStyle(Color.wpCream50.opacity(0.75))
        }
    }
    .padding()
    .background(Color.wpChar900)
    .preferredColorScheme(.dark)
}
