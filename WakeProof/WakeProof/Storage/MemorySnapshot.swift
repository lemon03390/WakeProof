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
