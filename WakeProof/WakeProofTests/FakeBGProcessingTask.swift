//
//  FakeBGProcessingTask.swift
//  WakeProofTests
//
//  R12 (Wave 2.5): testable replacement for the real `BGProcessingTask`. iOS
//  forbids constructing real `BGProcessingTask` instances in unit tests (the
//  init is unavailable), so we conform a fake to `BGProcessingTaskLike` and
//  drive it manually. Records every `setTaskCompleted(success:)` call so tests
//  can assert the completion-latch logic (e.g. "exactly one call with false")
//  without racing the BackgroundTasks queue.
//

import Foundation
@testable import WakeProof

/// Records every `setTaskCompleted` call in order so tests can assert both
/// count and arg values. Not thread-safe in the general sense — tests calling
/// `expirationHandler?()` on a background queue must `await` the scheduler's
/// `handleRefresh` to completion before inspecting the array. (The production
/// path uses `OSAllocatedUnfairLock`-backed `CompletionLatch` — if a test is
/// seeing unordered recording here, it means the production latch is missing
/// and THAT is what the test is catching.)
final class FakeBGProcessingTask: BGProcessingTaskLike {
    let identifier: String
    var completionCalls: [Bool] = []
    var expirationHandler: (() -> Void)?

    init(identifier: String = "com.wakeproof.tests.bgtask") {
        self.identifier = identifier
    }

    func setTaskCompleted(success: Bool) {
        completionCalls.append(success)
    }

    /// Test helper: simulate iOS firing the expirationHandler. Calls the handler
    /// synchronously so the test thread can proceed to assertions immediately.
    /// Returns true if a handler was installed; false if `handleRefresh` hasn't
    /// run yet or cleared it.
    @discardableResult
    func fireExpiration() -> Bool {
        guard let handler = expirationHandler else { return false }
        handler()
        return true
    }
}
