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
        ch.processingOverride.trimOverrideEnabled = true
        ch.processingOverride.compressorOverrideEnabled = true
        ch.setMuted(true)
        ch.clearOverrides()
        XCTAssertFalse(ch.muted)
        XCTAssertFalse(ch.faderOverrideEnabled)
        XCTAssertFalse(ch.panOverrideEnabled)
        XCTAssertEqual(ch.processingOverride.enabledFamilyCount, 0)
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
        XCTAssertFalse(decoded.stereoLinkedToNext)
        XCTAssertEqual(decoded.processingOverride, ChannelProcessingOverride())
    }

    func testProcessingOverridesRoundTripInCodable() throws {
        var ch = channel()
        ch.processingOverride.trimOverrideEnabled = true
        ch.processingOverride.trimDb = 4.5
        ch.processingOverride.hpfOverrideEnabled = true
        ch.processingOverride.hpfHz = 115
        ch.processingOverride.eqOverrideEnabled = true
        ch.processingOverride.eqBands[0].type = .notch
        ch.processingOverride.eqBands[0].frequencyHz = 315
        ch.processingOverride.eqBands[0].q = 6
        ch.processingOverride.eqBands[0].gainDb = -8
        ch.processingOverride.compressorOverrideEnabled = true
        ch.processingOverride.compressorRatio = 4
        ch.processingOverride.reverbOverrideEnabled = true
        ch.processingOverride.reverbSendDb = -18

        let data = try JSONEncoder().encode(ch)
        let decoded = try JSONDecoder().decode(ChannelMapping.self, from: data)

        XCTAssertEqual(decoded, ch)
        XCTAssertTrue(decoded.processingOverride.isValid)
        XCTAssertEqual(decoded.processingOverride.enabledFamilyCount, 5)
    }

    func testStereoLinkRoundTripsInCodable() throws {
        var ch = ChannelMapping(index: 0, name: "Keys L", role: .keys)
        ch.stereoLinkedToNext = true
        let data = try JSONEncoder().encode(ch)
        let decoded = try JSONDecoder().decode(ChannelMapping.self, from: data)
        XCTAssertTrue(decoded.stereoLinkedToNext)
    }

    func testServiceTemplateCoversWorshipSourcesAndStereoPairs() {
        let channels = ChannelMapping.serviceRoleTemplate(count: 24)
        XCTAssertEqual(channels.count, 24)
        XCTAssertEqual(channels[14].role, .snare)
        XCTAssertEqual(channels[15].role, .tom)
        XCTAssertEqual(channels[17].role, .overhead)
        XCTAssertEqual(channels[19].role, .percussion)
        XCTAssertEqual(channels[20].role, .playback)
        XCTAssertEqual(channels[10].name, "Keys L")
        XCTAssertEqual(channels[11].name, "Keys R")

        let coverage = StereoLinkCoverage.make(channelMappings: channels)
        XCTAssertTrue(coverage.isReady)
        XCTAssertEqual(
            coverage.pairs,
            [
                StereoLinkPair(leftChannelIndex: 10, rightChannelIndex: 11),
                StereoLinkPair(leftChannelIndex: 17, rightChannelIndex: 18),
                StereoLinkPair(leftChannelIndex: 20, rightChannelIndex: 21)
            ]
        )
    }

    func testStereoCoverageRejectsDifferentRolesAndOverlappingPairs() {
        let mismatched = [
            ChannelMapping(
                index: 0,
                name: "Keys L",
                role: .keys,
                stereoLinkedToNext: true
            ),
            ChannelMapping(index: 1, name: "Tracks R", role: .playback)
        ]
        let mismatchCoverage = StereoLinkCoverage.make(channelMappings: mismatched)
        XCTAssertFalse(mismatchCoverage.isReady)
        XCTAssertEqual(mismatchCoverage.invalidChannels, [0, 1])

        let overlapping = [
            ChannelMapping(
                index: 0,
                name: "Keys 1",
                role: .keys,
                stereoLinkedToNext: true
            ),
            ChannelMapping(
                index: 1,
                name: "Keys 2",
                role: .keys,
                stereoLinkedToNext: true
            ),
            ChannelMapping(index: 2, name: "Keys 3", role: .keys)
        ]
        let overlapCoverage = StereoLinkCoverage.make(channelMappings: overlapping)
        XCTAssertFalse(overlapCoverage.isReady)
        XCTAssertEqual(overlapCoverage.invalidChannels, [0, 1, 2])
    }

    func testSpeechCannotBeStereoLinked() {
        let speech = [
            ChannelMapping(
                index: 0,
                name: "Pastor L",
                role: .speech,
                stereoLinkedToNext: true
            ),
            ChannelMapping(index: 1, name: "Pastor R", role: .speech)
        ]
        let coverage = StereoLinkCoverage.make(channelMappings: speech)
        XCTAssertFalse(coverage.isReady)
        XCTAssertEqual(coverage.invalidChannels, [0, 1])
    }
}
