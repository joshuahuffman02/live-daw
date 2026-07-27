import Foundation
import XCTest
@testable import AutoMix_Native

final class AlertEvaluatorTests: XCTestCase {
    private func healthy() -> AlertInput {
        AlertInput(
            isRunning: true,
            operatorStopped: false,
            streamL: -8.0,
            streamR: -8.2,
            watchdogSafe: false,
            integratedLufs: -14.0,
            counters: CounterTelemetry(
                dropouts: 0, callbackOverruns: 0, deadlineMisses: 0,
                outputUnderruns: 0, outputOverruns: 0,
                lastCallbackFrames: 256, maxCallbackFrames: 256
            ),
            routeHealthy: true,
            channels: []
        )
    }

    private func ids(_ result: (alerts: [Alert], severity: AlertSeverity)) -> Set<String> {
        Set(result.alerts.map(\.id))
    }

    func testHealthyRunningInputProducesNoAlerts() {
        var ev = AlertEvaluator()
        let result = ev.step(healthy(), nowMs: 0)
        XCTAssertTrue(result.alerts.isEmpty)
        XCTAssertEqual(result.severity, .none)
    }

    func testIdleNeverStartedProducesNoAlerts() {
        var ev = AlertEvaluator()
        var input = healthy()
        input.isRunning = false
        input.streamL = -100
        input.streamR = -100
        input.integratedLufs = -100
        let result = ev.step(input, nowMs: 0)
        XCTAssertTrue(result.alerts.isEmpty, "idle app should be quiet, got \(ids(result))")
    }

    func testStreamSilenceFiresCriticalOnlyAfterSustain() {
        var ev = AlertEvaluator()
        var silent = healthy()
        silent.streamL = -100
        silent.streamR = -100

        XCTAssertFalse(ids(ev.step(silent, nowMs: 0)).contains("stream-silent"))
        XCTAssertFalse(ids(ev.step(silent, nowMs: 1_000)).contains("stream-silent"))
        let fired = ev.step(silent, nowMs: 2_500)
        XCTAssertTrue(ids(fired).contains("stream-silent"))
        XCTAssertEqual(fired.severity, .critical)
        XCTAssertEqual(fired.alerts.first { $0.id == "stream-silent" }?.actions, ["engageSafe"])
    }

    func testStreamSilenceClearsWhenAudioReturns() {
        var ev = AlertEvaluator()
        var silent = healthy()
        silent.streamL = -100
        silent.streamR = -100
        _ = ev.step(silent, nowMs: 0)
        XCTAssertTrue(ids(ev.step(silent, nowMs: 3_000)).contains("stream-silent"))
        XCTAssertFalse(ids(ev.step(healthy(), nowMs: 3_100)).contains("stream-silent"))
    }

    func testWatchdogSafeFiresImmediatelyCritical() {
        var ev = AlertEvaluator()
        var input = healthy()
        input.watchdogSafe = true
        let result = ev.step(input, nowMs: 0)
        XCTAssertTrue(ids(result).contains("watchdog-safe"))
        XCTAssertEqual(result.severity, .critical)
    }

    func testEngineStoppedFiresWhenRunningDropsUnexpectedly() {
        var ev = AlertEvaluator()
        _ = ev.step(healthy(), nowMs: 0)
        var stopped = healthy()
        stopped.isRunning = false
        let result = ev.step(stopped, nowMs: 100)
        XCTAssertTrue(ids(result).contains("engine-stopped"))
        XCTAssertEqual(result.severity, .critical)
    }

    func testEngineStoppedSuppressedWhenOperatorStopped() {
        var ev = AlertEvaluator()
        _ = ev.step(healthy(), nowMs: 0)
        var stopped = healthy()
        stopped.isRunning = false
        stopped.operatorStopped = true
        let result = ev.step(stopped, nowMs: 100)
        XCTAssertFalse(ids(result).contains("engine-stopped"))
    }

    func testCallbackStallIsCriticalWithoutDependingOnProgramSilence() {
        var ev = AlertEvaluator()
        var input = healthy()
        input.inputCallbackAgeMs = 1_250
        input.outputCallbackAgeMs = 1_400
        let result = ev.step(input, nowMs: 0)
        XCTAssertTrue(ids(result).contains("callback-stalled"))
        XCTAssertEqual(result.severity, .critical)
    }

