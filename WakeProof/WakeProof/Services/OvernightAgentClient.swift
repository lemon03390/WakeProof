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
    /// B5.3 fix: parseAgentReply found the BRIEFING: marker but no prose
    /// followed (empty or whitespace-only). Previously the function returned
    /// `("", nil)` which caused an empty MorningBriefing SwiftData row to be
    /// written and the session to be cleaned up — judges / users saw "No
    /// briefing this morning" as if Layer 3 had never run. Throwing this
    /// error lets finalizeBriefing route to `.failure(.agentEmptyResponse)`
    /// with a distinct user-facing message.
    case emptyBriefingResponse
    /// M7 (Wave 2.6): the events list contained zero `agent.message` events.
    /// Caller previously got `nil` and downstream mapped that to empty string
    /// → parseAgentReply saw "" → `emptyBriefingResponse`. The two conditions
    /// deserve distinct codes because the first means Claude hadn't produced
    /// any response at all (agent might still be thinking; retry has value),
    /// while the second means Claude DID respond but emitted only a marker
    /// header. Separating the two lets future UI copy distinguish.
    case noAgentResponse
    /// M7 (Wave 2.6): an `agent.message` event exists but its `content` array
    /// has no `{"type": "text"}` block (e.g. tool_use-only). Means the agent
    /// is mid-tool-call rather than done — a retry or a "check back later"
    /// surface is more useful than rendering an empty briefing.
    case agentMessageMissingTextBlock

    var errorDescription: String? {
        switch self {
        case .missingProxyToken: return "Overnight agent: proxy token missing."
        case .invalidURL: return "Overnight agent: invalid URL."
        case .transportFailed: return "Overnight agent: transport failed."
        case .httpError(let status, _): return "Overnight agent: HTTP \(status)."
        case .timeout: return "Overnight agent: timed out."
        case .missingResourceID(let name): return "Overnight agent: expected \(name) not found in response."
        case .decodingFailed: return "Overnight agent: response parse failed."
        case .emptyBriefingResponse: return "Overnight agent: briefing content was empty."
        case .noAgentResponse: return "Overnight agent: no agent message found in session events."
        case .agentMessageMissingTextBlock: return "Overnight agent: agent message had no text block (tool-use only)."
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
    private let logger = Logger(subsystem: LogSubsystem.overnight, category: "agent-client")

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
        // Secrets.claudeEndpoint ends in ".../v1/messages" on Day 3; the base URL for
        // the agent client is the same host without the messages segment. Our proxy's
        // wildcard route resolves everything from /v1/* onwards.
        //
        // Empty endpoint must crash loudly — a silent fallback to api.anthropic.com would
        // route around the proxy and either 401 (no x-api-key) or leak the Anthropic key
        // from the client if someone ever hardcoded one. Copy Secrets.swift.example →
        // Secrets.swift and fill in your Vercel proxy URL.
        precondition(
            !Secrets.claudeEndpoint.isEmpty,
            "OvernightAgentClient: Secrets.claudeEndpoint is empty — set it to your Vercel proxy URL in Secrets.swift"
        )
        // Wave 2.1 / R4 fix: validate host against the shared `EndpointGuard` allowlist
        // before deriving the base URL. Previously this code happily accepted any
        // parse-able URL, so a tampered Secrets value would silently route overnight
        // agent traffic to an attacker-controlled host (vision verification crashed
        // loudly on the same allowlist; overnight agent did not).
        // SF-4 (Wave 3.1, 2026-04-26): redact the Secrets value before
        // interpolating into the precondition message. Without this, a
        // tampered/misconfigured Secrets value containing credentials
        // (`https://u:p@host/...`) would land verbatim in the iOS crash log.
        // EndpointGuard.redact strips userinfo cleanly.
        guard let url = URL(string: Secrets.claudeEndpoint),
              let host = url.host,
              let scheme = url.scheme else {
            let redacted = EndpointGuard.redact(urlString: Secrets.claudeEndpoint)
            preconditionFailure("OvernightAgentClient: Secrets.claudeEndpoint '\(redacted)' could not be parsed into scheme+host")
        }
        // SR7 (Stage 4): validateOrCrash replaces the inline catch → preconditionFailure
        // block. The derived URL string is `scheme://host[:port]`; validateOrCrash
        // parses + allowlist-checks it and returns the URL.
        //
        // P1 (Stage 6 Wave 1): preserve an explicit port if one was configured. The
        // previous build rendered `scheme://host` unconditionally, which silently
        // stripped `:PORT` from the Secrets endpoint — fine for prod (standard 443),
        // but broke any local proxy deployment or non-default Vercel preview URL
        // that pins a port. Including the port preserves the iOS → proxy intent.
        let portSuffix = url.port.map { ":\($0)" } ?? ""
        return EndpointGuard.validateOrCrash(urlString: "\(scheme)://\(host)\(portSuffix)", label: "Overnight agent endpoint")
    }

    /// P-I3 (Wave 2.2, 2026-04-26): `static let` shared URLSession — see the
    /// rationale in ClaudeAPIClient.defaultSession. Same proxy host so HTTP/2
    /// connection coalescing makes sharing strictly better than per-instance
    /// sessions. Built via `ProxyURLSession` so the 15/30 timeout pair stays
    /// in lockstep with the other proxy clients.
    private static let defaultSession: URLSession = ProxyURLSession.make()

    // MARK: - Public API

    /// Ensure the agent + environment resources exist. Reuses cached IDs in
    /// UserDefaults; creates new ones on first call. Idempotent.
    ///
    /// P15 (Stage 6 Wave 2) — partial-failure invariant:
    ///   Before: `createAgent()` succeeded → `defaults.set(agentID, ...)` →
    ///           `createEnvironment()` threw → next call saw `cached agent ∧
    ///           missing env`, fell into the create-fresh branch, and made
    ///           ANOTHER agent. The original agent was orphaned (billing
    ///           still accrues on every orphan up to Anthropic's 24h ceiling).
    ///   After:  persist NEITHER id until BOTH resources land cleanly. If
    ///           `createEnvironment()` throws after `createAgent()` succeeded,
    ///           we log and re-throw without touching defaults. The next call
    ///           creates a fresh agent + env pair cleanly.
    ///
    ///   Corruption recovery: if one key is present but the other is missing
    ///   (reached here via a pre-P15 build, or direct UserDefaults mutation),
    ///   treat it as corrupt state — wipe both keys and recreate. Avoids
    ///   leaking the stale id while keeping the happy-path simple.
    func ensureAgentAndEnvironment() async throws -> (agentID: String, environmentID: String) {
        let cachedAgent = defaults.string(forKey: Self.agentIDKey)
        let cachedEnv = defaults.string(forKey: Self.environmentIDKey)
        if let a = cachedAgent, let e = cachedEnv {
            logger.info("Reusing cached agent+environment IDs agent=\(a.prefix(12), privacy: .private) env=\(e.prefix(12), privacy: .private)")
            return (a, e)
        }
        // P15: XOR — exactly one side is present. Pre-P15 partial persist,
        // or direct defaults tamper. Wipe both and continue into the create
        // branch so we never return a half-populated pair.
        if cachedAgent != nil || cachedEnv != nil {
            logger.warning("Partial cached state detected (cachedAgent=\(cachedAgent != nil, privacy: .public) cachedEnv=\(cachedEnv != nil, privacy: .public)) — clearing both and recreating")
            defaults.removeObject(forKey: Self.agentIDKey)
            defaults.removeObject(forKey: Self.environmentIDKey)
        }

        logger.info("Cached agent/environment IDs missing; creating fresh resources")
        let newAgentID = try await createAgent()
        do {
            let newEnvID = try await createEnvironment()
            // P15: persist BOTH keys together. If we crash between these two
            // sets, the next call will see the XOR state above and wipe +
            // recreate — same clean outcome.
            defaults.set(newAgentID, forKey: Self.agentIDKey)
            defaults.set(newEnvID, forKey: Self.environmentIDKey)
            logger.info("Fresh agent+environment created agent=\(newAgentID.prefix(12), privacy: .private) env=\(newEnvID.prefix(12), privacy: .private)")
            return (newAgentID, newEnvID)
        } catch {
            // P15: env-create failed AFTER agent-create succeeded. Do NOT
            // persist the agent id — otherwise the next call's cached-agent
            // path would hit the XOR branch above and wipe it anyway, just
            // with extra churn and an intermediate "we orphaned an agent but
            // don't know about it" window.
            //
            // R3-4 (Stage 6 Wave 3): the P15 fix prevented LOCAL corruption
            // (don't persist the agent id unless both succeed), but the
            // already-created agent at Anthropic was left orphaned upstream.
            // We now attempt a best-effort `terminateAgent` before rethrowing
            // so the orphan does not sit unused on Anthropic's side.
            //
            // Failure of the termination itself is logged at `.fault` and
            // SWALLOWED — the original env-create error is the actionable one
            // for the caller (retry-able, indicates upstream env endpoint
            // health), while the termination failure is a background-
            // hygiene concern best left to the cron sweep / server-side GC.
            // If we rethrew the termination error here, the caller would
            // lose the original env-create classification that drives the
            // retry semantics in OvernightScheduler.startOvernightSession.
            logger.warning("Environment create failed after agent create; agent \(newAgentID.prefix(12), privacy: .private) will not be persisted; attempting upstream termination to avoid orphan: \(error.localizedDescription, privacy: .public)")
            do {
                try await terminateAgent(agentID: newAgentID)
                logger.info("Orphan agent terminated after env-create failure agent=\(newAgentID.prefix(12), privacy: .private)")
            } catch let termError {
                // Best-effort — agent termination may not be supported by the
                // Managed Agents beta (undocumented). The cron sweep + server-
                // side GC are the safety nets. Cost impact is bounded because
                // agents themselves don't bill — only sessions do.
                logger.fault("Orphan agent termination failed agent=\(newAgentID.prefix(12), privacy: .private); cron sweep + Anthropic server-side GC are the safety net. Underlying: \(termError.localizedDescription, privacy: .public)")
            }
            throw error  // re-throw the ORIGINAL env-create error (not the termination error)
        }
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
            parsed = try SharedJSON.decodePlain(Resp.self, from: data)
        } catch {
            logger.error("startSession: response decode failed — \(error.localizedDescription, privacy: .public)")
            throw OvernightAgentError.decodingFailed(underlying: error)
        }
        guard let id = parsed.id else { throw OvernightAgentError.missingResourceID("session.id") }
        logger.info("Managed Agent session started id=\(id.prefix(12), privacy: .private)")

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
        logger.info("Appended event to session \(sessionID.prefix(12), privacy: .private) (bytes=\(text.utf8.count, privacy: .public))")
    }

    /// Fetch events and return the latest agent.message content.
    ///
    /// Response shape is `{"data": [<event>, ...]}` — the top-level key is
    /// `data`, not `events`. Each event has `type`, and `agent.message`
    /// events carry `content: [{"type": "text", "text": "..."}]`.
    ///
    /// M7 (Wave 2.6): no longer returns `String?`. Instead:
    ///   - Throws `.noAgentResponse` when the events list contains zero
    ///     `agent.message` entries. Previously the caller got `nil` → empty
    ///     string → `parseAgentReply` threw `.emptyBriefingResponse`, which
    ///     mapped to `.agentEmptyResponse`. Correct outcome at the *final*
    ///     classification but hostile to debugging — the error propagated up
    ///     as "briefing was empty" when the truth was "no briefing block at
    ///     all". Separating the two lets logs, metrics, and future UI copy
    ///     distinguish "agent hadn't responded yet" from "agent responded but
    ///     emitted a blank briefing".
    ///   - Throws `.agentMessageMissingTextBlock` when an agent.message event
    ///     exists but has no `text` content block (e.g. tool_use-only during
    ///     mid-session reasoning). This is distinct from the first case: the
    ///     agent IS producing output, just not a user-visible text yet.
    func fetchLatestAgentMessage(sessionID: String) async throws -> String {
        let url = baseURL.appendingPathComponent("v1/sessions/\(sessionID)/events")
        let data = try await getJSON(url: url)
        // SR5 (Stage 4): reuse the shared `TextBlock` shape for the per-event
        // content array. The outer `data: [Event]` shape is Managed-Agents-
        // specific so it stays local.
        struct EventsResponse: Decodable {
            struct Event: Decodable {
                let type: String
                let content: [AnthropicResponseDecoding.TextBlock]?
            }
            let data: [Event]?
        }
        let parsed: EventsResponse
        do {
            parsed = try SharedJSON.decodePlain(EventsResponse.self, from: data)
        } catch {
            logger.error("fetchLatestAgentMessage: decode failed — \(error.localizedDescription, privacy: .public)")
            throw OvernightAgentError.decodingFailed(underlying: error)
        }
        let agentMessages = parsed.data?.filter { $0.type == "agent.message" } ?? []
        guard let latest = agentMessages.last else {
            // No agent.message events yet. Distinct from "the text inside one
            // was empty" — the agent may simply not have produced anything.
            logger.info("fetchLatestAgentMessage session=\(sessionID.prefix(12), privacy: .private) no agent.message events found (data count=\(parsed.data?.count ?? 0, privacy: .public))")
            throw OvernightAgentError.noAgentResponse
        }
        // SR5 (Stage 4): shared text-block lookup with the emptyContent re-map.
        // Preserves the distinct `.agentMessageMissingTextBlock` error code —
        // the "agent responded but only with tool_use" signal callers rely on.
        let text: String
        do {
            text = try AnthropicResponseDecoding.firstTextBlock(from: latest.content)
        } catch AnthropicResponseDecodingError.emptyContent {
            let blockTypes = (latest.content ?? []).map { $0.type }.joined(separator: ",")
            logger.info("fetchLatestAgentMessage session=\(sessionID.prefix(12), privacy: .private) agent.message had no text block; types=\(blockTypes, privacy: .public)")
            throw OvernightAgentError.agentMessageMissingTextBlock
        }
        logger.info("fetchLatestAgentMessage session=\(sessionID.prefix(12), privacy: .private) foundAgentMessages=\(agentMessages.count, privacy: .public) lastTextBytes=\(text.utf8.count, privacy: .public)")
        return text
    }

    /// Terminate the session so its running-time billing stops accruing.
    /// Uses `DELETE /v1/sessions/:id` — confirmed by Task B.3 dry-run as the
    /// only supported termination path (PATCH returns 404). Response body is
    /// `{"id": "sesn_...", "type": "session_deleted"}` which we do not need
    /// to parse.
    func terminateSession(sessionID: String) async throws {
        let url = baseURL.appendingPathComponent("v1/sessions/\(sessionID)")
        _ = try await jsonRequest(url: url, method: "DELETE", body: nil)
        logger.info("Session \(sessionID.prefix(12), privacy: .private) deleted")
    }

    /// R3-4 (Stage 6 Wave 3): best-effort upstream agent termination. Used
    /// when `ensureAgentAndEnvironment` hits a partial-failure state where the
    /// agent was created successfully but the environment create that
    /// followed threw — the P15 fix prevents the orphaned agent ID from being
    /// persisted locally, but the upstream agent still exists on Anthropic's
    /// side until we delete it or the cron sweep / server-side GC catches it.
    ///
    /// API support caveat: the Managed Agents beta at `managed-agents-2026-04-01`
    /// documents session termination (DELETE /v1/sessions/:id) explicitly. The
    /// Anthropic docs (`/docs/en/managed-agents/sessions`) and our own
    /// `opus-4-7-research-notes.md` reference session termination but do NOT
    /// explicitly document DELETE /v1/agents/:id. We issue the DELETE as a
    /// best-effort attempt: the method throws on upstream failure and the
    /// caller logs at `.fault` before re-throwing the ORIGINAL env-create
    /// error. If the API doesn't support agent deletion (expect 404 / 405),
    /// the fault log captures the fact and we rely on:
    ///   (1) the cost impact being low — agents themselves are configs,
    ///       not sessions; only sessions accrue $0.08/hr. An orphan agent
    ///       sitting without any attached session costs nothing.
    ///   (2) the cron sweep at `cleanup-stale-sessions.js` still catches any
    ///       stale session that eventually gets attached to the orphan agent.
    ///   (3) Anthropic's own server-side GC for unused resources.
    func terminateAgent(agentID: String) async throws {
        let url = baseURL.appendingPathComponent("v1/agents/\(agentID)")
        _ = try await jsonRequest(url: url, method: "DELETE", body: nil)
        logger.info("Agent \(agentID.prefix(12), privacy: .private) deleted")
    }

    // MARK: - Private helpers

    private func createAgent() async throws -> String {
        let url = baseURL.appendingPathComponent("v1/agents")
        // P13 (Stage 6 Wave 2): the agent name string below is LOAD-BEARING.
        // The Vercel cron worker at
        //   workers/wakeproof-proxy-vercel/api/cron/cleanup-stale-sessions.js
        // filters sessions to clean up with
        //   `agentName.startsWith("wakeproof-overnight")`
        // (constant `WAKEPROOF_AGENT_PREFIX` in that file). If the name here
        // drifts (renamed, versioned, suffixed, etc.) without a matching
        // update in cleanup-stale-sessions.js, the cron stops sweeping our
        // orphan sessions and $0.08/hr meters run up to Anthropic's 24h
        // ceiling before auto-termination. When changing this value, grep
        // the worker repo for `WAKEPROOF_AGENT_PREFIX` and keep them in sync.
        let body: [String: Any] = [
            "name": "wakeproof-overnight",
            "model": Secrets.visionModel,  // Opus 4.7 — same model as the vision call
            "system": Self.agentSystemPrompt()
        ]
        let data = try await postJSON(url: url, body: body)
        struct Resp: Decodable { let id: String? }
        let parsed: Resp
        do {
            parsed = try SharedJSON.decodePlain(Resp.self, from: data)
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
            parsed = try SharedJSON.decodePlain(Resp.self, from: data)
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
        // S-I8 (Wave 2.1, 2026-04-26): centralised placeholder constant.
        guard !proxyToken.isEmpty, proxyToken != SecretsConstants.tokenPlaceholder else {
            logger.error("\(method, privacy: .public) \(url.path, privacy: .public): proxy token missing")
            throw OvernightAgentError.missingProxyToken
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        // SR8 (Stage 4): shared header extension. Managed Agents surface requires
        // the `anthropic-beta` header — the only one of the three clients to
        // use it.
        request.setWakeProofHeaders(token: proxyToken, beta: beta)
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
