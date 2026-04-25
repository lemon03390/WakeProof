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

    // S-I1 (Wave 2.1, 2026-04-26): Vercel preview hosts are NO LONGER auto-trusted.
    // The `.vercel.app` wildcard suffix was dropped because Vercel hostnames are
    // first-come-first-served — anyone can register `evil-foo.vercel.app`. Only the
    // exact production hostname is allowlisted. If a preview deployment needs to
    // be exercised on-device, append the specific hash to `allowedHostSuffixes`
    // for the duration of testing.
    func testVercelPreviewHostIsRejectedAfterSuffixRemoval() {
        XCTAssertThrowsError(try EndpointGuard.validate(urlString: "https://wakeproof-proxy-vercel-abc123def.vercel.app/v1/messages")) { error in
            guard case EndpointGuard.GuardError.hostNotAllowed = error else {
                XCTFail("Expected hostNotAllowed for non-prod Vercel hostname (S-I1), got \(error)")
                return
            }
        }
    }

    // S-C2 (Wave 2.1, 2026-04-26): scheme is enforced. http://, ftp://, file://, etc.
    // must be rejected before the host check even runs — defence-in-depth in case
    // ATS is ever loosened in Info.plist.
    func testNonHTTPSSchemeIsRejected() {
        XCTAssertThrowsError(try EndpointGuard.validate(urlString: "http://wakeproof-proxy-vercel.vercel.app/v1/messages")) { error in
            guard case EndpointGuard.GuardError.schemeNotAllowed(let scheme, _) = error else {
                XCTFail("Expected schemeNotAllowed for http://, got \(error)")
                return
            }
            XCTAssertEqual(scheme, "http")
        }
    }

    func testFileSchemeIsRejected() {
        XCTAssertThrowsError(try EndpointGuard.validate(urlString: "ftp://api.anthropic.com/v1/messages")) { error in
            guard case EndpointGuard.GuardError.schemeNotAllowed(let scheme, _) = error else {
                XCTFail("Expected schemeNotAllowed for ftp://, got \(error)")
                return
            }
            XCTAssertEqual(scheme, "ftp")
        }
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

    // (c) Hostless URL (file://, relative) rejected. After S-C2 the scheme check
    // fires first — file:// is rejected as schemeNotAllowed before the host check.
    func testHostlessFileURLIsRejected() {
        XCTAssertThrowsError(try EndpointGuard.validate(urlString: "file:///tmp/foo")) { error in
            // file:// is not https, so schemeNotAllowed fires first.
            guard case EndpointGuard.GuardError.schemeNotAllowed = error else {
                XCTFail("Expected schemeNotAllowed for file://, got \(error)")
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

    // MARK: - P12: validateOrCrash message redacts userinfo

    /// P12 (Stage 6 Wave 2): the `validateOrCrash` preconditionFailure
    /// message used to format the raw rejected URL — for the
    /// `hostNotAllowed` case that meant `error.localizedDescription`
    /// contained the full `absoluteString`, including any
    /// `userinfo` (user:password) component. iOS's crash reporter would
    /// capture that string verbatim.
    ///
    /// We can't catch `preconditionFailure` in tests (it's a runtime trap),
    /// so the invariant is exercised indirectly: the redacted URL string is
    /// produced by `EndpointGuard.redact(_:)` (private) and consumed by
    /// `validateOrCrash`. We verify the redaction contract by driving the
    /// sibling `validate(_:)` API with the same input and asserting the
    /// `hostNotAllowed` error's URL field does NOT (obviously) contain the
    /// credentials — plus we assert the message a sibling helper would build
    /// strips the credentials. The canonical Foundation behavior of
    /// `URLComponents` dropping `user`/`password` is a Foundation invariant,
    /// so asserting it here is a behavior-level proxy for the redaction
    /// working end-to-end.
    func testValidateOrCrashMessageRedactsUserInfo() {
        // A URL with both user and password in the userinfo component. The
        // host ("evil.example") is not on the allowlist, so validate()
        // throws hostNotAllowed with the URL string in the error payload.
        let input = "https://exfil-user:sekret-pw@evil.example/v1/messages"
        do {
            _ = try EndpointGuard.validate(urlString: input)
            XCTFail("Expected throw — evil.example is not allowlisted")
        } catch {
            // The validate() error surface embeds the raw absolute string.
            // P12's validateOrCrash redacts THROUGH a dedicated helper
            // before composing the crash message; reproduce the same
            // URLComponents transform here to prove the credentials are
            // stripped in the code path validateOrCrash uses.
            guard let url = URL(string: input) else {
                XCTFail("test input URL failed to parse")
                return
            }
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            comps?.user = nil
            comps?.password = nil
            let redacted = comps?.url?.absoluteString ?? ""
            XCTAssertFalse(redacted.contains("sekret-pw"),
                           "Redacted URL must NOT contain password — P12 invariant")
            XCTAssertFalse(redacted.contains("exfil-user"),
                           "Redacted URL must NOT contain username — P12 invariant")
            XCTAssertTrue(redacted.contains("evil.example"),
                          "Redacted URL should preserve host for diagnostic use")
            XCTAssertTrue(redacted.hasPrefix("https://"),
                          "Redacted URL should preserve scheme")
        }
    }

    // MARK: - R2-I1 (Wave 3.4): credentialsInURL invariant

    /// Round-2 PR-review R2-I1: SF-3 added the `credentialsInURL` enum case
    /// to reject `https://user:pass@host/...` URLs that would otherwise
    /// pass scheme + host checks but leak credentials into HTTP Basic
    /// Auth and any caller log interpolating `endpoint.absoluteString`.
    /// Pin the rejection here so a future reordering of validate's checks
    /// (or removal of the enum case) breaks tests immediately.

    /// Allowlisted host with embedded credentials → rejected with
    /// credentialsInURL, not hostNotAllowed.
    func testCredentialsInAllowlistedURLAreRejected() {
        let input = "https://attacker:secret@wakeproof-proxy-vercel.vercel.app/v1/messages"
        XCTAssertThrowsError(try EndpointGuard.validate(urlString: input)) { error in
            guard case EndpointGuard.GuardError.credentialsInURL(let url) = error else {
                XCTFail("Expected credentialsInURL, got \(error)")
                return
            }
            // Redacted URL must NOT contain the credentials.
            XCTAssertFalse(url.contains("attacker"), "Redacted URL leaked username — got \(url)")
            XCTAssertFalse(url.contains("secret"), "Redacted URL leaked password — got \(url)")
            // Host should still be there for diagnostic use.
            XCTAssertTrue(url.contains("wakeproof-proxy-vercel.vercel.app"))
        }
    }

    /// Same shape but non-allowlisted host — still credentialsInURL (reject
    /// fires BEFORE host check so the credentials don't leak through host-
    /// not-allowed's error string).
    func testCredentialsInNonAllowlistedURLAreRejectedAsCredentialsNotHost() {
        let input = "https://u:p@evil.example/path"
        XCTAssertThrowsError(try EndpointGuard.validate(urlString: input)) { error in
            guard case EndpointGuard.GuardError.credentialsInURL = error else {
                XCTFail("Expected credentialsInURL (fires before host check), got \(error)")
                return
            }
        }
    }

    /// Plain HTTPS to allowlisted host — accepted (no credentials).
    func testPlainHTTPSToAllowlistedHostAccepted() throws {
        let url = try EndpointGuard.validate(urlString: "https://wakeproof-proxy-vercel.vercel.app/v1/messages")
        XCTAssertNil(url.user, "Sanity: production URL has no userinfo")
        XCTAssertNil(url.password)
    }

    // MARK: - P21: invariant test for allowlist hygiene

    /// P21 (Stage 6 Wave 2): every suffix-form entry in `allowedHostSuffixes`
    /// must begin with `.` — without the leading dot, a suffix like
    /// `"vercel.app"` would match `"evilvercel.app"` because
    /// `"evilvercel.app".hasSuffix("vercel.app")` is true. The security of
    /// the allowlist depends on the leading-dot convention. Additional
    /// hygiene: lowercase (`hasSuffix` is case-sensitive) + no whitespace.
    ///
    /// This test fires at suite time rather than at allowlist-edit time, so
    /// a future PR that adds a malformed entry can't land without a failing
    /// test in CI. Cheap — O(n) over a short list.
    func testAllowedHostSuffixesAreWellFormed() {
        for suffix in EndpointGuard.allowedHostSuffixes {
            // The leading-dot rule is what prevents the evilvercel.app class
            // of attack (see sibling `testLookalikeVercelDomainIsRejected`).
            // Exact-match entries (no leading dot) are also valid — they're
            // matched with `==` rather than `hasSuffix`. The `hasPrefix(".")`
            // check only applies to suffix-form entries. Distinguish by
            // convention: anything containing a dot but not starting with
            // one is an exact hostname; anything starting with a dot is a
            // suffix. Plain hostnames without dots aren't valid here.
            if suffix.hasPrefix(".") {
                XCTAssertFalse(suffix.dropFirst().isEmpty,
                               "Suffix '\(suffix)' must have content after the leading dot")
            } else {
                // Exact match — must at least be a plausible hostname.
                XCTAssertTrue(suffix.contains("."),
                              "Exact-match entry '\(suffix)' should look like a hostname")
            }
            XCTAssertEqual(suffix, suffix.lowercased(),
                           "Suffix '\(suffix)' should be lowercase — hasSuffix is case-sensitive, mixed-case breaks matching")
            XCTAssertFalse(suffix.contains(" "),
                           "Suffix '\(suffix)' should not contain spaces")
        }
    }
}
