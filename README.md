# WakeProof

> An iOS alarm that verifies you're actually awake using Claude Opus 4.7 vision.
> A self-commitment device, not a sleep tracker. Future-you can't cheat past-you's contract.

Built for the Cerebral Valley × Anthropic **"Built with Opus 4.7: a Claude Code hackathon"** (Apr 21–26, 2026).

## The problem

iOS Clock alarms can be dismissed with a thumb on the lock screen, eyes still closed, body still horizontal. Third-party "alarm" apps give you a math puzzle you solve in bed. None of them prove you're *out of bed*.

## The mechanic

1. **Onboarding** — user takes a baseline photo at their designated awake-location (kitchen, bathroom sink, desk lamp).
2. **Alarm rings** — keeps ringing. Only way to silence it is to take a new live photo.
3. **Verification** — Claude Opus 4.7 compares new photo to baseline: same location, eyes open, upright, room lit, appears alert.
4. **Anti-spoofing** — retries add random action prompts: "blink twice", "show your right hand".
5. **Fail** — alarm continues escalating. No dismiss button.

## Why Opus 4.7

This is not a classification task a smaller model can handle reliably. It needs:

- **Vision** comparing two photos for location consistency
- **Reasoning** over whether the scene suggests wakefulness (body posture, eye openness, lighting)
- **Insight generation** from accumulated wake-up patterns across nights

A single Opus 4.7 call does the work that would otherwise need three specialized models stitched together.

## Stack

- **iOS:** Swift + SwiftUI, iOS 17+
- **AI:** Claude Opus 4.7 (vision verification, insight generation); Claude Sonnet 4.6 (non-vision text, cost-sensitive paths)
- **Storage:** SwiftData local-first. No backend required to run the demo.
- **Audio:** Foreground audio session + critical alert notifications (Alarmy-style workaround — iOS has no public Alarm API).

## Status

🛠 In active sprint. Submission deadline Apr 26 8:00 PM EDT (Apr 27 8:00 AM HKT).

## Running

1. Clone this repo
2. Open `WakeProof.xcodeproj` in Xcode 15+
3. Add your Claude API key to `WakeProof/Secrets.swift` (not committed — see `Secrets.swift.example`)
4. Select a physical iOS device (simulator does not support background audio behaviour reliably)
5. Build & run

## Claude Code usage

All Swift in this repo was generated and refined through Claude Code sessions guided by `CLAUDE.md`. See that file for project context if you're exploring with Claude Code yourself.

## Secret-scanning pre-commit hook (opt-in)

This repo ships an opt-in pre-commit hook at `.githooks/pre-commit` that blocks commits containing what looks like a 64-char hex proxy token. It's opt-in because Git's default hooks directory is `.git/hooks/` and we don't want to surprise contributors by enabling it silently.

Enable once per clone:

```bash
git config core.hooksPath .githooks
chmod +x .githooks/pre-commit
```

The hook skips known-safe paths (`/Fixtures/`, `.gitignore`, `Secrets.swift`). To allowlist additional paths (e.g. a SHA-256 test fixture outside `/Fixtures/`), add one path substring per line to `.githooks/pre-commit-allowlist`. The `scripts/layer2-smoke.py` + `scripts/generate-weekly-insight.py` helpers instruct devs to grep the proxy token out of gitignored `Secrets.swift` and pipe it to env vars or stdout — both common vectors for accidentally capturing the token in a committed debug file, which is what the hook is meant to catch.

## License

MIT — see [LICENSE](./LICENSE).
