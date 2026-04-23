# Memory Tool (Layer 2) Implementation Plan

> **For agentic workers:** Implement task-by-task with the `subagent-driven-development` skill, same plan→implement→adversarial-review→simplify pattern as `docs/plans/vision-verification.md` and `docs/plans/alarm-core.md`. Steps use checkbox (`- [ ]`) syntax. Phase gates are **hard checkpoints** — do NOT advance past a gate that has not passed.

**Goal:** End-of-morning Day 4 deliverable per `docs/build-plan.md` Day 4 Layer 2: every vision verification call reads a per-user memory file before Claude decides, and every verdict writes a memory-update line back to it. After 3–5 mornings the memory file starts to reflect the user's actual wake pattern, and the demo can show the file contents alongside the verification flow as evidence of the "persistent memory" layer.

**Architecture:** Three-phase, matching the Day 3 pattern. **Phase A** lands all new files under strict additive-only rules: a `UserIdentity` service, a `MemoryStore` service wrapping `Documents/memories/<uuid>/`, a `MemoryPromptBuilder` that renders the store as prompt text, a `v3` `VisionPromptTemplate` that accepts an optional memory block and emits an optional memory-update block, an extended `VerificationResult` with an optional `memoryUpdate` field, and doc artifacts (`docs/memory-schema.md`, `docs/memory-prompt.md`). Phase A performs zero runtime integration with the Day 3 verification flow. **Phase B** wires the store through `ClaudeAPIClient.verify(…)` (new optional parameter, defaulted `nil` so Day 3 tests stay green), injects memory into the prompt when present, parses the memory-update field out of Claude's response, and writes it back through `MemoryStore`. Phase B also lands the one-time UUID-generation path in the app bootstrap. **Phase C** runs the multi-phase review pipeline per `CLAUDE.md` (adversarial-review → simplify → re-review).

**Tech Stack:** Swift + SwiftUI (iOS 17+). File I/O through `FileManager` (no SwiftData — memory files are authored and consumed as text, SwiftData adds no value for plain markdown/JSONL). Atomic writes via `Data.write(to:options: [.atomic])` with `.complete` file protection. Single-writer discipline enforced through an `actor MemoryStore` — Swift concurrency gives us mutual exclusion without a lock. `Logger(subsystem: "com.wakeproof.memory", category: …)` for all logs. No new SPM dependencies. **Prompt-injection path, NOT Memory Tool protocol** — decision locked during planning brainstorm; the reasoning is documented inline below and in `docs/technical-decisions.md` Decision 8 addendum (this plan writes that addendum in Task A.8).

**Non-goals for this plan (deferred to later plans):**
- Real Memory Tool protocol (`memory_20250818` tool type with 6 commands) — deferred to Layer 3 where the overnight Managed Agent has time budget for a multi-round tool loop, see `docs/plans/overnight-agent.md`
- Server-side memory mirror — the Vercel proxy stays stateless; memory is strictly local on the iPhone
- Cross-device sync of memory — single-device hackathon demo; iCloud / Supabase sync is a post-hackathon line item
- Memory-file retention / GC — `history.jsonl` grows unbounded this plan; pruning after N entries is Day 5 polish
- Multi-user profiles on one install — single `UserIdentity` per install, no account switching
- `profile.md` schema versioning — first version is freeform markdown authored by Claude
- Layer 3 (overnight agent) + Layer 4 (weekly coach) consumption of the memory store — their plans reference the APIs this plan exposes; no coupling back into this plan

---

## Architecture decision — prompt-injection vs. Memory Tool protocol

The Memory Tool (`memory_20250818`) that ships with Opus 4.7 is a client-side tool: Claude emits `tool_use` blocks with `view` / `create` / `str_replace` / `insert` / `delete` / `rename` commands, the iOS client executes them against a local `/memories` directory, and POSTs `tool_result` back. It requires an agentic loop: 2–3 round-trips per verification (initial view → maybe a read → possible write → final verdict).

This plan rejects that shape for Layer 2 and uses **prompt-injection**: iOS reads `profile.md` + last-5 `history.jsonl` entries locally, inlines them as a system-prompt block on the single existing `verify(…)` call, parses Claude's response for an optional `memory_update` field, writes any update back locally.

Reasons the protocol path is rejected for Layer 2:

1. **Vercel Hobby 10 s cap.** Day 3 observed 11–13 s upstream latency on single-round-trip vision calls; a 3-leg agentic loop would timeout unpredictably. `docs/plans/vision-verification-findings.md` B3 is not fully solved — the v2 prompt thinning got us under the cap but P95 is still tight. Adding 2× more round trips breaks the budget on the first bad network day.
2. **Demo reliability.** A 10-second alarm is useless if it sometimes takes 30 s. The prompt-injection path is a guaranteed one round-trip. `CLAUDE.md` key design principle #1 ("photo verification must feel trustworthy") depends on consistent latency.
3. **Memory content doesn't need the six-command API.** `view` + `str_replace` is all we need. We'd be implementing and testing protocol plumbing to not use most of it.
4. **The "true" Memory Tool lands in Layer 3.** The overnight Managed Agent (`docs/plans/overnight-agent.md`) DOES run the protocol — it has all night to do tool-call round-trips, and the agent's "I looked at my memory, updated it, and wrote the morning briefing" story is the demo moment the Memory Tool capability deserves. Layer 2 in prompt-injection mode preserves 90% of the "persistent memory moat" narrative for the real-time verification flow without coupling demo reliability to the protocol's round-trip behaviour.

The strategy doc's Layer 2 section explicitly lists this fallback: `docs/opus-4-7-strategy.md` Layer 2 "Fallback paths" bullet 3: *"Layer 2 Memory Tool is read-only within a conversation → persist memory file to repo-local JSON and inject as system prompt context. Narrative holds; 'agent memory' framing weakens to 'prompt memory'."* The conversation with the user during planning brainstorm confirmed this reads like a reasonable downgrade given the 5-day time budget, and Layer 3 recovers the full "agent memory" story with the overnight agent.

Task A.8 appends an addendum to `docs/technical-decisions.md` Decision 8 making this tradeoff explicit.

---

## Critical constraints (Day 4, layer 2)

Day 3 is shipped, green-tested, and smoke-tested from HK. We must not regress any of it. Specifically:

- **DO NOT** modify `WakeProof/WakeProof/Verification/VisionVerifier.swift`'s existing method signatures except the two already-public parameters of `verify(attempt:baseline:context:)` — Phase B.3 extends it additively with one new optional parameter (`memory: MemorySnapshot? = nil`) to preserve Day 3 callers. The body's core flow (beginVerifying → handleResult / handleAPIError → persistOrFallbackToRinging → scheduler transition) stays structurally identical; the only insertions are (a) a memory read before the Claude call, (b) a memory write after `handleResult`.
- **DO NOT** modify `WakeProof/WakeProof/Services/ClaudeAPIClient.swift`'s existing `verify(…)` signature or `ClaudeAPIError` enum. Phase B.2 adds an optional 5th parameter `memoryContext: String? = nil` with a default — all Day 3 tests call the 4-arg form unchanged.
- **DO NOT** modify `WakeProof/WakeProof/Alarm/AlarmScheduler.swift` at all. Memory is transparent to the alarm state machine.
- **DO NOT** modify `WakeProof/WakeProof/Alarm/AudioSessionKeepalive.swift` or `AlarmSoundEngine.swift` at all.
- **DO NOT** modify the Vercel proxy (`workers/wakeproof-proxy-vercel/api/v1/messages.js`). Memory is entirely client-side; the proxy sees a slightly fatter system prompt but the shape is unchanged.
- **DO NOT** break the `WakeAttempt` schema. Memory lives in `Documents/memories/<uuid>/`, not in SwiftData.
- **DO NOT** hardcode any API key anywhere. No new keys are needed — Layer 2 reuses the existing `Secrets.wakeproofToken`.
- **DO NOT** run more than the one live Claude API call scheduled in Task B.6 without user confirmation, per `CLAUDE.md` 費用安全.
- **DO NOT** run `git push`. Local commits only.
- **DO NOT** write memory content directly to `Documents/` without `.complete` file protection + `isExcludedFromBackup = true`. Memory contains observed behavioural patterns — treat it with the same privacy hygiene as the video files (`CameraCaptureFlow.moveVideoToDocuments` is the pattern to copy).
- **DO NOT** allow the user-UUID to be derived from `identifierForVendor` or any Apple-managed identifier. Generate a fresh random UUID on first launch and persist to UserDefaults. Reasons: (a) `identifierForVendor` changes on app uninstall-reinstall, which would orphan memory; (b) any Apple-derived ID is technically a privacy-scoped identifier that we'd need to mention in the privacy policy — a self-generated UUID with no cross-app meaning has lower disclosure overhead.

Phase A is fully additive with zero runtime integration risk. Phase B is where Day 3 regressions become possible; each Phase B task runs simulator builds + the existing 52-test suite, and a single on-device smoke test validates the integration before Phase C.

---

## Token-cost budget (measured 2026-04-24, corrected in Phase C.1 from R7)

| Item | Size | Token delta vs v2 | USD delta @ Opus 4.7 input $15/Mtok |
|---|---|---|---|
| v2 system prompt | 1167 chars | baseline | baseline |
| v3 system prompt | 2459 chars | +~323 tokens | +$0.00485 per call |
| v3 user prompt `memory_update` schema block | +~100 chars | +~25 tokens | +$0.00038 per call |
| Per-call delta vs v2, memory empty | — | +~348 tokens | +$0.00523 per call |
| Per-call delta vs v2, memory active (profile + 5 history rows ~2000 chars) | — | +~848 tokens | +$0.01272 per call |

Measured 2026-04-24 against the live B.5 smoke test: **1120 input tokens + 204 output tokens** on a minimal request (no memory), producing **$0.0107** — grounded figure for the zero-memory branch.

The pre-C.1 estimate of "~225 extra tokens/call for v3" undershot by ~44% because it accounted for the system-prompt delta only, not the v3 user-prompt schema block. Corrected figures above are what the budget tracker in `docs/opus-4-7-strategy.md` should use.

---

## File Structure

New or modified in this plan:

