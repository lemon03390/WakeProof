# Vision Verification Implementation Plan

> **For agentic workers:** Implement task-by-task, using the same plan→implement→adversarial-review→simplify pattern as `docs/plans/alarm-core.md`. Steps use checkbox (`- [ ]`) syntax for tracking. Phase gates are **hard checkpoints** — do NOT advance past a gate that has not passed.

**Goal:** End-of-Day-3 deliverable per `docs/build-plan.md` Day 3: the alarm fires → user captures a video → Claude Opus 4.7 vision evaluates baseline vs. still → verdict updates the persisted `WakeAttempt` row and either stops the alarm (VERIFIED), keeps it ringing with a visible failure reason (REJECTED), or triggers a random anti-spoof action prompt and a single re-capture (RETRY). The printed-photo-attack rejection is the demo money shot and must work on device before the phase closes.

**Architecture:** Three-phase, matching the alarm-core plan. **Phase A** adds all new files under strict additive-only rules: a git-ignored `Secrets.swift` template, a new `Services/ClaudeAPIClient.swift`, three new Verification files (`VerificationResult.swift`, `VisionVerifier.swift`, `VerifyingView.swift`, `AntiSpoofActionPromptView.swift`), and two new docs (`docs/vision-prompt.md` v1 and `docs/test-scenarios.md`). Phase A performs zero integration with live alarm flow — the existing Day 2 contract (`CameraCaptureFlow` → scheduler.markCaptureCompleted → stop) keeps running unchanged. **Phase B** extends `AlarmPhase` additively with two new cases (`.verifying`, `.antiSpoofPrompt(instruction:)`), relaxes two existing scheduler guards to accept the new source phases, swaps `CameraCaptureFlow.onSuccess` to hand off to `VisionVerifier` instead of the direct stop chain, and wires the verifier at the app root. **Phase C** runs the multi-phase review pipeline per `CLAUDE.md` (adversarial-review → simplify → re-review until zero issues).

**Tech Stack:** Swift + SwiftUI (iOS 17+). Claude API via direct `URLSession` (no SDK — keeps the surface tiny for review). Specific error types per service, `Logger(subsystem: "com.wakeproof.verification", …)` for all logs, structured concurrency only (`async`/`await`, `Task`). JSON decoding via `JSONDecoder` on the first `content[0].text` block the API returns. No new SPM dependencies. Baseline + still images are sent **full resolution** (baseline ≈ 3.75 MP JPEG from `BaselinePhoto.imageData`, still ≈ the `CameraCaptureResult.stillImage.jpegData(compressionQuality: 0.9)` already persisted on Day 2) — `docs/opus-4-7-strategy.md` Layer 1 collapses if either is pre-compressed.

**Non-goals for this plan (deferred to later plans):**
- Layer 2 Memory Tool integration (per-user `/memories` directory, injection into the vision call) — Day 4
- Layer 3 Managed-Agent overnight pipeline — Day 4
- Layer 4 weekly-coach 1M-context call — Day 4
- HealthKit sleep-summary rendering on the post-verify screen — Day 4
- Production-grade anti-spoof prompts beyond the fixed three (`Blink twice`, `Show your right hand`, `Nod your head`)
- On-device face detection pre-flight via Vision framework — Decision 2 marks it optional Day 4
- Critical-alert runtime flow (entitlement still unapproved)
- A SwiftData schema migration — the existing `WakeAttempt.verdict: String?` column already supports the new `VERIFIED/REJECTED/RETRY` values, per the C.1 won't-fix M1 disposition in `docs/plans/alarm-core.md`

---

## Critical constraints (Day 3)

The alarm core is validated end-to-end on device (`docs/plans/alarm-core.md` Phase B.3 PASS) and the test protocol at `docs/device-test-protocol.md` lists 8 known-good behaviours. We must not regress any of them. Specifically:

- **DO NOT** modify `WakeProof/WakeProof/Alarm/AlarmScheduler.swift` except to (a) add two new cases to the `AlarmPhase` enum, (b) add two new public transition methods (`beginVerifying()`, `beginAntiSpoofPrompt(instruction:)`, `returnToRingingAfterVerifying(error:)`), and (c) relax two existing guards (`beginCapturing` must accept `.antiSpoofPrompt` as a source; `returnToRingingWith(error:)` must accept `.verifying` as a source). No other edits. `fire()`, `cancel()`, `scheduleNextFireIfEnabled`, `recoverUnresolvedFireIfNeeded`, `handleRingCeiling`, `reconcileAfterForeground`, `recordAttempt`, `scheduleBackupNotification`, `persistLastFireAt` stay byte-for-byte unchanged.
- **DO NOT** modify `WakeProof/WakeProof/Alarm/AudioSessionKeepalive.swift` at all. Volume reduction during `.verifying` uses the existing `setAlarmVolume(_:)` API from outside the file.
- **DO NOT** modify `WakeProof/WakeProof/Alarm/AlarmSoundEngine.swift` at all. The 60 s ramp + 10 min ceiling contract is not in scope.
- **DO NOT** modify `WakeProof/WakeProof/Alarm/AlarmRingingView.swift` at all. The banner-error rendering path (`scheduler.lastCaptureError`) is re-used by REJECTED verdicts without code change.
- **DO NOT** break the `WakeAttempt` schema. Verdict updates mutate the existing row in place via the `modelContext.mainContext` already captured by `CameraCaptureFlow`; no new `@Model` class, no new non-optional fields.
- **DO NOT** hardcode the Claude API key anywhere except `WakeProof/WakeProof/Services/Secrets.swift` (already git-ignored at `.gitignore:2`). Every commit in this plan must be preceded by `git diff --cached` ensuring `Secrets.swift` is not staged. `Secrets.swift.example` (placeholder key) is the only committed file that mentions the key shape.
- **DO NOT** run more than one live Claude API call without user confirmation, per `CLAUDE.md` 費用安全. Two calls are scheduled: Task B.6 (single smoke test before device validation; announce to user first) and Task B.7 (the five on-device verification scenarios — effectively five sequential alarm fires, each producing one API call; budget ≈ $0.065, well under the batch threshold). Iteration beyond that requires the user to greenlight.
- **DO NOT** downsize images before the API call. `image_detail=high` is the only acceptable way to control Claude's vision processing; JPEG compression is already applied by Day 2 code at `compressionQuality = 0.9` and must not drop further.
- **DO NOT** run `git push`. Local commits only, per `CLAUDE.md` 費用安全.

Phase A is fully additive and carries zero runtime risk. Phase B integration is the point at which regression of the Day 2 contract becomes possible — the Phase B tasks run simulator builds after every integration step and the five-scenario device run is mandatory at B.7 before the plan advances.

---

## File Structure

New or modified in this plan:

| Path | Action | Responsibility |
|---|---|---|
| `WakeProof/WakeProof/Services/Secrets.swift.example` | Unchanged (audited) | Already exists and is git-tracked as the committable template. Canonical placeholder `"sk-ant-REPLACE_ME"` (underscore) + `visionModel = "claude-opus-4-7"` + `textModel = "claude-sonnet-4-6"`. Task A.1 audits these fields rather than rewriting the file. |
| `WakeProof/WakeProof/Verification/VerificationResult.swift` | Create | `Codable` struct matching the JSON verdict shape: `same_location / person_upright / eyes_open / appears_alert / lighting_suggests_room_lit / confidence / reasoning / spoofing_ruled_out / verdict`. `Verdict` enum (`VERIFIED / REJECTED / RETRY`) with `mapped: WakeAttempt.Verdict` accessor. `fromClaudeMessageBody(_:)` helper tolerates fenced `json` blocks and extraneous prose around the JSON. |
| `WakeProof/WakeProof/Services/ClaudeAPIClient.swift` | Create | `protocol ClaudeVisionClient` (`verify(baselineJPEG:stillJPEG:baselineLocation:antiSpoofInstruction:) async throws -> VerificationResult`) + concrete `ClaudeAPIClient` using `URLSession` with `timeoutIntervalForRequest = 15`. Reads `Secrets.claudeAPIKey` and `Secrets.visionModel`. Specific `ClaudeAPIError` enum (`.missingAPIKey`, `.invalidURL`, `.transportFailed(underlying:)`, `.httpError(status:, snippet:)`, `.timeout`, `.emptyResponse`, `.decodingFailed(underlying:)`). Logs every call outcome with duration via `Logger(subsystem: "com.wakeproof.verification", category: "claude")`. |
| `WakeProof/WakeProof/Verification/VisionVerifier.swift` | Create | `@Observable @MainActor final class VisionVerifier`. Owns transient verification state (`isInFlight: Bool`, `lastError: String?`, `currentAntiSpoofInstruction: String?`, `attemptsInThisFire: Int`). Injected `ClaudeVisionClient` (defaulted to `ClaudeAPIClient()`). `verify(attempt: WakeAttempt, baseline: BaselinePhoto)` orchestrates: call client, update `attempt.verdict` + `verdictReasoning` + `retryCount` in the shared `modelContext`, dispatch to the right scheduler transition (`finishVerifyingVerified` / `returnToRingingAfterVerifying(error:)` / `beginAntiSpoofPrompt(instruction:)`). Picks anti-spoof instruction from a fixed three-element list `["Blink twice", "Show your right hand", "Nod your head"]`. Hard safety: second RETRY in the same fire is coerced to REJECTED. |
| `WakeProof/WakeProof/Verification/VerifyingView.swift` | Create | Pure-UI view bound to `VisionVerifier`. Black background, animated pulse (SwiftUI `.symbolEffect(.pulse)` on `sparkle.magnifyingglass` SF Symbol), "Verifying you're awake…" title, subtle caption showing attempt count ("retry 1/1" on second pass). No buttons — the view is non-dismissable by design; the verifier's state transition pops it. |
| `WakeProof/WakeProof/Verification/AntiSpoofActionPromptView.swift` | Create | Pure-UI view bound to an `instruction: String`. Large text "Now: \(instruction)" with a countdown-style explainer ("When you're ready, tap to re-capture."), single "I'm ready" button that calls the passed-in `onReady: () -> Void` to re-enter `.capturing`. No cancel option — per `CLAUDE.md` "the alarm must not be bypassable". |
| `WakeProof/WakeProof/Alarm/AlarmScheduler.swift` | Modify (surgical) | Phase B.1 ONLY. Extends `AlarmPhase` with `.verifying` and `.antiSpoofPrompt(instruction: String)`; adds `beginVerifying()`, `beginAntiSpoofPrompt(instruction:)`, `returnToRingingAfterVerifying(error:)`, `finishVerifyingVerified()`; relaxes `beginCapturing`'s guard from `phase == .ringing` to `phase == .ringing || phase == .antiSpoofPrompt`; relaxes `returnToRingingWith(error:)`'s guard from `phase == .capturing` to `phase == .capturing || phase == .verifying`. No other changes. |
| `WakeProof/WakeProof/Verification/CameraCaptureFlow.swift` | Modify (surgical) | Phase B.3 ONLY. Replaces the existing completion closure's direct `scheduler.markCaptureCompleted()` + `onSuccess(persisted)` handoff path with a call into the `VisionVerifier.verify(attempt:baseline:)` pipeline. Retains video-validation, durable persistence, and error handling untouched. The `onSuccess` callback parameter is retired (unused once the verifier owns the success chain). |
| `WakeProof/WakeProof/App/WakeProofApp.swift` | Modify (surgical) | Phase B.2 + B.4. Instantiates `VisionVerifier` as `@State`, registers via `.environment()`, wires the verifier's scheduler + modelContext dependencies in `bootstrapIfNeeded`, extends `RootView.alarmPhaseContent` to render `VerifyingView` on `.verifying` and `AntiSpoofActionPromptView` on `.antiSpoofPrompt`, and installs volume-reduction side effects on `.verifying` entry/exit (`audioKeepalive.setAlarmVolume(0.2)` in; `1.0` out). |
| `WakeProof/WakeProof/Services/Secrets.swift` | Unchanged content | Already exists with the real API key, already git-ignored. Plan never opens or diffs this file; code just reads `Secrets.claudeAPIKey` + `Secrets.visionModel`. |
| `WakeProof/WakeProofTests/VerificationResultTests.swift` | Create | Unit tests for JSON decoding: clean JSON, fenced `json` block, extraneous prose wrap, malformed JSON, verdict boundaries, confidence floor/ceiling, mapping to `WakeAttempt.Verdict`. |
| `WakeProof/WakeProofTests/ClaudeAPIClientTests.swift` | Create | Unit tests using a `URLProtocol` stub — no real network. Covers HTTP 200 decode path, 401/429/500 error classification, malformed JSON body → `.decodingFailed`, timeout → `.timeout`, empty response → `.emptyResponse`. |
| `WakeProof/WakeProofTests/VisionVerifierTests.swift` | Create | Unit tests with a fake `ClaudeVisionClient`. Covers the three verdict paths (VERIFIED → `finishVerifyingVerified`, REJECTED → `returnToRingingAfterVerifying`, RETRY → `beginAntiSpoofPrompt`); double-RETRY coerces to REJECTED; network error is classified as REJECTED with a user-friendly banner (not RETRY — we don't want silent retries that burn the user's ring ceiling). Also asserts `WakeAttempt.verdict` is updated in place, not inserted as a new row. |
| `WakeProof/WakeProofTests/AlarmSchedulerTests.swift` | Modify | Append tests for the new phase transitions: `.capturing → .verifying` via `beginVerifying`; `.verifying → .ringing` via `returnToRingingAfterVerifying`; `.verifying → .antiSpoofPrompt` via `beginAntiSpoofPrompt`; `.antiSpoofPrompt → .capturing` via `beginCapturing`; `.verifying → .idle` via `finishVerifyingVerified`. Assert invalid transitions are no-ops (`.ringing → .verifying` must be ignored). Existing tests untouched. |
| `docs/vision-prompt.md` | Create | v1 of the Opus 4.7 verification prompt. System prompt + user-message template + expected JSON schema + the self-verification chain instructions + change log. This is the committed source of truth for the prompt; any prompt change bumps the `v` and appends to the change log. |
| `docs/test-scenarios.md` | Create | Five fixture scenarios per `docs/build-plan.md` Day 3: (1) morning-lit kitchen VERIFIED, (2) night-lit kitchen VERIFIED-or-RETRY, (3) bathroom groggy RETRY, (4) printed-photo-of-baseline REJECTED (demo money shot), (5) user-in-bed REJECTED. Each with setup, baseline conditions, live-capture conditions, expected verdict, pass criteria, and a log-line sentinel the console must emit. |
| `docs/device-test-protocol.md` | Modify (append) | Add Tests 9–13 (the five verification scenarios) at the end of the existing Test 1–8 protocol. Pre-existing Tests 1–8 are untouched. |
| `WakeProof/WakeProof/Resources/alarm.m4a` | Unchanged | No touch. |
| `WakeProof/WakeProof/Resources/alarm.caf` | Unchanged | No touch. |
| `WakeProof/Info.plist` | Unchanged | HTTPS to `api.anthropic.com` works without an ATS exemption (standard-compliant TLS); no Info.plist edit needed. Camera + microphone keys already exist from Day 2. |

