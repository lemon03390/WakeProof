//
//  CameraCaptureFlowTests.swift
//  WakeProofTests
//
//  R8 fix: exercises the WatchdogBox coordination primitive extracted from
//  CameraCaptureFlow. The SwiftUI view itself can't be unit-tested reliably
//  (no ViewInspector in this project, and UIImagePickerController isn't
//  available in unit tests anyway), so we test the latch + timer coordination
//  primitive directly. Device-level watchdog firing is covered by the
//  on-device smoke test.
//

import XCTest
@testable import WakeProof

@MainActor
final class CameraCaptureFlowTests: XCTestCase {

    // MARK: - WatchdogBox semantics

    /// First `claim()` call must win; subsequent ones must return false so
    /// terminal-callback paths don't double-drive the scheduler.
    func testClaimReturnsTrueOnceOnly() {
        let box = WatchdogBox()
        XCTAssertTrue(box.claim(), "first claim always wins")
        XCTAssertFalse(box.claim(), "second claim must fail — this is what prevents double-transition")
        XCTAssertFalse(box.claim(), "third claim also fails")
    }

    /// `isClaimed` must reflect the latch state for assertions + DEBUG logging.
    func testIsClaimedTracksClaim() {
        let box = WatchdogBox()
        XCTAssertFalse(box.isClaimed, "fresh box not yet claimed")
        _ = box.claim()
        XCTAssertTrue(box.isClaimed, "after claim, flag must read true")
    }

    /// `claim()` must cancel the installed timer — that's how a successful
    /// terminal callback shuts down the watchdog before its 30s elapses.
    func testClaimCancelsInstalledTimer() async {
        let box = WatchdogBox()
        let fireExpectation = expectation(description: "timer should NOT fire because claim() cancels it")
        fireExpectation.isInverted = true

        let task = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return // cancelled — correct outcome
            }
            fireExpectation.fulfill() // fires only if sleep completed without cancellation
        }
        box.installTimer(task)

        // Immediately claim — timer should be cancelled.
        _ = box.claim()

        await fulfillment(of: [fireExpectation], timeout: 0.3)
    }

    /// `cancelTimer()` must work without claiming — the view's `onDisappear`
    /// uses it to tear down the timer when the user navigates away before
    /// any callback fires. Subsequent claim calls should still succeed.
    func testCancelTimerWithoutClaim() async {
        let box = WatchdogBox()
        let fireExpectation = expectation(description: "timer should NOT fire after cancelTimer()")
        fireExpectation.isInverted = true

        let task = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return
            }
            fireExpectation.fulfill()
        }
        box.installTimer(task)

        // Cancel without claiming — latch should still be unclaimed.
        box.cancelTimer()
        XCTAssertFalse(box.isClaimed, "cancelTimer must NOT claim the latch — only cancels the timer")

        await fulfillment(of: [fireExpectation], timeout: 0.3)
        XCTAssertTrue(box.claim(), "claim still succeeds after cancelTimer")
    }

    /// Short-timeout integration test: install a 50ms timer body that claims
    /// the latch on fire. Verify the latch ends up claimed within the
    /// tolerance window — this is the "watchdog wins because no callback
    /// ever fired" scenario compressed into a test-friendly duration.
    func testTimerFiresAndClaimsIfNoTerminalCallback() async {
        let box = WatchdogBox()
        let timerFired = expectation(description: "timer must fire and claim the latch")

        let task = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return
            }
            if box.claim() {
                timerFired.fulfill()
            }
        }
        box.installTimer(task)

        await fulfillment(of: [timerFired], timeout: 0.5)
        XCTAssertTrue(box.isClaimed, "after timer fires, latch must be claimed")
    }

    /// Race between terminal callback and timer — whichever claims first wins.
    /// This is the real-world scenario: camera returns a result right as the
    /// watchdog is about to fire. Without the latch, both would transition
    /// the scheduler (one to idle, one back to ringing with an error).
    func testOnlyOneSideWinsUnderRace() async {
        let box = WatchdogBox()
        // Simulate the terminal callback claiming first.
        XCTAssertTrue(box.claim(), "simulated terminal callback claims first")

        // Watchdog timer body runs second.
        let watchdogAttemptedClaim = expectation(description: "watchdog must see latch already claimed")
        let task = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                return
            }
            // claim returns false → watchdog knows not to reverse-transition.
            if !box.claim() {
                watchdogAttemptedClaim.fulfill()
            }
        }
        box.installTimer(task)

        await fulfillment(of: [watchdogAttemptedClaim], timeout: 0.3)
    }
}
