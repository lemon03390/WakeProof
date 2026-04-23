//
//  NightlySynthesisClient.swift
//  WakeProof
//
//  Fallback-path client for the nightly synthesis call. Calls the existing
//  /v1/messages route (via Vercel proxy) with the NightlyPromptTemplate.v1
//  prompt. Returns the briefing text. Chosen on the BGProcessingTask path
//  when Managed Agents onboarding did not land in Phase B's decision gate.
//

import Foundation
import os

enum NightlySynthesisError: LocalizedError {
    case missingProxyToken
    case invalidURL
    case transportFailed(underlying: Error)
    case httpError(status: Int, snippet: String)
    case timeout
    case emptyResponse
    case decodingFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .missingProxyToken: return "Nightly synthesis: proxy token missing."
        case .invalidURL: return "Nightly synthesis: could not build URL."
        case .transportFailed: return "Nightly synthesis: network error."
        case .httpError(let status, _): return "Nightly synthesis: HTTP \(status)."
        case .timeout: return "Nightly synthesis: timed out."
        case .emptyResponse: return "Nightly synthesis: empty response."
        case .decodingFailed: return "Nightly synthesis: response parse failed."
        }
    }
}

struct NightlySynthesisClient {

    let session: URLSession
    let endpoint: URL
    let model: String
    private let proxyToken: String
    private let logger = Logger(subsystem: "com.wakeproof.overnight", category: "nightly-synthesis")

    init(
        session: URLSession = Self.defaultSession,
        endpoint: URL = Self.defaultMessagesEndpoint,
        model: String = Secrets.textModel,
        proxyToken: String = Secrets.wakeproofToken
    ) {
        self.session = session
        self.endpoint = endpoint
        self.model = model
        self.proxyToken = proxyToken
    }

    private static var defaultMessagesEndpoint: URL {
        // Reuse the Day 3 messages.js endpoint. `Secrets.claudeEndpoint` is the
        // full messages URL (the proxy already publishes `.../v1/messages`).
        let base = Secrets.claudeEndpoint.isEmpty
            ? "https://api.anthropic.com/v1/messages"
            : Secrets.claudeEndpoint
        guard let url = URL(string: base) else {
            preconditionFailure("Nightly synthesis endpoint URL failed to parse: \(base)")
        }
        return url
    }

    private static var defaultSession: URLSession {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 30
        return URLSession(configuration: c)
    }

    func synthesize(
        sleep: SleepSnapshot,
        memoryProfile: String?,
        priorBriefings: [String]
    ) async throws -> String {
        guard !proxyToken.isEmpty, proxyToken != "REPLACE_WITH_OPENSSL_RAND_HEX_32" else {
            logger.error("Nightly synthesis aborted: proxy token missing or placeholder")
            throw NightlySynthesisError.missingProxyToken
        }

        let template = NightlyPromptTemplate.v1
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 500,
            "system": template.systemPrompt(),
            "messages": [[
                "role": "user",
                "content": [[
                    "type": "text",
                    "text": template.userPrompt(
                        sleep: sleep,
                        memoryProfile: memoryProfile,
                        priorBriefings: priorBriefings
                    )
                ]]
            ]]
        ]

        let bodyData: Data
        do {
            bodyData = try JSONSerialization.data(withJSONObject: body)
        } catch {
            logger.error("Nightly synthesis: failed to serialise body — \(error.localizedDescription, privacy: .public)")
            throw NightlySynthesisError.decodingFailed(underlying: error)
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(proxyToken, forHTTPHeaderField: "x-wakeproof-token")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = bodyData

        logger.info("Nightly synthesis: model=\(self.model, privacy: .public) memory=\(memoryProfile != nil, privacy: .public) priorCount=\(priorBriefings.count, privacy: .public)")
        let start = Date()

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            logger.error("Nightly synthesis timed out after \(Date().timeIntervalSince(start), privacy: .public)s")
            throw NightlySynthesisError.timeout
        } catch {
            logger.error("Nightly synthesis transport failure: \(error.localizedDescription, privacy: .public)")
            throw NightlySynthesisError.transportFailed(underlying: error)
        }
        let elapsed = Date().timeIntervalSince(start)

        guard let http = response as? HTTPURLResponse else {
            logger.error("Nightly synthesis: non-HTTP response after \(elapsed, privacy: .public)s")
            throw NightlySynthesisError.emptyResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let snippet = String(data: data.prefix(500), encoding: .utf8) ?? "<non-utf8>"
            logger.error("Nightly synthesis HTTP \(http.statusCode, privacy: .public) in \(elapsed, privacy: .public)s; snippet=\(snippet, privacy: .private)")
            throw NightlySynthesisError.httpError(status: http.statusCode, snippet: snippet)
        }

        struct Body: Decodable {
            struct Block: Decodable { let type: String; let text: String? }
            let content: [Block]?
        }
        let parsed: Body
        do {
            parsed = try JSONDecoder().decode(Body.self, from: data)
        } catch {
            logger.error("Nightly synthesis: response body decode failed — \(error.localizedDescription, privacy: .public)")
            throw NightlySynthesisError.decodingFailed(underlying: error)
        }
        guard let text = parsed.content?.first(where: { $0.type == "text" })?.text, !text.isEmpty else {
            logger.error("Nightly synthesis: no text block in content array")
            throw NightlySynthesisError.emptyResponse
        }

        logger.info("Nightly synthesis OK in \(elapsed, privacy: .public)s, response \(text.count, privacy: .public) chars")
        return text
    }
}
