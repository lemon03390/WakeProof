# WakeProof UI Rewrite — Phase 1-6 Implementation Plan

> **For agentic workers:** Use `subagent-driven-development` skill to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Phase gates are hard checkpoints — do NOT advance past a gate that has not passed. Each subagent MUST invoke the `wakeproof-design` skill before touching any file — it loads the locked design tokens, voice rules, and SwiftUI Color extension snippet that is the source of truth for this work.

**Goal:** Migrate all 11 shipped SwiftUI surfaces from "5-day hackathon" visual quality to "App Store ready" using the locked `docs/design-system/` token system (cream `#FBEEDB` + warm charcoal `#2B1F17` + orange-coral gradient `#FFA047→#F54F4F`, SF Pro Rounded typography, 4pt grid, warm-shadow elevation). Each surface uses shared tokens + a shared component library — no more scattered `.white.opacity(0.7)` constants, no more pure `Color.black`/`Color.white`, no more per-view `.system(size: N)` picks.

**Architecture:** Six sequential phases. Phase 1 lays down 6 token files and migrates `PrimaryButtonStyle` to consume them. Phase 2 builds 5 reusable SwiftUI components on those tokens (WPCard / WPSection / WPMetricCard / WPHeroTimeDisplay / WPStreakBadge). Phases 3-6 rewrite the 11 surfaces using the tokens + components while preserving every `@State` / `@Binding` / `@Query` / `@AppStorage` wire and every Wave 5 business-logic path (H1-H5, G1, G3). Token transcription is deterministic (copy-paste from `docs/design-system/SKILL.md` line 55-72 + `colors_and_type.css`); surface rewrites are judgement work that leans on the `ui_kits/ios/` mockups and the `preview/*.html` reference cards.

**Tech Stack:** Swift + SwiftUI (iOS 17+), `@Observable` + `@MainActor`, `async/await`, `Logger` from `os`. No bundled fonts (SF Pro Rounded is a system family), no new SPM deps, no analytics, no new backend. All invariants from `CLAUDE.md` apply (no `!`, no `print`, no hardcoded API keys, no `--no-verify`, no `git push` without user confirmation).

**Non-goals for this plan (out of scope — do not touch):**
- Wave 5 business logic: H1 vision prompt, H2 commitment note model (`WakeWindow.commitmentNote`), H3 `StreakService` algorithm, H4 metric computation (`InvestmentDashboardModel`), H5 share gate (`ShareCardModel.shouldShowShareButton`), G1 disable-challenge transitions (`AlarmScheduler.requestDisable` / `beginDisableChallenge` / `disableChallengeSucceeded`), G3 chained backup notification identifiers.
- `Services/ClaudeAPIClient.swift` split (730 LOC — post-hackathon debt).
- SwiftData `@Model` schema changes (any new field / new model forces a schema migration).
- New permissions / new `Info.plist` entries.
- `Assets.xcassets/AppIcon.appiconset/` — just committed in `4cd3991`, do not overwrite.
- Bundled Nunito fonts (design system explicitly says iOS uses SF Pro Rounded; Nunito is a web-only fallback).
- Prompt template edits (v3 SHA-256 snapshot test would break; `scripts/layer2-smoke.py` reference constant is frozen).
- Any `git push` — per `CLAUDE.md`, requires explicit user confirmation at end of plan (Phase 9).
- New analytics / tracking / Supabase / Cloudflare / Vercel integration.

---

## Invariants (must hold at every commit)

1. **Test count**: 366/0 baseline + tokens-phase additions. Never regressed. Every task's "verify" step runs the full suite:
   ```bash
   xcodebuild -project WakeProof/WakeProof.xcodeproj -scheme WakeProof -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' test 2>&1 > /tmp/ui-test.log
   grep -cE " passed on " /tmp/ui-test.log   # expect: 366 before phase 1 / ≥ 366 after tokens
   grep -E "TEST SUCCEEDED|TEST FAILED" /tmp/ui-test.log | tail -1   # expect: ** TEST SUCCEEDED **
   ```
2. **No force unwraps** in non-test code (`!` only in `WakeProofTests/`).
3. **All logging via `Logger(subsystem: LogSubsystem.<domain>, category: "...")`** — never `print()`.
4. **No API keys** outside `Services/Secrets.swift` (git-ignored).
5. **No emoji** in user-facing strings.
6. **No pure `Color.black` / `Color.white`** in any new or rewritten view — use tokens.
7. **Voice rules** per `docs/design-system/README.md` §CONTENT FUNDAMENTALS: second-person singular, sentence case, em-dash as signature connector, future-self metaphor, no gamification vocabulary.
8. **Wave 5 wiring preserved** — every `@State` / `@Binding` / `@AppStorage` / `@Query` / `.onChange` / `.onAppear` / `.task` observer that drives Wave 5 behaviour stays functionally identical. Visual re-skinning is free; wiring re-plumbing is out of scope.
9. **No `git push`** until Phase 9 user confirmation.
10. **Xcode project integration**: this project uses Xcode 16's `PBXFileSystemSynchronizedRootGroup` (`WakeProof.xcodeproj/project.pbxproj` lines 24-35). `WakeProof/WakeProof/` and `WakeProofTests/` are synchronized folders — any `.swift` file added anywhere under them is auto-compiled. **DO NOT** manually edit `project.pbxproj` to add new files; just create them on disk.

---

## File Structure

### New files (Phase 1 + Phase 2)

| Path | Phase | Responsibility |
|---|---|---|
| `WakeProof/WakeProof/Design/Tokens/Color+WakeProof.swift` | 1 | `Color` extension with 12 brand tokens (cream 50/100/200, char 300/500/800/900/950, orange, coral, verified, attempted). sRGB literal specified via `/255.0` for byte-perfect fidelity. |
| `WakeProof/WakeProof/Design/Tokens/Gradient+WakeProof.swift` | 1 | `LinearGradient` extension: `wpPrimary` (135° orange→coral), `wpSunrise` (180° 4-stop char900→rust→peach→cream100 for MorningBriefing reveal; rust/peach inlined hexes). |
| `WakeProof/WakeProof/Design/Tokens/Spacing.swift` | 1 | `WPSpacing` enum with 4pt grid (xs1=4 … xl5=64). Pure CGFloat constants — no view-modifier sugar in this file. |
| `WakeProof/WakeProof/Design/Tokens/Typography.swift` | 1 | `WPFont` enum mapping 11 roles (heroXL/hero/display/title1-3/headline/body/callout/subhead/footnote/caption) → `Font`. Display roles use `.system(design: .rounded)`; body roles use default. Tabular numerals applied to hero-xl/hero/display via `.monospacedDigit()` helper. |
| `WakeProof/WakeProof/Design/Tokens/Radii.swift` | 1 | `WPRadius` enum (xs=6, sm=10, md=14, lg=20, xl=28, pill=999). |
| `WakeProof/WakeProof/Design/Tokens/Shadows.swift` | 1 | `WPShadow` ViewModifier + `.wpShadow(.md)` etc. modifier helpers. All shadows use `rgba(43, 31, 23, α)` warm tint (NOT black). `accent` variant uses coral at α=0.25. |
| `WakeProof/WakeProof/Design/Components/WPCard.swift` | 2 | Container: cream-50 fill on light / char-800 on dark, 20pt radius, shadow-md on light / no shadow + 1px inset hairline on dark. `init(padding: CGFloat = WPSpacing.xl2) { ... }` with explicit slot. (32pt matches "screen padding" semantic; 48pt would be too generous as default.) |
| `WakeProof/WakeProof/Design/Components/WPSection.swift` | 2 | Titled section: caption-case label + 24pt gap + slot content. Used for grouping home rows. |
| `WakeProof/WakeProof/Design/Components/WPMetricCard.swift` | 2 | `(value: String, label: String, accent: Bool)` → hero numeral (42pt rounded) + caption label. Used by InvestmentDashboardView. |
| `WakeProof/WakeProof/Design/Components/WPHeroTimeDisplay.swift` | 2 | 88pt rounded tabular time display driven by `TimelineView(.periodic(from: .now, by: 1))`. Extracted from AlarmRingingView — same visual, reusable for home. Accepts a `style: .large / .medium` param so home can show 64pt while alarm-ring stays 88pt. |
| `WakeProof/WakeProof/Design/Components/WPStreakBadge.swift` | 2 | Evolved replacement for `StreakBadgeView`. Preserves `static func shouldRender(currentStreak:bestStreak:) -> Bool` public API. New visual built on tokens: wpVerified-filled pill for active streak, wpChar500 outline for dormant. |

### Modified files (Phase 1 migration + Phase 3-6 surfaces)

| Path | Phase | Scope |
|---|---|---|
| `WakeProof/WakeProof/App/PrimaryButtonStyle.swift` | 1 | Migrate 4 variants (primaryWhite/primaryConfirm/primaryMuted/primaryAlarm) to use Phase-1 tokens. `cornerRadius` default changes `12 → 14` (WPRadius.md); primaryAlarm uses pill radius. Foreground/background colors resolve against color scheme (light: wpCream50 fill + wpChar900 text; dark: wpCream50 fill + wpChar900 text unchanged — button is always light on dark hero screens). primaryConfirm moves from `.green` → `wpVerified`. **Semantic names kept for call-site stability** (every existing `.buttonStyle(.primaryAlarm)` call site continues to compile). |
| `WakeProof/WakeProof/Alarm/AlarmSchedulerView.swift` | 3 | Form → hero layout. Preserve all @State / @Binding / @Query / @AppStorage / .onChange / .onAppear / .task wiring exactly as-is. Wave 5 G1 proxy binding (`isEnabled` intercept), H3 recompute observer (`wakeAttempts.count`), H2 commitment note (`WakeWindow.commitmentNote` persistence), H5 share toggle (`ShareCardModel.shareCardEnabledKey`), DEBUG bypass (`AlarmScheduler.disableChallengeBypassKey`) — all preserved with byte-identical behaviour. |
| `WakeProof/WakeProof/Verification/MorningBriefingView.swift` | 4 | Ring reveal animation (opacity + scale), commitment-note spring-in, observation typewriter/fade. Preserve full prop list (`result: BriefingResult?`, `observation: String?`, `commitmentNote: String?`, `currentStreak: Int`, `onDismiss: () -> Void`), preserve `@AppStorage(ShareCardModel.shareCardEnabledKey)` + `@State shareCardFailed` + `makeShareImage()` logic exactly. |
| `WakeProof/WakeProof/Onboarding/OnboardingFlowView.swift` | 5 | Brand intro, permission primer visual pass. No new steps, no new permissions. |
| `WakeProof/WakeProof/Onboarding/BaselinePhotoView.swift` | 5 | Location-concept explainer + capture ritual framing. |
| `WakeProof/WakeProof/Onboarding/BedtimeStep.swift` | 5 | Visual polish. |
| `WakeProof/WakeProof/Alarm/AlarmRingingView.swift` | 6 | Replace `Color.black` → `wpChar900`; use `WPHeroTimeDisplay(style: .large)`; migrate spacing + typography. `primaryAlarm` CTA unchanged semantically (copy: "Prove you're awake"). |
| `WakeProof/WakeProof/Alarm/DisableChallengeView.swift` | 6 | Ritual framing. Two-step (explainer → capture) flow preserved. |
| `WakeProof/WakeProof/Alarm/StreakCalendarView.swift` | 6 | Month grid — wpVerified fill for verified days, wpAttempted for attempted-not-verified, wpChar500 outline for absent. |
| `WakeProof/WakeProof/Alarm/InvestmentDashboardView.swift` | 6 | Use WPMetricCard; replace `.white.opacity(...)` with tokens. |
| `WakeProof/WakeProof/Verification/AntiSpoofActionPromptView.swift` | 6 | Softer retry tone. |
| `WakeProof/WakeProof/Verification/WeeklyInsightView.swift` | 6 | Token migration. |
| `WakeProof/WakeProof/Alarm/StreakBadgeView.swift` | 6 | Deprecate file; forward the static `shouldRender(...)` helper to `WPStreakBadge.shouldRender(...)` so AlarmSchedulerView's current call sites continue to work until we migrate them. Fold into WPStreakBadge in Phase 6. |
| `WakeProof/WakeProof/Alarm/ShareCardView.swift` | 6 | Rendered 1080×1920 share card — migrate palette to tokens. `ImageRenderer` logic preserved. |

### Test files (Phase 1 + Phase 2)

| Path | Phase | Responsibility |
|---|---|---|
| `WakeProof/WakeProofTests/Design/ColorTokensTests.swift` | 1 | 12 tests (one per color token) — unpack `UIColor(Color)` sRGB components, assert byte-equivalence to hex spec within 0.01 accuracy. |
| `WakeProof/WakeProofTests/Design/GradientTests.swift` | 1 | Construction smoke tests for wpPrimary / wpSunrise — verify stop count + direction. |
| `WakeProof/WakeProofTests/Design/SpacingScaleTests.swift` | 1 | Assert WPSpacing constants are exact 4pt multiples. |
| `WakeProof/WakeProofTests/Design/TypographyTests.swift` | 1 | Font design family smoke — assert hero/display roles use `.rounded` via `Font` description equality where possible. Pragmatic: at minimum verify the enum exists with all 11 cases. |
| `WakeProof/WakeProofTests/Design/ComponentSmokeTests.swift` | 2 | Smoke tests — construct WPCard/WPSection/WPMetricCard/WPHeroTimeDisplay/WPStreakBadge without crash. Verify `WPStreakBadge.shouldRender` matches the old `StreakBadgeView.shouldRender` behavior for 4 cases (both-0, current>0 bestAny, current=0 best>0, current<0 defensive). |

