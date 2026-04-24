//
//  NoopBriefingSource.swift
//  WakeProof
//
//  Retained post-B.5 for (1) SwiftUI previews that need a scheduler without
//  hitting the network, and (2) rollback / B.4b if we ever need to swap the
//  primary `ManagedAgentBriefingSource` back out. Phase B.5 wired
//  ManagedAgentBriefingSource as the live source in WakeProofApp; this type
//  is no longer on the production hot path.
//
//  `planOvernight` and `pokeIfNeeded` succeed trivially so the scheduler's
//  happy path is exercised end-to-end in tests. `fetchBriefing` throws —
//  a wake-time call reaching the noop means something failed to wire a real
//  source, which should be loud (error in logs) rather than silent.
//

import Foundation

actor NoopBriefingSource: OvernightBriefingSource {

    func planOvernight(sleep: SleepSnapshot, memoryProfile: String?) async throws -> String {
        "noop-handle-\(UUID().uuidString)"
    }

    // Returns false to match the primary-path "keep refreshing until alarm time"
    // semantic. Per the protocol doc, `true` tells the scheduler "briefing ready —
    // stop refreshing". Returning `true` here was inconsistent with Managed Agents
    // (which never terminates early) and would falsely short-circuit the pipeline
    // in any future refactor that honors the return value. C.3 fix.
    func pokeIfNeeded(handle: String, sleep: SleepSnapshot) async throws -> Bool { false }

    func fetchBriefing(handle: String) async throws -> (text: String, memoryUpdate: String?) {
        throw OvernightNoopError.notConfigured
    }

    /// R3-2 (Stage 6 Wave 3): protocol collapsed to the throwing form. The
    /// noop source never opens a real session (`planOvernight` returns a fake
    /// "noop-handle-..." string), so there's nothing to terminate — body is
    /// intentionally empty. Conforms to the new signature without behaviour
    /// change; the throw clause is satisfied by simply not throwing.
    func cleanupThrowing(handle: String) async throws {}
}

enum OvernightNoopError: LocalizedError {
    case notConfigured

    var errorDescription: String? {
        "Overnight briefing not configured — Phase A placeholder (B.5 wires the real source)."
    }
}
