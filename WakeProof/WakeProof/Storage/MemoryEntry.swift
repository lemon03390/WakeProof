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

    @available(*, deprecated, message: "Do not use in production. Reads attempt.verdict which is still 'CAPTURED' at memory-write time. Construct MemoryEntry with explicit values from VerificationResult. See VisionVerifier.swift handleResult comment for the C1-bug rationale.")
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
