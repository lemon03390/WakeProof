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
    /// B1 fix: renamed from `missingAPIKey`. The Anthropic key no longer lives on
    /// the iOS client — the proxy holds it. What we check here is the per-install
    /// shared token that authenticates this client to the proxy.
    case missingProxyToken
    case invalidURL
    case transportFailed(underlying: Error)
    case httpError(status: Int, snippet: String)
    case timeout
    case emptyResponse
    case decodingFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .missingProxyToken:
            return "Proxy token not configured. Copy Secrets.swift.example to Secrets.swift and paste your token."
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

    /// HTTP header names the client uses. One place to rename / add.
    enum Header {
        static let contentType = "Content-Type"
        static let clientToken = "x-wakeproof-token"
        static let anthropicVersion = "anthropic-version"
    }

    /// Injectable for tests — production uses `.shared`.
    let session: URLSession
    let model: String
    let endpoint: URL
    let promptTemplate: VisionPromptTemplate
    /// Per-install shared token (not the Anthropic API key — that's in the proxy env).
    /// Private so logging / debug dumps elsewhere can't accidentally surface it.
    private let proxyToken: String

    private let logger = Logger(subsystem: "com.wakeproof.verification", category: "claude")

    init(
        session: URLSession = Self.defaultSession,
        proxyToken: String = Secrets.wakeproofToken,
        model: String = Secrets.visionModel,
        endpoint: URL = Self.defaultEndpoint,
        promptTemplate: VisionPromptTemplate = .v2
    ) {
        self.session = session
        self.proxyToken = proxyToken
        self.model = model
        self.endpoint = endpoint
        self.promptTemplate = promptTemplate
    }

    /// Where verification POSTs go. Reads from `Secrets.claudeEndpoint` first so a
    /// deployed Vercel proxy (see `workers/wakeproof-proxy-vercel/`) can bypass the
    /// direct-to-Anthropic Cloudflare HKG bot rules. Falls back to Anthropic direct
    /// when the Secrets value is empty — useful for simulator paths where the
    /// bot-scoring isn't triggered.
    ///
    /// S9 fix: hostname allowlisted at launch so a Secrets.swift tamper or copy-paste
    /// mistake can't silently route verification traffic to an attacker-controlled
    /// host. If the allowlist ever grows (e.g. a staging Vercel deployment), append
    /// to `allowedEndpointSuffixes`.
    private static let allowedEndpointSuffixes: [String] = [
        ".vercel.app",
        ".aspiratcm.com",
        "api.anthropic.com",
    ]
    private static let defaultEndpoint: URL = {
        let endpointString = Secrets.claudeEndpoint.isEmpty
            ? "https://api.anthropic.com/v1/messages"
            : Secrets.claudeEndpoint
        guard let url = URL(string: endpointString), let host = url.host else {
            preconditionFailure("Claude endpoint URL failed to parse: \(endpointString)")
        }
        let hostAllowed = allowedEndpointSuffixes.contains { suffix in
            host == suffix || host.hasSuffix(suffix)
        }
        guard hostAllowed else {
            preconditionFailure("Claude endpoint host \(host) not in allowlist \(allowedEndpointSuffixes)")
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
        // The proxy token authenticates this client to our Vercel proxy; the Anthropic
        // credential itself lives in the proxy's env var and never reaches this code.
        guard proxyToken != "REPLACE_WITH_OPENSSL_RAND_HEX_32", !proxyToken.isEmpty else {
            throw ClaudeAPIError.missingProxyToken
        }

        // R4 fix: base64-encoding the 2.78 MB baseline + 45 KB still + JSONSerialization
        // of the resulting [String: Any] dictionary allocates ~3.7 MB of String and blocks
        // MainActor for 40–100 ms on older devices. Both the verifier and SwiftUI's
        // `.easeInOut(duration: 0.2)` phase-transition animation run on MainActor, so the
        // block stutters the .capturing → .verifying animation. Detach the encode work
        // to a userInitiated background task and await its value. `promptTemplate` + `model`
        // are let-properties on a struct; `buildRequestBody` is pure — safe to detach.
        let frozenPromptTemplate = promptTemplate
        let frozenModel = model
        let bodyData = try await Task.detached(priority: .userInitiated) {
            let requestBody = Self.buildRequestBody(
                baselineJPEG: baselineJPEG,
                stillJPEG: stillJPEG,
                baselineLocation: baselineLocation,
                antiSpoofInstruction: antiSpoofInstruction,
                promptTemplate: frozenPromptTemplate,
                model: frozenModel
            )
            return try JSONSerialization.data(withJSONObject: requestBody)
        }.value

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: Header.contentType)
        request.setValue(proxyToken, forHTTPHeaderField: Header.clientToken)
        request.setValue("2023-06-01", forHTTPHeaderField: Header.anthropicVersion)
        request.httpBody = bodyData

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
            // R2 fix: the Vercel / Cloudflare proxies emit JSON with
            // `{"error":{"type":"upstream_fetch_failed"|"upload_timeout"|"body_too_large"}}`
            // for proxy-side failures. Special-case those so the user sees a
            // diagnosis targeted at the actual failure layer (Anthropic unreachable
            // vs. proxy upload timing) rather than a generic HTTP 4xx/5xx message.
            // Status codes: 408/413/502 are the proxy's conventions; any status can
            // carry this shape, so we key off the JSON body's error.type.
            struct ProxyError: Decodable {
                struct Inner: Decodable { let type: String?; let message: String? }
                let error: Inner?
            }
            if let body = try? JSONDecoder().decode(ProxyError.self, from: data),
               let type = body.error?.type,
               ["upstream_fetch_failed", "upload_timeout", "body_too_large"].contains(type) {
                logger.error("Proxy-layer failure type=\(type, privacy: .public) status=\(http.statusCode, privacy: .public) in \(elapsed, privacy: .public)s")
                // Surface as transportFailed so the verifier's error handler uses the
                // "Couldn't reach Claude" user message (which is accurate — this is a
                // proxy-or-anthropic connectivity failure, not an HTTP status Claude returned).
                let proxyError = NSError(
                    domain: "WakeProofProxy",
                    code: http.statusCode,
                    userInfo: [
                        NSLocalizedDescriptionKey: body.error?.message ?? type,
                        "proxyErrorType": type,
                    ]
                )
                throw ClaudeAPIError.transportFailed(underlying: proxyError)
            }
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
            // Debug-only diagnostic dump. Release builds never persist baseline +
            // face photos to Documents (iCloud-backup-enabled + not file-protected
            // by default). In debug we build a shape-preserving redacted dict from
            // the known input sizes rather than re-parsing and mutating the real
            // 3.7 MB bodyData — cheap enough to run on every 4xx without bloat.
            if let docs = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
                let dumpURL = docs.appendingPathComponent("last_4xx_request.json")
                let redactedDict: [String: Any] = [
                    "model": model,
                    "max_tokens": 800,
                    "system": promptTemplate.systemPrompt(),
                    "messages": [[
                        "role": "user",
                        "content": [
                            ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": "<REDACTED \(baselineJPEG.count)b>"]],
                            ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": "<REDACTED \(stillJPEG.count)b>"]],
                            ["type": "text", "text": promptTemplate.userPrompt(baselineLocation: baselineLocation, antiSpoofInstruction: antiSpoofInstruction)]
                        ]
                    ]],
                    "debug_request_body_bytes": bodyBytes,
                ]
                do {
                    let redacted = try JSONSerialization.data(withJSONObject: redactedDict)
                    try redacted.write(to: dumpURL, options: [.atomic])
                    var mutableDump = dumpURL
                    var rv = URLResourceValues()
                    rv.isExcludedFromBackup = true
                    try? mutableDump.setResourceValues(rv)
                    logger.error("Dumped redacted request shape to \(dumpURL.path, privacy: .private)")
                } catch {
                    logger.error("Failed to dump redacted request: \(error.localizedDescription, privacy: .public)")
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

    /// R4 fix: moved to a nonisolated static so `Task.detached` can call it without
    /// pulling the surrounding actor context. `promptTemplate` and `model` are passed
    /// in explicitly rather than captured off `self`.
    private static func buildRequestBody(
        baselineJPEG: Data,
        stillJPEG: Data,
        baselineLocation: String,
        antiSpoofInstruction: String?,
        promptTemplate: VisionPromptTemplate,
        model: String
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
            // S8 fix: bumped 600 → 800. Measured reasoning fields hit ~400 chars;
            // JSON overhead (field names, booleans, confidence, verdict) adds ~150
            // tokens. 600 was cutting it close enough that a detailed RETRY reasoning
            // risked truncation. 800 gives ~30% headroom. Trimming the prompt itself
            // (v1 → v2) also cuts upstream latency which amortizes the small output-
            // token increase against the Vercel 10s cap.
            "max_tokens": 800,
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

        // Parallel fan-out: three independent 5-s-timeout probes used to sum up to
        // 15 s on a bad network (wasting dev-time latency every fresh launch). With
        // `async let` the whole diagnostic dump caps at the slowest probe.
        async let cloudflare: Void = probe(url: "https://1.1.1.1/cdn-cgi/trace", label: "cloudflare-1.1.1.1", session: session, logger: logger)
        async let anthropic: Void = probe(url: "https://api.anthropic.com/", label: "anthropic-root", session: session, logger: logger)
        async let worker: Void = probe(url: endpoint.absoluteString, label: "worker-endpoint", session: session, logger: logger, method: "HEAD")
        _ = await (cloudflare, anthropic, worker)
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

/// Versioned prompt template. Bumping the version requires updating
/// `docs/vision-prompt.md` in the same commit. `v2` is the current default — it
/// drops the three-method spoofing chain from v1 because WakeProof is a
/// self-commitment tool where the user is both attacker and victim, making the
/// adversarial-threat enumeration a token cost and false-positive-RETRY risk
/// without real threat-model benefit. `v1` is retained for rollback.
enum VisionPromptTemplate {
    case v1
    case v2

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
        case .v2:
            return """
            You are the verification layer of a wake-up accountability app. The user set a self-commitment \
            contract with themselves: to dismiss the alarm, they must prove they're out of bed and at a \
            designated location. Compare BASELINE PHOTO (their awake-location at onboarding) to LIVE PHOTO \
            (just captured when the alarm fired) and return a single JSON object with your verdict.

            This is NOT an adversarial setting. The user isn't trying to defeat you — they set this alarm \
            themselves because they want to wake up. Your job is to be a reliable liveness check, not a \
            security-theatre spoof detector. Be strict on location + posture + alertness; be generous on \
            minor variance (grogginess, messy hair, different clothes). A genuinely awake user should get \
            VERIFIED. A genuinely-at-location-but-groggy user should get RETRY. A user who is in bed or at \
            the wrong location should get REJECTED.

            Your entire response MUST be a single JSON object matching the schema below. No prose outside \
            the JSON. Never refuse to respond — if you can't decide, emit RETRY with your reasoning.
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
        case .v2:
            let livenessBlock = antiSpoofInstruction.map { instruction in
                """


                LIVENESS CHECK: the user was asked to "\(instruction)". The LIVE photo is their re-capture. \
                Verify they visibly performed that action. If they didn't (same still posture, no gesture \
                visible), downgrade toward REJECTED — they're likely re-presenting an earlier capture.
                """
            } ?? ""

            return """
            BASELINE PHOTO: captured at the user's designated awake-location ("\(baselineLocation)").
            LIVE PHOTO: just captured at alarm time. Verify the user is at the same location, upright (NOT \
            lying in bed), eyes open, and appears alert.\(livenessBlock)

            Return a single JSON object with exactly these fields:

            {
              "same_location": true | false,
              "person_upright": true | false,
              "eyes_open": true | false,
              "appears_alert": true | false,
              "lighting_suggests_room_lit": true | false,
              "confidence": <float 0.0 to 1.0>,
              "reasoning": "<one sentence, under 300 chars, explain the verdict>",
              "verdict": "VERIFIED" | "REJECTED" | "RETRY"
            }

            Verdict rules:
              - VERIFIED: same location AND upright AND eyes open AND appears alert AND confidence ≥ 0.75.
              - RETRY: same location but posture or alertness is ambiguous, OR confidence 0.55–0.75.
              - REJECTED: different location, lying down / in bed, user not visible, OR confidence < 0.55.
            """
        }
    }
}