---

## Phase A — Additive infrastructure (zero runtime integration)

**Goal of phase:** Land every new file needed for Layer 1 vision verification and every new doc artifact required by `CLAUDE.md` reference-docs list. All code compiles against the simulator. No edits to existing runtime files. Zero behavioural change on device — a build shipped at the end of Phase A would run exactly like Day 2.

### Task A.1: Secrets template audit

**Files:** n/a (verification task; no file creation or edits)

**Dependencies:** none (first task)

**Important context:** `WakeProof/WakeProof/Services/Secrets.swift.example` already exists, is git-tracked, and uses placeholder `"sk-ant-REPLACE_ME"` (with an **underscore**). The live `Secrets.swift` also exists locally with the real API key and is git-ignored at `.gitignore` line 2. This task audits those invariants — it does **not** create or edit either file. The underscore placeholder is the canonical sentinel; Task A.3's `ClaudeAPIClient` matches it exactly so a developer who forgets to replace the placeholder hits the `missingAPIKey` guard rather than an auth failure on a live call.

- [ ] **Step 1: Confirm the committed template file exists unchanged and has all three expected identifiers.**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon ls-files WakeProof/WakeProof/Services/Secrets.swift.example
grep -n "sk-ant-REPLACE_ME" /Users/mountainfung/Desktop/WakeProof-Hackathon/WakeProof/WakeProof/Services/Secrets.swift.example
grep -n "claude-opus-4-7" /Users/mountainfung/Desktop/WakeProof-Hackathon/WakeProof/WakeProof/Services/Secrets.swift.example
grep -n "claude-sonnet-4-6" /Users/mountainfung/Desktop/WakeProof-Hackathon/WakeProof/WakeProof/Services/Secrets.swift.example
```

Expected: first command echoes the path; each `grep` shows exactly one line. If the `sk-ant-REPLACE_ME` placeholder shape differs (e.g. hyphen), STOP — Task A.3's guard depends on the exact string. If either model identifier is missing, A.3's code will fail to compile (`Secrets.visionModel` / `Secrets.textModel` are referenced). Either realign the template or update A.3 to match; do not leave them divergent.

- [ ] **Step 2: Verify `.gitignore` already excludes `Secrets.swift`.**

```bash
grep -n "Secrets.swift" /Users/mountainfung/Desktop/WakeProof-Hackathon/.gitignore
```

Expected: a line mentioning `Secrets.swift` (should be line 2 — presence is load-bearing, not the line number).

- [ ] **Step 3: Verify the live `Secrets.swift` is NOT staged or tracked.**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon ls-files --error-unmatch WakeProof/WakeProof/Services/Secrets.swift 2>&1 | head -3
```

Expected: `error: pathspec ... did not match any file(s) known to git`. If it matches (i.e., the real `Secrets.swift` is tracked), STOP — remove it from git history first, rotate the key, and only then continue.

- [ ] **Step 4: Confirm local `Secrets.swift` exists and has a real (non-placeholder) key.**

```bash
test -f /Users/mountainfung/Desktop/WakeProof-Hackathon/WakeProof/WakeProof/Services/Secrets.swift && echo "exists" || echo "MISSING — copy from Secrets.swift.example and paste a real key"
grep -q "sk-ant-REPLACE_ME" /Users/mountainfung/Desktop/WakeProof-Hackathon/WakeProof/WakeProof/Services/Secrets.swift && echo "STILL A PLACEHOLDER — update Secrets.swift with a real key" || echo "non-placeholder key present"
```

Expected: `exists` + `non-placeholder key present`. If either check fails, pause and have the user update `Secrets.swift` before proceeding.

- [ ] **Step 5: No commit for this task.** The audit touches no file; `git status` should still show a clean working tree. Move directly to Task A.2.

### Task A.2: VerificationResult model + tests

**Files:**
- Create: `WakeProof/WakeProof/Verification/VerificationResult.swift`
- Create: `WakeProof/WakeProofTests/VerificationResultTests.swift`

**Dependencies:** Task A.1

- [ ] **Step 1: Create the model.**

```swift
//
//  VerificationResult.swift
//  WakeProof
//
//  The JSON verdict Opus 4.7 returns for every wake-time verification call.
//  The model is asked to return a single JSON object (optionally wrapped in a
//  fenced `json` block); `fromClaudeMessageBody` tolerates both shapes plus a
//  small amount of prose around the JSON, because tightening the prompt further
//  costs more latency than a permissive parser costs in safety.
//

import Foundation

struct VerificationResult: Codable, Equatable {

    enum Verdict: String, Codable {
        case verified = "VERIFIED"
        case rejected = "REJECTED"
        case retry    = "RETRY"

        /// Map the vision-layer verdict onto the persistence-layer verdict column.
        /// RETRY is a *transient* verifier state — the persistence row ends up as
        /// `.verified` or `.rejected` depending on what the anti-spoof re-capture
        /// decides. If a row is written with `.retry` as the final value it means
        /// the user abandoned the alarm mid-flow; the default `.unresolved` path
        /// in AlarmScheduler.recoverUnresolvedFireIfNeeded already covers that.
        var mapped: WakeAttempt.Verdict {
            switch self {
            case .verified: return .verified
            case .rejected: return .rejected
            case .retry:    return .retry
            }
        }
    }

    let sameLocation: Bool
    let personUpright: Bool
    let eyesOpen: Bool
    let appearsAlert: Bool
    let lightingSuggestsRoomLit: Bool
    let confidence: Double
    let reasoning: String
    let spoofingRuledOut: [String]
    let verdict: Verdict

    /// Convenience forwarder so callers can write `result.mapped` without drilling
    /// through `verdict.mapped`. The mapping itself lives on the enum above.
    var mapped: WakeAttempt.Verdict { verdict.mapped }

    enum CodingKeys: String, CodingKey {
        case sameLocation = "same_location"
        case personUpright = "person_upright"
        case eyesOpen = "eyes_open"
        case appearsAlert = "appears_alert"
        case lightingSuggestsRoomLit = "lighting_suggests_room_lit"
        case confidence
        case reasoning
        case spoofingRuledOut = "spoofing_ruled_out"
        case verdict
    }

    /// Extract the first JSON object from the Messages-API `content[0].text`
    /// payload. Tolerates three shapes:
    ///   1. A pure JSON object: `{ ... }`
    ///   2. A fenced block: ```json\n{ ... }\n```
    ///   3. Prose + a JSON object embedded in it.
    /// Returns `nil` if no `{ ... }` balanced substring parses as `VerificationResult`.
    static func fromClaudeMessageBody(_ body: String) -> VerificationResult? {
        let candidate = extractJSONObject(from: body) ?? body
        guard let data = candidate.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(VerificationResult.self, from: data)
    }

    /// Find the first balanced `{ ... }` substring. Handles nested braces but not
    /// braces inside string literals with escape sequences — sufficient for
    /// Claude's emit shape and enough smaller than a full JSON parser to keep
    /// our error surface narrow.
    private static func extractJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var i = start
        while i < text.endIndex {
            let c = text[i]
            if escaped {
                escaped = false
            } else if c == "\\" && inString {
                escaped = true
            } else if c == "\"" {
                inString.toggle()
            } else if !inString {
                if c == "{" { depth += 1 }
                if c == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...i])
                    }
                }
            }
            i = text.index(after: i)
        }
        return nil
    }
}
```

- [ ] **Step 2: Create the tests.**

```swift
//
//  VerificationResultTests.swift
//  WakeProofTests
//

import XCTest
@testable import WakeProof

final class VerificationResultTests: XCTestCase {

    private let cleanJSON = """
    {
      "same_location": true,
      "person_upright": true,
      "eyes_open": true,
      "appears_alert": true,
      "lighting_suggests_room_lit": true,
      "confidence": 0.92,
      "reasoning": "Same kitchen counter; eyes open; alert posture.",
      "spoofing_ruled_out": ["photo-of-photo", "mannequin", "deepfake"],
      "verdict": "VERIFIED"
    }
    """

    func testCleanJSONDecodes() throws {
        let result = try XCTUnwrap(VerificationResult.fromClaudeMessageBody(cleanJSON))
        XCTAssertEqual(result.verdict, .verified)
        XCTAssertEqual(result.mapped, .verified)
        XCTAssertEqual(result.confidence, 0.92, accuracy: 0.001)
        XCTAssertEqual(result.spoofingRuledOut.count, 3)
    }

    func testFencedJSONBlockDecodes() throws {
        let fenced = "Here is the verdict:\n```json\n\(cleanJSON)\n```"
        let result = try XCTUnwrap(VerificationResult.fromClaudeMessageBody(fenced))
        XCTAssertEqual(result.verdict, .verified)
    }

    func testProseSurroundingJSONStillDecodes() throws {
        let messy = "I reasoned about the three spoofing paths and conclude:\n\n\(cleanJSON)\n\nThat's my verdict."
        let result = try XCTUnwrap(VerificationResult.fromClaudeMessageBody(messy))
        XCTAssertEqual(result.verdict, .verified)
    }

    func testMalformedJSONReturnsNil() {
        XCTAssertNil(VerificationResult.fromClaudeMessageBody("no json here"))
        XCTAssertNil(VerificationResult.fromClaudeMessageBody("{\"verdict\": \"VERIFIED\""), "unclosed brace")
    }

    func testRetryVerdictMapsToRetry() throws {
        let retryJSON = cleanJSON.replacingOccurrences(of: "\"VERIFIED\"", with: "\"RETRY\"")
        let result = try XCTUnwrap(VerificationResult.fromClaudeMessageBody(retryJSON))
        XCTAssertEqual(result.verdict, .retry)
        XCTAssertEqual(result.mapped, .retry)
    }

    func testRejectedVerdictMapsToRejected() throws {
        let rejectedJSON = cleanJSON.replacingOccurrences(of: "\"VERIFIED\"", with: "\"REJECTED\"")
        let result = try XCTUnwrap(VerificationResult.fromClaudeMessageBody(rejectedJSON))
        XCTAssertEqual(result.mapped, .rejected)
    }

    func testUnknownVerdictReturnsNil() {
        let junk = cleanJSON.replacingOccurrences(of: "\"VERIFIED\"", with: "\"WHATEVER\"")
        XCTAssertNil(VerificationResult.fromClaudeMessageBody(junk), "unknown verdict must fail decode — do not silently downgrade")
    }

    func testBracesInsideStringsDontFoolParser() throws {
        let tricky = """
        {
          "same_location": true,
          "person_upright": true,
          "eyes_open": true,
          "appears_alert": true,
          "lighting_suggests_room_lit": true,
          "confidence": 0.9,
          "reasoning": "User said: \\"it's 6am{braces}\\" — counter visible.",
          "spoofing_ruled_out": ["photo-of-photo"],
          "verdict": "VERIFIED"
        }
        """
        let result = try XCTUnwrap(VerificationResult.fromClaudeMessageBody(tricky))
        XCTAssertEqual(result.verdict, .verified)
    }
}
```

- [ ] **Step 3: Simulator build + run the new tests.**

```bash
xcodebuild -project /Users/mountainfung/Desktop/WakeProof-Hackathon/WakeProof/WakeProof.xcodeproj -scheme WakeProof -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 15' test -only-testing:WakeProofTests/VerificationResultTests 2>&1 | tail -60
```

