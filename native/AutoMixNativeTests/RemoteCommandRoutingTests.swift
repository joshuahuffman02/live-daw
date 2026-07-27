import Foundation
import XCTest
@testable import AutoMix_Native

private final class SpyTarget: RemoteControlTarget {
    var safe: Bool?
    var freeze: Bool?
    var scene: String?
    var knownScenes: Set<String> = ["worship", "sermon", "patch"]
    var validIdx: Range<Int> = 0..<32

    var muteCalls: [(idx: Int, on: Bool)] = []
    var faderCalls: [(idx: Int, on: Bool, db: Double)] = []
    var panCalls: [(idx: Int, on: Bool, pan: Double)] = []
    var clearedIdx: [Int] = []

    func remoteSetSafe(_ on: Bool) { safe = on }
    func remoteSetFreeze(_ on: Bool) { freeze = on }

    func remoteSetScene(_ scene: String) -> Bool {
        guard knownScenes.contains(scene) else { return false }
        self.scene = scene
        return true
    }

    func remoteSetMute(idx: Int, on: Bool) -> Bool {
        guard validIdx.contains(idx) else { return false }
        muteCalls.append((idx, on)); return true
    }

    func remoteSetFaderOverride(idx: Int, on: Bool, db: Double) -> Bool {
        guard validIdx.contains(idx) else { return false }
        faderCalls.append((idx, on, db)); return true
    }

    func remoteSetPanOverride(idx: Int, on: Bool, pan: Double) -> Bool {
        guard validIdx.contains(idx) else { return false }
        panCalls.append((idx, on, pan)); return true
    }

    func remoteClearOverride(idx: Int) -> Bool {
        guard validIdx.contains(idx) else { return false }
        clearedIdx.append(idx); return true
    }
}

final class RemoteCommandRoutingTests: XCTestCase {
    func testSafeAndFreezeRoute() {
        let spy = SpyTarget()
        XCTAssertTrue(RemoteCommandRouter.apply(.setSafe(on: true), to: spy).ok)
        XCTAssertEqual(spy.safe, true)
        XCTAssertTrue(RemoteCommandRouter.apply(.setFreeze(on: true), to: spy).ok)
        XCTAssertEqual(spy.freeze, true)
    }

    func testKnownSceneSucceedsUnknownSceneFails() {
        let spy = SpyTarget()
        XCTAssertTrue(RemoteCommandRouter.apply(.setScene(scene: "sermon"), to: spy).ok)
        XCTAssertEqual(spy.scene, "sermon")

        let bad = RemoteCommandRouter.apply(.setScene(scene: "nope"), to: spy)
        XCTAssertFalse(bad.ok)
        XCTAssertNotNil(bad.message)
    }

    func testMuteRoutes() {
        let spy = SpyTarget()
        XCTAssertTrue(RemoteCommandRouter.apply(.setMute(idx: 5, on: true), to: spy).ok)
        XCTAssertEqual(spy.muteCalls.first?.idx, 5)
        XCTAssertEqual(spy.muteCalls.first?.on, true)
    }

    func testFaderOverrideClampsDbToRange() {
        let spy = SpyTarget()
        _ = RemoteCommandRouter.apply(.setFaderOverride(idx: 1, on: true, db: 100), to: spy)
        _ = RemoteCommandRouter.apply(.setFaderOverride(idx: 2, on: true, db: -500), to: spy)
        XCTAssertEqual(spy.faderCalls[0].db, 12.0, accuracy: 0.001)
        XCTAssertEqual(spy.faderCalls[1].db, -80.0, accuracy: 0.001)
    }

    func testPanOverrideClampsToRange() {
        let spy = SpyTarget()
        _ = RemoteCommandRouter.apply(.setPanOverride(idx: 1, on: true, pan: 5), to: spy)
        _ = RemoteCommandRouter.apply(.setPanOverride(idx: 2, on: true, pan: -5), to: spy)
        XCTAssertEqual(spy.panCalls[0].pan, 1.0, accuracy: 0.001)
        XCTAssertEqual(spy.panCalls[1].pan, -1.0, accuracy: 0.001)
    }

    func testClearOverrideRoutes() {
        let spy = SpyTarget()
        XCTAssertTrue(RemoteCommandRouter.apply(.clearOverride(idx: 3), to: spy).ok)
        XCTAssertEqual(spy.clearedIdx, [3])
    }

    func testOutOfRangeChannelFailsGracefully() {
        let spy = SpyTarget()
        let result = RemoteCommandRouter.apply(.setMute(idx: 999, on: true), to: spy)
        XCTAssertFalse(result.ok)
        XCTAssertNotNil(result.message)
        XCTAssertTrue(spy.muteCalls.isEmpty)
    }
}
