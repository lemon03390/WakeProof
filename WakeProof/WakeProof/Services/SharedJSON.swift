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
//  P22 (Stage 6 Wave 2): the decoder/encoder instances are now PRIVATE. The
//  previous `static let iso8601Decoder: JSONDecoder` surface made them
//  publicly READABLE, which means publicly MUTABLE too — a caller could
//  silently set `SharedJSON.iso8601Decoder.dateDecodingStrategy =
//  .secondsSince1970` and cascade the change to every other call site. The
//  wrapper API below (`decodeISO8601` / `encodeISO8601` / `decodePlain` /
//  `encodePlain`) exposes the *behaviour* without exposing the *instance*.
//  Callers get the same allocation-amortisation benefit; no-one can mutate
//  configuration from outside this file.
//
//  Variants:
//  - `.decodeISO8601` / `.encodeISO8601`  — date strategy `.iso8601`. Used
//    by MemoryEntry, PendingMemoryWrite, PendingWakeAttempt, and any code
//    path that round-trips timestamps as strings.
//  - `.decodePlain` / `.encodePlain`      — default date strategy
//    (`deferredToDate`, i.e. timeInterval-since-reference-date). Used by API
//    response parsing where the server emits numeric Unix timestamps or no
//    dates at all (Anthropic message envelopes, proxy error envelopes).
//
//  When in doubt, match the writer's strategy. MemoryEntry writes with
//  `.iso8601`, so readers must also use `.iso8601`; Anthropic's Messages API
//  body has no Date fields at all, so `.decodePlain` is fine there.
//

import Foundation

// P8 (Stage 6 Wave 1): marking the enum itself `nonisolated` (vs adding the
// attribute per-property) lets the nonisolated retry-queue paths
// (`PendingWakeAttemptQueue.loadQueueUnsafe` / `saveQueueUnsafe` and friends)
// reach these singletons without an actor hop. The underlying encoders/decoders
// are `Sendable` at the Foundation level so cross-actor use is safe; the only
// reason the properties were previously MainActor-inferred is the project-wide
// default-actor-isolation setting — explicitly marking `nonisolated` overrides
// that inference here so file-local access stays cheap.
nonisolated enum SharedJSON {
    /// JSON decoder with `.iso8601` date-decoding strategy. Private — P22
    /// (Stage 6 Wave 2) removed the public instance surface so callers can't
    /// mutate configuration across paths. Use `decodeISO8601(_:from:)` below.
    private static let iso8601DecoderInstance: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// JSON encoder with `.iso8601` date-encoding strategy. Private — see
    /// `iso8601DecoderInstance` comment. Use `encodeISO8601(_:)` below.
    private static let iso8601EncoderInstance: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    /// Default-strategy JSON decoder. Private — see `iso8601DecoderInstance`
    /// comment. Use `decodePlain(_:from:)` below.
    private static let plainDecoderInstance = JSONDecoder()

    /// Default-strategy JSON encoder. Private — see `iso8601DecoderInstance`
    /// comment. Use `encodePlain(_:)` below.
    private static let plainEncoderInstance = JSONEncoder()

    /// Decode `data` using the shared `.iso8601` decoder. Amortises the per-
    /// call `JSONDecoder()` allocation; no caller can mutate configuration.
    static func decodeISO8601<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try iso8601DecoderInstance.decode(type, from: data)
    }

    /// Encode `value` using the shared `.iso8601` encoder. Pair with the
    /// matching decoder above.
    static func encodeISO8601<T: Encodable>(_ value: T) throws -> Data {
        try iso8601EncoderInstance.encode(value)
    }

    /// Decode `data` using the default-strategy decoder. Use for server
    /// responses that carry no Date fields.
    static func decodePlain<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try plainDecoderInstance.decode(type, from: data)
    }

    /// Encode `value` using the default-strategy encoder. Use for Date-free
    /// value types destined for UserDefaults.
    static func encodePlain<T: Encodable>(_ value: T) throws -> Data {
        try plainEncoderInstance.encode(value)
    }
}
