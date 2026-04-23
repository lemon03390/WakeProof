//
//  ManagedAgentBriefingSource.swift
//  WakeProof
//
//  Primary-path OvernightBriefingSource. Wraps OvernightAgentClient and
//  exposes the four protocol methods the scheduler drives:
//    planOvernight  — opens the session with seed = HealthKit + memory snapshot
//    pokeIfNeeded   — appends fresh sleep data as a user.message mid-night
//    fetchBriefing  — pulls the final agent.message at wake time, parses
//                     BRIEFING: / MEMORY_UPDATE: markers
//    cleanup        — DELETE /v1/sessions/:id
//
//  The "handle" the scheduler persists is the session id.
//

import Foundation
import os

actor ManagedAgentBriefingSource: OvernightBriefingSource {

    private let client: OvernightAgentClient
    private let logger = Logger(subsystem: "com.wakeproof.overnight", category: "managed-agent-source")

    init(client: OvernightAgentClient = OvernightAgentClient()) {
        self.client = client
    }

    func planOvernight(sleep: SleepSnapshot, memoryProfile: String?) async throws -> String {
        logger.info("planOvernight: sleep.totalInBed=\(sleep.totalInBedMinutes, privacy: .public) memoryProfile=\(memoryProfile != nil, privacy: .public)")
        let seed = Self.buildSeedMessage(sleep: sleep, memoryProfile: memoryProfile)
        let handle = try await client.startSession(seedMessage: seed)
        logger.info("planOvernight: session opened handle=\(handle.sessionID.prefix(12), privacy: .private)")
        return handle.sessionID
    }

    func pokeIfNeeded(handle: String, sleep: SleepSnapshot) async throws -> Bool {
        logger.info("pokeIfNeeded: session=\(handle.prefix(12), privacy: .private) freshSleep.totalInBed=\(sleep.totalInBedMinutes, privacy: .public)")
        let eventText = "Fresh sleep data at \(Date.now.ISO8601Format()): \(Self.renderSleep(sleep))"
        try await client.appendEvent(sessionID: handle, text: eventText)
        // We don't (yet) have a signal from the agent that the briefing is "ready" —
        // return false so the scheduler keeps submitting refresh tasks until wake time.
        // finalizeBriefing at alarm time is the terminal state.
        return false
    }

    func fetchBriefing(handle: String) async throws -> (text: String, memoryUpdate: String?) {
        logger.info("fetchBriefing: session=\(handle.prefix(12), privacy: .private)")
        let rawText = try await client.fetchLatestAgentMessage(sessionID: handle) ?? ""
        let parsed = Self.parseAgentReply(rawText)
        logger.info("fetchBriefing: briefingChars=\(parsed.text.count, privacy: .public) memoryUpdate=\(parsed.memoryUpdate != nil, privacy: .public)")
        return parsed
    }

    func cleanup(handle: String) async {
        do {
            try await client.terminateSession(sessionID: handle)
            logger.info("cleanup: session=\(handle.prefix(12), privacy: .private) deleted")
        } catch {
            logger.error("cleanup failed (non-fatal) for session=\(handle.prefix(12), privacy: .private): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Helpers

    /// Seed message content: render the sleep + memory as structured text the
    /// agent's system prompt already knows how to consume. Sent as a follow-up
    /// event after session-create because the managed-agents-2026-04-01 beta
    /// doesn't accept initial_message at session-create time.
    private static func buildSeedMessage(sleep: SleepSnapshot, memoryProfile: String?) -> String {
        var parts: [String] = []
        if let profile = memoryProfile, !profile.isEmpty {
            parts.append("<memory_profile>\n\(profile)\n</memory_profile>")
        }
        parts.append("<sleep>\n\(renderSleep(sleep))\n</sleep>")
        parts.append("""

        This is the start of your overnight analysis window. More sleep data will
        arrive as user.message events through the night. When you have enough
        context and the user signals wake-time (or you decide the briefing is
        ready), emit your final message as:

        BRIEFING: <3-5 sentences of prose>
        MEMORY_UPDATE: <optional updated memory profile, or NONE>
        """)
        return parts.joined(separator: "\n\n")
    }

    private static func renderSleep(_ s: SleepSnapshot) -> String {
        guard !s.isEmpty else { return "(no sleep data available)" }
        let hr: String
        if let avg = s.heartRateAvg {
            hr = "HR avg \(Int(avg))bpm, range \(Int(s.heartRateMin ?? avg))-\(Int(s.heartRateMax ?? avg)) across \(s.heartRateSampleCount) samples"
        } else {
            hr = "no HR samples"
        }
        return """
        window: \(s.windowStart.ISO8601Format()) → \(s.windowEnd.ISO8601Format())
        time in bed: \(s.totalInBedMinutes) min, awake: \(s.awakeMinutes) min
        \(hr)
        Apple Watch data: \(s.hasAppleWatchData)
        """
    }

    /// Parse the agent's FINAL message expected in the shape:
    ///   BRIEFING: <text>
    ///   MEMORY_UPDATE: <text or NONE>
    /// Tolerates missing markers: if neither shows up, treat the whole text as
    /// the briefing with no memory update.
    static func parseAgentReply(_ raw: String) -> (text: String, memoryUpdate: String?) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("", nil) }

        // Case: both markers present
        if let briefingRange = trimmed.range(of: "BRIEFING:", options: .caseInsensitive),
           let memoryRange = trimmed.range(of: "MEMORY_UPDATE:", options: .caseInsensitive),
           briefingRange.upperBound <= memoryRange.lowerBound {
            let briefingText = String(trimmed[briefingRange.upperBound..<memoryRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let memoryText = String(trimmed[memoryRange.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let memoryUpdate: String? = (memoryText.uppercased() == "NONE" || memoryText.isEmpty) ? nil : memoryText
            return (briefingText, memoryUpdate)
        }

        // Case: just BRIEFING: present
        if let briefingRange = trimmed.range(of: "BRIEFING:", options: .caseInsensitive) {
            let briefingText = String(trimmed[briefingRange.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (briefingText, nil)
        }

        // Case: no markers — treat the whole text as the briefing
        return (trimmed, nil)
    }
}
