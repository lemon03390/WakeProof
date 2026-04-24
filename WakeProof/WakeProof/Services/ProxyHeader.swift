//
//  ProxyHeader.swift
//  WakeProof
//
//  SR8 (Stage 4): HTTP header names + the standard header-writing extension
//  for outbound WakeProof-proxy calls. Previously each client (ClaudeAPIClient,
//  OvernightAgentClient, NightlySynthesisClient) carried its own inline
//  `enum Header { static let ... }` block and repeated the same three
//  `setValue(_:forHTTPHeaderField:)` calls to install them. Lifting the
//  strings here (single source of truth) and the installation to a
//  `URLRequest` extension means future changes (e.g. a new `x-wakeproof-
//  client` header, a managed-agents-beta version bump) touch one file.
//

import Foundation

/// Header names used on outbound requests to the WakeProof Vercel proxy.
///
/// Do not invent new headers for client-specific needs; add them here and
/// extend `URLRequest.setWakeProofHeaders(...)` so the contract stays unified.
enum ProxyHeader {
    /// `application/json` goes on every POST/PATCH/DELETE with a body.
    static let contentType = "Content-Type"
    /// Per-install shared token. Authenticates this client to the proxy;
    /// the proxy holds the Anthropic API key.
    static let clientToken = "x-wakeproof-token"
    /// Anthropic-side version header (same value regardless of beta).
    static let anthropicVersion = "anthropic-version"
    /// Managed Agents beta header — only required for the Managed Agents
    /// routes (agent / environment / session / events). Vision verification
    /// + nightly synthesis do not need this header.
    static let anthropicBeta = "anthropic-beta"
}

extension URLRequest {

    /// Install the standard WakeProof request headers on this request.
    ///
    /// - Parameters:
    ///   - token: the `x-wakeproof-token` value.
    ///   - anthropicVersion: always "2023-06-01" for current Anthropic APIs.
    ///     Hardcoded here so callers never pass a stale or forked value —
    ///     the beta parameter is where per-route variation lives.
    ///   - beta: optional `anthropic-beta` value. Pass `nil` for routes that
    ///     do not need beta opt-in (vision verification, nightly synthesis).
    ///     Pass `managed-agents-2026-04-01` (or its successor) for the
    ///     Managed Agents surface.
    ///
    /// Always sets `Content-Type: application/json` — call this BEFORE
    /// assigning `httpBody`, or after (either order works; the mutation is
    /// independent).
    mutating func setWakeProofHeaders(
        token: String,
        anthropicVersion: String = "2023-06-01",
        beta: String? = nil
    ) {
        setValue("application/json", forHTTPHeaderField: ProxyHeader.contentType)
        setValue(token, forHTTPHeaderField: ProxyHeader.clientToken)
        setValue(anthropicVersion, forHTTPHeaderField: ProxyHeader.anthropicVersion)
        if let beta {
            setValue(beta, forHTTPHeaderField: ProxyHeader.anthropicBeta)
        }
    }
}
