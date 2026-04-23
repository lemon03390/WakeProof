//
//  URL+FileProtection.swift
//  WakeProof
//
//  Consolidated helper for the `.isExcludedFromBackup` dance that repeats
//  across MemoryStore, CameraCaptureFlow, and ClaudeAPIClient's debug dump.
//  `FileProtectionType.complete` stays inline at call sites because it has
//  two distinct application modes (attributes-at-createFile-time vs.
//  setAttributes on overwrite) that should stay visible.
//

import Foundation

extension URL {
    /// Mark the file or directory at this URL as excluded from iCloud Backup.
    /// Best-effort: failures are swallowed and should be logged by the caller
    /// if they care (backup-exclusion is a hardening hint, not a correctness
    /// requirement).
    func markingExcludedFromBackup() {
        var mutable = self
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try? mutable.setResourceValues(rv)
    }
}