Expected: `** TEST SUCCEEDED **` with `Executed 8 tests, with 0 failures`.

- [ ] **Step 4: Commit.**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon add WakeProof/WakeProof/Verification/VerificationResult.swift WakeProof/WakeProofTests/VerificationResultTests.swift
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon commit -m "Vision Phase A.2: VerificationResult with tolerant JSON parser and decoding tests"
```

### Task A.3: ClaudeAPIClient + tests

**Files:**
- Create: `WakeProof/WakeProof/Services/ClaudeAPIClient.swift`
- Create: `WakeProof/WakeProofTests/ClaudeAPIClientTests.swift`

**Dependencies:** Task A.2

- [ ] **Step 1: Create the client and protocol.**

```swift
//
//  ClaudeAPIClient.swift
//  WakeProof
//
//  Thin async/await wrapper around the Anthropic Messages API. Only the vision
//  verification call lives here; Day 4's Memory Tool + Managed Agents layers
//  get their own clients. 15-second request timeout matches Decision 2: beyond
//  that the alarm volume is already back to full and retrying would waste ring
//  ceiling on a dead network.
//

import Foundation
import UIKit
import os

/// The abstraction the verifier depends on. Testable via a fake implementation.
protocol ClaudeVisionClient {
    func verify(
        baselineJPEG: Data,
        stillJPEG: Data,
        baselineLocation: String,
        antiSpoofInstruction: String?
    ) async throws -> VerificationResult
}

enum ClaudeAPIError: LocalizedError {
    case missingAPIKey
    case invalidURL
    case transportFailed(underlying: Error)
    case httpError(status: Int, snippet: String)
    case timeout
    case emptyResponse
    case decodingFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Claude API key not configured. Copy Secrets.swift.example to Secrets.swift and add your key."
        case .invalidURL:
            return "Couldn't build the Claude API request URL."
        case .transportFailed:
            return "Network error reaching Claude. Check your connection."
        case .httpError(let status, _):
            return "Claude returned HTTP \(status). The call was rejected; try again in a moment."
        case .timeout:
            return "Claude took too long (>15s). Try again."
        case .emptyResponse:
            return "Claude returned an empty response. Try again."
        case .decodingFailed:
            return "Claude returned a response we couldn't parse. Try again."
        }
    }
}

struct ClaudeAPIClient: ClaudeVisionClient {

    /// Injectable for tests — production uses `.shared`.
    let session: URLSession
    let apiKey: String
    let model: String
    let endpoint: URL
    let promptTemplate: VisionPromptTemplate

    private let logger = Logger(subsystem: "com.wakeproof.verification", category: "claude")

    init(
        session: URLSession = Self.defaultSession,
        apiKey: String = Secrets.claudeAPIKey,
        model: String = Secrets.visionModel,
        endpoint: URL = Self.defaultEndpoint,
        promptTemplate: VisionPromptTemplate = .v1
    ) {
        self.session = session
        self.apiKey = apiKey
        self.model = model
        self.endpoint = endpoint
        self.promptTemplate = promptTemplate
    }

    /// Literal URL that must always parse. Using `preconditionFailure` instead of `!`
    /// so we satisfy the project-wide "no force unwraps in committed code" rule while
    /// still trapping loudly at launch if a programmer somehow breaks the constant.
    private static let defaultEndpoint: URL = {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            preconditionFailure("Hardcoded Claude endpoint URL failed to parse — programmer error.")
        }
        return url
    }()

    private static var defaultSession: URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }

    func verify(
        baselineJPEG: Data,
        stillJPEG: Data,
        baselineLocation: String,
        antiSpoofInstruction: String?
    ) async throws -> VerificationResult {
        // Sentinel matches the exact placeholder shipped in Secrets.swift.example.
        // An underscore, not a hyphen — if these two strings drift, the guard fails open.
        guard apiKey != "sk-ant-REPLACE_ME", !apiKey.isEmpty else {
            throw ClaudeAPIError.missingAPIKey
        }

        let requestBody = buildRequestBody(
            baselineJPEG: baselineJPEG,
            stillJPEG: stillJPEG,
            baselineLocation: baselineLocation,
            antiSpoofInstruction: antiSpoofInstruction
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let start = Date()
        logger.info("Calling Claude \(model, privacy: .public) with \(baselineJPEG.count, privacy: .public)+\(stillJPEG.count, privacy: .public) bytes of image data; antiSpoof=\(antiSpoofInstruction ?? "nil", privacy: .public)")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            logger.error("Claude call timed out after \(Date().timeIntervalSince(start), privacy: .public)s")
            throw ClaudeAPIError.timeout
        } catch {
            logger.error("Claude transport error: \(error.localizedDescription, privacy: .public)")
            throw ClaudeAPIError.transportFailed(underlying: error)
        }
        let elapsed = Date().timeIntervalSince(start)

        guard let http = response as? HTTPURLResponse else {
            throw ClaudeAPIError.emptyResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            let snippet = String(data: data.prefix(300), encoding: .utf8) ?? "<non-utf8>"
            logger.error("Claude HTTP \(http.statusCode, privacy: .public) in \(elapsed, privacy: .public)s; body snippet: \(snippet, privacy: .public)")
            throw ClaudeAPIError.httpError(status: http.statusCode, snippet: snippet)
        }

        let text: String
        do {
            text = try extractTextBlock(from: data)
        } catch {
            logger.error("Claude response body didn't match expected shape: \(error.localizedDescription, privacy: .public)")
            throw ClaudeAPIError.decodingFailed(underlying: error)
        }

        guard let result = VerificationResult.fromClaudeMessageBody(text) else {
            logger.error("VerificationResult parser returned nil on body: \(text.prefix(300), privacy: .public)")
            throw ClaudeAPIError.decodingFailed(underlying: ClaudeAPIError.emptyResponse)
        }

        logger.info("Claude verdict \(result.verdict.rawValue, privacy: .public) confidence=\(result.confidence, privacy: .public) in \(elapsed, privacy: .public)s")
        return result
    }

    private func buildRequestBody(
        baselineJPEG: Data,
        stillJPEG: Data,
        baselineLocation: String,
        antiSpoofInstruction: String?
    ) -> [String: Any] {
        let systemPrompt = promptTemplate.systemPrompt()
        let userPrompt = promptTemplate.userPrompt(
            baselineLocation: baselineLocation,
            antiSpoofInstruction: antiSpoofInstruction
        )

        let content: [[String: Any]] = [
            [
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": baselineJPEG.base64EncodedString()
                ]
            ],
            [
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": stillJPEG.base64EncodedString()
                ]
            ],
            [
                "type": "text",
                "text": userPrompt
            ]
        ]

        return [
            "model": model,
            "max_tokens": 600,
            "system": systemPrompt,
            "messages": [
                [
                    "role": "user",
                    "content": content
                ]
            ]
        ]
    }

    /// Extract `response["content"][0]["text"]` — the only shape we act on today.
    private func extractTextBlock(from data: Data) throws -> String {
        struct Body: Decodable {
            struct Block: Decodable { let type: String; let text: String? }
            let content: [Block]?
        }
        let body = try JSONDecoder().decode(Body.self, from: data)
        guard let block = body.content?.first(where: { $0.type == "text" }),
              let text = block.text else {
            throw ClaudeAPIError.emptyResponse
        }
        return text
    }
}

/// Versioned prompt template. `v1` is the Day 3 baseline; any prompt change
/// bumps the version and must update `docs/vision-prompt.md` in the same commit.
enum VisionPromptTemplate {
    case v1

    func systemPrompt() -> String {
        switch self {
        case .v1:
            return """
            You are the verification layer of a wake-up accountability app. A user has set a self-commitment \
            contract: they cannot dismiss their alarm without proving they are awake and out of bed at a \
            designated location. Your job is to compare two images — a BASELINE reference photo captured \
            during onboarding at the user's awake-location, and a LIVE photo captured the moment the alarm \
            rings — and return a single JSON object with your verdict. Be strict but not cruel: users who are \
            genuinely awake but groggy should not be rejected; users attempting to spoof (showing a photo to \
            the camera, staying in bed, pretending to be somewhere they're not) must be rejected or flagged.

            Before returning your verdict, explicitly reason through three plausible spoofing methods and \
            confirm each is ruled out:
              1. photo-of-photo (user holds their baseline photo up to the camera instead of being at the location)
              2. mannequin or still image (no micro-movements, uncanny symmetry, no depth cues)
              3. deepfake or pre-recorded video (unnatural transitions, lighting mismatch, eye tracking)

            Your entire response MUST be a single JSON object matching the schema the user provides. No prose \
            outside the JSON. No apologies. No hedging. If you cannot decide, return verdict "RETRY" with your \
            reasoning — do not refuse to respond.
            """
        }
    }

    func userPrompt(baselineLocation: String, antiSpoofInstruction: String?) -> String {
        switch self {
        case .v1:
            let antiSpoofBlock = antiSpoofInstruction.map { instruction in
                """

                ANTI-SPOOF CHECK (user was asked to): \(instruction)
                The LIVE photo above is a retry. Verify the user visibly performed this action — if not, \
                this is evidence of spoofing and should push the verdict toward REJECTED. Record the check \
                in the reasoning field.
                """
            } ?? ""

            return """
            BASELINE PHOTO: captured at the user's designated awake-location ("\(baselineLocation)").
            LIVE PHOTO: just captured at alarm time. The user is required to be in the same location, \
            upright, eyes open, alert.\(antiSpoofBlock)

            Return a single JSON object with exactly these fields:

            {
              "same_location": true | false,
              "person_upright": true | false,
              "eyes_open": true | false,
              "appears_alert": true | false,
              "lighting_suggests_room_lit": true | false,
              "confidence": <float 0.0 to 1.0>,
              "reasoning": "<one paragraph, under 400 chars, plain prose>",
              "spoofing_ruled_out": ["photo-of-photo", "mannequin", "deepfake"],
              "verdict": "VERIFIED" | "REJECTED" | "RETRY"
            }

            Verdict rules:
              - VERIFIED: all five booleans are true AND confidence > 0.75 AND all three spoofing methods are ruled out.
              - RETRY: user appears to be at the right location but is not clearly upright, or eyes are only barely \
                open, or confidence is between 0.55 and 0.75.
              - REJECTED: location is wrong, person appears to be in bed or lying down, a spoofing method is \
                plausible, or confidence < 0.55.
            """
        }
    }
}
```

- [ ] **Step 2: Create the tests.**

```swift
//
//  ClaudeAPIClientTests.swift
//  WakeProofTests
//

import XCTest
@testable import WakeProof

final class ClaudeAPIClientTests: XCTestCase {

    /// URLProtocol stub: registers class-level handlers for each test, returns whatever the
    /// test wires up. No real network is ever hit — critical because unit tests must not
    /// burn API credits.
    final class StubProtocol: URLProtocol {
        nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?
        nonisolated(unsafe) static var throwing: Error?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            if let error = Self.throwing {
                client?.urlProtocol(self, didFailWithError: error)
                return
            }
            guard let handler = Self.handler else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            let (response, data) = handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func makeClient(handler: @escaping (URLRequest) -> (HTTPURLResponse, Data)) -> ClaudeAPIClient {
        StubProtocol.handler = handler
        StubProtocol.throwing = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: config)
        return ClaudeAPIClient(session: session, apiKey: "sk-ant-test-key", model: "claude-opus-4-7")
    }

    private let happyBodyJSON: [String: Any] = [
        "content": [
            [
                "type": "text",
                "text": """
                {
                  "same_location": true,
                  "person_upright": true,
                  "eyes_open": true,
                  "appears_alert": true,
                  "lighting_suggests_room_lit": true,
                  "confidence": 0.9,
                  "reasoning": "Same kitchen; upright; alert.",
                  "spoofing_ruled_out": ["photo-of-photo", "mannequin", "deepfake"],
                  "verdict": "VERIFIED"
                }
                """
            ]
        ]
    ]

    func testHTTP200DecodesVerifiedResult() async throws {
        let client = makeClient { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = try! JSONSerialization.data(withJSONObject: self.happyBodyJSON)
            return (response, body)
        }
        let result = try await client.verify(
            baselineJPEG: Data([0xFF, 0xD8, 0xFF]),
            stillJPEG: Data([0xFF, 0xD8, 0xFF]),
            baselineLocation: "kitchen",
            antiSpoofInstruction: nil
        )
        XCTAssertEqual(result.verdict, .verified)
    }

