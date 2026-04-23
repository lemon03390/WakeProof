//
//  ClaudeAPIClientTests.swift
//  WakeProofTests
//

import XCTest
@testable import WakeProof

final class ClaudeAPIClientTests: XCTestCase {

    /// URLProtocol stub: registers class-level handlers for each test, returns whatever the
    /// test wires up. No real network is ever hit — critical because unit tests must not
    /// burn API credits.
    final class StubProtocol: URLProtocol {
        nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?
        nonisolated(unsafe) static var throwing: Error?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
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
    }

    private func makeClient(handler: @escaping (URLRequest) -> (HTTPURLResponse, Data)) -> ClaudeAPIClient {
        StubProtocol.handler = handler
        StubProtocol.throwing = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: config)
        return ClaudeAPIClient(session: session, proxyToken: "test-token", model: "claude-opus-4-7")
    }

    private let happyBodyJSON: [String: Any] = [
        "content": [
            [
                "type": "text",
                "text": """
                {
                  "same_location": true,
                  "person_upright": true,
                  "eyes_open": true,
                  "appears_alert": true,
                  "lighting_suggests_room_lit": true,
                  "confidence": 0.9,
                  "reasoning": "Same kitchen; upright; alert.",
                  "spoofing_ruled_out": ["photo-of-photo", "mannequin", "deepfake"],
                  "verdict": "VERIFIED"
                }
                """
            ]
        ]
    ]

    func testHTTP200DecodesVerifiedResult() async throws {
        let client = makeClient { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = try! JSONSerialization.data(withJSONObject: self.happyBodyJSON)
            return (response, body)
        }
        let result = try await client.verify(
            baselineJPEG: Data([0xFF, 0xD8, 0xFF]),
            stillJPEG: Data([0xFF, 0xD8, 0xFF]),
            baselineLocation: "kitchen",
            antiSpoofInstruction: nil
        )
        XCTAssertEqual(result.verdict, .verified)
    }

    func testHTTP401MapsToHTTPError() async {
        let client = makeClient { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data("bad key".utf8))
        }
        do {
            _ = try await client.verify(baselineJPEG: Data([0xFF]), stillJPEG: Data([0xFF]), baselineLocation: "kitchen", antiSpoofInstruction: nil)
            XCTFail("expected httpError(401)")
        } catch ClaudeAPIError.httpError(let status, _) {
            XCTAssertEqual(status, 401)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testMissingProxyTokenShortCircuits() async {
        // Placeholder must match the sentinel in ClaudeAPIClient.verify exactly.
        // This duplication is intentional: if either drifts, this test fails
        // loudly in CI rather than letting a bogus token hit the wire.
        let client = ClaudeAPIClient(
            session: URLSession(configuration: .ephemeral),
            proxyToken: "REPLACE_WITH_OPENSSL_RAND_HEX_32",
            model: "claude-opus-4-7"
        )
        do {
            _ = try await client.verify(baselineJPEG: Data(), stillJPEG: Data(), baselineLocation: "x", antiSpoofInstruction: nil)
            XCTFail("expected missingProxyToken")
        } catch ClaudeAPIError.missingProxyToken {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testTimeoutMapsToTimeoutError() async {
        StubProtocol.handler = nil
        StubProtocol.throwing = URLError(.timedOut)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let client = ClaudeAPIClient(session: URLSession(configuration: config), proxyToken: "test-token", model: "claude-opus-4-7")
        do {
            _ = try await client.verify(baselineJPEG: Data(), stillJPEG: Data(), baselineLocation: "x", antiSpoofInstruction: nil)
            XCTFail("expected .timeout")
        } catch ClaudeAPIError.timeout {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testTransportErrorMapsToTransportFailed() async {
        StubProtocol.handler = nil
        StubProtocol.throwing = URLError(.notConnectedToInternet)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let client = ClaudeAPIClient(session: URLSession(configuration: config), proxyToken: "test-token", model: "claude-opus-4-7")
        do {
            _ = try await client.verify(baselineJPEG: Data(), stillJPEG: Data(), baselineLocation: "x", antiSpoofInstruction: nil)
            XCTFail("expected .transportFailed")
        } catch ClaudeAPIError.transportFailed {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testMalformedJSONBodyMapsToDecodingFailed() async {
        let client = makeClient { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("not json at all".utf8))
        }
        do {
            _ = try await client.verify(baselineJPEG: Data(), stillJPEG: Data(), baselineLocation: "x", antiSpoofInstruction: nil)
            XCTFail("expected .decodingFailed")
        } catch ClaudeAPIError.decodingFailed {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testVerdictUnparseableInsideTextBlockMapsToDecodingFailed() async {
        let client = makeClient { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = try! JSONSerialization.data(withJSONObject: [
                "content": [[ "type": "text", "text": "sorry I cannot comply" ]]
            ])
            return (response, body)
        }
        do {
            _ = try await client.verify(baselineJPEG: Data(), stillJPEG: Data(), baselineLocation: "x", antiSpoofInstruction: nil)
            XCTFail("expected .decodingFailed")
        } catch ClaudeAPIError.decodingFailed {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - R11: malformed Anthropic response shapes

    /// Anthropic adds a new block type (e.g., extended thinking) in a future model
    /// bump and pushes a response with `content[0].type != "text"`. Our parser scans
    /// for the first text block — if none, decodingFailed fires.
    func testResponseWithOnlyToolUseBlockMapsToDecodingFailed() async {
        let client = makeClient { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = try! JSONSerialization.data(withJSONObject: [
                "content": [[ "type": "tool_use", "id": "x", "name": "y", "input": [:] ]]
            ])
            return (response, body)
        }
        do {
            _ = try await client.verify(baselineJPEG: Data(), stillJPEG: Data(), baselineLocation: "x", antiSpoofInstruction: nil)
            XCTFail("expected .decodingFailed")
        } catch ClaudeAPIError.decodingFailed {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    /// Empty content array — Anthropic SHOULD never do this on a successful call,
    /// but if a bug slips through, we must not crash.
    func testResponseWithEmptyContentArrayMapsToDecodingFailed() async {
        let client = makeClient { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = try! JSONSerialization.data(withJSONObject: ["content": [] as [Any]])
            return (response, body)
        }
        do {
            _ = try await client.verify(baselineJPEG: Data(), stillJPEG: Data(), baselineLocation: "x", antiSpoofInstruction: nil)
            XCTFail("expected .decodingFailed")
        } catch ClaudeAPIError.decodingFailed {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    /// Content key missing entirely.
    func testResponseMissingContentKeyMapsToDecodingFailed() async {
        let client = makeClient { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = try! JSONSerialization.data(withJSONObject: ["id": "msg_123"])
            return (response, body)
        }
        do {
            _ = try await client.verify(baselineJPEG: Data(), stillJPEG: Data(), baselineLocation: "x", antiSpoofInstruction: nil)
            XCTFail("expected .decodingFailed")
        } catch ClaudeAPIError.decodingFailed {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    /// R2: proxy upload_timeout / body_too_large / upstream_fetch_failed responses
    /// must map to `.transportFailed`, not `.httpError`. User-facing copy hinges on this.
    func testProxyUploadTimeoutMapsToTransportFailed() async {
        let client = makeClient { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 408, httpVersion: nil, headerFields: nil)!
            let body = try! JSONSerialization.data(withJSONObject: [
                "error": ["type": "upload_timeout", "message": "Proxy upload_timeout before reaching Anthropic"]
            ])
            return (response, body)
        }
        do {
            _ = try await client.verify(baselineJPEG: Data([0xFF]), stillJPEG: Data([0xFF]), baselineLocation: "x", antiSpoofInstruction: nil)
            XCTFail("expected .transportFailed")
        } catch ClaudeAPIError.transportFailed {
            // expected — user sees "Couldn't reach Claude" which is the accurate diagnosis
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testProxyUpstreamFetchFailedMapsToTransportFailed() async {
        let client = makeClient { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 502, httpVersion: nil, headerFields: nil)!
            let body = try! JSONSerialization.data(withJSONObject: [
                "error": ["type": "upstream_fetch_failed", "message": "TLS handshake failed to api.anthropic.com"]
            ])
            return (response, body)
        }
        do {
            _ = try await client.verify(baselineJPEG: Data([0xFF]), stillJPEG: Data([0xFF]), baselineLocation: "x", antiSpoofInstruction: nil)
            XCTFail("expected .transportFailed")
        } catch ClaudeAPIError.transportFailed {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    /// A plain HTTP error without the proxy's JSON error envelope must still be classified
    /// as httpError — we only special-case the recognised proxy envelope types.
    func testPlainHTTP500WithoutProxyEnvelopeStaysHttpError() async {
        let client = makeClient { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, Data("upstream error".utf8))
        }
        do {
            _ = try await client.verify(baselineJPEG: Data([0xFF]), stillJPEG: Data([0xFF]), baselineLocation: "x", antiSpoofInstruction: nil)
            XCTFail("expected .httpError")
        } catch ClaudeAPIError.httpError(let status, _) {
            XCTAssertEqual(status, 500)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}
