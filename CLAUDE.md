# CLAUDE.md — WakeProof

Context for any Claude Code session working in this repo.

## What this is

An iOS alarm app built solo in 5 days for Cerebral Valley × Anthropic's "Built with Opus 4.7" hackathon (Apr 21–26, 2026). The core mechanic: a baseline photo captured during onboarding is compared against a live photo taken when the alarm rings, using Claude Opus 4.7 vision to verify the user is actually awake and out of bed.

Positioning is a **self-commitment device**, not a sleep tracker. Anything that sounds like "Apple Watch sleep staging" is out of scope.

## Tech stack (locked — don't re-litigate)

- **UI:** Swift + SwiftUI, iOS 17+
- **Storage:** SwiftData, local-first. No Supabase unless multi-device sync becomes demo-relevant.
- **AI:** Claude Opus 4.7 (`claude-opus-4-6` was the prior; this repo uses Opus 4.7) for vision + insight generation. Claude Sonnet 4.6 (`claude-sonnet-4-6`) for non-vision text to conserve credits.
- **Audio:** Foreground audio session + local notifications + critical alert request. Alarmy-style.
- **No React Native.** Bridges for HealthKit / audio session / Screen Time are unreliable on a 5-day budget.

## Architecture

```
WakeProof/
├── App/
│   └── WakeProofApp.swift          # Entry point, top-level state
├── Onboarding/
│   ├── OnboardingFlowView.swift    # Multi-step flow controller
│   ├── PermissionStepView.swift    # Contextual permission screens
│   └── BaselinePhotoView.swift     # Capture the reference photo
├── Alarm/
│   ├── AlarmScheduler.swift        # When the alarm fires
│   ├── AudioSessionKeepalive.swift # Keeps audio session alive overnight
│   ├── AlarmSoundEngine.swift      # Volume ramps, sound switches
│   └── AlarmRingingView.swift      # The "wake up" screen
├── Verification/
│   ├── CameraCaptureView.swift     # Live photo / 2-sec video
│   ├── VisionVerifier.swift        # Calls Claude Opus 4.7 vision API
│   └── VerificationResult.swift    # Verdict model + decoding
├── Services/
│   ├── PermissionsManager.swift    # Centralised permission requests
│   ├── ClaudeAPIClient.swift       # Thin wrapper around Messages API
│   └── Secrets.swift               # Git-ignored; API key lives here
└── Storage/
    ├── BaselinePhoto.swift         # SwiftData model
    ├── WakeAttempt.swift           # SwiftData model (attempts log)
    └── PersistenceController.swift # ModelContainer setup
```

This is the *target* structure. Day 1 will not have all of it — scaffold as we go.

## Key design principles

1. **Photo verification must feel trustworthy.** If the user can cheat it by showing a printed photo of themselves standing in the kitchen, the whole product is undermined. Anti-spoofing (random action prompts) is not optional.

2. **The alarm must not be bypassable.** No "dismiss" button. No snooze without re-verification. No force-quit escape hatch we could reasonably plug (we can't fully prevent force-quit on iOS, but we shouldn't expose an easier path).

3. **Opus 4.7 is the cognitive layer, not a helper.** It does vision + reasoning + insight generation in one call where a naive build would stitch three narrower models.

4. **Local-first.** Every feature should work with airplane mode on, except the Opus 4.7 verification step. Document the graceful-degrade path for offline.

## Hackathon judging weights

- Impact 30% — universal pain (everyone snoozes), mechanic generalizes beyond sleep
- Demo 25% — live on-device demo must be flawless
- Opus 4.7 use 25% — vision + reasoning + insight, not just one API call
- Depth & execution 20% — polish, error handling, real engineering

Special prizes worth targeting:
- **Most Creative Opus 4.7 Exploration** ($5k) — the photo-as-trust-contract angle
- **Best use of Claude Managed Agents** ($5k) — only pursue if Day 2 research confirms feasibility

## Conventions for Claude Code sessions

- Use `SwiftUI` over `UIKit` unless a behaviour genuinely requires UIKit (camera preview may).
- Use `@Observable` macro (iOS 17+) for view models, not `@ObservableObject`.
- Use `async/await` for all Claude API calls. No Combine.
- Use structured concurrency (`Task`, `TaskGroup`) for parallel API calls.
- Use `Logger` from `os` for logging, with a per-subsystem category. No `print()`.
- Use `try-await` with specific error types per service, not `Error`.
- SwiftData over Core Data. If Core Data is needed for a reason, document the reason.
- No force unwraps in committed code. No `!` outside of test fixtures.
- Info.plist usage descriptions are required for every permission — see `docs/info-plist-requirements.md`.

## Core development principles (promoted from CLAUDE-Reference.md)

Project-agnostic rules that apply regardless of language/framework. The RN/TypeScript-specific patterns in CLAUDE-Reference.md do NOT apply here — see that file only for the universal principles.