---

## Risks & known drift points

1. **Wave 5 @State/@Binding/@Query rewiring** — AlarmSchedulerView Phase 3 is the largest regression risk surface. Mitigations:
   - Copy the existing wiring block (`@Environment`, `@Query`, `@State`, `@AppStorage`) verbatim into the rewritten view's header.
   - Preserve the G1 proxy `Binding(get:set:)` pattern exactly.
   - Preserve `.onChange(of: wakeAttempts.count)`, `.onChange(of: scheduler.window.isEnabled)`, `.onAppear(perform: loadFromScheduler)`, `.onAppear(perform: refreshDroppedMemoryCount)`, `.onAppear(perform: recomputeStreak)`, `.task { await refreshOvernightStartError() }`.
   - `save()` / `handleDisableRequest()` / `recomputeStreak()` / `systemBanner` private helpers move to the new view body unchanged.

2. **Form → ScrollView behaviour drift** — SwiftUI `Form` provides keyboard avoidance, section grouping, safe-area handling for free. Moving to `ScrollView + VStack`:
   - Use `.scrollDismissesKeyboard(.interactively)` on ScrollView.
   - Wrap TextField sections in a container that pads for keyboard (`.padding(.bottom, keyboardHeight)` via `@FocusState` OR use iOS 16.4's `.scrollContentBackground(.hidden)` trick on a Form kept for the TextField section only).
   - Pragmatic: if keyboard avoidance gets finicky, keep the commitment-note section as a compact `Form` and use ScrollView + VStack for the rest.

3. **Dark-mode introduction on hero surfaces** — AlarmRingingView, MorningBriefingView, DisableChallengeView currently hard-code `Color.black`. Strategy:
   - These are ALWAYS-DARK hero screens by design (they run when the user just woke / needs focus). Apply `.preferredColorScheme(.dark)` to the hero views and replace `Color.black` → `Color.wpChar900`.
   - Do NOT introduce a system-respecting light mode on these hero surfaces in this plan (would need fresh copy, fresh spacing, fresh hero decisions — outside scope).
   - Home + onboarding surfaces respect system color scheme.

4. **H1 observation layout robustness** — the 30-60 char observation from Opus 4.7 can be CJK or English. Any MorningBriefing layout must:
   - Use `.lineLimit(nil)` + `.fixedSize(horizontal: false, vertical: true)` on the observation text.
   - Use `.multilineTextAlignment(.center)`.
   - Use horizontal padding `WPSpacing.xl4` (32pt) for safe iPhone SE readability.
   - Smoke-test with both English (~60 chars) and Chinese (~30 chars) sample text.

5. **ImageRenderer share-card drift** — H5 renders a 1080×1920 share card offscreen via `ImageRenderer`. After Phase 6 migration to tokens, re-verify render on iPhone 15/SE/15 Pro Max. The existing `shareCardFailed` @State latch + `.fault` log remains — surfacing render failure via DEBUG reason-tag.

6. **Permission primer / systemPermission alert timing** — `OnboardingFlowView` primers sit just before the system permission alert. Phase 5 visual polish MUST NOT move or re-wrap the primer → primer_dismiss → systemPermission_request sequence. Time-to-alert is permission-grant-rate load-bearing.

7. **AlarmScheduler `disableChallengeBypassKey` / `ShareCardModel.shareCardEnabledKey`** — `@AppStorage` keys are already extracted as static constants (Wave 5 review fixed this). Phase 3 must preserve these constant references, not hardcode the key strings.

8. **`@Observable` + `@MainActor`** — zero-exception rule. Any new `@Observable` class (even if this plan doesn't introduce one) must be `@MainActor`. Phase 1-2 does NOT introduce any `@Observable` class — components are stateless views, tokens are static constants.

---

## Phase 1 — Design Tokens + PrimaryButtonStyle Migration

**Phase gate — must hold before advancing to Phase 2:**
- All 6 token files compile (simulator build succeeds).
- `PrimaryButtonStyle` uses Phase-1 tokens (no new visual regressions in onboarding / baseline / alarm-ring).
- Test count ≥ 366 + new token tests (target: ~380).
- `git log --oneline` shows one commit per task.

**Every subagent dispatched for this phase starts with:** invoke `wakeproof-design` skill, then read SKILL.md line 55-72 for the Color extension, then read `colors_and_type.css` for the full token set.

### Task 1.1: Color+WakeProof.swift — 12 brand color tokens + tests

**Files:**
- Create: `WakeProof/WakeProof/Design/Tokens/Color+WakeProof.swift`
- Create: `WakeProof/WakeProofTests/Design/ColorTokensTests.swift`

- [ ] **Step 1: Invoke `wakeproof-design` skill** so tokens + voice rules are in context.

- [ ] **Step 2: Create the Tokens directory**

  ```bash
  mkdir -p WakeProof/WakeProof/Design/Tokens
  mkdir -p WakeProof/WakeProofTests/Design
  ```

- [ ] **Step 3: Write failing tests (`WakeProof/WakeProofTests/Design/ColorTokensTests.swift`)**

  ```swift
  import XCTest
  import SwiftUI
  import UIKit
  @testable import WakeProof

  /// Verifies every `wp*` color token resolves to the documented hex value in
  /// `docs/design-system/SKILL.md` § "SwiftUI color transcription" and
  /// `colors_and_type.css`. sRGB components are unpacked via `UIColor(Color)`
  /// and compared byte-wise with 0.01 accuracy (covers the 3-decimal rounding
  /// in the source spec).
  final class ColorTokensTests: XCTestCase {
      private func srgb(_ color: Color) -> (r: Double, g: Double, b: Double) {
          var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
          UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
          return (Double(r), Double(g), Double(b))
      }

      private func assertHex(_ color: Color, _ r: Int, _ g: Int, _ b: Int, file: StaticString = #file, line: UInt = #line) {
          let rgb = srgb(color)
          XCTAssertEqual(rgb.r, Double(r) / 255.0, accuracy: 0.01, "red channel", file: file, line: line)
          XCTAssertEqual(rgb.g, Double(g) / 255.0, accuracy: 0.01, "green channel", file: file, line: line)
          XCTAssertEqual(rgb.b, Double(b) / 255.0, accuracy: 0.01, "blue channel", file: file, line: line)
      }

      func testCream100_FBEEDB()  { assertHex(.wpCream100, 0xFB, 0xEE, 0xDB) }
      func testCream50_FEF8ED()   { assertHex(.wpCream50,  0xFE, 0xF8, 0xED) }
      func testCream200_F5E3C7()  { assertHex(.wpCream200, 0xF5, 0xE3, 0xC7) }
      func testChar950_1A120C()   { assertHex(.wpChar950,  0x1A, 0x12, 0x0C) }
      func testChar900_2B1F17()   { assertHex(.wpChar900,  0x2B, 0x1F, 0x17) }
      func testChar800_3D2D22()   { assertHex(.wpChar800,  0x3D, 0x2D, 0x22) }
      func testChar500_8A6B55()   { assertHex(.wpChar500,  0x8A, 0x6B, 0x55) }
      func testChar300_B89A82()   { assertHex(.wpChar300,  0xB8, 0x9A, 0x82) }
      func testOrange_FFA047()    { assertHex(.wpOrange,   0xFF, 0xA0, 0x47) }
      func testCoral_F54F4F()     { assertHex(.wpCoral,    0xF5, 0x4F, 0x4F) }
      func testVerified_4E8F47()  { assertHex(.wpVerified, 0x4E, 0x8F, 0x47) }
      func testAttempted_E07A2E() { assertHex(.wpAttempted,0xE0, 0x7A, 0x2E) }
  }
  ```

- [ ] **Step 4: Run tests — expect FAIL** (symbol `Color.wpCream100` not defined)

  ```bash
  xcodebuild -project WakeProof/WakeProof.xcodeproj -scheme WakeProof -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing WakeProofTests/ColorTokensTests 2>&1 | tail -20
  ```
  Expected: compile error "Value of type 'Color' has no member 'wpCream100'".

- [ ] **Step 5: Implement `Color+WakeProof.swift`** — literal transcription from `docs/design-system/colors_and_type.css` + `SKILL.md` line 55-72. Use `/255.0` so hex → sRGB is byte-exact.

  ```swift
  //
  //  Color+WakeProof.swift
  //  WakeProof
  //
  //  Brand color tokens transcribed literally from docs/design-system/colors_and_type.css.
  //  Source of truth for palette. Do not invent new colors in this file — new tokens must
  //  first be added to the CSS source and design-system preview cards, then mirrored here.
  //  SKILL.md § "SwiftUI color transcription" shows the same snippet with 3-decimal
  //  rounding; this file uses `/255.0` for byte-exact hex correspondence.
  //

  import SwiftUI

  extension Color {
      // Cream surface — the icon's background. NOT pure white.
      static let wpCream50  = Color(red: 0xFE / 255.0, green: 0xF8 / 255.0, blue: 0xED / 255.0)  // #FEF8ED
      static let wpCream100 = Color(red: 0xFB / 255.0, green: 0xEE / 255.0, blue: 0xDB / 255.0)  // #FBEEDB
      static let wpCream200 = Color(red: 0xF5 / 255.0, green: 0xE3 / 255.0, blue: 0xC7 / 255.0)  // #F5E3C7

      // Warm charcoal — the icon's dark mark. NOT pure black.
      static let wpChar950 = Color(red: 0x1A / 255.0, green: 0x12 / 255.0, blue: 0x0C / 255.0)   // #1A120C
      static let wpChar900 = Color(red: 0x2B / 255.0, green: 0x1F / 255.0, blue: 0x17 / 255.0)   // #2B1F17
      static let wpChar800 = Color(red: 0x3D / 255.0, green: 0x2D / 255.0, blue: 0x22 / 255.0)   // #3D2D22
      static let wpChar500 = Color(red: 0x8A / 255.0, green: 0x6B / 255.0, blue: 0x55 / 255.0)   // #8A6B55
      static let wpChar300 = Color(red: 0xB8 / 255.0, green: 0x9A / 255.0, blue: 0x82 / 255.0)   // #B89A82

      // Accent — the icon's orange→coral gradient stops.
      static let wpOrange = Color(red: 0xFF / 255.0, green: 0xA0 / 255.0, blue: 0x47 / 255.0)    // #FFA047
      static let wpCoral  = Color(red: 0xF5 / 255.0, green: 0x4F / 255.0, blue: 0x4F / 255.0)    // #F54F4F

      // Semantic supports — warm-shifted, no cold blues/greens.
      static let wpVerified  = Color(red: 0x4E / 255.0, green: 0x8F / 255.0, blue: 0x47 / 255.0) // #4E8F47
      static let wpAttempted = Color(red: 0xE0 / 255.0, green: 0x7A / 255.0, blue: 0x2E / 255.0) // #E07A2E
  }
  ```

- [ ] **Step 6: Verify files auto-pickup** — this project uses Xcode 16's `PBXFileSystemSynchronizedRootGroup` (see `project.pbxproj` line 24-35). Files under `WakeProof/WakeProof/` and `WakeProofTests/` are auto-compiled — NO manual pbxproj edit required. Just confirm the new `.swift` files exist on disk.

- [ ] **Step 7: Run tests — expect PASS for `ColorTokensTests`**

  ```bash
  xcodebuild -project WakeProof/WakeProof.xcodeproj -scheme WakeProof -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing WakeProofTests/ColorTokensTests 2>&1 | tail -20
  ```
  Expected: `Test Suite 'ColorTokensTests' passed`.

- [ ] **Step 8: Run full baseline** — expect 366 + 12 = 378 passed, 0 failed.

  ```bash
  xcodebuild -project WakeProof/WakeProof.xcodeproj -scheme WakeProof -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' test 2>&1 > /tmp/ui-1-1.log
  grep -cE " passed on " /tmp/ui-1-1.log   # expect: 378
  grep -E "TEST SUCCEEDED|TEST FAILED" /tmp/ui-1-1.log | tail -1  # expect: ** TEST SUCCEEDED **
  ```

- [ ] **Step 9: Commit**

  ```bash
  git add WakeProof/WakeProof/Design/Tokens/Color+WakeProof.swift WakeProof/WakeProofTests/Design/ColorTokensTests.swift  git commit -m "$(cat <<'EOF'
  UI 1.1: Color tokens (SwiftUI transcription from design-system)

  Direction D (docs/design-system/SKILL.md § "SwiftUI color transcription" +
  colors_and_type.css): ship a single source of truth for the palette so
  subsequent phases can replace scattered .white.opacity(...) constants with
  tokens. Hex → sRGB via /255.0 for byte-exact correspondence.

  Key changes:
  - Color+WakeProof.swift: 12 brand tokens (cream 50/100/200, char 300/500/800/900/950, orange, coral, verified, attempted).
  - ColorTokensTests.swift: 12 tests asserting each token's unpacked sRGB components match the hex spec within 0.01.

  Tests: 378/0 (was 366/0).

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

---

### Task 1.2: Gradient+WakeProof.swift — primary + sunrise

**Files:**
- Create: `WakeProof/WakeProof/Design/Tokens/Gradient+WakeProof.swift`
- Create: `WakeProof/WakeProofTests/Design/GradientTests.swift`

- [ ] **Step 1: Write failing tests**

  ```swift
  import XCTest
  import SwiftUI
  @testable import WakeProof

  /// Gradients can't be introspected via SwiftUI public API, so these smoke
  /// tests verify construction doesn't trap and the extension surface exists.
  /// Visual correctness is verified via the preview/colors-accent-gradient.html
  /// reference card and SwiftUI #Preview in the consuming components.
  final class GradientTests: XCTestCase {
      func testPrimaryGradientExists() {
          let gradient = LinearGradient.wpPrimary
          XCTAssertNotNil(gradient)
      }
      func testSunriseGradientExists() {
          let gradient = LinearGradient.wpSunrise
          XCTAssertNotNil(gradient)
      }
  }
  ```

- [ ] **Step 2: Run tests — expect FAIL**

- [ ] **Step 3: Implement `Gradient+WakeProof.swift`** — sunrise stops are transcribed literally from `colors_and_type.css` line 48 (canonical source-of-truth per SKILL.md). The intermediate rust (`#6E3824`) and warm-peach (`#F38B4D`) stops appear nowhere else in the palette, so they're inlined here rather than promoted to top-level `Color` tokens.

  **Known doc drift:** `README.md` line 143 shows `#1A120C` at the 0% stop (wpChar950); CSS shows `#2B1F17` (wpChar900). SKILL.md names `colors_and_type.css` as the CSS variable source-of-truth, so this plan follows CSS. File a follow-up to reconcile README against CSS — out of this plan's scope.

  ```swift
  //
  //  Gradient+WakeProof.swift
  //  WakeProof
  //
  //  Signature gradients. `wpPrimary` is the 135° orange→coral used for the
  //  primaryAlarm CTA, hero numerals, and the MorningBriefing H1 observation
  //  mark. `wpSunrise` is the 180° 4-stop reveal gradient reserved for the
  //  MorningBriefingView verified-verdict sunrise ceremony — do not use
  //  wpSunrise anywhere else.
  //
  //  Sunrise hex values transcribed from docs/design-system/colors_and_type.css
  //  line 48 (`--wp-gradient-sunrise`). Stops 1 (#6E3824 rust) and 2 (#F38B4D
  //  warm-peach) appear only in this gradient and are inlined rather than
  //  promoted to `Color+WakeProof.swift`.
  //

  import SwiftUI

  extension LinearGradient {
      /// 135° orange → coral. Primary alarm CTA, hero numerals, streak-digit
      /// fill, WakeProof wordmark on onboarding. NOT for backgrounds, NOT for
      /// long runs of text (use `wpCoral` solid for those).
      static let wpPrimary = LinearGradient(
          colors: [.wpOrange, .wpCoral],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
      )

      /// 180° 4-stop sunrise reveal. Reserved for MorningBriefingView's
      /// VERIFIED verdict transition — 1200ms vertical wipe from warm-char
      /// to cream via rust and warm-peach. Stops match CSS source exactly:
      /// wpChar900 (0x2B1F17) 0% → rust (0x6E3824) 45% → peach (0xF38B4D) 85%
      /// → wpCream100 (0xFBEEDB) 100%.
      static let wpSunrise = LinearGradient(
          stops: [
              .init(color: .wpChar900, location: 0.00),
              .init(color: Color(red: 0x6E / 255.0, green: 0x38 / 255.0, blue: 0x24 / 255.0), location: 0.45),
              .init(color: Color(red: 0xF3 / 255.0, green: 0x8B / 255.0, blue: 0x4D / 255.0), location: 0.85),
              .init(color: .wpCream100, location: 1.00)
          ],
          startPoint: .top,
          endPoint: .bottom
      )
  }
  ```

- [ ] **Step 4: Run tests — expect PASS**

- [ ] **Step 5: Run full suite — expect 378 + 2 = 380 passed**

- [ ] **Step 6: Commit**

  ```bash
  git add WakeProof/WakeProof/Design/Tokens/Gradient+WakeProof.swift WakeProof/WakeProofTests/Design/GradientTests.swift  git commit -m "UI 1.2: Gradient tokens (primary + sunrise)

  Direction D: signature 135° orange→coral + reserved 180° sunrise for
  MorningBriefing reveal. Per docs/design-system/README.md § 'Signature gradient'
  and § 'The sunrise gradient (reserved)'.

  Key changes:
  - Gradient+WakeProof.swift: LinearGradient.wpPrimary (135°), LinearGradient.wpSunrise (180° 4-stop).
  - GradientTests.swift: construction smoke tests.

  Tests: 380/0 (was 378/0).

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 1.3: Spacing.swift — 4pt grid scale

**Files:**
- Create: `WakeProof/WakeProof/Design/Tokens/Spacing.swift`
- Create: `WakeProof/WakeProofTests/Design/SpacingScaleTests.swift`

- [ ] **Step 1: Write failing tests**

  ```swift
  import XCTest
  @testable import WakeProof

  /// Spacing scale is a 4pt base grid per design-system §Spacing & radii.
  /// Tests assert the published values match the CSS source of truth so
  /// SwiftUI and the HTML preview cards stay in lockstep.
  final class SpacingScaleTests: XCTestCase {
      func testScaleMatchesCSSSource() {
          XCTAssertEqual(WPSpacing.xs1, 4)
          XCTAssertEqual(WPSpacing.xs2, 8)
          XCTAssertEqual(WPSpacing.sm,  12)
          XCTAssertEqual(WPSpacing.md,  16)
          XCTAssertEqual(WPSpacing.lg,  20)
          XCTAssertEqual(WPSpacing.xl,  24)
          XCTAssertEqual(WPSpacing.xl2, 32)
          XCTAssertEqual(WPSpacing.xl3, 40)
          XCTAssertEqual(WPSpacing.xl4, 48)
          XCTAssertEqual(WPSpacing.xl5, 64)
      }

      func testAllValuesAreMultiplesOfFour() {
          let values: [CGFloat] = [
              WPSpacing.xs1, WPSpacing.xs2, WPSpacing.sm, WPSpacing.md,
              WPSpacing.lg, WPSpacing.xl, WPSpacing.xl2, WPSpacing.xl3,
              WPSpacing.xl4, WPSpacing.xl5
          ]
          for v in values {
              XCTAssertEqual(v.truncatingRemainder(dividingBy: 4), 0, "\(v) is not a multiple of 4")
          }
      }
  }
  ```

- [ ] **Step 2: Run tests — expect FAIL**

- [ ] **Step 3: Implement `Spacing.swift`**

  ```swift
  //
  //  Spacing.swift
  //  WakeProof
  //
  //  4pt base grid per docs/design-system/colors_and_type.css § "Spacing scale".
  //  Screen padding is WPSpacing.xl2 (32pt). Section gap is WPSpacing.xl (24pt)
  //  matching the VStack(spacing: 24) usage throughout existing Swift code.
  //

  import CoreGraphics

  enum WPSpacing {
      static let xs1: CGFloat = 4
      static let xs2: CGFloat = 8
      static let sm:  CGFloat = 12
      static let md:  CGFloat = 16  // base row padding
      static let lg:  CGFloat = 20
      static let xl:  CGFloat = 24  // section gap
      static let xl2: CGFloat = 32  // screen padding
      static let xl3: CGFloat = 40
      static let xl4: CGFloat = 48
      static let xl5: CGFloat = 64  // hero top space
  }
  ```

- [ ] **Step 4: Run tests — expect PASS**

- [ ] **Step 5: Run full suite — expect 382 passed**

- [ ] **Step 6: Commit**

  ```bash
  git add WakeProof/WakeProof/Design/Tokens/Spacing.swift WakeProof/WakeProofTests/Design/SpacingScaleTests.swift  git commit -m "UI 1.3: Spacing scale (4pt grid)

  Direction D: WPSpacing enum mirrors the --wp-space-* CSS custom properties
  in docs/design-system/colors_and_type.css.

  Tests: 382/0 (was 380/0).

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 1.4: Typography.swift — WPFont enum

**Files:**
- Create: `WakeProof/WakeProof/Design/Tokens/Typography.swift`
- Create: `WakeProof/WakeProofTests/Design/TypographyTests.swift`

- [ ] **Step 1: Invoke `wakeproof-design` skill** — pull the type-scale preview cards (`type-display.html`, `type-titles.html`, `type-body.html`) for reference.

- [ ] **Step 2: Write failing tests**

  ```swift
  import XCTest
  import SwiftUI
  @testable import WakeProof

  /// Typography enum surfaces every role the CSS source defines (hero-xl,
  /// hero, display, title-1..3, headline, body, callout, subhead, footnote,
  /// caption). Hero and display roles use SF Pro Rounded via
  /// `.system(design: .rounded)`; body roles use the system default.
  /// Font internal structure isn't publicly introspectable — these tests
  /// verify the enum exists with all expected cases and returns non-nil Font.
  final class TypographyTests: XCTestCase {
      func testAllRolesResolveToFont() {
          let roles: [WPFont] = [
              .heroXL, .hero, .display, .title1, .title2, .title3,
              .headline, .body, .callout, .subhead, .footnote, .caption
          ]
          for role in roles {
              _ = role.font  // just verify property access doesn't trap
          }
      }
  }
  ```

- [ ] **Step 3: Run tests — expect FAIL**

- [ ] **Step 4: Implement `Typography.swift`**

  ```swift
  //
  //  Typography.swift
  //  WakeProof
  //
  //  Type scale per docs/design-system/colors_and_type.css § "Typography".
  //  Hero / display roles use SF Pro Rounded (system, iOS 17+) via
  //  `.system(design: .rounded)` per SKILL.md — Nunito is the web-only
  //  fallback, NOT shipped on iOS. Body roles use the system default.
  //
  //  Hero numerals (heroXL, hero, display) should use .monospacedDigit()
  //  at call-sites where the value ticks (streak counter, clock time) so
  //  the tabular rendering doesn't jitter. See AlarmRingingView time display.
  //

  import SwiftUI

  enum WPFont {
      case heroXL   // 88pt rounded — AlarmRingingView time
      case hero     // 64pt rounded — MorningBriefing H1
      case display  // 42pt rounded — Welcome title, large streak digit
      case title1   // 34pt — navigation titles
      case title2   // 28pt — commitment note emphasis
      case title3   // 22pt — section headings
      case headline // 17pt semibold
      case body     // 17pt regular
      case callout  // 16pt
      case subhead  // 15pt
      case footnote // 13pt
      case caption  // 12pt uppercase tracking

      var font: Font {
          switch self {
          case .heroXL:   return .system(size: 88, weight: .bold, design: .rounded)
          case .hero:     return .system(size: 64, weight: .bold, design: .rounded)
          case .display:  return .system(size: 42, weight: .bold, design: .rounded)
          case .title1:   return .system(size: 34, weight: .bold)
          case .title2:   return .system(size: 28, weight: .semibold)
          case .title3:   return .system(size: 22, weight: .semibold)
          case .headline: return .system(size: 17, weight: .semibold)
          case .body:     return .system(size: 17, weight: .regular)
          case .callout:  return .system(size: 16, weight: .regular)
          case .subhead:  return .system(size: 15, weight: .regular)
          case .footnote: return .system(size: 13, weight: .regular)
          case .caption:  return .system(size: 12, weight: .medium)
          }
      }
  }

  extension View {
      /// Applies a WPFont role's font. Use this at call sites instead of
      /// `.font(.system(size: N))` so the surface stays consistent with the
      /// design-system type scale.
      func wpFont(_ role: WPFont) -> some View {
          self.font(role.font)
      }
  }
  ```

- [ ] **Step 5: Run tests — expect PASS**

- [ ] **Step 6: Run full suite — expect 383 passed**

- [ ] **Step 7: Commit**

  ```bash
  git add WakeProof/WakeProof/Design/Tokens/Typography.swift WakeProof/WakeProofTests/Design/TypographyTests.swift  git commit -m "UI 1.4: Typography scale (SF Pro Rounded display + system body)

  Direction D: WPFont enum covers 12 roles. SF Pro Rounded on display
  (per SKILL.md — Nunito is web-only fallback, NOT shipped on iOS).

  Tests: 383/0 (was 382/0).

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 1.5: Radii.swift — 6-step radius scale

**Files:**
- Create: `WakeProof/WakeProof/Design/Tokens/Radii.swift`

- [ ] **Step 1: Implement** (no separate test — trivially reflected in spacing scale test pattern; cover in ComponentSmokeTests Phase 2)

  ```swift
  //
  //  Radii.swift
  //  WakeProof
  //
  //  Radius scale per docs/design-system/colors_and_type.css § "--wp-radius-*".
  //  Form inputs = sm (10). Cards = lg (20). Hero surfaces = xl (28).
  //  primaryAlarm CTA = pill (999). Standard buttons = md (14) — rounded
  //  up from the shipped PrimaryButtonStyle's 12 for a softer read on cream.
  //

  import CoreGraphics

  enum WPRadius {
      static let xs:   CGFloat = 6
      static let sm:   CGFloat = 10
      static let md:   CGFloat = 14
      static let lg:   CGFloat = 20
      static let xl:   CGFloat = 28
      static let pill: CGFloat = 999
  }
  ```

- [ ] **Step 2: Run full suite — expect 383 passed (no new tests)**

- [ ] **Step 3: Commit**

  ```bash
  git add WakeProof/WakeProof/Design/Tokens/Radii.swift  git commit -m "UI 1.5: Radii scale (xs/sm/md/lg/xl/pill)

  Direction D: WPRadius enum — form sm, card lg, hero xl, primaryAlarm pill.

  Tests: 383/0.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 1.6: Shadows.swift — warm-tinted elevation

**Files:**
- Create: `WakeProof/WakeProof/Design/Tokens/Shadows.swift`

- [ ] **Step 1: Implement**

  ```swift
  //
  //  Shadows.swift
  //  WakeProof
  //
  //  Warm-tinted elevation per docs/design-system/README.md § "Elevation".
  //  All shadow colors are rgba(43, 31, 23, α) — NEVER black. `.accent`
  //  uses coral α=0.25 for the signature primaryAlarm glow.
  //

  import SwiftUI

  enum WPElevation {
      case sm, md, lg, accent
  }

  struct WPShadowModifier: ViewModifier {
      let elevation: WPElevation

      func body(content: Content) -> some View {
          switch elevation {
          case .sm:
              content
                  .shadow(color: .wpChar900.opacity(0.06), radius: 2, x: 0, y: 1)
          case .md:
              content
                  .shadow(color: .wpChar900.opacity(0.08), radius: 14, x: 0, y: 4)
          case .lg:
              content
                  .shadow(color: .wpChar900.opacity(0.12), radius: 32, x: 0, y: 12)
          case .accent:
              content
                  .shadow(color: .wpCoral.opacity(0.25), radius: 24, x: 0, y: 8)
          }
      }
  }

  extension View {
      /// Applies a warm-tinted elevation per the design-system elevation
      /// ladder. `.accent` is reserved for the primaryAlarm CTA glow.
      func wpShadow(_ elevation: WPElevation) -> some View {
          self.modifier(WPShadowModifier(elevation: elevation))
      }
  }
  ```

- [ ] **Step 2: Run full suite — expect 383 passed**

- [ ] **Step 3: Commit**

  ```bash
  git add WakeProof/WakeProof/Design/Tokens/Shadows.swift  git commit -m "UI 1.6: Warm-tinted elevation tokens (sm/md/lg/accent)

  Direction D: WPElevation enum + wpShadow(_:) modifier. All shadow colors
  use wpChar900 tint (not black); .accent uses coral glow for primaryAlarm.

  Tests: 383/0.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 1.7: PrimaryButtonStyle migration to tokens

**Files:**
- Modify: `WakeProof/WakeProof/App/PrimaryButtonStyle.swift`

- [ ] **Step 1: Invoke `wakeproof-design` skill**. Open `preview/button-primary-alarm.html` and `preview/button-secondary.html` in browser for visual reference.

- [ ] **Step 2: Read existing shape** (use Read tool on `WakeProof/WakeProof/App/PrimaryButtonStyle.swift`)

- [ ] **Step 3: Migrate the file**

  ```swift
  //
  //  PrimaryButtonStyle.swift
  //  WakeProof
  //
  //  Shared pill button style used by every "next-step" CTA across onboarding,
  //  baseline capture, and the alarm-ringing screen. Migrated to design-system
  //  tokens per Phase 1 UI rewrite — variants keep their names for call-site
  //  stability but their fills / radii / fonts now come from Color+WakeProof,
  //  WPRadius, WPFont, and WPShadow.
  //
  //  Variant map:
  //   - primaryWhite   → cream-50 fill, char-900 text; default CTA on dark hero.
  //   - primaryConfirm → wpVerified fill, cream-50 text; baseline-save only.
  //   - primaryMuted   → cream-50 opacity-0.4 fill, char-900 opacity-0.5 text; disabled state.
  //   - primaryAlarm   → wpPrimary 135° gradient fill, cream-50 text, pill radius,
  //                      coral-accent shadow; the single alarm-dismissal CTA.
  //

  import SwiftUI

  struct PrimaryButtonStyle: ButtonStyle {
      var tint: Color = .wpCream50
      var foreground: Color = .wpChar900
      var gradient: LinearGradient? = nil
      var cornerRadius: CGFloat = WPRadius.md
      var font: Font = WPFont.body.font.bold()
      var isProminent: Bool = false

      func makeBody(configuration: Configuration) -> some View {
          configuration.label
              .font(font)
              .frame(maxWidth: .infinity)
              .padding()
              .background(background)
              .foregroundStyle(foreground)
              .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
              .opacity(buttonOpacity(pressed: configuration.isPressed))
              .scaleEffect(configuration.isPressed && isProminent ? 0.98 : 1.0)
              .wpShadow(isProminent ? .accent : .sm)
              .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
      }

      @ViewBuilder
      private var background: some View {
          if let gradient {
              gradient
          } else {
              tint
          }
      }

      private func buttonOpacity(pressed: Bool) -> Double {
          pressed ? 0.85 : 1.0
      }
  }

  extension ButtonStyle where Self == PrimaryButtonStyle {
      /// Cream-50 pill. Default CTA on dark hero surfaces ("Start your day",
      /// onboarding next-step buttons, verifying-success dismiss).
      static var primaryWhite: PrimaryButtonStyle { PrimaryButtonStyle() }

      /// Verified-green confirmation CTA. Used on baseline-save only — the
      /// moment the contract is actually committed.
      static var primaryConfirm: PrimaryButtonStyle {
          PrimaryButtonStyle(tint: .wpVerified, foreground: .wpCream50)
      }

      /// Disabled / inactive form. Renders the same shape but visually muted.
      static var primaryMuted: PrimaryButtonStyle {
          PrimaryButtonStyle(tint: Color.wpCream50.opacity(0.4), foreground: .wpChar900.opacity(0.5))
      }

      /// Pill CTA for the alarm-ringing screen ("Prove you're awake") and
      /// disable-challenge capture step. Signature 135° gradient + coral glow.
      static var primaryAlarm: PrimaryButtonStyle {
          PrimaryButtonStyle(
              foreground: .wpCream50,
              gradient: .wpPrimary,
              cornerRadius: WPRadius.pill,
              font: WPFont.title3.font.bold(),
              isProminent: true
          )
      }
  }
  ```

- [ ] **Step 4: Run full suite — expect 383 passed, 0 failed**

  If the build fails with "Cannot find 'WPFont' in scope" from a call site, verify the new Design/ folder is added to the app target (not the test target).

- [ ] **Step 5: Visual smoke test via `#Preview`** on one consumer — open `WakeProof/WakeProof/Alarm/AlarmRingingView.swift` in Xcode, hit Canvas, verify the "Prove you're awake" button renders with the pill shape + orange→coral gradient + coral glow. If the #Preview looks visually broken, investigate before commit.

- [ ] **Step 6: Commit**

  ```bash
  git add WakeProof/WakeProof/App/PrimaryButtonStyle.swift
  git commit -m "UI 1.7: Migrate PrimaryButtonStyle to design tokens

  Direction D: PrimaryButtonStyle now consumes Phase-1 tokens. Variant names
  preserved for call-site stability; backing visuals migrated.
  - primaryWhite: wpCream50 + wpChar900 (was .white + .black)
  - primaryConfirm: wpVerified + wpCream50 (was .green + .black)
  - primaryMuted: wpCream50@0.4 + wpChar900@0.5 (was .white@0.4 + .black)
  - primaryAlarm: wpPrimary gradient + wpCream50 + pill + .accent shadow
                  (was cornerRadius 16 + default shadow)

  Tests: 383/0.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

**Phase 1 gate checklist — confirm all before moving to Phase 2:**
- [ ] 6 token files compile + 1 migrated `PrimaryButtonStyle.swift`
- [ ] Test count = 383 (366 baseline + 17 token tests)
- [ ] `xcodebuild ... test` → `** TEST SUCCEEDED **`
- [ ] One commit per task → 7 commits ahead of `ce4cadd`
- [ ] Visual smoke: PrimaryButtonStyle #Preview shows pill + gradient on primaryAlarm

---

## Phase 2 — Component Library

**Phase gate — must hold before advancing to Phase 3:**
- 5 component files compile
- WPStreakBadge.shouldRender(...) behaves identically to StreakBadgeView.shouldRender(...)
- Test count ≥ 383 + component smoke tests (target: ~390)
- `xcodebuild ... test` green

### Task 2.1: WPCard — container with cream-50 + shadow-md

**Files:**
- Create: `WakeProof/WakeProof/Design/Components/WPCard.swift`

- [ ] **Step 1: Invoke `wakeproof-design` skill**. Open `preview/shadows.html` + `preview/radii.html` for visual reference.

- [ ] **Step 2: Create Components directory**

  ```bash
  mkdir -p WakeProof/WakeProof/Design/Components
  ```

- [ ] **Step 3: Implement**

  ```swift
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
  ```

- [ ] **Step 4: Run full suite — expect 383 passed (no new tests yet)**

- [ ] **Step 5: Visual smoke via #Preview (Light + Dark variants)**

- [ ] **Step 6: Commit**

  ```bash
  git add WakeProof/WakeProof/Design/Components/WPCard.swift  git commit -m "UI 2.1: WPCard container (cream-50 + wpShadow .md / char-800 + hairline)

  Phase 2 Direction D: primary surface container. Color-scheme-aware per
  README.md § 'Borders, cards, transparency'.

  Tests: 383/0.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 2.2: WPSection — titled content group

**Files:**
- Create: `WakeProof/WakeProof/Design/Components/WPSection.swift`

- [ ] **Step 1: Implement**

  ```swift
  //
  //  WPSection.swift
  //  WakeProof
  //
  //  Titled content group. Caption-styled label + 8pt gap + slotted content.
  //  Used on the home surface for organizing commitment note, streak, next
  //  fire, and sharing rows. Section is NOT a Card — it's a header + child;
  //  compose WPSection { WPCard { ... } } when the child needs elevation.
  //

  import SwiftUI

  struct WPSection<Content: View>: View {
      let title: String
      @ViewBuilder let content: () -> Content

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
  ```

- [ ] **Step 2: Run full suite — expect 383 passed**

- [ ] **Step 3: Commit**

  ```bash
  git add WakeProof/WakeProof/Design/Components/WPSection.swift  git commit -m "UI 2.2: WPSection titled group (caption label + content slot)

  Phase 2: composable section wrapper. Sentence-case copy input, renders
  uppercase per design-system caption style.

  Tests: 383/0.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 2.3: WPMetricCard — number + label atom

**Files:**
- Create: `WakeProof/WakeProof/Design/Components/WPMetricCard.swift`

- [ ] **Step 1: Invoke `wakeproof-design` skill**. Open `preview/component-metric-row.html` for reference.

- [ ] **Step 2: Implement**

  ```swift
  //
  //  WPMetricCard.swift
  //  WakeProof
  //
  //  Large-numeral + small-label atom used by InvestmentDashboardView and
  //  any future analytics surface. `accent=true` applies the wpPrimary
  //  gradient fill to the numeral via `.foregroundStyle(LinearGradient.wpPrimary)`.
  //

  import SwiftUI

  struct WPMetricCard: View {
      let value: String
      let label: String
      let accent: Bool

      init(value: String, label: String, accent: Bool = false) {
          self.value = value
          self.label = label
          self.accent = accent
      }

      var body: some View {
          WPCard {
              VStack(alignment: .leading, spacing: WPSpacing.xs2) {
                  valueView
                      .monospacedDigit()
                  Text(label)
                      .wpFont(.subhead)
                      .foregroundStyle(Color.wpChar500)
              }
          }
      }

      @ViewBuilder
      private var valueView: some View {
          if accent {
              Text(value)
                  .wpFont(.display)
                  .foregroundStyle(LinearGradient.wpPrimary)
          } else {
              Text(value)
                  .wpFont(.display)
                  .foregroundStyle(Color.wpChar900)
          }
      }
  }

  #Preview {
      HStack(spacing: WPSpacing.md) {
          WPMetricCard(value: "12", label: "Verified mornings", accent: true)
          WPMetricCard(value: "3", label: "Insights collected")
      }
      .padding()
      .background(Color.wpCream100)
  }
  ```

- [ ] **Step 3: Run full suite — expect 383 passed**

- [ ] **Step 4: Commit**

  ```bash
  git add WakeProof/WakeProof/Design/Components/WPMetricCard.swift  git commit -m "UI 2.3: WPMetricCard (display numeral + caption label)

  Phase 2: dashboard atom. accent=true applies wpPrimary gradient fill to
  the numeral. Used by InvestmentDashboardView in Phase 6.

  Tests: 383/0.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 2.4: WPHeroTimeDisplay — ticking time display

**Files:**
- Create: `WakeProof/WakeProof/Design/Components/WPHeroTimeDisplay.swift`

- [ ] **Step 1: Read existing** `AlarmRingingView.swift` lines 26-30 for the `TimelineView(.periodic(from: .now, by: 1))` pattern.

- [ ] **Step 2: Implement**

  ```swift
  //
  //  WPHeroTimeDisplay.swift
  //  WakeProof
  //
  //  Ticking time display driven by `TimelineView(.periodic(from: .now, by: 1))`.
  //  Two styles: `.large` (88pt, alarm-ring hero), `.medium` (64pt, home
  //  hero). Both use `.system(design: .rounded)` via WPFont.heroXL / .hero
  //  and `.monospacedDigit()` so the colon+digits don't jitter.
  //

  import SwiftUI

  struct WPHeroTimeDisplay: View {
      enum Style { case large, medium }

      let style: Style
      let foreground: Color

      init(style: Style = .large, foreground: Color = .wpCream50) {
          self.style = style
          self.foreground = foreground
      }

      var body: some View {
          TimelineView(.periodic(from: .now, by: 1)) { context in
              Text(context.date.formatted(date: .omitted, time: .shortened))
                  .wpFont(style == .large ? .heroXL : .hero)
                  .monospacedDigit()
                  .foregroundStyle(foreground)
          }
      }
  }

  #Preview("Large on dark") {
      WPHeroTimeDisplay(style: .large)
          .frame(maxWidth: .infinity)
          .padding()
          .background(Color.wpChar900)
          .preferredColorScheme(.dark)
  }

  #Preview("Medium on cream") {
      WPHeroTimeDisplay(style: .medium, foreground: .wpChar900)
          .frame(maxWidth: .infinity)
          .padding()
          .background(Color.wpCream100)
  }
  ```

- [ ] **Step 3: Run full suite — expect 383 passed**

- [ ] **Step 4: Commit**

  ```bash
  git add WakeProof/WakeProof/Design/Components/WPHeroTimeDisplay.swift  git commit -m "UI 2.4: WPHeroTimeDisplay (ticking rounded time)

  Phase 2: extracted the TimelineView pattern from AlarmRingingView into a
  reusable component so home + alarm-ring share the same clock primitive.
  .large style = 88pt (alarm-ring), .medium = 64pt (home).

  Tests: 383/0.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 2.5: WPStreakBadge + shouldRender API + tests

**Files:**
- Create: `WakeProof/WakeProof/Design/Components/WPStreakBadge.swift`
- Create: `WakeProof/WakeProofTests/Design/ComponentSmokeTests.swift`

- [ ] **Step 1: Invoke `wakeproof-design` skill**. Open `preview/component-streak-badge.html` for reference.

- [ ] **Step 2: Read the existing `StreakBadgeView.shouldRender`** signature from `WakeProof/WakeProof/Alarm/StreakBadgeView.swift` to preserve the public API contract.

- [ ] **Step 3: Write failing tests**

  ```swift
  import XCTest
  import SwiftUI
  @testable import WakeProof

  /// Component construction + public-API smoke. `WPStreakBadge.shouldRender`
  /// MUST behave identically to the existing `StreakBadgeView.shouldRender`
  /// so the AlarmSchedulerView call site can swap callers without branching.
  final class ComponentSmokeTests: XCTestCase {
      // ── WPStreakBadge.shouldRender contract ─────────────────────────────
      func testShouldRender_bothZero_false() {
          XCTAssertFalse(WPStreakBadge.shouldRender(currentStreak: 0, bestStreak: 0))
      }

      func testShouldRender_currentPositive_true() {
          XCTAssertTrue(WPStreakBadge.shouldRender(currentStreak: 3, bestStreak: 3))
          XCTAssertTrue(WPStreakBadge.shouldRender(currentStreak: 1, bestStreak: 5))
      }

      func testShouldRender_currentZeroBestPositive_true() {
          XCTAssertTrue(WPStreakBadge.shouldRender(currentStreak: 0, bestStreak: 5))
      }

      func testShouldRender_negativeDefensive_false() {
          XCTAssertFalse(WPStreakBadge.shouldRender(currentStreak: -1, bestStreak: -1))
      }

      // ── Construction smoke ──────────────────────────────────────────────
      func testWPCardConstructs() {
          _ = WPCard { Text("x") }
      }

      func testWPSectionConstructs() {
          _ = WPSection("S") { Text("x") }
      }

      func testWPMetricCardConstructs() {
          _ = WPMetricCard(value: "12", label: "mornings")
          _ = WPMetricCard(value: "12", label: "mornings", accent: true)
      }

      func testWPHeroTimeDisplayConstructs() {
          _ = WPHeroTimeDisplay(style: .large)
          _ = WPHeroTimeDisplay(style: .medium, foreground: .wpChar900)
      }

      func testWPStreakBadgeConstructs() {
          _ = WPStreakBadge(currentStreak: 3, bestStreak: 5)
      }
  }
  ```

- [ ] **Step 4: Run tests — expect FAIL** (WPStreakBadge not defined)

- [ ] **Step 5: Implement `WPStreakBadge.swift`**

  ```swift
  //
  //  WPStreakBadge.swift
  //  WakeProof
  //
  //  Evolved replacement for Alarm/StreakBadgeView. Preserves the public
  //  `shouldRender(currentStreak:bestStreak:)` static API so call sites don't
  //  branch during Phase 6 migration. Visual: wpVerified-filled pill when
  //  currentStreak > 0, wpChar500-outline pill when currentStreak == 0 and
  //  bestStreak > 0 (dormant — "best: N days" still worth showing).
  //

  import SwiftUI

  struct WPStreakBadge: View {
      let currentStreak: Int
      let bestStreak: Int

      /// Same semantic gate as the shipped StreakBadgeView.shouldRender.
      /// Returns false on a fresh install (both zero) and on defensive
      /// negative inputs — so the section rendering this badge is absent
      /// rather than showing a bleak "0-day streak" placeholder.
      static func shouldRender(currentStreak: Int, bestStreak: Int) -> Bool {
          guard currentStreak >= 0, bestStreak >= 0 else { return false }
          return currentStreak > 0 || bestStreak > 0
      }

      var body: some View {
          HStack(spacing: WPSpacing.sm) {
              if currentStreak > 0 {
                  activeBadge
              } else {
                  dormantBadge
              }
              if bestStreak > currentStreak {
                  Text("Best: \(bestStreak) day\(bestStreak == 1 ? "" : "s")")
                      .wpFont(.footnote)
                      .foregroundStyle(Color.wpChar500)
              }
          }
      }

      private var activeBadge: some View {
          HStack(spacing: WPSpacing.xs1) {
              Text("\(currentStreak)")
                  .wpFont(.title3)
                  .monospacedDigit()
              Text("day\(currentStreak == 1 ? "" : "s")")
                  .wpFont(.subhead)
          }
          .foregroundStyle(Color.wpCream50)
          .padding(.horizontal, WPSpacing.md)
          .padding(.vertical, WPSpacing.xs2)
          .background(Color.wpVerified)
          .clipShape(Capsule())
      }

      private var dormantBadge: some View {
          HStack(spacing: WPSpacing.xs1) {
              Text("Streak reset")
                  .wpFont(.subhead)
          }
          .foregroundStyle(Color.wpChar500)
          .padding(.horizontal, WPSpacing.md)
          .padding(.vertical, WPSpacing.xs2)
          .overlay(Capsule().stroke(Color.wpChar500, lineWidth: 1))
      }
  }

  #Preview("Active streak") {
      WPStreakBadge(currentStreak: 4, bestStreak: 4)
          .padding()
          .background(Color.wpCream100)
  }

  #Preview("Active + best above") {
      WPStreakBadge(currentStreak: 2, bestStreak: 7)
          .padding()
          .background(Color.wpCream100)
  }

  #Preview("Dormant") {
      WPStreakBadge(currentStreak: 0, bestStreak: 5)
          .padding()
          .background(Color.wpCream100)
  }
  ```

- [ ] **Step 6: Run tests — expect PASS (9 new tests)**

- [ ] **Step 7: Run full suite — expect 383 + 9 = 392 passed**

- [ ] **Step 8: Commit**

  ```bash
  git add WakeProof/WakeProof/Design/Components/WPStreakBadge.swift WakeProof/WakeProofTests/Design/ComponentSmokeTests.swift  git commit -m "UI 2.5: WPStreakBadge (evolved streak visual + shouldRender API preserved)

  Phase 2: evolved replacement for Alarm/StreakBadgeView. Same
  shouldRender(currentStreak:bestStreak:) contract — Phase 6 folds the old
  file in by forwarding to this component.

  Visual: wpVerified-filled capsule for currentStreak > 0, char500-outline
  capsule for dormant state. 'Best: N days' footnote when best > current.

  Tests: 392/0 (was 383/0; +9 component smokes).

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

