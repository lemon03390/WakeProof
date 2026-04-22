//
//  CameraCaptureErrorTests.swift
//  WakeProofTests
//

import XCTest
@testable import WakeProof

final class CameraCaptureErrorTests: XCTestCase {

    func testErrorDescriptionIsDistinctPerCase() {
        let messages: [String?] = [
            CameraCaptureError.cameraUnavailable.errorDescription,
            CameraCaptureError.noVideoURLReturned.errorDescription,
            CameraCaptureError.dismissedWhileBackgrounded.errorDescription,
            CameraCaptureError.frameExtractionFailed(underlying: SampleError.boom).errorDescription
        ]
        let unique = Set(messages.compactMap { $0 })
        XCTAssertEqual(unique.count, messages.count, "every case must have a distinct user-facing message")
    }

    func testCameraUnavailableMentionsRestart() {
        let msg = CameraCaptureError.cameraUnavailable.errorDescription ?? ""
        XCTAssertTrue(msg.lowercased().contains("restart") || msg.lowercased().contains("camera"),
                      "user needs an actionable hint, not a generic 'failed' message")
    }

    func testFrameExtractionFailedDoesNotLeakUnderlyingError() {
        let underlying = SampleError.boom
        let msg = CameraCaptureError.frameExtractionFailed(underlying: underlying).errorDescription ?? ""
        XCTAssertFalse(msg.contains("SampleError"),
                       "user-facing message must not surface the underlying error type name")
        XCTAssertFalse(msg.contains("boom"),
                       "user-facing message must not surface raw underlying error description")
    }

    func testAllCasesProvideErrorDescription() {
        XCTAssertNotNil(CameraCaptureError.cameraUnavailable.errorDescription)
        XCTAssertNotNil(CameraCaptureError.noVideoURLReturned.errorDescription)
        XCTAssertNotNil(CameraCaptureError.dismissedWhileBackgrounded.errorDescription)
        XCTAssertNotNil(CameraCaptureError.frameExtractionFailed(underlying: SampleError.boom).errorDescription)
    }

    private enum SampleError: Error {
        case boom
    }
}
