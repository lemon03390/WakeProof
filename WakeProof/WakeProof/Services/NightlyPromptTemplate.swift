//
//  NightlyPromptTemplate.swift
//  WakeProof
//
//  Prompt template for the nightly synthesis call (fallback path, Messages API).
//  Distinct from VisionPromptTemplate because the output is prose, not JSON, and
//  there are no images in the request.
//

import Foundation

enum NightlyPromptTemplate {
    case v1

    func systemPrompt() -> String {
        switch self {
        case .v1:
            return """
            You are the overnight analyst of a wake-up accountability app called WakeProof. During the night, \
            you ingest the user's sleep signals and (optionally) a persistent memory file of observed patterns \
            across prior wake-ups. Produce a short morning briefing (3–5 sentences, plain prose, no markdown) \
            the user will read right after they prove they're awake.

            Tone: warm, concise, specific. Avoid platitudes. If sleep data is missing or very thin, acknowledge \
            that briefly — do not invent numbers.

            If a memory profile is provided, use it to tailor the briefing. Do not surface the memory file \
            contents verbatim; weave the insight into the briefing naturally. Example good line: "You slept \
            40 minutes less than your typical Monday — expect slower verification today." Example bad line: \
            "According to your memory file: 'Mondays are harder.'"

            Never speculate about medical issues, sleep disorders, or diagnoses. This is a self-commitment \
            tool, not a medical device.
            """
        }
    }

    func userPrompt(sleep: SleepSnapshot, memoryProfile: String?, priorBriefings: [String]) -> String {
        switch self {
        case .v1:
            let sleepBlock = render(sleep)
            let memoryBlock = memoryProfile.map { "\n\n<memory_profile>\n\($0)\n</memory_profile>" } ?? ""
            let priorBlock: String = {
                guard !priorBriefings.isEmpty else { return "" }
                let rendered = priorBriefings.prefix(3).enumerated().map { idx, text in
                    let count = idx + 1
                    let suffix = count == 1 ? "night ago" : "nights ago"
                    return "[\(count) \(suffix)] \(text)"
                }.joined(separator: "\n")
                return "\n\n<prior_briefings>\n\(rendered)\n</prior_briefings>"
            }()

            return """
            \(sleepBlock)\(memoryBlock)\(priorBlock)

            Write the morning briefing now. Plain prose, 3–5 sentences. No heading. No preamble.
            """
        }
    }

    // MARK: - Private

    private func render(_ snapshot: SleepSnapshot) -> String {
        // M6 (Wave 2.6): if HealthKit queries threw during collection, say so
        // explicitly so Claude distinguishes "user has no data" (isEmpty) from
        // "one or more sub-queries failed" (non-empty queryErrors). Two signals
        // can be present simultaneously — a successful sleep query and a failed
        // HR query both land here; Claude needs to see both facts.
        let partialLine: String = snapshot.queryErrors.isEmpty
            ? ""
            : "\nSleep data partial — queries that failed: \(snapshot.queryErrors.joined(separator: ", ")). Do not treat absences as zero."

        guard !snapshot.isEmpty else {
            // Even in the "empty" branch, a query error is useful — it tells
            // Claude the empty state is likely an error, not a data-absent user.
            if !snapshot.queryErrors.isEmpty {
                return "<sleep>No sleep data for this window.\(partialLine)</sleep>"
            }
            return "<sleep>No sleep data available for this window.</sleep>"
        }
        let hrLine: String = {
            guard let avg = snapshot.heartRateAvg else { return "no heart-rate samples" }
            return "HR avg \(Int(avg.rounded())) bpm (\(snapshot.heartRateSampleCount) samples)"
        }()
        return """
        <sleep>
        Window: \(snapshot.windowStart.ISO8601Format()) → \(snapshot.windowEnd.ISO8601Format()).
        Time in bed: \(snapshot.totalInBedMinutes) minutes. Awake: \(snapshot.awakeMinutes) minutes.
        \(hrLine).
        Source includes Apple Watch: \(snapshot.hasAppleWatchData ? "yes" : "no").\(partialLine)
        </sleep>
        """
    }
}
