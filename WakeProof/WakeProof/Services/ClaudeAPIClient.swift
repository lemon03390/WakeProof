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
        // Required for requests made directly from a client where the API key is embedded
        // (mobile apps, single-page JS apps). Without this, Anthropic's gateway returns
        // HTTP 403 "Request not allowed" as a policy-layer rejection. The "dangerous" in
        // the name acknowledges that the key is exposed to the client; WakeProof is a solo
        // hackathon build shipping a hackathon-specific $500-credit key, so the tradeoff is
        // acceptable — production apps would proxy through a backend instead.
        request.setValue("true", forHTTPHeaderField: "anthropic-dangerous-direct-browser-access")
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
            let snippet = String(data: data.prefix(2000), encoding: .utf8) ?? "<non-utf8>"
            let bodyBytes = request.httpBody?.count ?? -1
            // Log every response header Anthropic's gateway returned so we can spot
            // request_id / cf-ray / anti-abuse signals that our narrow header lookup misses.
            let headerDump = http.allHeaderFields
                .map { "\($0.key)=\($0.value)" }
                .sorted()
                .joined(separator: " | ")
            logger.error("Claude HTTP \(http.statusCode, privacy: .public) in \(elapsed, privacy: .public)s (request_body=\(bodyBytes, privacy: .public) bytes); response headers: \(headerDump, privacy: .public); body: \(snippet, privacy: .public)")
            // On any non-2xx, dump the exact outbound request body to Documents so we can pull
            // it via devicectl and replay via curl from the Mac. If curl with these exact bytes
            // returns 200 we know URLSession is adding something Anthropic rejects; if curl
            // also 403s we know it's content-based.
            if let bodyData = request.httpBody,
               let docs = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
                let dumpURL = docs.appendingPathComponent("last_4xx_request.json")
                do {
                    try bodyData.write(to: dumpURL, options: [.atomic])
                    logger.error("Dumped failed request body to \(dumpURL.path, privacy: .public)")
                } catch {
                    logger.error("Failed to dump request body: \(error.localizedDescription, privacy: .public)")
                }
            }
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
