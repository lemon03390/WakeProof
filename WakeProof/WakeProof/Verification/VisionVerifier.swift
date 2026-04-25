//
//  VisionVerifier.swift
//  WakeProof
//
//  Orchestrates the vision-verification step. Called once per capture; drives
//  the alarm state machine to one of three terminal states: VERIFIED (alarm
//  stops), REJECTED (alarm keeps ringing with an error banner), RETRY (user
//  is shown an anti-spoof action prompt and re-captures once). A second RETRY
//  inside the same fire is coerced to REJECTED so we don't spin indefinitely
//  against either Claude or the user's ring ceiling.
//
//  This class does NOT own the ModelContext; callers pass it in via the
//  `verify(...)` call so a single verifier instance can be used across multiple
//  scenes/contexts without re-binding.
//

import Foundation
import Observation
import SwiftData
import UIKit
import os

@Observable
@MainActor
final class VisionVerifier {

    // MARK: - Observable state

    private(set) var lastError: String?
    private(set) var currentAttemptIndex: Int = 0        // 0 before first call, 1 after first, 2 after retry
    private(set) var currentAntiSpoofInstruction: String?

    /// P14 (Stage 6 Wave 2): set to `true` when `MemoryStore.read()` throws
    /// `.invalidUserUUID`. That error is the signal that the UserDefaults-
    /// backed UUID was externally mutated (path-traversal guard refused to
    /// open the directory) — a security-relevant state distinct from the
    /// first-install "no memory yet" case, both of which previously collapsed
    /// into a silent `memoryContext = nil`. AlarmSchedulerView's systemBanner
    /// picks this up as the highest-priority surface so the user is prompted
    /// to reinstall (regenerating identity wipes the stored UUID in the
    /// process).
    ///
    /// Never flips back to false at runtime: once the UUID is out of shape
    /// the only remediation is a reinstall. The DEBUG menu (if present)
    /// could clear it manually, but the banner staying up until then is
    /// intentional — a stale warning is better than a fixed one the user
    /// dismissed and immediately forgot.
    private(set) var requiresReinstall: Bool = false

    /// E-C3 (Wave 2.3, 2026-04-26): set to `true` when MemoryStore bootstrap
    /// throws a non-UUID error (disk full, sandbox edge case, ReadOnly
    /// directory). That failure used to collapse silently — `memoryStore`
    /// would stay nil for the rest of the session, every verify ran without
    /// calibration context, the queue grew until it dropped older entries.
    /// AlarmSchedulerView's systemBanner now surfaces this so the user knows
    /// memory is unavailable and the verdicts won't accumulate calibration.
    /// Distinct from `requiresReinstall` (UUID-shape failure) so the banner
    /// copy can differentiate.
    private(set) var memoryBootstrapFailed: Bool = false

    /// E-C2 (Wave 2.3, 2026-04-26): timestamp of the last MorningBriefing
    /// SwiftData persist failure. The .success branch of the VERIFIED
    /// transition still renders the in-memory DTO to the cover (user did wake
    /// up + earn the briefing), but the audit row was never written. Banner
    /// surfaces this so the user knows their history has a gap. Cleared on
    /// the next successful persist.
    private(set) var lastBriefingPersistFailedAt: Date?

    /// Setter for `memoryBootstrapFailed`. Called from `WakeProofApp.bootstrapMemoryStore`'s
    /// catch arm. See the field declaration above for the failure-mode rationale.
    @MainActor
    func setMemoryBootstrapFailed(_ failed: Bool) {
        memoryBootstrapFailed = failed
    }

    /// E-M4 (Wave 2.3): bootstrap-time entry point for `requiresReinstall`. Without
    /// this, only the `read()` path could flip the flag — so a UUID-shape failure
    /// during bootstrap stayed silent until the first verify triggered a read.
    /// Now the reinstall banner surfaces immediately on launch.
    @MainActor
    func flipRequiresReinstall() {
        requiresReinstall = true
    }

    /// Setter for `lastBriefingPersistFailedAt`. Pass `true` to record `.now`,
    /// `false` to clear. See the field above for why a Date timestamp (not a
    /// Bool) — callers may want to display elapsed-time copy in the future.
    @MainActor
    func setBriefingPersistFailed(_ failed: Bool) {
        lastBriefingPersistFailedAt = failed ? .now : nil
    }

    /// Derived from the scheduler's phase — `.verifying` is the only state in which a
    /// Claude call is pending. Eliminates the drift risk of maintaining a separate
    /// `isInFlight` flag alongside `scheduler.phase`: any future branch that forgot to
    /// flip the flag would pin it while the scheduler had already moved on. Computed
    /// from the single source of truth.
    var isInFlight: Bool { scheduler?.phase == .verifying }

    // MARK: - Dependencies

