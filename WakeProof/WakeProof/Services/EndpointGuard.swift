//
//  EndpointGuard.swift
//  WakeProof
//
//  Single source of truth for the hostname allowlist enforced on every
//  outbound Claude-proxy call. Before Wave 2.1 the allowlist lived only
//  inside `ClaudeAPIClient.defaultEndpoint`; `OvernightAgentClient` and
//  `NightlySynthesisClient` derived their base URLs from the same
//  `Secrets.claudeEndpoint` but skipped the host check entirely, so a
//  tampered Secrets value would silently route overnight agent traffic +
//  nightly synthesis to an attacker-controlled host while vision
//  verification still crashed loudly. This file centralises the check and
//  is called by all three clients at launch (preconditionFailure on
//  mismatch — same-fail-mode as the original ClaudeAPIClient guard).
//
//  Adding a new allowed host: append to `allowedHostSuffixes` and document
//  the reason in a one-liner comment. Prefer exact hostnames over wildcard
//  suffixes — the ".vercel.app" suffix is the one concession we make for
//  preview deployment URLs, which change on every PR. If the suffix model
//  ever feels too loose, switch to an explicit hash-per-deployment allow
//  list.
//
//  Not used for outbound auth — auth is the `x-wakeproof-token` header
//  validated by the proxy. This guard only prevents the client from
//  talking to hosts other than our infrastructure in the first place.
//

import Foundation

/// Hostname allowlist guard for outbound Claude-proxy calls.
///
/// `nonisolated` so callers on any actor (including `OvernightAgentClient`'s
/// `nonisolated` static init) can invoke `validate` without actor hops.
/// The enum has no stored state — all methods are pure.
nonisolated enum EndpointGuard {
    /// Hosts the iOS client is permitted to reach.
    ///
    /// Entries are matched either as exact hostnames (e.g. `api.anthropic.com`)
    /// or as DNS suffixes with a leading dot (e.g. `.vercel.app` matches
    /// `wakeproof-proxy-vercel.vercel.app` and any preview hash). Suffixes must
    /// start with a `.` so `.vercel.app` does not accidentally match
    /// `evilvercel.app`.
    ///
    /// Keep ordering alphabetical for diff stability; the guard's time complexity
    /// is O(n) over this list and the list is small.
    static let allowedHostSuffixes: [String] = [
        "api.anthropic.com",                            // Direct-to-Anthropic fallback (simulator + sanity probes)
        ".aspiratcm.com",                               // Cloudflare Worker archive domain (retained for rollback)
        ".vercel.app",                                  // Any Vercel-issued hostname (prod + preview hashes)
        "wakeproof-proxy-vercel.vercel.app",            // Current production proxy (explicit for clarity)
    ]

    enum GuardError: LocalizedError {
        case hostNotAllowed(host: String, url: String)
        case malformedURL(urlString: String)

        var errorDescription: String? {
            switch self {
            case .hostNotAllowed(let host, _):
                return "Endpoint host '\(host)' is not in the WakeProof allowlist. " +
                    "Update Secrets.swift or add the host to EndpointGuard.allowedHostSuffixes."
            case .malformedURL(let urlString):
                return "Endpoint URL could not be parsed: '\(urlString)'."
            }
        }
    }

    /// Validate that a URL's host is in the allowlist. Returns the URL unchanged
    /// on success; throws `GuardError.hostNotAllowed` otherwise.
    ///
    /// Call at application-launch time from each client's default endpoint
    /// derivation (e.g. `private static let defaultEndpoint: URL = { ... }()`).
    /// Throwing (rather than `preconditionFailure`) lets callers decide whether
    /// a misconfigured endpoint should crash the process or degrade gracefully —
    /// in current WakeProof the call sites wrap this in a `preconditionFailure`
    /// to preserve the original fail-closed behaviour, but tests can exercise the
    /// throwing path directly.
    static func validate(_ url: URL) throws -> URL {
        guard let host = url.host, !host.isEmpty else {
            throw GuardError.malformedURL(urlString: url.absoluteString)
        }
        let allowed = allowedHostSuffixes.contains { suffix in
            if suffix.hasPrefix(".") {
                // Suffix form: match subdomains of the base (".vercel.app" matches
                // "foo.vercel.app" but not "vercel.app" or "evilvercel.app").
                return host.hasSuffix(suffix)
            }
            // Exact-match form.
            return host == suffix
        }
        guard allowed else {
            throw GuardError.hostNotAllowed(host: host, url: url.absoluteString)
        }
        return url
    }

    /// Convenience: parse a URL string and validate in one step. Separate because
    /// many call sites already have a pre-parsed `URL` from other Foundation APIs.
    static func validate(urlString: String) throws -> URL {
        guard let url = URL(string: urlString) else {
            throw GuardError.malformedURL(urlString: urlString)
        }
        return try validate(url)
    }

    /// SR7 (Stage 4): the original static-init pattern at all three client
    /// call sites was identical: `do { return try validate(...) } catch {
    /// preconditionFailure("<label> rejected by EndpointGuard: ...") }`.
    /// This helper collapses that boilerplate to a single call so the
    /// preconditionFailure message stays uniformly formatted and the
    /// fail-closed invariant can't diverge by accident.
    ///
    /// `label` is prefixed to the crash message so the logged reason names
    /// which client hit the wall ("Vision endpoint", "Overnight agent",
    /// "Nightly synthesis"). Crash is `preconditionFailure` (same as before)
    /// — an invalid Secrets value is a programmer error on deploy, not a
    /// recoverable runtime error.
    static func validateOrCrash(urlString: String, label: String) -> URL {
        do {
            return try validate(urlString: urlString)
        } catch {
            preconditionFailure("\(label) rejected by EndpointGuard: \(error.localizedDescription)")
        }
    }
}
