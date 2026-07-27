import Foundation
import XCTest
@testable import AutoMix_Native

final class ChannelMappingMuteTests: XCTestCase {
    private func channel() -> ChannelMapping {
        ChannelMapping(index: 0, name: "Ch 1", role: .leadVocal)
    }

    func testMuteEnablesFaderOverrideAtFloor() {
        var ch = channel()
        XCTAssertFalse(ch.faderOverrideEnabled)
        ch.setMuted(true)
        XCTAssertTrue(ch.muted)
        XCTAssertTrue(ch.faderOverrideEnabled)
        XCTAssertEqual(ch.faderDb, ChannelMapping.faderDbOverrideRange.lowerBound, accuracy: 0.001)
    }

    func testUnmuteRestoresAutonomousFaderWhenNoPriorOverride() {
        var ch = channel()              // override off, faderDb default -6
        let originalDb = ch.faderDb
        ch.setMuted(true)
        ch.setMuted(false)
        XCTAssertFalse(ch.muted)
        XCTAssertFalse(ch.faderOverrideEnabled)
        XCTAssertEqual(ch.faderDb, originalDb, accuracy: 0.001)
    }

    func testUnmuteRestoresPriorManualOverride() {
        var ch = channel()
        ch.faderOverrideEnabled = true
        ch.faderDb = 3.0
        ch.setMuted(true)
        XCTAssertEqual(ch.faderDb, ChannelMapping.faderDbOverrideRange.lowerBound, accuracy: 0.001)
        ch.setMuted(false)
        XCTAssertTrue(ch.faderOverrideEnabled)
        XCTAssertEqual(ch.faderDb, 3.0, accuracy: 0.001)
    }

    func testMuteIsIdempotentAndPreservesOriginal() {
        var ch = channel()              // faderDb -6
        ch.setMuted(true)
        ch.setMuted(true)               // must not capture -80 as the "prior" value
        ch.setMuted(false)
        XCTAssertEqual(ch.faderDb, -6.0, accuracy: 0.001)
    }

    func testClearOverridesResetsFaderPanAndMute() {
        var ch = channel()
        ch.faderOverrideEnabled = true
        ch.panOverrideEnabled = true
        ch.pan = -0.5
        ch.setMuted(true)
        ch.clearOverrides()
        XCTAssertFalse(ch.muted)
        XCTAssertFalse(ch.faderOverrideEnabled)
        XCTAssertFalse(ch.panOverrideEnabled)
    }

    func testClearOverridesRestoresFaderWhenClearingAMutedChannel() {
        var ch = channel()              // faderDb -6, no override
        ch.setMuted(true)               // forces faderDb to -80 floor
        XCTAssertEqual(ch.faderDb, -80.0, accuracy: 0.001)
        ch.clearOverrides()
        // After clearing, the stale -80 mute floor must not be left as the fader value
        // reported to the phone / persisted.
        XCTAssertEqual(ch.faderDb, -6.0, accuracy: 0.001)
        XCTAssertFalse(ch.muted)
        XCTAssertFalse(ch.faderOverrideEnabled)
    }

    func testMuteStateRoundTripsInCodable() throws {
        var ch = channel()
        ch.setMuted(true)
        let data = try JSONEncoder().encode(ch)
        let decoded = try JSONDecoder().decode(ChannelMapping.self, from: data)
        XCTAssertTrue(decoded.muted)
        XCTAssertEqual(decoded.faderDb, ChannelMapping.faderDbOverrideRange.lowerBound, accuracy: 0.001)
    }

    func testDecodingLegacyProfileWithoutMuteDefaultsToUnmuted() throws {
        let legacy = #"{"index":0,"inputChannelIndex":0,"name":"Ch 1","role":"leadVocal","faderOverrideEnabled":false,"faderDb":-6,"panOverrideEnabled":false,"pan":0}"#
        let decoded = try JSONDecoder().decode(ChannelMapping.self, from: Data(legacy.utf8))
        XCTAssertFalse(decoded.muted)
    }
}
