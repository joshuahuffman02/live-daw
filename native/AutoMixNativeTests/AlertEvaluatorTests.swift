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
}
