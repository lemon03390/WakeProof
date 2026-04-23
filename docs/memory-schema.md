# WakeProof Memory Schema

> On-disk format of the Layer 2 per-user memory store. Owned by `MemoryStore` in `WakeProof/WakeProof/Services/MemoryStore.swift`; consumed at read time by `MemoryPromptBuilder` (prompt-injected into the vision verification call, not exposed as a Claude tool).

## Directory layout

```
Documents/
└── memories/
    └── <USER_UUID>/
        ├── profile.md       # Claude-authored persistent profile (markdown)
        └── history.jsonl    # Append-only per-verification log (newline-delimited JSON)
```

- `<USER_UUID>` is a random UUIDv4 generated on first launch by `UserIdentity` and persisted in `UserDefaults.standard` under `com.wakeproof.user.uuid`.
- Both files carry `FileProtectionType.complete` (require device unlock for every access) and `isExcludedFromBackupKey = true` (not synced to iCloud Backup). Same privacy baseline as `WakeAttempts/*.mov` shipped in Day 3.

## profile.md

- Format: plain markdown.
- Soft cap: **16 KB** enforced by `MemoryStore.rewriteProfile(_:)`. Oversized writes are truncated preserving the last newline boundary; a warning is logged.
- Author: Claude Opus 4.7 via the `memory_update.profile_delta` field of the verification response (Layer 2) and via the Memory Tool `str_replace` / `create` commands (Layer 3 overnight agent).
- Purpose: durable insights about this user's wake patterns. NOT a log. Typical content: scene conditions, behavioural patterns, calibration hints for the vision verifier.
- Example:

```markdown
User wakes groggy on Mondays; weekend verifications are consistently faster and more alert.
Kitchen has poor morning light before 7 AM in winter — `lighting_suggests_room_lit=false` is common
then without indicating the user is still in bed. After 7:10 AM the room is clearly lit.
User typically wears a dark-blue robe; this is not cause to question identity.
```

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

```json
{"t":"2026-04-24T06:31:02Z","v":"VERIFIED","c":0.82,"r":0,"n":"fast verify, morning after storm"}
```

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
