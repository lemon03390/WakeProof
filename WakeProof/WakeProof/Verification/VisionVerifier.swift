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

    private(set) var isInFlight: Bool = false
    private(set) var lastError: String?
    private(set) var currentAttemptIndex: Int = 0        // 0 before first call, 1 after first, 2 after retry
    private(set) var currentAntiSpoofInstruction: String?

    // MARK: - Dependencies

    private let client: ClaudeVisionClient
    /// Late-bound scheduler hook — wired in WakeProofApp.bootstrapIfNeeded so the verifier
    /// stays free of `AlarmScheduler` import at type-level for tests.
    var scheduler: AlarmScheduler?

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
        isInFlight = false
        lastError = nil
        currentAttemptIndex = 0
        currentAntiSpoofInstruction = nil
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
        guard !isInFlight else {
            logger.warning("verify() ignored — already in flight")
            return
        }
        // B9 fix: bail BEFORE burning a Claude call if the scheduler isn't in the
        // state it needs to be in. Without this guard, verify() would call Claude
        // (spending credits + latency), then every later scheduler transition would
        // silently refuse because phase != .verifying — user would see no verdict
        // reflected in UI despite the API spend.
        guard scheduler.phase == .capturing else {
            logger.fault("verify() called with scheduler.phase=\(String(describing: scheduler.phase), privacy: .public) (expected .capturing) — aborting before Claude spend")
            return
        }
        isInFlight = true
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

        let instructionForThisCall = currentAntiSpoofInstruction
        do {
            let result = try await client.verify(
                baselineJPEG: baselineJPEG,
                stillJPEG: stillJPEG,
                baselineLocation: baseline.locationLabel,
                antiSpoofInstruction: instructionForThisCall
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
        switch result.verdict {
        case .verified:
            await finish(attempt: attempt, context: context, verdict: .verified, reasoning: result.reasoning)
        case .rejected:
            await finish(attempt: attempt, context: context, verdict: .rejected, reasoning: result.reasoning)
        case .retry:
            if currentAttemptIndex >= 2 {
                // We already did one anti-spoof retry; another RETRY burns ceiling and can't
                // improve. Coerce to REJECTED so the user re-captures via the ringing path
                // with full context of why.
                logger.warning("Second RETRY verdict coerced to REJECTED — one anti-spoof attempt per fire")
                await finish(attempt: attempt, context: context, verdict: .rejected,
                             reasoning: "Verification still uncertain after retry: \(result.reasoning)")
                return
            }
            let instruction = Self.antiSpoofBank.randomElement() ?? "Blink twice"
            currentAntiSpoofInstruction = instruction
            do {
                try updatePersistedAttempt(attempt, context: context, verdict: .retry, reasoning: result.reasoning)
            } catch {
                // B10 fix: audit-row integrity matters even on RETRY. If we can't save
                // the RETRY marker, don't hand the user an anti-spoof prompt that
                // would race a stale audit row. Drop back to ringing instead.
                logger.fault("Persistence failed on RETRY — keeping alarm in .ringing to protect audit trail")
                isInFlight = false
                scheduler?.returnToRingingAfterVerifying(error: "Retry save failed — tap \"Prove you're awake\" to retry.")
                return
            }
            isInFlight = false
            scheduler?.beginAntiSpoofPrompt(instruction: instruction)
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
            userMessage = "Claude returned HTTP \(status) — tap \"Prove you're awake\" to retry."
        case .decodingFailed(let underlying):
            // R1 fix: persist the underlying parse/shape error into reasoning so the
            // audit trail captures what went wrong at the protocol boundary. Without
            // this the user and any future forensic reader both see "Couldn't read
            // Claude's response" with no signal about whether it was a missing content
            // block, malformed JSON, or an unexpected error body.
            userMessage = "Couldn't read Claude's response (\(underlying.localizedDescription)) — tap \"Prove you're awake\" to retry."
        case .emptyResponse, .invalidURL:
            userMessage = "Couldn't read Claude's response — tap \"Prove you're awake\" to retry."
        }
        await finish(attempt: attempt, context: context, verdict: .rejected, reasoning: userMessage)
    }

    private func finish(attempt: WakeAttempt, context: ModelContext, verdict: WakeAttempt.Verdict, reasoning: String) async {
        do {
            try updatePersistedAttempt(attempt, context: context, verdict: verdict, reasoning: reasoning)
        } catch {
            // B10 fix: the self-commitment contract depends on audit integrity. If we
            // can't save the verdict row, DO NOT transition the scheduler to `.idle` on
            // VERIFIED — that would stop the alarm with no record, letting a user "pass"
            // verification without a persistent trace. Keep the alarm ringing and
            // surface the save failure so the user retries (which creates a fresh attempt
            // row on the next capture).
            logger.fault("Persistence failed for verdict \(verdict.rawValue, privacy: .public) — keeping alarm in .ringing to protect audit trail")
            isInFlight = false
            scheduler?.returnToRingingAfterVerifying(error: "Verified but couldn't save — tap \"Prove you're awake\" to retry.")
            return
        }
        isInFlight = false
        switch verdict {
        case .verified:
            scheduler?.finishVerifyingVerified()
            resetForNewFire()
        case .rejected:
            scheduler?.returnToRingingAfterVerifying(error: "Verification failed: \(reasoning)")
        case .retry, .captured, .timeout, .unresolved:
            // B8 fix: these verdicts aren't emitted by the current caller paths, but
            // if a future refactor introduces one, the `logger.fault`-only path left
            // the alarm pinned in `.verifying` with no UI and no recovery affordance.
            // Explicit fallback to ringing keeps the state machine closed.
            logger.fault("finish() invoked with unexpected verdict \(verdict.rawValue, privacy: .public) — falling back to ringing")
            scheduler?.returnToRingingAfterVerifying(error: "Verification hit an unexpected state. Tap \"Prove you're awake\" to retry.")
            resetForNewFire()
        }
    }

    /// Persists verdict + reasoning and saves the context. Throws on save failure so the
    /// caller (`finish` / `handleResult`) can decide the recovery UX — the self-commitment
    /// contract requires that we never transition to `.idle` silently when the audit row
    /// didn't land, so callers keep the alarm ringing rather than swallowing.
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
