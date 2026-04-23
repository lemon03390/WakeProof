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

    // MARK: - Layer 2 v3 prompt template

    func testV3SystemPromptMentionsMemoryContext() {
        let system = VisionPromptTemplate.v3.systemPrompt()
        XCTAssertTrue(system.contains("<memory_context>"), "v3 system prompt must tell the model memory_context may appear")
    }

    func testV3SystemPromptMentionsMemoryUpdate() {
        let system = VisionPromptTemplate.v3.systemPrompt()
        XCTAssertTrue(system.contains("memory_update"), "v3 system prompt must mention the optional memory_update output")
    }

    func testV3UserPromptIncludesMemoryBlockWhenProvided() {
        let text = VisionPromptTemplate.v3.userPrompt(
            baselineLocation: "kitchen",
            antiSpoofInstruction: nil,
            memoryContext: "<memory_context>fake block</memory_context>"
        )
        XCTAssertTrue(text.contains("<memory_context>fake block</memory_context>"))
    }

    func testV3UserPromptOmitsMemoryWhenNil() {
        let withNil = VisionPromptTemplate.v3.userPrompt(
            baselineLocation: "kitchen",
            antiSpoofInstruction: nil,
            memoryContext: nil
        )
        XCTAssertFalse(withNil.contains("<memory_context>"), "nil memoryContext must produce no memory block in v3 user prompt")
    }

    func testV2IgnoresMemoryContextParameter() {
        // Ensures passing memoryContext to v2 does not silently mutate the output —
        // the v2 branch must be byte-identical whether memoryContext is nil or set.
        let noMem = VisionPromptTemplate.v2.userPrompt(
            baselineLocation: "kitchen", antiSpoofInstruction: nil, memoryContext: nil
        )
        let withMem = VisionPromptTemplate.v2.userPrompt(
            baselineLocation: "kitchen", antiSpoofInstruction: nil, memoryContext: "<memory_context>IGNORED</memory_context>"
        )
        XCTAssertEqual(noMem, withMem, "v2 must ignore the memoryContext parameter")
    }

    func testV1IgnoresMemoryContextParameter() {
        let noMem = VisionPromptTemplate.v1.userPrompt(
            baselineLocation: "kitchen", antiSpoofInstruction: nil, memoryContext: nil
        )
        let withMem = VisionPromptTemplate.v1.userPrompt(
            baselineLocation: "kitchen", antiSpoofInstruction: nil, memoryContext: "<memory_context>IGNORED</memory_context>"
        )
        XCTAssertEqual(noMem, withMem, "v1 must ignore the memoryContext parameter")
    }

    // MARK: - Layer 2 ClaudeAPIClient wiring

    func testDefaultTemplateIsV3() {
        let client = ClaudeAPIClient()
        XCTAssertEqual(client.promptTemplate, .v3)
    }

    func testFiveArgVerifyForwardsMemoryContextToUserMessage() async throws {
        let memoryBlock = "<memory_context>MEMORY_MARKER</memory_context>"
        let bodyCapture = try await performStubbedVerify(memoryContext: memoryBlock)
        XCTAssertTrue(bodyCapture.contains("MEMORY_MARKER"),
                      "memoryContext must be injected into the user message on the 5-arg verify path")
    }

    func testFourArgVerifyProducesNoMemoryBlock() async throws {
        let bodyCapture = try await performStubbedVerifyLegacy()
        // The v3 system prompt mentions `<memory_context>` in prose (describing what MAY
        // appear), so we can't assert on the opening tag alone. The closing tag
        // `</memory_context>` only appears when the caller actually injected a block —
        // that's the true signal we want to assert is absent on the 4-arg legacy path.
        XCTAssertFalse(bodyCapture.contains("</memory_context>"),
                       "4-arg (legacy) verify path must produce a user prompt with no memory block")
    }

    // MARK: helpers
    private func performStubbedVerify(memoryContext: String?) async throws -> String {
        let captureBox = CaptureBox()
        let client = makeClientCapturing(box: captureBox, responseJSON: happyBodyJSON)
        _ = try await client.verify(
            baselineJPEG: Data(repeating: 0xAA, count: 16),
            stillJPEG: Data(repeating: 0xBB, count: 16),
            baselineLocation: "kitchen",
            antiSpoofInstruction: nil,
            memoryContext: memoryContext
        )
        return captureBox.capturedBodyString ?? ""
    }

    private func performStubbedVerifyLegacy() async throws -> String {
        let captureBox = CaptureBox()
        let client = makeClientCapturing(box: captureBox, responseJSON: happyBodyJSON)
        _ = try await client.verify(
            baselineJPEG: Data(repeating: 0xAA, count: 16),
            stillJPEG: Data(repeating: 0xBB, count: 16),
            baselineLocation: "kitchen",
            antiSpoofInstruction: nil
        )
        return captureBox.capturedBodyString ?? ""
    }

    private final class CaptureBox { var capturedBodyString: String? }

    private func makeClientCapturing(box: CaptureBox, responseJSON: [String: Any]) -> ClaudeAPIClient {
        StubProtocol.handler = { request in
            if let body = request.httpBody ?? request.bodyStreamAsData() {
                box.capturedBodyString = String(data: body, encoding: .utf8)
            }
            let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            let data = try! JSONSerialization.data(withJSONObject: responseJSON)
            return (http, data)
        }
        StubProtocol.throwing = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: config)
        return ClaudeAPIClient(session: session, proxyToken: "test-token", model: "claude-opus-4-7")
    }
}

/// URLRequest helper: URLSession sometimes passes the body via bodyStream instead of
/// httpBody depending on how URLRequest was built. This extension normalises both paths
/// so the capture box reliably sees the bytes.
extension URLRequest {
    func bodyStreamAsData() -> Data? {
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
