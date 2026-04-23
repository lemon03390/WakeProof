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

    /// Where verification POSTs go. Reads from `Secrets.claudeEndpoint` first so a
    /// deployed Cloudflare Worker proxy (see `workers/wakeproof-proxy/`) can bypass
    /// Cloudflare Bot Management's iOS-URLSession block. Falls back to Anthropic direct
    /// when the Secrets value is empty — useful for simulator paths where the bot-scoring
    /// isn't triggered and for any future server-to-server call site.
    private static let defaultEndpoint: URL = {
        let endpointString = Secrets.claudeEndpoint.isEmpty
            ? "https://api.anthropic.com/v1/messages"
            : Secrets.claudeEndpoint
        guard let url = URL(string: endpointString) else {
            preconditionFailure("Claude endpoint URL failed to parse: \(endpointString)")
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
        // B5 fix: image byte counts and anti-spoof instruction live inside `.private` —
        // not secrets per se, but they reveal session-specific details that sysdiagnose
        // collection would otherwise capture verbatim. Model + retry context stays public
        // so field debugging still lands useful signal without exposing per-session state.
        logger.info("Calling Claude \(model, privacy: .public) with \(baselineJPEG.count, privacy: .private)+\(stillJPEG.count, privacy: .private) bytes of image data; antiSpoof=\(antiSpoofInstruction ?? "nil", privacy: .private)")
        #if DEBUG
        // B7 fix: diagnostic probes were built for Cloudflare HKG debugging and have
        // no production purpose. In release they'd add up to 15s of ring-ceiling spend
        // to the first verify per launch while also exposing the proxy endpoint in Console.
        await Self.dumpNetworkDiagnosticsOnce(session: session, endpoint: endpoint, logger: logger)
        #endif

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
            // B5 fix: Anthropic error bodies commonly echo back request fragments including
            // base64 image bytes; response headers include session identifiers. Both go to
            // `.private` so a sysdiagnose submission doesn't ship face/location imagery
            // fragments verbatim to Apple support. Status code stays public for triage.
            let headerDump = http.allHeaderFields
                .map { "\($0.key)=\($0.value)" }
                .sorted()
                .joined(separator: " | ")
            logger.error("Claude HTTP \(http.statusCode, privacy: .public) in \(elapsed, privacy: .public)s (request_body=\(bodyBytes, privacy: .private) bytes); response headers: \(headerDump, privacy: .private); body: \(snippet, privacy: .private)")
            #if DEBUG
            // B4 fix: the debug-only body dump is behind #if DEBUG so release builds never
            // persist baseline + face photos to Documents (which is iCloud-backup-enabled
            // and not file-protected by default). Within debug, scrub the base64 image
            // payloads so a developer sharing the dump for bug triage doesn't also share
            // the user's bedroom photo. Schema shape stays intact so a curl replay still
            // exercises the JSON path — just without real image bytes.
            if let bodyData = request.httpBody,
               let docs = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
                let dumpURL = docs.appendingPathComponent("last_4xx_request.json")
                let redacted = Self.redactImageBase64(bodyData) ?? bodyData
                do {
                    try redacted.write(to: dumpURL, options: [.atomic])
                    // Mark excluded from iCloud backup even in DEBUG — developers shouldn't
                    // restore their bedroom photos from an old backup by accident.
                    var mutableDump = dumpURL
                    var rv = URLResourceValues()
                    rv.isExcludedFromBackup = true
                    try? mutableDump.setResourceValues(rv)
                    logger.error("Dumped failed request body (redacted) to \(dumpURL.path, privacy: .private)")
                } catch {
                    logger.error("Failed to dump request body: \(error.localizedDescription, privacy: .public)")
                }
            }
            #endif
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

    #if DEBUG
    /// One-shot network diagnostic: runs on the first verification call of each app
    /// launch, logs system proxy settings plus three HTTPS probe requests so we can tell
    /// which layer is broken when the Claude call fails with -1004 / 127.0.0.1 routing.
    /// Subsequent calls skip the dump to avoid log spam and probe cost.
    /// B7 fix: entire function is gated `#if DEBUG` — in release builds it does not exist
    /// and the call site at `verify()` is also gated, so first-fire verify never pays the
    /// up-to-15s probe budget or exposes endpoint/PoP info in production logs.
    private static let diagnosticsLock = OSAllocatedUnfairLock(initialState: false)
    private static func dumpNetworkDiagnosticsOnce(session: URLSession, endpoint: URL, logger: Logger) async {
        let alreadyRan = diagnosticsLock.withLock { ran -> Bool in
            if ran { return true }
            ran = true
            return false
        }
        if alreadyRan { return }

        // System proxy settings (set via Settings > Wi-Fi > Configure Proxy OR via a
        // managed configuration profile). Empty dictionary means no proxy.
        if let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] {
            let filtered = settings.filter { !($0.key as String).hasPrefix("__SCOPED__") }
            logger.info("[diag] System proxy settings: \(filtered, privacy: .private)")
        } else {
            logger.info("[diag] System proxy settings: unavailable")
        }
        logger.info("[diag] Session proxy dict: \(session.configuration.connectionProxyDictionary ?? [:], privacy: .private)")
        logger.info("[diag] Target endpoint: \(endpoint.absoluteString, privacy: .private) host=\(endpoint.host ?? "?", privacy: .private)")

        await probe(url: "https://1.1.1.1/cdn-cgi/trace", label: "cloudflare-1.1.1.1", session: session, logger: logger)
        await probe(url: "https://api.anthropic.com/", label: "anthropic-root", session: session, logger: logger)
        await probe(url: endpoint.absoluteString, label: "worker-endpoint", session: session, logger: logger, method: "HEAD")
    }

    private static func probe(url: String, label: String, session: URLSession, logger: Logger, method: String = "GET") async {
        guard let u = URL(string: url) else {
            logger.error("[diag] \(label, privacy: .public): URL didn't parse — \(url, privacy: .private)")
            return
        }
        var req = URLRequest(url: u)
        req.httpMethod = method
        req.timeoutInterval = 5
        let t0 = Date()
        do {
            let (data, response) = try await session.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let snippet = String(data: data.prefix(120), encoding: .utf8) ?? "<non-utf8>"
            logger.info("[diag] \(label, privacy: .public): HTTP \(code, privacy: .public) in \(Date().timeIntervalSince(t0), privacy: .public)s; body: \(snippet, privacy: .private)")
        } catch {
            logger.error("[diag] \(label, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// B4 fix helper: redact base64 image payloads from a serialized request body before
    /// dumping it to disk so the diagnostic artifact never contains the user's actual
    /// bedroom/face imagery. Schema shape is preserved so a `curl` replay still exercises
    /// the JSON parse path — the image fields are just null-weighted.
    fileprivate static func redactImageBase64(_ bodyData: Data) -> Data? {
        guard var obj = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              var messages = obj["messages"] as? [[String: Any]] else {
            return nil
        }
        for i in messages.indices {
            guard var content = messages[i]["content"] as? [[String: Any]] else { continue }
            for j in content.indices {
                guard content[j]["type"] as? String == "image",
                      var source = content[j]["source"] as? [String: Any],
                      let data = source["data"] as? String else { continue }
                source["data"] = "<REDACTED \(data.count)b>"
                content[j]["source"] = source
            }
            messages[i]["content"] = content
        }
        obj["messages"] = messages
        return try? JSONSerialization.data(withJSONObject: obj)
    }
    #endif

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
