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
                primaryHeartbeatState: .healthy,
                primaryHeartbeatDetail: "primary audio carrier healthy",
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
        XCTAssertEqual(pipeline["primaryHeartbeatState"] as? String, "healthy")
        XCTAssertEqual(pipeline["encoderState"] as? String, "healthy")
    }

    func testPrimaryAudioHeartbeatRequiresRunningRouteAndFreshCallbacks() {
        let heartbeat = PrimaryAudioHeartbeat.make(
            name: "venue",
            nowMs: 10_000,
            operatorStopped: false,
            engineRunning: true,
            routeHealthy: true,
            routeDetail: "route ready",
            inputCallbackAgeMs: 20,
            outputCallbackAgeMs: 25
        )

        XCTAssertTrue(heartbeat.ok)
        XCTAssertTrue(heartbeat.healthy)
        XCTAssertTrue(heartbeat.streaming)
        XCTAssertTrue(heartbeat.audioActive)
        XCTAssertTrue(heartbeat.manualReturnRequired)

        let stalled = PrimaryAudioHeartbeat.make(
            name: "venue",
            nowMs: 10_000,
            operatorStopped: false,
            engineRunning: true,
            routeHealthy: true,
            routeDetail: "route ready",
            inputCallbackAgeMs: 1_000,
            outputCallbackAgeMs: 25
        )
        XCTAssertFalse(stalled.healthy)
        XCTAssertFalse(stalled.streaming)
        XCTAssertFalse(stalled.audioActive)
        XCTAssertEqual(stalled.detail, "input callback stalled")

        let wrongRoute = PrimaryAudioHeartbeat.make(
            name: "venue",
            nowMs: 10_000,
            operatorStopped: false,
            engineRunning: true,
            routeHealthy: false,
            routeDetail: "wrong output UID",
            inputCallbackAgeMs: 20,
            outputCallbackAgeMs: 25
        )
        XCTAssertFalse(wrongRoute.healthy)
        XCTAssertFalse(wrongRoute.streaming)
        XCTAssertFalse(wrongRoute.audioActive)
        XCTAssertEqual(wrongRoute.detail, "wrong output UID")
    }

    func testPrimaryAudioHeartbeatNormalizesNonfiniteCallbackTelemetry() throws {
        let heartbeat = PrimaryAudioHeartbeat.make(
            name: "venue",
            nowMs: 10_000,
            operatorStopped: false,
            engineRunning: true,
            routeHealthy: true,
            routeDetail: "route ready",
            inputCallbackAgeMs: .nan,
            outputCallbackAgeMs: .infinity
        )

        XCTAssertFalse(heartbeat.healthy)
        XCTAssertEqual(heartbeat.inputCallbackAgeMs, -1)
        XCTAssertEqual(heartbeat.outputCallbackAgeMs, -1)
        let data = try JSONEncoder().encode(heartbeat)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        for key in [
            "formatVersion", "kind", "ok", "healthy", "streaming", "audioActive",
            "timestampMs", "name", "detail", "engineRunning", "routeHealthy",
            "inputCallbackAgeMs", "outputCallbackAgeMs", "manualReturnRequired"
        ] {
            XCTAssertNotNil(object[key], "missing heartbeat key \(key)")
        }
    }

    func testPrimaryAudioHeartbeatFailsClosedWhenStaleOrFutureDated() {
        let heartbeat = PrimaryAudioHeartbeat.make(
            name: "venue",
            nowMs: 10_000,
            operatorStopped: false,
            engineRunning: true,
            routeHealthy: true,
            routeDetail: "route ready",
            inputCallbackAgeMs: 20,
            outputCallbackAgeMs: 25
        )

        XCTAssertTrue(
            heartbeat.evaluated(
                at: 10_000 + PrimaryAudioHeartbeat.maximumFreshAgeMs
            ).healthy
        )
        let stale = heartbeat.evaluated(
            at: 10_001 + PrimaryAudioHeartbeat.maximumFreshAgeMs
        )
        XCTAssertFalse(stale.healthy)
        XCTAssertEqual(stale.detail, "heartbeat stale")

        let future = heartbeat.evaluated(at: 9_999)
        XCTAssertFalse(future.healthy)
        XCTAssertEqual(future.detail, "heartbeat timestamp is in the future")
    }

    func testMonitorServiceHealthDefaultsFailClosedAndPublishesAtomically() {
        let core = MonitorServiceCore(
            pairingStore: PairingStore(code: "424242"),
            healthName: "venue"
        )
        XCTAssertFalse(core.currentPrimaryAudioHeartbeat().healthy)

        let heartbeat = PrimaryAudioHeartbeat.make(
            name: "venue",
            nowMs: 10_000,
            operatorStopped: false,
            engineRunning: true,
            routeHealthy: true,
            routeDetail: "route ready",
            inputCallbackAgeMs: 20,
            outputCallbackAgeMs: 25
        )
        core.publishPrimaryAudioHeartbeat(heartbeat)
        XCTAssertEqual(core.currentPrimaryAudioHeartbeat(), heartbeat)
    }

    func testRemoteControlFreshnessAcceptsOnlyRecentServerAndClientSnapshots() {
        let nowMs: Int64 = 10_000
        XCTAssertNil(
            RemoteControlFreshness.rejection(
                nowMs: nowMs,
                serverSnapshotTs: nowMs,
                clientSnapshotTs: nowMs
            )
        )
        XCTAssertNil(
            RemoteControlFreshness.rejection(
                nowMs: nowMs,
                serverSnapshotTs:
                    nowMs - RemoteControlFreshness.maximumServerSnapshotAgeMs,
                clientSnapshotTs:
                    nowMs -
                    RemoteControlFreshness.maximumServerSnapshotAgeMs -
                    RemoteControlFreshness.maximumClientSnapshotLagMs
            )
        )
    }

    func testRemoteControlFreshnessRejectsMissingOrInvalidServerTelemetry() {
        let nowMs: Int64 = 10_000
        XCTAssertEqual(
            RemoteControlFreshness.rejection(
                nowMs: nowMs,
                serverSnapshotTs: nowMs,
                clientSnapshotTs: nil
            ),
            .clientSnapshotMissing
        )
        XCTAssertEqual(
            RemoteControlFreshness.rejection(
                nowMs: nowMs,
                serverSnapshotTs: 0,
                clientSnapshotTs: nowMs
            ),
            .serverSnapshotUnavailable
        )
        XCTAssertEqual(
            RemoteControlFreshness.rejection(
                nowMs: nowMs,
                serverSnapshotTs: nowMs + 1,
                clientSnapshotTs: nowMs
            ),
            .serverSnapshotFuture
        )
        XCTAssertEqual(
            RemoteControlFreshness.rejection(
                nowMs: nowMs,
                serverSnapshotTs:
                    nowMs - RemoteControlFreshness.maximumServerSnapshotAgeMs - 1,
                clientSnapshotTs: nowMs
            ),
            .serverSnapshotStale
        )
    }

    func testRemoteControlFreshnessRejectsFutureOrStaleClientView() {
        let nowMs: Int64 = 10_000
        XCTAssertEqual(
            RemoteControlFreshness.rejection(
                nowMs: nowMs,
                serverSnapshotTs: nowMs,
                clientSnapshotTs: nowMs + 1
            ),
            .clientSnapshotFuture
        )
        XCTAssertEqual(
            RemoteControlFreshness.rejection(
                nowMs: nowMs,
                serverSnapshotTs: nowMs,
                clientSnapshotTs:
                    nowMs - RemoteControlFreshness.maximumClientSnapshotLagMs - 1
            ),
            .clientSnapshotStale
        )
        XCTAssertEqual(
            RemoteControlFreshness.rejection(
                nowMs: nowMs,
                serverSnapshotTs: nowMs,
                clientSnapshotTs: Int64.min
            ),
            .clientSnapshotStale
        )
    }

    func testMonitorServicePublishesSnapshotDataAndTimestampTogether() {
        let core = MonitorServiceCore(
            pairingStore: PairingStore(code: "424242"),
            healthName: "venue"
        )
        let data = Data(#"{"ts":1234}"#.utf8)
        core.publish(data, timestampMs: 1_234)
        XCTAssertEqual(core.currentSnapshotJSON(), data)
        XCTAssertEqual(core.currentSnapshotTimestampMs(), 1_234)
    }

    func testRemoteCommandExecutionWindowRejectsLateMainActorWork() {
        let startedAtMs: Int64 = 10_000
        let deadlineMs = RemoteCommandExecutionWindow.deadlineMs(
            startedAtMs: startedAtMs
        )
        XCTAssertEqual(
            deadlineMs,
            startedAtMs + RemoteCommandExecutionWindow.maximumExecutionDelayMs
        )
        XCTAssertTrue(
            RemoteCommandExecutionWindow.canExecute(
                nowMs: deadlineMs,
                deadlineMs: deadlineMs
            )
        )
        XCTAssertFalse(
            RemoteCommandExecutionWindow.canExecute(
                nowMs: deadlineMs + 1,
                deadlineMs: deadlineMs
            )
        )
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
        XCTAssertEqual(
            try decode(#"{"type":"setSafe","on":true,"snapshotTs":1234}"#),
            .setSafe(on: true)
        )
        XCTAssertEqual(
            try decode(
                #"{"type":"setSafe","on":false,"confirmSafeRelease":true,"snapshotTs":1234}"#
            ),
            .setSafe(on: false)
        )
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
