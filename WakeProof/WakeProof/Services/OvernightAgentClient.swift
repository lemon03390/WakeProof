//
//  OvernightAgentClient.swift
//  WakeProof
//
//  Primary-path client for the overnight Managed Agent. Wraps the three-tier
//  resource model (agent → environment → session) plus events and termination.
//  Agent and environment IDs persist in UserDefaults across nights; sessions
//  are one-per-night.
//
//  All calls route through the Vercel wildcard proxy (/api/v1/*) — the
//  Anthropic key never reaches the device. Required beta header:
//  `managed-agents-2026-04-01`.
//
//  API shapes (confirmed by Task B.3 dry-run on 2026-04-24):
//   - POST /v1/environments: body is `{"name": "..."}` only. No runtime field.
//   - POST /v1/sessions:    body is `{"agent": <id>, "environment_id": <id>}`
//                           only. `initial_message` and `task_budget` are NOT
//                           accepted at session-create in the
//                           managed-agents-2026-04-01 beta; send the seed
//                           prompt as a follow-up user.message event.
//   - POST /v1/sessions/:id/events: body is `{"events": [{...}]}` — plural
//                           array with a single element.
//   - Session termination:  `DELETE /v1/sessions/:id` (PATCH returns 404).
//   - Session id prefix:    `sesn_...` (four-letter, not `sess_`).
//   - GET  /v1/sessions/:id/events response shape: `{"data": [...]}` top-level.
//

import Foundation
import os

enum OvernightAgentError: LocalizedError {
    case missingProxyToken
    case invalidURL
    case transportFailed(underlying: Error)
    case httpError(status: Int, snippet: String)
    case timeout
    case missingResourceID(String)
    case decodingFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .missingProxyToken: return "Overnight agent: proxy token missing."
        case .invalidURL: return "Overnight agent: invalid URL."
        case .transportFailed: return "Overnight agent: transport failed."
        case .httpError(let status, _): return "Overnight agent: HTTP \(status)."
        case .timeout: return "Overnight agent: timed out."
        case .missingResourceID(let name): return "Overnight agent: expected \(name) not found in response."
        case .decodingFailed: return "Overnight agent: response parse failed."
        }
    }
}

