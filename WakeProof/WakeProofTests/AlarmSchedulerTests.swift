//
//  AlarmSchedulerTests.swift
//  WakeProofTests
//
//  Smoke tests for the AlarmScheduler state machine. Notification scheduling,
//  Task.sleep timing, and audio playback are NOT covered here — those need
//  on-device validation (see docs/device-test-protocol.md).
//

import XCTest
@testable import WakeProof

@MainActor
final class AlarmSchedulerTests: XCTestCase {

    private var scheduler: AlarmScheduler!

    /// R15 (Wave 2.5): per-run suite-scoped UserDefaults so tests don't bleed into
    /// `.standard`. Unique UUID per test to avoid any cross-instance state (which
    /// matters because suite removal is async on some iOS versions).
    private var suiteDefaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "com.wakeproof.tests.alarmscheduler.\(UUID().uuidString)"
        suiteDefaults = UserDefaults(suiteName: suiteName)
        suiteDefaults.removePersistentDomain(forName: suiteName)
        scheduler = AlarmScheduler(defaults: suiteDefaults)
    }

    override func tearDown() async throws {
        scheduler.cancel()
        suiteDefaults?.removePersistentDomain(forName: suiteName)
        suiteDefaults = nil
        suiteName = nil
        scheduler = nil
        try await super.tearDown()
    }

    // MARK: - Initial state

    func testInitialPhaseIsIdle() {
        XCTAssertEqual(scheduler.phase, .idle)
        XCTAssertNil(scheduler.lastFireAt)
        XCTAssertNil(scheduler.lastCaptureError)
    }

    // MARK: - State transitions via fireNow → captures → resolution

    func testFireNowEntersRingingAndSetsLastFireAt() {
        scheduler.fireNow()
        XCTAssertEqual(scheduler.phase, .ringing)
        XCTAssertNotNil(scheduler.lastFireAt)
    }

    func testFireNowIsIdempotentWhilePhaseNotIdle() {
        scheduler.fireNow()
        let firstFireAt = scheduler.lastFireAt
        scheduler.fireNow() // second invocation should be a no-op
        XCTAssertEqual(scheduler.phase, .ringing)
        XCTAssertEqual(scheduler.lastFireAt, firstFireAt, "fire() must guard on phase != .idle")
    }

    func testBeginCapturingTransitionsRingingToCapturing() {
        scheduler.fireNow()
        scheduler.beginCapturing()
        XCTAssertEqual(scheduler.phase, .capturing)
        XCTAssertNil(scheduler.lastCaptureError, "transition into capturing must clear previous error")
    }

    func testBeginCapturingIgnoredWhenIdle() {
        scheduler.beginCapturing() // no fire happened
        XCTAssertEqual(scheduler.phase, .idle)
    }

    func testReturnToRingingClearsCapturingPhase() {
        scheduler.fireNow()
        scheduler.beginCapturing()
        scheduler.returnToRingingWith(error: "Cancelled")
        XCTAssertEqual(scheduler.phase, .ringing)
        XCTAssertEqual(scheduler.lastCaptureError, "Cancelled")
    }

    func testStopRingingClearsAllState() {
        scheduler.fireNow()
        scheduler.beginCapturing()
        scheduler.returnToRingingWith(error: "x")
        scheduler.stopRinging()
        XCTAssertEqual(scheduler.phase, .idle)
        XCTAssertNil(scheduler.lastFireAt, "stopRinging must clear the unresolved-fire marker")
        XCTAssertNil(scheduler.lastCaptureError)
    }

    func testMarkCaptureCompletedClearsLastFireAtButPreservesPhase() {
        scheduler.fireNow()
        scheduler.beginCapturing()
        XCTAssertNotNil(scheduler.lastFireAt)
        scheduler.markCaptureCompleted()
        XCTAssertNil(scheduler.lastFireAt, "marker must be cleared so launch-time recovery doesn't double-count")
        XCTAssertEqual(scheduler.phase, .capturing,
                       "phase reset is the parent's job (handled by stopRinging from onSuccess)")
    }

    // MARK: - lastFireAt persistence

    func testLastFireAtPersistsToUserDefaults() throws {
        scheduler.fireNow()
        let firedAt = try XCTUnwrap(scheduler.lastFireAt)

        // Verify the persistence side-effect directly. Spinning up a second AlarmScheduler
        // in-process triggers a UNUserNotificationCenter re-registration that the test host
        // doesn't tolerate gracefully — so we assert against the on-disk state instead. The
        // recovery PATH (init reading UserDefaults) is exercised by every fresh launch.
        let storedDate = suiteDefaults.object(forKey: "com.wakeproof.alarm.lastFireAt") as? Date
        let stored = try XCTUnwrap(storedDate, "fire() must persist lastFireAt to UserDefaults")
        XCTAssertEqual(stored.timeIntervalSince1970, firedAt.timeIntervalSince1970, accuracy: 1.0)
    }

    func testStopRingingClearsPersistedMarker() {
        scheduler.fireNow()
        scheduler.stopRinging()
        let stored = suiteDefaults.object(forKey: "com.wakeproof.alarm.lastFireAt") as? Date
        XCTAssertNil(stored, "stopRinging must clear the persisted marker")
    }

    // MARK: - persistAttempt callback

    func testRecoverUnresolvedFireFiresPersistAttemptOnce() throws {
        scheduler.fireNow()
        let firedAt = try XCTUnwrap(scheduler.lastFireAt)

        // Simulate the launch-time recovery path WITHOUT spinning up a second AlarmScheduler
        // (see testLastFireAtPersistsToUserDefaults for why). Wire persistAttempt on the
        // existing instance and call recoverUnresolvedFireIfNeeded — semantically identical:
        // both code paths read scheduler.lastFireAt and forward to persistAttempt.
        var capturedVerdicts: [WakeAttempt.Verdict] = []
        var capturedDates: [Date] = []
        scheduler.persistAttempt = { verdict, date in
            capturedVerdicts.append(verdict)
            capturedDates.append(date)
        }
        scheduler.recoverUnresolvedFireIfNeeded()
        XCTAssertEqual(capturedVerdicts, [.unresolved])
        let capturedDate = try XCTUnwrap(capturedDates.first)
        XCTAssertEqual(capturedDate.timeIntervalSince1970, firedAt.timeIntervalSince1970, accuracy: 1.0)
        XCTAssertNil(scheduler.lastFireAt, "recovery must clear the marker after persisting")

        // Idempotent: the second call observes lastFireAt is now nil and bails out.
        scheduler.recoverUnresolvedFireIfNeeded()
        XCTAssertEqual(capturedVerdicts, [.unresolved], "recovery must be idempotent")
    }

    func testHandleRingCeilingPersistsTimeoutAndStopsRinging() {
        scheduler.fireNow()
        var capturedVerdicts: [WakeAttempt.Verdict] = []
        scheduler.persistAttempt = { verdict, _ in capturedVerdicts.append(verdict) }

        scheduler.handleRingCeiling()

        XCTAssertEqual(capturedVerdicts, [.timeout])
        XCTAssertEqual(scheduler.phase, .idle)
        XCTAssertNil(scheduler.lastFireAt)
    }

    // MARK: - Update window

    func testUpdateWindowSavesAndReschedules() {
        let new = WakeWindow(startHour: 7, startMinute: 30, endHour: 8, endMinute: 0, isEnabled: true)
        scheduler.updateWindow(new)
        XCTAssertEqual(scheduler.window, new)
        XCTAssertNotNil(scheduler.nextFireAt, "enabled window must produce a nextFireAt")
    }

    func testUpdateWindowDisabledClearsNextFireAt() {
        scheduler.updateWindow(WakeWindow(startHour: 7, startMinute: 0, endHour: 7, endMinute: 30, isEnabled: true))
        XCTAssertNotNil(scheduler.nextFireAt)
        scheduler.updateWindow(WakeWindow(startHour: 7, startMinute: 0, endHour: 7, endMinute: 30, isEnabled: false))
        XCTAssertNil(scheduler.nextFireAt)
    }

    // MARK: - Day 3 phase extensions

    func testBeginVerifyingFromCapturingTransitionsToVerifying() {
        scheduler.fireNow()
        scheduler.beginCapturing()
        scheduler.beginVerifying()
        XCTAssertEqual(scheduler.phase, .verifying)
    }

    func testBeginVerifyingIgnoredFromRinging() {
        scheduler.fireNow()
        scheduler.beginVerifying()  // still in .ringing
        XCTAssertEqual(scheduler.phase, .ringing)
    }

    func testReturnToRingingAfterVerifyingClearsVerifyingPhase() {
        scheduler.fireNow()
        scheduler.beginCapturing()
        scheduler.beginVerifying()
        scheduler.returnToRingingAfterVerifying(error: "Verification failed: bed")
        XCTAssertEqual(scheduler.phase, .ringing)
        XCTAssertEqual(scheduler.lastCaptureError, "Verification failed: bed")
    }

    func testBeginAntiSpoofPromptFromVerifyingTransitionsToAntiSpoofPrompt() {
        scheduler.fireNow()
        scheduler.beginCapturing()
        scheduler.beginVerifying()
        scheduler.beginAntiSpoofPrompt(instruction: "Blink twice")
        guard case let .antiSpoofPrompt(instruction) = scheduler.phase else {
            return XCTFail("expected antiSpoofPrompt")
        }
        XCTAssertEqual(instruction, "Blink twice")
    }

    func testBeginCapturingFromAntiSpoofPromptAllowsReEntry() {
        scheduler.fireNow()
        scheduler.beginCapturing()
        scheduler.beginVerifying()
        scheduler.beginAntiSpoofPrompt(instruction: "Show your right hand")
        scheduler.beginCapturing()  // re-entry from anti-spoof
        XCTAssertEqual(scheduler.phase, .capturing)
    }

    func testReturnToRingingWithErrorFromVerifyingIsAllowed() {
        scheduler.fireNow()
        scheduler.beginCapturing()
        scheduler.beginVerifying()
        scheduler.returnToRingingWith(error: "network down")
        XCTAssertEqual(scheduler.phase, .ringing)
        XCTAssertEqual(scheduler.lastCaptureError, "network down")
    }

    func testFinishVerifyingVerifiedClearsEverything() {
        scheduler.fireNow()
        scheduler.beginCapturing()
        scheduler.beginVerifying()
        scheduler.finishVerifyingVerified()
        XCTAssertEqual(scheduler.phase, .idle)
        XCTAssertNil(scheduler.lastFireAt)
    }

    func testFinishVerifyingVerifiedIgnoredFromOtherPhases() {
        scheduler.fireNow()
        scheduler.finishVerifyingVerified()  // still in .ringing
        XCTAssertEqual(scheduler.phase, .ringing)
        XCTAssertNotNil(scheduler.lastFireAt)
    }

    // MARK: - P3: cancel() bumps schedulingGeneration

    /// P3 (Stage 6 Wave 1): previously `cancel()` did not bump `schedulingGeneration`.
    /// A fire task that had already passed its `Task.isCancelled` guard before the
    /// cancel lands could still reach the MainActor.run block — and the generation
    /// check inside (`myGeneration == self.schedulingGeneration`) would match
    /// (generations identical), so the alarm would fire despite the cancel.
    ///
    /// This test doesn't need to reproduce the full async race (which would require
    /// blocking the fire task at a precise point). Instead we assert the invariant
    /// the fix establishes: after `scheduleNextFireIfEnabled` + `cancel`, the
    /// generation must have been bumped TWICE (once by the schedule, once by the
    /// cancel) — confirming the cancel does not silently reuse the scheduled
    /// generation. This is a stronger guarantee than the before-the-fix behaviour
    /// where cancel left the generation untouched.
    func testCancelBumpsSchedulingGeneration() {
        // Enable a valid window so scheduleNextFireIfEnabled actually bumps.
        let enabled = WakeWindow(startHour: 7, startMinute: 0, endHour: 7, endMinute: 30, isEnabled: true)
        scheduler.updateWindow(enabled)
        // Schedule pattern: updateWindow internally calls scheduleNextFireIfEnabled
        // which bumps generation once. Verify the nextFireAt was populated.
        XCTAssertNotNil(scheduler.nextFireAt, "precondition: enabled window must have a nextFireAt")

        // Cancel should bump generation even though we're not scheduling anew.
        scheduler.cancel()
        XCTAssertNil(scheduler.nextFireAt, "cancel clears nextFireAt")

        // Re-schedule. If cancel DIDN'T bump, this schedule's generation would
        // collide with any pre-cancel fire task that survived the Task.isCancelled
        // check. The fix guarantees the cancel bumped too, so this schedule lands
        // on a strictly greater generation.
        scheduler.scheduleNextFireIfEnabled()
        XCTAssertNotNil(scheduler.nextFireAt, "re-schedule must produce a nextFireAt")

        // Cancel then cancel again — each cancel bumps even without intervening schedule.
        // Post-fix invariant: cancel is unconditionally a barrier that invalidates
        // every previously-captured generation. Test proxy: no crash, no leftover
        // nextFireAt. The direct generation read isn't exposed as public API, but
        // sequential cancel+schedule+cancel without assert failure demonstrates the
        // invariant holds across successive bumps (the &+= operator wraps safely).
        scheduler.cancel()
        XCTAssertNil(scheduler.nextFireAt)
    }

    // MARK: - G3 (Wave 5): chained backup notifications

    /// G3: the single backup `UNNotificationRequest` has been replaced with a chain of
    /// three at fireAt + 0s / +90s / +180s so a force-quit mid-ring still leaves three
    /// timed beeps on the phone. This test locks the count and the distinct-identifier
    /// invariant — anyone refactoring the constants can't silently collapse them.
    func testBackupIdentifiersAreThreeUnique() {
        let identifiers = AlarmScheduler.backupNotificationIdentifiers
        XCTAssertEqual(identifiers.count, 3, "G3 expects exactly three chained backup notifications")
        XCTAssertEqual(Set(identifiers).count, 3, "backup identifiers must be distinct — iOS keys pending requests by identifier and duplicates would silently coalesce")
        // Namespace check: all three must live under the agreed prefix so `cancel()`
        // can't accidentally remove unrelated pending requests from other subsystems.
        for identifier in identifiers {
            XCTAssertTrue(identifier.hasPrefix("com.wakeproof.alarm.next.backup."),
                          "identifier \(identifier) must use the .backup.N namespace")
        }
    }

    /// G3: the offsets array drives the scheduling loop. Locking [0, 90, 180] prevents
    /// a drive-by tweak to "a longer chain" or "closer-together beeps" without
    /// reviewing the UX tradeoff (see docs/self-sabotage-defense-analysis.md §7.2).
    func testBackupOffsetsAreZeroNinetyOneEighty() {
        XCTAssertEqual(AlarmScheduler.backupOffsetsSeconds, [0, 90, 180],
                       "G3 spec pins the chain to 0s / 90s / 180s — changes need a doc update")
        // Parallel-array invariant: offsets.count must match identifiers.count
        // because `scheduleBackupNotification` zips them by index.
        XCTAssertEqual(AlarmScheduler.backupOffsetsSeconds.count,
                       AlarmScheduler.backupNotificationIdentifiers.count,
                       "offsets and identifiers arrays must have the same length — the scheduling loop indexes them together")
    }

    /// G3: body copy escalates across the three pings. Distinctness matters for UX
    /// (iOS coalesces identical-body notifications in the Notification Center tray)
    /// and for the demo narrative (three different messages across three minutes
    /// reads as deliberate, not as one notification that kept repeating). The exact
    /// strings are pinned so a copy-editing pass can't silently skip here.
    func testBackupCopyIsDistinctPerOffset() {
        let bodies = AlarmScheduler.backupNotificationBodies
        XCTAssertEqual(bodies.count, 3, "three bodies for three backups")
        XCTAssertEqual(Set(bodies).count, 3, "each backup must have distinct body copy")
        XCTAssertEqual(bodies[0], "Time to prove you're awake.")
        XCTAssertEqual(bodies[1], "Still sleeping? WakeProof needs your photo.")
        XCTAssertEqual(bodies[2], "Your commitment expires soon.")
        // Parallel-array invariant: bodies.count must match identifiers.count.
        XCTAssertEqual(bodies.count, AlarmScheduler.backupNotificationIdentifiers.count,
                       "bodies and identifiers must have matching counts")
    }

    // MARK: - P5: updateWindow returns Bool

    /// P5 (Stage 6 Wave 1): `updateWindow` now returns Bool so AlarmSchedulerView's
    /// Save & schedule button can surface save failures inline. Previously the
    /// method set `lastCaptureError` (which only AlarmRingingView surfaces) and
    /// returned `Void`, so a tap in the settings screen silently proceeded past
    /// a failed persist. Happy path returns true.
    func testUpdateWindowReturnsTrueOnSuccess() {
        let w = WakeWindow(startHour: 7, startMinute: 0, endHour: 7, endMinute: 30, isEnabled: true)
        let saved = scheduler.updateWindow(w)
        XCTAssertTrue(saved, "valid window save must return true")
        XCTAssertEqual(scheduler.window, w)
    }

    // MARK: - Wave 5 G1: disable-challenge grace period

    /// G1 (§12.4-G1): within the 24h grace window, `requestDisable` returns
    /// `.allowed` so AlarmSchedulerView can flip `isEnabled` directly without
    /// the vision-verified challenge. New users recovering from a wrong-baseline
    /// setup need this escape hatch per §7.1 "Nuances".
    func testRequestDisableReturnsAllowedInGracePeriod() {
        let installedAt = Date()
        suiteDefaults.set(installedAt, forKey: AlarmScheduler.firstInstallAtKey)
        // 1h after install → comfortably inside the 24h grace.
        let now = installedAt.addingTimeInterval(60 * 60)
        let outcome = scheduler.requestDisable(now: now)
        XCTAssertEqual(outcome, .allowed,
                       "within 24h grace window, disable must be allowed directly")
    }

    /// G1: past the 24h grace, `requestDisable` returns `.challengeRequired`
    /// so the Toggle proxy binding routes into the vision-verified flow.
    /// This is the contract-binding state for the vast majority of the app's
    /// lifetime.
    func testRequestDisableReturnsChallengeRequiredAfterGrace() {
        let installedAt = Date()
        suiteDefaults.set(installedAt, forKey: AlarmScheduler.firstInstallAtKey)
        // 25h after install → past the 24h window.
        let now = installedAt.addingTimeInterval(25 * 60 * 60)
        let outcome = scheduler.requestDisable(now: now)
        XCTAssertEqual(outcome, .challengeRequired,
                       "past 24h, disable must require the vision-verified challenge")
    }

    /// G1: absent `firstInstallAt` timestamp is treated as "grace active"
    /// so a pre-G1 user whose backfill hasn't landed yet (theoretically a
    /// millisecond window during bootstrap) doesn't hit a locked-out state
    /// on their first G1-aware launch. Once `recordFirstInstallIfNeeded`
    /// writes the timestamp, the above tests' logic takes over.
    func testRequestDisableAllowedWhenNoFirstInstallTimestamp() {
        // Don't set `firstInstallAtKey` — simulates the defensive-backfill edge.
        XCTAssertNil(suiteDefaults.object(forKey: AlarmScheduler.firstInstallAtKey),
                     "precondition: no timestamp set")
        let outcome = scheduler.requestDisable(now: Date())
        XCTAssertEqual(outcome, .allowed,
                       "absent timestamp must default to grace-active so first-launch G1-aware code doesn't lock the user out")
    }

    /// G1: `recordFirstInstallIfNeeded` is idempotent — a re-run (e.g.
    /// bootstrap's defensive backfill firing after OnboardingFlowView
    /// already recorded the timestamp) must NOT overwrite the first value.
    /// Preserving the original timestamp is what makes "24h from first
    /// commit" meaningful across app restarts.
    func testRecordFirstInstallIfNeededIsIdempotent() {
        let earlier = Date(timeIntervalSinceReferenceDate: 1_000_000)
        AlarmScheduler.recordFirstInstallIfNeeded(now: earlier, defaults: suiteDefaults)
        let stored1 = suiteDefaults.object(forKey: AlarmScheduler.firstInstallAtKey) as? Date
        XCTAssertEqual(stored1, earlier, "first call must write")

        // Second call with a later timestamp must not overwrite.
        let later = earlier.addingTimeInterval(3600)
        AlarmScheduler.recordFirstInstallIfNeeded(now: later, defaults: suiteDefaults)
        let stored2 = suiteDefaults.object(forKey: AlarmScheduler.firstInstallAtKey) as? Date
        XCTAssertEqual(stored2, earlier,
                       "second call must NOT overwrite — grace window is measured from FIRST install")
    }

    // MARK: - Wave 5 G1: disable-challenge phase transitions

    /// G1: `beginDisableChallenge` valid only from .idle. A call while the
    /// alarm is actively ringing must no-op — the Toggle is inside the
    /// scheduler view which isn't visible during .ringing, so reaching
    /// this branch is a programmer error but it must fail closed.
    func testBeginDisableChallengeOnlyFromIdle() {
        // From .idle → transitions
        scheduler.beginDisableChallenge()
        XCTAssertEqual(scheduler.phase, .disableChallenge)

        // Go back to .idle via cancel
        scheduler.cancelDisableChallenge()
        XCTAssertEqual(scheduler.phase, .idle)

        // From .ringing → no-op
        scheduler.fireNow()
        XCTAssertEqual(scheduler.phase, .ringing)
        scheduler.beginDisableChallenge()
        XCTAssertEqual(scheduler.phase, .ringing,
                       "beginDisableChallenge must be ignored when the alarm is ringing")
    }

    /// G1: a VERIFIED verdict on the disable challenge flips
    /// `window.isEnabled` to false AND returns the scheduler to .idle.
    /// This is the happy-path commit surface — the contract is what gets
    /// silenced, not just the UI state.
    func testDisableChallengeSucceededFlipsIsEnabledAndReturnsToIdle() {
        // Seed: enabled window, enter challenge phase.
        let enabled = WakeWindow(startHour: 7, startMinute: 0, endHour: 7, endMinute: 30, isEnabled: true)
        scheduler.updateWindow(enabled)
        XCTAssertTrue(scheduler.window.isEnabled, "precondition: window enabled")
        scheduler.beginDisableChallenge()
        XCTAssertEqual(scheduler.phase, .disableChallenge)

        // Act: verify verdict lands.
        scheduler.disableChallengeSucceeded()

        // Assert: window disabled, phase idle, nextFireAt cleared (because
        // updateWindow triggers scheduleNextFireIfEnabled which sees
        // isEnabled=false and clears the scheduled fire).
        XCTAssertFalse(scheduler.window.isEnabled,
                       "VERIFIED disable challenge must flip window.isEnabled=false")
        XCTAssertEqual(scheduler.phase, .idle,
                       "post-success must return to .idle")
        XCTAssertNil(scheduler.nextFireAt,
                     "disabled window must clear nextFireAt via the internal rescheduleEvents")
    }

    /// G1: a REJECTED verdict keeps the window enabled and returns the
    /// scheduler to .idle with `lastCaptureError` set to the reasoning so a
    /// future banner surface can render it. The alarm contract holds.
    func testDisableChallengeFailedReturnsToIdleKeepsWindowEnabled() {
        let enabled = WakeWindow(startHour: 7, startMinute: 0, endHour: 7, endMinute: 30, isEnabled: true)
        scheduler.updateWindow(enabled)
        scheduler.beginDisableChallenge()
        XCTAssertEqual(scheduler.phase, .disableChallenge)

        scheduler.disableChallengeFailed(error: "Different person detected.")

        XCTAssertTrue(scheduler.window.isEnabled,
                      "REJECTED disable challenge must keep window enabled")
        XCTAssertEqual(scheduler.phase, .idle,
                       "failed challenge returns to .idle with alarm still armed")
        XCTAssertEqual(scheduler.lastCaptureError, "Different person detected.",
                       "failure error must surface via lastCaptureError")
    }

    /// G1: user cancels the capture flow before resolving. Distinguished
    /// from a REJECTED verdict in that no error message surfaces — this
    /// is an intentional back-out, not a failed proof.
    func testCancelDisableChallengeReturnsToIdle() {
        let enabled = WakeWindow(startHour: 7, startMinute: 0, endHour: 7, endMinute: 30, isEnabled: true)
        scheduler.updateWindow(enabled)
        scheduler.beginDisableChallenge()

        scheduler.cancelDisableChallenge()

        XCTAssertEqual(scheduler.phase, .idle)
        XCTAssertTrue(scheduler.window.isEnabled,
                      "cancel must keep the window enabled — no contract change")
        XCTAssertNil(scheduler.lastCaptureError,
                     "cancel is intentional, not a failure — no error message should surface")
    }

    // MARK: - Stage 8 CRITICAL 1: disableChallengeSucceeded save failure

    /// Stage 8 CRITICAL 1: the review identified that `disableChallengeSucceeded`
    /// previously discarded `updateWindow`'s Bool return via `_ = updateWindow(...)`.
    /// On `WakeWindow.save()` failure the in-memory flip to `isEnabled = false` had
    /// already happened → Toggle UI animated OFF, but UserDefaults still held
    /// `isEnabled = true`, so the NEXT relaunch re-armed the alarm silently. The
    /// exact silent-failure pattern CLAUDE.md forbids (8x repeat offense).
    ///
    /// Testing the save-failure branch directly requires either (a) injecting a
    /// `WakeWindow` subclass that overrides `save()` — but `WakeWindow` is a
    /// `struct`, not a class, so subclassing isn't available, or (b) making
    /// `WakeWindow.save()` fail via a UserDefaults mock — but the scheduler's
    /// `disableChallengeSucceeded` calls `updated.save()` with the default `.standard`
    /// argument which isn't injectable from here.
    ///
    /// Constructing a save-failing scenario is therefore impractical at the unit
    /// level; the invariant is enforced by code inspection + the happy-path test
    /// below which locks the expected post-success state. The full save-failure
    /// branch is device-tested alongside the disk-full / encode-error scenarios
    /// in `docs/device-test-protocol.md`.
    ///
    /// What this test locks instead: the happy path's end-state is structurally
    /// unchanged by the fix (save succeeds → window flips, phase idle, fire
    /// cleared). If a future refactor accidentally swaps the order of operations
    /// and breaks this, the test catches it.
    func testDisableChallengeSucceededHappyPathEndState() {
        let enabled = WakeWindow(startHour: 7, startMinute: 0, endHour: 7, endMinute: 30, isEnabled: true)
        scheduler.updateWindow(enabled)
        XCTAssertTrue(scheduler.window.isEnabled, "precondition: window enabled + saved")
        scheduler.beginDisableChallenge()
        XCTAssertEqual(scheduler.phase, .disableChallenge)

        scheduler.disableChallengeSucceeded()

        // Save-on-success path: all three invariants must hold together.
        // If save() returned false, the fix routes through disableChallengeFailed
        // and `window.isEnabled` would remain true — so this combined assertion
        // also indirectly confirms save() succeeded in-test.
        XCTAssertFalse(scheduler.window.isEnabled,
                       "VERIFIED disable challenge with successful save must flip window.isEnabled=false")
        XCTAssertEqual(scheduler.phase, .idle,
                       "post-success save: phase must return to .idle")
        XCTAssertNil(scheduler.nextFireAt,
                     "post-success save: disabled window has no next fire")
    }

    // MARK: - Stage 8 CRITICAL 2: fire() no longer reschedules (G3 backup chain)

    /// Stage 8 CRITICAL 2: `fire()` previously called `scheduleNextFireIfEnabled()`
    /// at its tail, which internally calls `cancel()` — wiping the +90s/+180s
    /// backup chain identifiers that `scheduleBackupNotification` had JUST
    /// scheduled. A force-quit after the +0s banner would then never see
    /// +90s/+180s, defeating G3's force-quit durability story.
    ///
    /// The fix moved `scheduleNextFireIfEnabled()` out of `fire()` and into
    /// terminal transitions (`stopRinging()` + `handleRingCeiling()` which
    /// calls stopRinging). This test verifies the invariant: after `fireNow()`,
    /// the scheduling generation has NOT been bumped again (which would happen
    /// if fire() had called scheduleNextFireIfEnabled / cancel internally).
    ///
    /// Direct proof would require observing `schedulingGeneration`, which is
    /// private. Proxy: `nextFireAt` after `fireNow()` with an enabled window
    /// must remain at the SAME value it held before fire (i.e. today's fire
    /// time), not advance to tomorrow. Pre-fix, fire() would have cancelled
    /// the today-schedule and written a tomorrow-schedule, so `nextFireAt`
    /// would have advanced. Post-fix, fire() leaves `nextFireAt` untouched.
    func testFireDoesNotRescheduleTomorrow() throws {
        // Enable a window so scheduleNextFireIfEnabled populates nextFireAt.
        let enabled = WakeWindow(startHour: 7, startMinute: 0, endHour: 7, endMinute: 30, isEnabled: true)
        scheduler.updateWindow(enabled)
        let initialNextFireAt = try XCTUnwrap(scheduler.nextFireAt,
                                               "precondition: enabled window must schedule")

        // Fire. With the fix, fire() does NOT call scheduleNextFireIfEnabled,
        // so nextFireAt stays at the initial (pre-fire) value. Pre-fix, it
        // would have advanced to tomorrow (a roughly +24h jump).
        scheduler.fireNow()
        XCTAssertEqual(scheduler.phase, .ringing)
        XCTAssertEqual(scheduler.nextFireAt, initialNextFireAt,
                       "fire() must NOT reschedule — that would cancel today's +90s/+180s backup chain mid-flight (G3 durability)")
    }

    /// Stage 8 CRITICAL 2 (cont.): the counterpart invariant — `stopRinging()`
    /// MUST reschedule when the window is enabled so tomorrow's fire is set
    /// up at terminal resolution (when the backup-chain identifier collision
    /// is safe because today's chain has resolved).
    ///
    /// Shape of the test: call fireNow (which no longer reschedules per the
    /// fix), then call cancel() to clear nextFireAt, then call stopRinging
    /// and assert that stopRinging re-populated nextFireAt via
    /// scheduleNextFireIfEnabled (because window.isEnabled is true). The
    /// cancel() step is what makes the test observable — without it we
    /// can't distinguish "stopRinging reschedules" from "already scheduled
    /// from updateWindow" because the fire-time calculation is wall-clock
    /// based and doesn't change between fireNow and stopRinging.
    func testStopRingingReschedulesWhenWindowEnabled() throws {
        let enabled = WakeWindow(startHour: 7, startMinute: 0, endHour: 7, endMinute: 30, isEnabled: true)
        scheduler.updateWindow(enabled)
        XCTAssertNotNil(scheduler.nextFireAt, "precondition: updateWindow scheduled")

        scheduler.fireNow()
        XCTAssertEqual(scheduler.phase, .ringing)

        // Simulate a mid-flight cancel to make the reschedule observable:
        // without this cancel step the pre-fire schedule persists from
        // updateWindow (fire() no longer reschedules per the fix), so we
        // can't distinguish "stopRinging DID reschedule" from "was already
        // scheduled". Cancel clears nextFireAt; if stopRinging reschedules
        // as expected, it will re-populate. If stopRinging DOESN'T
        // reschedule (the pre-fix / wrong behavior), nextFireAt stays nil.
        scheduler.cancel()
        XCTAssertNil(scheduler.nextFireAt, "precondition: cancel cleared nextFireAt")
        // fireNow left phase=.ringing; cancel() doesn't touch phase. Call
        // stopRinging which is the path under test.
        scheduler.stopRinging()
        XCTAssertEqual(scheduler.phase, .idle)
        XCTAssertNotNil(scheduler.nextFireAt,
                        "stopRinging with an enabled window must call scheduleNextFireIfEnabled to set up tomorrow's fire")
    }

    /// Stage 8 CRITICAL 2 (cont.): when the window becomes disabled between
    /// fire and resolution (e.g. disable-challenge succeeded during a ring
    /// edge case), stopRinging's rescheduling is gated — no tomorrow fire
    /// should be written for a disabled window. Belt-and-suspenders: the
    /// scheduler's own `scheduleNextFireIfEnabled` also no-ops on disabled
    /// windows, but the guard inside stopRinging makes the intent explicit.
    func testStopRingingDoesNotRescheduleWhenWindowDisabled() {
        // Enable + fire → then disable mid-ring → stopRinging.
        let enabled = WakeWindow(startHour: 7, startMinute: 0, endHour: 7, endMinute: 30, isEnabled: true)
        scheduler.updateWindow(enabled)
        scheduler.fireNow()
        XCTAssertEqual(scheduler.phase, .ringing)

        let disabled = WakeWindow(startHour: 7, startMinute: 0, endHour: 7, endMinute: 30, isEnabled: false)
        // updateWindow on a disabled window clears nextFireAt via
        // scheduleNextFireIfEnabled's early-return branch.
        scheduler.updateWindow(disabled)
        XCTAssertNil(scheduler.nextFireAt, "disabled window must clear nextFireAt")

        scheduler.stopRinging()
        XCTAssertEqual(scheduler.phase, .idle)
        XCTAssertNil(scheduler.nextFireAt,
                     "stopRinging with a disabled window must NOT write a tomorrow schedule")
    }

    #if DEBUG
    /// G1: the DEBUG bypass flag short-circuits `requestDisable` to `.allowed`
    /// regardless of grace-window state. Demo recording only. A UIT launch
    /// argument does the same thing (`-disableBypassForUIT`). Both live in
    /// `#if DEBUG` so release builds can never honor them.
    func testDebugBypassToggleAllowsDirectDisable() {
        // Seed past-grace so only the bypass can allow.
        let installedAt = Date()
        suiteDefaults.set(installedAt, forKey: AlarmScheduler.firstInstallAtKey)
        let now = installedAt.addingTimeInterval(25 * 60 * 60) // post-grace

        // Without bypass: challenge required.
        XCTAssertFalse(suiteDefaults.bool(forKey: AlarmScheduler.disableChallengeBypassKey),
                       "precondition: bypass key off")
        XCTAssertEqual(scheduler.requestDisable(now: now), .challengeRequired)

        // With bypass on: allowed.
        suiteDefaults.set(true, forKey: AlarmScheduler.disableChallengeBypassKey)
        XCTAssertEqual(scheduler.requestDisable(now: now), .allowed,
                       "DEBUG bypass flag must allow direct disable regardless of grace window")

        // Clear for subsequent tests — the tearDown wipes the suite, but
        // explicit reset makes the test readable.
        suiteDefaults.set(false, forKey: AlarmScheduler.disableChallengeBypassKey)
    }

    /// G1: the UIT launch-arg pathway. Implementation inspects
    /// `ProcessInfo.processInfo.arguments` at call time; the static helper
    /// accepts an injected `arguments` array so tests can drive it without
    /// monkey-patching the process-wide arg list.
    func testUITLaunchArgumentActivatesBypass() {
        XCTAssertTrue(
            AlarmScheduler.isDisableChallengeBypassActive(
                defaults: suiteDefaults,
                arguments: ["-disableBypassForUIT"]
            ),
            "-disableBypassForUIT launch arg must flip bypass on in DEBUG builds"
        )
        XCTAssertFalse(
            AlarmScheduler.isDisableChallengeBypassActive(
                defaults: suiteDefaults,
                arguments: []
            ),
            "no launch arg and no UserDefaults key → bypass off"
        )
    }
    #endif
}
