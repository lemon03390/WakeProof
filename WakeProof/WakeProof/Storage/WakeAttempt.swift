//
//  WakeAttempt.swift
//  WakeProof
//
//  Per-alarm log of the user's verification attempts. The full vision-verdict pipeline
//  populates `verdict` + `verdictReasoning` later; today's writes set `verdict` to
//  CAPTURED / TIMEOUT / UNRESOLVED based on which terminal state the alarm reached.
//

import Foundation
import SwiftData

@Model
final class WakeAttempt {
    var scheduledAt: Date
    var capturedAt: Date?
    var imageData: Data?

    /// Stored as raw String (not the `Verdict` enum) so adding new cases later doesn't
    /// force a SwiftData schema migration. Read via `verdictEnum` for the safe path.
    var verdict: String?
    var verdictReasoning: String?
    var retryCount: Int
    var dismissedAt: Date?

    // SwiftData treats new optional properties as a lightweight migration — the
    // on-device store is preserved across releases that add fields here.
    var videoPath: String?
    var triggeredWindowStart: Date?
    var triggeredWindowEnd: Date?

    init(scheduledAt: Date) {
        self.scheduledAt = scheduledAt
        self.retryCount = 0
    }

    /// Safe accessor for the verdict column. Routes through `Verdict.init(legacyRawValue:)`
    /// so any unrecognised stored string surfaces as `.unresolved` instead of crashing or
    /// returning a blank value at the call site.
    var verdictEnum: Verdict { Verdict(legacyRawValue: verdict) }

    /// String constants stored in the `verdict` column. Adding cases is migration-free.
    enum Verdict: String {
        case captured       = "CAPTURED"        // user produced a video; vision verdict pending
        case verified       = "VERIFIED"        // vision call confirmed
        case rejected       = "REJECTED"        // vision call disagreed
        case retry          = "RETRY"           // user cancelled or failed mid-capture
        case timeout        = "TIMEOUT"         // ring ceiling reached without capture
        case unresolved     = "UNRESOLVED"      // alarm fired but app died before resolution

        /// Decode a stored value, treating nil or any unrecognised string as `.unresolved`
        /// so callers don't have to defensively handle pre-enum migration data or future
        /// rolled-back deployments leaving stray strings.
        init(legacyRawValue: String?) {
            guard let raw = legacyRawValue, let value = Verdict(rawValue: raw) else {
                self = .unresolved
                return
            }
            self = value
        }
    }
}