    func testHTTP401MapsToHTTPError() async {
        let client = makeClient { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data("bad key".utf8))
        }
        do {
            _ = try await client.verify(baselineJPEG: Data([0xFF]), stillJPEG: Data([0xFF]), baselineLocation: "kitchen", antiSpoofInstruction: nil)
            XCTFail("expected httpError(401)")
        } catch ClaudeAPIError.httpError(let status, _) {
            XCTAssertEqual(status, 401)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testMissingAPIKeyShortCircuits() async {
        // Placeholder must match the sentinel in ClaudeAPIClient.verify exactly —
        // underscore, not hyphen. This duplication is intentional: if either drifts
        // this test fails loudly in CI rather than letting a bogus key hit the wire.
        let client = ClaudeAPIClient(
            session: URLSession(configuration: .ephemeral),
            apiKey: "sk-ant-REPLACE_ME",
            model: "claude-opus-4-7"
        )
        do {
            _ = try await client.verify(baselineJPEG: Data(), stillJPEG: Data(), baselineLocation: "x", antiSpoofInstruction: nil)
            XCTFail("expected missingAPIKey")
        } catch ClaudeAPIError.missingAPIKey {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testTimeoutMapsToTimeoutError() async {
        StubProtocol.handler = nil
        StubProtocol.throwing = URLError(.timedOut)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let client = ClaudeAPIClient(session: URLSession(configuration: config), apiKey: "sk-ant-test", model: "claude-opus-4-7")
        do {
            _ = try await client.verify(baselineJPEG: Data(), stillJPEG: Data(), baselineLocation: "x", antiSpoofInstruction: nil)
            XCTFail("expected .timeout")
        } catch ClaudeAPIError.timeout {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testTransportErrorMapsToTransportFailed() async {
        StubProtocol.handler = nil
        StubProtocol.throwing = URLError(.notConnectedToInternet)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let client = ClaudeAPIClient(session: URLSession(configuration: config), apiKey: "sk-ant-test", model: "claude-opus-4-7")
        do {
            _ = try await client.verify(baselineJPEG: Data(), stillJPEG: Data(), baselineLocation: "x", antiSpoofInstruction: nil)
            XCTFail("expected .transportFailed")
        } catch ClaudeAPIError.transportFailed {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testMalformedJSONBodyMapsToDecodingFailed() async {
        let client = makeClient { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("not json at all".utf8))
        }
        do {
            _ = try await client.verify(baselineJPEG: Data(), stillJPEG: Data(), baselineLocation: "x", antiSpoofInstruction: nil)
            XCTFail("expected .decodingFailed")
        } catch ClaudeAPIError.decodingFailed {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testVerdictUnparseableInsideTextBlockMapsToDecodingFailed() async {
        let client = makeClient { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = try! JSONSerialization.data(withJSONObject: [
                "content": [[ "type": "text", "text": "sorry I cannot comply" ]]
            ])
            return (response, body)
        }
        do {
            _ = try await client.verify(baselineJPEG: Data(), stillJPEG: Data(), baselineLocation: "x", antiSpoofInstruction: nil)
            XCTFail("expected .decodingFailed")
        } catch ClaudeAPIError.decodingFailed {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}
```

- [ ] **Step 3: Simulator build + run the client tests.**

```bash
xcodebuild -project /Users/mountainfung/Desktop/WakeProof-Hackathon/WakeProof/WakeProof.xcodeproj -scheme WakeProof -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 15' test -only-testing:WakeProofTests/ClaudeAPIClientTests 2>&1 | tail -60
```

Expected: `** TEST SUCCEEDED **`, 7 tests pass, zero real network traffic (StubProtocol intercepts everything).

- [ ] **Step 4: Commit.**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon add WakeProof/WakeProof/Services/ClaudeAPIClient.swift WakeProof/WakeProofTests/ClaudeAPIClientTests.swift
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon commit -m "Vision Phase A.3: ClaudeAPIClient with versioned v1 prompt template and URLProtocol-stubbed tests"
```

### Task A.4: VisionVerifier + tests

**Files:**
- Create: `WakeProof/WakeProof/Verification/VisionVerifier.swift`
- Create: `WakeProof/WakeProofTests/VisionVerifierTests.swift`

**Dependencies:** Task A.3 **and Task B.1** (see ordering note below).

**Ordering note (2026-04-23 revision):** The original plan claimed A.4 could land before B.1 with "test-only compile-pending". That was wrong — `VisionVerifier.swift` itself calls `scheduler.beginVerifying()` / `beginAntiSpoofPrompt(...)` / `returnToRingingAfterVerifying(...)` / `finishVerifyingVerified()`, all of which are B.1 additions. Committing A.4 before B.1 would leave the entire project uncompilable, which violates `CLAUDE.md`'s "never commit non-compiling code" rule. Execution order is therefore: A.1 → A.2 → A.3 → A.6 → A.7 → A.8 → B.1 → **A.4** → A.5 → A.9 → B.2 → B.3 → B.4 → B.5 → B.6 → C.1 → C.2 → C.3. The file-creation code below is unchanged; only the sequencing moved.

- [ ] **Step 1: Create the verifier.**

```swift
//
//  VisionVerifier.swift
//  WakeProof
//
//  Orchestrates the vision-verification step. Called once per capture; drives
//  the alarm state machine to one of three terminal states: VERIFIED (alarm
//  stops), REJECTED (alarm keeps ringing with an error banner), RETRY (user
//  is shown an anti-spoof action prompt and re-captures once). A second RETRY
//  inside the same fire is coerced to REJECTED so we don't spin indefinitely
//  against either Claude or the user's ring ceiling.
//
//  This class does NOT own the ModelContext; callers pass it in via the
//  `verify(...)` call so a single verifier instance can be used across multiple
//  scenes/contexts without re-binding.
//

import Foundation
import Observation
import SwiftData
import UIKit
import os

@Observable
@MainActor
final class VisionVerifier {

    // MARK: - Observable state

    private(set) var isInFlight: Bool = false
    private(set) var lastError: String?
    private(set) var currentAttemptIndex: Int = 0        // 0 before first call, 1 after first, 2 after retry
    private(set) var currentAntiSpoofInstruction: String?

    // MARK: - Dependencies

    private let client: ClaudeVisionClient
    /// Late-bound scheduler hook — wired in WakeProofApp.bootstrapIfNeeded so the verifier
    /// stays free of `AlarmScheduler` import at type-level for tests.
    var scheduler: AlarmScheduler?

    private let logger = Logger(subsystem: "com.wakeproof.verification", category: "verifier")

    private static let antiSpoofBank = [
        "Blink twice",
        "Show your right hand",
        "Nod your head"
    ]

    init(client: ClaudeVisionClient = ClaudeAPIClient()) {
        self.client = client
    }

    /// Reset per-fire state. Called by `AlarmScheduler.stopRinging` indirectly via the
    /// observable chain — here it's an explicit method so callers (and tests) can make the
    /// reset obvious in trace.
    func resetForNewFire() {
        isInFlight = false
        lastError = nil
        currentAttemptIndex = 0
        currentAntiSpoofInstruction = nil
    }

    /// Entry point. The caller has already persisted `attempt` with `verdict = .captured`;
    /// we update it in place (no new row) based on Claude's verdict.
    func verify(
        attempt: WakeAttempt,
        baseline: BaselinePhoto,
        context: ModelContext
    ) async {
        guard let scheduler else {
            logger.fault("verify() called but scheduler not wired — alarm will hang in .verifying")
            return
        }
        guard !isInFlight else {
            logger.warning("verify() ignored — already in flight")
            return
        }
        isInFlight = true
        lastError = nil
        // Note: `currentAttemptIndex` is bumped only after Claude actually returns a verdict
        // (see `handleResult`). Network errors and internal guard failures must NOT consume
        // the one-retry budget — otherwise a dropped connection on the first try would coerce
        // the legitimate second try into REJECTED on a RETRY verdict.
        scheduler.beginVerifying()

        guard let stillJPEG = attempt.imageData else {
            logger.error("Attempt has no imageData — cannot verify")
            await finish(attempt: attempt, context: context, verdict: .rejected, reasoning: "Internal error: no image captured.")
            return
        }
        let baselineJPEG = baseline.imageData

        let instructionForThisCall = currentAntiSpoofInstruction
        do {
            let result = try await client.verify(
                baselineJPEG: baselineJPEG,
                stillJPEG: stillJPEG,
                baselineLocation: baseline.locationLabel,
                antiSpoofInstruction: instructionForThisCall
            )
            await handleResult(result, attempt: attempt, context: context)
        } catch let apiError as ClaudeAPIError {
            await handleAPIError(apiError, attempt: attempt, context: context)
        } catch {
            logger.error("Unexpected verifier error: \(error.localizedDescription, privacy: .public)")
            await finish(attempt: attempt, context: context, verdict: .rejected, reasoning: "Verification failed. Try again.")
        }
    }

    // MARK: - Private

    private func handleResult(_ result: VerificationResult, attempt: WakeAttempt, context: ModelContext) async {
        // Only count attempts that actually resulted in a Claude verdict. Network errors
        // handled in `handleAPIError` deliberately skip this increment.
        currentAttemptIndex += 1
        switch result.verdict {
        case .verified:
            await finish(attempt: attempt, context: context, verdict: .verified, reasoning: result.reasoning)
        case .rejected:
            await finish(attempt: attempt, context: context, verdict: .rejected, reasoning: result.reasoning)
        case .retry:
            if currentAttemptIndex >= 2 {
                // We already did one anti-spoof retry; another RETRY burns ceiling and can't
                // improve. Coerce to REJECTED so the user re-captures via the ringing path
                // with full context of why.
                logger.warning("Second RETRY verdict coerced to REJECTED — one anti-spoof attempt per fire")
                await finish(attempt: attempt, context: context, verdict: .rejected,
                             reasoning: "Verification still uncertain after retry: \(result.reasoning)")
                return
            }
            let instruction = Self.antiSpoofBank.randomElement() ?? "Blink twice"
            currentAntiSpoofInstruction = instruction
            updatePersistedAttempt(attempt, context: context, verdict: .retry, reasoning: result.reasoning)
            isInFlight = false
            scheduler?.beginAntiSpoofPrompt(instruction: instruction)
        }
    }

    private func handleAPIError(_ error: ClaudeAPIError, attempt: WakeAttempt, context: ModelContext) async {
        // Network errors become REJECTED rather than RETRY. Rationale: RETRY spends the one
        // anti-spoof chance on a condition the user can't fix, and the retry re-uploads the
        // same images so a transient network blip just delays the same outcome. REJECTED
        // keeps the alarm ringing and lets the user retry by tapping "Prove you're awake"
        // again — which gives us a *new* capture (fresher, possibly on a different route).
        let userMessage: String
        switch error {
        case .missingAPIKey:
            userMessage = "Claude API key missing. Check Secrets.swift in the project."
        case .timeout, .transportFailed:
            userMessage = "Couldn't reach Claude — tap \"Prove you're awake\" to retry."
        case .httpError(let status, _):
            userMessage = "Claude returned HTTP \(status) — tap \"Prove you're awake\" to retry."
        case .decodingFailed, .emptyResponse, .invalidURL:
            userMessage = "Couldn't read Claude's response — tap \"Prove you're awake\" to retry."
        }
        await finish(attempt: attempt, context: context, verdict: .rejected, reasoning: userMessage)
    }

    private func finish(attempt: WakeAttempt, context: ModelContext, verdict: WakeAttempt.Verdict, reasoning: String) async {
        updatePersistedAttempt(attempt, context: context, verdict: verdict, reasoning: reasoning)
        isInFlight = false
        switch verdict {
        case .verified:
            scheduler?.finishVerifyingVerified()
            resetForNewFire()
        case .rejected:
            scheduler?.returnToRingingAfterVerifying(error: "Verification failed: \(reasoning)")
        case .retry, .captured, .timeout, .unresolved:
            // retry is handled upstream; the others are never emitted here.
            logger.fault("finish() invoked with unexpected verdict \(verdict.rawValue, privacy: .public)")
        }
    }

    private func updatePersistedAttempt(_ attempt: WakeAttempt, context: ModelContext, verdict: WakeAttempt.Verdict, reasoning: String) {
        attempt.verdict = verdict.rawValue
        attempt.verdictReasoning = reasoning
        // retryCount counts anti-spoof retries, not verification attempts overall.
        if verdict == .retry { attempt.retryCount += 1 }
        do {
            try context.save()
            logger.info("WakeAttempt updated: verdict=\(verdict.rawValue, privacy: .public) retryCount=\(attempt.retryCount, privacy: .public)")
        } catch {
            logger.error("Failed to persist verdict update: \(error.localizedDescription, privacy: .public)")
            context.rollback()
        }
    }
}
```

- [ ] **Step 2: Create the tests.** (Uses an in-memory `ModelContainer` and a fake client.)

```swift
//
//  VisionVerifierTests.swift
//  WakeProofTests
//

import XCTest
import SwiftData
import UIKit
@testable import WakeProof

@MainActor
final class VisionVerifierTests: XCTestCase {

    /// In-memory `ModelContainer` so tests don't touch the on-device SwiftData store.
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }
    private var scheduler: AlarmScheduler!
    private var baseline: BaselinePhoto!

    override func setUp() async throws {
        try await super.setUp()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: BaselinePhoto.self, WakeAttempt.self, configurations: config)
        UserDefaults.standard.removeObject(forKey: "com.wakeproof.alarm.lastFireAt")
        scheduler = AlarmScheduler()
        baseline = BaselinePhoto(imageData: Data([0xFF, 0xD8, 0xFF]), locationLabel: "kitchen")
        context.insert(baseline)
    }

    override func tearDown() async throws {
        scheduler.cancel()
        UserDefaults.standard.removeObject(forKey: "com.wakeproof.alarm.lastFireAt")
        scheduler = nil
        container = nil
        baseline = nil
        try await super.tearDown()
    }

    private func makeAttempt() -> WakeAttempt {
        let attempt = WakeAttempt(scheduledAt: Date())
        attempt.imageData = Data([0xFF, 0xD8, 0xFF])
        attempt.verdict = WakeAttempt.Verdict.captured.rawValue
        context.insert(attempt)
        try? context.save()
        return attempt
    }

    private func enterVerifyingState() {
        scheduler.fireNow()
        scheduler.beginCapturing()
    }

    // MARK: - Verdict routing

    func testVerifiedVerdictTransitionsSchedulerToIdleAndUpdatesRow() async throws {
        let result = VerificationResult(sameLocation: true, personUpright: true, eyesOpen: true,
                                        appearsAlert: true, lightingSuggestsRoomLit: true,
                                        confidence: 0.9, reasoning: "All good.",
                                        spoofingRuledOut: ["photo-of-photo", "mannequin", "deepfake"],
                                        verdict: .verified)
        let client = FakeClient(result: .success(result))
        let verifier = VisionVerifier(client: client)
        verifier.scheduler = scheduler
        enterVerifyingState()
        let attempt = makeAttempt()

        await verifier.verify(attempt: attempt, baseline: baseline, context: context)

        XCTAssertEqual(scheduler.phase, .idle)
        XCTAssertEqual(attempt.verdictEnum, .verified)
        XCTAssertEqual(attempt.verdictReasoning, "All good.")
    }

    func testRejectedVerdictReturnsToRingingWithError() async {
        let result = VerificationResult(sameLocation: false, personUpright: true, eyesOpen: true,
                                        appearsAlert: true, lightingSuggestsRoomLit: true,
                                        confidence: 0.3, reasoning: "Different location.",
                                        spoofingRuledOut: ["photo-of-photo", "mannequin", "deepfake"],
                                        verdict: .rejected)
        let client = FakeClient(result: .success(result))
        let verifier = VisionVerifier(client: client)
        verifier.scheduler = scheduler
        enterVerifyingState()
        let attempt = makeAttempt()

        await verifier.verify(attempt: attempt, baseline: baseline, context: context)

        XCTAssertEqual(scheduler.phase, .ringing)
        XCTAssertTrue(scheduler.lastCaptureError?.contains("Different location") == true)
        XCTAssertEqual(attempt.verdictEnum, .rejected)
    }

    func testRetryVerdictTransitionsToAntiSpoofPrompt() async {
        let result = VerificationResult(sameLocation: true, personUpright: false, eyesOpen: true,
                                        appearsAlert: false, lightingSuggestsRoomLit: true,
                                        confidence: 0.62, reasoning: "Unclear posture.",
                                        spoofingRuledOut: ["photo-of-photo", "mannequin", "deepfake"],
                                        verdict: .retry)
        let client = FakeClient(result: .success(result))
        let verifier = VisionVerifier(client: client)
        verifier.scheduler = scheduler
        enterVerifyingState()
        let attempt = makeAttempt()

        await verifier.verify(attempt: attempt, baseline: baseline, context: context)

        guard case let .antiSpoofPrompt(instruction) = scheduler.phase else {
            return XCTFail("expected phase=.antiSpoofPrompt, got \(scheduler.phase)")
        }
        XCTAssertFalse(instruction.isEmpty)
        XCTAssertEqual(verifier.currentAntiSpoofInstruction, instruction)
        XCTAssertEqual(attempt.retryCount, 1)
    }

    func testSecondRetryCoercesToRejected() async {
        let result = VerificationResult(sameLocation: true, personUpright: false, eyesOpen: true,
                                        appearsAlert: false, lightingSuggestsRoomLit: true,
                                        confidence: 0.6, reasoning: "Still unclear.",
                                        spoofingRuledOut: ["photo-of-photo", "mannequin", "deepfake"],
                                        verdict: .retry)
        let client = FakeClient(result: .success(result))
        let verifier = VisionVerifier(client: client)
        verifier.scheduler = scheduler
        enterVerifyingState()
        let attempt = makeAttempt()

        // First call: RETRY → anti-spoof prompt
        await verifier.verify(attempt: attempt, baseline: baseline, context: context)
        // User taps "I'm ready", re-enters capturing, fresh attempt
        scheduler.beginCapturing()
        let retryAttempt = makeAttempt()
        // Second call: RETRY again → coerced to REJECTED
        await verifier.verify(attempt: retryAttempt, baseline: baseline, context: context)

        XCTAssertEqual(scheduler.phase, .ringing)
        XCTAssertEqual(retryAttempt.verdictEnum, .rejected)
    }

    func testNetworkErrorIsClassifiedAsRejected() async {
        let client = FakeClient(result: .failure(ClaudeAPIError.timeout))
        let verifier = VisionVerifier(client: client)
        verifier.scheduler = scheduler
        enterVerifyingState()
        let attempt = makeAttempt()

        await verifier.verify(attempt: attempt, baseline: baseline, context: context)

        XCTAssertEqual(scheduler.phase, .ringing)
        XCTAssertEqual(attempt.verdictEnum, .rejected)
        XCTAssertTrue(scheduler.lastCaptureError?.contains("Couldn't reach Claude") == true)
    }

    func testMissingAPIKeyShowsConfigMessage() async {
        let client = FakeClient(result: .failure(ClaudeAPIError.missingAPIKey))
        let verifier = VisionVerifier(client: client)
        verifier.scheduler = scheduler
        enterVerifyingState()
        let attempt = makeAttempt()

        await verifier.verify(attempt: attempt, baseline: baseline, context: context)

        XCTAssertTrue(scheduler.lastCaptureError?.contains("Secrets.swift") == true)
    }

    func testResetForNewFireClearsCounter() async {
        let result = VerificationResult(sameLocation: true, personUpright: true, eyesOpen: true,
                                        appearsAlert: true, lightingSuggestsRoomLit: true,
                                        confidence: 0.9, reasoning: "ok",
                                        spoofingRuledOut: ["photo-of-photo", "mannequin", "deepfake"],
                                        verdict: .retry)
        let client = FakeClient(result: .success(result))
        let verifier = VisionVerifier(client: client)
        verifier.scheduler = scheduler
        enterVerifyingState()
        let attempt = makeAttempt()
        await verifier.verify(attempt: attempt, baseline: baseline, context: context)
        XCTAssertEqual(verifier.currentAttemptIndex, 1)

        verifier.resetForNewFire()
        XCTAssertEqual(verifier.currentAttemptIndex, 0)
        XCTAssertNil(verifier.currentAntiSpoofInstruction)
    }

    // MARK: - Fake client

    private final class FakeClient: ClaudeVisionClient {
        let result: Result<VerificationResult, Error>
        init(result: Result<VerificationResult, Error>) { self.result = result }
        func verify(baselineJPEG: Data, stillJPEG: Data, baselineLocation: String, antiSpoofInstruction: String?) async throws -> VerificationResult {
            switch result {
            case .success(let r): return r
            case .failure(let e): throw e
            }
        }
    }
}
```

- [ ] **Step 3: Simulator build + run verifier tests.** By the time this task runs, B.1 has already landed so production AND test targets should compile. Use `iPhone 17` as the destination (available on this Mac; older simulator names are not installed):

```bash
xcodebuild -project /Users/mountainfung/Desktop/WakeProof-Hackathon/WakeProof/WakeProof.xcodeproj -scheme WakeProof -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:WakeProofTests/VisionVerifierTests 2>&1 | tail -80
```

Expected: `** TEST SUCCEEDED **` with 7 tests passing. If any test fails, inspect the failure before committing — the most likely culprit is a drift between `VisionVerifier`'s `currentAttemptIndex` semantics and the scheduler's phase guards.

- [ ] **Step 4: Commit** (now a clean, compiling commit since B.1 landed first).

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon add WakeProof/WakeProof/Verification/VisionVerifier.swift WakeProof/WakeProofTests/VisionVerifierTests.swift
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon commit -m "Vision Phase A.4: VisionVerifier orchestrator + tests"
```

### Task A.5: VerifyingView

**Files:**
- Create: `WakeProof/WakeProof/Verification/VerifyingView.swift`

**Dependencies:** Task A.4

- [ ] **Step 1: Create the view.**

```swift
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

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 24) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 80))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, options: .repeating)
                Text("Verifying you're awake…")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                if verifier.currentAttemptIndex > 1 {
                    Text("Retry \(verifier.currentAttemptIndex - 1) of 1")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                }
                if let err = verifier.lastError {
                    Text(err)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }
        }
    }
}
```

- [ ] **Step 2: Simulator compile check.** Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit.**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon add WakeProof/WakeProof/Verification/VerifyingView.swift
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon commit -m "Vision Phase A.5: VerifyingView with pulsing magnifying-glass symbol effect"
```

### Task A.6: AntiSpoofActionPromptView

**Files:**
- Create: `WakeProof/WakeProof/Verification/AntiSpoofActionPromptView.swift`

**Dependencies:** Task A.4

- [ ] **Step 1: Create the view.**

```swift
//
//  AntiSpoofActionPromptView.swift
//  WakeProof
//
//  Shown when Claude returns RETRY. The user is asked to perform a specific
//  random action (blink twice / show right hand / nod head) before re-capturing.
//  The next capture is then verified with the action included in the prompt so
//  Claude can confirm the action was performed — this is the load-bearing piece
//  against the photo-of-photo spoof. No cancel option — the alarm is unskippable.
//

import SwiftUI

struct AntiSpoofActionPromptView: View {

    let instruction: String
    let onReady: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 28) {
                Spacer()
                Text("Now:")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))
                Text(instruction)
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Text("When you're ready, tap to re-capture.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Spacer()
                Button("I'm ready", action: onReady)
                    .buttonStyle(.primaryAlarm)
                    .padding(.horizontal)
                    .padding(.bottom, 40)
            }
        }
    }
}
```

- [ ] **Step 2: Simulator compile check.** Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit.**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon add WakeProof/WakeProof/Verification/AntiSpoofActionPromptView.swift
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon commit -m "Vision Phase A.6: AntiSpoofActionPromptView with random instruction display"
```

### Task A.7: Vision prompt artifact (docs/vision-prompt.md)

**Files:**
- Create: `docs/vision-prompt.md`

**Dependencies:** Task A.3 (prompt strings live in `ClaudeAPIClient.VisionPromptTemplate.v1`)

- [ ] **Step 1: Create the doc.**

```markdown
# Opus 4.7 Vision Verification Prompt

> Versioned artifact. Any change to the prompt bumps the `v` and appends a change-log entry.
> The live prompt is sourced from `ClaudeAPIClient.VisionPromptTemplate.v1` in
> `WakeProof/WakeProof/Services/ClaudeAPIClient.swift`; this file is the committed mirror.

## v1 — 2026-04-24

### System prompt

```
You are the verification layer of a wake-up accountability app. A user has set a self-commitment
contract: they cannot dismiss their alarm without proving they are awake and out of bed at a
designated location. Your job is to compare two images — a BASELINE reference photo captured
during onboarding at the user's awake-location, and a LIVE photo captured the moment the alarm
rings — and return a single JSON object with your verdict. Be strict but not cruel: users who are
genuinely awake but groggy should not be rejected; users attempting to spoof (showing a photo to
the camera, staying in bed, pretending to be somewhere they're not) must be rejected or flagged.

Before returning your verdict, explicitly reason through three plausible spoofing methods and
confirm each is ruled out:
  1. photo-of-photo (user holds their baseline photo up to the camera instead of being at the location)
  2. mannequin or still image (no micro-movements, uncanny symmetry, no depth cues)
  3. deepfake or pre-recorded video (unnatural transitions, lighting mismatch, eye tracking)

Your entire response MUST be a single JSON object matching the schema the user provides. No prose
outside the JSON. No apologies. No hedging. If you cannot decide, return verdict "RETRY" with your
reasoning — do not refuse to respond.
```

### User prompt template

(Injected fields: `baselineLocation`, optional `antiSpoofInstruction`.)

```
BASELINE PHOTO: captured at the user's designated awake-location ("{baselineLocation}").
LIVE PHOTO: just captured at alarm time. The user is required to be in the same location,
upright, eyes open, alert.

[ANTI-SPOOF CHECK (user was asked to): {antiSpoofInstruction}]
[The LIVE photo above is a retry. Verify the user visibly performed this action — if not, ...]

Return a single JSON object with exactly these fields:

{
  "same_location": true | false,
  "person_upright": true | false,
  "eyes_open": true | false,
  "appears_alert": true | false,
  "lighting_suggests_room_lit": true | false,
  "confidence": <float 0.0 to 1.0>,
  "reasoning": "<one paragraph, under 400 chars, plain prose>",
  "spoofing_ruled_out": ["photo-of-photo", "mannequin", "deepfake"],
  "verdict": "VERIFIED" | "REJECTED" | "RETRY"
}

Verdict rules:
  - VERIFIED: all five booleans are true AND confidence > 0.75 AND all three spoofing methods are ruled out.
  - RETRY: user appears to be at the right location but is not clearly upright, or eyes are only barely
    open, or confidence is between 0.55 and 0.75.
  - REJECTED: location is wrong, person appears to be in bed or lying down, a spoofing method is
    plausible, or confidence < 0.55.
```

### Non-negotiables (source: `docs/opus-4-7-strategy.md` Layer 1)

- Images sent at full resolution — never downsize before the call.
- Response is structured JSON, not prose. JSON shape is matched by `VerificationResult`.
- Self-verification chain (3 spoofing methods) is in the system prompt. `spoofing_ruled_out` in the
  response is how we verify the chain actually executed. If the array length is < 3, treat the verdict
  as suspect (VisionVerifier's JSON decode enforces this by strict `[String]` typing).

### Change log

- **v1 (2026-04-24)** — initial Day 3 Layer 1 prompt.
```

- [ ] **Step 2: Commit.**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon add docs/vision-prompt.md
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon commit -m "Vision Phase A.7: versioned vision-prompt.md v1 artifact (mirrors VisionPromptTemplate.v1)"
```

### Task A.8: Test scenarios doc (docs/test-scenarios.md)

**Files:**
- Create: `docs/test-scenarios.md`

**Dependencies:** none (independent of code tasks)

- [ ] **Step 1: Create the doc.**

```markdown
# Vision Verification — Test Scenarios

> Five fixtures exercised before any prompt change is merged or before device-path Task B.7 can be
> declared PASS. Scenario 4 (printed-photo attack) is the demo-day money shot — if it regresses,
> the whole Layer 1 "self-commitment contract" framing is undermined.

All scenarios use the same baseline: a photo captured during onboarding at the user's kitchen
counter under morning light. The live capture differs per scenario.

---

## Scenario 1 — Kitchen, morning, alert

**Baseline:** kitchen counter, 7 am daylight.
**Live capture:** same counter, same-ish time of day, user standing, eyes clearly open, facing camera.
**Expected verdict:** VERIFIED
**Console sentinel (subsystem=com.wakeproof.verification, category=claude):** `Claude verdict VERIFIED confidence=...`
**Pass criteria:** alarm stops within ~8 s of capture; WakeAttempt row has `verdict = "VERIFIED"` and non-empty `verdictReasoning`.

## Scenario 2 — Kitchen, night, alert

**Baseline:** kitchen counter (reused).
**Live capture:** same counter, 3 am with overhead light on; user standing.
**Expected verdict:** VERIFIED (confidence may be 0.75–0.90) OR RETRY if lighting diverges too much from baseline.
**Pass criteria:** verdict is not REJECTED and not stuck in infinite retry. A RETRY followed by an anti-spoof re-capture should resolve to VERIFIED.

## Scenario 3 — Bathroom, groggy

**Baseline:** kitchen (reused).
**Live capture:** bathroom, eyes half-closed, posture slouched.
**Expected verdict:** RETRY (location differs from baseline → likely REJECTED, but eyes half-closed is classically a RETRY signal). Document whichever the model emits.
**Pass criteria:** if RETRY, the anti-spoof prompt displays a random instruction; user performs it; second call resolves deterministically to VERIFIED or REJECTED.

## Scenario 4 — **Printed photo of baseline (DEMO MONEY SHOT)**

**Baseline:** kitchen (reused).
**Live capture:** on a second phone, open the baseline photo from camera roll; hold that phone's screen up to the WakeProof camera during capture.
**Expected verdict:** REJECTED with `spoofing_ruled_out` containing "photo-of-photo" but `verdict = REJECTED` because the spoof is NOT ruled out.
**Pass criteria:** alarm continues ringing; `lastCaptureError` banner cites "photo-of-photo" or "same_location=false". Console log shows `Claude verdict REJECTED confidence=...`.
**Demo note:** this is the 60-second moment in the demo video. Rehearse it.

## Scenario 5 — User in bed

**Baseline:** kitchen (reused).
**Live capture:** user lying in bed, phone held above face.
**Expected verdict:** REJECTED (same_location=false OR person_upright=false).
**Pass criteria:** alarm continues ringing; `lastCaptureError` mentions posture or location.

---

## Budget accounting

- Each scenario costs ~$0.013 per Decision 2. Five scenarios = ~$0.065 per full pass.
- Budget for the full Day 3 device validation round (5 scenarios × 2 for reliability): ~$0.13. Non-constraint.

## When to re-run

- After any prompt change (`docs/vision-prompt.md` version bump).
- After any VisionVerifier logic change.
- Once before pushing the submission build.
- After model swap (if the hackathon adds a Haiku 4.5 vision option — check the verdict shape is unchanged).
```

- [ ] **Step 2: Commit.**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon add docs/test-scenarios.md
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon commit -m "Vision Phase A.8: 5-scenario device fixture spec (printed-photo is the money shot)"
```

### Task A.9: Simulator build sweep

**Files:** n/a (verification task)

**Dependencies:** A.1–A.8 all complete

- [ ] **Step 1: Clean build from the simulator.**

```bash
xcodebuild -project /Users/mountainfung/Desktop/WakeProof-Hackathon/WakeProof/WakeProof.xcodeproj -scheme WakeProof -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' clean build 2>&1 | tail -50
```

Expected: `** BUILD SUCCEEDED **`, zero warnings in any new file. The only compile-pending file is `VisionVerifierTests.swift` (awaits Phase B.1) — the production build succeeds because tests aren't compiled into the main target. A separate `test` target build may fail here; that's expected. Run:

```bash
xcodebuild -project /Users/mountainfung/Desktop/WakeProof-Hackathon/WakeProof/WakeProof.xcodeproj -scheme WakeProof -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 15' test -only-testing:WakeProofTests/VerificationResultTests -only-testing:WakeProofTests/ClaudeAPIClientTests 2>&1 | tail -60
```

Expected: both `VerificationResultTests` and `ClaudeAPIClientTests` pass. `VisionVerifierTests` is intentionally skipped from this run — it needs Phase B.1.

- [ ] **Step 2: Verify no `Secrets.swift` (real key) leaked into any commit.**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon log --all --full-history --diff-filter=A --name-only -- WakeProof/WakeProof/Services/Secrets.swift 2>&1 | head -5
```

Expected: empty output (no commit adds `Secrets.swift`). If anything appears, STOP and rotate the key.

- [ ] **Step 3: Confirm clean working tree.**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon status
```

Expected: working tree clean. No stray changes from Xcode auto-saves.

**Phase A gate (HARD):** Simulator production build passes. `VerificationResultTests` + `ClaudeAPIClientTests` pass. `VisionVerifierTests` intentionally compile-pending on Phase B.1. Zero real-key leakage (audit in Task A.1 verified). 7 Phase A commits landed on local `main` (Tasks A.2–A.8 each produce one commit; A.1 is an audit with no commit; A.9 is a verification sweep with no commit). `git log origin/main..main` shows them unpushed.

---

## Phase B — Integration (modifies alarm runtime, surgical additive edits only)

**Goal of phase:** Wire VisionVerifier into the Day 2 state machine without breaking any of the eight existing device tests (`docs/device-test-protocol.md` Tests 1–8). Every existing state transition, guard, and callback stays as it was; the only changes are additive enum cases, two loosened guards, and one swapped success callback. On-device verified by running the five new scenarios at B.7.

### Task B.1: Extend AlarmPhase enum + scheduler transitions

**Files:**
- Modify: `WakeProof/WakeProof/Alarm/AlarmScheduler.swift`
- Modify: `WakeProof/WakeProofTests/AlarmSchedulerTests.swift`

**Dependencies:** Phase A gate

- [ ] **Step 1: Extend the enum.** Locate the existing `enum AlarmPhase` block (lines 24–28 of the current file). Replace with:

```swift
/// Four-phase state machine for the alarm. A single ZStack overlay at the root swaps between
/// the phase-specific views. .verifying and .antiSpoofPrompt were added in Day 3; the comment
/// about nested fullScreenCover regressions still applies and the ZStack pattern prevents them.
enum AlarmPhase: Equatable {
    case idle
    case ringing
    case capturing
    case verifying
    case antiSpoofPrompt(instruction: String)
}
```

`Equatable` synthesis still works because `String` is Equatable. The `alarmPhaseContent` switch in `WakeProofApp.swift` needs the new cases (Task B.3); until then, the switch will emit a "switch must be exhaustive" warning. Add a `@unknown default: EmptyView()` there in B.3, don't silence it here.

- [ ] **Step 2: Add the four new transition methods.** Insert immediately after `returnToRingingWith(error:)` in `AlarmScheduler.swift`:

```swift
/// Transition capturing → verifying when the camera flow successfully persists a WakeAttempt
/// and VisionVerifier is about to call Claude. The ring audio stays on (volume reduction is
/// an app-root concern so the scheduler stays audio-agnostic).
func beginVerifying() {
    guard phase == .capturing else {
        logger.warning("beginVerifying ignored — phase=\(String(describing: self.phase), privacy: .public)")
        return
    }
    lastCaptureError = nil
    phase = .verifying
    logger.info("Phase → verifying")
}

/// Transition verifying → antiSpoofPrompt when Claude returns RETRY. The instruction is chosen
/// by VisionVerifier from a fixed bank; the prompt view displays it to the user, who taps
/// "I'm ready" to move back into .capturing.
func beginAntiSpoofPrompt(instruction: String) {
    guard phase == .verifying else {
        logger.warning("beginAntiSpoofPrompt ignored — phase=\(String(describing: self.phase), privacy: .public)")
        return
    }
    lastCaptureError = nil
    phase = .antiSpoofPrompt(instruction: instruction)
    logger.info("Phase → antiSpoofPrompt (instruction=\(instruction, privacy: .public))")
}

/// Transition verifying → ringing when Claude returns REJECTED or a network error occurred.
/// `error` surfaces on the ringing banner.
func returnToRingingAfterVerifying(error: String?) {
    guard phase == .verifying else {
        logger.warning("returnToRingingAfterVerifying ignored — phase=\(String(describing: self.phase), privacy: .public)")
        return
    }
    lastCaptureError = error
    phase = .ringing
    logger.info("Phase → ringing after verifying (error=\(error ?? "none", privacy: .public))")
}

/// Transition verifying → idle when Claude returns VERIFIED. Wraps `stopRinging()` behind a
/// source-phase guard so the method is named for intent (not just side-effect). `stopRinging`
/// already clears `phase`, `lastFireAt`, and `lastCaptureError` — calling it is a single source
/// of truth and avoids the `persistLastFireAt` didSet firing twice.
func finishVerifyingVerified() {
    guard phase == .verifying else {
        logger.warning("finishVerifyingVerified ignored — phase=\(String(describing: self.phase), privacy: .public)")
        return
    }
    stopRinging()
    logger.info("Phase → idle after verified")
}
```

- [ ] **Step 3: Relax two existing guards.**

In `beginCapturing()` (current line ~172), replace:

```swift
guard phase == .ringing else {
```

with:

```swift
// Accept either the initial ringing→capturing entry OR the anti-spoof re-entry.
let isValidSource: Bool
switch phase {
case .ringing: isValidSource = true
case .antiSpoofPrompt: isValidSource = true
default: isValidSource = false
}
guard isValidSource else {
```

In `returnToRingingWith(error:)` (current line ~183), replace:

```swift
guard phase == .capturing else {
```

with:

```swift
// Accept return from either capturing or verifying (network error mid-verify).
let isValidSource: Bool
switch phase {
case .capturing: isValidSource = true
case .verifying: isValidSource = true
default: isValidSource = false
}
guard isValidSource else {
```

These are literal switch replacements — do not change the `phase = .ringing` body of either method. Keep the `logger.info` lines unchanged.

- [ ] **Step 4: Add tests to `AlarmSchedulerTests.swift`.** Append (do NOT modify existing tests):

```swift
// MARK: - Day 3 phase extensions

func testBeginVerifyingFromCapturingTransitionsToVerifying() {
    scheduler.fireNow()
    scheduler.beginCapturing()
    scheduler.beginVerifying()
    XCTAssertEqual(scheduler.phase, .verifying)
}

func testBeginVerifyingIgnoredFromRinging() {
    scheduler.fireNow()
    scheduler.beginVerifying()  // still in .ringing
    XCTAssertEqual(scheduler.phase, .ringing)
}

func testReturnToRingingAfterVerifyingClearsVerifyingPhase() {
    scheduler.fireNow()
    scheduler.beginCapturing()
    scheduler.beginVerifying()
    scheduler.returnToRingingAfterVerifying(error: "Verification failed: bed")
    XCTAssertEqual(scheduler.phase, .ringing)
    XCTAssertEqual(scheduler.lastCaptureError, "Verification failed: bed")
}

func testBeginAntiSpoofPromptFromVerifyingTransitionsToAntiSpoofPrompt() {
    scheduler.fireNow()
    scheduler.beginCapturing()
    scheduler.beginVerifying()
    scheduler.beginAntiSpoofPrompt(instruction: "Blink twice")
    guard case let .antiSpoofPrompt(instruction) = scheduler.phase else {
        return XCTFail("expected antiSpoofPrompt")
    }
    XCTAssertEqual(instruction, "Blink twice")
}

func testBeginCapturingFromAntiSpoofPromptAllowsReEntry() {
    scheduler.fireNow()
    scheduler.beginCapturing()
    scheduler.beginVerifying()
    scheduler.beginAntiSpoofPrompt(instruction: "Show your right hand")
    scheduler.beginCapturing()  // re-entry from anti-spoof
    XCTAssertEqual(scheduler.phase, .capturing)
}

func testReturnToRingingWithErrorFromVerifyingIsAllowed() {
    scheduler.fireNow()
    scheduler.beginCapturing()
    scheduler.beginVerifying()
    scheduler.returnToRingingWith(error: "network down")
    XCTAssertEqual(scheduler.phase, .ringing)
    XCTAssertEqual(scheduler.lastCaptureError, "network down")
}

func testFinishVerifyingVerifiedClearsEverything() {
    scheduler.fireNow()
    scheduler.beginCapturing()
    scheduler.beginVerifying()
    scheduler.finishVerifyingVerified()
    XCTAssertEqual(scheduler.phase, .idle)
    XCTAssertNil(scheduler.lastFireAt)
}

func testFinishVerifyingVerifiedIgnoredFromOtherPhases() {
    scheduler.fireNow()
    scheduler.finishVerifyingVerified()  // still in .ringing
    XCTAssertEqual(scheduler.phase, .ringing)
    XCTAssertNotNil(scheduler.lastFireAt)
}
```

- [ ] **Step 5: Simulator build + run all three vision test classes.**

```bash
xcodebuild -project /Users/mountainfung/Desktop/WakeProof-Hackathon/WakeProof/WakeProof.xcodeproj -scheme WakeProof -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 15' test -only-testing:WakeProofTests/AlarmSchedulerTests -only-testing:WakeProofTests/VerificationResultTests -only-testing:WakeProofTests/ClaudeAPIClientTests -only-testing:WakeProofTests/VisionVerifierTests 2>&1 | tail -80
```

Expected: all four test classes pass, `Executed N tests, 0 failures`. If the full-suite count is less than Day-2's AlarmScheduler test count + 8 new + 8 VerificationResult + 7 ClaudeAPIClient + 7 VisionVerifier, investigate which new case regressed.

- [ ] **Step 6: Commit.**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon add WakeProof/WakeProof/Alarm/AlarmScheduler.swift WakeProof/WakeProofTests/AlarmSchedulerTests.swift
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon commit -m "Vision Phase B.1: extend AlarmPhase with .verifying + .antiSpoofPrompt; relax two guards (additive only)"
```

### Task B.2: Wire VisionVerifier in WakeProofApp

**Files:**
- Modify: `WakeProof/WakeProof/App/WakeProofApp.swift`

**Dependencies:** Task B.1

- [ ] **Step 1: Instantiate the verifier.** Immediately after `@State private var soundEngine = AlarmSoundEngine()` (line 19), insert:

```swift
@State private var visionVerifier = VisionVerifier()
```

- [ ] **Step 2: Register in the environment.** In the `WindowGroup` builder, after `.environment(soundEngine)`, insert:

```swift
.environment(visionVerifier)
```

- [ ] **Step 3: Wire scheduler into the verifier** in `bootstrapIfNeeded`. After `wireSchedulerCallbacks()`:

```swift
visionVerifier.scheduler = scheduler
```

- [ ] **Step 4: Simulator compile check.** Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit.**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon add WakeProof/WakeProof/App/WakeProofApp.swift
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon commit -m "Vision Phase B.2: mount VisionVerifier at app root and wire scheduler dependency"
```

### Task B.3: Swap CameraCaptureFlow success handoff

**Files:**
- Modify: `WakeProof/WakeProof/Verification/CameraCaptureFlow.swift`
- Modify: `WakeProof/WakeProof/App/WakeProofApp.swift`

**Dependencies:** Task B.2

- [ ] **Step 1: Change CameraCaptureFlow's onSuccess signature** to surface the persisted `WakeAttempt` and hand off to the verifier instead of calling the direct stop chain.

Make three precise edits inside `CameraCaptureFlow.swift`:

1. Replace the field declaration at line ~22 from

    ```swift
    let onSuccess: (CameraCaptureResult) -> Void
    ```

    to

    ```swift
    let onSuccess: (WakeAttempt) -> Void
    ```

2. Inside the `onCaptured` closure (line ~28), replace the two lines:

    ```swift
    let persisted = try await persist(result)
    scheduler.markCaptureCompleted()
    onSuccess(persisted)
    ```

    with:

    ```swift
    let persistedAttempt = try await persist(result)
    scheduler.markCaptureCompleted()
    onSuccess(persistedAttempt)
    ```

3. Change `persist`'s signature and return site. Find line ~75:

    ```swift
    private func persist(_ result: CameraCaptureResult) async throws -> CameraCaptureResult {
    ```

    Change to:

    ```swift
    private func persist(_ result: CameraCaptureResult) async throws -> WakeAttempt {
    ```

    At the end of the method body (line ~109) replace:

    ```swift
    return CameraCaptureResult(stillImage: result.stillImage, videoURL: durableVideoURL)
    ```

    with:

    ```swift
    return attempt
    ```

The `durableVideoURL` is no longer returned because `attempt.videoPath` already carries the durable filename; the verifier reads `attempt.imageData` directly for the JPEG bytes it needs.

- [ ] **Step 2: Update `RootView.alarmPhaseContent`** in `WakeProofApp.swift` to hand the persisted attempt to the verifier and add the new phase branches:

```swift
@ViewBuilder
private var alarmPhaseContent: some View {
    switch scheduler.phase {
    case .idle:
        EmptyView()
    case .ringing:
        AlarmRingingView(onRequestCapture: { scheduler.beginCapturing() })
    case .capturing:
        CameraCaptureFlow(onSuccess: { attempt in
            // Hand the WakeAttempt to the verifier. Volume reduction happens via the
            // scheduler.phase onChange handler added below. The audio/soundEngine stop
            // chain is invoked from the onChange handler when phase transitions to .idle.
            Task { @MainActor in
                if let baseline = baselines.first {
                    await visionVerifier.verify(
                        attempt: attempt,
                        baseline: baseline,
                        context: modelContext
                    )
                } else {
                    // No baseline = onboarding incomplete. This is a programmer error; the
                    // RootView gates on baselines.isEmpty before showing the scheduler UI.
                    scheduler.returnToRingingWith(error: "No baseline photo — re-run onboarding.")
                }
            }
        })
    case .verifying:
        VerifyingView()
    case .antiSpoofPrompt(let instruction):
        AntiSpoofActionPromptView(
            instruction: instruction,
            onReady: { scheduler.beginCapturing() }
        )
    }
}
```

`RootView` needs additional environment bindings:

```swift
@Environment(VisionVerifier.self) private var visionVerifier
@Environment(\.modelContext) private var modelContext
```

- [ ] **Step 3: Hook the post-verify audio stop into a phase-transition onChange.** Currently the CameraCaptureFlow success closure stopped the sound engine and alarm player directly. The new model: those stops happen on `.idle` transition. Add to `RootView.body` (alongside the existing `.onChange(of: scenePhase)`):

```swift
.onChange(of: scheduler.phase) { oldPhase, newPhase in
    switch (oldPhase, newPhase) {
    case (.verifying, .idle):
        // VERIFIED path — alarm stops, verifier state resets.
        soundEngine.stop()
        audioKeepalive.stopAlarmSound()
        visionVerifier.resetForNewFire()
    case (_, .verifying):
        // Reduce but do not mute during verification; Decision 2 failure-mode table says
        // a full mute makes the user think they already succeeded. Applies to both the
        // initial .capturing → .verifying hop AND the anti-spoof re-capture → .verifying hop.
        audioKeepalive.setAlarmVolume(0.2)
    case (.verifying, .ringing):
        // Verification failed (REJECTED or network error). Restore full volume and reset
        // the verifier so a user-initiated "Prove you're awake" retry starts with a fresh
        // two-attempt budget rather than carrying over the previous fire's state.
        audioKeepalive.setAlarmVolume(1.0)
        visionVerifier.resetForNewFire()
    // .verifying → .antiSpoofPrompt intentionally has no volume change: the anti-spoof
    // view keeps the ring volume at 0.2 (already reduced above) because the user is about
    // to re-capture in seconds. Adding a restore-then-reduce cycle would be a noticeable click.
    default:
        break
    }
}
```

- [ ] **Step 4: Simulator compile check.** Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit.**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon add WakeProof/WakeProof/Verification/CameraCaptureFlow.swift WakeProof/WakeProof/App/WakeProofApp.swift
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon commit -m "Vision Phase B.3: swap CameraCaptureFlow success → VisionVerifier; add volume-reduce on .verifying"
```

### Task B.4: Append device-test-protocol extension

**Files:**
- Modify: `docs/device-test-protocol.md`

**Dependencies:** Task B.3

- [ ] **Step 1: Append a new section at the end of the file** (immediately after `## Known not-tested-on-device`):

```markdown
---

## Vision verification scenarios (Day 3 Layer 1)

Exercise all five `docs/test-scenarios.md` fixtures on the primary test device. Each scenario is a
full alarm fire — schedule for `now + 2 minutes`, follow the capture flow through verification, and
confirm the expected verdict. Budget: ~$0.013 per scenario.

### Test 9 — Scenario 1 (kitchen/morning/alert → VERIFIED)
Follow `docs/test-scenarios.md` Scenario 1. Pass: verdict VERIFIED, alarm stops, WakeAttempt row
committed with `verdict = "VERIFIED"`.

### Test 10 — Scenario 2 (kitchen/night/alert → VERIFIED or RETRY)
Follow Scenario 2. Pass: verdict is not REJECTED; RETRY resolves after anti-spoof re-capture.

### Test 11 — Scenario 3 (bathroom/groggy → RETRY)
Follow Scenario 3. Pass: anti-spoof prompt displayed exactly once; second verification resolves
deterministically.

### Test 12 — Scenario 4 (printed photo → REJECTED) — DEMO MONEY SHOT
Follow Scenario 4. Pass: verdict REJECTED with spoofing reasoning; alarm keeps ringing; banner
surfaces the rejection reason.

### Test 13 — Scenario 5 (user in bed → REJECTED)
Follow Scenario 5. Pass: verdict REJECTED; alarm continues; banner mentions posture or location.

### Pass criteria (aggregate)
- All five verdicts match expected. Scenarios 2–3 have tolerance for alternate-path routing
  (RETRY-then-pass is valid for both).
- No console `fault` entries under `com.wakeproof.verification`.
- WakeAttempt count increments by exactly one per scenario (RETRY path does NOT create a duplicate;
  the same row is updated in place).
- Total API credit burn matches expectation (~$0.065 per full pass) in Anthropic console.
```

- [ ] **Step 2: Commit.**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon add docs/device-test-protocol.md
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon commit -m "Vision Phase B.4: extend device-test-protocol with Tests 9–13 (verification scenarios)"
```

### Task B.5: Single-call API smoke test (USER CONFIRMATION REQUIRED BEFORE RUNNING)

**Files:** n/a (live API call)

**Dependencies:** Task B.4

This is the first real Claude API call this plan produces. It burns ~$0.013 of the $500 budget. Per `CLAUDE.md` 費用安全, a single planned API call is safe to auto-execute; this step is isolated here (one call, not a batch) so the user can watch the console credit counter update.

- [ ] **Step 1: Announce.** Output to the user: *"About to make the first live Claude Opus 4.7 vision call. One call, ~$0.013. You can watch the spend tick up at console.anthropic.com/settings/usage. Proceed?"* Wait for yes.

- [ ] **Step 2: Build + install to the attached device.**

First list paired devices and pick the physical iPhone's UUID (don't hardcode — if the phone was reset or re-paired the UUID baked into `docs/device-test-protocol.md` is stale):

```bash
xcrun devicectl list devices
```

Use the `Device UUID` for the physical iPhone row (not a simulator UUID):

```bash
DEVICE_ID="<paste UUID from the previous output>"
xcodebuild -project /Users/mountainfung/Desktop/WakeProof-Hackathon/WakeProof/WakeProof.xcodeproj \
  -scheme WakeProof \
  -destination "id=${DEVICE_ID}" \
  -allowProvisioningUpdates \
  install 2>&1 | tail -30
```

Expected: `** BUILD SUCCEEDED **` + `installing to …`. If install fails with signing errors, ask the user to open Xcode, select the WakeProof target, and re-enable automatic signing before retrying.

- [ ] **Step 3: Run Scenario 1 only (the guaranteed-VERIFIED path).** Follow `docs/test-scenarios.md` Scenario 1 exactly on the device. Watch Console.app filtered to `subsystem:com.wakeproof.verification` — confirm the sequence:
    - `Calling Claude claude-opus-4-7 with <N>+<M> bytes of image data; antiSpoof=nil`
    - `Claude verdict VERIFIED confidence=…` (expected within 10 s)
    - `WakeAttempt updated: verdict=VERIFIED retryCount=0`

- [ ] **Step 4: Confirm WakeAttempt row update** via Xcode Devices & Simulators → WakeProof → Container → download → open SwiftData store. Latest row has `verdict = "VERIFIED"` and non-empty `verdictReasoning`. No duplicate rows from the same fire.

**Pass:** Scenario 1 produces a VERIFIED verdict on the first try. Claude console shows one vision call logged. No `fault` entries.
**Fail:** Report the console log to the user. Do not re-run — a second call doubles the cost; diagnose first.

### Task B.6: Five-scenario device run

**Files:** n/a (device test + protocol sign-off)

**Dependencies:** Task B.5 PASS

This executes `docs/device-test-protocol.md` Tests 9–13 in sequence. Five alarm fires, five API calls, ~$0.065 total. Still well under the 20-call batch threshold.

- [ ] **Step 1: Run Tests 9, 10, 11 in sequence.** For each: schedule alarm 2 min out, let it fire, follow the capture flow, record the verdict observed and whether it matched the expected one. If a scenario needs a RETRY → anti-spoof prompt → re-capture path, record both verdicts (RETRY + final).

- [ ] **Step 2: Run Test 12 (printed-photo REJECTED) — the money shot.** Prepare the spoof attempt: open baseline photo on a second device or printed out, hold it up to the camera during the 2-sec capture. Expected: verdict REJECTED. If REJECTED: video-record this scenario — it is the demo-day footage.

- [ ] **Step 3: Run Test 13 (user in bed REJECTED).**

- [ ] **Step 4: Append a results appendix to `docs/device-test-protocol.md`** documenting the five outcomes:

```markdown
## Appendix: Day 3 vision-verification device run (YYYY-MM-DD)

| Test | Expected | Actual | Notes |
|---|---|---|---|
| 9   | VERIFIED | …        | … |
| 10  | VERIFIED or RETRY→VERIFIED | … | … |
| 11  | RETRY→(VERIFIED or REJECTED) | … | … |
| 12  | REJECTED | …        | Spoof method used: printed photo of kitchen |
| 13  | REJECTED | …        | Bed posture |

**Credit spend this run:** ~$… per Anthropic console.
**Overall status:** PASS / PASS-with-caveats / FAIL
```

- [ ] **Step 5: Commit.**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon add docs/device-test-protocol.md
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon commit -m "Vision Phase B.6: record 5-scenario device run results including printed-photo REJECTED"
```

**Phase B gate (HARD):** All five scenarios resolve to their expected verdict (with documented alternate paths for 2 and 3). Test 12 (printed photo) rejects on first try. Total API spend < $0.20. Console shows zero faults from `com.wakeproof.verification`. Existing Tests 1–8 still pass in quick re-test (at minimum Tests 6 + 8 must be re-run here because the capture-flow handoff changed).

---

## Phase C — Review pipeline

Per `CLAUDE.md` "Multi-phase review pipeline". Each sub-step runs in order and must reach zero open issues before the plan closes.

### Task C.1: adversarial-review

**Files:** n/a (review task)

**Dependencies:** Phase B gate

- [ ] **Step 1:** Invoke the `adversarial-review` skill against the Day 3 diff:

```
git diff origin/main..HEAD -- WakeProof/WakeProof/Services WakeProof/WakeProof/Verification WakeProof/WakeProof/Alarm/AlarmScheduler.swift WakeProof/WakeProof/App/WakeProofApp.swift WakeProof/WakeProofTests docs/vision-prompt.md docs/test-scenarios.md docs/device-test-protocol.md
```

Focus prompts (explicitly ask the reviewer to look at these):
- **Secrets:** has `Services/Secrets.swift` (the real-key file) appeared in ANY commit across the Day 3 branch? Run `git log --all --full-history --diff-filter=A --name-only -- WakeProof/WakeProof/Services/Secrets.swift` and expect empty. If non-empty, hard-stop.
- **Base64 encoding of large images:** the still JPEG is ~3.75 MP (up to ~1.5 MB). Base64 is 4/3 × raw. For two images plus JSON overhead, the request body is ~4 MB. Does the `URLSession` config tolerate that? Does the Anthropic API? (Documented limit is 5 MB per image — single-image or total?). If we're near the wire, compression-disable might not be safe; re-read the strategy doc.
- **Concurrency:** `VisionVerifier.verify(...)` is `async`. Can a second capture complete while the first is in-flight and clobber `currentAttemptIndex`? The `isInFlight` guard blocks verify, but what about the path where RETRY → anti-spoof → new capture happens before the previous verify resolves (shouldn't, but the state machine should be provably bulletproof)?
- **State leak across fires:** after VERIFIED, `resetForNewFire()` clears counters. What about after REJECTED on the first call (no retry) — does the counter reset when the user re-enters `.capturing` from `.ringing`? Trace the flow.
- **ModelContext thread safety:** `VisionVerifier` is `@MainActor`; `ClaudeAPIClient.verify` does network on a background task. The `context.save()` call happens after the await resumes on MainActor. Is there any path where the `WakeAttempt` object crosses thread boundaries?
- **URLProtocol stub test hygiene:** the `StubProtocol` uses `nonisolated(unsafe) static var handler`. If two test cases run concurrently (XCTest parallelization), do they race? Should be serial by default, but the reviewer should confirm.
- **WakeAttempt row duplication risk:** if VisionVerifier gets called twice on the same `attempt` (re-capture on RETRY, but with a different WakeAttempt row each time), are we sure `CameraCaptureFlow.persist` is creating fresh rows, not reusing? Trace.
- **The `antiSpoofInstruction` random pick:** `randomElement()` returns `Optional<String>` — what happens if the bank is empty? The fallback to `"Blink twice"` covers it, but reviewer should confirm the bank can never go empty via `#error` or `precondition`.
- **The `AlarmPhase.antiSpoofPrompt(instruction: String)` case:** with associated value, `Equatable` conformance compares strings. If the verifier re-enters `.antiSpoofPrompt` with the same instruction twice (unlikely but possible), does SwiftUI's `.onChange(of: scheduler.phase)` see a no-op or does it fire again? Does any side effect depend on it firing?
- **Volume ramp after `.verifying → .ringing`:** we set `setAlarmVolume(1.0)`. But `AlarmSoundEngine`'s 60s ramp owns volume. Did ramp finish by now (15s+ verification means yes, likely at 1.0 already)? Does overwriting it cause an audible click? Test on device.

- [ ] **Step 2:** Surface every issue regardless of severity. Per `CLAUDE.md` auto-promoted rule and local decision framework: "Review 發現的所有 issue 必須處理，不論嚴重度".

- [ ] **Step 3:** Fix surfaced issues. Each fix is its own commit with WHY in the message.

### Task C.2: simplify

**Files:** n/a (review task)

**Dependencies:** Task C.1 zero open issues

- [ ] **Step 1:** Invoke `simplify` on the same diff.

- [ ] **Step 2:** Look specifically for:
    - `VisionPromptTemplate` enum with a single case `.v1`: pulling its weight vs. a plain struct? (Keep the enum — the extension story for v2 is the whole point of committing to an enum up front.)
    - `VerificationResult.fromClaudeMessageBody` and `extractJSONObject`: are they defensive against something that doesn't happen? Strip any speculative fallback paths.
    - `ClaudeAPIClient.buildRequestBody` returns `[String: Any]` — is a `Codable` struct cleaner, or does the heterogeneous image-content array make `[String: Any]` strictly simpler?
    - `VisionVerifier.handleResult` — two branches dispatch to `finish` with different verdicts. Worth hoisting the common path? Only if three branches, per "wait for the third repetition".
    - Test doubles: `FakeClient` in `VisionVerifierTests` is a 7-line struct. Keep inline vs. hoist to a shared `Mocks.swift`? Keep inline — the third consumer hasn't appeared.

- [ ] **Step 3:** Apply simplifications. Commit each with WHY.

### Task C.3: Re-review loop

**Files:** n/a

**Dependencies:** Task C.2

- [ ] **Step 1:** Re-run `adversarial-review` against the simplified diff. If new issues surface from the simplification, fix and repeat.
- [ ] **Step 2:** When both `adversarial-review` and `simplify` return zero issues for the same diff state, Phase C completes.
- [ ] **Step 3:** Log the final state:

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon log --oneline origin/main..main
```

Expected: the Phase A commits (7, because A.1 is an audit-only task) + Phase B commits (5, because B.5 is a live smoke-test step that produces no commit) + any review fixes = 12 baseline commits before any Phase C review fixes land. Ready for a `git push` **only when the user explicitly authorizes** — see the pivot trigger row below ("`Secrets.swift` appears in a diff") and `CLAUDE.md` 費用安全. Do not auto-push even at Phase C gate.

**Phase C gate (HARD):** Zero open review issues across both `adversarial-review` and `simplify`. All commit-gate requirements from `CLAUDE.md` satisfied (builds cleanly, no `print()`, no force-unwraps, no hardcoded keys, commit messages explain WHY). `Secrets.swift` has NEVER appeared in any commit diff.

---

## Cross-phase dependency summary

```
Phase A (additive, zero runtime change)
  A.1 Secrets audit (no commit) ──▶ A.2 VerificationResult + tests ──▶ A.3 ClaudeAPIClient + tests
                                                                              │
                                                                              ▼
                                                              A.4 VisionVerifier + tests (compile-pending on B.1)
                                                                              │
                                                          ┌───────────────────┴─────────────────────┐
                                                          ▼                                         ▼
                                                  A.5 VerifyingView                  A.6 AntiSpoofActionPromptView
                                                          │                                         │
                                                          └──────────────────┬──────────────────────┘
                                                                             ▼
                                                         A.7 vision-prompt.md  A.8 test-scenarios.md
                                                                             │
                                                                             ▼
                                                                  A.9 simulator build sweep ── HARD GATE ──▶

Phase B (integration; surgical edits to alarm runtime)
  B.1 AlarmPhase enum + transitions + tests ──▶ B.2 Wire VisionVerifier at app root
                                                        │
                                                        ▼
                                          B.3 Swap CameraCaptureFlow success chain
                                                        │
                                                        ▼
                                          B.4 Append Tests 9–13 to protocol doc
                                                        │
                                                        ▼
                                    B.5 Single-call API smoke test (USER CONFIRMATION)
                                                        │
                                                        ▼
                                    B.6 Five-scenario device run (~$0.065) ── HARD GATE ──▶

Phase C (review pipeline)
  C.1 adversarial-review ──▶ fix ──▶ C.2 simplify ──▶ fix ──▶ C.3 re-review
                                                                            │
                                                                            ▼ HARD GATE
                                                                 vision-verification complete
```

## Pivot triggers (do not forward-roll past these)

| Condition | Action |
|---|---|
| Phase A simulator build fails at any task | Stop. Fix before moving to next task. |
| B.5 smoke test returns a verdict other than VERIFIED in Scenario 1 | Do not run B.6 (five-scenario run). Diagnose the prompt, image encoding, or network path first. Each false negative costs $0.013 we're not learning from. |
| B.5 smoke test reports `missingAPIKey` | Verify `Secrets.swift` exists and contains a real key. Do not edit `Secrets.swift.example`. |
| Printed-photo scenario (Test 12) returns VERIFIED | Major prompt failure. The self-verification chain is not engaging. Review `docs/vision-prompt.md` system prompt; try strengthening "verify each is ruled out". If still failing after one prompt revision, escalate — this is load-bearing for the demo. |
| API latency exceeds 15 s consistently | Drop `timeoutIntervalForRequest` or raise it to 20 s. Document the change. Do NOT downsize images as a latency workaround — the strategy doc explicitly forbids this. |
| Credit spend during B.6 exceeds $0.20 | STOP. Calls are being double-fired. Inspect the `isInFlight` guard and the `.onChange(of: scheduler.phase)` handler for re-entrance. |
| B.6 Tests 1–8 regress (audio survival, force-quit recovery, etc.) | Critical. Revert the most recent Phase B integration commit, re-test the alarm core, and rebuild only the regressed subsystem before moving on. |
| `Secrets.swift` appears in a `git status` or a diff | Immediate hard-stop. Do NOT commit. `git restore --staged WakeProof/WakeProof/Services/Secrets.swift`. If it was already committed: rotate the API key at console.anthropic.com, then rewrite history locally and re-check before any push. |

## Out of scope for this plan (captured for follow-ups)

Each bullet is a known Day 4+ deliverable surfaced here so the implementer does not scope-creep:

- Layer 2 Memory Tool per-user `/memories` integration (Day 4 plan)
- Layer 3 Managed Agent overnight pipeline (Day 4 plan)
- Layer 4 weekly-coach 1M-context call (Day 4 plan)
- Replacing `UIImagePickerController` with an `AVCaptureSession`-based capture UI for better liveness cues (Day 5 polish plan if time)
- On-device face detection pre-flight via iOS `Vision` framework (Decision 2 optional Day 4)
- HealthKit sleep-summary display on the post-verify "you woke up" confirmation screen (Day 4 plan)
- Baseline-refresh prompt (if same_location false rate > 10 % over a week, ask user to re-capture)
- Metrics display: per-day success rate, average time-to-verify, etc. (Day 5 polish)
- Spoof-attempt audit view: user-viewable history of REJECTED verdicts with thumbnails (Day 5 polish)

Day numbers from `docs/build-plan.md` are reference only; advance when gates pass, not on calendar rollover.
