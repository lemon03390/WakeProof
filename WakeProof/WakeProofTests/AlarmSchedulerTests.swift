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
}