    private let client: ClaudeVisionClient
    /// Late-bound scheduler hook — wired in WakeProofApp.bootstrapIfNeeded so the verifier
    /// stays free of `AlarmScheduler` import at type-level for tests.
    ///
    /// L7 (Wave 2.7) resolved by Wave 2.2's serialized bootstrap Task — both this
    /// and `memoryStore` below are assigned inside a single @MainActor Task before
    /// any fire path can reach verify() (see `WakeProofApp.bootstrapIfNeeded`). No
    /// transient window where scheduler is wired but memoryStore isn't: the
    /// serialized Task awaits `bootstrapMemoryStore()` (which wires `memoryStore`)
    /// and only then proceeds; `scheduler` is wired in the same synchronous path
    /// before that Task is spawned. The DEBUG "Fire now" button cannot race either
    /// assignment because it fires through the scheduler, which is already wired
    /// by the time its view is mounted.
    var scheduler: AlarmScheduler?

    /// Late-bound memory store — wired by WakeProofApp.bootstrapIfNeeded. Nil in tests
    /// unless explicitly set; nil-safe: a nil store means memory is never read or written.
    /// See L7 comment on `scheduler` above for the Wave 2.2 serialization rationale.
    var memoryStore: MemoryStore?

    /// Wave 2.4 R14 fix: retry queue for failed memory writes. Default uses the shared
    /// UserDefaults store; tests inject a mock. Not `Optional` — the queue itself is
    /// always available; a nil memoryStore simply means no writes ever get enqueued.
    /// Backlog counts are reachable via `memoryWriteQueue.count()` if a UI consumer
    /// is wired later.
    var memoryWriteQueue: PendingMemoryWriteQueue = PendingMemoryWriteQueue()

    private let logger = Logger(subsystem: LogSubsystem.verification, category: "verifier")

    /// T-C2 (Wave 2.4, 2026-04-26): exposed as `internal` (was `private`) so
    /// tests can verify `bank.count >= 2` and that every entry passes the
    /// MemoryPromptBuilder XML/escape invariants. Deformed entries (empty
    /// strings, pipe characters that break the prompt's table layout, bytes
    /// Claude can't liveness-verify against) used to ship without a regression
    /// gate. The bank itself remains in this file; `internal` access doesn't
    /// expand the API surface beyond `@testable import`.
    static let antiSpoofBank = [
        "Blink twice",
        "Show your right hand",
        "Nod your head"
    ]

    init(client: ClaudeVisionClient = ClaudeAPIClient()) {
        self.client = client
    }

    /// Reset per-fire state. Called by `AlarmScheduler.stopRinging` indirectly via the
    /// observable chain — here it's an explicit method so callers (and tests) can make the
    /// reset obvious in trace.
    func resetForNewFire() {
        lastError = nil
        currentAttemptIndex = 0
        currentAntiSpoofInstruction = nil
    }

    /// Wave 2.4 R14 fix: drain any queued memory writes that failed on a prior launch.
    /// Called from WakeProofApp.bootstrapMemoryStore AFTER memoryStore bootstrap succeeds
    /// so the writer closure can actually land a row. Failures during flush re-enqueue
    /// the row with a bumped retryCount; rows exceeding `maxRetryAttempts` get dropped
    /// with a logger.error (see PendingMemoryWriteQueue.flush).
    func flushMemoryWriteQueue() async {
        guard let memoryStore else {
            logger.info("flushMemoryWriteQueue: no memoryStore wired — leaving queue intact")
            return
        }
        let queue = memoryWriteQueue
        let remaining = await queue.flush { entry, profileDelta in
            try await memoryStore.writeVerdictRow(entry: entry, profileDelta: profileDelta)
        }
        logger.info("flushMemoryWriteQueue: flushed backlog; remaining=\(remaining, privacy: .public)")
    }

