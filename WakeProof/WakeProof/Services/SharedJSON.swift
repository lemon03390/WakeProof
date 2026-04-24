//
//  SharedJSON.swift
//  WakeProof
//
//  SR4 (Stage 4): shared `JSONDecoder` / `JSONEncoder` instances so the 19
//  inline instantiations across Services/, Alarm/, Storage/ stop building a
//  fresh decoder per call. Decoders are heavier than their obvious API shape
//  suggests — constructing one allocates a date-strategy machine, a key-
//  decoding-strategy machine, a user-info dict, etc. Reusing them on hot
//  paths (MemoryStore writes, UserDefaults queue encode/decode, per-verify
//  Claude response parsing) avoids that allocation.
//
//  Thread safety: `JSONEncoder` / `JSONDecoder` are documented Sendable in
//  Swift 6 (ref-types whose all-mutable-state is configured at init). Once
//  configured here, they are never mutated — safe to share across actors and
//  concurrent calls.
//
//  Variants:
//  - `.iso8601Decoder` / `.iso8601Encoder`  — date strategy `.iso8601`. Used
//    by MemoryEntry, PendingMemoryWrite, PendingWakeAttempt, and any code
//    path that round-trips timestamps as strings.
//  - `.plainDecoder` / `.plainEncoder`      — default date strategy
//    (`deferredToDate`, i.e. timeInterval-since-reference-date). Used by API
//    response parsing where the server emits numeric Unix timestamps or no
//    dates at all (Anthropic message envelopes, proxy error envelopes).
//
//  When in doubt, match the writer's strategy. MemoryEntry writes with
//  `.iso8601`, so readers must also use `.iso8601`; Anthropic's Messages API
//  body has no Date fields at all, so `.plainDecoder` is fine there.
//

import Foundation

enum SharedJSON {
    /// JSON decoder with `.iso8601` date-decoding strategy. Used for
    /// UserDefaults queue blobs, MemoryEntry + sidecar round-trips, and any
    /// WakeProof-authored JSON that serialises Dates as ISO-8601 strings.
    static let iso8601Decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// JSON encoder with `.iso8601` date-encoding strategy. Pair with the
    /// matching decoder above.
    static let iso8601Encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    /// Default-strategy JSON decoder. Used for API response envelopes (Claude
    /// Messages body, Anthropic error shapes, Managed Agents event lists)
    /// which carry no Date fields.
    static let plainDecoder = JSONDecoder()

    /// Default-strategy JSON encoder. Used for WakeWindow + BedtimeSettings
    /// UserDefaults blobs (both are date-free value types).
    static let plainEncoder = JSONEncoder()
}
