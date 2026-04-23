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
        StubProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = try! JSONSerialization.data(withJSONObject: ["id": "sess_42"])
            return (response, body)
        }
        let client = makeClient()
        let handle = try await client.startSession(seedMessage: "hello")
        XCTAssertEqual(handle.sessionID, "sess_42")
        XCTAssertEqual(handle.agentID, "agent_preset")
        XCTAssertEqual(handle.environmentID, "env_preset")

        let posts = StubProtocol.requests.filter { $0.method == "POST" && $0.path.hasSuffix("/v1/sessions") }
        XCTAssertEqual(posts.count, 1)
    }

    func testStartSessionIncludesTaskBudget() async throws {
        suiteDefaults.set("agent_preset", forKey: OvernightAgentClient.agentIDKey)
        suiteDefaults.set("env_preset", forKey: OvernightAgentClient.environmentIDKey)
        StubProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = try! JSONSerialization.data(withJSONObject: ["id": "sess_budget"])
            return (response, body)
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
        XCTAssertEqual(json["agent_id"] as? String, "agent_preset")
        XCTAssertEqual(json["environment_id"] as? String, "env_preset")
        guard let budget = json["task_budget"] as? [String: Any] else {
            return XCTFail("task_budget missing from POST body")
        }
        XCTAssertEqual(budget["type"] as? String, "tokens")
        XCTAssertEqual(budget["total"] as? Int, 55_555)
    }

    // MARK: - appendEvent

    func testAppendEventPostsToCorrectPath() async throws {
        suiteDefaults.set("agent_preset", forKey: OvernightAgentClient.agentIDKey)
        suiteDefaults.set("env_preset", forKey: OvernightAgentClient.environmentIDKey)
        StubProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("{}".utf8))
        }
        let client = makeClient()
        try await client.appendEvent(sessionID: "sess_42", text: "heart rate dropped")

        guard let post = StubProtocol.requests.first else {
            return XCTFail("no request captured")
        }
        XCTAssertEqual(post.method, "POST")
        XCTAssertTrue(post.path.hasSuffix("/v1/sessions/sess_42/events"), "got path \(post.path)")

        guard let body = post.body,
              let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let event = json["event"] as? [String: Any] else {
            return XCTFail("append body did not parse")
        }
        XCTAssertEqual(event["type"] as? String, "user.message")
        guard let content = event["content"] as? [[String: Any]],
              let first = content.first else {
            return XCTFail("append content block missing")
        }
        XCTAssertEqual(first["type"] as? String, "text")
        XCTAssertEqual(first["text"] as? String, "heart rate dropped")
    }

    // MARK: - fetchLatestAgentMessage

    func testFetchLatestAgentMessageFindsAgentMessageEvents() async throws {
        suiteDefaults.set("agent_preset", forKey: OvernightAgentClient.agentIDKey)
        suiteDefaults.set("env_preset", forKey: OvernightAgentClient.environmentIDKey)
        StubProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let payload: [String: Any] = [
                "events": [
                    ["type": "user.message", "content": [["type": "text", "text": "user seed"]]],
                    ["type": "agent.message", "content": [["type": "text", "text": "first draft"]]],
                    ["type": "agent.message", "content": [["type": "text", "text": "FINAL BRIEFING"]]]
                ]
            ]
            let body = try! JSONSerialization.data(withJSONObject: payload)
            return (response, body)
        }
        let client = makeClient()
        let text = try await client.fetchLatestAgentMessage(sessionID: "sess_42")
        XCTAssertEqual(text, "FINAL BRIEFING")

        guard let get = StubProtocol.requests.first else {
            return XCTFail("no request captured")
        }
        XCTAssertEqual(get.method, "GET")
        XCTAssertTrue(get.path.hasSuffix("/v1/sessions/sess_42/events"), "got path \(get.path)")
    }

    func testFetchLatestAgentMessageReturnsNilWhenNoAgentMessages() async throws {
        suiteDefaults.set("agent_preset", forKey: OvernightAgentClient.agentIDKey)
        suiteDefaults.set("env_preset", forKey: OvernightAgentClient.environmentIDKey)
        StubProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let payload: [String: Any] = [
                "events": [
                    ["type": "user.message", "content": [["type": "text", "text": "just user"]]]
                ]
            ]
            let body = try! JSONSerialization.data(withJSONObject: payload)
            return (response, body)
        }
        let client = makeClient()
        let text = try await client.fetchLatestAgentMessage(sessionID: "sess_42")
        XCTAssertNil(text)
    }

    // MARK: - terminateSession

    func testTerminateSessionHappyPathPATCHes() async throws {
        suiteDefaults.set("agent_preset", forKey: OvernightAgentClient.agentIDKey)
        suiteDefaults.set("env_preset", forKey: OvernightAgentClient.environmentIDKey)
        StubProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("{}".utf8))
        }
        let client = makeClient()
        try await client.terminateSession(sessionID: "sess_42")

        let patches = StubProtocol.requests.filter { $0.method == "PATCH" }
        XCTAssertEqual(patches.count, 1)
        XCTAssertTrue(patches[0].path.hasSuffix("/v1/sessions/sess_42"))
        guard let body = patches[0].body,
              let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return XCTFail("PATCH body did not parse")
        }
        XCTAssertEqual(json["status"] as? String, "terminated")

        let fallbackPosts = StubProtocol.requests.filter { $0.method == "POST" && $0.path.hasSuffix("/events") }
        XCTAssertTrue(fallbackPosts.isEmpty, "happy path must not fall back to interrupt event")
    }

    func testTerminateSessionFallsBackToInterruptEventOn404() async throws {
        suiteDefaults.set("agent_preset", forKey: OvernightAgentClient.agentIDKey)
        suiteDefaults.set("env_preset", forKey: OvernightAgentClient.environmentIDKey)
        StubProtocol.handler = { request in
            if request.httpMethod == "PATCH" {
                let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (response, Data("not found".utf8))
            }
            // Interrupt event POST succeeds.
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("{}".utf8))
        }
        let client = makeClient()
        try await client.terminateSession(sessionID: "sess_42")

        let patches = StubProtocol.requests.filter { $0.method == "PATCH" }
        XCTAssertEqual(patches.count, 1)

        let posts = StubProtocol.requests.filter { $0.method == "POST" && $0.path.hasSuffix("/v1/sessions/sess_42/events") }
        XCTAssertEqual(posts.count, 1, "404 PATCH must fall back to exactly one interrupt POST")
        guard let body = posts[0].body,
              let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let event = json["event"] as? [String: Any] else {
            return XCTFail("interrupt-event POST body did not parse")
        }
        XCTAssertEqual(event["type"] as? String, "user.interrupt")
        XCTAssertEqual(event["reason"] as? String, "client-terminated")
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
                return (response, try! JSONSerialization.data(withJSONObject: ["id": "sess_42"]))
            } else if path.hasSuffix("/events") {
                return (response, Data("{}".utf8))
            } else {
                return (response, Data("{}".utf8))
            }
        }
        let client = makeClient()
        let handle = try await client.startSession(seedMessage: "ping")
        try await client.appendEvent(sessionID: handle.sessionID, text: "midnight data point")
        _ = try? await client.fetchLatestAgentMessage(sessionID: handle.sessionID)
        // We intentionally swallow termination — PATCH returns `{}` on 200 which is fine.
        try await client.terminateSession(sessionID: handle.sessionID)

        XCTAssertFalse(StubProtocol.requests.isEmpty, "no requests captured")
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
}