    /// Entry point. The caller has already persisted `attempt` with `verdict = .captured`;
    /// we update it in place (no new row) based on Claude's verdict.
    func verify(
        attempt: WakeAttempt,
        baseline: BaselinePhoto,
        context: ModelContext
    ) async {
        guard let scheduler else {
            logger.fault("verify() called but scheduler not wired — alarm will hang in .verifying")
            return
        }
        // Bail BEFORE burning a Claude call if the scheduler isn't in the state it needs
        // to be in. Without this guard, verify() would call Claude (spending credits +
        // latency), then every later scheduler transition would silently refuse because
        // phase != .verifying — user would see no verdict reflected in UI despite the
        // API spend. This guard also dedupes re-entry: if a prior call is still awaiting
        // Claude, phase is `.verifying`, not `.capturing`, and we fail the guard cleanly.
        guard scheduler.phase == .capturing else {
            logger.fault("verify() called with scheduler.phase=\(String(describing: scheduler.phase), privacy: .public) (expected .capturing) — aborting before Claude spend")
            return
        }
        lastError = nil
        // Note: `currentAttemptIndex` is bumped only after Claude actually returns a verdict
        // (see `handleResult`). Network errors and internal guard failures must NOT consume
        // the one-retry budget — otherwise a dropped connection on the first try would coerce
        // the legitimate second try into REJECTED on a RETRY verdict.
        scheduler.beginVerifying()

        guard let stillJPEG = attempt.imageData else {
            logger.error("Attempt has no imageData — cannot verify")
            await finish(attempt: attempt, context: context, verdict: .rejected, reasoning: "Internal error: no image captured.")
            return
        }
        let baselineJPEG = baseline.imageData

        let memoryContext: String?
        if let memoryStore {
            do {
                let snapshot = try await memoryStore.read()
                memoryContext = MemoryPromptBuilder.render(snapshot)
                logger.info("Memory loaded: profile=\(snapshot.profile != nil, privacy: .public) history=\(snapshot.recentHistory.count, privacy: .public)/\(snapshot.totalHistoryCount, privacy: .public)")
            } catch MemoryStoreError.invalidUserUUID {
                // P14 (Stage 6 Wave 2): `.invalidUserUUID` means the stored UUID
                // was externally mutated (path-traversal guard refused to open
                // the directory). This is security-relevant — distinct from the
                // first-install no-memory-yet case which also returns nil. Flip
                // the @Observable flag so AlarmSchedulerView's banner can warn
                // the user to reinstall. Verification still proceeds without
                // memory context so the alarm itself isn't bricked (memory is
                // ancillary), but the signal is no longer silent.
                logger.fault("MemoryStore rejected UUID (invalidUserUUID) — reinstall recommended. Skipping memory context for this verify.")
                requiresReinstall = true
                memoryContext = nil
            } catch {
                logger.fault("MemoryStore read failed, verifying without memory: \(error.localizedDescription, privacy: .public)")
                memoryContext = nil
            }
        } else {
            memoryContext = nil
        }

        let instructionForThisCall = currentAntiSpoofInstruction
        do {
            let result = try await client.verify(
                baselineJPEG: baselineJPEG,
                stillJPEG: stillJPEG,
                baselineLocation: baseline.locationLabel,
                antiSpoofInstruction: instructionForThisCall,
                memoryContext: memoryContext
            )
            await handleResult(result, attempt: attempt, context: context)
        } catch let apiError as ClaudeAPIError {
            await handleAPIError(apiError, attempt: attempt, context: context)
        } catch {
            logger.error("Unexpected verifier error: \(error.localizedDescription, privacy: .public)")
            await finish(attempt: attempt, context: context, verdict: .rejected, reasoning: "Verification failed. Try again.")
        }
    }

    // MARK: - Wave 5 G1: disable-challenge verify

