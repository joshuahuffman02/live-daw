import Foundation
import XCTest
@testable import AutoMix_Native

final class TelemetryAssemblerTests: XCTestCase {
    func testChannelTelemetryMapsFieldsAndPicksLevelByIndex() {
        var ch0 = ChannelMapping(index: 0, name: "Pastor", role: .speech)
        ch0.setMuted(true)
        let ch1 = ChannelMapping(index: 1, name: "Lead", role: .leadVocal,
                                 panOverrideEnabled: true, pan: -0.3)
        let levels = [-22.0, -8.0]

        let tel = TelemetryAssembler.channelTelemetry([ch0, ch1], levelsDb: levels)

        XCTAssertEqual(tel[0].name, "Pastor")
        XCTAssertEqual(tel[0].role, "speech")
        XCTAssertEqual(tel[0].levelDb, -22.0, accuracy: 0.001)
        XCTAssertTrue(tel[0].muted)
        XCTAssertTrue(tel[0].faderOverride)            // mute forces fader override
        XCTAssertEqual(tel[1].levelDb, -8.0, accuracy: 0.001)
        XCTAssertTrue(tel[1].panOverride)
        XCTAssertEqual(tel[1].pan, -0.3, accuracy: 0.001)
    }

    func testChannelTelemetryDefaultsMissingLevelToFloor() {
        let ch = ChannelMapping(index: 5, name: "X", role: .keys)
        let tel = TelemetryAssembler.channelTelemetry([ch], levelsDb: [])
        XCTAssertEqual(tel[0].levelDb, -100.0, accuracy: 0.001)
    }

    func testAssembleSetsFaultTrueOnlyForCriticalSeverity() {
        let base = TelemetryAssembler.assemble(
            ts: 1, venueName: "V", isRunning: true, safe: false, freeze: false,
            watchdogSafe: false, scene: "worship", scenes: ["worship", "sermon"],
            sampleRate: 96_000, inputChannelCount: 64, bpm: 120, bpmConfidence: 0.8,
            stream: StreamTelemetry(l: -8, r: -8, momentaryLufs: -14, shortLufs: -14,
                                    integratedLufs: -14, limiterGrDb: 0),
            counters: CounterTelemetry(dropouts: 0, callbackOverruns: 0, deadlineMisses: 0,
                                       outputUnderruns: 0, outputOverruns: 0,
                                       lastCallbackFrames: 256, maxCallbackFrames: 256),
            channels: [],
            alerts: [Alert(id: "x", severity: .warning, title: "t", detail: "d")],
            severity: .warning
        )
        XCTAssertFalse(base.fault)
        XCTAssertEqual(base.severity, .warning)

        let critical = TelemetryAssembler.assemble(
            ts: 1, venueName: "V", isRunning: true, safe: false, freeze: false,
            watchdogSafe: true, scene: "worship", scenes: ["worship"],
            sampleRate: 96_000, inputChannelCount: 64, bpm: 120, bpmConfidence: 0.8,
            stream: StreamTelemetry(l: -8, r: -8, momentaryLufs: -14, shortLufs: -14,
                                    integratedLufs: -14, limiterGrDb: 0),
            counters: CounterTelemetry(dropouts: 0, callbackOverruns: 0, deadlineMisses: 0,
                                       outputUnderruns: 0, outputOverruns: 0,
                                       lastCallbackFrames: 256, maxCallbackFrames: 256),
            channels: [],
            alerts: [Alert(id: "watchdog-safe", severity: .critical, title: "t", detail: "d")],
            severity: .critical
        )
        XCTAssertTrue(critical.fault)
    }
}
