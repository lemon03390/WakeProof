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
        return ClaudeAPIClient(session: session, apiKey: "sk-ant-test-key", model: "claude-opus-4-7")
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

    func testMissingAPIKeyShortCircuits() async {
        // Placeholder must match the sentinel in ClaudeAPIClient.verify exactly —
        // underscore, not hyphen. This duplication is intentional: if either drifts
        // this test fails loudly in CI rather than letting a bogus key hit the wire.
        let client = ClaudeAPIClient(
            session: URLSession(configuration: .ephemeral),
            apiKey: "sk-ant-REPLACE_ME",
            model: "claude-opus-4-7"
        )
        do {
            _ = try await client.verify(baselineJPEG: Data(), stillJPEG: Data(), baselineLocation: "x", antiSpoofInstruction: nil)
            XCTFail("expected missingAPIKey")
        } catch ClaudeAPIError.missingAPIKey {
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
        let client = ClaudeAPIClient(session: URLSession(configuration: config), apiKey: "sk-ant-test", model: "claude-opus-4-7")
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
        let client = ClaudeAPIClient(session: URLSession(configuration: config), apiKey: "sk-ant-test", model: "claude-opus-4-7")
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
}
