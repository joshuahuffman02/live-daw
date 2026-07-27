import Foundation

// Pure-ish fault brain. The phone never decides faults; the Mac computes them here
// and pushes them in the telemetry. `step` is deterministic given the same input
// sequence + nowMs, so it is fully unit-testable (see AlertEvaluatorTests).

struct AlertThresholds {
    var silenceDb = -90.0
    var silenceSustainMs: Int64 = 2_000
    var clipDb = -0.1
    var clipSustainMs: Int64 = 1_000
    var loudnessLowLufs = -20.0
    var loudnessHighLufs = -9.0
    var loudnessSustainMs: Int64 = 10_000
    var loudnessMeasuredFloorLufs = -70.0
    var deadChannelDb = -90.0
    var deadChannelActivePeerDb = -60.0
    var deadChannelSustainMs: Int64 = 5_000
}

struct AlertInput {
    struct Channel {
        var idx: Int
        var role: String
        var levelDb: Double
    }

    var isRunning: Bool
    var operatorStopped: Bool
    var streamL: Double
    var streamR: Double
    var watchdogSafe: Bool
    var integratedLufs: Double
    var counters: CounterTelemetry
    var routeHealthy: Bool
    var channels: [Channel]
}

struct AlertEvaluator {
    var thresholds = AlertThresholds()

    private var everRunning = false
    private var prevCounters: CounterTelemetry?
    private var sustainStart: [String: Int64] = [:]

    mutating func step(_ input: AlertInput, nowMs: Int64) -> (alerts: [Alert], severity: AlertSeverity) {
        everRunning = everRunning || input.isRunning
        var alerts: [Alert] = []

        // stream-silent (critical)
        let silent = input.isRunning
            && input.streamL < thresholds.silenceDb
            && input.streamR < thresholds.silenceDb
        if sustained("stream-silent", active: silent, nowMs: nowMs,
                     requiredMs: thresholds.silenceSustainMs) {
            let secs = elapsedSeconds("stream-silent", nowMs: nowMs)
            alerts.append(Alert(id: "stream-silent", severity: .critical,
                                title: "Stream silent",
                                detail: "No audio on stream L/R · \(secs)s",
                                actions: ["engageSafe"]))
        }

        // watchdog-safe (critical)
        if input.watchdogSafe {
            alerts.append(Alert(id: "watchdog-safe", severity: .critical,
                                title: "Watchdog SAFE engaged",
                                detail: "The brain watchdog forced the failsafe mix",
                                actions: []))
        }

        // engine-stopped (critical)
        if everRunning && !input.isRunning && !input.operatorStopped {
            alerts.append(Alert(id: "engine-stopped", severity: .critical,
                                title: "Engine stopped",
                                detail: "Audio engine is no longer running",
                                actions: []))
        }

        // xrun (warning) — any error counter climbed since last tick
        if let prev = prevCounters, countersIncreased(prev, input.counters) {
            alerts.append(Alert(id: "xrun", severity: .warning,
                                title: "Audio glitches",
                                detail: "Dropouts or overruns are climbing",
                                actions: []))
        }
        prevCounters = input.counters

        // clipping (warning)
        let clipping = input.isRunning
            && (input.streamL >= thresholds.clipDb || input.streamR >= thresholds.clipDb)
        if sustained("clipping", active: clipping, nowMs: nowMs,
                     requiredMs: thresholds.clipSustainMs) {
            alerts.append(Alert(id: "clipping", severity: .warning,
                                title: "Stream clipping",
                                detail: "Stream output is at full scale",
                                actions: []))
        }

        // loudness-band (warning)
        let measured = input.integratedLufs > thresholds.loudnessMeasuredFloorLufs
        let outOfBand = input.isRunning && measured
            && (input.integratedLufs < thresholds.loudnessLowLufs
                || input.integratedLufs > thresholds.loudnessHighLufs)
        if sustained("loudness-band", active: outOfBand, nowMs: nowMs,
                     requiredMs: thresholds.loudnessSustainMs) {
            alerts.append(Alert(id: "loudness-band", severity: .warning,
                                title: "Loudness out of range",
                                detail: String(format: "Integrated %.1f LUFS", input.integratedLufs),
                                actions: []))
        }

        // route-drift (warning)
        if input.isRunning && !input.routeHealthy {
            alerts.append(Alert(id: "route-drift", severity: .warning,
                                title: "Route changed",
                                detail: "Sample rate, channel count, format, or output route drifted",
                                actions: []))
        }

        // dead-channel (info) — sustain timer keyed per channel so a recovering
        // channel's elapsed time never bleeds into a different channel going dead.
        let dead = deadChannel(input.channels)
        let deadKey = dead.map { "dead-channel-\($0.idx)" }
        for key in Array(sustainStart.keys) where key.hasPrefix("dead-channel-") && key != deadKey {
            sustainStart[key] = nil
        }
        if let dead, let deadKey,
           sustained(deadKey, active: true, nowMs: nowMs, requiredMs: thresholds.deadChannelSustainMs) {
            alerts.append(Alert(id: "dead-channel", severity: .info,
                                title: "Channel silent",
                                detail: "\(dead.role) channel \(dead.idx + 1) is silent while its group is active",
                                actions: []))
        }

        let severity = alerts.map(\.severity).max() ?? .none
        let order: [AlertSeverity] = [.critical, .warning, .info, .none]
        let sorted = alerts.sorted {
            (order.firstIndex(of: $0.severity) ?? 99) < (order.firstIndex(of: $1.severity) ?? 99)
        }
        return (sorted, severity)
    }

    private mutating func sustained(_ id: String, active: Bool, nowMs: Int64, requiredMs: Int64) -> Bool {
        guard active else {
            sustainStart[id] = nil
            return false
        }
        let start = sustainStart[id] ?? nowMs
        sustainStart[id] = start
        return nowMs - start >= requiredMs
    }

    private func elapsedSeconds(_ id: String, nowMs: Int64) -> Int {
        guard let start = sustainStart[id] else { return 0 }
        return Int((nowMs - start) / 1_000)
    }

    private func countersIncreased(_ a: CounterTelemetry, _ b: CounterTelemetry) -> Bool {
        b.dropouts > a.dropouts
            || b.callbackOverruns > a.callbackOverruns
            || b.deadlineMisses > a.deadlineMisses
            || b.outputUnderruns > a.outputUnderruns
            || b.outputOverruns > a.outputOverruns
    }

    private func deadChannel(_ channels: [AlertInput.Channel]) -> AlertInput.Channel? {
        let assigned = channels.filter { !$0.role.isEmpty && $0.role != "unknown" }
        for ch in assigned where ch.levelDb < thresholds.deadChannelDb {
            let peerActive = assigned.contains {
                $0.idx != ch.idx && $0.role == ch.role && $0.levelDb > thresholds.deadChannelActivePeerDb
            }
            if peerActive { return ch }
        }
        return nil
    }
}
