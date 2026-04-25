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
//  suffixes. After S-I1 (Wave 2.1) the wildcard `.vercel.app` was removed
//  because Vercel hostnames are first-come-first-served; any attacker who
//  can deploy a `wakeproof-clone.vercel.app` would have passed the suffix
//  check. Preview deployments are no longer auto-trusted. If you need to
//  test against a preview, append the specific hash for the duration of
//  testing and remove before merge.
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
    /// Entries are matched either as exact hostnames (e.g. `api.anthropic.com`,
    /// `wakeproof-proxy-vercel.vercel.app`) or as DNS suffixes with a leading
    /// dot (e.g. `.aspiratcm.com` matches `wakeproof.aspiratcm.com`). Suffixes
    /// MUST start with a `.` so `.aspiratcm.com` does not accidentally match
    /// `evilaspiratcm.com`.
    ///
    /// S-I1 history: a `.vercel.app` wildcard previously lived here; removed
    /// because Vercel hostnames are first-come-first-served and any attacker
    /// who deploys `evil-foo.vercel.app` would have passed the suffix check.
    /// Prefer exact hostnames; suffixes are reserved for DNS zones we control.
    ///
    /// Keep ordering alphabetical for diff stability; the guard's time complexity
    /// is O(n) over this list and the list is small.
    /// S-I1 (Wave 2.1, 2026-04-26): wildcard `.vercel.app` removed. Vercel
    /// hostnames are first-come-first-served; any attacker who can deploy a
    /// `evil-foo.vercel.app` would have passed the suffix check. Replaced with
    /// the production hostname only. Preview-URL deployments (which change per
    /// PR) are no longer auto-trusted; if needed, append the specific preview
    /// hash here per environment, or use a build-config to swap allowlists.
    /// Round-1 PR-review I-4 (Wave 3.2, 2026-04-26): tightened `.aspiratcm.com`
    /// from suffix-form to exact `wakeproof.aspiratcm.com`. The wildcard
    /// suffix would have allowed any subdomain (e.g. `evil.aspiratcm.com`)
    /// if the team's DNS provider were ever compromised. The archive Cloudflare
    /// Worker only ever lived at the `wakeproof.` subdomain — pin to that.
    static let allowedHostSuffixes: [String] = [
        "api.anthropic.com",                            // Direct-to-Anthropic fallback (simulator + sanity probes)
        "wakeproof.aspiratcm.com",                      // Cloudflare Worker archive — exact subdomain (post-I-4)
        "wakeproof-proxy-vercel.vercel.app",            // Current production proxy (exact hostname only — see S-I1)
    ]

    enum GuardError: LocalizedError {
        case hostNotAllowed(host: String, url: String)
        case malformedURL(urlString: String)
        case schemeNotAllowed(scheme: String, url: String)
        /// Round-1 PR-review SF-3 (Wave 3.1, 2026-04-26): URLs of the form
        /// `https://user:pass@host/...` parse cleanly + match the host allowlist
        /// + use HTTPS — but the embedded credentials would land in URL-Request
        /// HTTP Basic Auth and in any caller log that interpolates
        /// `endpoint.absoluteString`. Rejected unconditionally to remove the
        /// silent credential-leak surface.
        case credentialsInURL(url: String)

        var errorDescription: String? {
            switch self {
            case .hostNotAllowed(let host, _):
                return "Endpoint host '\(host)' is not in the WakeProof allowlist. " +
                    "Update Secrets.swift or add the host to EndpointGuard.allowedHostSuffixes."
            case .malformedURL(let urlString):
                return "Endpoint URL could not be parsed: '\(urlString)'."
            case .schemeNotAllowed(let scheme, _):
                return "Endpoint scheme '\(scheme)' is not allowed. " +
                    "Only 'https' is accepted — plaintext or non-HTTP schemes are rejected to prevent token leakage."
            case .credentialsInURL:
                return "Endpoint URL contains embedded credentials (user:password@). " +
                    "Strip them from Secrets.swift — credentials in URL leak into HTTP Basic Auth and crash logs."
            }
        }
    }

    /// Validate that a URL's scheme is HTTPS and host is in the allowlist. Returns
    /// the URL unchanged on success; throws on any mismatch.
    ///
    /// Call at application-launch time from each client's default endpoint
    /// derivation (e.g. `private static let defaultEndpoint: URL = { ... }()`).
    /// Throwing (rather than `preconditionFailure`) lets callers decide whether
    /// a misconfigured endpoint should crash the process or degrade gracefully —
    /// in current WakeProof the call sites wrap this in a `preconditionFailure`
    /// to preserve the original fail-closed behaviour, but tests can exercise the
    /// throwing path directly.
    ///
    /// S-C2 (Wave 2.1, 2026-04-26): scheme is now enforced. ATS will already block
    /// `http://` to public hosts on a stock build, but ATS is a deployable
    /// configuration — a future Info.plist edit could disable it. The guard's
    /// whole job is to fail before that becomes load-bearing. Accepts only
    /// `https`; rejects `http`, `ftp`, `file`, `data`, etc.
    ///
    /// Order: malformed (missing scheme entirely) → wrong scheme → credentials
    /// embedded → malformed host → host-not-allowed. A URL with no scheme at
    /// all is malformed input; one with a concrete-but-wrong scheme is a
    /// deliberate reject path so the error surface stays distinct. Credentials-
    /// in-URL (`https://u:p@host`) is rejected before host check so the error
    /// payload (which embeds `url.absoluteString`) goes through `redact(_:)`
    /// at the call site — see SF-3 / SF-4.
    static func validate(_ url: URL) throws -> URL {
        // No scheme at all = malformed input (URL parsed but has nothing).
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else {
            throw GuardError.malformedURL(urlString: url.absoluteString)
        }
        // Concrete-but-wrong scheme = schemeNotAllowed.
        guard scheme == "https" else {
            throw GuardError.schemeNotAllowed(scheme: scheme, url: url.absoluteString)
        }
        // SF-3 (Wave 3.1): reject embedded credentials so they don't become
        // part of the live `endpoint` URL. Use the redacted form in the error
        // payload so the credentials don't leak into the thrown error either.
        if url.user != nil || url.password != nil {
            throw GuardError.credentialsInURL(url: redact(url))
        }
        guard let host = url.host, !host.isEmpty else {
            throw GuardError.malformedURL(urlString: url.absoluteString)
        }
        let allowed = allowedHostSuffixes.contains { suffix in
            if suffix.hasPrefix(".") {
                // Suffix form: match subdomains of the base (".aspiratcm.com" matches
                // "wakeproof.aspiratcm.com" but not "aspiratcm.com" or "evilaspiratcm.com").
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
    ///
    /// P12 (Stage 6 Wave 2): the crash message used to embed
    /// `error.localizedDescription`, which for the `hostNotAllowed` case
    /// contains the raw rejected URL (the `validate(_:)` throw wraps the
    /// full `url.absoluteString`). A URL containing credentials in
    /// `userinfo` form (e.g. `https://user:pass@host/...`) would land in
    /// iOS's crash reporter verbatim. This fix routes the rejected URL
    /// through `redact(_:)` — which strips the `userinfo` component — so
    /// tampered-Secrets callers that happen to include credentials don't
    /// leak them into the crash log. Behaviour for the common case (no
    /// credentials, plain `https://host/path`) is unchanged.
    static func validateOrCrash(urlString: String, label: String) -> URL {
        do {
            return try validate(urlString: urlString)
        } catch {
            let redacted = redact(URL(string: urlString))
            preconditionFailure("\(label) rejected by EndpointGuard — url=\(redacted), reason=\(error.localizedDescription)")
        }
    }

    /// P12 (Stage 6 Wave 2): strip `user` + `password` from a URL so its
    /// string form is safe to embed in crash messages / logs. Returns a
    /// placeholder string for unparseable inputs so call sites don't have to
    /// branch.
    ///
    /// Deliberately a plain string (not URL) return: the caller is always a
    /// diagnostic format context, not a network path. Using
    /// `URLComponents.url?.absoluteString` preserves scheme/host/port/path/
    /// query but drops credentials cleanly — this matches the "log the
    /// URL without its secrets" intent exactly.
    ///
    /// SF-4 (Wave 3.1, 2026-04-26): exposed as `static` (not `private`) so
    /// other clients deriving URLs from `Secrets.claudeEndpoint` can route
    /// their own preconditionFailure messages through the same redactor.
    /// `OvernightAgentClient.defaultBaseURL` previously interpolated
    /// `Secrets.claudeEndpoint` verbatim into a precondition message, leaking
    /// any embedded credentials into the iOS crash log.
    static func redact(_ url: URL?) -> String {
        guard let url else { return "<unparseable>" }
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        comps?.user = nil
        comps?.password = nil
        return comps?.url?.absoluteString ?? "<redacted>"
    }

    /// SF-4 (Wave 3.1): redact a URL string. Same contract as `redact(_:)`
    /// but accepts the un-parsed string — useful when the caller has only the
    /// raw `Secrets.claudeEndpoint` value and wants to log without leaking
    /// credentials embedded in it.
    static func redact(urlString: String) -> String {
        redact(URL(string: urlString))
    }
}
