//
//  OvernightAgentClientTests.swift
//  WakeProofTests
//
//  URLProtocol-stubbed tests for the Managed Agents primary-path client.
//  Each test injects a fresh UserDefaults suite so cached agent/environment
//  IDs do not cross-contaminate. The stub class is file-local so its static
//  handler state stays isolated from other test files in this target.
//

import XCTest
@testable import WakeProof

final class OvernightAgentClientTests: XCTestCase {

    // MARK: - Stub protocol

    /// URLProtocol stub with file-scoped static handlers. Tests in this file
    /// must run serially (the scheme already disables parallel-testing globally
    /// per ClaudeAPIClientTests' note) — concurrent test methods would race on
    /// `requests`, `handler`, and `throwing`.
    final class StubProtocol: URLProtocol {
        nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?
        nonisolated(unsafe) static var throwing: Error?
        /// All requests that reached the stub, in order. Body data is re-read
        /// off bodyStream here (URLSession often prefers the stream form).
        nonisolated(unsafe) static var requests: [(method: String, path: String, headers: [String: String], body: Data?)] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let method = request.httpMethod ?? ""
            let path = request.url?.path ?? ""
            let headers = request.allHTTPHeaderFields ?? [:]
            let body = request.httpBody ?? request.bodyStreamAsData()
            Self.requests.append((method, path, headers, body))

            if let error = Self.throwing {
                client?.urlProtocol(self, didFailWithError: error)
                return
            }
            guard let handler = Self.handler else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            let (response, data) = handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}