    /// Wave 5 G1 (§12.4-G1): sibling of `verify(...)` for the disable-challenge
    /// flow. Reuses the Claude Opus 4.7 vision call verbatim (same prompt, same
    /// schema) so the evening-self can't cheat by finding a different surface —
    /// it's literally the same verification as morning-self's ring.
    ///
    /// Differences from `verify(...)`:
    ///   * Guards on `scheduler.phase == .disableChallenge` (not `.capturing`).
    ///   * Single-shot: a RETRY verdict is coerced to REJECTED. The disable flow
    ///     is not a wake-up sequence — we're not going to chain anti-spoof
    ///     re-prompts on top of a user trying to toggle the alarm off.
    ///   * On VERIFIED, routes to `scheduler.disableChallengeSucceeded()` (which
    ///     flips `window.isEnabled = false`) — not `finishVerifyingVerified()`
    ///     (which is the ring-resolution surface).
    ///   * On REJECTED / RETRY-coerced / network error, routes to
    ///     `scheduler.disableChallengeFailed(error:)` and the alarm stays
    ///     enabled.
    ///
    /// The WakeAttempt rows written here count toward the audit trail
    /// identically to ring-time rows — by design. A disable challenge is a
    /// verified wake moment; dropping it from streak / investment metrics
    /// would distort the picture.
    func verifyDisableChallenge(
        attempt: WakeAttempt,
        baseline: BaselinePhoto,
        context: ModelContext
    ) async {
        guard let scheduler else {
            logger.fault("verifyDisableChallenge called but scheduler not wired — challenge will hang")
            return
        }
        guard scheduler.phase == .disableChallenge else {
            // Stage 8 MEDIUM 6 fix: previously a bare `return` left the
            // WakeAttempt row at `.captured` forever — the audit trail
            // never closed for this programmer-error path. Now we still
            // abort before Claude spend, but we explicitly mark the
            // attempt REJECTED so the audit row reaches a terminal state.
            // The scheduler's `disableChallengeSucceeded/Failed` guards on
            // `phase == .disableChallenge` so calling finishDisableChallenge
            // here will (a) persist the REJECTED row via updatePersistedAttempt
            // and (b) no-op the scheduler transition (we're already in a
            // wrong phase, triggering a transition from that phase would be
            // incorrect). If the persist itself throws, finishDisableChallenge's
            // own catch logs `.fault` and attempts disableChallengeFailed
            // (which will no-op at the guard — fail-closed is correct here).
            logger.fault("verifyDisableChallenge called with scheduler.phase=\(String(describing: scheduler.phase), privacy: .public) (expected .disableChallenge) — persisting REJECTED and aborting before Claude spend")
            await finishDisableChallenge(
                attempt: attempt,
                context: context,
                verdict: .rejected,
                reasoning: "Verification aborted — phase mismatch at entry"
            )
            return
        }
        lastError = nil

        guard let stillJPEG = attempt.imageData else {
            logger.error("Disable-challenge attempt has no imageData — cannot verify")
            await finishDisableChallenge(
                attempt: attempt,
                context: context,
                verdict: .rejected,
                reasoning: "Internal error: no image captured."
            )
            return
        }
        let baselineJPEG = baseline.imageData

        // Memory context threads through the same as `verify(...)`. A failed
        // read flips `requiresReinstall` on the invalidUserUUID path so the
        // scheduler-view banner surfaces the security warning, matching the
        // ring-flow's handling. Branches are kept synchronized so future
        // Claude prompt / memory-integration changes don't diverge between
        // the two call sites.
        let memoryContext: String?
        if let memoryStore {
            do {
                let snapshot = try await memoryStore.read()
                memoryContext = MemoryPromptBuilder.render(snapshot)
                logger.info("Disable-challenge memory loaded: profile=\(snapshot.profile != nil, privacy: .public) history=\(snapshot.recentHistory.count, privacy: .public)/\(snapshot.totalHistoryCount, privacy: .public)")
            } catch MemoryStoreError.invalidUserUUID {
                logger.fault("MemoryStore rejected UUID (invalidUserUUID) during disable challenge — reinstall recommended.")
                requiresReinstall = true
                memoryContext = nil
            } catch {
                logger.fault("MemoryStore read failed during disable challenge, verifying without memory: \(error.localizedDescription, privacy: .public)")
                memoryContext = nil
            }
        } else {
            memoryContext = nil
        }

        do {
            let result = try await client.verify(
                baselineJPEG: baselineJPEG,
                stillJPEG: stillJPEG,
                baselineLocation: baseline.locationLabel,
                // No anti-spoof instruction on disable — single-shot UX.
                antiSpoofInstruction: nil,
                memoryContext: memoryContext
            )
            await handleDisableChallengeResult(result, attempt: attempt, context: context)
        } catch let apiError as ClaudeAPIError {
            // Uses the neutral "try again" suffix — the disable flow is
            // single-shot and doesn't have a "Prove you're awake" button
            // the user would tap to retry; they just flip the toggle again.
            let userMessage = Self.userMessage(for: apiError, retrySuffix: "try again.")
            await finishDisableChallenge(
                attempt: attempt,
                context: context,
                verdict: .rejected,
                reasoning: userMessage
            )
        } catch {
            logger.error("Unexpected disable-challenge error: \(error.localizedDescription, privacy: .public)")
            await finishDisableChallenge(
                attempt: attempt,
                context: context,
                verdict: .rejected,
                reasoning: "Verification failed. Try again."
            )
        }
    }

