# WakeProof Design System

> The design system for **WakeProof** — an iOS alarm that uses Claude Opus 4.7 vision to verify you're actually awake and out of bed. A self-commitment device, not a sleep tracker.

This folder is the source of truth for WakeProof's visual and verbal identity. It is consumed two ways:

1. **Designers** previewing components in the browser via `preview/*.html` cards (registered to the Design System tab).
2. **Claude Code sessions** inside the WakeProof iOS codebase, pulling tokens, copy rules, and component patterns to keep new SwiftUI surfaces coherent with the AppIcon.

---

## Product context

- **What it is.** WakeProof is a post-hackathon indie iOS app. The user signs a **wake-up contract** with themselves the night before; the next morning, the alarm only silences once Claude Opus 4.7 has compared a live photo to a baseline photo of the user's designated "awake-location" (kitchen, bathroom sink, desk). There is no dismiss button.
- **Positioning.** "A wake-up contract you can't unsign." NOT a sleep tracker. The interesting object is the contract, not the user's sleep.
- **Tone.** Serious about the contract, warm and generous about the reward. A verified morning is a fresh start, not a scorecard. A broken streak is "Streak reset — tomorrow's a fresh start", never shame.
- **Avoid.** Gamification (streaks are not points), emoji-heavy UI, cutesy copy, shame on reset. Cold blues/greens/greyscale — they break the AppIcon's warmth.

## Sources this system was built from

