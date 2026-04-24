//
//  WPSection.swift
//  WakeProof
//
//  Titled content group. Caption-styled label + 8pt gap + slotted content.
//  Used on the home surface for organizing commitment note, streak, next
//  fire, and sharing rows. Section is NOT a Card — it's a header + child;
//  compose `WPSection { WPCard { ... } }` when the child needs elevation.
//
//  The title input is sentence-case copy (e.g. "First thing tomorrow"); the
//  view renders it uppercased with .tracking(1.5) per design-system caption
//  style, so callers don't need to think about casing. This matches
//  README § "Casing" — the SOURCE is sentence case, the RENDERING is caps.
//

import SwiftUI

struct WPSection<Content: View>: View {
    let title: String
    let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WPSpacing.sm) {
            Text(title.uppercased())
                .wpFont(.caption)
                .tracking(1.5)
                .foregroundStyle(Color.wpChar500)
            content()
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: WPSpacing.xl) {
        WPSection("First thing tomorrow") {
            WPCard {
                Text("Call Mom back").wpFont(.title3)
            }
        }
        WPSection("Wake window") {
            WPCard {
                Text("06:30").wpFont(.display)
            }
        }
    }
    .padding()
    .background(Color.wpCream100)
}
