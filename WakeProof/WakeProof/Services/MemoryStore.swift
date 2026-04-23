//
//  MemoryStore.swift
//  WakeProof
//
//  On-disk store for the Layer 2 per-user memory file. Two files per user UUID:
//    Documents/memories/<uuid>/profile.md      — Claude-authored persistent profile
//    Documents/memories/<uuid>/history.jsonl   — one MemoryEntry JSON per line
//
//  Wrapped in a Swift actor so concurrent appendHistory / rewriteProfile calls
//  serialise without a manual lock. Caller-facing API is async throws. All writes
//  go through `.complete` file protection and `isExcludedFromBackup = true`.
//
//  Size discipline: profile.md soft cap 16 KB (oversized rewrites truncate with a
//  warning log); history.jsonl soft cap 4096 entries (reached but unenforced on
//  Day 4 — a warning log is emitted, rotation is Day 5 polish). Reads return at
//  most `historyReadLimit` entries (default 5) so the prompt payload stays bounded.
//

import Foundation
import os

actor MemoryStore {

    // MARK: - Configuration

    /// Injectable for tests. Production use: `MemoryStore()` resolves to
    /// `Documents/memories/<UserIdentity.shared.uuid>/`.
    struct Configuration {
        var rootDirectory: URL
        var userUUID: String
        var historyReadLimit: Int = 5
        var profileMaxBytes: Int = 16 * 1024
        var historyMaxEntries: Int = 4096
    }

    // `private(set) var` rather than `private let` so the @testable-imported test
    // suite can reach `configuration.userUUID` from a test-only extension without
    // forcing a public getter into the production surface. The setter stays private
    // — configuration is assigned once in init and never mutated afterwards.
    private(set) var configuration: Configuration
    private let logger = Logger(subsystem: "com.wakeproof.memory", category: "store")

    // MARK: - Public API

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// Production initializer — derives the path from UserIdentity.
    /// A caller in WakeProofApp does `MemoryStore()` once at bootstrap.
    init() {
        let docs: URL
        do {
            docs = try FileManager.default.url(
                for: .documentDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            )
        } catch {
            // Documents is guaranteed by iOS; a failure here is a platform-level
            // pathological state (ReadOnly device, disk corruption). Fall back to
            // tmp so the app continues to launch without crashing — reads will
            // return .empty, writes will discard cleanly, and the logger surfaces
            // the root cause for triage.
            Logger(subsystem: "com.wakeproof.memory", category: "store")
                .fault("Documents directory unavailable, memory will be ephemeral: \(error.localizedDescription, privacy: .public)")
            docs = FileManager.default.temporaryDirectory
        }
        self.configuration = Configuration(
            rootDirectory: docs.appendingPathComponent("memories", isDirectory: true),
            userUUID: UserIdentity.shared.uuid
        )
    }

    /// Ensure `memories/<uuid>/` exists and is excluded from backup. Safe to call
    /// many times — subsequent calls are no-ops. Call once from `WakeProofApp.
    /// bootstrapIfNeeded` so the first verification never pays a directory-create
    /// cost inline.
    func bootstrapIfNeeded() async throws {
        let userDir = try userDirectoryURL()
        let fm = FileManager.default
        try fm.createDirectory(at: userDir, withIntermediateDirectories: true)
        // Idempotent backup-exclusion write. If setResourceValues fails (transient
        // filesystem state), log and continue; the directory itself already exists.
        var mutable = userDir
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        do { try mutable.setResourceValues(rv) }
        catch { logger.warning("Failed to mark memories dir excluded-from-backup: \(error.localizedDescription, privacy: .public)") }
        logger.info("MemoryStore bootstrap ok for user \(self.configuration.userUUID.prefix(8), privacy: .private)…")
    }

    /// Read profile + recent history into a frozen snapshot. Returns `.empty` if
    /// the directory doesn't exist yet (first-ever launch) or if both files are
    /// missing. Never throws for "file absent" — that's the expected steady state
    /// for a fresh install.
    func read() async throws -> MemorySnapshot {
        let userDir = try userDirectoryURL()
        let fm = FileManager.default
        guard fm.fileExists(atPath: userDir.path) else {
            return .empty
        }
        let profile = try? loadProfile(in: userDir)
        let (recent, total) = loadHistory(in: userDir)
        let snapshot = MemorySnapshot(
            profile: profile,
            recentHistory: recent,
            totalHistoryCount: total
        )
        return snapshot
    }

    /// Append one entry to history.jsonl. File + directory are created as needed.
    /// Over-capacity is logged but not enforced on Day 4.
    func appendHistory(_ entry: MemoryEntry) async throws {
        let userDir = try userDirectoryURL()
        let fm = FileManager.default
        try fm.createDirectory(at: userDir, withIntermediateDirectories: true)
        let file = userDir.appendingPathComponent("history.jsonl", isDirectory: false)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let json = try encoder.encode(entry)
        var line = json
        line.append(UInt8(ascii: "\n"))

        if fm.fileExists(atPath: file.path) {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            // R5 fix: create the file with `.complete` protection in a single
            // call so the inode's protection class is set at birth — no brief
            // weaker-class window between atomic-write landing and a subsequent
            // setAttributes upgrade. isExcludedFromBackup is a URL resource
            // value (not a file attribute), so it's applied separately.
            let created = fm.createFile(
                atPath: file.path,
                contents: line,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
            guard created else {
                throw MemoryStoreError.fileCreationFailed
            }
            var mutable = file
            var rv = URLResourceValues()
            rv.isExcludedFromBackup = true
            try? mutable.setResourceValues(rv)
        }

        // Capacity probe — log only. Rotation is Day 5.
        let (_, total) = loadHistory(in: userDir)
        if total > configuration.historyMaxEntries {
            logger.warning("history.jsonl over cap (\(total, privacy: .public) > \(self.configuration.historyMaxEntries, privacy: .public)); rotation deferred to Day 5")
        }
    }

    /// Replace profile.md with new markdown. Oversized markdown is truncated to
    /// `profileMaxBytes` and a warning is logged. The truncation boundary prefers
    /// the last newline within the cap so we don't slice mid-sentence — if no
    /// newline exists, byte-level truncation wins over refusing the write.
    func rewriteProfile(_ markdown: String) async throws {
        let userDir = try userDirectoryURL()
        let fm = FileManager.default
        try fm.createDirectory(at: userDir, withIntermediateDirectories: true)
        let file = userDir.appendingPathComponent("profile.md", isDirectory: false)

        let data = Data(markdown.utf8)
        let bounded: Data
        if data.count <= configuration.profileMaxBytes {
            bounded = data
        } else {
            logger.warning("profile.md rewrite oversized (\(data.count, privacy: .public) > \(self.configuration.profileMaxBytes, privacy: .public)) — truncating")
            bounded = Self.truncatePreservingNewlines(data, to: configuration.profileMaxBytes)
        }
        if fm.fileExists(atPath: file.path) {
            // Overwrite path: atomic rename preserves the existing inode's
            // protection class (set at first-create below), so a subsequent
            // applyFileProtection is a no-op upgrade when the file was
            // already .complete. Retaining the call is defensive — a prior
            // build (pre-R5) may have created the file at the weaker default.
            try bounded.write(to: file, options: [.atomic])
            try applyFileProtection(to: file)
        } else {
            // R5 fix: first-create path sets `.complete` protection at birth
            // via `createFile(…attributes:)`. No brief weaker-class window.
            let created = fm.createFile(
                atPath: file.path,
                contents: bounded,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
            guard created else {
                throw MemoryStoreError.fileCreationFailed
            }
            var mutable = file
            var rv = URLResourceValues()
            rv.isExcludedFromBackup = true
            try? mutable.setResourceValues(rv)
        }
    }

    // MARK: - Private helpers

    private func userDirectoryURL() throws -> URL {
        // Path-traversal guard: the UUID is meant to be a UUID-shaped string.
        // If something mutated it to `../evil`, we must refuse to escape the
        // memories root — a stolen user-defaults value shouldn't let an attacker
        // overwrite arbitrary files in the app container.
        let uuid = configuration.userUUID
        guard UUID(uuidString: uuid) != nil else {
            throw MemoryStoreError.invalidUserUUID
        }
        return configuration.rootDirectory.appendingPathComponent(uuid, isDirectory: true)
    }

    private func loadProfile(in userDir: URL) throws -> String? {
        let file = userDir.appendingPathComponent("profile.md", isDirectory: false)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try String(contentsOf: file, encoding: .utf8)
    }

    private func loadHistory(in userDir: URL) -> (recent: [MemoryEntry], total: Int) {
        let file = userDir.appendingPathComponent("history.jsonl", isDirectory: false)
        guard FileManager.default.fileExists(atPath: file.path),
              let raw = try? String(contentsOf: file, encoding: .utf8) else {
            return ([], 0)
        }
        let lines = raw.split(whereSeparator: \.isNewline).map(String.init)
        let total = lines.count
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Decode all so partial corruption in older entries doesn't crater the
        // most-recent read; tolerate per-line decode failures with a warning.
        let entries: [MemoryEntry] = lines.compactMap { line in
            guard !line.isEmpty,
                  let data = line.data(using: .utf8) else { return nil }
            do { return try decoder.decode(MemoryEntry.self, from: data) }
            catch {
                logger.warning("history.jsonl line decode failed, skipping: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        let recent = Array(entries.suffix(configuration.historyReadLimit))
        return (recent, total)
    }

    private func applyFileProtection(to url: URL) throws {
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
        var mutable = url
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try? mutable.setResourceValues(rv)
    }

    private static func truncatePreservingNewlines(_ data: Data, to byteLimit: Int) -> Data {
        guard data.count > byteLimit else { return data }
        let slice = data.prefix(byteLimit)
        if let newlineIndex = slice.lastIndex(of: UInt8(ascii: "\n")) {
            // +1 to include the newline so the file ends on a clean line boundary.
            return Data(slice.prefix(upTo: slice.index(after: newlineIndex)))
        }
        // R3 fix: no newline found — byte-truncate, but snap back to the nearest
        // UTF-8 codepoint boundary so we never split a multi-byte codepoint. An
        // invalid trailing byte would make the whole profile fail to decode on
        // the next read (String(contentsOf:encoding:.utf8) returns nil) and
        // silently evict the file via loadProfile's try-returning-nil.
        //
        // Detection: if the byte immediately AFTER our slice is a continuation
        // byte (10xxxxxx), then our slice ends mid-codepoint. Walk back over
        // any trailing continuation bytes inside the slice (10xxxxxx), then
        // drop the leading byte of the bisected codepoint (11xxxxxx). If the
        // byte after the slice is ASCII or a new-codepoint leading byte, the
        // slice is already on a valid boundary — nothing to do.
        var end = byteLimit
        if (data[end] & 0b1100_0000) == 0b1000_0000 {
            while end > 0 && (data[end - 1] & 0b1100_0000) == 0b1000_0000 {
                end -= 1
            }
            if end > 0 && (data[end - 1] & 0b1100_0000) == 0b1100_0000 {
                end -= 1
            }
        }
        return Data(data.prefix(end))
    }
}

enum MemoryStoreError: LocalizedError {
    case invalidUserUUID
    /// R5 fix: first-create via `FileManager.createFile(atPath:contents:attributes:)`
    /// returns `false` (rather than throwing) on write failure. Surface it as a
    /// specific error so callers don't silently lose the write — the caller's
    /// `do/catch` block will log it as a non-fatal memory-write failure.
    case fileCreationFailed

    var errorDescription: String? {
        switch self {
        case .invalidUserUUID:
            return "Memory store: stored user UUID is not a valid UUID shape — refusing to open directory."
        case .fileCreationFailed:
            return "Memory store: failed to create profile.md or history.jsonl on first write."
        }
    }
}
