//
//  UserIdentityTests.swift
//  WakeProofTests
//

import XCTest
@testable import WakeProof

final class UserIdentityTests: XCTestCase {

    private var suiteDefaults: UserDefaults!
    private let suiteName = "com.wakeproof.tests.useridentity"

    override func setUp() {
        super.setUp()
        // Wipe any stale default from a prior run so every test starts fresh.
        UserDefaults.standard.removeObject(forKey: "com.wakeproof.user.uuid")
        suiteDefaults = UserDefaults(suiteName: suiteName)
        suiteDefaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        suiteDefaults?.removePersistentDomain(forName: suiteName)
        UserDefaults.standard.removeObject(forKey: "com.wakeproof.user.uuid")
        super.tearDown()
    }

    func testFirstAccessGeneratesUUID() {
        let id = UserIdentity.shared.uuid
        XCTAssertFalse(id.isEmpty)
        XCTAssertNotNil(UUID(uuidString: id), "UserIdentity should yield a valid UUID string shape")
    }

    func testSecondAccessReturnsSameUUID() {
        let first = UserIdentity.shared.uuid
        let second = UserIdentity.shared.uuid
        XCTAssertEqual(first, second, "Repeated access must return the persisted UUID, not regenerate")
    }

    func testPersistsAcrossUserDefaultsReads() {
        let first = UserIdentity.shared.uuid
        let defaults = UserDefaults.standard
        XCTAssertEqual(defaults.string(forKey: "com.wakeproof.user.uuid"), first,
                       "UUID must be written to UserDefaults.standard under the documented key")
    }

    #if DEBUG
    func testRotateGeneratesDifferentUUID() {
        let first = UserIdentity.shared.uuid
        UserIdentity.shared.rotate()
        let second = UserIdentity.shared.uuid
        XCTAssertNotEqual(first, second, "rotate() must force fresh generation on next access")
    }
    #endif
}
