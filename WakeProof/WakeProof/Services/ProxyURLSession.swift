//
//  ProxyURLSession.swift
//  WakeProof
//
//  Centralised URLSession factory shared by the three Claude-proxy clients
//  (`ClaudeAPIClient`, `NightlySynthesisClient`, `OvernightAgentClient`).
//
//  Before this file each client carried its own near-identical `defaultSession`
//  static-let factory with timeouts 15/30. Two of the three already pointed
//  back to `ClaudeAPIClient.defaultSession` in their comments for the
//  rationale — a documentation-level admission that the configuration was
//  shared. Centralising removes the drift risk: a future timeout change
//  (e.g. raising request to 20 s) would have required edits to all three
//  files plus updates to the cross-references.
//
//  P-I3 (Wave 2.2, 2026-04-26): each call site uses `static let` so the
//  underlying URLSession is allocated once at first reference and shared
//  for the lifetime of the process. URLSession is thread-safe for the
//  request-creation API surface we use.
//

import Foundation

enum ProxyURLSession {
    /// Build a URLSession suitable for talking to the WakeProof Vercel proxy.
    ///
    /// Default `15s/30s` request/resource timeouts match Decision 2: beyond 15 s
    /// the alarm has already ramped to full volume and a retry would waste
    /// ring-ceiling on a dead network. The 30 s resource ceiling backstops
    /// streaming responses we don't currently consume.
    ///
    /// `waitsForConnectivity` defaults `false` because the vision-verification
    /// path runs on the alarm-fire critical path — the user is staring at a
    /// "verifying…" spinner; waiting for connectivity to come back beats the
    /// 15 s request timeout into a 60 s+ stall on a flaky cell tower.
    /// `OvernightAgentClient` and `NightlySynthesisClient` historically left
    /// it at the URLSession default (also `false` in the configurations they
    /// constructed because they didn't override) so all three settle on the
    /// same posture.
    static func make(
        requestTimeout: TimeInterval = 15,
        resourceTimeout: TimeInterval = 30,
        waitsForConnectivity: Bool = false
    ) -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        config.waitsForConnectivity = waitsForConnectivity
        return URLSession(configuration: config)
    }
}