    /// Handle the Claude result for a disable challenge. RETRY is coerced to
    /// REJECTED (single-shot flow). The memory-write hook is intentionally
    /// mirrored from `handleResult` so history.jsonl captures disable-challenge
    /// verdicts too — the audit trail contract extends to this surface.
    private func handleDisableChallengeResult(
        _ result: VerificationResult,
        attempt: WakeAttempt,
        context: ModelContext
    ) async {
        // Coerce raw Claude verdict to final UX verdict. RETRY → REJECTED in the
        // disable flow (single-shot) — we do NOT count it as a retry consumed.
        let finalVerdict: WakeAttempt.Verdict
        switch result.verdict {
        case .verified:
            finalVerdict = .verified
        case .rejected, .retry:
            finalVerdict = .rejected
        }

        // Fire-and-forget memory write, mirroring `handleResult` — a disable
        // challenge that landed VERIFIED is a calibration-relevant signal
        // (user proved themselves at an off-ring moment), and REJECTED still
        // contributes a history row. The profile-rewrite gate (VERIFIED-only)
        // matches the ring-flow invariant so a failed disable challenge
        // can't pollute durable state.
        if let memoryStore, let memoryUpdate = result.memoryUpdate {
            // Disable challenges don't count anti-spoof retries — the flow is
            // single-shot; retryCount on the WakeAttempt row stays at its
            // current value (normally 0 at challenge time).
            let entry = MemoryEntry(
                timestamp: .now,
                verdict: finalVerdict.rawValue,
                confidence: result.confidence,
                retryCount: attempt.retryCount,
                note: memoryUpdate.historyNote
            )
            let profileDelta: String? = (finalVerdict == .verified) ? memoryUpdate.profileDelta : nil
            let queue = memoryWriteQueue
            Task { [logger] in
                do {
                    try await memoryStore.writeVerdictRow(entry: entry, profileDelta: profileDelta)
                } catch {
                    logger.error("MemoryStore disable-challenge write failed — enqueueing for retry: \(error.localizedDescription, privacy: .public)")
                    let pending = PendingMemoryWrite(entry: entry, profileDelta: profileDelta)
                    queue.enqueueSync(pending)
                }
            }
        }

        // Observation is persisted on VERIFIED here too — the disable-challenge
        // briefing surface (if one is ever added) can surface it just like
        // MorningBriefingView does. REJECTED rows drop it so verdict narrative
        // stays consistent with H1's handling.
        if finalVerdict == .verified {
            attempt.observation = result.observation
        }

        switch finalVerdict {
        case .verified:
            await finishDisableChallenge(
                attempt: attempt,
                context: context,
                verdict: .verified,
                reasoning: result.reasoning
            )
        case .rejected:
            // Single-shot — tag the raw-RETRY-coerced case in the reasoning so
            // the user's banner captures the nuance if a future UI decides to
            // show it.
            if result.verdict == .retry {
                logger.info("Disable challenge RETRY coerced to REJECTED — single-shot flow")
                await finishDisableChallenge(
                    attempt: attempt,
                    context: context,
                    verdict: .rejected,
                    reasoning: "Verification unclear: \(result.reasoning)"
                )
            } else {
                await finishDisableChallenge(
                    attempt: attempt,
                    context: context,
                    verdict: .rejected,
                    reasoning: result.reasoning
                )
            }
        case .retry, .captured, .timeout, .unresolved:
            // Defensive fallback — finalVerdict only ever resolves to
            // .verified / .rejected above, but a future shape change must
            // fail closed (alarm stays enabled).
            logger.fault("handleDisableChallengeResult reached unreachable finalVerdict case: \(finalVerdict.rawValue, privacy: .public)")
            await finishDisableChallenge(
                attempt: attempt,
                context: context,
                verdict: .rejected,
                reasoning: "Verification hit an unexpected state."
            )
        }
    }

    /// Persist the WakeAttempt row for a disable challenge and drive the
    /// scheduler transition. Mirrors `finish(...)`'s shape but routes to the
    /// G1 transitions (`disableChallengeSucceeded` / `disableChallengeFailed`)
    /// instead of the ring-flow ones. Persistence failure keeps the alarm
    /// enabled (returns caller to .idle via `disableChallengeFailed`) — the
    /// self-commitment contract means a dropped audit row must not silently
    /// let the user slip past the challenge.
    private func finishDisableChallenge(
        attempt: WakeAttempt,
        context: ModelContext,
        verdict: WakeAttempt.Verdict,
        reasoning: String
    ) async {
        do {
            try updatePersistedAttempt(attempt, context: context, verdict: verdict, reasoning: reasoning)
        } catch {
            logger.fault("Disable-challenge persistence failed for verdict \(verdict.rawValue, privacy: .public) — aborting challenge (alarm stays enabled) to protect audit trail")
            scheduler?.disableChallengeFailed(
                error: "Couldn't save verification — try again."
            )
            return
        }
        switch verdict {
        case .verified:
            scheduler?.disableChallengeSucceeded()
        case .rejected:
            scheduler?.disableChallengeFailed(error: reasoning)
        case .retry, .captured, .timeout, .unresolved:
            // Unreachable — handleDisableChallengeResult coerces to .verified
            // or .rejected before reaching here. Defensive log + fail-closed.
            logger.fault("finishDisableChallenge invoked with unexpected verdict \(verdict.rawValue, privacy: .public) — failing challenge")
            scheduler?.disableChallengeFailed(
                error: "Verification hit an unexpected state."
            )
        }
    }

    // MARK: - Private

