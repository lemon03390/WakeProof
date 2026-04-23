//
//  NightlySynthesisClientTests.swift
//  WakeProofTests
//
//  Mirrors the URLProtocol-stub pattern used in ClaudeAPIClientTests.
//  The stub class is file-local to keep its static handler state
//  isolated from ClaudeAPIClientTests.StubProtocol — no cross-file
//  sharing, no serialisation contract between the two files.
//

import XCTest
@testable import WakeProof

final class NightlySynthesisClientTests: XCTestCase {

    /// URLProtocol stub with file-scoped static handlers. Tests in this file
    /// must run serially (the scheme already disables parallel-testing globally
    /// per ClaudeAPIClientTests' note) — concurrent test methods would race on
    /// `handler` / `throwing`.
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

    private let endpoint = URL(string: "https://wakeproof-proxy-vercel.vercel.app/v1/messages")!

    private let sleep = SleepSnapshot(
        totalInBedMinutes: 420, awakeMinutes: 30,
        heartRateAvg: 58, heartRateMin: 48, heartRateMax: 75,
        heartRateSampleCount: 128, hasAppleWatchData: true,
        windowStart: Date(timeIntervalSince1970: 1_745_400_000),
        windowEnd: Date(timeIntervalSince1970: 1_745_425_200)
    )

    private func makeClient(
        handler: @escaping (URLRequest) -> (HTTPURLResponse, Data)
    ) -> NightlySynthesisClient {
        StubProtocol.handler = handler
        StubProtocol.throwing = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: config)
        return NightlySynthesisClient(
            session: session,
            endpoint: endpoint,
            model: "claude-sonnet-4-6",
            proxyToken: "test-token"
        )
    }

    private func makeThrowingClient(error: Error) -> NightlySynthesisClient {
        StubProtocol.handler = nil
        StubProtocol.throwing = error
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: config)
        return NightlySynthesisClient(
            session: session,
            endpoint: endpoint,
            model: "claude-sonnet-4-6",
            proxyToken: "test-token"
        )
    }

    // MARK: - Happy path

    func testHappyPathReturnsBriefingText() async throws {
        let expected = "You slept 7 hours. HR was steady. Today should feel normal. Ease into the morning."
        let client = makeClient { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            let body = try! JSONSerialization.data(withJSONObject: [
                "content": [["type": "text", "text": expected]]
            ])
            return (response, body)
        }

        let text = try await client.synthesize(
            sleep: sleep,
            memoryProfile: nil,
            priorBriefings: []
        )
        XCTAssertEqual(text, expected)
    }

    // MARK: - HTTP errors

    func testHTTP4xxMapsToHttpError() async {
        let client = makeClient { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil
            )!
            return (response, Data("bad token".utf8))
        }
        do {
            _ = try await client.synthesize(sleep: sleep, memoryProfile: nil, priorBriefings: [])
            XCTFail("expected httpError(401)")
        } catch NightlySynthesisError.httpError(let status, _) {
            XCTAssertEqual(status, 401)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - Transport errors

    func testTimeoutMapsToTimeoutError() async {
        let client = makeThrowingClient(error: URLError(.timedOut))
        do {
            _ = try await client.synthesize(sleep: sleep, memoryProfile: nil, priorBriefings: [])
            XCTFail("expected .timeout")
        } catch NightlySynthesisError.timeout {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - Decoding failures

    func testMalformedBodyMapsToDecodingFailed() async {
        let client = makeClient { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data("not json at all".utf8))
        }
        do {
            _ = try await client.synthesize(sleep: sleep, memoryProfile: nil, priorBriefings: [])
            XCTFail("expected .decodingFailed")
        } catch NightlySynthesisError.decodingFailed {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testEmptyContentArrayMapsToEmptyResponse() async {
        let client = makeClient { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            let body = try! JSONSerialization.data(withJSONObject: ["content": [] as [Any]])
            return (response, body)
        }
        do {
            _ = try await client.synthesize(sleep: sleep, memoryProfile: nil, priorBriefings: [])
            XCTFail("expected .emptyResponse")
        } catch NightlySynthesisError.emptyResponse {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - Short-circuit

    func testMissingProxyTokenShortCircuits() async {
        // Placeholder must match the sentinel in NightlySynthesisClient.synthesize exactly.
        // This duplication is intentional: if either drifts, this test fails loudly
        // in CI rather than letting a bogus token hit the wire.
        let client = NightlySynthesisClient(
            session: URLSession(configuration: .ephemeral),
            endpoint: endpoint,
            model: "claude-sonnet-4-6",
            proxyToken: "REPLACE_WITH_OPENSSL_RAND_HEX_32"
        )
        do {
            _ = try await client.synthesize(sleep: sleep, memoryProfile: nil, priorBriefings: [])
            XCTFail("expected .missingProxyToken")
        } catch NightlySynthesisError.missingProxyToken {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}
