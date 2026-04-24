---
name: wakeproof-design
description: Use this skill when designing or writing code for the WakeProof iOS app — a Claude-Opus-4.7-verified alarm. Loads color tokens, typography, button styles, copy voice rules, and component patterns so new surfaces stay coherent with the AppIcon and shipped views.
---

# WakeProof design system

WakeProof is an iOS 17+ SwiftUI app: **"an alarm your future self can't cheat."** The user signs a wake-up contract the night before; in the morning the alarm only silences when Claude Opus 4.7 verifies a live photo against a baseline photo of their wake-location. This skill gives you the visual and verbal rules to build new screens that fit.

## When to use this skill

- Adding a new SwiftUI view or extending one in the `WakeProof` Xcode project.
- Writing any user-facing copy — banners, empty states, permission prompts, push notifications, weekly insights.
- Producing marketing or docs artifacts (screenshots, landing page) that need to match the app.
- Reviewing a PR against design intent.

If the user asks for something unrelated to WakeProof, don't invoke this skill.

## How to use it

1. **Start by reading `README.md`** in this folder — it's the source of truth for voice, palette, type, elevation, motion, and iconography, and it links to the preview cards for visual reference.
2. **Import `colors_and_type.css`** if you're building an HTML/web surface. For SwiftUI, transcribe the same hex values into a `Color` extension (see snippet below) — do not invent new colors.
3. **Browse `preview/*.html`** to see how each token and component renders. Each card is 700px wide, named by what it shows. Relevant cards for common tasks:
   - New screen with a primary action → `button-primary-alarm.html`, `button-secondary.html`
   - New list/form → `form-inputs.html`, `component-metric-row.html`
   - Streak UI → `component-streak-badge.html`, `component-calendar-cells.html`
   - Any banner or error state → `component-banners.html`
   - Copy voice check → `brand-voice.html`
4. **Browse `ui_kits/ios/index.html`** for a device-framed click-through of the seven shipped screens. When extending an existing view, match the layout, spacing, and copy tone of its neighbors.

## Non-negotiables (the five things most likely to drift)

1. **Never use pure white or pure black.** Light bg = `#FBEEDB` (cream-100). Dark bg = `#2B1F17` (char-900). These are the only two root surfaces.
2. **The primary gradient is 135°, orange → coral, `#FFA047 → #F54F4F`.** Reserved for hero numerals, the alarm CTA, and the wordmark. Not for long runs of text, not for backgrounds.
3. **Sentence case, no emoji, em-dash is the signature punctuation.** "Streak reset — tomorrow's a fresh start." Never "Streak Reset! 🎉".
4. **The alarm CTA is always `primaryAlarm` — 60px pill, gradient fill, coral shadow, label "Prove you're awake".** Do not introduce new alarm-dismissal buttons.
5. **No gamification vocabulary.** Streaks are surfaced as days ("4-day streak") — never "points", "level", "unlock", "achievement", "score".

## Copy starter snippets (lift these when the situation matches)

| Situation | Copy |
|---|---|
| Primary alarm CTA | "Prove you're awake" |
| Meet prompt (alarm + disable) | "Meet yourself at {location}." |
| Broken streak | "Streak reset — tomorrow's a fresh start." |
| Notifications off banner | "Notifications are off — WakeProof can't reliably wake you. Open Settings → WakeProof → Notifications." |
| Commitment framing | "Apple Clock doesn't know you. WakeProof has {N} of your mornings." |

Full list in `README.md` → "Example copy".

## SwiftUI color transcription

When you need tokens inside Swift, mirror the CSS variables 1:1 so both surfaces agree:

```swift
extension Color {
    static let wpCream100 = Color(red: 0.984, green: 0.933, blue: 0.859)  // #FBEEDB
    static let wpCream50  = Color(red: 0.996, green: 0.973, blue: 0.929)  // #FEF8ED
    static let wpChar900  = Color(red: 0.169, green: 0.122, blue: 0.090)  // #2B1F17
    static let wpChar500  = Color(red: 0.541, green: 0.420, blue: 0.333)  // #8A6B55
    static let wpOrange   = Color(red: 1.000, green: 0.627, blue: 0.278)  // #FFA047
    static let wpCoral    = Color(red: 0.961, green: 0.310, blue: 0.310)  // #F54F4F
    static let wpVerified = Color(red: 0.306, green: 0.561, blue: 0.278)  // #4E8F47
}

extension LinearGradient {
    static let wpPrimary = LinearGradient(
        colors: [.wpOrange, .wpCoral],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
}
```

## What to do when the spec is silent

1. Look for the nearest shipped parallel in `ui_kits/ios/screens.jsx` or the repo's `*/Alarm/*.swift` files, and match its spacing, typography, and copy tone.
2. If there's still no match, pick the simpler option — this product earns trust through restraint.
3. Ask the user before inventing a new color, icon set, or voice register.