    private func handleResult(_ result: VerificationResult, attempt: WakeAttempt, context: ModelContext) async {
        // Only count attempts that actually resulted in a Claude verdict. Network errors
        // handled in `handleAPIError` deliberately skip this increment.
        currentAttemptIndex += 1

        // R9 fix: compute the FINAL verdict up-front — including the second-RETRY
        // coercion to REJECTED — so the memory write (below) and the scheduler
        // dispatch (switch below) agree. Previously the memory row captured the
        // raw Claude verdict while updatePersistedAttempt wrote the coerced one,
        // leaving history.jsonl and the SwiftData WakeAttempt divergent on the
        // second-RETRY path. Future memory readers (Layer 3 overnight agent,
        // Layer 4 weekly coach) need rows that reflect the UX-final outcome.
        let finalVerdict: WakeAttempt.Verdict
        switch result.verdict {
        case .verified:
            finalVerdict = .verified
        case .rejected:
            finalVerdict = .rejected
        case .retry:
            finalVerdict = currentAttemptIndex >= 2 ? .rejected : .retry
        }

        // Fire-and-forget memory write. Runs concurrent with the scheduler transition
        // the switch dispatches. Failure is logged but never rewinds the verdict —
        // the alarm UX has already committed to the outcome by this point.
        //
        // IMPORTANT: do NOT use MemoryEntry.makeEntry(fromAttempt:) here — at this
        // call site `attempt.verdict` is still "CAPTURED" (set by CameraCaptureFlow
        // pre-verify). The final verdict only lands inside updatePersistedAttempt
        // which runs AFTER the switch below. Same for retryCount — which is also
        // bumped later. Construct the MemoryEntry with explicit values derived
        // from the Claude response so the on-disk row reflects what Claude actually
        // said, not the stale pre-verify state.
        //
        // R6 fix: use a single MemoryStore.writeVerdictRow(entry:profileDelta:) call
        // so history-append + profile-rewrite are serialised by MemoryStore's actor
        // executor. Previously two verifies in the same fire (RETRY → VERIFIED) each
        // spawned their own `Task { ... }` and Swift doesn't guarantee FIFO across
        // unstructured Tasks even when both inherit MainActor — a later Task's
        // rewriteProfile could land before an earlier Task's appendHistory, leaving
        // the profile updated without a corresponding history row.
        if let memoryStore, let memoryUpdate = result.memoryUpdate {
            // Mirror the retryCount adjustment updatePersistedAttempt applies: only
            // the .retry branch increments. Use finalVerdict (post-coercion) so the
            // row reflects the UX outcome, not the raw Claude verdict.
            let effectiveRetryCount = finalVerdict == .retry ? attempt.retryCount + 1 : attempt.retryCount
            let entry = MemoryEntry(
                timestamp: .now,
                verdict: finalVerdict.rawValue,
                confidence: result.confidence,
                retryCount: effectiveRetryCount,
                note: memoryUpdate.historyNote
            )
            // R1 gate remains here: the profile represents durable TRUTH about this
            // user; only rewrite on a verdict we believe (VERIFIED). REJECTED/RETRY
            // verdicts still append a history row (useful calibration signal) but
            // must NOT override the profile — otherwise failed spoof attempts
            // pollute durable state.
            let profileDelta: String? = (finalVerdict == .verified) ? memoryUpdate.profileDelta : nil
            // Wave 2.4 R14 fix: on memory write failure, enqueue into the retry queue
            // instead of silently logging. The enclosing fire-and-forget Task preserved
            // the "non-fatal" invariant (memory is ancillary; a write hiccup must never
            // rewind the alarm verdict UX), but the catch branch silently dropped the
            // calibration data — degrading Layer 2 fidelity over time with no signal.
            // The retry queue (PendingMemoryWriteQueue, UserDefaults-backed) gives a
            // next-launch flush a chance to land the write.
            //
            // SE3 (Stage 4): the outer Task inherits @MainActor from VisionVerifier.
            // No redundant `MainActor.run` hop needed after enqueue. Queue counts
            // remain reachable via `queue.count()` if a future UI banner needs them.
            //
            // P8 (Stage 6 Wave 1): the catch branch switched from `await queue.enqueue(...)`
            // to synchronous `queue.enqueueSync(...)`. The outer `Task { ... }` still
            // runs the MemoryStore write concurrently with the scheduler transition
            // (that's load-bearing — the await would block verdict UX on disk I/O),
            // but when the write fails the enqueue must not hop-and-lose under app
            // teardown. `enqueueSync` runs under an unfair-lock-guarded UserDefaults
            // write, landing the row before the catch block returns — a tear-down at
            // this boundary still leaves the calibration row on disk for the
            // next-launch flush to pick up.
            let queue = memoryWriteQueue
            Task { [logger] in
                do {
                    try await memoryStore.writeVerdictRow(entry: entry, profileDelta: profileDelta)
                } catch {
                    logger.error("MemoryStore write failed — enqueueing for retry: \(error.localizedDescription, privacy: .public)")
                    let pending = PendingMemoryWrite(entry: entry, profileDelta: profileDelta)
                    queue.enqueueSync(pending)
                }
            }
        }

        // Wave 5 H1 (§12.3-H1): persist Claude's optional observation onto the
        // WakeAttempt row, but ONLY on VERIFIED. REJECTED/RETRY rows drop it —
        // the verdict says "not awake yet" and layering an insight onto that
        // row would produce contradictory UX. Writing before the switch below
        // lets the same SwiftData save that the verdict update performs include
        // the observation field — no extra save cycle.
        if finalVerdict == .verified {
            attempt.observation = result.observation
        }

        switch finalVerdict {
        case .verified:
            await finish(attempt: attempt, context: context, verdict: .verified, reasoning: result.reasoning)
        case .rejected:
            // Two sub-paths:
            //   (a) Claude returned REJECTED directly → user sees Claude's reasoning
            //   (b) Second-RETRY was coerced to REJECTED → prepend the "still uncertain after retry" context
            if result.verdict == .retry {
                logger.warning("Second RETRY verdict coerced to REJECTED — one anti-spoof attempt per fire")
                await finish(attempt: attempt, context: context, verdict: .rejected,
                             reasoning: "Verification still uncertain after retry: \(result.reasoning)")
            } else {
                await finish(attempt: attempt, context: context, verdict: .rejected, reasoning: result.reasoning)
            }
        case .retry:
            // First RETRY — pick an anti-spoof instruction and transition to that phase.
            //
            // E-I2 (Wave 2.3, 2026-04-26): the assignment to
            // `currentAntiSpoofInstruction` used to happen BEFORE the persist
            // guard, so a persist failure (early-return) would leave the
            // instruction polluting state for the next fire's read at line 228.
            // Now we hold the instruction in a local until persist succeeds, so
            // the early-return path doesn't observe a half-applied state.
            let instruction = Self.antiSpoofBank.randomElement() ?? "Blink twice"
            guard persistOrFallbackToRinging(
                attempt, context: context, verdict: .retry, reasoning: result.reasoning,
                fallbackMessage: "Retry save failed — tap \"Prove you're awake\" to retry."
            ) else { return }
            currentAntiSpoofInstruction = instruction
            scheduler?.beginAntiSpoofPrompt(instruction: instruction)
        case .captured, .timeout, .unresolved:
            // Defensive branch; unreachable by current `VerificationResult.Verdict` cases
            // (finalVerdict only ever resolves to verified/rejected/retry). Logger.fault
            // ships as audit trail if VerdictEnum ever grows — the previous test
            // `testUnexpectedVerdictFallbackReturnsToRinging` (deleted in Wave 2.5) was a
            // strict subset of the REJECTED-path test and couldn't exercise this branch
            // without inventing a new Verdict case. See VisionVerifierTests M9 comment.
            logger.fault("handleResult reached unreachable finalVerdict case: \(finalVerdict.rawValue, privacy: .public)")
            await finish(attempt: attempt, context: context, verdict: .rejected, reasoning: "Verification hit an unexpected state.")
        }
    }

