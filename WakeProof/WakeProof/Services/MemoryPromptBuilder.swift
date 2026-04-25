//
//  MemoryPromptBuilder.swift
//  WakeProof
//
//  Renders a MemorySnapshot into the prompt-injected memory block. Pure function,
//  no I/O. Returns nil for empty snapshots (caller short-circuits the block).
//
//  The rendered shape is XML-tagged because Anthropic's prompting guidance for
//  Opus 4.x prefers XML for structured context. Profile is rendered first so its
//  stable insights retain weight under long-context attention decay. Recent
//  history is a compact table — minimal prose, explicit per-row context.
//

import Foundation

enum MemoryPromptBuilder {

    /// Maximum rendered length. The builder drops history rows oldest-first if the
    /// full render exceeds this; the profile is always preserved intact.
    static let maxLength: Int = 2000

    /// Death-spiral guard: REJECTED entries newer than this are dropped before
    /// rendering. Phase 8 device test reproduced a feedback loop where a single
    /// REJECTED verdict (e.g. "wrong location") got fed back as memory_context
    /// on the user's immediate retry, biasing Claude toward another REJECTED
    /// ("consistent with prior off-location pattern"), which fed the next retry,
    /// etc. The user observed 5 REJECTEDs in 4 minutes and gave up.
    /// 15 minutes covers same-fire retry chains (typically <5 min spread)
    /// while preserving genuine next-day calibration ("user actually was at
    /// wrong location yesterday morning at 7am — useful to know").
    static let rejectedSuppressionWindow: TimeInterval = 15 * 60

    static func render(_ snapshot: MemorySnapshot, now: Date = Date()) -> String? {
        if snapshot.isEmpty { return nil }

        let effectiveSnapshot = applyDeathSpiralFilter(snapshot, now: now)
        if effectiveSnapshot.isEmpty { return nil }

        var parts: [String] = []
        parts.append("<memory_context total_history=\"\(snapshot.totalHistoryCount)\">")

        if let profile = effectiveSnapshot.profile, !profile.isEmpty {
            parts.append("<profile>")
            // B1/R2 fix: escape angle brackets in Claude-authored content so a
            // previously-authored profile can't close our wrapping tag early
            // and inject pseudo-instructions into the next verify call. The
            // v3 prompt frames memory as "observed patterns" — HTML-encoded
            // brackets read as literal characters, not as XML structure.
            parts.append(escapeForXML(profile))
            parts.append("</profile>")
        }

        if !effectiveSnapshot.recentHistory.isEmpty {
            parts.append("<recent_history>")
            parts.append("| when | verdict | confidence | retries | note |")
            parts.append("|---|---|---|---|---|")
            for entry in effectiveSnapshot.recentHistory {
                parts.append(renderRow(entry))
            }
            parts.append("</recent_history>")
        }

        parts.append("</memory_context>")

        let full = parts.joined(separator: "\n")
        guard full.count > maxLength else { return full }

        // Over budget. Drop history rows from oldest, keep profile intact.
        return buildTruncated(effectiveSnapshot)
    }

    /// Filter out REJECTED entries within `rejectedSuppressionWindow` so a
    /// same-fire retry chain doesn't compound prior rejections into a
    /// self-reinforcing bias. Older REJECTEDs and any VERIFIED / RETRY entry
    /// are preserved.
    private static func applyDeathSpiralFilter(_ snapshot: MemorySnapshot, now: Date) -> MemorySnapshot {
        let cutoff = now.addingTimeInterval(-rejectedSuppressionWindow)
        let filtered = snapshot.recentHistory.filter { entry in
            if entry.verdict == "REJECTED" && entry.timestamp > cutoff {
                return false
            }
            return true
        }
        return MemorySnapshot(
            profile: snapshot.profile,
            recentHistory: filtered,
            totalHistoryCount: snapshot.totalHistoryCount
        )
    }

    // MARK: - Private

    private static func renderRow(_ entry: MemoryEntry) -> String {
        let when = entry.timestamp.ISO8601Format()
        let confidence = entry.confidence.map { String(format: "%.2f", $0) } ?? "—"
        // B1/R2 fix: escape angle brackets before pipe/newline flattening so a
        // Claude-authored note can't close <recent_history> or <memory_context>
        // early. Apply escape FIRST so the subsequent pipe/newline rules see the
        // already-encoded form.
        let note = (entry.note.map { escapeForXML($0)
                                        .replacingOccurrences(of: "|", with: "/")
                                        .replacingOccurrences(of: "\n", with: " ") }) ?? ""
        return "| \(when) | \(entry.verdict) | \(confidence) | \(entry.retryCount) | \(note) |"
    }

    /// Replace `&`, `<`, and `>` with their HTML-encoded equivalents so Claude-authored
    /// content round-tripped through the memory store can't inject synthetic
    /// closing tags that break out of `<profile>` / `<recent_history>` and smuggle
    /// new instructions into the next system prompt. The v3 prompt describes the
    /// memory block as observed patterns, so encoded brackets read as literal
    /// characters — no decoder consumes them.
    ///
    /// L2 (Wave 2.7): `&` MUST be escaped FIRST. If we escaped `<` → `&lt;` first,
    /// then did `&` → `&amp;`, the already-encoded `&lt;` would become `&amp;lt;` —
    /// double-encoding that would display to Claude as the literal text "&lt;"
    /// rather than a less-than sign. Escaping `&` first avoids the double-escape:
    /// any `&` in the input becomes `&amp;` (including raw ampersands that would
    /// otherwise break XML entity parsing), and subsequent `<`/`>` → `&lt;`/`&gt;`
    /// rewrites don't introduce any new `&` characters to re-process.
    private static func escapeForXML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func buildTruncated(_ snapshot: MemorySnapshot) -> String? {
        var history = snapshot.recentHistory
        while !history.isEmpty {
            history.removeFirst()  // drop oldest
            let trimmed = MemorySnapshot(
                profile: snapshot.profile,
                recentHistory: history,
                totalHistoryCount: snapshot.totalHistoryCount
            )
            if let candidate = render(trimmed), candidate.count <= maxLength {
                return candidate
            }
        }
        // History fully dropped; render with profile only if possible.
        let profileOnly = MemorySnapshot(profile: snapshot.profile, recentHistory: [], totalHistoryCount: snapshot.totalHistoryCount)
        return render(profileOnly)
    }
}