actor OvernightAgentClient {

    struct Handle: Codable, Equatable {
        let agentID: String
        let environmentID: String
        let sessionID: String
    }

    /// UserDefaults keys for the cached resource IDs. Exposed `static` so tests
    /// can wipe them between runs and callers can audit what's persisted.
    static let agentIDKey = "com.wakeproof.overnight.agentID"
    static let environmentIDKey = "com.wakeproof.overnight.environmentID"

    private let session: URLSession
    private let baseURL: URL
    private let proxyToken: String
    private let beta: String
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.wakeproof.overnight", category: "agent-client")

    init(
        session: URLSession = OvernightAgentClient.defaultSession,
        baseURL: URL = OvernightAgentClient.defaultBaseURL,
        proxyToken: String = Secrets.wakeproofToken,
        beta: String = "managed-agents-2026-04-01",
        defaults: UserDefaults = .standard
    ) {
        self.session = session
        self.baseURL = baseURL
        self.proxyToken = proxyToken
        self.beta = beta
        self.defaults = defaults
    }

    private static var defaultBaseURL: URL {
        // Strip the messages suffix if the Day 3 Secrets value points at it.
        let raw = Secrets.claudeEndpoint.isEmpty
            ? "https://api.anthropic.com"
            : Secrets.claudeEndpoint
        // Secrets.claudeEndpoint ends in ".../v1/messages" on Day 3; the base URL for
        // the agent client is the same host without the messages segment. Our proxy's
        // wildcard route resolves everything from /v1/* onwards.
        if let url = URL(string: raw),
           let host = url.host,
           let scheme = url.scheme,
           let derived = URL(string: "\(scheme)://\(host)") {
            return derived
        }
        // If both the configured endpoint and the fallback fail to parse, we have
        // nothing we can usefully do at runtime — crash loudly so the issue is
        // surfaced in CI / on first launch rather than later with confusing
        // .invalidURL errors from every call.
        guard let fallback = URL(string: "https://api.anthropic.com") else {
            preconditionFailure("OvernightAgentClient: hardcoded fallback URL failed to parse")
        }
        return fallback
    }

    private static var defaultSession: URLSession {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 30
        return URLSession(configuration: c)
    }

    // MARK: - Public API

    /// Ensure the agent + environment resources exist. Reuses cached IDs in
    /// UserDefaults; creates new ones on first call. Idempotent.
    func ensureAgentAndEnvironment() async throws -> (agentID: String, environmentID: String) {
        let cachedAgent = defaults.string(forKey: Self.agentIDKey)
        let cachedEnv = defaults.string(forKey: Self.environmentIDKey)
        if let a = cachedAgent, let e = cachedEnv {
            logger.info("Reusing cached agent+environment IDs agent=\(a, privacy: .public) env=\(e, privacy: .public)")
            return (a, e)
        }

        logger.info("Cached agent/environment IDs missing; creating fresh resources (cachedAgent=\(cachedAgent != nil, privacy: .public) cachedEnv=\(cachedEnv != nil, privacy: .public))")
        let agentID = try await createAgent()
        defaults.set(agentID, forKey: Self.agentIDKey)
        let envID = try await createEnvironment()
        defaults.set(envID, forKey: Self.environmentIDKey)
        logger.info("Fresh agent+environment created agent=\(agentID, privacy: .public) env=\(envID, privacy: .public)")
        return (agentID, envID)
    }

    /// Start a new session for tonight. Returns the session id + the attached
    /// agent / environment ids baked into a `Handle`.
    ///
    /// The `taskBudgetTokens` parameter is currently unused — Anthropic's
    /// Managed Agents API at `managed-agents-2026-04-01` does NOT accept
    /// `task_budget` at session-create time. Parameter kept for API-surface
    /// compatibility; will be wired up when we migrate to the full
    /// agentic-loop SDK (or when Anthropic adds it to the session-create body).
    ///
    /// After session-create succeeds we immediately post the `seedMessage` as
    /// a `user.message` event so the agent has something to react to — the
    /// same flow runtime pokes use later in the night.
    func startSession(seedMessage: String, taskBudgetTokens: Int = 128_000) async throws -> Handle {
        _ = taskBudgetTokens // intentionally unused — see doc-comment above.
        let (agentID, envID) = try await ensureAgentAndEnvironment()
        let url = baseURL.appendingPathComponent("v1/sessions")
        let body: [String: Any] = [
            "agent": agentID,
            "environment_id": envID
        ]
        let data = try await postJSON(url: url, body: body)
        struct Resp: Decodable { let id: String? }
        let parsed: Resp
        do {
            parsed = try JSONDecoder().decode(Resp.self, from: data)
        } catch {
            logger.error("startSession: response decode failed — \(error.localizedDescription, privacy: .public)")
            throw OvernightAgentError.decodingFailed(underlying: error)
        }
        guard let id = parsed.id else { throw OvernightAgentError.missingResourceID("session.id") }
        logger.info("Managed Agent session started id=\(id, privacy: .public)")

        // Send the seed message as a follow-up user.message event. Same shape
        // as runtime overnight pokes — session-create does not accept
        // initial_message in this API version.
        try await appendEvent(sessionID: id, text: seedMessage)

        return Handle(agentID: agentID, environmentID: envID, sessionID: id)
    }

    /// Append a user.message event to a live session.
    ///
    /// Request body is `{"events": [{...}]}` — the plural `events` key takes
    /// an array of event objects. We send one event per call.
    func appendEvent(sessionID: String, text: String) async throws {
        let url = baseURL.appendingPathComponent("v1/sessions/\(sessionID)/events")
        let body: [String: Any] = [
            "events": [
                [
                    "type": "user.message",
                    "content": [["type": "text", "text": text]]
                ]
            ]
        ]
        _ = try await postJSON(url: url, body: body)
        logger.info("Appended event to session \(sessionID, privacy: .public) (bytes=\(text.utf8.count, privacy: .public))")
    }

    /// Fetch events and return the latest agent.message content (if any).
    ///
    /// Response shape is `{"data": [<event>, ...]}` — the top-level key is
    /// `data`, not `events`. Each event has `type`, and `agent.message`
    /// events carry `content: [{"type": "text", "text": "..."}]`.
    func fetchLatestAgentMessage(sessionID: String) async throws -> String? {
        let url = baseURL.appendingPathComponent("v1/sessions/\(sessionID)/events")
        let data = try await getJSON(url: url)
        struct EventsResponse: Decodable {
            struct Event: Decodable {
                struct Block: Decodable { let type: String; let text: String? }
                let type: String
                let content: [Block]?
            }
            let data: [Event]?
        }
        let parsed: EventsResponse
        do {
            parsed = try JSONDecoder().decode(EventsResponse.self, from: data)
        } catch {
            logger.error("fetchLatestAgentMessage: decode failed — \(error.localizedDescription, privacy: .public)")
            throw OvernightAgentError.decodingFailed(underlying: error)
        }
        let agentMessages = parsed.data?.filter { $0.type == "agent.message" } ?? []
        let lastText = agentMessages.last?.content?.first(where: { $0.type == "text" })?.text
        logger.info("fetchLatestAgentMessage session=\(sessionID, privacy: .public) foundAgentMessages=\(agentMessages.count, privacy: .public) lastTextBytes=\(lastText?.utf8.count ?? 0, privacy: .public)")
        return lastText
    }

    /// Terminate the session so its running-time billing stops accruing.
    /// Uses `DELETE /v1/sessions/:id` — confirmed by Task B.3 dry-run as the
    /// only supported termination path (PATCH returns 404). Response body is
    /// `{"id": "sesn_...", "type": "session_deleted"}` which we do not need
    /// to parse.
    func terminateSession(sessionID: String) async throws {
        let url = baseURL.appendingPathComponent("v1/sessions/\(sessionID)")
        _ = try await jsonRequest(url: url, method: "DELETE", body: nil)
        logger.info("Session \(sessionID, privacy: .public) deleted")
    }

    // MARK: - Private helpers

    private func createAgent() async throws -> String {
        let url = baseURL.appendingPathComponent("v1/agents")
        let body: [String: Any] = [
            "name": "wakeproof-overnight",
            "model": Secrets.visionModel,  // Opus 4.7 — same model as the vision call
            "system": Self.agentSystemPrompt()
        ]
        let data = try await postJSON(url: url, body: body)
        struct Resp: Decodable { let id: String? }
        let parsed: Resp
        do {
            parsed = try JSONDecoder().decode(Resp.self, from: data)
        } catch {
            logger.error("createAgent: decode failed — \(error.localizedDescription, privacy: .public)")
            throw OvernightAgentError.decodingFailed(underlying: error)
        }
        guard let id = parsed.id else { throw OvernightAgentError.missingResourceID("agent.id") }
        return id
    }

    private func createEnvironment() async throws -> String {
        let url = baseURL.appendingPathComponent("v1/environments")
        // Managed Agents API at managed-agents-2026-04-01 does NOT accept a
        // `runtime` field — environments default to cloud Python-capable.
        let body: [String: Any] = [
            "name": "wakeproof-env-v1"
        ]
        let data = try await postJSON(url: url, body: body)
        struct Resp: Decodable { let id: String? }
        let parsed: Resp
        do {
            parsed = try JSONDecoder().decode(Resp.self, from: data)
        } catch {
            logger.error("createEnvironment: decode failed — \(error.localizedDescription, privacy: .public)")
            throw OvernightAgentError.decodingFailed(underlying: error)
        }
        guard let id = parsed.id else { throw OvernightAgentError.missingResourceID("environment.id") }
        return id
    }

    private static func agentSystemPrompt() -> String {
        """
        You are the overnight analyst of WakeProof, a wake-up accountability app. Over the course of \
        one night, you ingest sleep + heart-rate data the iOS client sends as user.message events. You \
        are also given a `memory_profile` markdown block describing observed patterns from prior \
        wake-ups. Your task: produce a short morning briefing (3–5 sentences, plain prose, no markdown) \
        the user will read right after they prove they're awake tomorrow.

        Use the Python environment to write scratch notes to /tmp/notes/ as you reason. Do not echo \
        environment contents back in your final message — the user only sees the briefing.

        Your FINAL message must have this shape on the agent.message content:

          BRIEFING: <3–5 sentences of prose>
          MEMORY_UPDATE: <optional updated profile markdown, or "NONE">

        Rules:
          - Warm, specific, concise. No platitudes. No medical speculation.
          - If sleep data is missing, say so briefly in BRIEFING, do not invent numbers.
          - MEMORY_UPDATE is only for durable insights ("user's Monday mornings are harder than weekends"), \
            not a log of this night's events. Output NONE if nothing new.
        """
    }

    private func postJSON(url: URL, body: [String: Any]) async throws -> Data {
        try await jsonRequest(url: url, method: "POST", body: body)
    }

    private func getJSON(url: URL) async throws -> Data {
        try await jsonRequest(url: url, method: "GET", body: nil)
    }

    private func jsonRequest(url: URL, method: String, body: [String: Any]?) async throws -> Data {
        guard !proxyToken.isEmpty, proxyToken != "REPLACE_WITH_OPENSSL_RAND_HEX_32" else {
            logger.error("\(method, privacy: .public) \(url.path, privacy: .public): proxy token missing")
            throw OvernightAgentError.missingProxyToken
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(proxyToken, forHTTPHeaderField: "x-wakeproof-token")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue(beta, forHTTPHeaderField: "anthropic-beta")
        let bodyBytes: Int
        if let body {
            do {
                let data = try JSONSerialization.data(withJSONObject: body)
                request.httpBody = data
                bodyBytes = data.count
            } catch {
                logger.error("\(method, privacy: .public) \(url.path, privacy: .public): body serialise failed — \(error.localizedDescription, privacy: .public)")
                throw OvernightAgentError.decodingFailed(underlying: error)
            }
        } else {
            bodyBytes = 0
        }

        let start = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            logger.error("\(method, privacy: .public) \(url.path, privacy: .public) timed out after \(Date().timeIntervalSince(start), privacy: .public)s")
            throw OvernightAgentError.timeout
        } catch {
            logger.error("\(method, privacy: .public) \(url.path, privacy: .public) transport failure: \(error.localizedDescription, privacy: .public)")
            throw OvernightAgentError.transportFailed(underlying: error)
        }
        let elapsed = Date().timeIntervalSince(start)
        guard let http = response as? HTTPURLResponse else {
            logger.error("\(method, privacy: .public) \(url.path, privacy: .public): non-HTTP response after \(elapsed, privacy: .public)s")
            throw OvernightAgentError.decodingFailed(underlying: OvernightAgentError.invalidURL)
        }
        guard (200..<300).contains(http.statusCode) else {
            let snippet = String(data: data.prefix(500), encoding: .utf8) ?? "<non-utf8>"
            logger.error("\(method, privacy: .public) \(url.path, privacy: .public) → HTTP \(http.statusCode, privacy: .public) in \(elapsed, privacy: .public)s bodyBytes=\(bodyBytes, privacy: .public); snippet=\(snippet, privacy: .private)")
            throw OvernightAgentError.httpError(status: http.statusCode, snippet: snippet)
        }
        logger.info("\(method, privacy: .public) \(url.path, privacy: .public) → HTTP \(http.statusCode, privacy: .public) in \(elapsed, privacy: .public)s bodyBytes=\(bodyBytes, privacy: .public) respBytes=\(data.count, privacy: .public)")
        return data
    }
}