    private func handleAPIError(_ error: ClaudeAPIError, attempt: WakeAttempt, context: ModelContext) async {
        // Network errors become REJECTED rather than RETRY. Rationale: RETRY spends the one
        // anti-spoof chance on a condition the user can't fix, and the retry re-uploads the
        // same images so a transient network blip just delays the same outcome. REJECTED
        // keeps the alarm ringing and lets the user retry by tapping "Prove you're awake"
        // again — which gives us a *new* capture (fresher, possibly on a different route).
        //
        // Wave 5 G1 (§12.4-G1): `userMessage(for:retrySuffix:)` is the shared
        // error-to-copy mapping consumed by both this ring-path handler AND
        // the disable-challenge path in `verifyDisableChallenge`. Copy
        // divergence (ring says "tap \"Prove you're awake\" to retry", disable
        // says "try again.") is preserved via the retrySuffix argument — the
        // SHAPE of the error mapping is identical so future ClaudeAPIError
        // cases only need to land in one switch.
        let userMessage = Self.userMessage(
            for: error,
            retrySuffix: "tap \"Prove you're awake\" to retry."
        )
        await finish(attempt: attempt, context: context, verdict: .rejected, reasoning: userMessage)
    }

    /// Wave 5 G1: shared ClaudeAPIError → user-facing copy. The ring-path
    /// appends "tap \"Prove you're awake\" to retry." (there's a button for
    /// that); the disable-challenge path appends "try again." (single-shot,
    /// user just flips the toggle again). One switch, one place to update
    /// when a new ClaudeAPIError case is added — without this extraction the
    /// two call sites would drift silently.
    ///
    /// `nonisolated static` so it can be referenced without touching the
    /// @Observable actor surface. The switch is pure-functional and has no
    /// side effects.
    nonisolated private static func userMessage(
        for error: ClaudeAPIError,
        retrySuffix: String
    ) -> String {
        switch error {
        case .missingProxyToken:
            return "Proxy token missing. Check Secrets.swift in the project."
        case .timeout, .transportFailed:
            return "Couldn't reach Claude — \(retrySuffix)"
        case .httpError(let status, _):
            // L10 (Wave 2.7): unify 502 messaging. Our Vercel proxy returns a 502 with
            // `{error:{type:"upstream_fetch_failed"}}` when it can't reach Anthropic;
            // ClaudeAPIClient already decodes that envelope and throws .transportFailed
            // (handled above). An Anthropic-native 502 (non-envelope body) falls through
            // here — same root cause (Anthropic unreachable) but different user message.
            // Map 502 to the transport-equivalent copy so the user experience doesn't
            // diverge based on WHICH layer of the chain was unreachable. Keep the
            // httpError case distinct in logs (still `status=502` in the audit trail).
            if status == 502 {
                return "Couldn't reach Claude — \(retrySuffix)"
            } else {
                return "Claude returned HTTP \(status) — \(retrySuffix)"
            }
        case .decodingFailed(let underlying):
            // Persist the underlying parse/shape error into reasoning so the audit trail
            // captures what went wrong at the protocol boundary (missing content block,
            // malformed JSON, unexpected error body) rather than just a generic message.
            return "Couldn't read Claude's response (\(underlying.localizedDescription)) — \(retrySuffix)"
        case .emptyResponse, .invalidURL:
            return "Couldn't read Claude's response — \(retrySuffix)"
        }
    }