- `uploads/icon_1024.png` and `uploads/icon_180.png` — the AppIcon (cream bg, orange→coral gradient alarm clock with sparkles). The hard anchor for the palette.
- **GitHub repo:** [`lemon03390/WakeProof`](https://github.com/lemon03390/WakeProof) — Swift + SwiftUI codebase, iOS 17+. Design-relevant files read:
  - `WakeProof/WakeProof/App/PrimaryButtonStyle.swift` — the existing pill-button seed (primaryWhite / primaryConfirm / primaryMuted / primaryAlarm)
  - `WakeProof/WakeProof/Alarm/AlarmSchedulerView.swift` — home / scheduler Form
  - `WakeProof/WakeProof/Alarm/AlarmRingingView.swift` — the ring screen
  - `WakeProof/WakeProof/Alarm/DisableChallengeView.swift` — evening-self disable gate
  - `WakeProof/WakeProof/Alarm/StreakBadgeView.swift`, `StreakCalendarView.swift`, `InvestmentDashboardView.swift`
  - `WakeProof/WakeProof/Onboarding/OnboardingFlowView.swift`, `BaselinePhotoView.swift`
  - `README.md`, `CLAUDE.md`
- Reader of this README does not need repo access — all direct quotes / copy rules here are transcribed below. Path references are for contributors who also have the repo checked out.

## Index

| File | Purpose |
|---|---|
| `README.md` | This document — brand, voice, visual, iconography reference. |
| `colors_and_type.css` | CSS variable source-of-truth: palette, gradients, radii, shadows, type scale. Import this in every preview. |
| `SKILL.md` | Claude Code skill manifest — lets `wakeproof-design` be invoked from outside this project. |
| `assets/` | Raw brand assets — AppIcon at 180px and 1024px. |
| `preview/` | Individual HTML cards surfaced in the Design System tab. One concept per card. |
| `ui_kits/ios/` | Pixel-fidelity recreations of the seven priority iOS surfaces as HTML/JSX click-throughs, framed in an iOS bezel. Open `ui_kits/ios/index.html`. |

### Preview card index (Design System tab)

Every card lives at `preview/<name>.html` and is registered under one of five groups:

- **Brand** — `brand-app-icon`, `brand-voice`
- **Colors** — `colors-cream`, `colors-charcoal`, `colors-accent-gradient`, `colors-sunrise`, `colors-semantic`
- **Type** — `type-display`, `type-titles`, `type-body`
- **Spacing** — `spacing-scale`, `radii`, `shadows`
- **Components** — `button-primary-alarm`, `button-secondary`, `form-inputs`, `component-streak-badge`, `component-banners`, `component-calendar-cells`, `component-metric-row`

### For Claude Code sessions

`SKILL.md` at the folder root is the entry point when this system is invoked as a skill from the iOS codebase. It distills the non-negotiables (no pure white/black, 135° gradient, sentence case, no emoji, no gamification) plus ready-to-paste copy and a SwiftUI `Color` transcription of the palette.

---

## CONTENT FUNDAMENTALS

Voice is the most distinctive thing about WakeProof after the orange. These rules are lifted directly from the shipped Swift copy — every quote below is taken verbatim from the code.

### Core stance

- **Second-person, singular.** "Prove you're awake." "Meet yourself at the kitchen." "You'll take one live photo." The product talks *to* the user; it never refers to itself as "we" in instructional copy. The exception is the manifesto-style explainer: *"Claude Opus 4.7 is the witness."*
- **Future-self vs past-self is the core metaphor.** Copy assumes a three-character play: past-you (signs the contract), future-you (tries to cheat), witness (Claude). Example lines it enables:
  - *"An alarm your future self can't cheat."*
  - *"You'll set a contract with yourself…"*
  - *"Disabling requires the same proof as waking."*
- **Serious about the contract.** No softening, no hedging, no "try to". Imperatives: *"Prove you're awake."* *"Meet yourself at {location}."* *"Capture baseline."*
- **Warm about the reward.** The morning briefing, the streak badge, and weekly insights use observational language — never congratulatory. *"Streak reset — tomorrow's a fresh start."* *"Apple Clock doesn't know you. WakeProof has 3 of your mornings."*
- **No emoji.** None. The codebase has zero emoji in user-facing strings; do not add any.
- **No gamification vocabulary.** Never "points", "level up", "achievement", "unlock", "score". Streaks are surfaced as days, and only when non-zero. "Best: 4 days" appears as a subline, not a leaderboard.

### Casing

- **Sentence case everywhere.** *"Wake window."* *"First thing tomorrow."* *"Your commitment."* *"Alarm enabled."* Never Title Case For Labels.
- **App name is always `WakeProof`**, one word, both caps. Not "Wakeproof", not "WAKEPROOF".
- **Contractions are fine** — "can't", "you're", "couldn't", "we'll". They match the conversational second-person tone.

### Punctuation

- **Em-dash (—) is the signature connector.** Every banner and most secondary lines use one. *"Streak reset — tomorrow's a fresh start."* *"Apple Clock doesn't know you. WakeProof has N of your mornings."* *"Camera access is required to verify you're awake. Open Settings → WakeProof → Camera to enable, then return."*
- **Settings path uses → (right arrow).** *"Open Settings → WakeProof → Notifications."* Always in-line, never a button, to match iOS conventions.
- **Periods at end of every sentence**, including short imperative CTA labels inside an explainer paragraph. Button labels themselves do NOT get periods.

### Example copy (lifted from the repo — reuse as-is when the situation matches)

| Surface | Copy |
|---|---|
| Welcome hero | "An alarm your future self can't cheat." |
| Welcome body | "You'll set a contract with yourself: tomorrow morning, you will be out of bed at your designated wake-location. The only way to silence the alarm is to prove it. Claude Opus 4.7 is the witness." |
| Camera permission | "The contract needs a witness" / "When your alarm rings, you'll take one live photo at your designated wake-location. Claude Opus 4.7 checks you're actually there and actually awake. No photos leave your device except that single verification call." |
| Baseline prompt | "Pick the spot in your home where you will physically be when you successfully wake up — kitchen counter, bathroom sink, your desk. Capture it now in the lighting you'll see it in tomorrow morning." |
| Alarm ringing | "Meet yourself at {location}." / button: "Prove you're awake" |
| Disable gate | "Prove you're awake to disable." / "Meet yourself at {location} first — same as a morning ring." |
| Streak reset | "Streak reset — tomorrow's a fresh start." |
| Commitment framing | "Apple Clock doesn't know you. WakeProof has N of your mornings." |
| Banner (notifications off) | "Notifications are off — WakeProof can't reliably wake you. Open Settings → WakeProof → Notifications." |

### Banner / warning copy rules

1. State the consequence, not the cause. *"WakeProof can't reliably wake you."* — not *"Permission denied."*
2. End with an actionable path (Settings URL, retry prompt, or a reassurance: *"We'll retry next launch."*).
3. Three-tier priority, reflected by tone:
   - **Contract-breaking** (notifications off, audio broken): amber text, not red — the alarm CAN still fire, it just might not survive lock.
   - **Feature-degrading** (HealthKit unavailable, insights stale): secondary grey, soft phrasing ("last-night summary won't appear").
   - **Security** (UUID tampered): reinstall required, stated flatly, no exclamation mark. *"Security issue: reinstall WakeProof to regenerate identity."*

---

## VISUAL FOUNDATIONS

### Palette at a glance

The palette is a direct transcription of the AppIcon plus a minimal set of semantic supports. Nothing in this system is cold.

| Role | Token | Hex | Notes |
|---|---|---|---|
| Base background | `--wp-cream-100` | `#FBEEDB` | Matches the icon canvas exactly. Never use `#FFFFFF`. |
| Elevated card | `--wp-cream-50`  | `#FEF8ED` | Lifted surface, e.g. Form row in dark mode won't use this — it's a light-mode token. |
| Divider (cream) | `rgba(43, 31, 23, 0.10)` | — | Warm-tinted translucent. |
| Dark hero bg | `--wp-char-900` | `#2B1F17` | Replaces pure black on AlarmRingingView, MorningBriefingView, DisableChallengeView. |
| Deep dark | `--wp-char-950` | `#1A120C` | Only for the top of the sunrise gradient. |
| Primary text (light) | `--wp-char-900` | `#2B1F17` | |
| Secondary text | `--wp-char-500` | `#8A6B55` | Warm mid-grey; replaces SwiftUI's default `.secondary`. |
| Accent gradient start | `--wp-orange-500` | `#FFA047` | Top-left of the signature gradient. |
| Accent gradient end | `--wp-coral-500` | `#F54F4F` | Bottom-right. Also the solo "accent" color. |
| Verified | `--wp-verified-500` | `#4E8F47` | Warm leafy green — streak calendar fill. |
| Attempted (broke) | `--wp-attempted-500` | `#E07A2E` | Burnt amber — alarm fired but not verified. |

### Signature gradient

Direction **135°** (top-left → bottom-right), matching the icon ring:
```
linear-gradient(135deg, #FFA047 0%, #F54F4F 100%)
```
**Use for:** the primary alarm CTA ("Prove you're awake"), hero numerals (streak count, morning time), Claude's observation H1 in MorningBriefing. **Don't use for:** backgrounds (use the cream surface) or for long runs of text (use the coral solid).

### The "sunrise" gradient (reserved)

```
linear-gradient(180deg, #1A120C 0%, #6E3824 45%, #F38B4D 85%, #FBEEDB 100%)
```
**Reserved for a single moment:** the MorningBriefingView reveal after a VERIFIED verdict. This is the climax of the product — a 1200ms vertical wipe from warm-black to cream. It replaces the current static pure-black background and is the single biggest visual lever we have to carry the "sunrise ceremony" framing the designer flagged.

### Type

- **Display / hero**: SF Pro Rounded on-device. Web substitute: **Nunito 800** (from Google Fonts). Flagged substitution — if you have SF Pro Rounded TTF rights, drop them into `fonts/` and update `--wp-font-display`. The "rounded" aesthetic is load-bearing for WakeProof's warmth; do not substitute with Inter/Roboto.
- **Body**: SF Pro (system). Web stack falls back through `-apple-system, BlinkMacSystemFont, "SF Pro Text"`.
- **Hierarchy matches SwiftUI one-for-one**: `hero-xl` (88px, AlarmRingingView time), `hero` (64px, MorningBriefing H1), `display` (42px, Welcome title), `title-1` (34px) … `footnote` (13px). See `colors_and_type.css`.
- **Hero digits are tabular** (`font-variant-numeric: tabular-nums`) so streak counters and alarm times don't jitter.
- **Gradient-fill text** is applied sparingly — reserved for the morning hero digit, the streak current number, and `WakeProof` wordmark in onboarding.

### Spacing & radii

- 4pt base grid: `--wp-space-1` … `--wp-space-16`. Screen padding is `--wp-space-8` (32px). Section gap is `--wp-space-6` (24px) — matching `VStack(spacing: 24)` which appears throughout the Swift code.
- Radii: **10px** for form inputs, **14px** (`--wp-radius-md`) for standard buttons — rounded up from the Swift code's `12` to give the pill a softer read against cream, **20px** for cards, **28px** for hero surfaces (MorningBriefing), pill (`999px`) for the `primaryAlarm` CTA.

### Elevation

Three-level warm-tinted shadow system (all shadows use `rgba(43, 31, 23, ...)`, not black):
- `--wp-shadow-sm` — form rows, subtle lift
- `--wp-shadow-md` — cards, banners
- `--wp-shadow-lg` — hero briefing cards, fullscreen-over-fullscreen
- `--wp-shadow-accent` — the signature coral glow under the primary CTA

No inner shadows. No gloss. No borders as shadow substitutes.

### Backgrounds

- **Light surfaces**: flat cream (`--wp-cream-100`). No textures, no patterns, no hand-drawn illustrations. The icon itself is the only illustrative element in the product.
- **Dark / hero surfaces**: flat warm-charcoal (`--wp-char-900`) — with one exception, the MorningBriefing sunrise gradient.
- **Imagery**: the only images in the app are the user's own baseline photo and their morning verification photo. Both display in their natural colors, framed by a 16px rounded corner, with no filters applied. Warmth comes from the surrounding surface, not the image.

### Borders, cards, transparency

- Cards are **flat fill, 20px radius, no border**, elevated by `--wp-shadow-md`.
- On dark surfaces, cards use `--wp-char-800` fill; no shadow (shadows don't read on warm-charcoal) — instead a 1px inset `rgba(251, 238, 219, 0.06)` line at the top to catch the eye.
- Transparency: rare. Allowed for overlay dimmers (`rgba(26, 18, 12, 0.6)` over the sunrise), for pressed-state feedback (opacity 0.85 — matches `PrimaryButtonStyle.buttonOpacity`), and for translucent text on dark surfaces (`rgba(251, 238, 219, 0.75)` for secondary).
- **No backdrop-blur / glass.** The product is warm, not frosted. iOS `.thinMaterial` is only acceptable for the camera capture chrome where the OS demands it.

### Motion

Directly inherits SwiftUI defaults the existing code uses. Three easings:
- **Standard** `cubic-bezier(0.25, 0.1, 0.25, 1)` — default for all UI transitions.
- **Emphasize** `cubic-bezier(0.2, 0, 0, 1)` — the sunrise reveal, fresh-start moments.
- **Out** `cubic-bezier(0.33, 1, 0.68, 1)` — button releases, dismissals.

Durations: **120ms** (the exact value from `PrimaryButtonStyle`'s press animation), **240ms** base, **480ms** slow, **1200ms** hero. No bounces — this is a serious product; bouncing springs undermine the contract.

### Press / hover / active states

- **Press on primary CTA**: opacity 0.85 + 2% scale-down (matches the shipped `PrimaryButtonStyle`'s `isProminent` path). `scaleEffect(0.98)` for primary; non-prominent buttons drop scale and only fade.
- **Hover** (Mac Catalyst / web previews only): 4% darken via a `filter: brightness(0.96)`. iOS touch has no hover state by design.
- **Active row in Form**: cream-200 fill, no outline.
- **Disabled**: `--wp-fg-tertiary` text + 0.4 opacity on any background fill, matching `PrimaryButtonStyle.primaryMuted`.

### Layout rules

- Mobile canvas: **390 × 844** (iPhone 15). Hit targets ≥ **44px**.
- `NavigationStack` title bar uses the system default (large title inset 16px). Form sections use SwiftUI's default inset-grouped style — on cream, the inner row fill is `--wp-cream-50`.
- The alarm-ringing hero uses a centered single-column layout with `Spacer()` on both ends. The primary CTA sits `32px` above the safe-area bottom — copied straight from `AlarmRingingView`.
- `BaselinePhotoView` image preview has a **260px** max height with a **16px** rounded corner.

---

## ICONOGRAPHY

The iOS app currently uses **SF Symbols** exclusively — no bundled icon font, no custom SVG sprite. The only custom visual mark is the AppIcon itself (in `assets/`, copied from the Xcode `AppIcon.appiconset`).

### Approach

- On iOS: **Apple SF Symbols 5**, with `.font(.system(…))`-driven sizing to match text weight. The repo references only `lock.shield` (DisableChallengeView) and `checkmark` (StreakCalendarView) directly — the rest of the product is text-led.
- On web / previews: substitute with **Lucide Icons** (CDN) — the closest open-source match for SF Symbols' stroke weight. The small number of icons used (`shield-check`, `check`, `circle`, `chevron-right`) lets us side-step a full icon import.

  ```html
  <script src="https://unpkg.com/lucide@latest"></script>
  <i data-lucide="shield-check"></i>
  ```

  **Flagged substitution.** Lucide `shield-check` is visually close to SF Symbols `lock.shield` but not identical. If pixel parity is required for docs / marketing screenshots, export the SF Symbol directly from SF Symbols.app.
- **No emoji.** The codebase is emoji-free; do not introduce any.
- **No unicode icons** except the in-line arrow (→) in the Settings-path copy (*"Settings → WakeProof → Notifications"*). Treat → as a typographic character, not an icon.

### Brand imagery

The AppIcon is the only brand image. Two versions are kept in `assets/`:
- `assets/icon_1024.png` — canonical master (App Store size).
- `assets/icon_180.png` — @3x device size, the one you'll compose with in marketing surfaces.

The icon must never be placed on a non-cream background without a cream plate beneath it (it was designed as cream-on-cream; coral ring on a dark surface loses the clock-face-as-circle read).

---

## Iteration history / open questions

- **Fonts.** Nunito is our flagged web substitute for SF Pro Rounded. Please confirm whether you'd like me to try a different Google Fonts pick (candidates: Figtree 700, Plus Jakarta Sans 700 — both less round) or drop in SF Pro Rounded TTFs.
- **Sunrise gradient.** The 4-stop vertical gradient is a spec recommendation, not transcribed from the codebase. If you want a tighter / looser sunrise, say the word and I'll shift the stops.
- **Morning-briefing copy.** I have not yet seen `MorningBriefingView.swift` (not in the design-read set). The current UI-kit render uses observation-style copy modeled on the `weekly-insight-seed.json` tone; please verify against your intended MorningBriefing script.