### Work style
- **小步前進** — each change must compile. No big-bang refactors.
- **先理解再動手** — find 3 similar existing implementations before writing new code.
- **務實不教條** — adapt to the project's reality, don't over-engineer for abstract theory.
- **單一職責** — each function/view does one thing.
- **避免過早抽象** — wait for the third repetition before extracting.
- **意圖清晰** — pick the most direct phrasing; if it needs explaining, it's too complex.

### 卡關協議 (CRITICAL)
Same problem, max 3 attempts. Then STOP:
1. Record what was tried + exact error messages
2. Question assumptions — wrong abstraction level? simpler framing? fewer layers not more?
3. Report to user with 2-3 alternative directions

### 決策框架 (tie-breaker order when multiple options exist)
1. **Testability** — can this be verified easily (device test counts)?
2. **Readability** — understandable in 6 months?
3. **Consistency** — matches existing project patterns?
4. **Simplicity** — simplest viable path?
5. **Reversibility** — how hard to change later?

### Review issue handling (MANDATORY)
Any issue surfaced by `adversarial-review`, `/simplify`, `uat-review`, or peer review — **regardless of severity** (Critical/Important/Medium/Low) — must be addressed:
- **Fix** — modify code to resolve, OR
- **Explicitly mark "won't fix"** — with a technical reason (e.g. "protected by iOS sandbox", "pre-existing design tradeoff — see decision N")

Never skip by severity. Never defer Medium/Low while fixing only Critical. Never pass a phase gate with open review issues.

### Commit gate (mandatory before every commit)
- [ ] Builds successfully, no new warnings in touched files
- [ ] Relevant verification gate passed (device test if touched runtime-sensitive code)
- [ ] Error paths use `Logger` from `os`, not silent catch / `print()`
- [ ] No force unwraps, no `!` outside test fixtures
- [ ] No hardcoded API keys outside `Services/Secrets.swift`
- [ ] Commit message explains WHY, not WHAT

### 禁止事項
- `--no-verify` to bypass commit hooks
- Disabling failing tests instead of fixing them
- Committing non-compiling code
- Assumptions — read existing code to verify before changing
- Undocumented TODOs (each TODO must cite a reason)

### 費用安全與不可逆操作 (confirmation required)
Must have explicit user confirmation before executing:
- `git push` / `git push --force` / `git rebase` / `git reset --hard`
- Any `rm -rf` / destructive file deletion
- Anthropic API batch runs or > ~20 calls in succession (we have $500 total budget)
- TestFlight submission / App Store Connect upload
- Auto-generating new `.md` documentation files (unless user asked)

Safe to auto-execute: `git add`, `git commit` (only when asked), reads/searches, Xcode builds, single planned API calls.

### Multi-phase review pipeline (when doing large changes)
When a feature spans multiple Waves/phases, each phase goes through in order:
1. Implement
2. `adversarial-review` (red-team the diff)
3. Fix surfaced issues
4. `/simplify` (reuse + quality pass)
5. `pr-review-toolkit:review-pr` if branch is PR-bound
6. Fix surfaced issues → `/simplify` again → re-review until zero issues
7. Only then advance to next phase

## What Claude Code should NOT do

- Do not add React Native, JS bridges, or Expo anything.
- Do not add analytics SDKs (Mixpanel, Amplitude, Firebase).
- Do not add a backend unless explicitly asked (Supabase / Cloudflare / Vercel).
- Do not suggest features that expand scope beyond the 5-day plan in `docs/build-plan.md`.
- Do not claim the app detects sleep stages from iPhone alone — HealthKit read-only is the ceiling.
- Do not hardcode the API key anywhere except `Services/Secrets.swift` (git-ignored).

## Testing philosophy

This is a 5-day hackathon build — no XCTest suite is mandated, but:

- Every vision-verification prompt change must be exercised against the test fixture folder (`docs/test-scenarios.md` describes the 5 scenarios) before merging.
- The audio session keepalive must be validated on real device, 30+ minutes, screen locked, silent mode on — simulator results don't count.

## Demo-day framing (copy for pitches / slides)

> "WakeProof creates a wake-up contract you can't unsign. Apple's Clock can be muted in 2 seconds. WakeProof can't."

> "Opus 4.7 is doing three jobs at once: vision (is this the same kitchen?), reasoning (do those eyes look open or is that a printed photo?), and insight generation (what did last night's data suggest about tomorrow's wake-up plan?)."

## Reference docs

- `docs/build-plan.md` — day-by-day schedule (reference only, not hard rule; we can run ahead)
- `docs/technical-decisions.md` — locked architectural decisions with rejected alternatives
- `docs/go-no-go-audio-test.md` — the foundation test that determines whether this whole approach works
- `docs/info-plist-requirements.md` — every permission key + copy
- `docs/vision-prompt.md` — the Opus 4.7 verification prompt (versioned)
- `docs/plans/` — implementation plans produced by `writing-plans` skill; phase gates are hard checkpoints
- `CLAUDE-Reference.md` — universal engineering principles (source of the "Core development principles" section above)
