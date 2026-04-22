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

    override func setUp() async throws {
        try await super.setUp()
        // Each test gets a fresh scheduler. Scheduler reads UserDefaults at init —
        // tests run in app sandbox; clean stale lastFireAt to keep tests independent.
        UserDefaults.standard.removeObject(forKey: "com.wakeproof.alarm.lastFireAt")
        scheduler = AlarmScheduler()
    }

    override func tearDown() async throws {
        scheduler.cancel()
        UserDefaults.standard.removeObject(forKey: "com.wakeproof.alarm.lastFireAt")
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

    func testLastFireAtPersistsAcrossSchedulerInstances() {
        scheduler.fireNow()
        let firedAt = try! XCTUnwrap(scheduler.lastFireAt)

        // Simulate process restart: throw away the scheduler, build a new one.
        scheduler = nil
        let recovered = AlarmScheduler()
        XCTAssertEqual(recovered.lastFireAt?.timeIntervalSince1970,
                       firedAt.timeIntervalSince1970,
                       accuracy: 0.001,
                       "force-quit during ring must leave a recovery marker")
        recovered.cancel()
    }

    func testStopRingingClearsPersistedMarker() {
        scheduler.fireNow()
        scheduler.stopRinging()
        let recovered = AlarmScheduler()
        XCTAssertNil(recovered.lastFireAt)
        recovered.cancel()
    }

    // MARK: - persistAttempt callback

    func testRecoverUnresolvedFireFiresPersistAttemptOnce() {
        scheduler.fireNow()
        scheduler.cancel() // doesn't clear lastFireAt — simulates force-quit semantics

        // Simulate launch: new instance with persistAttempt wired.
        let recovered = AlarmScheduler()
        var capturedVerdicts: [WakeAttempt.Verdict] = []
        recovered.persistAttempt = { verdict, _ in capturedVerdicts.append(verdict) }
        recovered.recoverUnresolvedFireIfNeeded()
        XCTAssertEqual(capturedVerdicts, [.unresolved])
        XCTAssertNil(recovered.lastFireAt, "recovery must clear the marker after persisting")

        // Second call is a no-op.
        recovered.recoverUnresolvedFireIfNeeded()
        XCTAssertEqual(capturedVerdicts, [.unresolved], "recovery must be idempotent")
        recovered.cancel()
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
}