        static func reset() {
            handler = nil
            throwing = nil
            requests.removeAll()
        }
    }

    // MARK: - Test plumbing

    private var suiteDefaults: UserDefaults!
    private let suiteName = "com.wakeproof.tests.overnightagent"
    private let baseURL = URL(string: "https://wakeproof-proxy-vercel.vercel.app")!

    override func setUp() {
        super.setUp()
        StubProtocol.reset()
        suiteDefaults = UserDefaults(suiteName: suiteName)
        suiteDefaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        suiteDefaults?.removePersistentDomain(forName: suiteName)
        suiteDefaults = nil
        StubProtocol.reset()
        super.tearDown()
    }

    /// Build a client whose URLSession routes through `StubProtocol` and whose
    /// UserDefaults is scoped to the per-test suite so no global state leaks.
    private func makeClient() -> OvernightAgentClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: config)
        return OvernightAgentClient(
            session: session,
            baseURL: baseURL,
            proxyToken: "test-token",
            beta: "managed-agents-2026-04-01",
            defaults: suiteDefaults
        )
    }

    private func jsonResponse(for request: URLRequest, status: Int, payload: [String: Any]) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        let body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        return (response, body)
    }

    // MARK: - ensureAgentAndEnvironment

    func testEnsureAgentAndEnvironmentCreatesBothOnFirstCall() async throws {
        StubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/v1/agents") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let body = try! JSONSerialization.data(withJSONObject: ["id": "agent_abc"])
                return (response, body)
            } else if path.hasSuffix("/v1/environments") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let body = try! JSONSerialization.data(withJSONObject: ["id": "env_xyz"])
                return (response, body)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let client = makeClient()
        let (agentID, envID) = try await client.ensureAgentAndEnvironment()

        XCTAssertEqual(agentID, "agent_abc")
        XCTAssertEqual(envID, "env_xyz")
        XCTAssertEqual(suiteDefaults.string(forKey: OvernightAgentClient.agentIDKey), "agent_abc")
        XCTAssertEqual(suiteDefaults.string(forKey: OvernightAgentClient.environmentIDKey), "env_xyz")

        let postPaths = StubProtocol.requests.filter { $0.method == "POST" }.map { $0.path }
        XCTAssertEqual(postPaths.count, 2, "first call should create both agent + environment")
        XCTAssertTrue(postPaths.contains(where: { $0.hasSuffix("/v1/agents") }))
        XCTAssertTrue(postPaths.contains(where: { $0.hasSuffix("/v1/environments") }))
    }

    func testEnsureAgentAndEnvironmentReusesCachedIDs() async throws {
        suiteDefaults.set("agent_cached", forKey: OvernightAgentClient.agentIDKey)
        suiteDefaults.set("env_cached", forKey: OvernightAgentClient.environmentIDKey)
        // Ensure any stray network hit would fail visibly.
        StubProtocol.handler = { request in
            XCTFail("unexpected HTTP call to \(request.url?.absoluteString ?? "?")")
            let response = HTTPURLResponse(url: request.url!, statusCode: 418, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let client = makeClient()
        let (agentID, envID) = try await client.ensureAgentAndEnvironment()

        XCTAssertEqual(agentID, "agent_cached")
        XCTAssertEqual(envID, "env_cached")
        XCTAssertTrue(StubProtocol.requests.isEmpty, "cached IDs must bypass all HTTP traffic")
    }

    // MARK: - startSession

    func testStartSessionReturnsHandleWithSessionID() async throws {
        suiteDefaults.set("agent_preset", forKey: OvernightAgentClient.agentIDKey)
        suiteDefaults.set("env_preset", forKey: OvernightAgentClient.environmentIDKey)
        // startSession now (1) POSTs /v1/sessions then (2) POSTs the seed as a
        // follow-up events event. Both stubbed responses must be valid.
        StubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if path.hasSuffix("/v1/sessions") {
                let body = try! JSONSerialization.data(withJSONObject: ["id": "sesn_42"])
                return (response, body)
            } else if path.hasSuffix("/events") {
                return (response, Data("{}".utf8))
            }
            return (response, Data("{}".utf8))
        }
        let client = makeClient()
        let handle = try await client.startSession(seedMessage: "hello")
        XCTAssertEqual(handle.sessionID, "sesn_42")
        XCTAssertEqual(handle.agentID, "agent_preset")
        XCTAssertEqual(handle.environmentID, "env_preset")

        let sessionPosts = StubProtocol.requests.filter { $0.method == "POST" && $0.path.hasSuffix("/v1/sessions") }
        XCTAssertEqual(sessionPosts.count, 1)
        let eventPosts = StubProtocol.requests.filter { $0.method == "POST" && $0.path.hasSuffix("/v1/sessions/sesn_42/events") }
        XCTAssertEqual(eventPosts.count, 1, "seed message must be posted as a follow-up event")
    }

    func testStartSessionBodyShapeIsAgentAndEnvironmentIDOnly() async throws {
        // API shape confirmed by Task B.3 dry-run: {"agent": <id>, "environment_id": <id>}.
        // No initial_message, no task_budget at session-create time.
        suiteDefaults.set("agent_preset", forKey: OvernightAgentClient.agentIDKey)
        suiteDefaults.set("env_preset", forKey: OvernightAgentClient.environmentIDKey)
        StubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if path.hasSuffix("/v1/sessions") {
                let body = try! JSONSerialization.data(withJSONObject: ["id": "sesn_budget"])
                return (response, body)
            } else if path.hasSuffix("/events") {
                return (response, Data("{}".utf8))
            }
            return (response, Data("{}".utf8))
        }
        let client = makeClient()
        _ = try await client.startSession(seedMessage: "hi", taskBudgetTokens: 55_555)

        guard let sessionPost = StubProtocol.requests.first(where: {
            $0.method == "POST" && $0.path.hasSuffix("/v1/sessions")
        }) else {
            return XCTFail("missing POST /v1/sessions")
        }
        guard let body = sessionPost.body,
              let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return XCTFail("session POST body did not parse as JSON object")
        }
        XCTAssertEqual(json["agent"] as? String, "agent_preset",
                       "session-create body must use 'agent' key (not 'agent_id')")
        XCTAssertEqual(json["environment_id"] as? String, "env_preset")
        XCTAssertNil(json["agent_id"], "'agent_id' is rejected by the API; must use 'agent'")
        XCTAssertNil(json["initial_message"], "initial_message not accepted at session-create — seed via events POST")
        XCTAssertNil(json["task_budget"], "task_budget not accepted at session-create in managed-agents-2026-04-01")
    }

    func testStartSessionSendsSeedAsFollowUpEvent() async throws {
        // Seed prompt is sent as an events POST immediately after session-create.
        suiteDefaults.set("agent_preset", forKey: OvernightAgentClient.agentIDKey)
        suiteDefaults.set("env_preset", forKey: OvernightAgentClient.environmentIDKey)
        StubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if path.hasSuffix("/v1/sessions") {
                let body = try! JSONSerialization.data(withJSONObject: ["id": "sesn_seed"])
                return (response, body)
            } else if path.hasSuffix("/events") {
                return (response, Data("{}".utf8))
            }
            return (response, Data("{}".utf8))
        }
        let client = makeClient()
        _ = try await client.startSession(seedMessage: "seed payload")

        guard let eventPost = StubProtocol.requests.first(where: {
            $0.method == "POST" && $0.path.hasSuffix("/v1/sessions/sesn_seed/events")
        }) else {
            return XCTFail("missing POST /v1/sessions/sesn_seed/events")
        }
        guard let body = eventPost.body,
              let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let events = json["events"] as? [[String: Any]],
              let first = events.first,
              let content = first["content"] as? [[String: Any]],
              let block = content.first else {
            return XCTFail("seed-event body did not parse")
        }
        XCTAssertEqual(first["type"] as? String, "user.message")
        XCTAssertEqual(block["type"] as? String, "text")
        XCTAssertEqual(block["text"] as? String, "seed payload")
    }

    // MARK: - appendEvent

    func testAppendEventPostsToCorrectPath() async throws {
        // API shape confirmed by Task B.3 dry-run: body is {"events": [{...}]}
        // with the plural `events` key wrapping a single-element array.
        suiteDefaults.set("agent_preset", forKey: OvernightAgentClient.agentIDKey)
        suiteDefaults.set("env_preset", forKey: OvernightAgentClient.environmentIDKey)
        StubProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("{}".utf8))
        }
        let client = makeClient()
        try await client.appendEvent(sessionID: "sesn_42", text: "heart rate dropped")

        guard let post = StubProtocol.requests.first else {
            return XCTFail("no request captured")
        }
        XCTAssertEqual(post.method, "POST")
        XCTAssertTrue(post.path.hasSuffix("/v1/sessions/sesn_42/events"), "got path \(post.path)")

        guard let body = post.body,
              let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return XCTFail("append body did not parse as JSON object")
        }
        XCTAssertNil(json["event"], "singular 'event' key is rejected — must be plural 'events' array")
        guard let events = json["events"] as? [[String: Any]] else {
            return XCTFail("append body must contain 'events' array at top level")
        }
        XCTAssertEqual(events.count, 1, "we send one event per call")
        let firstEvent = events[0]
        XCTAssertEqual(firstEvent["type"] as? String, "user.message")
        guard let content = firstEvent["content"] as? [[String: Any]],
              let first = content.first else {
            return XCTFail("append content block missing")
        }
        XCTAssertEqual(first["type"] as? String, "text")
        XCTAssertEqual(first["text"] as? String, "heart rate dropped")
    }

    // MARK: - fetchLatestAgentMessage

    func testFetchLatestAgentMessageFindsAgentMessageEvents() async throws {
        // API shape confirmed by Task B.3 dry-run: response top-level is
        // {"data": [<event>, ...]} (not {"events": [...]}).
        suiteDefaults.set("agent_preset", forKey: OvernightAgentClient.agentIDKey)
        suiteDefaults.set("env_preset", forKey: OvernightAgentClient.environmentIDKey)
        StubProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let payload: [String: Any] = [
                "data": [
                    ["type": "user.message", "content": [["type": "text", "text": "user seed"]]],
                    ["type": "agent.message", "content": [["type": "text", "text": "first draft"]]],
                    ["type": "agent.message", "content": [["type": "text", "text": "FINAL BRIEFING"]]]
                ]
            ]
            let body = try! JSONSerialization.data(withJSONObject: payload)
            return (response, body)
        }
        let client = makeClient()
        let text = try await client.fetchLatestAgentMessage(sessionID: "sesn_42")
        XCTAssertEqual(text, "FINAL BRIEFING")

        guard let get = StubProtocol.requests.first else {
            return XCTFail("no request captured")
        }
        XCTAssertEqual(get.method, "GET")
        XCTAssertTrue(get.path.hasSuffix("/v1/sessions/sesn_42/events"), "got path \(get.path)")
    }

    /// M7 (Wave 2.6): renamed from `...ReturnsNilWhenNoAgentMessages` because
    /// the method no longer returns `String?` — it throws `noAgentResponse`.
    /// Before, the caller got nil → "" → `parseAgentReply` threw
    /// `emptyBriefingResponse`, which finalizeBriefing mapped to
    /// `.agentEmptyResponse` — user-facing outcome was right, but the
    /// underlying signal ("no agent message found at all") was indistinct
    /// from "agent emitted an empty BRIEFING: marker". Throwing explicitly
    /// preserves the distinction in logs / metrics.
    func testFetchLatestAgentMessageThrowsWhenNoAgentMessages() async throws {
        suiteDefaults.set("agent_preset", forKey: OvernightAgentClient.agentIDKey)
        suiteDefaults.set("env_preset", forKey: OvernightAgentClient.environmentIDKey)
        StubProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let payload: [String: Any] = [
                "data": [
                    ["type": "user.message", "content": [["type": "text", "text": "just user"]]]
                ]
            ]
            let body = try! JSONSerialization.data(withJSONObject: payload)
            return (response, body)
        }
        let client = makeClient()
        do {
            _ = try await client.fetchLatestAgentMessage(sessionID: "sesn_42")
            XCTFail("expected .noAgentResponse")
        } catch OvernightAgentError.noAgentResponse {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    /// M7 (Wave 2.6): agent.message exists, but its content array has only
    /// tool_use blocks and no text block. Previously the nil-return path ran
    /// for this case too; the new code throws `agentMessageMissingTextBlock`
    /// so the caller can tell "agent is mid-tool-call" apart from "agent
    /// hadn't produced anything". Both collapse to `.agentEmptyResponse` in
    /// the scheduler's UI-copy classification today, but the distinction
    /// stays visible in `errorDescription` and logs for post-mortem.
    func testFetchLatestAgentMessageThrowsWhenAgentEmitsOnlyToolUse() async throws {
        suiteDefaults.set("agent_preset", forKey: OvernightAgentClient.agentIDKey)
        suiteDefaults.set("env_preset", forKey: OvernightAgentClient.environmentIDKey)
        StubProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let payload: [String: Any] = [
                "data": [
                    // Agent IS producing events — just not a text block yet.
                    ["type": "agent.message", "content": [["type": "tool_use", "id": "x", "name": "python", "input": ["code": "1+1"]]]]
                ]
            ]
            let body = try! JSONSerialization.data(withJSONObject: payload)
            return (response, body)
        }
        let client = makeClient()
        do {
            _ = try await client.fetchLatestAgentMessage(sessionID: "sesn_42")
            XCTFail("expected .agentMessageMissingTextBlock")
        } catch OvernightAgentError.agentMessageMissingTextBlock {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - terminateSession

    func testTerminateSessionCallsDELETE() async throws {
        // API shape confirmed by Task B.3 dry-run: DELETE /v1/sessions/:id is
        // the only supported termination path. PATCH returns 404.
        suiteDefaults.set("agent_preset", forKey: OvernightAgentClient.agentIDKey)
        suiteDefaults.set("env_preset", forKey: OvernightAgentClient.environmentIDKey)
        StubProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let payload: [String: Any] = ["id": "sesn_42", "type": "session_deleted"]
            let body = try! JSONSerialization.data(withJSONObject: payload)
            return (response, body)
        }
        let client = makeClient()
        try await client.terminateSession(sessionID: "sesn_42")

        let deletes = StubProtocol.requests.filter { $0.method == "DELETE" }
        XCTAssertEqual(deletes.count, 1, "terminate must issue exactly one DELETE")
        XCTAssertTrue(deletes[0].path.hasSuffix("/v1/sessions/sesn_42"))
        XCTAssertNil(deletes[0].body, "DELETE termination takes no body")

        let patches = StubProtocol.requests.filter { $0.method == "PATCH" }
        XCTAssertTrue(patches.isEmpty, "PATCH termination path was removed — must not be used")
        let fallbackPosts = StubProtocol.requests.filter { $0.method == "POST" && $0.path.hasSuffix("/events") }
        XCTAssertTrue(fallbackPosts.isEmpty, "interrupt-event fallback was removed — must not be used")
    }

    // MARK: - Beta header

    func testAllCallsSendManagedAgentsBetaHeader() async throws {
        StubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if path.hasSuffix("/v1/agents") {
                return (response, try! JSONSerialization.data(withJSONObject: ["id": "agent_abc"]))
            } else if path.hasSuffix("/v1/environments") {
                return (response, try! JSONSerialization.data(withJSONObject: ["id": "env_xyz"]))
            } else if path.hasSuffix("/v1/sessions") {
                return (response, try! JSONSerialization.data(withJSONObject: ["id": "sesn_42"]))
            } else if path.hasSuffix("/events") {
                // GET returns {"data": [...]}; POST events returns {}. Either
                // shape parses cleanly for this header-only test.
                return (response, Data("{\"data\": []}".utf8))
            } else {
                return (response, try! JSONSerialization.data(withJSONObject: ["id": "sesn_42", "type": "session_deleted"]))
            }
        }
        let client = makeClient()
        let handle = try await client.startSession(seedMessage: "ping")
        try await client.appendEvent(sessionID: handle.sessionID, text: "midnight data point")
        _ = try? await client.fetchLatestAgentMessage(sessionID: handle.sessionID)
        try await client.terminateSession(sessionID: handle.sessionID)

        XCTAssertFalse(StubProtocol.requests.isEmpty, "no requests captured")
        // Confirm we saw at least one DELETE (termination) so the header
        // assertions actually cover that path.
        XCTAssertTrue(StubProtocol.requests.contains { $0.method == "DELETE" },
                      "expected DELETE termination request in captured traffic")
        for captured in StubProtocol.requests {
            let beta = captured.headers["anthropic-beta"]
            XCTAssertEqual(beta, "managed-agents-2026-04-01",
                           "method=\(captured.method) path=\(captured.path) missing/wrong anthropic-beta header (got \(beta ?? "nil"))")
            let token = captured.headers["x-wakeproof-token"]
            XCTAssertEqual(token, "test-token", "proxy token missing on \(captured.method) \(captured.path)")
            let version = captured.headers["anthropic-version"]
            XCTAssertEqual(version, "2023-06-01", "anthropic-version missing on \(captured.method) \(captured.path)")
        }
    }

    // MARK: - Missing proxy token

    func testMissingProxyTokenShortCircuits() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: config)
        let client = OvernightAgentClient(
            session: session,
            baseURL: baseURL,
            proxyToken: "REPLACE_WITH_OPENSSL_RAND_HEX_32",
            beta: "managed-agents-2026-04-01",
            defaults: suiteDefaults
        )
        do {
            _ = try await client.ensureAgentAndEnvironment()
            XCTFail("expected .missingProxyToken")
        } catch OvernightAgentError.missingProxyToken {
            // expected — this is the placeholder sentinel
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - P15: partial-failure agent-leak prevention

    /// P15 (Stage 6 Wave 2): `createAgent()` succeeds, `createEnvironment()`
    /// throws. Previously the agent ID was persisted BEFORE env-create ran, so
    /// the next call's `cached agent ∧ missing env` guard failed, fell into the
    /// create-fresh branch, and made ANOTHER agent — original one orphaned at
    /// $0.08/hr until Anthropic's 24h ceiling kicked in. Fix: persist NEITHER
    /// ID until BOTH resources land.
    ///
    /// Test: stub `/v1/agents` to 200 + id, stub `/v1/environments` to 500.
    /// Call ensureAgentAndEnvironment, expect throw. Assert `agentIDKey` is
    /// NOT set in defaults. Re-calling should create a fresh pair, not reuse
    /// the orphaned agent.
    func testPartialFailureDoesNotPersistAgentIDIfEnvCreateThrows() async {
        StubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/v1/agents") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let body = try! JSONSerialization.data(withJSONObject: ["id": "agent_first"])
                return (response, body)
            } else if path.hasSuffix("/v1/environments") {
                // 500 triggers OvernightAgentError.httpError in the client.
                let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
                return (response, Data("{\"error\": \"env create failed\"}".utf8))
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let client = makeClient()
        do {
            _ = try await client.ensureAgentAndEnvironment()
            XCTFail("env-create failure must propagate as a throw")
        } catch {
            // Expected — the env-create 500 bubbles up.
        }

        // P15 critical invariant: the orphaned agent must NOT be persisted.
        // If this assertion flips, the next ensureAgentAndEnvironment call
        // would see a cached agent but no env, and (pre-P15) would create
        // another agent — silently leaking $0.08/hr until Anthropic 24h TTL.
        XCTAssertNil(suiteDefaults.string(forKey: OvernightAgentClient.agentIDKey),
                     "agentID must NOT be persisted when env-create fails — prevents orphaned-agent leak")
        XCTAssertNil(suiteDefaults.string(forKey: OvernightAgentClient.environmentIDKey),
                     "envID obviously not persisted since env-create failed")
    }

    /// P15 (Stage 6 Wave 2): corruption recovery — if one key is present and
    /// the other is missing (pre-P15 build, or direct defaults tamper), the
    /// ensureAgentAndEnvironment call must wipe both and recreate cleanly.
    /// Previously `if let a, let e` succeeded only on both-present, falling
    /// through to the create branch on either-missing — but the create
    /// branch re-persisted the missing side, leaving the STALE other side
    /// in place. Result: a zombie pairing of new-agent + stale-env (or
    /// inverse), which fails at the first use.
    func testEnsureAgentAndEnvironmentWipesXORStateAndRecreates() async throws {
        // Seed half the pair — agent present, env missing.
        suiteDefaults.set("agent_stale", forKey: OvernightAgentClient.agentIDKey)

        StubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if path.hasSuffix("/v1/agents") {
                let body = try! JSONSerialization.data(withJSONObject: ["id": "agent_fresh"])
                return (response, body)
            } else if path.hasSuffix("/v1/environments") {
                let body = try! JSONSerialization.data(withJSONObject: ["id": "env_fresh"])
                return (response, body)
            }
            return (response, Data())
        }
        let client = makeClient()
        let (agentID, envID) = try await client.ensureAgentAndEnvironment()

        // Stale agent must be replaced, not reused.
        XCTAssertEqual(agentID, "agent_fresh",
                       "XOR-state detection must wipe stale agent and mint a fresh one")
        XCTAssertEqual(envID, "env_fresh")
        XCTAssertEqual(suiteDefaults.string(forKey: OvernightAgentClient.agentIDKey), "agent_fresh")
        XCTAssertEqual(suiteDefaults.string(forKey: OvernightAgentClient.environmentIDKey), "env_fresh")
    }
}
