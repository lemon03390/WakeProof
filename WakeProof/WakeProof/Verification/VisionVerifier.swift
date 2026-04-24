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
    var memoryWriteQueue: PendingMemoryWriteQueue = PendingMemoryWriteQueue()

    /// @Observable sidecar for the AlarmSchedulerView system-banner. Updated via
    /// `refreshMemoryWriteBacklog()` after each enqueue and after flush. Backlog of
    /// >5 entries surfaces a "Memory writes are backlogged (N pending) — calibration
    /// may be stale" banner (threshold defined in AlarmSchedulerView).
    let memoryWriteBacklog = MemoryWriteBacklog()

    private let logger = Logger(subsystem: "com.wakeproof.verification", category: "verifier")

    private static let antiSpoofBank = [
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
        let backlog = memoryWriteBacklog
        let queue = memoryWriteQueue
        let remaining = await queue.flush { entry, profileDelta in
            try await memoryStore.writeVerdictRow(entry: entry, profileDelta: profileDelta)
        }
        await MainActor.run { backlog.update(remaining) }
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
            let queue = memoryWriteQueue
            let backlog = memoryWriteBacklog
            Task { [logger] in
                do {
                    try await memoryStore.writeVerdictRow(entry: entry, profileDelta: profileDelta)
                } catch {
                    logger.error("MemoryStore write failed — enqueueing for retry: \(error.localizedDescription, privacy: .public)")
                    let pending = PendingMemoryWrite(entry: entry, profileDelta: profileDelta)
                    await queue.enqueue(pending)
                    let newCount = await queue.count()
                    await MainActor.run { backlog.update(newCount) }
                }
            }
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
            let instruction = Self.antiSpoofBank.randomElement() ?? "Blink twice"
            currentAntiSpoofInstruction = instruction
            guard persistOrFallbackToRinging(
                attempt, context: context, verdict: .retry, reasoning: result.reasoning,
                fallbackMessage: "Retry save failed — tap \"Prove you're awake\" to retry."
            ) else { return }
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
        let userMessage: String
        switch error {
        case .missingProxyToken:
            userMessage = "Proxy token missing. Check Secrets.swift in the project."
        case .timeout, .transportFailed:
            userMessage = "Couldn't reach Claude — tap \"Prove you're awake\" to retry."
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
                userMessage = "Couldn't reach Claude — tap \"Prove you're awake\" to retry."
            } else {
                userMessage = "Claude returned HTTP \(status) — tap \"Prove you're awake\" to retry."
            }
        case .decodingFailed(let underlying):
            // Persist the underlying parse/shape error into reasoning so the audit trail
            // captures what went wrong at the protocol boundary (missing content block,
            // malformed JSON, unexpected error body) rather than just a generic message.
            userMessage = "Couldn't read Claude's response (\(underlying.localizedDescription)) — tap \"Prove you're awake\" to retry."
        case .emptyResponse, .invalidURL:
            userMessage = "Couldn't read Claude's response — tap \"Prove you're awake\" to retry."
        }
        await finish(attempt: attempt, context: context, verdict: .rejected, reasoning: userMessage)
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
