//
//  EndpointGuardTests.swift
//  WakeProofTests
//
//  Wave 2.1 / R4 coverage: the shared hostname allowlist previously duplicated
//  inside `ClaudeAPIClient.defaultEndpoint` (and silently absent from
//  `OvernightAgentClient` + `NightlySynthesisClient`) now funnels through
//  `EndpointGuard.validate`. These tests pin:
//    a) a valid Vercel-hosted URL is accepted and returned unchanged
//    b) a wrong host is rejected with the specific `hostNotAllowed` case
//    c) a malformed URL string is rejected with `malformedURL` (not a crash)
//
//  Note: we exercise `EndpointGuard` directly rather than the client defaults —
//  the client `preconditionFailure`s on mismatch to preserve launch-time
//  fail-closed behaviour, which isn't catchable in XCTest. The throwing
//  surface this file exercises is the code path consumed by those clients.
//

import XCTest
@testable import WakeProof

final class EndpointGuardTests: XCTestCase {

    // (a) Valid host accepted — production Vercel proxy host.
    func testValidVercelProxyHostIsAccepted() throws {
        let url = try EndpointGuard.validate(urlString: "https://wakeproof-proxy-vercel.vercel.app/v1/messages")
        XCTAssertEqual(url.host, "wakeproof-proxy-vercel.vercel.app")
        XCTAssertEqual(url.path, "/v1/messages")
    }

    // (a) Valid host accepted — Anthropic direct fallback (simulator path).
    func testValidAnthropicDirectHostIsAccepted() throws {
        let url = try EndpointGuard.validate(urlString: "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(url.host, "api.anthropic.com")
    }

    // (a) Valid host accepted — Vercel preview host (suffix match).
    func testValidVercelPreviewHostIsAcceptedViaSuffixMatch() throws {
        let url = try EndpointGuard.validate(urlString: "https://wakeproof-proxy-vercel-abc123def.vercel.app/v1/messages")
        XCTAssertEqual(url.host, "wakeproof-proxy-vercel-abc123def.vercel.app")
    }

    // (b) Wrong host rejected with the specific error case.
    func testWrongHostRejectedWithHostNotAllowedError() {
        XCTAssertThrowsError(try EndpointGuard.validate(urlString: "https://evil.example.com/v1/messages")) { error in
            guard case EndpointGuard.GuardError.hostNotAllowed(let host, let urlString) = error else {
                XCTFail("Expected hostNotAllowed, got \(error)")
                return
            }
            XCTAssertEqual(host, "evil.example.com")
            XCTAssertEqual(urlString, "https://evil.example.com/v1/messages")
        }
    }

    // (b) Suffix-matching doesn't allow bypass via lookalike domain.
    // ".vercel.app" must not match "evilvercel.app" — the leading dot requirement
    // in the allowlist prevents this class of attack.
    func testLookalikeVercelDomainIsRejected() {
        XCTAssertThrowsError(try EndpointGuard.validate(urlString: "https://evilvercel.app/v1/messages")) { error in
            guard case EndpointGuard.GuardError.hostNotAllowed(let host, _) = error else {
                XCTFail("Expected hostNotAllowed for evilvercel.app, got \(error)")
                return
            }
            XCTAssertEqual(host, "evilvercel.app")
        }
    }

    // (c) Malformed URL rejected with the specific error case, not a crash.
    func testMalformedURLRejectedWithMalformedError() {
        XCTAssertThrowsError(try EndpointGuard.validate(urlString: "not a url")) { error in
            // "not a url" is either rejected by URL(string:) or by the no-host check —
            // both paths land on GuardError.malformedURL.
            guard case EndpointGuard.GuardError.malformedURL = error else {
                XCTFail("Expected malformedURL, got \(error)")
                return
            }
        }
    }

    // (c) Hostless URL (file://, relative) rejected with malformedURL.
    func testHostlessURLIsRejected() {
        // URL(string: "file:///tmp/foo") parses successfully but has no host —
        // allowlist suffix matching with an empty string would spuriously match
        // "" against any suffix, hence the explicit empty-host guard.
        XCTAssertThrowsError(try EndpointGuard.validate(urlString: "file:///tmp/foo")) { error in
            guard case EndpointGuard.GuardError.malformedURL = error else {
                XCTFail("Expected malformedURL for file://, got \(error)")
                return
            }
        }
    }

    // errorDescription includes the offending host so on-device logs can triage
    // mis-routed traffic without digging into the enum case manually.
    func testHostNotAllowedErrorDescriptionMentionsHost() {
        do {
            _ = try EndpointGuard.validate(urlString: "https://pwn.example/v1/messages")
            XCTFail("Expected throw")
        } catch {
            let description = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertTrue(description.contains("pwn.example"), "description should mention rejected host, got: \(description)")
        }
    }
}