    func testOutputClockRiskRequiresSustainAndClearsNearTarget() {
        var ev = AlertEvaluator()
        var input = healthy()
        input.outputRingTargetFrames = 4_096
        input.outputRingFillFrames = 500
        input.outputClockCorrectionPpm = -950
        XCTAssertFalse(ids(ev.step(input, nowMs: 0)).contains("output-clock-risk"))
        XCTAssertTrue(ids(ev.step(input, nowMs: 2_500)).contains("output-clock-risk"))

        input.outputRingFillFrames = 4_096
        input.outputClockCorrectionPpm = 100
        XCTAssertFalse(ids(ev.step(input, nowMs: 2_600)).contains("output-clock-risk"))
    }

    func testEncoderOrEgressFailureBecomesCriticalAfterSustain() {
        var ev = AlertEvaluator()
        var input = healthy()
        input.encoderHealth = StreamEndpointHealth(
            state: .unhealthy,
            detail: "encoder is not streaming",
            checkedAtMs: 0,
            observedAtMs: 0
        )

        XCTAssertFalse(ids(ev.step(input, nowMs: 0)).contains("stream-pipeline-health"))
        let fired = ev.step(input, nowMs: 3_100)
        XCTAssertTrue(ids(fired).contains("stream-pipeline-health"))
        XCTAssertEqual(fired.severity, .critical)

        input.encoderHealth = StreamEndpointHealth(
            state: .healthy,
            detail: "live",
            checkedAtMs: 3_200,
            observedAtMs: 3_200
        )
        XCTAssertFalse(ids(ev.step(input, nowMs: 3_200)).contains("stream-pipeline-health"))
    }

    func testContinuousRecordingDropsAlertOnlyWhenCounterClimbs() {
        var ev = AlertEvaluator()
        var input = healthy()
        input.recordingDroppedFrames = 0
        XCTAssertFalse(ids(ev.step(input, nowMs: 0)).contains("recording-drops"))
        input.recordingDroppedFrames = 256
        XCTAssertTrue(ids(ev.step(input, nowMs: 100)).contains("recording-drops"))
        XCTAssertFalse(ids(ev.step(input, nowMs: 200)).contains("recording-drops"))
    }

    func testRequestedButInactiveRecordingIsCriticalWithoutStoppingMix() {
        var ev = AlertEvaluator()
        var input = healthy()
        input.recordingRequested = true
        input.recordingActive = false
        input.recordingStorageStatus = "waiting · insufficient space"

        let result = ev.step(input, nowMs: 0)

        XCTAssertTrue(ids(result).contains("recording-not-active"))
        XCTAssertEqual(result.severity, .critical)
        XCTAssertEqual(
            result.alerts.first { $0.id == "recording-not-active" }?.detail,
            "waiting · insufficient space"
        )
    }

    func testXrunFiresOnCounterIncreaseThenClears() {
        var ev = AlertEvaluator()
        _ = ev.step(healthy(), nowMs: 0)
        var bumped = healthy()
        bumped.counters = CounterTelemetry(
            dropouts: 3, callbackOverruns: 0, deadlineMisses: 0,
            outputUnderruns: 0, outputOverruns: 0,
            lastCallbackFrames: 256, maxCallbackFrames: 256
        )
        XCTAssertTrue(ids(ev.step(bumped, nowMs: 100)).contains("xrun"))
        // same counters again -> no further increase -> no alert
        XCTAssertFalse(ids(ev.step(bumped, nowMs: 200)).contains("xrun"))
    }

    func testClippingFiresAfterSustain() {
        var ev = AlertEvaluator()
        var clip = healthy()
        clip.streamL = 0.0
        clip.streamR = -0.05
        XCTAssertFalse(ids(ev.step(clip, nowMs: 0)).contains("clipping"))
        let fired = ev.step(clip, nowMs: 1_500)
        XCTAssertTrue(ids(fired).contains("clipping"))
        XCTAssertEqual(fired.severity, .warning)
    }

    func testLoudnessOutOfBandFiresAfterSustainButNotInBand() {
        var ev = AlertEvaluator()
        // in band: quiet
        XCTAssertFalse(ids(ev.step(healthy(), nowMs: 0)).contains("loudness-band"))
        var hot = healthy()
        hot.integratedLufs = -6.0
        XCTAssertFalse(ids(ev.step(hot, nowMs: 1_000)).contains("loudness-band"))
        XCTAssertTrue(ids(ev.step(hot, nowMs: 12_000)).contains("loudness-band"))
    }

    func testLoudnessBandIgnoresUnmeasuredSilence() {
        var ev = AlertEvaluator()
        var unmeasured = healthy()
        unmeasured.integratedLufs = -100   // no real measurement yet
        _ = ev.step(unmeasured, nowMs: 0)
        XCTAssertFalse(ids(ev.step(unmeasured, nowMs: 20_000)).contains("loudness-band"))
    }

