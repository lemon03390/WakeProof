//
//  NoopBriefingSource.swift
//  WakeProof
//
//  Placeholder OvernightBriefingSource. Phase A ships this so the scheduler
//  can be instantiated without picking a concrete source; Phase B.5 swaps it
//  for either `ManagedAgentBriefingSource` (primary) or `SynthesisBriefingSource`
//  (fallback) based on the B.3 decision-gate outcome.
//
//  `planOvernight` and `pokeIfNeeded` succeed trivially so the scheduler's
//  happy path is exercised end-to-end in tests. `fetchBriefing` throws —
//  a wake-time call reaching the noop means B.5 failed to wire a real
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
