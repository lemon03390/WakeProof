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

    let sameLocation: Bool
    let personUpright: Bool
    let eyesOpen: Bool
    let appearsAlert: Bool
    let lightingSuggestsRoomLit: Bool
    let confidence: Double
    let reasoning: String
    /// Optional — v1 prompt required the model to enumerate three ruled-out spoofing
    /// methods (photo-of-photo, mannequin, deepfake). Per user product insight
    /// (2026-04-23), WakeProof is a self-commitment tool where the user is both
    /// attacker and victim — adversarial threats are theoretical. The v2 prompt
    /// drops the field to reduce token cost and false-positive RETRY rate. The
    /// decoder remains compatible with v1 responses that still include the array.
    let spoofingRuledOut: [String]?
    let verdict: Verdict
    /// Layer 2 memory-tool field. Declared without a `= nil` default so the
    /// synthesized `Decodable` conformance actually decodes it from JSON —
    /// `let = nil` would make Swift skip it entirely. The explicit `init`
    /// below gives it a default of `nil` at construction sites so existing
    /// Day 3 call sites (e.g. VisionVerifier tests) keep compiling.
    let memoryUpdate: MemoryUpdate?

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
        case memoryUpdate = "memory_update"
    }

    /// Explicit memberwise init so `memoryUpdate` can default to `nil` without
    /// breaking the synthesized `Decodable` conformance (which `let = nil`
    /// silently does — see comment on the property).
    init(
        sameLocation: Bool,
        personUpright: Bool,
        eyesOpen: Bool,
        appearsAlert: Bool,
        lightingSuggestsRoomLit: Bool,
        confidence: Double,
        reasoning: String,
        spoofingRuledOut: [String]?,
        verdict: Verdict,
        memoryUpdate: MemoryUpdate? = nil
    ) {
        self.sameLocation = sameLocation
        self.personUpright = personUpright
        self.eyesOpen = eyesOpen
        self.appearsAlert = appearsAlert
        self.lightingSuggestsRoomLit = lightingSuggestsRoomLit
        self.confidence = confidence
        self.reasoning = reasoning
        self.spoofingRuledOut = spoofingRuledOut
        self.verdict = verdict
        self.memoryUpdate = memoryUpdate
    }

    /// Extract the first JSON object from the Messages-API `content[0].text`
    /// payload. Tolerates three shapes:
    ///   1. A pure JSON object: `{ ... }`
    ///   2. A fenced block: ```json\n{ ... }\n```
    ///   3. Prose + a JSON object embedded in it.
    /// Returns `nil` if no `{ ... }` balanced substring parses as `VerificationResult`.
    ///
    /// Convenience wrapper retained for test call sites that prefer a
    /// nil-returning shape. Production code inside `ClaudeAPIClient` routes
    /// through `fromClaudeMessageBodyDetailed(_:)` so a DecodingError surfaces
    /// the specific field / context that failed decode (M3 fix).
    static func fromClaudeMessageBody(_ body: String) -> VerificationResult? {
        try? fromClaudeMessageBodyDetailed(body)
    }

    /// M3 (Wave 2.6): throwing variant. When Claude's response shape drifts
    /// (e.g. Opus renames `verdict` or omits `confidence` on a model bump),
    /// the caller gets a `DecodingError` with `.keyNotFound` / `.typeMismatch`
    /// identifying WHICH field failed, instead of a bare nil. `ClaudeAPIClient`
    /// catches this and surfaces the specific field name in logs + wraps it as
    /// `ClaudeAPIError.decodingFailed(underlying:)` for the user-facing path.
    ///
    /// Error cases:
    ///   - `VerificationParseError.noJSONObjectFound` — neither pure JSON nor
    ///     a balanced `{...}` substring was found; the body was pure prose
    ///     (e.g. Claude emitted "I can't comply" instead of a verdict).
    ///   - `VerificationParseError.invalidUTF8` — the extracted candidate
    ///     couldn't be encoded as UTF-8 (unreachable in practice because Swift
    ///     Strings are UTF-8; kept as defense-in-depth for surface stability).
    ///   - `DecodingError` — propagated verbatim from `JSONDecoder`. Callers
    ///     should log `.localizedDescription` plus the redacted body snippet.
    static func fromClaudeMessageBodyDetailed(_ body: String) throws -> VerificationResult {
        guard let candidate = extractJSONObject(from: body) else {
            throw VerificationParseError.noJSONObjectFound
        }
        guard let data = candidate.data(using: .utf8) else {
            throw VerificationParseError.invalidUTF8
        }
        return try JSONDecoder().decode(VerificationResult.self, from: data)
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

/// M3 (Wave 2.6): distinguishes "no JSON at all" and "non-UTF8" from a
/// `DecodingError` thrown by `JSONDecoder` itself. `ClaudeAPIClient` switches
/// on the thrown error: `DecodingError` carries `.keyNotFound(_, context)` /
/// `.typeMismatch(_, context)` with a `codingPath` pointing at the exact
/// field (e.g. `CodingKeys.verdict`), which we surface in log lines so a
/// field triage of a Claude shape drift can tell at a glance whether the
/// model renamed `verdict`, changed `confidence`'s type, etc.
enum VerificationParseError: LocalizedError {
    case noJSONObjectFound
    case invalidUTF8

    var errorDescription: String? {
        switch self {
        case .noJSONObjectFound:
            return "Claude's response contained no JSON object to parse."
        case .invalidUTF8:
            return "Claude's response wasn't valid UTF-8."
        }
    }
}