    func testRouteDriftFiresWhileRunning() {
        var ev = AlertEvaluator()
        var drift = healthy()
        drift.routeHealthy = false
        let result = ev.step(drift, nowMs: 0)
        XCTAssertTrue(ids(result).contains("route-drift"))
        XCTAssertEqual(result.severity, .warning)
    }

    func testDeadChannelFiresWhenAssignedChannelSilentWithActivePeer() {
        var ev = AlertEvaluator()
        var input = healthy()
        input.channels = [
            AlertInput.Channel(idx: 0, role: "speech", levelDb: -100),  // dead, assigned
            AlertInput.Channel(idx: 1, role: "speech", levelDb: -10)    // active peer
        ]
        XCTAssertFalse(ids(ev.step(input, nowMs: 0)).contains("dead-channel"))
        let fired = ev.step(input, nowMs: 6_000)
        XCTAssertTrue(ids(fired).contains("dead-channel"))
        XCTAssertEqual(fired.severity, .info)
    }

    func testDeadChannelDoesNotFireWithoutActivePeer() {
        var ev = AlertEvaluator()
        var input = healthy()
        input.channels = [
            AlertInput.Channel(idx: 0, role: "speech", levelDb: -100),
            AlertInput.Channel(idx: 1, role: "speech", levelDb: -100)
        ]
        _ = ev.step(input, nowMs: 0)
        XCTAssertFalse(ids(ev.step(input, nowMs: 6_000)).contains("dead-channel"))
    }

    func testDeadChannelIgnoresUnknownRole() {
        var ev = AlertEvaluator()
        var input = healthy()
        input.channels = [
            AlertInput.Channel(idx: 0, role: "unknown", levelDb: -100),
            AlertInput.Channel(idx: 1, role: "unknown", levelDb: -10)
        ]
        _ = ev.step(input, nowMs: 0)
        XCTAssertFalse(ids(ev.step(input, nowMs: 6_000)).contains("dead-channel"))
    }

    func testDeadChannelTimerDoesNotBleedAcrossChannels() {
        var ev = AlertEvaluator()
        var aDead = healthy()
        aDead.channels = [
            AlertInput.Channel(idx: 0, role: "speech", levelDb: -100),  // dead
            AlertInput.Channel(idx: 1, role: "speech", levelDb: -10)    // active peer
        ]
        _ = ev.step(aDead, nowMs: 0)
        XCTAssertTrue(ids(ev.step(aDead, nowMs: 6_000)).contains("dead-channel"))  // A legitimately fires

        var bDead = healthy()
        bDead.channels = [
            AlertInput.Channel(idx: 0, role: "speech", levelDb: -10),   // A recovered
            AlertInput.Channel(idx: 1, role: "speech", levelDb: -100)   // B now dead
        ]
        // B has only just gone silent; it must NOT inherit A's elapsed sustain time.
        XCTAssertFalse(ids(ev.step(bDead, nowMs: 6_100)).contains("dead-channel"))
        // B fires on its own ~5s clock.
        XCTAssertTrue(ids(ev.step(bDead, nowMs: 11_200)).contains("dead-channel"))
    }

    func testSeverityIsMaxAcrossSimultaneousAlerts() {
        var ev = AlertEvaluator()
        // prime running for engine-stopped baseline, then create silence (critical) + route drift (warning)
        _ = ev.step(healthy(), nowMs: 0)
        var bad = healthy()
        bad.streamL = -100
        bad.streamR = -100
        bad.routeHealthy = false
        _ = ev.step(bad, nowMs: 100)
        let result = ev.step(bad, nowMs: 3_000)
        XCTAssertTrue(ids(result).isSuperset(of: ["stream-silent", "route-drift"]))
        XCTAssertEqual(result.severity, .critical)
    }

    func testRecoveryCoordinatorUsesGraceBackoffAndVerification() {
        var coordinator = RuntimeRecoveryCoordinator()
        coordinator.arm(nowMs: 0)
        var sample = RuntimeHealthSample(
            nowMs: 100,
            armed: true,
            operatorStopped: false,
            isRunning: true,
            routeHealthy: true,
            inputCallbackAgeMs: 5,
            outputCallbackAgeMs: 5
        )
        XCTAssertEqual(coordinator.step(sample), .none)

        sample.routeHealthy = false
        sample.nowMs = 200
        XCTAssertEqual(coordinator.step(sample), .none)
        sample.nowMs = 2_300
        XCTAssertEqual(
            coordinator.step(sample),
            .attemptRestart(reason: "Core Audio route is no longer ready")
        )

        coordinator.noteAttemptResult(success: false, nowMs: 2_300)
        XCTAssertEqual(coordinator.attemptCount, 1)
        sample.nowMs = 3_200
        XCTAssertEqual(coordinator.step(sample), .none)
        sample.nowMs = 3_300
        XCTAssertEqual(
            coordinator.step(sample),
            .attemptRestart(reason: "Core Audio route is no longer ready")
        )

        coordinator.noteAttemptResult(success: true, nowMs: 3_300)
        sample.nowMs = 5_000
        XCTAssertEqual(coordinator.step(sample), .none, "successful restart gets verification grace")
        sample.routeHealthy = true
        sample.nowMs = 5_100
        XCTAssertEqual(coordinator.step(sample), .none)
        XCTAssertEqual(coordinator.attemptCount, 0)
    }