    private func finish(attempt: WakeAttempt, context: ModelContext, verdict: WakeAttempt.Verdict, reasoning: String) async {
        guard persistOrFallbackToRinging(
            attempt, context: context, verdict: verdict, reasoning: reasoning,
            fallbackMessage: "Verified but couldn't save — tap \"Prove you're awake\" to retry."
        ) else { return }
        switch verdict {
        case .verified:
            scheduler?.finishVerifyingVerified()
            resetForNewFire()
        case .rejected:
            scheduler?.returnToRingingAfterVerifying(error: "Verification failed: \(reasoning)")
        case .retry, .captured, .timeout, .unresolved:
            // Unreachable from current caller paths — `.retry` takes the handleResult
            // branch before finish; `.captured/.timeout/.unresolved` never flow here.
            // Kept as a defensive fallback so a future refactor that introduces such a
            // path can't silently pin the alarm in `.verifying` with no UI recovery.
            logger.fault("finish() invoked with unexpected verdict \(verdict.rawValue, privacy: .public) — falling back to ringing")
            scheduler?.returnToRingingAfterVerifying(error: "Verification hit an unexpected state. Tap \"Prove you're awake\" to retry.")
            resetForNewFire()
        }
    }

    /// Save the verdict row; on failure, drop back to ringing with a verbose banner so
    /// the user retries (fresh capture → fresh row). Returns true on success, false when
    /// the fallback fired — callers early-return on false so they don't race a stale row
    /// with a downstream scheduler transition. The self-commitment contract depends on
    /// this invariant: never transition to `.idle` (or `.antiSpoofPrompt`) silently when
    /// the audit row didn't land.
    private func persistOrFallbackToRinging(
        _ attempt: WakeAttempt,
        context: ModelContext,
        verdict: WakeAttempt.Verdict,
        reasoning: String,
        fallbackMessage: String
    ) -> Bool {
        do {
            try updatePersistedAttempt(attempt, context: context, verdict: verdict, reasoning: reasoning)
            return true
        } catch {
            logger.fault("Persistence failed for verdict \(verdict.rawValue, privacy: .public) — keeping alarm in .ringing to protect audit trail")
            scheduler?.returnToRingingAfterVerifying(error: fallbackMessage)
            return false
        }
    }

    /// Persists verdict + reasoning and saves the context. Throws on save failure so
    /// the caller (`persistOrFallbackToRinging`) can own the recovery decision.
    private func updatePersistedAttempt(_ attempt: WakeAttempt, context: ModelContext, verdict: WakeAttempt.Verdict, reasoning: String) throws {
        attempt.verdict = verdict.rawValue
        attempt.verdictReasoning = reasoning
        // retryCount counts anti-spoof retries, not verification attempts overall.
        if verdict == .retry { attempt.retryCount += 1 }
        do {
            try context.save()
            logger.info("WakeAttempt updated: verdict=\(verdict.rawValue, privacy: .public) retryCount=\(attempt.retryCount, privacy: .public)")
        } catch {
            logger.error("Failed to persist verdict update: \(error.localizedDescription, privacy: .public)")
            context.rollback()
            throw error
        }
    }
}
