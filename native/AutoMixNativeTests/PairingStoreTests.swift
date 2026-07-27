import Foundation
import XCTest
@testable import AutoMix_Native

final class PairingStoreTests: XCTestCase {
    func testDefaultInitGeneratesSixDigitNumericCode() {
        let store = PairingStore()
        XCTAssertEqual(store.code.count, 6)
        XCTAssertTrue(store.code.allSatisfy(\.isNumber))
    }

    func testCorrectCodeMintsTokenWrongCodeDoesNot() {
        let store = PairingStore(code: "424242")
        XCTAssertNil(store.pair(code: "000000", label: "iPhone"))
        XCTAssertNotNil(store.pair(code: "424242", label: "iPhone"))
    }

    func testMintedTokenIsValidUnknownTokenIsNot() {
        let store = PairingStore(code: "424242")
        let token = try? XCTUnwrap(store.pair(code: "424242", label: "iPhone"))
        XCTAssertTrue(store.isValid(token: token ?? ""))
        XCTAssertFalse(store.isValid(token: "not-a-real-token"))
        XCTAssertFalse(store.isValid(token: ""))
    }

    func testRevokeAllInvalidatesExistingTokens() {
        let store = PairingStore(code: "424242")
        let token = store.pair(code: "424242", label: "iPhone")!
        XCTAssertTrue(store.isValid(token: token))
        store.revokeAll()
        XCTAssertFalse(store.isValid(token: token))
        XCTAssertTrue(store.pairedClients.isEmpty)
    }

    func testEachPairingMintsADistinctToken() {
        let store = PairingStore(code: "424242")
        let a = store.pair(code: "424242", label: "iPhone")!
        let b = store.pair(code: "424242", label: "iPad")!
        XCTAssertNotEqual(a, b)
    }

    func testPairedClientsTracksLabels() {
        let store = PairingStore(code: "424242")
        _ = store.pair(code: "424242", label: "iPhone")
        _ = store.pair(code: "424242", label: "iPad")
        XCTAssertEqual(store.pairedClients.count, 2)
        XCTAssertEqual(Set(store.pairedClients.map(\.label)), ["iPhone", "iPad"])
    }

    func testLockoutAfterRepeatedWrongCodesBlocksEvenTheCorrectCode() {
        var clock = Date(timeIntervalSince1970: 1_000)
        let store = PairingStore(code: "424242", now: { clock })

        // Below threshold: the correct code still works.
        for _ in 0..<(PairingStore.maxFailedAttempts - 1) {
            XCTAssertNil(store.pair(code: "000000", label: "x"))
        }
        XCTAssertFalse(store.isLockedOut)

        // Trip the threshold.
        XCTAssertNil(store.pair(code: "000000", label: "x"))
        XCTAssertTrue(store.isLockedOut)
        // Even the right code is refused while locked out.
        XCTAssertNil(store.pair(code: "424242", label: "x"))

        // After the lockout window passes, the right code works again.
        clock = clock.addingTimeInterval(PairingStore.lockoutSeconds + 1)
        XCTAssertFalse(store.isLockedOut)
        XCTAssertNotNil(store.pair(code: "424242", label: "x"))
    }

    func testSuccessfulPairResetsFailureCounter() {
        var clock = Date(timeIntervalSince1970: 1_000)
        let store = PairingStore(code: "424242", now: { clock })
        for _ in 0..<(PairingStore.maxFailedAttempts - 1) {
            _ = store.pair(code: "000000", label: "x")
        }
        XCTAssertNotNil(store.pair(code: "424242", label: "x"))   // success resets count
        clock = clock.addingTimeInterval(1)
        // A fresh batch of wrong attempts should not instantly lock (counter was reset).
        XCTAssertNil(store.pair(code: "000000", label: "x"))
        XCTAssertFalse(store.isLockedOut)
    }

    func testTokensAreNotValidAcrossSeparateStores() {
        let a = PairingStore(code: "424242")
        let b = PairingStore(code: "424242")
        let token = a.pair(code: "424242", label: "iPhone")!
        XCTAssertTrue(a.isValid(token: token))
        XCTAssertFalse(b.isValid(token: token), "tokens must not cross store/launch boundaries")
    }
}