    func testRecoveryCoordinatorDetectsCallbackStallAndHonorsOperatorStop() {
        var coordinator = RuntimeRecoveryCoordinator(unhealthyGraceMs: 0)
        coordinator.arm(nowMs: 0)
        var sample = RuntimeHealthSample(
            nowMs: 4_000,
            armed: true,
            operatorStopped: false,
            isRunning: true,
            routeHealthy: true,
            inputCallbackAgeMs: 1_500,
            outputCallbackAgeMs: 5
        )
        XCTAssertEqual(
            coordinator.step(sample),
            .attemptRestart(reason: "input callback stalled")
        )

        coordinator.noteAttemptResult(success: false, nowMs: 4_000)
        sample.operatorStopped = true
        sample.nowMs = 10_000
        XCTAssertEqual(coordinator.step(sample), .none)
        XCTAssertEqual(coordinator.attemptCount, 0)
    }

    func testIncidentJournalAppendsDurableJSONLines() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try RuntimeIncidentJournal(directory: directory)
        let first = RuntimeIncident(
            timestampMs: 100,
            kind: "route-unhealthy",
            severity: .warning,
            message: "route changed",
            details: ["inputUID": "dante"]
        )
        let second = RuntimeIncident(
            timestampMs: 200,
            kind: "restart-succeeded",
            severity: .info,
            message: "engine recovered",
            details: [:]
        )

        let url = try await journal.append(first)
        _ = try await journal.append(second)
        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(RuntimeIncident.self, from: Data(lines[0].utf8)), first)
        XCTAssertEqual(try decoder.decode(RuntimeIncident.self, from: Data(lines[1].utf8)), second)
    }

    func testHealthyFreshStreamingPayloadPasses() throws {
        let data = try JSONEncoder().encode(StreamHealthPayload(
            healthy: true,
            streaming: true,
            audioActive: true,
            timestampMs: 100_000,
            detail: "primary ingest live"
        ))

        let result = StreamHealthAssessment.assess(
            statusCode: 200,
            data: data,
            nowMs: 105_000
        )

        XCTAssertEqual(result.state, .healthy)
        XCTAssertTrue(result.summary.contains("primary ingest live"))
    }

    func testStaleStreamHealthPayloadFailsEvenWhenHealthyFlagIsTrue() throws {
        let data = try JSONEncoder().encode(StreamHealthPayload(
            healthy: true,
            streaming: true,
            audioActive: true,
            timestampMs: 10_000,
            detail: nil
        ))

        let result = StreamHealthAssessment.assess(
            statusCode: 200,
            data: data,
            nowMs: 30_001
        )

        XCTAssertEqual(result.state, .unhealthy)
        XCTAssertTrue(result.detail.contains("stale"))
    }

    func testStoppedStreamAndMissingAudioCarrierFailHealthAssessment() throws {
        let stopped = try JSONEncoder().encode(StreamHealthPayload(
            healthy: true,
            streaming: false,
            audioActive: true,
            timestampMs: 50_000,
            detail: nil
        ))
        XCTAssertTrue(StreamHealthAssessment.assess(
            statusCode: 200,
            data: stopped,
            nowMs: 50_100
        ).detail.contains("not streaming"))

        let silent = try JSONEncoder().encode(StreamHealthPayload(
            healthy: true,
            streaming: true,
            audioActive: false,
            timestampMs: 50_000,
            detail: nil
        ))
        XCTAssertTrue(StreamHealthAssessment.assess(
            statusCode: 200,
            data: silent,
            nowMs: 50_100
        ).detail.contains("no audio"))
    }

    func testStreamHealthHTTPAndSchemaFailuresAreExplicit() {
        XCTAssertEqual(
            StreamHealthAssessment.assess(
                statusCode: 503,
                data: Data(),
                nowMs: 1
            ).detail,
            "HTTP 503"
        )
        XCTAssertEqual(
            StreamHealthAssessment.assess(
                statusCode: 200,
                data: Data("{}".utf8),
                nowMs: 1
            ).detail,
            "invalid health JSON"
        )
    }
}
