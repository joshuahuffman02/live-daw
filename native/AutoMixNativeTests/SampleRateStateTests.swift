import Foundation
import XCTest
@testable import AutoMix_Native

final class SampleRateStateTests: XCTestCase {
    func testSupportedRatesAre48And96() {
        XCTAssertTrue(BroadcastSampleRate.isSupported(48_000))
        XCTAssertTrue(BroadcastSampleRate.isSupported(96_000))
        XCTAssertFalse(BroadcastSampleRate.isSupported(44_100))
        XCTAssertFalse(BroadcastSampleRate.isSupported(88_200))
        XCTAssertFalse(BroadcastSampleRate.isSupported(0))
    }

    func testNearestSupportedSnapsToAllowedRate() {
        XCTAssertEqual(BroadcastSampleRate.nearestSupported(44_100), 48_000, accuracy: 0.5)
        XCTAssertEqual(BroadcastSampleRate.nearestSupported(48_000), 48_000, accuracy: 0.5)
        XCTAssertEqual(BroadcastSampleRate.nearestSupported(90_000), 96_000, accuracy: 0.5)
    }

    func testStateReadyWhenDetectedMatchesExpected() {
        guard case .ready(let r) = SampleRateState.make(detected: 48_000, expected: 48_000) else {
            return XCTFail("expected .ready at matching 48k")
        }
        XCTAssertEqual(r, 48_000, accuracy: 0.5)
    }

    func testStateMismatchWhenDetectedDiffersFromExpected() {
        // A 48k rig with the operator expecting 96k must be flagged (drift protection).
        guard case .mismatch(let expected, let actual) = SampleRateState.make(detected: 48_000, expected: 96_000) else {
            return XCTFail("expected .mismatch")
        }
        XCTAssertEqual(expected, 96_000, accuracy: 0.5)
        XCTAssertEqual(actual, 48_000, accuracy: 0.5)
        XCTAssertTrue(SampleRateState.make(detected: 48_000, expected: 96_000).isWarning)
    }

    func testStateUnknownWhenNoRate() {
        XCTAssertEqual(SampleRateState.make(detected: 0, expected: 48_000), .unknown)
    }

    func testPreflightSampleRateCheckUsesExpectedRate() {
        // 48k rig + expecting 48k -> Sample Rate check passes.
        let ok = HD96PreflightReport.make(
            inputDevice: nil, outputDevice: nil,
            expectedInputChannels: 24, detectedInputChannels: 24,
            detectedSampleRate: 48_000, expectedSampleRate: 48_000
        )
        XCTAssertTrue(ok.checks.first { $0.name == "Sample Rate" }?.passed == true)

        // 48k rig + expecting 96k -> Sample Rate check fails.
        let bad = HD96PreflightReport.make(
            inputDevice: nil, outputDevice: nil,
            expectedInputChannels: 24, detectedInputChannels: 24,
            detectedSampleRate: 48_000, expectedSampleRate: 96_000
        )
        XCTAssertTrue(bad.checks.first { $0.name == "Sample Rate" }?.passed == false)
    }
}
