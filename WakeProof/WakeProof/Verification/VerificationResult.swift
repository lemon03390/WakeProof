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
    /// Optional — v1 prompt required the model to enumerate three ruled-out spoofing
    /// methods (photo-of-photo, mannequin, deepfake). Per user product insight
    /// (2026-04-23), WakeProof is a self-commitment tool where the user is both
    /// attacker and victim — adversarial threats are theoretical. The v2 prompt
    /// drops the field to reduce token cost and false-positive RETRY rate. The
    /// decoder remains compatible with v1 responses that still include the array.
    let spoofingRuledOut: [String]?
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
