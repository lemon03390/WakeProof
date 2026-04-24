//
//  UserIdentityTests.swift
//  WakeProofTests
//
//  R15 (Wave 2.5): tests now inject a per-run `UserDefaults(suiteName:)` via the
//  new `UserIdentity(defaults:)` initializer so state never leaks into `.standard`
//  or cross-contaminates parallel tests. Previously setUp/tearDown had to wipe the
//  `.standard` key by name, which was fragile and raced against other tests that
//  might also read/write the same key.
//

import XCTest
@testable import WakeProof

final class UserIdentityTests: XCTestCase {

    private var suiteDefaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "com.wakeproof.tests.useridentity.\(UUID().uuidString)"
        suiteDefaults = UserDefaults(suiteName: suiteName)
        suiteDefaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        suiteDefaults?.removePersistentDomain(forName: suiteName)
        suiteDefaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testFirstAccessGeneratesUUID() {
        let identity = UserIdentity(defaults: suiteDefaults)
        let id = identity.uuid
        XCTAssertFalse(id.isEmpty)
        XCTAssertNotNil(UUID(uuidString: id), "UserIdentity should yield a valid UUID string shape")
    }

    func testSecondAccessReturnsSameUUID() {
        let identity = UserIdentity(defaults: suiteDefaults)
        let first = identity.uuid
        let second = identity.uuid
        XCTAssertEqual(first, second, "Repeated access must return the persisted UUID, not regenerate")
    }

    func testPersistsAcrossUserDefaultsReads() {
        let identity = UserIdentity(defaults: suiteDefaults)
        let first = identity.uuid
        XCTAssertEqual(suiteDefaults.string(forKey: "com.wakeproof.user.uuid"), first,
                       "UUID must be written to the injected UserDefaults under the documented key")
    }

    #if DEBUG
    func testRotateGeneratesDifferentUUID() {
        let identity = UserIdentity(defaults: suiteDefaults)
        let first = identity.uuid
        identity.rotate()
        let second = identity.uuid
        XCTAssertNotEqual(first, second, "rotate() must force fresh generation on next access")
    }
    #endif
}
