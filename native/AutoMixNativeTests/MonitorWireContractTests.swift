import Foundation
import XCTest
@testable import AutoMix_Native

final class MonitorWireContractTests: XCTestCase {
    private func makeSnapshot() -> TelemetrySnapshot {
        TelemetrySnapshot(
            ts: 1_718_900_000_000,
            venueName: "AutoMix Native",
            isRunning: true,
            safe: false,
            freeze: false,
            watchdogSafe: false,
            scene: "worship",
            scenes: ["worship", "sermon", "patch"],
            sampleRate: 96_000,
            inputChannelCount: 64,
            bpm: 120.0,
            bpmConfidence: 0.8,
            stream: StreamTelemetry(
                l: -7.2, r: -7.6,
                momentaryLufs: -14.2, shortLufs: -14.0, integratedLufs: -14.1,
                limiterGrDb: -1.2
            ),
            counters: CounterTelemetry(
                dropouts: 0, callbackOverruns: 0, deadlineMisses: 0,
                outputUnderruns: 0, outputOverruns: 0,
                lastCallbackFrames: 256, maxCallbackFrames: 256
            ),
            pipeline: PipelineTelemetry(
                encoderState: .healthy,
                encoderDetail: "ingest live",
                egressState: .healthy,
                egressDetail: "public playback live"
            ),
            channels: [
                ChannelTelemetry(
                    idx: 0, name: "Pastor", role: "speech", levelDb: -22.0,
                    muted: false, faderOverride: false, faderDb: 0.0,
                    panOverride: false, pan: 0.0
                )
            ],
            alerts: [
                Alert(id: "stream-silent", severity: .critical,
                      title: "Stream silent", detail: "No audio on stream L/R · 4s",
                      actions: ["engageSafe"])
            ],
            fault: true,
            severity: .critical
        )
    }

    func testTelemetrySnapshotRoundTripsLosslessly() throws {
        let snapshot = makeSnapshot()
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(TelemetrySnapshot.self, from: data)
        XCTAssertEqual(decoded, snapshot)
    }

    func testTelemetrySnapshotUsesDocumentedJSONKeys() throws {
        let data = try JSONEncoder().encode(makeSnapshot())
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        for key in ["ts", "venueName", "isRunning", "safe", "freeze", "watchdogSafe",
                    "scene", "scenes", "sampleRate", "inputChannelCount", "bpm",
                    "bpmConfidence", "stream",
                    "counters", "pipeline", "channels", "alerts", "fault", "severity"] {
            XCTAssertNotNil(object[key], "missing top-level key \(key)")
        }
        let stream = try XCTUnwrap(object["stream"] as? [String: Any])
        XCTAssertNotNil(stream["momentaryLufs"])
        XCTAssertNotNil(stream["limiterGrDb"])
        let pipeline = try XCTUnwrap(object["pipeline"] as? [String: Any])
        XCTAssertEqual(pipeline["encoderState"] as? String, "healthy")
    }

    func testAlertSeverityIsComparableForMaxEscalation() {
        XCTAssertLessThan(AlertSeverity.none, AlertSeverity.info)
        XCTAssertLessThan(AlertSeverity.info, AlertSeverity.warning)
        XCTAssertLessThan(AlertSeverity.warning, AlertSeverity.critical)
        let severities: [AlertSeverity] = [.info, .critical, .warning]
        XCTAssertEqual(severities.max(), .critical)
    }

    func testRemoteCommandDecodesDocumentedWireShapes() throws {
        let decoder = JSONDecoder()
        func decode(_ json: String) throws -> RemoteCommand {
            try decoder.decode(RemoteCommand.self, from: Data(json.utf8))
        }

        XCTAssertEqual(try decode(#"{"type":"setSafe","on":true}"#),
                       .setSafe(on: true))
        XCTAssertEqual(try decode(#"{"type":"setFreeze","on":false}"#),
                       .setFreeze(on: false))
        XCTAssertEqual(try decode(#"{"type":"setScene","scene":"sermon"}"#),
                       .setScene(scene: "sermon"))
        XCTAssertEqual(try decode(#"{"type":"setMute","idx":7,"on":true}"#),
                       .setMute(idx: 7, on: true))
        XCTAssertEqual(try decode(#"{"type":"setFaderOverride","idx":7,"on":true,"db":-6.0}"#),
                       .setFaderOverride(idx: 7, on: true, db: -6.0))
        XCTAssertEqual(try decode(#"{"type":"setPanOverride","idx":7,"on":true,"pan":-0.3}"#),
                       .setPanOverride(idx: 7, on: true, pan: -0.3))
        XCTAssertEqual(try decode(#"{"type":"clearOverride","idx":7}"#),
                       .clearOverride(idx: 7))
    }

    func testRemoteCommandRejectsUnknownType() {
        let json = Data(#"{"type":"launchMissiles","idx":1}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(RemoteCommand.self, from: json))
    }

    func testRemoteCommandEncodesTypeTag() throws {
        let data = try JSONEncoder().encode(RemoteCommand.setMute(idx: 3, on: true))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["type"] as? String, "setMute")
        XCTAssertEqual(object["idx"] as? Int, 3)
        XCTAssertEqual(object["on"] as? Bool, true)
    }

    func testCommandResultRoundTrips() throws {
        let result = CommandResult(ok: false, message: "not paired")
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(CommandResult.self, from: data)
        XCTAssertEqual(decoded, result)
    }
}