**Phase 2 gate checklist:**
- [ ] 5 component files compile
- [ ] `WPStreakBadge.shouldRender` matches shipped `StreakBadgeView.shouldRender` (same test vectors pass)
- [ ] Test count = 392
- [ ] `xcodebuild ... test` → `** TEST SUCCEEDED **`
- [ ] Each component has at least one `#Preview` that renders cleanly in Xcode Canvas

---

## Phase 3 — Home Screen Hero (Direction A)

**Phase gate — must hold before Phase 4:**
- `AlarmSchedulerView` rewritten hero-style (ScrollView + VStack + sections built on WPCard / WPSection / WPHeroTimeDisplay / WPStreakBadge / WPMetricCard)
- All Wave 5 wiring preserved byte-identically (G1 proxy Binding, H3 recompute, H2 note, H5 share toggle, systemBanner priority chain)
- Test count = 392 (no new regressions; view-layer change doesn't move logic-layer tests)
- `xcodebuild ... test` green
- Manual UAT on simulator: setting window, toggling alarm off (G1 challenge path), toggling share, DEBUG fire-now — all functional

### Task 3.1: Home hero layout skeleton

**Files:**
- Modify: `WakeProof/WakeProof/Alarm/AlarmSchedulerView.swift`

Scope: replace the outer `Form { ... }` with `NavigationStack { ScrollView { VStack(spacing: WPSpacing.xl) { ... } } }`. Move the systemBanner into a top-of-scroll banner. Reorganize content into 6 sections: hero (time + streak), commitment note, wake window, share toggle, secondary surfaces (calendar / dashboard / weekly insight), DEBUG (unchanged #if DEBUG).

- [ ] **Step 1: Invoke `wakeproof-design` skill**. Open `ui_kits/ios/index.html` → "home" screen for the target layout.

- [ ] **Step 2: Read the full existing `AlarmSchedulerView.swift`** to extract every `@Environment` / `@Query` / `@State` / `@AppStorage` declaration and every `.onAppear` / `.onChange` / `.task` modifier. Copy-paste these into the new body verbatim so wiring is preserved.

- [ ] **Step 3: Rewrite body** — replace `Form { ... }` with the hero structure. Key sections:

  1. **Banner strip** — if `systemBanner` non-nil, render a `WPCard { Text(banner).foregroundStyle(Color.wpAttempted) }` at the top.
  2. **Hero** — `WPHeroTimeDisplay(style: .medium, foreground: .wpChar900)` centered + a `nextFireAt`-derived subtitle ("Next: Monday 06:30") + `WPStreakBadge` if `shouldRender(...)`.
  3. **WPSection("First thing tomorrow")** — contains the commitment-note `TextField` + char counter. **PRESERVE THE ENTIRE `.onChange(of: commitmentNote)` truncation block**.
  4. **WPSection("Wake window")** — `DatePicker` + `Toggle("Alarm enabled", isOn: $proxyBinding)`. **PRESERVE THE G1 PROXY BINDING** (`Binding(get:set:)` that calls `handleDisableRequest()` on OFF).
  5. **Save & schedule button** — `.buttonStyle(.primaryConfirm)` (was implicit Form button). **PRESERVE `windowSaveFailureMessage` inline warning**.
  6. **WPSection("Next fire")** — if `scheduler.nextFireAt`, show formatted date.
  7. **WPSection("Sharing")** — Toggle bound to `$shareCardEnabled` (@AppStorage) + footnote copy.
  8. **#if DEBUG block** — keep verbatim: bypass toggle, fire-now, start-overnight, finalize-briefing.
  9. **WPSection("Weekly insight")** — `WeeklyInsightView(...)` from existing code, passed same params.

  **NavigationStack title**: keep `.navigationTitle("WakeProof")`.

  **Do NOT change**: `loadFromScheduler()`, `handleDisableRequest()`, `recomputeStreak()`, `save()`, `refreshOvernightStartError()`, `refreshDroppedMemoryCount()`, `systemBanner` computed property. Move them into the struct body unchanged.

- [ ] **Step 4: Apply `.background(Color.wpCream100).ignoresSafeArea()`** to the ScrollView so empty space matches the design-system cream surface.

- [ ] **Step 5: Apply `.scrollDismissesKeyboard(.interactively)`** to the ScrollView so the commitment-note TextField dismisses cleanly.

- [ ] **Step 6: Grep-verify no wiring got renamed or dropped** — every symbol in the existing view's header must still appear in the rewritten body with the same spelling.

  ```bash
  for symbol in commitmentNote isEnabled startTime lastSessionStartError windowSaveFailureMessage droppedMemoryWrites shareCardEnabled disableChallengeBypassEnabled wakeAttempts streakService scheduler audioKeepalive permissions weeklyCoach visionVerifier overnightScheduler loadFromScheduler handleDisableRequest recomputeStreak refreshOvernightStartError refreshDroppedMemoryCount systemBanner save; do
      count=$(grep -c "$symbol" WakeProof/WakeProof/Alarm/AlarmSchedulerView.swift)
      echo "$symbol: $count"
  done
  ```
  Expected: every symbol has count ≥ 1. A zero means wiring got dropped during the rewrite — restore from the pre-rewrite file before commit.

- [ ] **Step 7: Run full suite — expect 392 passed**

  If any AlarmSchedulerView-adjacent test breaks, the wiring was dropped — re-copy the missing @State / @Environment / @Query / observer.

- [ ] **Step 8: Simulator UAT** — boot the sim, complete onboarding fixture, land on home. Verify:
  - Time displays in 64pt rounded (WPHeroTimeDisplay medium)
  - StreakBadge renders cream/wpVerified capsule when an attempt row exists
  - Toggling "Alarm enabled" OFF triggers the G1 challenge path (DisableChallengeView presents)
  - Commitment note saves and persists across relaunch
  - Sharing toggle flips without glitching

- [ ] **Step 9: Commit**

  ```bash
  git add WakeProof/WakeProof/Alarm/AlarmSchedulerView.swift
  git commit -m "UI 3.1: Home hero layout (ScrollView + WPCard/Section composition)

  Direction A (docs/design-system/ui_kits/ios/ home screen): Form →
  ScrollView + VStack hero. All Wave 5 wiring preserved byte-identically
  (G1 proxy Binding, H3 recompute observer, H2 commitment note truncation
  chain, H5 share toggle, systemBanner priority chain, DEBUG bypass).

  Key changes:
  - Replace outer Form with NavigationStack { ScrollView { VStack } }.
  - Hero: WPHeroTimeDisplay(.medium) + next-fire strip + WPStreakBadge.
  - WPSection(s) for commitment note / wake window / sharing / weekly insight.
  - Cream background, interactive keyboard dismissal.

  Tests: 392/0.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 3.2: Next-fire strip + streak-badge Tap target → StreakCalendarView

**Files:**
- Modify: `WakeProof/WakeProof/Alarm/AlarmSchedulerView.swift`

- [ ] **Step 1: Wrap `WPStreakBadge` in `NavigationLink` → `StreakCalendarView(attempts: wakeAttempts)`** — matches existing "View streak calendar" navigation. Preserve the existing separate link for back-compat until UAT confirms the tap area is discoverable.

- [ ] **Step 2: Add a dedicated next-fire strip below the hero time**: when `scheduler.nextFireAt` is non-nil, render `Text("Next ring " + formatted).wpFont(.footnote).foregroundStyle(Color.wpChar500)`. Use the existing `next.formatted(date: .abbreviated, time: .standard)` formatter for consistency.

- [ ] **Step 3: Run full suite — expect 392 passed**

- [ ] **Step 4: Simulator UAT** — tap WPStreakBadge → lands on calendar. Next-fire strip shows below hero time and updates on alarm enable/disable.

- [ ] **Step 5: Commit**

  ```bash
  git add WakeProof/WakeProof/Alarm/AlarmSchedulerView.swift
  git commit -m "UI 3.2: Home hero next-fire strip + tap-to-calendar

  Direction A: promote next-fire to the hero strip (secondary line under
  the ticking time). Make the WPStreakBadge itself a NavigationLink into
  StreakCalendarView for one-tap discovery.

  Tests: 392/0.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 3.3: Secondary surface re-IA — 'Your commitment' + calendar promoted

**Files:**
- Modify: `WakeProof/WakeProof/Alarm/AlarmSchedulerView.swift`

Current "Streak" section contains two stacked NavigationLinks ("View streak calendar" + "Your commitment"). Rewrite as a WPSection rendering two side-by-side WPCard tap targets.

- [ ] **Step 1: Replace the two NavigationLinks with a horizontal HStack of two WPCards.** Each card: icon (SF Symbol) + title + secondary caption.

  ```swift
  WPSection("Your contract") {
      HStack(spacing: WPSpacing.md) {
          NavigationLink {
              InvestmentDashboardView()
          } label: {
              WPCard {
                  VStack(alignment: .leading, spacing: WPSpacing.xs2) {
                      Image(systemName: "book.closed")
                          .wpFont(.title3)
                          .foregroundStyle(Color.wpCoral)
                      Text("Your commitment").wpFont(.headline)
                      Text("Baseline age, mornings, insights").wpFont(.footnote).foregroundStyle(Color.wpChar500)
                  }
              }
          }
          .buttonStyle(.plain)

          NavigationLink {
              StreakCalendarView(attempts: wakeAttempts)
          } label: {
              WPCard {
                  VStack(alignment: .leading, spacing: WPSpacing.xs2) {
                      Image(systemName: "calendar")
                          .wpFont(.title3)
                          .foregroundStyle(Color.wpVerified)
                      Text("Streak calendar").wpFont(.headline)
                      Text("Every verified morning").wpFont(.footnote).foregroundStyle(Color.wpChar500)
                  }
              }
          }
          .buttonStyle(.plain)
      }
  }
  ```

- [ ] **Step 2: Run full suite — expect 392 passed**

- [ ] **Step 3: UAT** — both cards navigate correctly. Tap target matches design-system 44pt minimum (both cards are 88pt+).

- [ ] **Step 4: Commit**

  ```bash
  git add WakeProof/WakeProof/Alarm/AlarmSchedulerView.swift
  git commit -m "UI 3.3: Secondary IA (Your commitment + Streak calendar as cards)

  Direction A: promote 'Your commitment' (H4) out of a buried NavigationLink
  list row into a first-class card alongside the streak calendar.

  Tests: 392/0.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 3.4: Commitment-note card polish

**Files:**
- Modify: `WakeProof/WakeProof/Alarm/AlarmSchedulerView.swift`

- [ ] **Step 1: Wrap the commitment-note TextField in a WPCard** so it reads as a first-class input, not a Form row. Apply cream-50 fill.

- [ ] **Step 2: Move the char counter to a right-aligned footnote** with warm-grey `Color.wpChar500`.

- [ ] **Step 3: Preserve the full `.onChange(of: commitmentNote)` truncation block** exactly as it was.

- [ ] **Step 4: Update placeholder copy** to match design-system voice: `"First thing tomorrow-you needs to do (optional)"` → stays as-is (the design-system allows the parenthetical "(optional)" per the existing copy audit). No rewording needed.

- [ ] **Step 5: Run full suite — expect 392 passed**

- [ ] **Step 6: UAT** — type + clear + relaunch. Note persists; char counter updates; truncation at `WakeWindow.commitmentNoteMaxLength` still works.

- [ ] **Step 7: Commit**

  ```bash
  git add WakeProof/WakeProof/Alarm/AlarmSchedulerView.swift
  git commit -m "UI 3.4: Commitment-note card polish

  Direction A: wrap H2 commitment-note TextField in WPCard, right-align char
  counter. Wiring (onChange truncation against WakeWindow.commitmentNoteMaxLength)
  preserved.

  Tests: 392/0.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 3.5: Empty / loading states

**Files:**
- Modify: `WakeProof/WakeProof/Alarm/AlarmSchedulerView.swift`

- [ ] **Step 1: Add a fresh-install empty hero** — when both `scheduler.nextFireAt == nil` AND `wakeAttempts.isEmpty`, render a WPCard with copy: "Your contract starts the night you set an alarm." + primary button "Set your first alarm" which scrolls to the wake-window section (use `ScrollViewReader` + `.scrollTo("wake-window", anchor: .top)`).

- [ ] **Step 2: Add `.id("wake-window")` to the wake-window WPSection.**

- [ ] **Step 3: Run full suite — expect 392 passed**

- [ ] **Step 4: UAT** — fresh install (wipe app data): empty-hero CTA appears; tapping it scrolls to wake-window section.

- [ ] **Step 5: Commit**

  ```bash
  git add WakeProof/WakeProof/Alarm/AlarmSchedulerView.swift
  git commit -m "UI 3.5: Fresh-install empty hero + scroll-to wake-window

  Direction A: guide brand-new users into setting their first contract on
  the home surface rather than leaving them to discover the Toggle.

  Tests: 392/0.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

**Phase 3 gate checklist:**
- [ ] AlarmSchedulerView uses ScrollView+VStack, WPCard/WPSection/WPHeroTimeDisplay/WPStreakBadge/WPMetricCard tokens
- [ ] Wave 5 wiring (G1/H2/H3/H5) preserved in full
- [ ] Test count = 392
- [ ] `xcodebuild ... test` green
- [ ] Simulator UAT: fresh install + configured install + G1 disable path all functional

---

## Phase 4 — Morning Briefing Animation + Emotion Polish (Direction B)

**Phase gate — must hold before Phase 5:**
- MorningBriefingView uses `Color.wpChar900` (not `Color.black`)
- Sunrise reveal animation lands on VERIFIED result (1200ms per design-system)
- Commitment-note spring-in animation
- Observation fade-in with typewriter feel
- All props preserved (result/observation/commitmentNote/currentStreak/onDismiss + shareCardEnabled @AppStorage + shareCardFailed @State)
- `ImageRenderer` share-card path continues to work
- Test count = 392

### Task 4.1: Replace Color.black + apply wpSunrise reveal

**Files:**
- Modify: `WakeProof/WakeProof/Verification/MorningBriefingView.swift`

- [ ] **Step 1: Invoke `wakeproof-design` skill**. Note: sunrise gradient is **only** for MorningBriefingView on a VERIFIED result — do not reuse elsewhere.

- [ ] **Step 2: Replace the top-level `Color.black.ignoresSafeArea()` with a conditional:**

  ```swift
  var body: some View {
      ZStack {
          // VERIFIED → sunrise reveal. Non-success → warm-charcoal hero.
          if case .success = result {
              LinearGradient.wpSunrise
                  .ignoresSafeArea()
                  .opacity(revealOpacity)
                  .animation(.easeOut(duration: 1.2), value: revealOpacity)
          } else {
              Color.wpChar900.ignoresSafeArea()
          }
          // ... rest of VStack ...
      }
      .onAppear {
          // Stagger the reveal: sunrise fades in over 1200ms on first appear.
          withAnimation(.easeOut(duration: 1.2)) {
              revealOpacity = 1
          }
          // existing Self.logger.info(...) stays as-is
      }
  }
  ```

- [ ] **Step 3: Add `@State private var revealOpacity: Double = 0`** near the top of the struct, grouped with the other `@State` vars.

- [ ] **Step 4: Replace every `.foregroundStyle(.white.opacity(N))`** with `.foregroundStyle(Color.wpCream50.opacity(N))` using the same alpha values. Token migration — no semantic change.

- [ ] **Step 5: Run full suite — expect 392 passed**

- [ ] **Step 6: Simulator UAT** — trigger a successful verify (DEBUG button flow). Briefing shows sunrise reveal. Non-success cases (nil / failure / noSession) show flat warm-charcoal.

- [ ] **Step 7: Commit**

  ```bash
  git add WakeProof/WakeProof/Verification/MorningBriefingView.swift
  git commit -m "UI 4.1: MorningBriefing sunrise reveal on VERIFIED

  Direction B (docs/design-system/README.md § 'The sunrise gradient (reserved)'):
  1200ms sunrise fade on VERIFIED result. Non-success paths keep warm-charcoal
  hero (wpChar900) instead of pure black.

  Props + @AppStorage + @State wiring preserved (result, observation,
  commitmentNote, currentStreak, shareCardEnabled, shareCardFailed,
  makeShareImage).

  Tests: 392/0.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 4.2: Commitment-note spring-in

**Files:**
- Modify: `WakeProof/WakeProof/Verification/MorningBriefingView.swift`

- [ ] **Step 1: Add @State for note reveal**

  ```swift
  @State private var commitmentNoteOffset: CGFloat = 24
  @State private var commitmentNoteOpacity: Double = 0
  ```

- [ ] **Step 2: Apply offset + opacity** to the commitment-note Text:

  ```swift
  if let commitmentNote, !commitmentNote.isEmpty {
      Text(commitmentNote)
          .wpFont(.title2)
          .foregroundStyle(Color.wpCream50.opacity(0.95))
          .multilineTextAlignment(.center)
          .padding(.horizontal, WPSpacing.xl)
          .padding(.top, WPSpacing.md)
          .offset(y: commitmentNoteOffset)
          .opacity(commitmentNoteOpacity)
  }
  ```

- [ ] **Step 3: Trigger animation from .onAppear** with a 400ms delay so it lands after the sunrise:

  ```swift
  .onAppear {
      withAnimation(.easeOut(duration: 1.2)) { revealOpacity = 1 }
      withAnimation(.spring(response: 0.5, dampingFraction: 0.7).delay(0.4)) {
          commitmentNoteOffset = 0
          commitmentNoteOpacity = 1
      }
      // existing logger.info(...)
  }
  ```

- [ ] **Step 4: Run full suite — expect 392 passed**

- [ ] **Step 5: UAT** — briefing with commitment note shows the note springing up from below with warm emphasis.

- [ ] **Step 6: Commit**

  ```bash
  git add WakeProof/WakeProof/Verification/MorningBriefingView.swift
  git commit -m "UI 4.2: Commitment-note spring-in on briefing reveal

  Direction B: H2 user-authored note gets a 500ms spring (offset+opacity)
  that lands 400ms after the sunrise starts — so the user sees the sunrise,
  then their own sentence rises into it.

  Tests: 392/0.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 4.3: Observation ceremony (fade + italic)

**Files:**
- Modify: `WakeProof/WakeProof/Verification/MorningBriefingView.swift`

- [ ] **Step 1: Add @State**

  ```swift
  @State private var observationOpacity: Double = 0
  ```

- [ ] **Step 2: Wrap the "Claude noticed" block** with opacity + delay:

  ```swift
  if let observation, !observation.isEmpty {
      VStack(spacing: WPSpacing.xs2) {
          Text("Claude noticed")
              .wpFont(.caption)
              .foregroundStyle(Color.wpCream50.opacity(0.65))
          Text(observation)
              .wpFont(.footnote)
              .italic()
              .multilineTextAlignment(.center)
              .foregroundStyle(Color.wpCream50.opacity(0.7))
              .padding(.horizontal, WPSpacing.xl2)
              .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.top, WPSpacing.md)
      .opacity(observationOpacity)
  }
  ```

- [ ] **Step 3: Fire the fade-in from .onAppear** at +900ms:

  ```swift
  .onAppear {
      // ... existing sunrise + commitment-note animations ...
      withAnimation(.easeOut(duration: 0.6).delay(0.9)) {
          observationOpacity = 1
      }
      // ... existing logger ...
  }
  ```

- [ ] **Step 4: Run full suite — expect 392 passed**

- [ ] **Step 5: UAT** — observation block fades in after the commitment-note lands, reading as a "Claude's aside" rather than competing with the briefing.

- [ ] **Step 6: Commit**

  ```bash
  git add WakeProof/WakeProof/Verification/MorningBriefingView.swift
  git commit -m "UI 4.3: Observation ceremony (fade-in at +900ms)

  Direction B: H1 observation fades in 900ms after briefing reveal starts
  — reads as Claude's aside rather than headline prose. .fixedSize vertical
  handles CJK/EN length robustness on iPhone SE.

  Tests: 392/0.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 4.4: Share button subtlety + 'Start your day' CTA polish

**Files:**
- Modify: `WakeProof/WakeProof/Verification/MorningBriefingView.swift`

- [ ] **Step 1: Update ShareLink visual** — keep the existing `.underline()` + `.wpFont(.callout)` but swap `Color.white.opacity(0.6)` → `Color.wpCream50.opacity(0.55)`. Preserve the full `ShareCardModel.shouldShowShareButton(...)` gate and the case-success unwrap.

- [ ] **Step 2: "Start your day" CTA** stays with `.buttonStyle(.primaryWhite)` (the migrated variant now renders on dark surface with cream-50 fill + char-900 text). No copy change.

- [ ] **Step 3: Add haptic on the CTA tap** — iOS 17+ `.sensoryFeedback(.success, trigger: dismissed)` where `dismissed` flips on button tap. This gives the commitment-close moment a tactile anchor.

  ```swift
  @State private var dismissedTrigger: Bool = false

  // on CTA:
  Button("Start your day") {
      dismissedTrigger.toggle()
      onDismiss()
  }
  .buttonStyle(.primaryWhite)
  .padding(.horizontal, WPSpacing.xl2)
  .padding(.bottom, WPSpacing.xs2)
  .sensoryFeedback(.success, trigger: dismissedTrigger)
  ```

- [ ] **Step 4: Run full suite — expect 392 passed**

- [ ] **Step 5: UAT on real device (haptics need hardware)** — tap CTA, feel the success haptic. Share button hidden unless opted-in + streak>=1 + success.

- [ ] **Step 6: Commit**

  ```bash
  git add WakeProof/WakeProof/Verification/MorningBriefingView.swift
  git commit -m "UI 4.4: Start-your-day haptic + share button token migration

  Direction B: sensoryFeedback(.success) on the CTA gives the commitment-close
  moment a tactile anchor. Share button visual migrated to wpCream50 token;
  full shouldShowShareButton + case-success + shareCardFailed wiring preserved.

  Tests: 392/0.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

**Phase 4 gate:**
- [ ] MorningBriefingView uses wpChar900 / wpSunrise (no Color.black)
- [ ] 3 animations: sunrise fade, commitment-note spring, observation fade (staggered 0ms / +400ms / +900ms)
- [ ] Haptic on CTA
- [ ] ImageRenderer share-card still renders (re-verify with Preview "Success" or DEBUG fire-now flow)
- [ ] Test count = 392
- [ ] `xcodebuild ... test` green

---

## Phase 5 — Onboarding Rewrite (Direction C)

**Phase gate — must hold before Phase 6:**
- OnboardingFlowView brand moment lands ("An alarm your future self can't cheat.")
- BaselinePhotoView location-concept explainer clear
- BedtimeStep polish
- Permission primer sequence UNCHANGED (primer dismiss → systemPermission request)
- Test count = 392 (no logic layer changed)

### Task 5.1: Welcome / brand intro

**Files:**
- Modify: `WakeProof/WakeProof/Onboarding/OnboardingFlowView.swift`

Scope: first step's hero. Make the `"An alarm your future self can't cheat."` line read as the manifesto. Use wpChar900 background + wpCream50 text + wpPrimary-gradient `.foregroundStyle` on the "WakeProof" wordmark.

- [ ] **Step 1: Invoke `wakeproof-design` skill**. Open `preview/brand-app-icon.html` + `preview/brand-voice.html` + `ui_kits/ios/` onboarding mockup for reference.

- [ ] **Step 2: Read the current `OnboardingFlowView.swift`** to map the existing step list.

- [ ] **Step 3: Rewrite the welcome step** — WakeProof wordmark rendered with `.foregroundStyle(LinearGradient.wpPrimary)`, manifesto line in `WPFont.display`, secondary explanation in `WPFont.body` and `Color.wpCream50.opacity(0.75)`. Primary CTA "Set your wake-up contract" with `.buttonStyle(.primaryWhite)`.

- [ ] **Step 4: Preserve the flow controller state + next-step mechanics** — whatever `enum Step` / `@State private var step` pattern exists stays. Visual re-skin only.

- [ ] **Step 5: Run full suite — expect 392 passed**

- [ ] **Step 6: Simulator UAT** — wipe app data, boot onboarding. Welcome hero lands; tap "Set your wake-up contract" advances to next step.

- [ ] **Step 7: Commit**

  ```bash
  git add WakeProof/WakeProof/Onboarding/OnboardingFlowView.swift
  git commit -m "UI 5.1: Welcome hero + brand manifesto

  Direction C: first impression — WakeProof wordmark with wpPrimary gradient,
  manifesto line ('An alarm your future self can't cheat.') in display
  typography, warm-charcoal hero.

  Tests: 392/0.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 5.2: Permission primers token migration

**Files:**
- Modify: `WakeProof/WakeProof/Onboarding/OnboardingFlowView.swift` (or the file where `PermissionStepView`-style screens live — read first)

- [ ] **Step 1: Locate each permission primer** (notifications, camera, HealthKit). These already have copy aligned with design-system voice ("The contract needs a witness" for camera etc.). DO NOT CHANGE THE COPY.

- [ ] **Step 2: Migrate visual tokens** — backgrounds to `wpChar900`, text to `wpCream50`, primary CTA to `.primaryWhite`, secondary ("Not now") to a plain Button with `wpCream50.opacity(0.6)` text.

- [ ] **Step 3: DO NOT reorder, re-wrap, or delay the primer → systemPermission sequence.** Permission grant rate depends on the primer being visible immediately before the alert. Test by wiping + redoing onboarding; the system alert must appear within 1s of tapping the primer's CTA.

- [ ] **Step 4: Run full suite — expect 392 passed**

- [ ] **Step 5: UAT** — each primer visually matches brand, grant path unchanged.

- [ ] **Step 6: Commit**

  ```bash
  git add WakeProof/WakeProof/Onboarding/OnboardingFlowView.swift
  git commit -m "UI 5.2: Permission primers token migration

  Direction C: visual-only pass on each primer (notifications / camera /
  HealthKit). Copy + primer→systemPermission timing UNCHANGED — permission
  grant rate is load-bearing on that sequence.

  Tests: 392/0.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 5.3: Baseline capture — location concept + ritual

**Files:**
- Modify: `WakeProof/WakeProof/Onboarding/BaselinePhotoView.swift`

- [ ] **Step 1: Invoke `wakeproof-design` skill**. Open `ui_kits/ios/` baseline-capture mockup for reference.

- [ ] **Step 2: Read existing `BaselinePhotoView.swift`** to map the capture flow.

- [ ] **Step 3: Add an explainer card above the preview** with the existing shipped copy (verbatim): `"Pick the spot in your home where you will physically be when you successfully wake up — kitchen counter, bathroom sink, your desk. Capture it now in the lighting you'll see it in tomorrow morning."`

  Render in WPCard on cream-100 background, body text + `foregroundStyle(Color.wpChar900)`.

- [ ] **Step 4: Migrate capture button** to `.buttonStyle(.primaryConfirm)` (wpVerified) — this is the commitment moment.

- [ ] **Step 5: Preview image** retains its 260px max height + 16px rounded corner per README.md § Layout rules.

- [ ] **Step 6: Run full suite — expect 392 passed**

- [ ] **Step 7: UAT** — capture + retake flow unchanged; visual matches mockup.

- [ ] **Step 8: Commit**

  ```bash
  git add WakeProof/WakeProof/Onboarding/BaselinePhotoView.swift
  git commit -m "UI 5.3: Baseline capture ritual + location explainer card

  Direction C: location-concept explainer (verbatim shipped copy) above the
  preview, wpVerified 'Save baseline' primary CTA, cream-100 surface, 260pt
  preview frame preserved per README § Layout rules.

  Tests: 392/0.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 5.4: BedtimeStep polish + first-night ritual handoff

**Files:**
- Modify: `WakeProof/WakeProof/Onboarding/BedtimeStep.swift`

- [ ] **Step 1: Read existing `BedtimeStep.swift`** to map its save flow (has `saveFailureMessage` state per the existing code).

- [ ] **Step 2: Apply token pass** — same treatment: wpChar900 bg, wpCream50 text, primaryWhite CTA.

- [ ] **Step 3: Add an end-of-onboarding "contract active" confirmation** — after the last step saves, show a `WPCard` with copy `"Your contract is active — tomorrow at {formatted time}, Claude will be waiting."` + primary button "Enter WakeProof" that advances to AlarmSchedulerView. This is the commitment-contract transition moment. Em-dash per design-system voice rule (signature connector); sentence case; no emoji. If this copy is new to the product (not already shipped), surface it for user review before commit — voice fit may warrant a sharper line.

- [ ] **Step 4: Preserve `saveFailureMessage` inline warning** (same yellow footnote pattern).

- [ ] **Step 5: Run full suite — expect 392 passed**

- [ ] **Step 6: UAT** — complete onboarding end-to-end, see contract-active confirmation, transition to home.

- [ ] **Step 7: Commit**

  ```bash
  git add WakeProof/WakeProof/Onboarding/BedtimeStep.swift
  git commit -m "UI 5.4: Bedtime polish + contract-active confirmation

  Direction C: final onboarding step gets a confirmation moment — 'Your
  contract is active. Tomorrow morning at HH:MM, Claude will be waiting.'
  Signals to the user that the contract is now binding.

  saveFailureMessage wiring preserved.

  Tests: 392/0.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

**Phase 5 gate:**
- [ ] Welcome hero (manifesto + wordmark gradient + primary CTA)
- [ ] Permission primers visual pass; primer→systemPermission sequence unchanged
- [ ] Baseline capture location-concept card + primaryConfirm CTA
- [ ] Contract-active confirmation moment
- [ ] Test count = 392
- [ ] `xcodebuild ... test` green

---

## Phase 6 — Secondary Surfaces Polish

**Phase gate — must hold before Phase 7:**
- AlarmRingingView / DisableChallengeView / StreakCalendarView / InvestmentDashboardView / AntiSpoofActionPromptView / WeeklyInsightView / ShareCardView migrated to tokens
- `StreakBadgeView.swift` deprecated: file either deleted OR forwards to `WPStreakBadge`; all existing call sites in AlarmSchedulerView work
- Test count = 392
- `xcodebuild ... test` green

### Task 6.1: AlarmRingingView token migration

**Files:**
- Modify: `WakeProof/WakeProof/Alarm/AlarmRingingView.swift`

- [ ] **Step 1: Replace `Color.black` → `Color.wpChar900`** on the `ZStack`.

- [ ] **Step 2: Replace the inline `TimelineView(.periodic...)` block with `WPHeroTimeDisplay(style: .large)`.**

- [ ] **Step 3: Migrate `.foregroundStyle(.white)` → `.foregroundStyle(Color.wpCream50)`** on the "Meet yourself at..." / "Prove you're awake." text.

- [ ] **Step 4: Migrate spacing to tokens** — `spacing: 24` → `spacing: WPSpacing.xl`, `.padding(.bottom, 32)` → `.padding(.bottom, WPSpacing.xl2)`.

- [ ] **Step 5: Preserve `onRequestCapture: () -> Void` closure + `scheduler.lastCaptureError` handling.**

- [ ] **Step 6: Run full suite — expect 392 passed**

- [ ] **Step 7: UAT (DEBUG fire-now)** — ring screen shows warm-charcoal hero + pill gradient CTA.

- [ ] **Step 8: Commit**

  ```bash
  git add WakeProof/WakeProof/Alarm/AlarmRingingView.swift
  git commit -m "UI 6.1: AlarmRingingView token migration (wpChar900 + WPHeroTimeDisplay)

  Direction B neighbour: ring screen uses wpChar900, WPHeroTimeDisplay(.large),
  cream-50 text, WPSpacing tokens. onRequestCapture closure + lastCaptureError
  banner preserved.

  Tests: 392/0.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 6.2: DisableChallengeView ritual polish

**Files:**
- Modify: `WakeProof/WakeProof/Alarm/DisableChallengeView.swift`

- [ ] **Step 1: Read existing `DisableChallengeView.swift`** — two-step (explainer → capture) flow must be preserved byte-identically. Only visual layer changes.

- [ ] **Step 2: Replace `Color.black` → `Color.wpChar900` on the background.**

- [ ] **Step 3: Step 1 explainer** — use existing shipped copy: `"Prove you're awake to disable."` / `"Meet yourself at {location} first — same as a morning ring."` — wpFont(.title2) + wpFont(.body), wpCream50 + wpCream50.opacity(0.75).

- [ ] **Step 4: lock.shield SF Symbol** — wpCream50.opacity(0.9), size 64 per README § Iconography.

- [ ] **Step 5: Primary button** — `.buttonStyle(.primaryAlarm)` for "Start challenge" (same radius as morning alarm CTA — this IS a morning-alarm-equivalent ritual).

- [ ] **Step 6: Run full suite — expect 392 passed**

- [ ] **Step 7: UAT** — from home, toggle alarm OFF when out of 24h grace, DEBUG bypass OFF. Challenge explainer → capture path works.

- [ ] **Step 8: Commit**

  ```bash
  git add WakeProof/WakeProof/Alarm/DisableChallengeView.swift
  git commit -m "UI 6.2: DisableChallengeView ritual polish

  Direction A/B nbr: G1 disable-challenge gets ritual treatment — wpChar900
  hero, primaryAlarm CTA parity with morning ring. Two-step explainer→capture
  sequence (Wave 5 G1) preserved.

  Tests: 392/0.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 6.3: StreakCalendarView month grid

**Files:**
- Modify: `WakeProof/WakeProof/Alarm/StreakCalendarView.swift`

- [ ] **Step 1: Read existing** `StreakCalendarView.swift` to understand the grid rendering + verdict tagging.

- [ ] **Step 2: Migrate day cells** — verified days: wpVerified fill + wpCream50 check mark; attempted-but-not-verified: wpAttempted fill; absent: wpChar300 stroke circle.

- [ ] **Step 3: Month header** — `WPFont.title3` + `wpChar900`.

- [ ] **Step 4: Background** — `Color.wpCream100`.

- [ ] **Step 5: Run full suite — expect 392 passed**

- [ ] **Step 6: UAT** — simulate a few attempts, verify color coding matches expected verdict on each cell.

- [ ] **Step 7: Commit**

  ```bash
  git add WakeProof/WakeProof/Alarm/StreakCalendarView.swift
  git commit -m "UI 6.3: StreakCalendar token pass (verified/attempted/absent)

  Direction A nbr: month grid uses wpVerified / wpAttempted / wpChar300
  per design-system § 'Palette at a glance'.

  Tests: 392/0.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 6.4: InvestmentDashboardView to WPMetricCard

**Files:**
- Modify: `WakeProof/WakeProof/Alarm/InvestmentDashboardView.swift`

- [ ] **Step 1: Read existing** `InvestmentDashboardView.swift` — identify each metric (baseline age, verified count, insights count) + framing copy.

- [ ] **Step 2: Replace hand-rolled metric rendering with WPMetricCard** for each of the 3 metrics. Set `accent: true` on the primary metric (verified count) to apply the gradient-fill numeral.

- [ ] **Step 3: Preserve the framing line** — per Wave 5 H4 commitment framing copy, wpFont(.body) + wpChar900 on cream.

- [ ] **Step 4: Background** — `Color.wpCream100`.

- [ ] **Step 5: Run full suite — expect 392 passed**

- [ ] **Step 6: Commit**

  ```bash
  git add WakeProof/WakeProof/Alarm/InvestmentDashboardView.swift
  git commit -m "UI 6.4: InvestmentDashboard via WPMetricCard

  Direction A nbr: H4 dashboard uses WPMetricCard for baseline age /
  verified mornings / insights collected. Framing line + Wave 5 H4 metric
  computation preserved.

  Tests: 392/0.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 6.5: StreakBadgeView deprecation (forward to WPStreakBadge)

**Files:**
- Modify: `WakeProof/WakeProof/Alarm/StreakBadgeView.swift` (or delete — see step 3)

- [ ] **Step 1: Check AlarmSchedulerView for call sites** — grep for `StreakBadgeView`. Phase 3 Task 3.1 should already have replaced the renderer call with `WPStreakBadge`. Remaining references are likely only to `StreakBadgeView.shouldRender(...)`.

  ```bash
  grep -rn "StreakBadgeView" WakeProof/WakeProof/
  ```

- [ ] **Step 2: Decision** — if the ONLY remaining reference is `StreakBadgeView.shouldRender(...)`, replace all call sites with `WPStreakBadge.shouldRender(...)` and delete `StreakBadgeView.swift` entirely. If the renderer is still referenced, replace it with `WPStreakBadge` at the call site.

- [ ] **Step 3: Delete the file**

  ```bash
  git rm WakeProof/WakeProof/Alarm/StreakBadgeView.swift
  ```

- [ ] **Step 4: Update Xcode project.pbxproj** to drop the StreakBadgeView.swift reference. In Xcode: right-click the file in the navigator → Delete → Move to Trash. This is the cleanest way to update the pbxproj.

- [ ] **Step 5: Run full suite — expect 392 passed**

  If StreakBadgeViewTests existed, expect 392 - N_badge_tests. Phase 2 Task 2.5's component smoke tests cover the same shouldRender contract.

- [ ] **Step 6: Commit**

  ```bash
  git add -A
  git commit -m "UI 6.5: Delete StreakBadgeView.swift (folded into WPStreakBadge)

  Phase 2 Task 2.5 established WPStreakBadge as the canonical implementation
  with a preserved shouldRender(currentStreak:bestStreak:) contract. All
  call sites in AlarmSchedulerView already reference WPStreakBadge (Phase 3
  Task 3.1). Removing the old file now that the migration is complete.

  Tests: 392/0.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 6.6: AntiSpoofActionPromptView softer retry tone

**Files:**
- Modify: `WakeProof/WakeProof/Verification/AntiSpoofActionPromptView.swift`

- [ ] **Step 1: Read existing** — preserve the action-prompt text (blink, turn left, etc. — driven by VisionVerifier).

- [ ] **Step 2: Migrate visual** — wpChar900 bg, wpCream50 text, primary action in wpFont(.title2), wpCoral accent on the action emphasis (e.g. the verb).

- [ ] **Step 3: Preserve retry-count + timing wiring** (whatever @State / observer exists).

- [ ] **Step 4: Run full suite — expect 392 passed**

- [ ] **Step 5: Commit**

  ```bash
  git add WakeProof/WakeProof/Verification/AntiSpoofActionPromptView.swift
  git commit -m "UI 6.6: AntiSpoofActionPromptView token pass

  Tests: 392/0.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 6.7: WeeklyInsightView + ShareCardView token migration

**Files:**
- Modify: `WakeProof/WakeProof/Verification/WeeklyInsightView.swift`
- Modify: `WakeProof/WakeProof/Alarm/ShareCardView.swift`

- [ ] **Step 1: WeeklyInsightView** — migrate background (`Color.wpCream100` on light / `Color.wpChar800` on dark), text tokens, `.foregroundStyle(Color.wpChar500)` for secondary. Preserve `generatedAt` + `insight` props.

- [ ] **Step 2: ShareCardView** — the 1080×1920 render canvas uses its own background (currently some hand-picked color). Migrate to `LinearGradient.wpPrimary` fill per the design-system hero-image rule, streak digit in `.wpFont(.heroXL)` with `.monospacedDigit()` + `.foregroundStyle(Color.wpCream50)`, observation in wpFont(.callout) italic. Preserve the `streak` + `observation` prop shape so `ShareCardModel.shouldShowShareButton` gate and `ImageRenderer` caller work unchanged.

- [ ] **Step 3: Re-test share render by hitting DEBUG Finalize-briefing path** and tapping the share button. Render output should show gradient background + hero streak digit + italic observation.

- [ ] **Step 4: Run full suite — expect 392 passed**

- [ ] **Step 5: Commit**

  ```bash
  git add WakeProof/WakeProof/Verification/WeeklyInsightView.swift WakeProof/WakeProof/Alarm/ShareCardView.swift
  git commit -m "UI 6.7: WeeklyInsight + ShareCard token migration

  ShareCard uses wpPrimary gradient bg, heroXL streak digit, callout italic
  observation. Props + ImageRenderer wiring preserved.

  Tests: 392/0.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  ```

**Phase 6 gate:**
- [ ] 6 surface files migrated (+1 deprecation)
- [ ] Every `Color.white` / `Color.black` / `.white.opacity(...)` / `.black.opacity(...)` in touched files replaced with tokens (verify via grep: `grep -rn 'Color.white\|Color.black\|\.white\.opacity\|\.black\.opacity' WakeProof/WakeProof/Alarm/ WakeProof/WakeProof/Verification/ WakeProof/WakeProof/Onboarding/`)
- [ ] Test count = 392
- [ ] `xcodebuild ... test` green

---

## Phase 7 — Review Loop

**Every phase must pass these reviews before advancing.** Run them at the end of each phase, not just the end of Phase 6.

### Task 7.1: Per-phase adversarial review

After each Phase 1-6 closes its gate, dispatch:

- [ ] **Step 1: Run `adversarial-review` skill** on the phase's commits. Scope argument: `git diff <phase-start-sha>..HEAD`.

- [ ] **Step 2: Triage findings** — every issue regardless of severity (per `CLAUDE.md` review rule) must be either fixed or explicitly marked won't-fix with a technical reason.

- [ ] **Step 3: Fix all findings** → commit → re-run adversarial review.

- [ ] **Step 4: Commit fixes as** `UI <phase>.review: <N> adversarial findings fixed`.

---

### Task 7.2: Per-phase code review via pr-review-toolkit

- [ ] **Step 1: Dispatch `pr-review-toolkit:code-reviewer`** on the phase's diff.

- [ ] **Step 2: Fix all findings** → commit → re-review.

- [ ] **Step 3: Commit as** `UI <phase>.code-review: <N> findings fixed`.

---

### Task 7.3: Simplify pass

- [ ] **Step 1: Invoke `simplify` skill** on the phase's diff.

- [ ] **Step 2: Apply simplifications** → commit.

- [ ] **Step 3: Commit as** `UI <phase>.simplify: <N> reductions`.

---

### Task 7.4: End-of-Phase-6 UAT review

After Phase 6 closes and all 6 phase-level reviews are clean:

- [ ] **Step 1: Invoke `uat-review` skill** on the full app.

- [ ] **Step 2: Work through findings** — visual polish, copy checks, accessibility (VoiceOver, Dynamic Type, contrast).

- [ ] **Step 3: Commit as** `UI uat: <N> UAT findings fixed`.

- [ ] **Step 4: Re-run `uat-review` until clean.**

---

## Phase 8 — Device Verification

**Phase gate:**
- All 6 surfaces verified on real device (not simulator).
- Demo script end-to-end works: onboarding → baseline → set alarm → alarm rings → capture → verify → briefing reveal → streak increments → share card renders → disable challenge fires when alarm toggled OFF without 24h grace.

### Task 8.1: Demo script end-to-end on real device

- [ ] **Step 1: Install dev build on the paired iPhone** (team JD337PDHDV, paid Developer Program).

- [ ] **Step 2: Wipe app data, run fresh onboarding** — capture baseline, set bedtime, complete contract-active confirmation.

- [ ] **Step 3: Set an alarm for ~2 min from now with a commitment note** ("test — make coffee").

- [ ] **Step 4: Lock device, silent mode, wait for alarm.**

- [ ] **Step 5: Ring → Prove you're awake → capture → verify → briefing** — verify the sunrise reveal is smooth, commitment-note springs in, observation fades in.

- [ ] **Step 6: Check streak incremented + share card renders** (tap share, inspect preview).

- [ ] **Step 7: Toggle alarm OFF** — since <24h grace may apply, force 24h+ path via DEBUG bypass OFF → verify challenge flow lands.

- [ ] **Step 8: Record ~3 min demo video.**

- [ ] **Step 9: Report findings to user.** If any regression, file as a UAT issue and fix before Phase 9.

---

## Phase 9 — Push Strategy

**User-confirmed step only. Claude Code does not execute `git push` without explicit user yes.**

- [ ] **Step 1: Ask the user:** "Per-phase push OR bundled push after UAT clean? origin/main is behind by `<N commits>` (Phase 1-6 + reviews)."

- [ ] **Step 2: On user yes, run** `git push origin main`. Report SHA + CI status (if any).

- [ ] **Step 3: If user declines push**, keep commits local. No action needed.

---

## Glossary (for subagent context)

- **Wave 5** = the last-completed body of engagement + defense work (H1-H5 + G1 + G3). UI layer is in-scope here; logic layer is NOT.
- **Design system LOCK** = tokens / voice / palette / type decisions are fixed in `docs/design-system/`. This plan transcribes + applies; it does not re-decide.
- **Token** = a named design constant (`Color.wpCream100`, `WPSpacing.xl`, `WPRadius.md`) derived from `docs/design-system/colors_and_type.css`.
- **Component** = a reusable SwiftUI `View` consuming tokens (WPCard, WPSection, WPMetricCard, WPHeroTimeDisplay, WPStreakBadge).
- **Surface** = an existing production SwiftUI view being migrated to tokens + components (AlarmSchedulerView, MorningBriefingView, …).
- **wakeproof-design skill** = the symlinked design-system skill at `.claude/skills/wakeproof-design`. Every subagent invokes this before touching a file so the tokens + voice rules + SwiftUI Color extension are in context.
- **Phase gate** = a hard checkpoint. Do not advance past a gate that has not passed.
- **Invariants** = rules that hold at every commit (tests 366+, no `!`, no `print`, no `Color.black`/`.white` after Phase 1, voice rules, Wave 5 wiring).

---

## Post-plan: session-state + handoff

After this plan is written:

1. **Save to**: `docs/plans/2026-04-25-ui-rewrite-phase-1-6.md`
2. **Review loop**: dispatch a single `plan-document-reviewer` subagent against this file + this plan's implicit spec (the handoff prompt the user pasted) per `writing-plans/plan-document-reviewer-prompt.md`.
3. **After reviewer approves**, offer the user the two execution options:
   - **Subagent-Driven (recommended)** — fresh subagent per task, review between, fast iteration, handoff via `subagent-driven-development` skill. RECOMMENDED per handoff step 10.
   - **Inline Execution** — execute tasks sequentially in this session with TodoWrite tracking.
