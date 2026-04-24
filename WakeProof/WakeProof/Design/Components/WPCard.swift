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
    @ViewBuilder let content: () -> Content

    init(padding: CGFloat = WPSpacing.xl2, @ViewBuilder content: @escaping () -> Content) {
        self.padding = padding
        self.content = content
    }

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
            .overlay(alignment: .top) {
                if colorScheme == .dark {
                    Rectangle()
                        .fill(Color.wpCream50.opacity(0.06))
                        .frame(height: 1)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: WPRadius.lg))
            .wpShadow(colorScheme == .light ? .md : .sm)
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
