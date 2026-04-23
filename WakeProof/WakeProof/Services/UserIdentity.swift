//
//  UserIdentity.swift
//  WakeProof
//
//  One random UUID per install, persisted to UserDefaults. First access generates;
//  subsequent accesses return the stored value. We use a self-generated UUID rather
//  than `identifierForVendor` so (a) reinstalling WakeProof rotates the ID cleanly
//  (simulating a fresh-install state for memory without iOS playing tricks), and
//  (b) we avoid adding an Apple-derived-identifier disclosure to the privacy copy.
//

import Foundation
import os

struct UserIdentity {

    /// Shared instance read lazily. A struct + static var is sufficient because the
    /// API is a single string — no observable state, no mutation hooks, no SwiftUI
    /// subscription needs. Threading safety comes from `UserDefaults` being thread-safe.
    static let shared = UserIdentity()

    private static let key = "com.wakeproof.user.uuid"
    private static let logger = Logger(subsystem: "com.wakeproof.memory", category: "identity")

    /// The install's stable UUID. First access generates + persists.
    var uuid: String {
        if let existing = UserDefaults.standard.string(forKey: Self.key) {
            return existing
        }
        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: Self.key)
        Self.logger.info("Generated new user UUID (first launch)")
        return generated
    }

    #if DEBUG
    /// Test-only hook. Clears the stored UUID so the next `uuid` access generates.
    /// Guarded `#if DEBUG` so release builds cannot accidentally lose user memory by
    /// calling this from a future refactor.
    func rotate() {
        UserDefaults.standard.removeObject(forKey: Self.key)
        Self.logger.warning("User UUID rotated (debug-only path)")
    }
    #endif
}
