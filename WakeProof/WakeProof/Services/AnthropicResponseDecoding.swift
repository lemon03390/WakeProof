//
//  AnthropicResponseDecoding.swift
//  WakeProof
//
//  SR5 (Stage 4): one place to extract the first `text` block from an
//  Anthropic Messages API response body. ClaudeAPIClient, OvernightAgentClient,
//  and NightlySynthesisClient each had a small Codable struct + .first-text-
//  block lookup copy — small enough to look harmless, drifted enough in
//  practice that error-mapping diverged across clients (one threw
//  `.decodingFailed`, one threw `.emptyResponse`, one threw `.noAgentResponse`
//  for the identical "no text block" condition).
//
//  Rules of use:
//  - Call `firstTextBlock(from:)` with the raw response `Data`. It returns
//    the `text` string of the first `type == "text"` content block.
//  - On decode failure (malformed JSON) it throws the propagated
//    `DecodingError`. Callers wrap with their own typed error
//    (`ClaudeAPIError.decodingFailed`, `OvernightAgentError.decodingFailed`,
//    `NightlySynthesisError.decodingFailed`) so the client-specific error
//    surface stays stable.
//  - On "decoded OK but no text block found" it throws
//    `AnthropicResponseDecodingError.emptyContent`. Callers re-map to their
//    own emptiness codes (e.g. Overnight → `.noAgentResponse`,
//    ClaudeAPIClient → `.emptyResponse`).
//  - This file intentionally does NOT know about the Managed Agents
//    `agent.message` shape (which nests text blocks inside an event list).
//    `OvernightAgentClient.fetchLatestAgentMessage` uses its own decoder for
//    the outer `EventsResponse` and then calls into a shape-compatible
//    check — see that function for the event-vs-message distinction it
//    surfaces as `.noAgentResponse` vs `.agentMessageMissingTextBlock`.
//

import Foundation

enum AnthropicResponseDecoding {

    /// A single `content` block as Anthropic returns it — `type` is "text",
    /// "tool_use", etc.; `text` is populated only when `type == "text"`.
    /// Hoisted to the top level of the enum so callers that pre-decode the
    /// outer envelope (e.g. OvernightAgentClient's events-list shape) can
    /// reuse it as the element type.
    struct TextBlock: Decodable {
        let type: String
        let text: String?
    }

    /// The minimal envelope Anthropic's `/v1/messages` responses share: a
    /// top-level `content` array of typed blocks. The decoder only reads
    /// what we use here — unknown top-level fields (`id`, `role`, `model`,
    /// `stop_reason`, `usage`, etc.) are silently ignored.
    struct MessageBody: Decodable {
        let content: [TextBlock]?
    }

    /// Decode the envelope and return the first `type == "text"` block's
    /// `text` string. Throws `DecodingError` on malformed JSON; throws
    /// `.emptyContent` when the JSON parses but no text block is present
    /// (or the `text` field is nil/empty).
    ///
    /// The SharedJSON plain decoder wrapper is used — Anthropic response
    /// bodies carry no Date fields.
    static func firstTextBlock(from data: Data) throws -> String {
        let body = try SharedJSON.decodePlain(MessageBody.self, from: data)
        return try firstTextBlock(from: body.content)
    }

    /// Variant used by callers that have already decoded the outer envelope
    /// (e.g. `OvernightAgentClient.fetchLatestAgentMessage` walks an events
    /// list and then reaches in for the last `agent.message`'s content array).
    /// Returns the first `type == "text"` block's `text` string; throws
    /// `.emptyContent` when no text block is present or the text field is
    /// nil/empty.
    static func firstTextBlock(from blocks: [TextBlock]?) throws -> String {
        guard let block = blocks?.first(where: { $0.type == "text" }),
              let text = block.text,
              !text.isEmpty else {
            throw AnthropicResponseDecodingError.emptyContent
        }
        return text
    }
}

/// Internal-only distinction for "the JSON decoded fine but carried no
/// user-visible text". Callers catch + re-map to their own typed error so
/// the public error surface of each client stays stable and debuggable by
/// grep / error-message-alphabet lookups.
enum AnthropicResponseDecodingError: Error {
    case emptyContent
}