| Path | Action | Responsibility |
|---|---|---|
| `WakeProof/WakeProof/Services/UserIdentity.swift` | Create | `struct UserIdentity` with `static let shared = UserIdentity()`. On first access, generates a random UUID via `UUID().uuidString` and persists to `UserDefaults.standard` under `com.wakeproof.user.uuid`. Subsequent accesses return the persisted value. Exposes `uuid: String` and `rotate()` (debug-only, for testing the onboarding path). |
| `WakeProof/WakeProof/Storage/MemoryEntry.swift` | Create | `struct MemoryEntry: Codable, Equatable`: `timestamp: Date`, `verdict: String` (raw from `WakeAttempt.Verdict`), `confidence: Double?`, `retryCount: Int`, `note: String?` (Claude-authored free-text observation). `static func makeEntry(fromAttempt: WakeAttempt, confidence: Double?, note: String?) -> MemoryEntry` for the call site. |
| `WakeProof/WakeProof/Storage/MemorySnapshot.swift` | Create | `struct MemorySnapshot: Equatable`: frozen view of the memory at read time. Fields: `profile: String?`, `recentHistory: [MemoryEntry]`, `totalHistoryCount: Int`. `var isEmpty: Bool`. Passed to `ClaudeAPIClient.verify(…)` and consumed by `MemoryPromptBuilder`. Immutable by design: VisionVerifier reads once, uses for the whole call. |
| `WakeProof/WakeProof/Services/MemoryStore.swift` | Create | `actor MemoryStore` (Swift concurrency actor — one writer at a time, no locks). Public API: `func read() async throws -> MemorySnapshot`, `func appendHistory(_ entry: MemoryEntry) async throws`, `func rewriteProfile(_ markdown: String) async throws`, `func bootstrapIfNeeded() async throws`. Internal: owns `Documents/memories/<UserIdentity.shared.uuid>/`; creates on first touch; enforces file-protection + backup-exclusion; guards `profile.md` rewrite with a size cap (16 KB hard limit — oversized updates are truncated with a warning log). `history.jsonl` is append-only, newline-delimited JSON; reads use `String(contentsOf:)` and split on newlines (file stays small — cap at 4096 entries before rotation, which Day 4 does not implement, just logs). |
| `WakeProof/WakeProof/Services/MemoryPromptBuilder.swift` | Create | Pure function: `struct MemoryPromptBuilder { static func render(_ snapshot: MemorySnapshot) -> String? }`. Returns nil if snapshot is empty — allows the prompt template to short-circuit the memory block entirely and keep token overhead at zero for the first wake. Returns a `<memory_context>…</memory_context>` XML-style block otherwise (Claude's released guidance for Opus 4.7 prefers XML tags over markdown for structured context). Recent history is rendered as a compact markdown table, oldest first. Hard truncation at 2000 chars — profile is preserved, history is dropped oldest-first until under budget. |
| `WakeProof/WakeProof/Verification/VerificationResult.swift` | Modify (additive) | Add optional nested struct `MemoryUpdate: Codable, Equatable` (fields: `profileDelta: String?`, `historyNote: String?`). Add `memoryUpdate: MemoryUpdate?` to `VerificationResult`. Update `CodingKeys` enum. `fromClaudeMessageBody(_:)` parser already tolerates extra fields; adding a nested optional is a no-op for the existing path. Tests extend `VerificationResultTests.swift` to cover the new field's present/absent/malformed shapes. |
| `WakeProof/WakeProof/Services/ClaudeAPIClient.swift` | Modify (additive) | (1) Extend `ClaudeVisionClient` protocol with a second `verify(…)` method that accepts a `memoryContext: String?`. Keep the existing method as a thin wrapper calling the new one with `nil`. Day 3 callers and tests unchanged. (2) Extend `VisionPromptTemplate` enum with a `v3` case — `.v3` becomes the new default for fresh `ClaudeAPIClient()` instances; `v2` stays for rollback; `v1` stays for archaeology. `v3` systemPrompt + userPrompt accept the optional memory block and request an optional `memory_update` field in the output JSON. (3) Extend `buildRequestBody` to interpolate the memory block when present. Nothing else changes in the network path. |
| `WakeProof/WakeProof/Verification/VisionVerifier.swift` | Modify (surgical) | (1) Accept a `memoryStore: MemoryStore?` via initializer (defaulted nil for test constructors; wired by `WakeProofApp`). (2) In `verify(…)`: before the Claude call, `let snapshot = try await memoryStore?.read() ?? .empty`, pass `MemoryPromptBuilder.render(snapshot)` into the new `client.verify(…, memoryContext:)`. (3) After a successful `handleResult`: if `result.memoryUpdate != nil`, call `memoryStore?.appendHistory(…)` and/or `memoryStore?.rewriteProfile(…)`. Memory write failures are **logged and non-fatal** — the verdict has already transitioned the scheduler; failing to write memory does not rewind the alarm. |
| `WakeProof/WakeProof/App/WakeProofApp.swift` | Modify (surgical) | (1) Instantiate `MemoryStore` as `@State`. (2) `bootstrapIfNeeded` calls `await memoryStore.bootstrapIfNeeded()` in a detached task and wires `visionVerifier.memoryStore = memoryStore` after scheduler wiring. (3) `UserIdentity.shared.uuid` is first-touched during bootstrap so UUID generation happens once, at app launch, before any verification. |
| `WakeProof/WakeProofTests/UserIdentityTests.swift` | Create | Tests: first-access generates + persists a UUID; second access returns the same string; `rotate()` generates a new one; the persisted string is a valid UUID shape. Uses a throwaway `UserDefaults(suiteName:)` per test to avoid bleeding across the suite. |
| `WakeProof/WakeProofTests/MemoryEntryTests.swift` | Create | Codable round-trip tests: encoding produces stable key order (lexicographic, verified against a golden string); decoding tolerates unknown fields (future-proof); encoding decimal confidence preserves the value without scientific notation; missing optional fields (confidence, note) decode to nil. |
| `WakeProof/WakeProofTests/MemorySnapshotTests.swift` | Create | Construction tests: `isEmpty` returns true when `profile == nil` and `recentHistory.isEmpty`; otherwise false. `totalHistoryCount` independence from `recentHistory.count` (snapshot can show last 5 of 1000). |
| `WakeProof/WakeProofTests/MemoryStoreTests.swift` | Create | Tests cover: empty-directory bootstrap; read-empty returns `MemorySnapshot.empty`; write-profile-then-read returns that profile; append-history-then-read returns that entry; N=200 appends then read returns only last 5; profile rewrite replaces (not appends); oversized profile write (>16 KB) truncates with warning log; path-traversal UUID (`../evil`) cannot escape `Documents/memories/`; file-protection + backup-exclusion flags present on directory and both files; concurrent `appendHistory` from 10 tasks produces 10 distinct entries with no interleaving corruption. |
| `WakeProof/WakeProofTests/MemoryPromptBuilderTests.swift` | Create | Tests: empty snapshot returns nil; snapshot with only profile returns a block with just the profile; snapshot with only history returns a block with a table; snapshot with both returns the ordered profile-then-history block; 4000-char profile + 5 entries is truncated so output ≤ 2000 chars with profile preserved; ordering is oldest-first (Claude decided this reads more naturally). |
| `WakeProof/WakeProofTests/VerificationResultTests.swift` | Modify (append) | Add tests: JSON with `memory_update` object → `memoryUpdate` populated; JSON without the field → `memoryUpdate == nil`; JSON with `memory_update: {}` → non-nil struct with both fields nil; JSON with `memory_update: null` → nil. Extra field inside `memory_update` is ignored (not a decode error). |
| `WakeProof/WakeProofTests/VisionVerifierTests.swift` | Modify (append) | Add tests: when verifier has no memoryStore, `verify(…)` calls client with `memoryContext = nil` and does not try to write; when verifier has a memoryStore, `verify(…)` reads snapshot and passes `memoryContext != nil` if snapshot non-empty; after VERIFIED with memoryUpdate present, `appendHistory` was called with matching values; after REJECTED with memoryUpdate present, `appendHistory` was still called (memory captures all verdicts); after VERIFIED with memoryUpdate nil, `appendHistory` was NOT called (we don't speculatively log); a memoryStore write failure is logged but does NOT rewind the scheduler transition. |
| `WakeProof/WakeProofTests/ClaudeAPIClientTests.swift` | Modify (append) | Add tests: new `verify(…, memoryContext:)` method invoked with a non-nil memoryContext embeds the block verbatim in the system prompt (assert via the stubbed request body); same method invoked with nil memoryContext produces a request body byte-identical to the Day 3 4-arg path (guards against token regression); `v3` prompt template is the default for fresh `ClaudeAPIClient()` instances; `v3` prompt explicitly mentions the `memory_update` output field. |
| `docs/memory-schema.md` | Create | Documents the on-disk format: directory layout, `profile.md` expectations (plain markdown, <16 KB), `history.jsonl` field set, privacy flags, capacity limits. Cross-references `docs/memory-prompt.md` for how the data is consumed at call time. |
| `docs/memory-prompt.md` | Create | v1 of the memory-aware vision prompt (the v3 VisionPromptTemplate). System prompt + user prompt + the memory context block interpolation. Mirrors the shape of `docs/vision-prompt.md`. |
| `docs/vision-prompt.md` | Modify (append) | Append v3 section describing how v3 differs from v2 (adds memory context + memory_update output) with a pointer to `docs/memory-prompt.md` as the full artifact. |
| `docs/technical-decisions.md` | Modify (append) | Append a Decision 8 addendum locking the prompt-injection-over-protocol decision with the rejected-alternatives table. |
| `docs/plans/memory-tool.md` | Create | This file. |

---

## Phase A — Additive infrastructure (zero runtime integration)

**Goal of phase:** Land every new file needed for Layer 2 memory and every new doc artifact, all under additive-only rules. Simulator builds clean at the end of every task. A build shipped at the end of Phase A runs **exactly like Day 3** on-device — no memory is read or written, no prompt change is observable, no test regressions.

### Task A.0: Plan lands in repo

**Files:**
- Create: `docs/plans/memory-tool.md` (this document)

**Dependencies:** none (first task)

- [ ] **Step 1: Verify the file you are reading is committed.** If not, commit it before touching anything else. A plan that lives only in this session is not a plan.

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon status docs/plans/memory-tool.md
```

Expected: either `untracked` (then commit it here) or `clean` (already committed). If the file is present in git but has uncommitted edits, stage + commit those edits as a separate commit before proceeding.

- [ ] **Step 2: Commit.**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon add docs/plans/memory-tool.md
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon commit -m "Memory Phase A.0: land the memory-tool implementation plan document"
```

### Task A.1: UserIdentity service

**Files:**
- Create: `WakeProof/WakeProof/Services/UserIdentity.swift`
- Create: `WakeProof/WakeProofTests/UserIdentityTests.swift`

**Dependencies:** Task A.0

**Important context:** There is no existing user identity in the app. Day 3 is effectively single-user: the single `BaselinePhoto` row in SwiftData is the entire user-specific state. Memory introduces a per-user file-system directory that must survive relaunch without depending on SwiftData. We persist a UUID to `UserDefaults.standard`. Rationale for a self-generated UUID (vs. `identifierForVendor`) is in "Critical constraints" above.

- [ ] **Step 1: Create `UserIdentity.swift`:**

```swift
//
//  UserIdentity.swift
//  WakeProof
//
//  One random UUID per install, persisted to UserDefaults. First access generates;
//  subsequent accesses return the stored value. We use a self-generated UUID rather
//  than `identifierForVendor` so (a) reinstalling WakeProof rotates the ID cleanly
//  (simulating a fresh-install state for memory without iOS playing tricks), and
//  (b) we avoid adding an Apple-derived-identifier disclosure to the privacy copy.
//

import Foundation
import os

struct UserIdentity {

    /// Shared instance read lazily. A struct + static var is sufficient because the
    /// API is a single string — no observable state, no mutation hooks, no SwiftUI
    /// subscription needs. Threading safety comes from `UserDefaults` being thread-safe.
    static let shared = UserIdentity()

    private static let key = "com.wakeproof.user.uuid"
    private static let logger = Logger(subsystem: "com.wakeproof.memory", category: "identity")

    /// The install's stable UUID. First access generates + persists.
    var uuid: String {
        if let existing = UserDefaults.standard.string(forKey: Self.key) {
            return existing
        }
        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: Self.key)
        Self.logger.info("Generated new user UUID (first launch)")
        return generated
    }

    #if DEBUG
    /// Test-only hook. Clears the stored UUID so the next `uuid` access generates.
    /// Guarded `#if DEBUG` so release builds cannot accidentally lose user memory by
    /// calling this from a future refactor.
    func rotate() {
        UserDefaults.standard.removeObject(forKey: Self.key)
        Self.logger.warning("User UUID rotated (debug-only path)")
    }
    #endif
}
```

- [ ] **Step 2: Create `UserIdentityTests.swift`:**

```swift
//
//  UserIdentityTests.swift
//  WakeProofTests
//

import XCTest
@testable import WakeProof

final class UserIdentityTests: XCTestCase {

    private var suiteDefaults: UserDefaults!
    private let suiteName = "com.wakeproof.tests.useridentity"

    override func setUp() {
        super.setUp()
        // Wipe any stale default from a prior run so every test starts fresh.
        UserDefaults.standard.removeObject(forKey: "com.wakeproof.user.uuid")
        suiteDefaults = UserDefaults(suiteName: suiteName)
        suiteDefaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        suiteDefaults?.removePersistentDomain(forName: suiteName)
        UserDefaults.standard.removeObject(forKey: "com.wakeproof.user.uuid")
        super.tearDown()
    }

    func testFirstAccessGeneratesUUID() {
        let id = UserIdentity.shared.uuid
        XCTAssertFalse(id.isEmpty)
        XCTAssertNotNil(UUID(uuidString: id), "UserIdentity should yield a valid UUID string shape")
    }

    func testSecondAccessReturnsSameUUID() {
        let first = UserIdentity.shared.uuid
        let second = UserIdentity.shared.uuid
        XCTAssertEqual(first, second, "Repeated access must return the persisted UUID, not regenerate")
    }

    func testPersistsAcrossUserDefaultsReads() {
        let first = UserIdentity.shared.uuid
        let defaults = UserDefaults.standard
        XCTAssertEqual(defaults.string(forKey: "com.wakeproof.user.uuid"), first,
                       "UUID must be written to UserDefaults.standard under the documented key")
    }

    #if DEBUG
    func testRotateGeneratesDifferentUUID() {
        let first = UserIdentity.shared.uuid
        UserIdentity.shared.rotate()
        let second = UserIdentity.shared.uuid
        XCTAssertNotEqual(first, second, "rotate() must force fresh generation on next access")
    }
    #endif
}
```

- [ ] **Step 3: Simulator build + run tests.**

```bash
xcodebuild -project /Users/mountainfung/Desktop/WakeProof-Hackathon/WakeProof/WakeProof.xcodeproj \
  -scheme WakeProof -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  test -only-testing:WakeProofTests/UserIdentityTests 2>&1 | tail -40
```

Expected: 4 tests pass (3 in release config, 4 in DEBUG).

- [ ] **Step 4: Commit.**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon add WakeProof/WakeProof/Services/UserIdentity.swift WakeProof/WakeProofTests/UserIdentityTests.swift
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon commit -m "Memory Phase A.1: UserIdentity service (self-generated UUID in UserDefaults) + tests"
```

### Task A.2: MemoryEntry + MemorySnapshot value types

**Files:**
- Create: `WakeProof/WakeProof/Storage/MemoryEntry.swift`
- Create: `WakeProof/WakeProof/Storage/MemorySnapshot.swift`
- Create: `WakeProof/WakeProofTests/MemoryEntryTests.swift`
- Create: `WakeProof/WakeProofTests/MemorySnapshotTests.swift`

**Dependencies:** Task A.1

**Important context:** These are pure value types. `MemoryEntry` is the row format for `history.jsonl` — one JSON object per line, newline-delimited. `MemorySnapshot` is the frozen view that `MemoryStore.read()` hands to `VisionVerifier` — read once, consumed for the whole verification flow, then discarded. Keeping them free of SwiftData means `MemoryStore`'s file I/O is the only place memory touches disk; testing both types needs no `ModelContainer` scaffolding.

- [ ] **Step 1: Create `MemoryEntry.swift`:**

```swift
//
//  MemoryEntry.swift
//  WakeProof
//
//  One row of history.jsonl. Kept small — memory is consumed by Opus 4.7 as prompt
//  context, so each row's token cost matters. Fields chosen for recall value:
//  verdict + confidence carry the actual outcome, retryCount hints at difficulty,
//  note captures a Claude-authored observation ("lighting dim" / "posture leaning").
//

import Foundation

struct MemoryEntry: Codable, Equatable {

    let timestamp: Date
    /// Raw WakeAttempt.Verdict rawValue (`VERIFIED`, `REJECTED`, `RETRY`, etc.). Stored
    /// as String (not the enum) so future enum additions don't break decoding of older rows.
    let verdict: String
    /// Optional — only present when we had a Claude verdict. Missing on fallback paths.
    let confidence: Double?
    let retryCount: Int
    /// Optional Claude-authored observation, at most ~120 chars. Empty/nil when no insight.
    let note: String?

    enum CodingKeys: String, CodingKey {
        case timestamp = "t"
        case verdict   = "v"
        case confidence = "c"
        case retryCount = "r"
        case note      = "n"
    }

    static func makeEntry(
        timestamp: Date = .now,
        fromAttempt attempt: WakeAttempt,
        confidence: Double?,
        note: String?
    ) -> MemoryEntry {
        MemoryEntry(
            timestamp: timestamp,
            verdict: attempt.verdict ?? WakeAttempt.Verdict.unresolved.rawValue,
            confidence: confidence,
            retryCount: attempt.retryCount,
            note: note
        )
    }
}
```

- [ ] **Step 2: Create `MemorySnapshot.swift`:**

```swift
//
//  MemorySnapshot.swift
//  WakeProof
//
//  Frozen view of the memory store at read time. MemoryStore.read() materialises
//  one of these and hands it to the verifier; the verifier passes it through to
//  MemoryPromptBuilder. Immutable by design — treat as a value, copy freely.
//

import Foundation

struct MemorySnapshot: Equatable {

    /// Free-form markdown authored by Claude across prior verifications. Optional —
    /// the file may not exist yet on first launch, or may have been cleared.
    let profile: String?

    /// Most recent verification records, oldest first. Hard-capped at the read limit
    /// configured in MemoryStore (default 5). This is what Claude sees on each call.
    let recentHistory: [MemoryEntry]

    /// Total number of entries in history.jsonl at read time. Used by the prompt
    /// builder to communicate "we've done N verifications total, here are the last 5".
    let totalHistoryCount: Int

    /// Convenience — treat as empty if there is no profile and no history to show.
    var isEmpty: Bool { profile == nil && recentHistory.isEmpty }

    static let empty = MemorySnapshot(profile: nil, recentHistory: [], totalHistoryCount: 0)
}
```

- [ ] **Step 3: Create `MemoryEntryTests.swift`:**

```swift
//
//  MemoryEntryTests.swift
//  WakeProofTests
//

import XCTest
@testable import WakeProof

final class MemoryEntryTests: XCTestCase {

    private let fixedDate = Date(timeIntervalSince1970: 1_745_466_662)  // 2025-04-24T00:31:02Z

    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    func testRoundTrip() throws {
        let entry = MemoryEntry(
            timestamp: fixedDate,
            verdict: "VERIFIED",
            confidence: 0.82,
            retryCount: 0,
            note: "first morning, well-lit"
        )
        let data = try encoder.encode(entry)
        let decoded = try decoder.decode(MemoryEntry.self, from: data)
        XCTAssertEqual(entry, decoded)
    }

    func testEncodedKeysUseCompactNames() throws {
        let entry = MemoryEntry(
            timestamp: fixedDate, verdict: "REJECTED",
            confidence: 0.41, retryCount: 1, note: nil
        )
        let data = try encoder.encode(entry)
        let string = String(data: data, encoding: .utf8) ?? ""
        // Compact keys keep prompt token cost down across many history lines.
        XCTAssertTrue(string.contains("\"t\""))
        XCTAssertTrue(string.contains("\"v\""))
        XCTAssertTrue(string.contains("\"r\""))
        XCTAssertFalse(string.contains("\"timestamp\""))
    }

    func testMissingOptionalFieldsDecodeAsNil() throws {
        let minimal = #"{"t":"2025-04-24T00:31:02Z","v":"CAPTURED","r":0}"#
        let data = Data(minimal.utf8)
        let decoded = try decoder.decode(MemoryEntry.self, from: data)
        XCTAssertNil(decoded.confidence)
        XCTAssertNil(decoded.note)
        XCTAssertEqual(decoded.verdict, "CAPTURED")
    }

    func testUnknownFieldsAreIgnored() throws {
        // Future-proofing: adding a new field (e.g., "location") in v4 must not break v3 readers.
        let withExtra = #"{"t":"2025-04-24T00:31:02Z","v":"VERIFIED","r":0,"location":"kitchen"}"#
        let data = Data(withExtra.utf8)
        let decoded = try decoder.decode(MemoryEntry.self, from: data)
        XCTAssertEqual(decoded.verdict, "VERIFIED")
    }

    func testConfidencePrecisionPreserved() throws {
        let entry = MemoryEntry(
            timestamp: fixedDate, verdict: "VERIFIED",
            confidence: 0.7523456789, retryCount: 0, note: nil
        )
        let data = try encoder.encode(entry)
        let decoded = try decoder.decode(MemoryEntry.self, from: data)
        XCTAssertEqual(entry.confidence!, decoded.confidence!, accuracy: 1e-10)
    }

    func testMakeEntryFromAttempt() {
        let attempt = WakeAttempt(scheduledAt: fixedDate)
        attempt.verdict = "VERIFIED"
        attempt.retryCount = 1
        let entry = MemoryEntry.makeEntry(
            timestamp: fixedDate,
            fromAttempt: attempt,
            confidence: 0.9,
            note: "second try after retry"
        )
        XCTAssertEqual(entry.verdict, "VERIFIED")
        XCTAssertEqual(entry.retryCount, 1)
        XCTAssertEqual(entry.confidence, 0.9)
        XCTAssertEqual(entry.note, "second try after retry")
        XCTAssertEqual(entry.timestamp, fixedDate)
    }

    func testMakeEntryHandlesNilVerdict() {
        // WakeAttempt.verdict is optional; a row that persists with no string should
        // map to the legacy .unresolved sentinel via the established fallback.
        let attempt = WakeAttempt(scheduledAt: fixedDate)
        attempt.verdict = nil
        let entry = MemoryEntry.makeEntry(
            timestamp: fixedDate, fromAttempt: attempt,
            confidence: nil, note: nil
        )
        XCTAssertEqual(entry.verdict, WakeAttempt.Verdict.unresolved.rawValue)
    }
}
```

- [ ] **Step 4: Create `MemorySnapshotTests.swift`:**

```swift
//
//  MemorySnapshotTests.swift
//  WakeProofTests
//

import XCTest
@testable import WakeProof

final class MemorySnapshotTests: XCTestCase {

    func testEmptyHasNoContent() {
        XCTAssertTrue(MemorySnapshot.empty.isEmpty)
        XCTAssertEqual(MemorySnapshot.empty.recentHistory.count, 0)
        XCTAssertNil(MemorySnapshot.empty.profile)
        XCTAssertEqual(MemorySnapshot.empty.totalHistoryCount, 0)
    }

    func testProfileOnlyIsNotEmpty() {
        let snap = MemorySnapshot(profile: "Observations across 3 mornings…", recentHistory: [], totalHistoryCount: 0)
        XCTAssertFalse(snap.isEmpty)
    }

    func testHistoryOnlyIsNotEmpty() {
        let entry = MemoryEntry(timestamp: .now, verdict: "VERIFIED", confidence: 0.8, retryCount: 0, note: nil)
        let snap = MemorySnapshot(profile: nil, recentHistory: [entry], totalHistoryCount: 1)
        XCTAssertFalse(snap.isEmpty)
    }

    func testTotalCountIndependentOfRecent() {
        let entries = (0..<5).map { i in
            MemoryEntry(timestamp: .now, verdict: "VERIFIED", confidence: 0.8, retryCount: 0, note: "entry \(i)")
        }
        let snap = MemorySnapshot(profile: nil, recentHistory: entries, totalHistoryCount: 1000)
        XCTAssertEqual(snap.recentHistory.count, 5)
        XCTAssertEqual(snap.totalHistoryCount, 1000)
    }
}
```

- [ ] **Step 5: Simulator build + run new tests.**

```bash
xcodebuild -project /Users/mountainfung/Desktop/WakeProof-Hackathon/WakeProof/WakeProof.xcodeproj \
  -scheme WakeProof -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  test -only-testing:WakeProofTests/MemoryEntryTests -only-testing:WakeProofTests/MemorySnapshotTests 2>&1 | tail -50
```

Expected: 11 tests pass (7 entry + 4 snapshot).

- [ ] **Step 6: Commit.**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon add WakeProof/WakeProof/Storage/MemoryEntry.swift WakeProof/WakeProof/Storage/MemorySnapshot.swift WakeProof/WakeProofTests/MemoryEntryTests.swift WakeProof/WakeProofTests/MemorySnapshotTests.swift
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon commit -m "Memory Phase A.2: value types (MemoryEntry with compact codable keys, MemorySnapshot) + tests"
```

### Task A.3: MemoryStore actor

**Files:**
- Create: `WakeProof/WakeProof/Services/MemoryStore.swift`
- Create: `WakeProof/WakeProofTests/MemoryStoreTests.swift`

**Dependencies:** Task A.2

**Important context:** This is the disk-backed store. It is an `actor` (Swift concurrency actor type, NOT `@MainActor`) so that concurrent `appendHistory` calls serialize without a manual lock. Every public method is `async throws`. The store owns `Documents/memories/<UserIdentity.shared.uuid>/` and two files within: `profile.md` (Claude-authored markdown, rewritable, soft 16 KB cap) and `history.jsonl` (newline-delimited `MemoryEntry` JSON, append-only, soft 4096-entry cap). Cap violations log warnings but do not throw; Day 5 polish handles rotation.

Privacy hardening matches Day 3 `CameraCaptureFlow.moveVideoToDocuments` — `.complete` file protection + `isExcludedFromBackup`. Reason: memory contains behavioural fingerprints (time of wake, confidence curve over time, Claude-authored observations) that a forensic iCloud dump should not yield.

- [ ] **Step 1: Create `MemoryStore.swift`:**

```swift
//
//  MemoryStore.swift
//  WakeProof
//
//  On-disk store for the Layer 2 per-user memory file. Two files per user UUID:
//    Documents/memories/<uuid>/profile.md      — Claude-authored persistent profile
//    Documents/memories/<uuid>/history.jsonl   — one MemoryEntry JSON per line
//
//  Wrapped in a Swift actor so concurrent appendHistory / rewriteProfile calls
//  serialise without a manual lock. Caller-facing API is async throws. All writes
//  go through `.complete` file protection and `isExcludedFromBackup = true`.
//
//  Size discipline: profile.md soft cap 16 KB (oversized rewrites truncate with a
//  warning log); history.jsonl soft cap 4096 entries (reached but unenforced on
//  Day 4 — a warning log is emitted, rotation is Day 5 polish). Reads return at
//  most `historyReadLimit` entries (default 5) so the prompt payload stays bounded.
//

import Foundation
import os

actor MemoryStore {

    // MARK: - Configuration

    /// Injectable for tests. Production use: `MemoryStore()` resolves to
    /// `Documents/memories/<UserIdentity.shared.uuid>/`.
    struct Configuration {
        var rootDirectory: URL
        var userUUID: String
        var historyReadLimit: Int = 5
        var profileMaxBytes: Int = 16 * 1024
        var historyMaxEntries: Int = 4096
    }

    private let configuration: Configuration
    private let logger = Logger(subsystem: "com.wakeproof.memory", category: "store")

    // MARK: - Public API

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// Production initializer — derives the path from UserIdentity.
    /// A caller in WakeProofApp does `MemoryStore()` once at bootstrap.
    init() {
        let docs: URL
        do {
            docs = try FileManager.default.url(
                for: .documentDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            )
        } catch {
            // Documents is guaranteed by iOS; a failure here is a platform-level
            // pathological state (ReadOnly device, disk corruption). Fall back to
            // tmp so the app continues to launch without crashing — reads will
            // return .empty, writes will discard cleanly, and the logger surfaces
            // the root cause for triage.
            Logger(subsystem: "com.wakeproof.memory", category: "store")
                .fault("Documents directory unavailable, memory will be ephemeral: \(error.localizedDescription, privacy: .public)")
            docs = FileManager.default.temporaryDirectory
        }
        self.configuration = Configuration(
            rootDirectory: docs.appendingPathComponent("memories", isDirectory: true),
            userUUID: UserIdentity.shared.uuid
        )
    }

    /// Ensure `memories/<uuid>/` exists and is excluded from backup. Safe to call
    /// many times — subsequent calls are no-ops. Call once from `WakeProofApp.
    /// bootstrapIfNeeded` so the first verification never pays a directory-create
    /// cost inline.
    func bootstrapIfNeeded() async throws {
        let userDir = try userDirectoryURL()
        let fm = FileManager.default
        try fm.createDirectory(at: userDir, withIntermediateDirectories: true)
        // Idempotent backup-exclusion write. If setResourceValues fails (transient
        // filesystem state), log and continue; the directory itself already exists.
        var mutable = userDir
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        do { try mutable.setResourceValues(rv) }
        catch { logger.warning("Failed to mark memories dir excluded-from-backup: \(error.localizedDescription, privacy: .public)") }
        logger.info("MemoryStore bootstrap ok for user \(self.configuration.userUUID.prefix(8), privacy: .private)…")
    }

    /// Read profile + recent history into a frozen snapshot. Returns `.empty` if
    /// the directory doesn't exist yet (first-ever launch) or if both files are
    /// missing. Never throws for "file absent" — that's the expected steady state
    /// for a fresh install.
    func read() async throws -> MemorySnapshot {
        let userDir = try userDirectoryURL()
        let fm = FileManager.default
        guard fm.fileExists(atPath: userDir.path) else {
            return .empty
        }
        let profile = try? loadProfile(in: userDir)
        let (recent, total) = loadHistory(in: userDir)
        let snapshot = MemorySnapshot(
            profile: profile,
            recentHistory: recent,
            totalHistoryCount: total
        )
        return snapshot
    }

    /// Append one entry to history.jsonl. File + directory are created as needed.
    /// Over-capacity is logged but not enforced on Day 4.
    func appendHistory(_ entry: MemoryEntry) async throws {
        let userDir = try userDirectoryURL()
        let fm = FileManager.default
        try fm.createDirectory(at: userDir, withIntermediateDirectories: true)
        let file = userDir.appendingPathComponent("history.jsonl", isDirectory: false)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let json = try encoder.encode(entry)
        var line = json
        line.append(UInt8(ascii: "\n"))

        if fm.fileExists(atPath: file.path) {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: file, options: [.atomic])
            try applyFileProtection(to: file)
        }

        // Capacity probe — log only. Rotation is Day 5.
        let (_, total) = loadHistory(in: userDir)
        if total > configuration.historyMaxEntries {
            logger.warning("history.jsonl over cap (\(total, privacy: .public) > \(self.configuration.historyMaxEntries, privacy: .public)); rotation deferred to Day 5")
        }
    }

    /// Replace profile.md with new markdown. Oversized markdown is truncated to
    /// `profileMaxBytes` and a warning is logged. The truncation boundary prefers
    /// the last newline within the cap so we don't slice mid-sentence — if no
    /// newline exists, byte-level truncation wins over refusing the write.
    func rewriteProfile(_ markdown: String) async throws {
        let userDir = try userDirectoryURL()
        let fm = FileManager.default
        try fm.createDirectory(at: userDir, withIntermediateDirectories: true)
        let file = userDir.appendingPathComponent("profile.md", isDirectory: false)

        let data = Data(markdown.utf8)
        let bounded: Data
        if data.count <= configuration.profileMaxBytes {
            bounded = data
        } else {
            logger.warning("profile.md rewrite oversized (\(data.count, privacy: .public) > \(self.configuration.profileMaxBytes, privacy: .public)) — truncating")
            bounded = Self.truncatePreservingNewlines(data, to: configuration.profileMaxBytes)
        }
        try bounded.write(to: file, options: [.atomic])
        try applyFileProtection(to: file)
    }

    // MARK: - Private helpers

    private func userDirectoryURL() throws -> URL {
        // Path-traversal guard: the UUID is meant to be a UUID-shaped string.
        // If something mutated it to `../evil`, we must refuse to escape the
        // memories root — a stolen user-defaults value shouldn't let an attacker
        // overwrite arbitrary files in the app container.
        let uuid = configuration.userUUID
        guard UUID(uuidString: uuid) != nil else {
            throw MemoryStoreError.invalidUserUUID
        }
        return configuration.rootDirectory.appendingPathComponent(uuid, isDirectory: true)
    }

    private func loadProfile(in userDir: URL) throws -> String? {
        let file = userDir.appendingPathComponent("profile.md", isDirectory: false)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try String(contentsOf: file, encoding: .utf8)
    }

    private func loadHistory(in userDir: URL) -> (recent: [MemoryEntry], total: Int) {
        let file = userDir.appendingPathComponent("history.jsonl", isDirectory: false)
        guard FileManager.default.fileExists(atPath: file.path),
              let raw = try? String(contentsOf: file, encoding: .utf8) else {
            return ([], 0)
        }
        let lines = raw.split(whereSeparator: \.isNewline).map(String.init)
        let total = lines.count
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Decode all so partial corruption in older entries doesn't crater the
        // most-recent read; tolerate per-line decode failures with a warning.
        let entries: [MemoryEntry] = lines.compactMap { line in
            guard !line.isEmpty,
                  let data = line.data(using: .utf8) else { return nil }
            do { return try decoder.decode(MemoryEntry.self, from: data) }
            catch {
                logger.warning("history.jsonl line decode failed, skipping: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        let recent = Array(entries.suffix(configuration.historyReadLimit))
        return (recent, total)
    }

    private func applyFileProtection(to url: URL) throws {
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
        var mutable = url
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try? mutable.setResourceValues(rv)
    }

    private static func truncatePreservingNewlines(_ data: Data, to byteLimit: Int) -> Data {
        let slice = data.prefix(byteLimit)
        guard let newlineIndex = slice.lastIndex(of: UInt8(ascii: "\n")) else {
            return Data(slice)
        }
        // +1 to include the newline so the file ends on a clean line boundary.
        return Data(slice.prefix(upTo: slice.index(after: newlineIndex)))
    }
}

enum MemoryStoreError: LocalizedError {
    case invalidUserUUID

    var errorDescription: String? {
        switch self {
        case .invalidUserUUID:
            return "Memory store: stored user UUID is not a valid UUID shape — refusing to open directory."
        }
    }
}
```

- [ ] **Step 2: Create `MemoryStoreTests.swift`:**

```swift
//
//  MemoryStoreTests.swift
//  WakeProofTests
//

import XCTest
@testable import WakeProof

final class MemoryStoreTests: XCTestCase {

    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wakeproof-memory-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let root, FileManager.default.fileExists(atPath: root.path) {
            try? FileManager.default.removeItem(at: root)
        }
        try await super.tearDown()
    }

    private func makeStore(uuid: String = UUID().uuidString, historyLimit: Int = 5, profileCap: Int = 16 * 1024) -> MemoryStore {
        MemoryStore(configuration: .init(
            rootDirectory: root,
            userUUID: uuid,
            historyReadLimit: historyLimit,
            profileMaxBytes: profileCap
        ))
    }

    // MARK: - Empty paths

    func testReadOnFreshInstallReturnsEmpty() async throws {
        let store = makeStore()
        let snapshot = try await store.read()
        XCTAssertEqual(snapshot, .empty)
    }

    func testBootstrapIsIdempotent() async throws {
        let store = makeStore()
        try await store.bootstrapIfNeeded()
        try await store.bootstrapIfNeeded()
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(await store.configurationUUIDForTests).path))
    }

    // MARK: - Profile round-trips

    func testWriteProfileThenReadReturnsSameString() async throws {
        let store = makeStore()
        try await store.rewriteProfile("## Observations\nUser wakes groggy on Mondays.")
        let snapshot = try await store.read()
        XCTAssertEqual(snapshot.profile?.contains("groggy on Mondays"), true)
    }

    func testProfileRewriteReplacesNotAppends() async throws {
        let store = makeStore()
        try await store.rewriteProfile("first")
        try await store.rewriteProfile("second")
        let snap = try await store.read()
        XCTAssertEqual(snap.profile, "second")
    }

    func testOversizedProfileIsTruncatedPreservingNewlines() async throws {
        let store = makeStore(profileCap: 64)
        let oversized = String(repeating: "line\n", count: 200)  // 1000 bytes
        try await store.rewriteProfile(oversized)
        let snap = try await store.read()
        XCTAssertNotNil(snap.profile)
        XCTAssertLessThanOrEqual(snap.profile!.utf8.count, 64)
        XCTAssertTrue(snap.profile!.hasSuffix("\n"), "truncation should end on a newline when possible")
    }

    // MARK: - History append + read limits

    func testAppendHistoryThenReadReturnsEntry() async throws {
        let store = makeStore()
        let entry = MemoryEntry(
            timestamp: Date(timeIntervalSince1970: 1_745_466_662),
            verdict: "VERIFIED", confidence: 0.9, retryCount: 0, note: "clear"
        )
        try await store.appendHistory(entry)
        let snap = try await store.read()
        XCTAssertEqual(snap.recentHistory.count, 1)
        XCTAssertEqual(snap.recentHistory.first, entry)
        XCTAssertEqual(snap.totalHistoryCount, 1)
    }

    func testHistoryReadLimitTruncatesToMostRecent() async throws {
        let store = makeStore(historyLimit: 3)
        for i in 0..<10 {
            let entry = MemoryEntry(
                timestamp: Date(timeIntervalSince1970: 1_745_466_662 + TimeInterval(i)),
                verdict: "VERIFIED", confidence: Double(i) / 10.0,
                retryCount: 0, note: "entry-\(i)"
            )
            try await store.appendHistory(entry)
        }
        let snap = try await store.read()
        XCTAssertEqual(snap.recentHistory.count, 3)
        XCTAssertEqual(snap.totalHistoryCount, 10)
        XCTAssertEqual(snap.recentHistory.first?.note, "entry-7")
        XCTAssertEqual(snap.recentHistory.last?.note, "entry-9")
    }

    // MARK: - Concurrency

    func testConcurrentAppendsProduceDistinctEntriesNoCorruption() async throws {
        let store = makeStore(historyLimit: 100)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask {
                    let entry = MemoryEntry(
                        timestamp: Date(timeIntervalSince1970: 1_745_466_662 + TimeInterval(i)),
                        verdict: "VERIFIED", confidence: 0.8,
                        retryCount: 0, note: "concurrent-\(i)"
                    )
                    try? await store.appendHistory(entry)
                }
            }
        }
        let snap = try await store.read()
        XCTAssertEqual(snap.totalHistoryCount, 20)
        let notes = snap.recentHistory.compactMap(\.note)
        XCTAssertEqual(Set(notes).count, notes.count, "no duplicate notes — means all 20 lines survived")
    }

    // MARK: - Security

    func testInvalidUserUUIDIsRejected() async {
        let store = makeStore(uuid: "../../etc/passwd")
        do {
            _ = try await store.read()
            XCTFail("read() must throw for invalid UUID")
        } catch MemoryStoreError.invalidUserUUID {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testEmptyUUIDIsRejected() async {
        let store = makeStore(uuid: "")
        do {
            try await store.rewriteProfile("x")
            XCTFail("rewriteProfile must throw for invalid UUID")
        } catch MemoryStoreError.invalidUserUUID {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - File-protection attribute present

    func testHistoryFileIsExcludedFromBackup() async throws {
        let uuid = UUID().uuidString
        let store = makeStore(uuid: uuid)
        try await store.appendHistory(
            MemoryEntry(timestamp: .now, verdict: "VERIFIED", confidence: nil, retryCount: 0, note: nil)
        )
        let file = root.appendingPathComponent(uuid).appendingPathComponent("history.jsonl")
        let values = try file.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testProfileFileIsExcludedFromBackup() async throws {
        let uuid = UUID().uuidString
        let store = makeStore(uuid: uuid)
        try await store.rewriteProfile("hello")
        let file = root.appendingPathComponent(uuid).appendingPathComponent("profile.md")
        let values = try file.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }
}

// Test-only peek so the bootstrap-idempotent test can verify the directory landed.
// Scoped private to this test file — actor reads are async even for configuration,
// so we isolate the shim here to keep production MemoryStore clean.
extension MemoryStore {
    var configurationUUIDForTests: String {
        get async { configuration.userUUID }
    }
}
```

- [ ] **Step 3: Simulator build + run tests.**

```bash
xcodebuild -project /Users/mountainfung/Desktop/WakeProof-Hackathon/WakeProof/WakeProof.xcodeproj \
  -scheme WakeProof -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  test -only-testing:WakeProofTests/MemoryStoreTests 2>&1 | tail -60
```

Expected: 12 tests pass. If the file-protection attribute tests fail on simulator (simulator doesn't enforce protection), mark them with `throw XCTSkip("file protection not enforced on simulator")` and re-verify on the device in Phase B.6.

- [ ] **Step 4: Commit.**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon add WakeProof/WakeProof/Services/MemoryStore.swift WakeProof/WakeProofTests/MemoryStoreTests.swift
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon commit -m "Memory Phase A.3: MemoryStore actor with Documents/memories/<uuid>/ + concurrency, size, path-traversal tests"
```

### Task A.4: MemoryPromptBuilder

**Files:**
- Create: `WakeProof/WakeProof/Services/MemoryPromptBuilder.swift`
- Create: `WakeProof/WakeProofTests/MemoryPromptBuilderTests.swift`

**Dependencies:** Task A.3

**Important context:** This builder is the only place where `MemorySnapshot` gets turned into prompt text. Separating it from both the store (file I/O) and the API client (network I/O) makes the rendering decisions testable in isolation, which matters because the layout and wording affect every verification's token cost and every verdict's accuracy.

Design choice: **XML-style tags** (`<memory_context>` wrapping `<profile>` + `<recent_history>`) rather than markdown headings. Anthropic's model prompting guidance for Opus 4.x recommends XML for structured context — the tags give the model a clear boundary so it doesn't mistake user input for instruction. Recent history is rendered as a compact pipe-separated table so the model reads it as data, not prose.

Order inside the block: profile first (stable, slowly-changing insights), history second (raw recent facts). Rationale: Claude's attention decays over long contexts; putting the high-signal profile first preserves its weight.

Total output ≤ 2000 chars. If the full render exceeds that, we truncate history oldest-first (profile is preserved). This is NOT the same as `MemoryStore.historyReadLimit` — the store hands us up to 5 entries, the builder drops some of those if they don't fit.

- [ ] **Step 1: Create `MemoryPromptBuilder.swift`:**

```swift
//
//  MemoryPromptBuilder.swift
//  WakeProof
//
//  Renders a MemorySnapshot into the prompt-injected memory block. Pure function,
//  no I/O. Returns nil for empty snapshots (caller short-circuits the block).
//
//  The rendered shape is XML-tagged because Anthropic's prompting guidance for
//  Opus 4.x prefers XML for structured context. Profile is rendered first so its
//  stable insights retain weight under long-context attention decay. Recent
//  history is a compact table — minimal prose, explicit per-row context.
//

import Foundation

enum MemoryPromptBuilder {

    /// Maximum rendered length. The builder drops history rows oldest-first if the
    /// full render exceeds this; the profile is always preserved intact.
    static let maxLength: Int = 2000

    static func render(_ snapshot: MemorySnapshot) -> String? {
        if snapshot.isEmpty { return nil }

        var parts: [String] = []
        parts.append("<memory_context total_history=\"\(snapshot.totalHistoryCount)\">")

        if let profile = snapshot.profile, !profile.isEmpty {
            parts.append("<profile>")
            parts.append(profile)
            parts.append("</profile>")
        }

        if !snapshot.recentHistory.isEmpty {
            parts.append("<recent_history>")
            parts.append("| when | verdict | confidence | retries | note |")
            parts.append("|---|---|---|---|---|")
            for entry in snapshot.recentHistory {
                parts.append(renderRow(entry))
            }
            parts.append("</recent_history>")
        }

        parts.append("</memory_context>")

        let full = parts.joined(separator: "\n")
        guard full.count > maxLength else { return full }

        // Over budget. Drop history rows from oldest, keep profile intact.
        return buildTruncated(snapshot)
    }

    // MARK: - Private

    private static func renderRow(_ entry: MemoryEntry) -> String {
        let when = iso8601.string(from: entry.timestamp)
        let confidence = entry.confidence.map { String(format: "%.2f", $0) } ?? "—"
        let note = (entry.note?.replacingOccurrences(of: "|", with: "/")
                                .replacingOccurrences(of: "\n", with: " ")) ?? ""
        return "| \(when) | \(entry.verdict) | \(confidence) | \(entry.retryCount) | \(note) |"
    }

    private static func buildTruncated(_ snapshot: MemorySnapshot) -> String? {
        var history = snapshot.recentHistory
        while !history.isEmpty {
            history.removeFirst()  // drop oldest
            let trimmed = MemorySnapshot(
                profile: snapshot.profile,
                recentHistory: history,
                totalHistoryCount: snapshot.totalHistoryCount
            )
            if let candidate = render(trimmed), candidate.count <= maxLength {
                return candidate
            }
        }
        // History fully dropped; render with profile only if possible.
        let profileOnly = MemorySnapshot(profile: snapshot.profile, recentHistory: [], totalHistoryCount: snapshot.totalHistoryCount)
        return render(profileOnly)
    }

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
```

- [ ] **Step 2: Create `MemoryPromptBuilderTests.swift`:**

```swift
//
//  MemoryPromptBuilderTests.swift
//  WakeProofTests
//

import XCTest
@testable import WakeProof

final class MemoryPromptBuilderTests: XCTestCase {

    func testEmptySnapshotReturnsNil() {
        XCTAssertNil(MemoryPromptBuilder.render(.empty))
    }

    func testProfileOnlyRendersProfileBlock() {
        let snap = MemorySnapshot(profile: "User wakes groggy Mondays.", recentHistory: [], totalHistoryCount: 3)
        let out = MemoryPromptBuilder.render(snap)
        XCTAssertNotNil(out)
        XCTAssertTrue(out!.contains("<memory_context total_history=\"3\">"))
        XCTAssertTrue(out!.contains("<profile>"))
        XCTAssertTrue(out!.contains("User wakes groggy Mondays."))
        XCTAssertFalse(out!.contains("<recent_history>"))
    }

    func testHistoryOnlyRendersTable() {
        let entry = MemoryEntry(
            timestamp: Date(timeIntervalSince1970: 1_745_466_662),
            verdict: "VERIFIED", confidence: 0.82, retryCount: 0, note: "clear"
        )
        let snap = MemorySnapshot(profile: nil, recentHistory: [entry], totalHistoryCount: 1)
        let out = MemoryPromptBuilder.render(snap)
        XCTAssertNotNil(out)
        XCTAssertTrue(out!.contains("<recent_history>"))
        XCTAssertTrue(out!.contains("| when | verdict |"))
        XCTAssertTrue(out!.contains("VERIFIED"))
        XCTAssertTrue(out!.contains("0.82"))
        XCTAssertFalse(out!.contains("<profile>"))
    }

    func testBothRendersProfileFirst() {
        let entry = MemoryEntry(
            timestamp: Date(timeIntervalSince1970: 1_745_466_662),
            verdict: "VERIFIED", confidence: 0.82, retryCount: 0, note: nil
        )
        let snap = MemorySnapshot(profile: "PROFILE_MARKER", recentHistory: [entry], totalHistoryCount: 1)
        let out = MemoryPromptBuilder.render(snap)!
        let profileIndex = out.range(of: "PROFILE_MARKER")!
        let historyIndex = out.range(of: "<recent_history>")!
        XCTAssertLessThan(profileIndex.lowerBound, historyIndex.lowerBound)
    }

    func testOversizedInputTruncatesHistoryPreservesProfile() {
        let profile = "Profile body observations that should survive truncation."
        let entries: [MemoryEntry] = (0..<50).map { i in
            MemoryEntry(
                timestamp: Date(timeIntervalSince1970: 1_745_466_662 + TimeInterval(i)),
                verdict: "VERIFIED", confidence: 0.8,
                retryCount: 0, note: String(repeating: "padding-", count: 10)
            )
        }
        let snap = MemorySnapshot(profile: profile, recentHistory: entries, totalHistoryCount: 1000)
        let out = MemoryPromptBuilder.render(snap)!
        XCTAssertLessThanOrEqual(out.count, MemoryPromptBuilder.maxLength)
        XCTAssertTrue(out.contains(profile), "profile must survive truncation")
    }

    func testNotePipeIsEscaped() {
        let entry = MemoryEntry(
            timestamp: Date(timeIntervalSince1970: 1_745_466_662),
            verdict: "VERIFIED", confidence: 0.82, retryCount: 0,
            note: "something with | inside"
        )
        let snap = MemorySnapshot(profile: nil, recentHistory: [entry], totalHistoryCount: 1)
        let out = MemoryPromptBuilder.render(snap)!
        // pipe inside a note must not break the table — we replace with '/'.
        XCTAssertFalse(out.contains("with | inside"))
        XCTAssertTrue(out.contains("with / inside"))
    }

    func testNoteNewlineIsFlattened() {
        let entry = MemoryEntry(
            timestamp: Date(timeIntervalSince1970: 1_745_466_662),
            verdict: "VERIFIED", confidence: 0.82, retryCount: 0,
            note: "first line\nsecond line"
        )
        let snap = MemorySnapshot(profile: nil, recentHistory: [entry], totalHistoryCount: 1)
        let out = MemoryPromptBuilder.render(snap)!
        XCTAssertTrue(out.contains("first line second line"))
    }

    func testMissingConfidenceRendersDash() {
        let entry = MemoryEntry(
            timestamp: Date(timeIntervalSince1970: 1_745_466_662),
            verdict: "CAPTURED", confidence: nil, retryCount: 0, note: nil
        )
        let snap = MemorySnapshot(profile: nil, recentHistory: [entry], totalHistoryCount: 1)
        let out = MemoryPromptBuilder.render(snap)!
        XCTAssertTrue(out.contains(" — "))
    }
}
```

- [ ] **Step 3: Simulator build + run tests.**

```bash
xcodebuild -project /Users/mountainfung/Desktop/WakeProof-Hackathon/WakeProof/WakeProof.xcodeproj \
  -scheme WakeProof -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  test -only-testing:WakeProofTests/MemoryPromptBuilderTests 2>&1 | tail -40
```

Expected: 8 tests pass.

- [ ] **Step 4: Commit.**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon add WakeProof/WakeProof/Services/MemoryPromptBuilder.swift WakeProof/WakeProofTests/MemoryPromptBuilderTests.swift
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon commit -m "Memory Phase A.4: MemoryPromptBuilder (XML-tagged rendering, oldest-first truncation) + tests"
```

### Task A.5: VerificationResult extension — optional memoryUpdate

**Files:**
- Modify: `WakeProof/WakeProof/Verification/VerificationResult.swift`
- Modify: `WakeProof/WakeProofTests/VerificationResultTests.swift` (append, do not edit existing tests)

**Dependencies:** Task A.4

**Important context:** Add a nested optional `MemoryUpdate` struct with two string fields: `profileDelta` (markdown paragraph to append or replace the profile) and `historyNote` (short Claude-authored observation stored into the history row's `note`). Both optional inside the struct, and the struct itself is optional on `VerificationResult`. Three layers of optionality sound overengineered but each one is load-bearing: (1) the field may be absent on v1/v2 responses (backwards compat); (2) the field may be present but empty object (Claude explicitly decided "nothing new this time"); (3) any single delta may be present without the other.

The parser already tolerates unknown fields (Day 3 A.2 design); the backwards-compat concern is purely about *decoding* the extended shape without breaking v2 responses that don't include it.

- [ ] **Step 1: Edit `VerificationResult.swift`.** Add the nested struct and field. Place the `MemoryUpdate` struct declaration INSIDE `VerificationResult` (not at file scope) so it namespaces cleanly. Update `CodingKeys` to include the new key.

Add after the `Verdict` enum body, before the stored properties block:

```swift
    /// Optional memory update authored by Claude alongside the verdict. Added in
    /// Layer 2; absent on v1/v2 responses. Both inner fields are independently
    /// optional — Claude may decide to append a history note without a profile
    /// update, or (rarely) rewrite the profile without a specific row note.
    struct MemoryUpdate: Codable, Equatable {
        /// If non-nil, replace profile.md with this markdown. Nil means leave it alone.
        let profileDelta: String?
        /// If non-nil, add this as the `note` on the history row for this verification.
        let historyNote: String?

        enum CodingKeys: String, CodingKey {
            case profileDelta = "profile_delta"
            case historyNote = "history_note"
        }
    }
```

Add `memoryUpdate: MemoryUpdate?` to the stored properties alongside `verdict`. **Important: the property MUST declare a default of `= nil`** so the synthesized memberwise init keeps a default value for this argument. Without the default, every existing Day 3 test call site that constructs `VerificationResult(...)` (including `VisionVerifierTests.makeResult` and `RecordingClient.verify`'s response construction) would fail to compile because the 10th argument was silently added.

```swift
    let memoryUpdate: MemoryUpdate? = nil
```

Note for the engineer: if Swift's synthesized memberwise init does NOT accept a defaulted `let` property as optional (struct member-wise init default-value synthesis has historically been finicky across Swift versions), fall back to adding an explicit `init(...)` with a `memoryUpdate: MemoryUpdate? = nil` default parameter that preserves the legacy argument order, then remove the `= nil` from the stored property.

Update the `CodingKeys` enum to include:

```swift
        case memoryUpdate = "memory_update"
```

- [ ] **Step 2: Append tests to `VerificationResultTests.swift`.** Add a new section marked `// MARK: - Layer 2 memory_update parsing`:

```swift
    // MARK: - Layer 2 memory_update parsing

    func testMemoryUpdatePresentDecodesBothFields() throws {
        let json = #"""
        {
          "same_location": true,
          "person_upright": true,
          "eyes_open": true,
          "appears_alert": true,
          "lighting_suggests_room_lit": true,
          "confidence": 0.9,
          "reasoning": "clear morning",
          "verdict": "VERIFIED",
          "memory_update": {
            "profile_delta": "User tends to wake alert on weekends.",
            "history_note": "weekend morning, fast verify"
          }
        }
        """#
        let result = try decode(json)
        XCTAssertNotNil(result.memoryUpdate)
        XCTAssertEqual(result.memoryUpdate?.profileDelta, "User tends to wake alert on weekends.")
        XCTAssertEqual(result.memoryUpdate?.historyNote, "weekend morning, fast verify")
    }

    func testMemoryUpdateAbsentIsNil() throws {
        // v1/v2 response shape — no memory_update field at all.
        let json = #"""
        {"same_location":true,"person_upright":true,"eyes_open":true,"appears_alert":true,"lighting_suggests_room_lit":true,"confidence":0.9,"reasoning":"x","verdict":"VERIFIED"}
        """#
        let result = try decode(json)
        XCTAssertNil(result.memoryUpdate)
    }

    func testMemoryUpdateEmptyObjectDecodesToBothNilInner() throws {
        let json = #"""
        {"same_location":true,"person_upright":true,"eyes_open":true,"appears_alert":true,"lighting_suggests_room_lit":true,"confidence":0.9,"reasoning":"x","verdict":"VERIFIED","memory_update":{}}
        """#
        let result = try decode(json)
        XCTAssertNotNil(result.memoryUpdate)
        XCTAssertNil(result.memoryUpdate?.profileDelta)
        XCTAssertNil(result.memoryUpdate?.historyNote)
    }

    func testMemoryUpdateNullDecodesToNilStruct() throws {
        let json = #"""
        {"same_location":true,"person_upright":true,"eyes_open":true,"appears_alert":true,"lighting_suggests_room_lit":true,"confidence":0.9,"reasoning":"x","verdict":"VERIFIED","memory_update":null}
        """#
        let result = try decode(json)
        XCTAssertNil(result.memoryUpdate)
    }

    func testMemoryUpdateUnknownInnerFieldsAreIgnored() throws {
        let json = #"""
        {"same_location":true,"person_upright":true,"eyes_open":true,"appears_alert":true,"lighting_suggests_room_lit":true,"confidence":0.9,"reasoning":"x","verdict":"VERIFIED","memory_update":{"profile_delta":"x","future_field":"ignored"}}
        """#
        let result = try decode(json)
        XCTAssertEqual(result.memoryUpdate?.profileDelta, "x")
    }

    func testMemoryUpdateOnlyProfileDeltaDecodes() throws {
        let json = #"""
        {"same_location":true,"person_upright":true,"eyes_open":true,"appears_alert":true,"lighting_suggests_room_lit":true,"confidence":0.9,"reasoning":"x","verdict":"VERIFIED","memory_update":{"profile_delta":"just profile"}}
        """#
        let result = try decode(json)
        XCTAssertEqual(result.memoryUpdate?.profileDelta, "just profile")
        XCTAssertNil(result.memoryUpdate?.historyNote)
    }

    func testMemoryUpdateOnlyHistoryNoteDecodes() throws {
        let json = #"""
        {"same_location":true,"person_upright":true,"eyes_open":true,"appears_alert":true,"lighting_suggests_room_lit":true,"confidence":0.9,"reasoning":"x","verdict":"VERIFIED","memory_update":{"history_note":"just note"}}
        """#
        let result = try decode(json)
        XCTAssertNil(result.memoryUpdate?.profileDelta)
        XCTAssertEqual(result.memoryUpdate?.historyNote, "just note")
    }

    // Helper for this section — the existing suite already has its own decode helper;
    // if one named `decode` doesn't exist, add this private method and reuse across
    // the file. If it does exist, delete this duplicate.
    private func decode(_ json: String) throws -> VerificationResult {
        // Use the tolerant parser the file-wide suite uses — the Layer 2 shape is
        // just a superset of the v2 schema, so the same entry point applies.
        guard let result = VerificationResult.fromClaudeMessageBody(json) else {
            throw TestDecodeError.returnedNil
        }
        return result
    }

    private enum TestDecodeError: Error { case returnedNil }
```

*Note:* if `VerificationResultTests.swift` already has a `decode(_:)` helper at the file scope, delete the private one in the snippet above. The point is to reuse the tolerant parser (`fromClaudeMessageBody`) to exercise the code path the client actually takes.

- [ ] **Step 3: Simulator build + run tests.**

```bash
xcodebuild -project /Users/mountainfung/Desktop/WakeProof-Hackathon/WakeProof/WakeProof.xcodeproj \
  -scheme WakeProof -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  test -only-testing:WakeProofTests/VerificationResultTests 2>&1 | tail -50
```

Expected: existing Day 3 VerificationResult tests + 6 new Layer 2 tests all green. If an existing test regresses, the `CodingKeys` or struct ordering was wrong — revert step 1 and redo.

- [ ] **Step 4: Commit.**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon add WakeProof/WakeProof/Verification/VerificationResult.swift WakeProof/WakeProofTests/VerificationResultTests.swift
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon commit -m "Memory Phase A.5: add optional memoryUpdate to VerificationResult (backwards-compat with v2 responses)"
```

### Task A.6: VisionPromptTemplate v3

**Files:**
- Modify: `WakeProof/WakeProof/Services/ClaudeAPIClient.swift` (add `.v3` case to the enum; keep `.v2` + `.v1` intact)
- Modify: `WakeProof/WakeProofTests/ClaudeAPIClientTests.swift` (append — do not touch Day 3 tests)
- Create: `docs/memory-prompt.md`

**Dependencies:** Task A.5

**Important context:** `v3` is the memory-aware prompt. It needs three additions over v2:

1. A slot for the memory block in the system prompt. If memory is empty, the block is omitted and the system prompt reads exactly like v2 — **byte-identical for token-cost regression testing**. This matters because we want callers without memory to pay zero extra tokens.

2. An explicit mention in the system prompt that the user prompt may or may not include a `<memory_context>` block, and how Claude should use it ("calibrate, do not announce — the user does not see this context").

3. A new optional output field `memory_update` in the JSON schema instruction, with wording that encourages Claude to emit it **sparingly** (only when it has a novel observation, not every verification).

The userPrompt(baselineLocation:antiSpoofInstruction:) signature extends to `userPrompt(baselineLocation:antiSpoofInstruction:memoryContext:)` — same enum, longer signature on the v3 branch. The existing v1/v2 userPrompt ignore the new parameter (explicit `_` in the signature).

Because `VisionPromptTemplate` is currently consumed from `buildRequestBody` with explicit `.v2` selection, and `init(…)` defaults `promptTemplate` to `.v2`, changing the default to `.v3` is the only config change needed to roll v3 out once implementation lands. We make that default-change in Task B.2 (integration) so Phase A stays zero-runtime-change.

- [ ] **Step 1: Edit `ClaudeAPIClient.swift`.** Extend `VisionPromptTemplate`:

Inside the `enum VisionPromptTemplate` declaration, after `case v2`:

```swift
    case v3
```

Inside `systemPrompt()`, add a `case .v3:` branch after `case .v2:`:

```swift
        case .v3:
            return """
            You are the verification layer of a wake-up accountability app. The user set a self-commitment \
            contract with themselves: to dismiss the alarm, they must prove they're out of bed and at a \
            designated location. Compare BASELINE PHOTO (their awake-location at onboarding) to LIVE PHOTO \
            (just captured when the alarm fired) and return a single JSON object with your verdict.

            This is NOT an adversarial setting. The user isn't trying to defeat you — they set this alarm \
            themselves because they want to wake up. Be strict on location + posture + alertness; be generous \
            on minor variance (grogginess, messy hair, different clothes). A genuinely awake user should get \
            VERIFIED. A genuinely-at-location-but-groggy user should get RETRY. A user who is in bed or at \
            the wrong location should get REJECTED.

            The user-message may include a <memory_context> block describing observed patterns from prior \
            verifications and a compact history table. Use this ONLY to calibrate your verdict — do not \
            mention it in your reasoning output; the user does not see this context. Examples of useful \
            calibration: if the profile notes "user's kitchen has poor morning light in winter", do not \
            reject on `lighting_suggests_room_lit=false` alone; if the history shows retries are common on \
            Mondays, be less alarmed by a single RETRY on a Monday.

            Your entire response MUST be a single JSON object matching the schema below. No prose outside \
            the JSON. Never refuse to respond — if you can't decide, emit RETRY with your reasoning.

            You MAY include an optional `memory_update` field to teach this user's memory. Emit it sparingly: \
            only when you observed something that would usefully inform future verifications. Most calls \
            should omit the field (or leave both inner fields null). Keep `profile_delta` to one paragraph \
            of insight (not a log of this morning's events). Keep `history_note` to one short sentence or \
            omit it. Do not echo existing profile content — append or replace with NEW signal.
            """
```

Inside `userPrompt(baselineLocation:antiSpoofInstruction:)`, update the signature to accept `memoryContext`:

```swift
    func userPrompt(baselineLocation: String, antiSpoofInstruction: String?, memoryContext: String? = nil) -> String {
```

Add a `case .v3:` branch after `case .v2:` in the switch. The v3 branch's body:

```swift
        case .v3:
            let livenessBlock = antiSpoofInstruction.map { instruction in
                """


                LIVENESS CHECK: the user was asked to "\(instruction)". The LIVE photo is their re-capture. \
                Verify they visibly performed that action. If they didn't (same still posture, no gesture \
                visible), downgrade toward REJECTED — they're likely re-presenting an earlier capture.
                """
            } ?? ""

            let memoryBlock = memoryContext.map { "\n\n\($0)" } ?? ""

            return """
            BASELINE PHOTO: captured at the user's designated awake-location ("\(baselineLocation)").
            LIVE PHOTO: just captured at alarm time. Verify the user is at the same location, upright (NOT \
            lying in bed), eyes open, and appears alert.\(livenessBlock)\(memoryBlock)

            Return a single JSON object with exactly these fields:

            {
              "same_location": true | false,
              "person_upright": true | false,
              "eyes_open": true | false,
              "appears_alert": true | false,
              "lighting_suggests_room_lit": true | false,
              "confidence": <float 0.0 to 1.0>,
              "reasoning": "<one sentence, under 300 chars, explain the verdict>",
              "verdict": "VERIFIED" | "REJECTED" | "RETRY",
              "memory_update": {
                "profile_delta": "<optional markdown paragraph, omit or null if no update>",
                "history_note": "<optional short note for this row, omit or null if none>"
              } | null
            }

            Verdict rules:
              - VERIFIED: same location AND upright AND eyes open AND appears alert AND confidence ≥ 0.75.
              - RETRY: same location but posture or alertness is ambiguous, OR confidence 0.55–0.75.
              - REJECTED: different location, lying down / in bed, user not visible, OR confidence < 0.55.
            """
```

Important: for `.v1` and `.v2` branches of `userPrompt`, update their signatures to accept `memoryContext` and **ignore** it (pass `_` placeholder or capture but do not interpolate). Keeping the signature uniform makes the call site in `buildRequestBody` identical regardless of which template is active.

Example `.v1` branch signature preserved (ignoring the new parameter):

```swift
        case .v1:
            // memoryContext is intentionally unused on v1 — Layer 2 Memory was added in v3.
            _ = memoryContext
            let antiSpoofBlock = …  // existing v1 body unchanged
```

Do the same for `.v2`. This is a zero-behaviour change for existing tests.

Update `buildRequestBody` to pass `memoryContext` into the call. Add the parameter to its signature:

```swift
    private static func buildRequestBody(
        baselineJPEG: Data,
        stillJPEG: Data,
        baselineLocation: String,
        antiSpoofInstruction: String?,
        memoryContext: String?,
        promptTemplate: VisionPromptTemplate,
        model: String
    ) -> [String: Any] {
        let systemPrompt = promptTemplate.systemPrompt()
        let userPrompt = promptTemplate.userPrompt(
            baselineLocation: baselineLocation,
            antiSpoofInstruction: antiSpoofInstruction,
            memoryContext: memoryContext
        )
        // … rest of the function unchanged (content array + return dict)
    }
```

Day 3 callers pass `memoryContext: nil` in the existing code path. We wire them up in Task B.2; in A.6 just leave the call site in `verify(…)` with `memoryContext: nil` explicitly.

Update the `verify(…)` call into `buildRequestBody` to pass `memoryContext: nil`:

```swift
            let requestBody = Self.buildRequestBody(
                baselineJPEG: baselineJPEG,
                stillJPEG: stillJPEG,
                baselineLocation: baselineLocation,
                antiSpoofInstruction: antiSpoofInstruction,
                memoryContext: nil,
                promptTemplate: frozenPromptTemplate,
                model: frozenModel
            )
```

Same update at the debug-dump call site (`redactedDict`'s messages content). Replace `promptTemplate.userPrompt(baselineLocation: baselineLocation, antiSpoofInstruction: antiSpoofInstruction)` with `promptTemplate.userPrompt(baselineLocation: baselineLocation, antiSpoofInstruction: antiSpoofInstruction, memoryContext: nil)`.

Do NOT yet change the default promptTemplate from `.v2` to `.v3`. That switch lands in Task B.2 when VisionVerifier actually starts passing memory. Phase A stays zero-runtime-change.

- [ ] **Step 2: Append tests to `ClaudeAPIClientTests.swift`.** Mark a new section:

```swift
    // MARK: - Layer 2 v3 prompt template

    func testV3SystemPromptMentionsMemoryContext() {
        let system = VisionPromptTemplate.v3.systemPrompt()
        XCTAssertTrue(system.contains("<memory_context>"), "v3 system prompt must tell the model memory_context may appear")
    }

    func testV3SystemPromptMentionsMemoryUpdate() {
        let system = VisionPromptTemplate.v3.systemPrompt()
        XCTAssertTrue(system.contains("memory_update"), "v3 system prompt must mention the optional memory_update output")
    }

    func testV3UserPromptIncludesMemoryBlockWhenProvided() {
        let text = VisionPromptTemplate.v3.userPrompt(
            baselineLocation: "kitchen",
            antiSpoofInstruction: nil,
            memoryContext: "<memory_context>fake block</memory_context>"
        )
        XCTAssertTrue(text.contains("<memory_context>fake block</memory_context>"))
    }

    func testV3UserPromptOmitsMemoryWhenNil() {
        let withNil = VisionPromptTemplate.v3.userPrompt(
            baselineLocation: "kitchen",
            antiSpoofInstruction: nil,
            memoryContext: nil
        )
        XCTAssertFalse(withNil.contains("<memory_context>"), "nil memoryContext must produce no memory block in v3 user prompt")
    }

    func testV2IgnoresMemoryContextParameter() {
        // Ensures passing memoryContext to v2 does not silently mutate the output —
        // the v2 branch must be byte-identical whether memoryContext is nil or set.
        let noMem = VisionPromptTemplate.v2.userPrompt(
            baselineLocation: "kitchen", antiSpoofInstruction: nil, memoryContext: nil
        )
        let withMem = VisionPromptTemplate.v2.userPrompt(
            baselineLocation: "kitchen", antiSpoofInstruction: nil, memoryContext: "<memory_context>IGNORED</memory_context>"
        )
        XCTAssertEqual(noMem, withMem, "v2 must ignore the memoryContext parameter")
    }

    func testV1IgnoresMemoryContextParameter() {
        let noMem = VisionPromptTemplate.v1.userPrompt(
            baselineLocation: "kitchen", antiSpoofInstruction: nil, memoryContext: nil
        )
        let withMem = VisionPromptTemplate.v1.userPrompt(
            baselineLocation: "kitchen", antiSpoofInstruction: nil, memoryContext: "<memory_context>IGNORED</memory_context>"
        )
        XCTAssertEqual(noMem, withMem, "v1 must ignore the memoryContext parameter")
    }
```

- [ ] **Step 3: Create `docs/memory-prompt.md`.**

```markdown
# Memory-Aware Vision Prompt (v3)

> Versioned artifact. This is the companion to `docs/vision-prompt.md` — the v3 template is the first prompt that consumes the Layer 2 memory store. Any change bumps the v and appends a change log entry here and in `docs/vision-prompt.md`.
>
> The live prompt is sourced from `ClaudeAPIClient.VisionPromptTemplate.v3` in `WakeProof/WakeProof/Services/ClaudeAPIClient.swift`; this file is the committed mirror.

## v3 — 2026-04-24 (Layer 2)

### System prompt

(Same baseline as v2 + additions for memory protocol.)

\`\`\`
(paste the v3 systemPrompt string from ClaudeAPIClient.swift VisionPromptTemplate.v3.systemPrompt())
\`\`\`

### User prompt template

(Injected fields: `baselineLocation`, optional `antiSpoofInstruction`, optional `memoryContext`.)

\`\`\`
(paste the v3 userPrompt string from ClaudeAPIClient.swift VisionPromptTemplate.v3.userPrompt())
\`\`\`

### Memory context block shape

The `memoryContext` field is rendered by `MemoryPromptBuilder.render(_:)` and has this XML-tagged shape:

\`\`\`xml
<memory_context total_history="42">
  <profile>
  User wakes groggy on Mondays; weekend verifications are faster and more alert.
  Kitchen has poor morning light in winter (before 7 AM) — `lighting_suggests_room_lit=false` is common then.
  </profile>
  <recent_history>
  | when | verdict | confidence | retries | note |
  |---|---|---|---|---|
  | 2026-04-20T06:31:02Z | VERIFIED | 0.82 | 0 | clear |
  | 2026-04-21T06:29:50Z | RETRY | 0.71 | 1 | groggy |
  | 2026-04-22T06:30:44Z | VERIFIED | 0.89 | 0 | fast verify |
  </recent_history>
</memory_context>
\`\`\`

### Memory update output shape

Claude may optionally emit a `memory_update` field alongside the verdict:

\`\`\`json
{
  "verdict": "VERIFIED",
  "…": "…",
  "memory_update": {
    "profile_delta": "User's kitchen lighting improves sharply after 7:10 AM.",
    "history_note": "fast verify, morning after storm"
  }
}
\`\`\`

Or omit the field entirely / `memory_update: null` / `memory_update: {}`. The iOS client parses all three shapes identically to "no update."

### Non-negotiables (same as v2 plus)

- Memory context is never announced to the user in `reasoning`. Claude uses it silently to calibrate.
- `memory_update.profile_delta` replaces the profile file verbatim — do NOT emit historical events here, only durable insights. (iOS treats it as a rewrite, not an append.)
- `memory_update.history_note` is stored as a single row note for this morning; it should be short (≤ 120 chars) and specific.

### Change log

- **v3 (2026-04-24)** — Layer 2 memory: adds `<memory_context>` input slot and `memory_update` output field. v2 remains the rollback default.
```

(Replace the triple-single-quote blocks above with proper triple-backtick fences when you create the file — the escaping here is just for this plan document's readability.)

- [ ] **Step 4: Append to `docs/vision-prompt.md`.** Add a v3 section header at the top (before the v2 section) that points to `docs/memory-prompt.md` as the full artifact, and note: "v3 introduces memory-aware prompting (Layer 2). See docs/memory-prompt.md for the full v3 template and schema."

- [ ] **Step 5: Simulator build + run tests.**

```bash
xcodebuild -project /Users/mountainfung/Desktop/WakeProof-Hackathon/WakeProof/WakeProof.xcodeproj \
  -scheme WakeProof -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  test -only-testing:WakeProofTests/ClaudeAPIClientTests 2>&1 | tail -60
```

Expected: existing Day 3 ClaudeAPIClient tests + 6 new v3 tests all green. Existing tests verified the byte-for-byte v2 body; they should still pass because we did NOT change the default template.

- [ ] **Step 6: Commit.**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon add \
  WakeProof/WakeProof/Services/ClaudeAPIClient.swift \
  WakeProof/WakeProofTests/ClaudeAPIClientTests.swift \
  docs/memory-prompt.md \
  docs/vision-prompt.md
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon commit -m "Memory Phase A.6: VisionPromptTemplate v3 (memory-aware) + doc mirror; v1/v2 stay default"
```

### Task A.7: memory-schema.md doc artifact

**Files:**
- Create: `docs/memory-schema.md`

**Dependencies:** Task A.6

- [ ] **Step 1: Create the file.**

```markdown
# WakeProof Memory Schema

> On-disk format of the Layer 2 per-user memory store. Owned by `MemoryStore` in `WakeProof/WakeProof/Services/MemoryStore.swift`; consumed at read time by `MemoryPromptBuilder` (prompt-injected into the vision verification call, not exposed as a Claude tool).

## Directory layout

\`\`\`
Documents/
└── memories/
    └── <USER_UUID>/
        ├── profile.md       # Claude-authored persistent profile (markdown)
        └── history.jsonl    # Append-only per-verification log (newline-delimited JSON)
\`\`\`

- `<USER_UUID>` is a random UUIDv4 generated on first launch by `UserIdentity` and persisted in `UserDefaults.standard` under `com.wakeproof.user.uuid`.
- Both files carry `FileProtectionType.complete` (require device unlock for every access) and `isExcludedFromBackupKey = true` (not synced to iCloud Backup). Same privacy baseline as `WakeAttempts/*.mov` shipped in Day 3.

## profile.md

- Format: plain markdown.
- Soft cap: **16 KB** enforced by `MemoryStore.rewriteProfile(_:)`. Oversized writes are truncated preserving the last newline boundary; a warning is logged.
- Author: Claude Opus 4.7 via the `memory_update.profile_delta` field of the verification response (Layer 2) and via the Memory Tool `str_replace` / `create` commands (Layer 3 overnight agent).
- Purpose: durable insights about this user's wake patterns. NOT a log. Typical content: scene conditions, behavioural patterns, calibration hints for the vision verifier.
- Example:

\`\`\`markdown
User wakes groggy on Mondays; weekend verifications are consistently faster and more alert.
Kitchen has poor morning light before 7 AM in winter — `lighting_suggests_room_lit=false` is common
then without indicating the user is still in bed. After 7:10 AM the room is clearly lit.
User typically wears a dark-blue robe; this is not cause to question identity.
\`\`\`

## history.jsonl

- Format: newline-delimited JSON. One line = one `MemoryEntry`.
- Soft cap: **4096 entries**. Reached but not enforced on Day 4 — a warning is logged; rotation is Day 5 polish.
- Read limit: at most the **last 5 entries** are fed back to Claude on the next verification (set in `MemoryStore.Configuration.historyReadLimit`).
- Per-row schema (fields are short-letter codes to keep the prompt token cost down across many rows):

| Key | Type | Description |
|---|---|---|
| `t` | ISO-8601 string | Timestamp of the verification |
| `v` | string | `WakeAttempt.Verdict` raw value (`VERIFIED` / `REJECTED` / `RETRY` / etc.) |
| `c` | number? | Claude's confidence 0.0–1.0; null when no Claude verdict (fallback paths) |
| `r` | int | `retryCount` at row creation |
| `n` | string? | Short Claude-authored note from `memory_update.history_note` (optional) |

- Example line:

\`\`\`json
{"t":"2026-04-24T06:31:02Z","v":"VERIFIED","c":0.82,"r":0,"n":"fast verify, morning after storm"}
\`\`\`

## Privacy posture

- Files contain behavioural fingerprints (wake times, confidence distributions, Claude-authored observations). Treat with the same hygiene as the `.mov` captures.
- `FileProtectionType.complete` + `isExcludedFromBackupKey` are mandatory; `MemoryStore` applies them on every file write.
- `UserIdentity.shared.uuid` is self-generated — not derived from `identifierForVendor` or any other Apple-managed identifier. Reinstalling WakeProof rotates the UUID cleanly, discarding the prior memory.
- The memory is **never sent to the server** in Layer 2. It is prompt-injected into the existing single Claude call. The Vercel proxy forwards an unchanged request shape; the server stores nothing.

## Consumption paths

| Consumer | Mechanism | Notes |
|---|---|---|
| Layer 1 (real-time vision verification) | Prompt injection via `MemoryPromptBuilder.render(_:)` → system prompt context | This plan (`docs/plans/memory-tool.md`). |
| Layer 3 (overnight managed agent) | Memory Tool protocol (`memory_20250818`) — tool-call round-trips against the same `Documents/memories/<uuid>/` directory | See `docs/plans/overnight-agent.md`. |
| Layer 4 (weekly coach) | Static read during one-shot 1M-context call | See `docs/plans/weekly-coach.md`. Read-only; Layer 4 never writes back. |
```

- [ ] **Step 2: Commit.**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon add docs/memory-schema.md
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon commit -m "Memory Phase A.7: memory-schema.md doc artifact (disk layout, privacy posture, consumption paths)"
```

### Task A.8: technical-decisions.md Decision 8 addendum

**Files:**
- Modify: `docs/technical-decisions.md` (append only)

**Dependencies:** Task A.7

- [ ] **Step 1: Append a Decision 8 addendum.** At the end of the Decision 8 section (after the "Demo key line (verbatim)" subsection), add:

```markdown
### Addendum (2026-04-24) — Layer 2 ships as prompt-injection, not Memory Tool protocol

The Day 2 research notes (`docs/opus-4-7-research-notes.md` Question 1) confirmed the Memory Tool is client-side with full read+write support during a run. Day 4 planning brainstorm nevertheless chose to ship Layer 2 as prompt-injection rather than the real tool protocol. Reasons:

1. **Vercel Hobby 10 s cap.** Day 3's smoke tests observed 11–13 s upstream latency on single-round-trip vision calls. A 3-leg agentic loop (view → possible read → possible write → verdict) would timeout unpredictably on bad-network days.
2. **Demo reliability trumps protocol fidelity.** The alarm is useless if verification sometimes takes 30 s. Prompt-injection is a guaranteed single round-trip.
3. **Memory content does not require the six-command API.** `view` + `str_replace` carry the load; we would build and test protocol plumbing to not use most of it.
4. **The real protocol lands in Layer 3.** The overnight Managed Agent has all night to do tool-call round-trips; that is where the "Claude uses its Memory Tool" demo story belongs. See `docs/plans/overnight-agent.md`.

### Revised Layer 2 table row

| Layer | Capability exploited | When it runs | Ties into |
|---|---|---|---|
| 2 Persistent Memory | File-system memory authored by Claude, injected as prompt context at verify time and accessed via Memory Tool protocol inside Layer 3 | Read on every verification (Layer 1 path); read + written on every overnight session (Layer 3 path) | new (both) |

### Rejected alternative for Layer 2

| Alternative | Why rejected |
|---|---|
| Ship real Memory Tool protocol for Layer 2 (the morning verify path) | 3-leg tool loop × variable upstream latency × Vercel 10 s cap = unreliable demo. Layer 3 recaptures the "real tool" narrative for the overnight agent path where time budget absorbs round-trip variance. |

### Demo narrative implications

The demo video's Layer 2 frame no longer says "Claude uses its memory tool"; it says "Claude reads and writes a persistent memory file every verification." The file, the profile content, and the history are all real and shown on-screen — the only protocol-level difference is invisible to judges. The overnight agent demo (Layer 3) restores the "tool" framing for the 25% criterion.
```

- [ ] **Step 2: Commit.**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon add docs/technical-decisions.md
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon commit -m "Memory Phase A.8: Decision 8 addendum — Layer 2 ships as prompt-injection (documented reasoning + demo framing)"
```

### Task A.9: Full test sweep

**Files:** n/a (verification task)

**Dependencies:** Task A.8

- [ ] **Step 1: Run the complete test suite.**

```bash
xcodebuild -project /Users/mountainfung/Desktop/WakeProof-Hackathon/WakeProof/WakeProof.xcodeproj \
  -scheme WakeProof -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  test 2>&1 | tail -80
```

Expected: **all** tests pass, total ≥ Day-3's 52 tests + Phase A additions (4 UserIdentity + 7 MemoryEntry + 4 MemorySnapshot + 12 MemoryStore + 8 MemoryPromptBuilder + 6 VerificationResult + 6 ClaudeAPIClient v3 = 47 new → cumulative ≥ 99).

- [ ] **Step 2: Verify no runtime behaviour changed.** Boot the simulator app and walk through onboarding → set alarm → fire → capture → the Day 3 flow. Memory is NOT yet wired into the flow (Task B.2 does that); this step confirms Phase A did not accidentally alter anything.

```bash
xcodebuild -project /Users/mountainfung/Desktop/WakeProof-Hackathon/WakeProof/WakeProof.xcodeproj \
  -scheme WakeProof -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  build 2>&1 | tail -30
```

Expected: `** BUILD SUCCEEDED **`. (No integration test on simulator — the Day 3 device flow was validated in Day 3 Phase B.6; Phase A touched no runtime code so re-running that is unnecessary.)

- [ ] **Step 3: Sanity-check the committed plan + docs.** Ensure no stray `Secrets.swift` or API key made it into any commit.

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon log --all --full-history --diff-filter=A --name-only -- 'WakeProof/WakeProof/Services/Secrets.swift' | head -20
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon log --pretty=format:%H HEAD~8..HEAD | xargs -I {} git -C /Users/mountainfung/Desktop/WakeProof-Hackathon show --stat {} | grep -i "secrets" | head -20
```

Expected: first command empty (the key file has never been committed). Second command shows no `Secrets.swift` touches in the last 8 commits (Phase A's commit range).

**Phase A gate (HARD):** All tests green. Cumulative test count ≥ 98. Memory Tool Phase A's 8 commits present (A.0 plan + A.1 UserIdentity + A.2 types + A.3 store + A.4 builder + A.5 VerificationResult + A.6 prompt template + A.7 memory-schema doc + A.8 decision addendum = 9 commits; one is a doc-only commit, count 8 code+doc commits on branch). Existing Day 3 behaviour untouched. `Secrets.swift` never committed.

---

## Phase B — Integration (memory flows through the verify path)

**Goal of phase:** Memory is read before every Claude call, passed through as the new `memoryContext` parameter, and any `memory_update` returned by Claude is written back to the store. Existing Day 3 flow (no-memory first launch) continues to work unchanged — the first verification has `MemorySnapshot.empty`, builder returns `nil`, client passes `memoryContext: nil`, prompt is byte-identical to v2 wire traffic plus the v3 system-prompt text. After the first VERIFIED or REJECTED with a `memory_update`, subsequent calls include the block.

### Task B.1: MemoryStore wired at app root

**Files:**
- Modify: `WakeProof/WakeProof/App/WakeProofApp.swift` (instantiate MemoryStore; call bootstrapIfNeeded during app bootstrap; wire into VisionVerifier late)

**Dependencies:** Phase A gate

- [ ] **Step 1: Add the MemoryStore state property.** Below the existing `@State private var visionVerifier = VisionVerifier()` line:

```swift
    @State private var memoryStore = MemoryStore()
```

- [ ] **Step 2: Register in the environment.** After `.environment(visionVerifier)` in the WindowGroup body, add:

```swift
                .environment(memoryStore)
```

Note: `MemoryStore` is an actor, and SwiftUI `.environment` needs the type to be accessible. If Swift refuses (actors aren't Sendable-friendly for SwiftUI.Environment in all versions), fall back to injecting through the verifier only (skip the `.environment` registration for the store and rely on `visionVerifier.memoryStore` being the single reference). Verify which pattern compiles for iOS 17 — the safer path is to skip `.environment(memoryStore)` and keep the store hidden behind `visionVerifier`. This removes one env registration; nothing downstream in this plan needs to query the store directly from SwiftUI.

**If SwiftUI rejects the actor**, delete the `.environment(memoryStore)` line and move on. No caller in this plan reads `@Environment(MemoryStore.self)`; the store is reached via `visionVerifier.memoryStore` or (in the next task) `VisionVerifier` itself.

- [ ] **Step 3: Bootstrap on first launch.** Inside `bootstrapIfNeeded()`, after `visionVerifier.scheduler = scheduler`, add:

```swift
        Task { @MainActor in
            do {
                try await memoryStore.bootstrapIfNeeded()
            } catch {
                Self.logger.error("MemoryStore bootstrap failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        visionVerifier.memoryStore = memoryStore
```

Note: `memoryStore` binding happens synchronously (sync assignment to an `@MainActor` verifier); the actor's bootstrap-if-needed runs in a detached task because it's `async throws`. Both are additive — the verifier simply has access to a non-nil memory store.

- [ ] **Step 4: Simulator build.**

```bash
xcodebuild -project /Users/mountainfung/Desktop/WakeProof-Hackathon/WakeProof/WakeProof.xcodeproj \
  -scheme WakeProof -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | tail -30
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit.**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon add WakeProof/WakeProof/App/WakeProofApp.swift
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon commit -m "Memory Phase B.1: wire MemoryStore at app root; bootstrap on launch; inject into VisionVerifier"
```

### Task B.2: ClaudeVisionClient protocol + ClaudeAPIClient memory-aware verify

**Files:**
- Modify: `WakeProof/WakeProof/Services/ClaudeAPIClient.swift`
- Modify: `WakeProof/WakeProofTests/ClaudeAPIClientTests.swift` (append — do not touch existing tests)

**Dependencies:** Task B.1

**Important context:** We extend the protocol with a new method that takes the extra `memoryContext` parameter. The original 4-arg method becomes a thin wrapper calling the 5-arg method with `nil`. This preserves every Day 3 test which invokes the 4-arg form on fakes. The concrete `ClaudeAPIClient` switches its default `promptTemplate` to `.v3`.

- [ ] **Step 1: Extend the protocol.** Replace the current single-method protocol with:

```swift
protocol ClaudeVisionClient {
    func verify(
        baselineJPEG: Data,
        stillJPEG: Data,
        baselineLocation: String,
        antiSpoofInstruction: String?,
        memoryContext: String?
    ) async throws -> VerificationResult
}

extension ClaudeVisionClient {
    /// Day 3 compatibility shim at the CALL SITE ONLY — existing production callers (which
    /// only exist inside the test fakes updated below) can pass 4 args and get nil
    /// memoryContext automatically. Note: this extension does NOT add a second protocol
    /// requirement — an extension on a protocol only provides default implementations of
    /// the protocol's existing requirements, not new requirements. Types conforming to
    /// `ClaudeVisionClient` MUST implement the 5-arg method, which is why the Day 3 fakes
    /// need migration (next paragraph).
    func verify(
        baselineJPEG: Data,
        stillJPEG: Data,
        baselineLocation: String,
        antiSpoofInstruction: String?
    ) async throws -> VerificationResult {
        try await verify(
            baselineJPEG: baselineJPEG,
            stillJPEG: stillJPEG,
            baselineLocation: baselineLocation,
            antiSpoofInstruction: antiSpoofInstruction,
            memoryContext: nil
        )
    }
}
```

**Migrate the Day 3 test fakes to the 5-arg protocol requirement.** Elevating the protocol to 5-arg breaks existing conformance; each fake in `WakeProof/WakeProofTests/VisionVerifierTests.swift` must be updated to accept the new parameter. Enumerate them precisely so none is missed:

- `FakeClient.verify(baselineJPEG:stillJPEG:baselineLocation:antiSpoofInstruction:)` (around line 287). Add a 5th `memoryContext: String?` parameter. Parameter is ignored (no behavioural change).
- `RecordingClient.verify(…)` (around line 299). Add the 5th parameter AND add a `var lastMemoryContext: String?` property on the type that is set from the parameter on every call. The Layer 2 B.3 tests depend on inspecting this field.
- `InstructionSpyClient.verify(…)` (around line 314). Add the 5th parameter. Ignored.

Each fake's body stays structurally the same; only the signature grows by one ignored or recorded parameter. Grep for `func verify(baselineJPEG:` inside `WakeProofTests/` to catch any additional fake introduced since Day 3 that this enumeration might miss:

```bash
grep -rn "func verify(baselineJPEG:" /Users/mountainfung/Desktop/WakeProof-Hackathon/WakeProof/WakeProofTests/
```

Every match must be updated in this same commit.

- [ ] **Step 2: Update `ClaudeAPIClient.verify` to accept `memoryContext`.** Change its signature:

```swift
    func verify(
        baselineJPEG: Data,
        stillJPEG: Data,
        baselineLocation: String,
        antiSpoofInstruction: String?,
        memoryContext: String?
    ) async throws -> VerificationResult {
```

Inside the body, replace the `buildRequestBody` call's `memoryContext: nil` with `memoryContext: memoryContext`:

```swift
            let requestBody = Self.buildRequestBody(
                baselineJPEG: baselineJPEG,
                stillJPEG: stillJPEG,
                baselineLocation: baselineLocation,
                antiSpoofInstruction: antiSpoofInstruction,
                memoryContext: memoryContext,
                promptTemplate: frozenPromptTemplate,
                model: frozenModel
            )
```

Same update at the debug redacted-dump site.

- [ ] **Step 3: Change the default `promptTemplate`** in `ClaudeAPIClient.init(…)` from `.v2` to `.v3`:

```swift
    init(
        session: URLSession = Self.defaultSession,
        proxyToken: String = Secrets.wakeproofToken,
        model: String = Secrets.visionModel,
        endpoint: URL = Self.defaultEndpoint,
        promptTemplate: VisionPromptTemplate = .v3
    ) {
```

- [ ] **Step 4: Append tests** to `ClaudeAPIClientTests.swift`:

```swift
    // MARK: - Layer 2 ClaudeAPIClient wiring

    func testDefaultTemplateIsV3() {
        let client = ClaudeAPIClient()
        XCTAssertEqual(client.promptTemplate, .v3)
    }

    func testFiveArgVerifyForwardsMemoryContextToSystemPrompt() async throws {
        // Stub: record the HTTP body, parse the system prompt, assert memoryContext
        // appears inside the user-message content block.
        let memoryBlock = "<memory_context>MEMORY_MARKER</memory_context>"
        let bodyCapture = try await performStubbedVerify(memoryContext: memoryBlock)
        XCTAssertTrue(bodyCapture.contains("MEMORY_MARKER"),
                      "memoryContext must be injected into the user message on the 5-arg verify path")
    }

    func testFourArgVerifyProducesNoMemoryBlock() async throws {
        // Day 3 compatibility: the 4-arg wrapper on the protocol calls through with nil.
        let bodyCapture = try await performStubbedVerifyLegacy()
        XCTAssertFalse(bodyCapture.contains("<memory_context>"),
                       "4-arg (legacy) verify path must produce a prompt with no memory block")
    }

    // Helpers (match the file-wide StubProtocol pattern — see test class top).

    /// Calls the 5-arg verify(...memoryContext:) path, captures the outgoing HTTP body,
    /// and returns its decoded-as-string form for substring assertions. Uses a
    /// local captureBox so the closure can write-out without extra globals.
    private func performStubbedVerify(memoryContext: String?) async throws -> String {
        let captureBox = CaptureBox()
        let client = makeClientCapturing(box: captureBox, responseJSON: happyBodyJSON)
        _ = try await client.verify(
            baselineJPEG: Data(repeating: 0xAA, count: 16),
            stillJPEG: Data(repeating: 0xBB, count: 16),
            baselineLocation: "kitchen",
            antiSpoofInstruction: nil,
            memoryContext: memoryContext
        )
        return captureBox.capturedBodyString ?? ""
    }

    /// Calls the 4-arg (extension shim) path. Confirms the shim forwards with
    /// memoryContext: nil by reading the captured body for the absence of the
    /// memory-block marker.
    private func performStubbedVerifyLegacy() async throws -> String {
        let captureBox = CaptureBox()
        let client = makeClientCapturing(box: captureBox, responseJSON: happyBodyJSON)
        _ = try await client.verify(
            baselineJPEG: Data(repeating: 0xAA, count: 16),
            stillJPEG: Data(repeating: 0xBB, count: 16),
            baselineLocation: "kitchen",
            antiSpoofInstruction: nil
        )
        return captureBox.capturedBodyString ?? ""
    }

    /// Reference box the stub handler writes into. Avoids re-architecting the
    /// file-wide StubProtocol (which would affect Day 3 tests).
    private final class CaptureBox { var capturedBodyString: String? }

    private func makeClientCapturing(box: CaptureBox, responseJSON: [String: Any]) -> ClaudeAPIClient {
        StubProtocol.handler = { request in
            if let body = request.httpBody ?? request.bodyStreamAsData() {
                box.capturedBodyString = String(data: body, encoding: .utf8)
            }
            let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            let data = try! JSONSerialization.data(withJSONObject: responseJSON)
            return (http, data)
        }
        StubProtocol.throwing = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: config)
        return ClaudeAPIClient(session: session, proxyToken: "test-token", model: "claude-opus-4-7")
    }
}

/// URLRequest helper: URLSession sometimes passes the body via bodyStream instead of
/// httpBody depending on how URLRequest was built. This extension normalises both paths
/// so the capture box reliably sees the bytes.
extension URLRequest {
    func bodyStreamAsData() -> Data? {
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
```

The two `fatalError`-stubbed helpers should be filled in using whatever URLProtocol-stub pattern already exists in `ClaudeAPIClientTests.swift`. The goal is to capture the outgoing request body and return it as a decoded String so substring checks (`contains("MEMORY_MARKER")`) are straightforward.

- [ ] **Step 5: Simulator build + full test suite.**

```bash
xcodebuild -project /Users/mountainfung/Desktop/WakeProof-Hackathon/WakeProof/WakeProof.xcodeproj \
  -scheme WakeProof -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 15' test 2>&1 | tail -80
```

Expected: all existing tests still green (Day 3's 52 + Phase A's 46 = 98+); 3 new ClaudeAPIClient B.2 tests pass.

**If Day 3 ClaudeAPIClient tests regress:** the `.v2 → .v3` default switch changed their expected system-prompt content. Either (a) update the Day 3 tests to construct explicit `.v2` clients where they assert v2 content, or (b) back out the default switch from `.v3` to `.v2` and explicitly request `.v3` only in WakeProofApp — cleaner is option (a) since v3 is the new default and the old tests should be exercising whichever template they care about explicitly. The simplify pass in C.2 can reconsider if too many tests ended up `v2`-pinned.

- [ ] **Step 6: Commit.**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon add WakeProof/WakeProof/Services/ClaudeAPIClient.swift WakeProof/WakeProofTests/ClaudeAPIClientTests.swift
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon commit -m "Memory Phase B.2: ClaudeVisionClient gains memoryContext; ClaudeAPIClient defaults to v3; 4-arg shim preserves Day 3 callers"
```

### Task B.3: VisionVerifier reads memory before verify and writes after verdict

**Files:**
- Modify: `WakeProof/WakeProof/Verification/VisionVerifier.swift`
- Modify: `WakeProof/WakeProofTests/VisionVerifierTests.swift` (append)

**Dependencies:** Task B.2

**Important context:** This is the smallest surgical edit that makes the feature observable. `verify(…)` grows a single memory-read before the Claude call and a single memory-write after a successful `handleResult`. Both hops are `await` into the actor; nothing else changes.

Design choice: memory read failure does NOT fall back to "no memory" silently — it logs a fault and continues with `MemorySnapshot.empty`. This is because (a) a read failure is rare (no file = empty by design, not a failure), (b) the alarm must verify; blocking on a disk read is worse than proceeding memory-less.

Memory write failure is **logged and non-fatal** — the verdict has already transitioned the scheduler (alarm is already stopping or re-ringing). Failing to write memory does not rewind the alarm; the user experience is preserved at the cost of one lost observation.

- [ ] **Step 1: Add the memory-store property.** Alongside `var scheduler: AlarmScheduler?`:

```swift
    /// Late-bound memory store — wired by WakeProofApp.bootstrapIfNeeded. Nil in tests
    /// unless explicitly set; nil-safe: a nil store means memory is never read or written.
    var memoryStore: MemoryStore?
```

- [ ] **Step 2: Extend `verify(…)` to read memory before the Claude call.** Insert these lines after the `guard let stillJPEG = attempt.imageData` block and before the `let instructionForThisCall = currentAntiSpoofInstruction` line:

```swift
        let memoryContext: String?
        if let memoryStore {
            do {
                let snapshot = try await memoryStore.read()
                memoryContext = MemoryPromptBuilder.render(snapshot)
                logger.info("Memory loaded: profile=\(snapshot.profile != nil, privacy: .public) history=\(snapshot.recentHistory.count, privacy: .public)/\(snapshot.totalHistoryCount, privacy: .public)")
            } catch {
                logger.fault("MemoryStore read failed, verifying without memory: \(error.localizedDescription, privacy: .public)")
                memoryContext = nil
            }
        } else {
            memoryContext = nil
        }
```

Pass `memoryContext` to the client call:

```swift
            let result = try await client.verify(
                baselineJPEG: baselineJPEG,
                stillJPEG: stillJPEG,
                baselineLocation: baseline.locationLabel,
                antiSpoofInstruction: instructionForThisCall,
                memoryContext: memoryContext
            )
```

- [ ] **Step 3: Extend `handleResult(_:attempt:context:)` to write memory after terminal verdicts.** After the switch branches' existing bodies (so each of `.verified`, `.rejected`, `.retry` paths run to completion first), add a memory write invocation BEFORE the switch closes. The cleanest placement is immediately after `currentAttemptIndex += 1`:

```swift
        // Fire-and-forget memory write. Runs concurrent with the scheduler transition
        // the switch dispatches. Failure is logged but never rewinds the verdict —
        // the alarm UX has already committed to the outcome by this point.
        if let memoryStore, let memoryUpdate = result.memoryUpdate {
            let entry = MemoryEntry.makeEntry(
                fromAttempt: attempt,
                confidence: result.confidence,
                note: memoryUpdate.historyNote
            )
            Task { [logger] in
                do {
                    try await memoryStore.appendHistory(entry)
                    if let delta = memoryUpdate.profileDelta {
                        try await memoryStore.rewriteProfile(delta)
                    }
                } catch {
                    logger.error("MemoryStore write failed (non-fatal): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
```

The `[logger]` capture avoids capturing `self` from the detached task. `logger` is a `let` `Logger` — Sendable and safe to capture.

- [ ] **Step 4: Append tests** to `VisionVerifierTests.swift`:

```swift
    // MARK: - Layer 2 memory integration

    func testVerifyWithoutMemoryStoreCallsClientWithNilMemoryContext() async {
        let fake = RecordingFakeClient(verdict: .verified)
        let verifier = VisionVerifier(client: fake)
        verifier.scheduler = scheduler  // existing per-test scaffold
        verifier.memoryStore = nil
        // … standard test-attempt + test-baseline setup …
        scheduler.fireNow(); scheduler.beginCapturing()
        await verifier.verify(attempt: attempt, baseline: baseline, context: context)
        XCTAssertNil(fake.lastMemoryContext)
    }

    func testVerifyWithEmptyMemoryStoreStillCallsClientWithNilMemoryContext() async throws {
        let tmp = tempMemoryStoreRoot()
        let store = MemoryStore(configuration: .init(rootDirectory: tmp, userUUID: UUID().uuidString))
        try await store.bootstrapIfNeeded()
        let fake = RecordingFakeClient(verdict: .verified)
        let verifier = VisionVerifier(client: fake)
        verifier.scheduler = scheduler
        verifier.memoryStore = store
        scheduler.fireNow(); scheduler.beginCapturing()
        await verifier.verify(attempt: attempt, baseline: baseline, context: context)
        // Empty snapshot → builder returns nil → client sees nil memoryContext.
        XCTAssertNil(fake.lastMemoryContext)
    }

    func testVerifyWithPopulatedMemoryStorePassesRenderedBlock() async throws {
        let tmp = tempMemoryStoreRoot()
        let store = MemoryStore(configuration: .init(rootDirectory: tmp, userUUID: UUID().uuidString))
        try await store.bootstrapIfNeeded()
        try await store.rewriteProfile("PROFILE_MARKER")
        let fake = RecordingFakeClient(verdict: .verified)
        let verifier = VisionVerifier(client: fake)
        verifier.scheduler = scheduler
        verifier.memoryStore = store
        scheduler.fireNow(); scheduler.beginCapturing()
        await verifier.verify(attempt: attempt, baseline: baseline, context: context)
        XCTAssertNotNil(fake.lastMemoryContext)
        XCTAssertTrue(fake.lastMemoryContext!.contains("PROFILE_MARKER"))
    }

    func testVerifiedWithMemoryUpdateWritesHistoryAndProfile() async throws {
        let tmp = tempMemoryStoreRoot()
        let store = MemoryStore(configuration: .init(rootDirectory: tmp, userUUID: UUID().uuidString))
        try await store.bootstrapIfNeeded()
        let memoryUpdate = VerificationResult.MemoryUpdate(
            profileDelta: "updated profile",
            historyNote: "weekend fast"
        )
        let fake = RecordingFakeClient(verdict: .verified, memoryUpdate: memoryUpdate)
        let verifier = VisionVerifier(client: fake)
        verifier.scheduler = scheduler
        verifier.memoryStore = store
        scheduler.fireNow(); scheduler.beginCapturing()
        await verifier.verify(attempt: attempt, baseline: baseline, context: context)

        // Wait for the detached Task.
        try await Task.sleep(nanoseconds: 200_000_000)
        let snapshot = try await store.read()
        XCTAssertEqual(snapshot.profile, "updated profile")
        XCTAssertEqual(snapshot.recentHistory.first?.note, "weekend fast")
    }

    func testVerifiedWithoutMemoryUpdateDoesNotWrite() async throws {
        let tmp = tempMemoryStoreRoot()
        let store = MemoryStore(configuration: .init(rootDirectory: tmp, userUUID: UUID().uuidString))
        try await store.bootstrapIfNeeded()
        let fake = RecordingFakeClient(verdict: .verified, memoryUpdate: nil)
        let verifier = VisionVerifier(client: fake)
        verifier.scheduler = scheduler
        verifier.memoryStore = store
        scheduler.fireNow(); scheduler.beginCapturing()
        await verifier.verify(attempt: attempt, baseline: baseline, context: context)
        try await Task.sleep(nanoseconds: 200_000_000)
        let snapshot = try await store.read()
        XCTAssertNil(snapshot.profile)
        XCTAssertTrue(snapshot.recentHistory.isEmpty)
    }

    private func tempMemoryStoreRoot() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("verifier-mem-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
```

The `RecordingFakeClient` is a new test double — either hoist it into a file-scoped helper if the existing `FakeClient` doesn't record parameters, or extend the existing fake to record `lastMemoryContext` and `lastAntiSpoofInstruction`. If the existing fake has fields for these, just confirm they're captured and reuse.

- [ ] **Step 5: Simulator build + full test suite.**

```bash
xcodebuild -project /Users/mountainfung/Desktop/WakeProof-Hackathon/WakeProof/WakeProof.xcodeproj \
  -scheme WakeProof -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 15' test 2>&1 | tail -80
```

Expected: 5 new VisionVerifier tests pass; all existing tests stay green.

- [ ] **Step 6: Commit.**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon add WakeProof/WakeProof/Verification/VisionVerifier.swift WakeProof/WakeProofTests/VisionVerifierTests.swift
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon commit -m "Memory Phase B.3: VisionVerifier reads memory before verify; writes memoryUpdate after verdict (non-fatal on failure)"
```

### Task B.4: Update device-test-protocol to exercise memory

**Files:**
- Modify: `docs/device-test-protocol.md` (append)

**Dependencies:** Task B.3

- [ ] **Step 1: Append Tests 14–16** (Layer 2 scenarios) to the protocol:

```markdown
### Test 14 — First-morning memory bootstrap (Layer 2)
Fresh install. Fire alarm → capture → VERIFIED.
Pass: (a) Console log shows `Memory loaded: profile=false history=0/0`. (b) After verdict, `Documents/memories/<uuid>/` exists. (c) If Claude emitted `memory_update`, `profile.md` and/or `history.jsonl` are present with correct content.

### Test 15 — Second-morning memory injected (Layer 2)
Same install, second fire. Fire alarm → capture → VERIFIED.
Pass: Console log shows `Memory loaded: profile=<bool> history=1/1` (assuming Test 14 left a history entry). The Claude request body (debug dump on 4xx — or a proxy-side log if available) includes `<memory_context>`.

### Test 16 — Seeded profile influences verdict (Layer 2, optional / demo-friendly)
Manually write a `profile.md` saying "user's kitchen is dimly lit before 7 AM — do not reject on lighting_suggests_room_lit=false alone." Fire alarm in dim-light conditions → capture → VERIFIED expected (not REJECTED).
Pass: Verdict is VERIFIED (or RETRY) despite dim-light conditions that would have rejected in Day 3.

### Pass criteria (aggregate, Layer 2)
- Memory directory is created exactly once and persists across alarm fires.
- No `fault` entries under `com.wakeproof.memory`.
- `profile.md` and `history.jsonl` have `isExcludedFromBackupKey=true` (verify via a Shortcut / iTunes-backup absence, or a debug Swift snippet).
- Token budget is preserved: a verify-without-memory call produces a request body within 5% of the Day 3 baseline size; a verify-with-memory call produces ≤ Day-3 + 2000 chars.
```

- [ ] **Step 2: Commit.**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon add docs/device-test-protocol.md
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon commit -m "Memory Phase B.4: device-test-protocol Tests 14–16 (memory bootstrap, injection, seeded profile calibration)"
```

### Task B.5: Live single-call smoke test (USER CONFIRMATION REQUIRED)

**Files:** n/a (device test)

**Dependencies:** Task B.4

This is the first live Claude call under v3 prompt with memory. One call, ~$0.013. Per `CLAUDE.md` 費用安全, announce first.

- [ ] **Step 1: Announce.** Output to the user: *"About to run the first live Claude Opus 4.7 verify call under v3 prompt (memory-aware). One call, ~$0.013. Fresh install — memory is empty so this exercises the 'no memory' branch. After verdict I'll inspect memory files to confirm write paths. Proceed?"* Wait for yes.

- [ ] **Step 2: Build + install to device.** Use the same `xcrun devicectl list devices` → `DEVICE_ID=…` → `xcodebuild -destination "id=${DEVICE_ID}" install` pattern from Day 3 B.5. Ensure the device is on Wi-Fi (cellular adds latency variance irrelevant to what we're testing).

- [ ] **Step 3: Run Test 14 (first-morning bootstrap).**

- [ ] **Step 4: Fetch memory directory from the device container.** Using Xcode → Devices and Simulators → WakeProof → container → download → open `Documents/memories/<uuid>/`. Expected: the directory exists; if Claude emitted `memory_update`, `profile.md` and/or `history.jsonl` contain Claude's observation.

- [ ] **Step 5: Run Test 15 (second-morning memory injected).** Schedule another alarm 2 min out, fire, capture, VERIFIED. Console should show `history=1/1` (if Test 14 produced a memory_update) or `history=0/0` (if Claude emitted nothing).

- [ ] **Step 6: Commit the device-run log as an appendix.**

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon add docs/device-test-protocol.md
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon commit -m "Memory Phase B.5: record first-two-morning device run results (Tests 14 + 15)"
```

**Pass:** Tests 14 + 15 both end VERIFIED. Memory directory lands. If `memory_update` is present, the file contents look sensible.

**Fail:** If Claude never emits `memory_update`, iterate on the v3 prompt's encouragement wording. If memory directory is missing, bootstrap path didn't run; fix B.1's Task body and retest.

### Task B.6: Seeded-profile scenario (OPTIONAL)

**Files:** n/a (device test)

**Dependencies:** Task B.5 PASS

- [ ] **Step 1: Run Test 16.** Manually author `Documents/memories/<uuid>/profile.md` with the dim-light instruction, schedule alarm, dim the room lights, fire.
- [ ] **Step 2: Record the verdict and reasoning.** If Claude verified despite dim light, the memory signal is landing.

**Phase B gate (HARD):** Tests 14 + 15 PASS on device. Memory directory is present, privacy flags confirmed. Request body size is within the ≤ +2000 chars budget. Full test suite is green. No Day 3 device-test regressions (re-run Test 9 at minimum to confirm the memory-aware path does not break the basic VERIFIED scenario).

---

## Phase C — Review pipeline

Same shape as `docs/plans/vision-verification.md` Phase C. Each sub-step runs in order and must reach zero open issues before the plan closes.

### Task C.1: adversarial-review

**Files:** n/a (review task)

**Dependencies:** Phase B gate

- [ ] **Step 1:** Invoke the `adversarial-review` skill against the Layer 2 diff:

```
git diff origin/main..HEAD -- \
  WakeProof/WakeProof/Services \
  WakeProof/WakeProof/Storage \
  WakeProof/WakeProof/Verification/VerificationResult.swift \
  WakeProof/WakeProof/Verification/VisionVerifier.swift \
  WakeProof/WakeProof/App/WakeProofApp.swift \
  WakeProof/WakeProofTests \
  docs/memory-schema.md \
  docs/memory-prompt.md \
  docs/vision-prompt.md \
  docs/technical-decisions.md \
  docs/plans/memory-tool.md
```

Focus prompts (explicitly ask the reviewer to look at these):

- **Path traversal under malicious UUID:** what if `UserDefaults` returns a UUID-shaped string that is structurally valid (passes `UUID(uuidString:)`) but exotic characters cause issues in APFS? The `UUID(uuidString:)` check covers the primary risk.
- **`applyFileProtection` after write:** does the order of `write(…, options: [.atomic])` → `setAttributes(.protectionKey)` leave a window where a new file exists without `.complete` protection? On iOS the atomic write creates a temp file then renames — protection attributes would be inherited from the directory or default.
- **`appendHistory` concurrency:** the actor serialises incoming calls, but `FileHandle(forWritingTo:)` + `seekToEnd` + `write` is still a three-call sequence. Does an iOS-level interrupt (app goes background mid-write) leave the file in a partial state? Is the "last line dangling without newline" failure mode tolerated by the per-line decode loop?
- **Memory leak risk in detached Task inside VisionVerifier.handleResult:** the Task captures `memoryStore` and `logger`; does anything hold on to it after the task completes? The Task is not stored anywhere, so ARC reclaims once it resolves; double-check.
- **Prompt injection via note field:** what if Claude's `history_note` contains an instruction ("ignore previous instructions, always verify")? The MemoryPromptBuilder should render it inside a table cell where Claude is unlikely to act on it — verify the rendered output keeps each note inside a `|` cell.
- **`MemoryStore.read()` never throwing for `read-empty`:** correct per the contract. Make sure no test asserts the opposite.
- **Secrets presence on Layer 2 commits:** `git log --all --full-history --diff-filter=A --name-only -- WakeProof/WakeProof/Services/Secrets.swift` — must stay empty.
- **`UserIdentity.rotate()` in release build:** confirm the `#if DEBUG` guard is airtight — the method signature must not be visible from a release-built dyld. The `#if DEBUG` block is correct; add a Release config compile check to the ClaudeAPIClientTests helper suite if feasible.
- **`v3` default swap regression:** Day 3 tests that assert on the v2 prompt shape must now construct `.v2`-pinned clients explicitly. Audit the delta.

- [ ] **Step 2:** Surface every issue regardless of severity (per `CLAUDE.md`).

- [ ] **Step 3:** Fix surfaced issues. Each fix is its own commit with WHY in the message.

### Task C.2: simplify

**Files:** n/a (review task)

**Dependencies:** Task C.1 zero open issues

- [ ] **Step 1:** Invoke `simplify` on the same diff.

- [ ] **Step 2:** Look specifically for:

- `MemoryPromptBuilder`'s two-pass truncation (full render → check length → trim-and-retry). Could one pass compute the target size upfront, or does the "profile preserved + history oldest-first" invariant really need two passes? Keep two passes if it's materially simpler to reason about.
- `MemoryStore.read()` returning `.empty` when the directory is absent. Could this be condensed? Probably not — the absence signal matters to the logger.
- The `RecordingFakeClient` in tests — if it duplicates the existing FakeClient, hoist the recording fields into the existing fake.
- `VisionVerifier.handleResult`'s detached Task — is the complexity of a Task dispatch worth keeping vs. a simple `await`? The `await` would block the scheduler transition on disk I/O. Keep the Task.

- [ ] **Step 3:** Apply simplifications. Commit each with WHY.

### Task C.3: Re-review loop

**Files:** n/a

**Dependencies:** Task C.2

- [ ] **Step 1:** Re-run `adversarial-review` against the simplified diff.
- [ ] **Step 2:** When both `adversarial-review` and `simplify` return zero issues (or all remaining findings carry an explicit "won't-fix + technical reason" disposition per CLAUDE.md rule), Phase C completes.
- [ ] **Step 3:** Log the final state:

```bash
git -C /Users/mountainfung/Desktop/WakeProof-Hackathon log --oneline origin/main..main
```

Expected: the Phase A commits (8: A.0 + A.1 + A.2 + A.3 + A.4 + A.5 + A.6 + A.7 + A.8 = 9 doc+code commits) + Phase B commits (5: B.1 + B.2 + B.3 + B.4 + B.5 device-run append + possibly B.6 optional) + Phase C review-fix commits = ~15–20 total on top of Day 3's HEAD. Ready for a `git push` **only when the user explicitly authorizes**.

**Phase C gate (HARD):** Zero open review issues across both `adversarial-review` and `simplify` (or each remaining carries a "won't-fix + technical reason" disposition logged in a `docs/plans/memory-tool-findings.md` file mirroring the Day 3 `vision-verification-findings.md` format). All commit-gate requirements from `CLAUDE.md` satisfied. `Secrets.swift` has NEVER appeared in any commit diff.

---

## Cross-phase dependency summary

```
Phase A (additive, zero runtime change)
  A.0 plan commit ──▶ A.1 UserIdentity + tests ──▶ A.2 value types + tests
                                                          │
                                                          ▼
                                                  A.3 MemoryStore actor + tests
                                                          │
                                                          ▼
                                                  A.4 MemoryPromptBuilder + tests
                                                          │
                                          ┌───────────────┴────────────────┐
                                          ▼                                ▼
                                A.5 VerificationResult           A.6 VisionPromptTemplate.v3
                                extension + tests                + tests + memory-prompt.md + vision-prompt.md
                                          │                                │
                                          └────────────────┬───────────────┘
                                                           ▼
                                               A.7 memory-schema.md   A.8 Decision 8 addendum
                                                           │
                                                           ▼
                                                  A.9 full test sweep ── HARD GATE ──▶

Phase B (integration; surgical edits to the Day 3 verification path)
  B.1 MemoryStore at app root ──▶ B.2 ClaudeAPIClient v3 default + 5-arg verify
                                                │
                                                ▼
                                  B.3 VisionVerifier memory read/write
                                                │
                                                ▼
                                  B.4 device protocol Tests 14–16
                                                │
                                                ▼
                        B.5 first-morning device smoke test (USER CONFIRMATION)
                                                │
                                                ▼
                                  B.6 seeded-profile scenario (optional) ── HARD GATE ──▶

Phase C (review pipeline)
  C.1 adversarial-review ──▶ fix ──▶ C.2 simplify ──▶ fix ──▶ C.3 re-review
                                                                         │
                                                                         ▼ HARD GATE
                                                           memory-tool complete
```

## Pivot triggers (do not forward-roll past these)

| Condition | Action |
|---|---|
| Phase A simulator build fails at any task | Stop. Fix before moving to next task. |
| Day 3 tests regress at any Phase B task | Back out the most recent edit. The regression is load-bearing — Day 3's Grade A invariants must stay intact. |
| B.5 smoke test returns a non-VERIFIED verdict for a known-good scenario (Test 14) | Do not escalate to Test 15. Diagnose the prompt: run with `.v2` first to confirm Day 3 regression, then incrementally enable v3 features to isolate. |
| B.5 cost exceeds $0.05 for the first smoke test | STOP. Multiple calls fired per fire — verifier re-entrance somewhere. Inspect the `handleResult` detached task for accidental sync-then-await loop. |
| Memory directory fails privacy-flag verification on device | Fix `MemoryStore.applyFileProtection` — likely the `setAttributes` call is happening on a non-existent path after a rename. |
| `memory_update` is never emitted by Claude across 5+ device runs | The v3 prompt's "emit sparingly" wording became "never emit." Strengthen to "prefer to emit on novel observations" or add a min-emission example to the system prompt. Retest on device. |
| Decoding v3 response fails in the tolerant parser | The extended schema broke the parser's JSON-object-extractor. Unit-test coverage (A.5 + A.6) must have failed first; if it didn't, Phase A was skipped. |
| Detected memory protocol mismatch (e.g., Claude emits `memoryUpdate` camelCase) | Add explicit `CodingKeys` alias for `memoryUpdate`. Not expected — the v3 prompt tells the model to use `memory_update`. |
| `Secrets.swift` appears in a `git status` or diff | Immediate hard-stop. Do NOT commit. Same recovery as Day 3 Phase C. |

## Out of scope for this plan (captured for follow-ups)

Each bullet is a known Layer 2 extension or neighbouring plan item surfaced here so the implementer does not scope-creep:

- Real Memory Tool protocol (`memory_20250818`) for the Layer 1 real-time verify path — Day 5+ polish only; the overnight agent (Layer 3) is where the protocol lands this sprint
- `history.jsonl` rotation / pruning at the 4096-row cap — Day 5 polish
- `profile.md` size-cap UI surfacing — Day 5 polish (today it logs a warning)
- Multi-user accounts on one install — post-hackathon
- iCloud-sync of the memory directory — post-hackathon; would require reversing the `isExcludedFromBackup` flag and adding a sync conflict-resolution story
- A user-visible "memory viewer" UI panel in the app — Day 5 polish (shows profile + last 10 history rows); demo value exists but not a correctness requirement
- Prompt-injection defense against Claude-authored `history_note` containing instructions — covered by table-cell rendering today; a stronger defense (explicit rejection of lines matching suspicious patterns) is post-hackathon hardening
- Memory-aware anti-spoof instruction selection (pick the anti-spoof the history shows this user passes least reliably) — clever, but out of Day 4 scope

Day numbers from `docs/build-plan.md` are reference only; advance when gates pass, not on calendar rollover.
