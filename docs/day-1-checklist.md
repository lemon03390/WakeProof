# Day 1 Execution Checklist (Apr 22 HKT)

Printable version of what to actually do today. Roughly sequenced.

## Admin (do while coffee brews — ~1h)

- [ ] Confirm Discord role assigned via https://anthropic.com/discord and check hackathon channels are visible
- [ ] Read every pinned message in `#announcements`
- [ ] Watch kickoff recording if posted (2× speed)
- [ ] Claim $500 API credits at console.anthropic.com. Create a **dedicated key** for WakeProof — do not reuse TCM Pro key.
- [ ] Save key into `WakeProof/Secrets.swift` (copy from `.example`). Confirm `.gitignore` ignores it before first commit.
- [ ] Create public GitHub repo `wakeproof`. Add MIT license at creation time. Leave README empty — we'll commit ours.

## Repo bootstrapping (~30m)

From the workspace skeleton folder:

- [ ] `git clone <your-repo-url> wakeproof && cd wakeproof`
- [ ] Copy all files from `repo-skeleton/` into the repo root (README, LICENSE, .gitignore, CLAUDE.md, docs/, WakeProof/)
- [ ] `git add . && git commit -m "Repo skeleton"` — first commit before any Xcode noise

## Xcode project init (~30m)

- [ ] File > New > Project > iOS App. Product name: `WakeProof`. Interface: SwiftUI. Language: Swift. Storage: SwiftData. Tests: off (we're in a 5-day sprint).
- [ ] Save inside the cloned repo, same folder as the skeleton files. Let Xcode create `WakeProof.xcodeproj` alongside the existing `WakeProof/` folder. When Xcode asks whether to add existing files, say yes.
- [ ] Move Xcode's default `ContentView.swift` and `WakeProofApp.swift` to trash — ours replace them.
- [ ] In the target's Signing & Capabilities:
  - Team: your personal Apple ID
  - Bundle ID: `com.vincent.wakeproof` (or any that's unused)
  - Add capability: **Background Modes** → check **Audio, AirPlay, and Picture in Picture**
  - Add capability: **HealthKit** (no store auth needed)
- [ ] Add Info.plist keys from `docs/info-plist-requirements.md`
- [ ] Drop a placeholder `silence.m4a` (30 sec of silence) and `test-tone.m4a` (2 sec chime) into the bundle. Any silence/chime WAV converted to AAC will do — ffmpeg works fine.
- [ ] Build target → resolve any Swift compile errors (ask Claude Code to fix) → run on simulator first to confirm onboarding flow renders.

## GO/NO-GO audio test (~1.5h in elapsed time; ~15m active)

See `docs/go-no-go-audio-test.md` for full procedure.

- [ ] Install on real iPhone (Xcode-signed install is fine; no TestFlight needed)
- [ ] Flip ring/silent switch to SILENT
- [ ] Launch app, observe audio session log
- [ ] Lock screen, start 30-min timer, do something else
- [ ] At 30-min mark: app should auto-play test tone (schedule in `WakeProofApp.init`)
- [ ] **If tone plays audibly → PASS. Proceed.**
- [ ] **If no tone → FAIL. Stop. Write up the failure mode, start overnight 8h test, decide pivot tomorrow morning.**

## Baseline photo flow (~1h, only if audio passed)

- [ ] Run onboarding end-to-end on device
- [ ] Confirm each of the 5 permission prompts appears (critical alerts will deny — that's expected)
- [ ] Capture a baseline photo at your actual kitchen or bathroom
- [ ] Confirm it persists via SwiftData — force-quit and relaunch, app should skip onboarding and show placeholder home screen

## End-of-day wrap (~15m)

- [ ] `git add -A && git commit -m "Day 1: scaffolding, onboarding, audio keepalive"`
- [ ] `git push`
- [ ] Post to Discord `#introductions`: short intro, project name, one-liner. Do NOT mention your location.
- [ ] React to 5+ other intros — be a neighbour, not a lurker
- [ ] Write Day 2 top-3 priorities in a text file before sleeping

## Definition of done

Audio test PASS + onboarding flow complete + baseline photo persisted + repo pushed public.

If audio failed, replace the first item with "pivot plan drafted in `docs/technical-decisions.md` under a new Decision 8."
