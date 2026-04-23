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

    func pokeIfNeeded(handle: String, sleep: SleepSnapshot) async throws -> Bool { true }

    func fetchBriefing(handle: String) async throws -> (text: String, memoryUpdate: String?) {
        throw OvernightNoopError.notConfigured
    }

    func cleanup(handle: String) async {}
}

enum OvernightNoopError: LocalizedError {
    case notConfigured

    var errorDescription: String? {
        "Overnight briefing not configured — Phase A placeholder (B.5 wires the real source)."
    }
}
