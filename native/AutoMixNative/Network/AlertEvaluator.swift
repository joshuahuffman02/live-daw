import Foundation

enum StreamHealthState: String, Codable, Equatable, Sendable {
    case disabled
    case checking
    case healthy
    case unhealthy
}

struct StreamEndpointHealth: Equatable, Sendable {
    var state: StreamHealthState
    var detail: String
    var checkedAtMs: Int64?
    var observedAtMs: Int64?

    static let disabled = StreamEndpointHealth(
        state: .disabled,
        detail: "not configured",
        checkedAtMs: nil,
        observedAtMs: nil
    )

    var isConfigured: Bool { state != .disabled }
    var isFailure: Bool { state == .unhealthy }

    var summary: String {
        switch state {
        case .disabled: return "not configured"
        case .checking: return "checking"
        case .healthy: return detail.isEmpty ? "healthy" : "healthy · \(detail)"
        case .unhealthy: return detail.isEmpty ? "unhealthy" : detail
        }
    }
}

struct StreamHealthPayload: Codable, Equatable, Sendable {
    var healthy: Bool
    var streaming: Bool?
    var audioActive: Bool?
    var timestampMs: Int64
    var detail: String?
}

enum StreamHealthAssessment {
    static func assess(
        statusCode: Int,
        data: Data,
        nowMs: Int64,
        maxPayloadAgeMs: Int64 = 15_000
    ) -> StreamEndpointHealth {
        guard (200...299).contains(statusCode) else {
            return unhealthy("HTTP \(statusCode)", nowMs: nowMs)
        }

        let payload: StreamHealthPayload
        do {
            payload = try JSONDecoder().decode(StreamHealthPayload.self, from: data)
        } catch {
            return unhealthy("invalid health JSON", nowMs: nowMs)
        }

        let ageMs = nowMs - payload.timestampMs
        guard ageMs >= -5_000, ageMs <= maxPayloadAgeMs else {
            return unhealthy(
                ageMs < 0 ? "health timestamp is in the future" : "stale health payload",
                nowMs: nowMs,
                observedAtMs: payload.timestampMs
            )
        }
        guard payload.healthy else {
            return unhealthy(
                payload.detail ?? "endpoint reports unhealthy",
                nowMs: nowMs,
                observedAtMs: payload.timestampMs
            )
        }
        if payload.streaming == false {
            return unhealthy(
                payload.detail ?? "encoder is not streaming",
                nowMs: nowMs,
                observedAtMs: payload.timestampMs
            )
        }
        if payload.audioActive == false {
            return unhealthy(
                payload.detail ?? "encoder has no audio carrier",
                nowMs: nowMs,
                observedAtMs: payload.timestampMs
            )
        }

        return StreamEndpointHealth(
            state: .healthy,
            detail: payload.detail ?? "live",
            checkedAtMs: nowMs,
            observedAtMs: payload.timestampMs
        )
    }

    static func invalidURL(nowMs: Int64) -> StreamEndpointHealth {
        unhealthy("enter an http:// or https:// health URL", nowMs: nowMs)
    }

    static func requestFailed(_ message: String, nowMs: Int64) -> StreamEndpointHealth {
        unhealthy(message, nowMs: nowMs)
    }

    private static func unhealthy(
        _ detail: String,
        nowMs: Int64,
        observedAtMs: Int64? = nil
    ) -> StreamEndpointHealth {
        StreamEndpointHealth(
            state: .unhealthy,
            detail: detail,
            checkedAtMs: nowMs,
            observedAtMs: observedAtMs
        )
    }
}

actor StreamHealthProbe {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func probe(urlString: String, nowMs: Int64) async -> StreamEndpointHealth {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .disabled }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil
        else {
            return StreamHealthAssessment.invalidURL(nowMs: nowMs)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 2
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return StreamHealthAssessment.requestFailed(
                    "health endpoint did not return HTTP",
                    nowMs: nowMs
                )
            }
            return StreamHealthAssessment.assess(
                statusCode: http.statusCode,
                data: data,
                nowMs: nowMs
            )
        } catch {
            return StreamHealthAssessment.requestFailed(
                error.localizedDescription,
                nowMs: nowMs
            )
        }
    }
}

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
    var callbackStallMs = 1_000.0
    var clockCorrectionWarningPpm = 900.0
    var clockRiskSustainMs: Int64 = 2_000
    var streamHealthSustainMs: Int64 = 3_000
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
    var inputCallbackAgeMs: Double = -1
    var outputCallbackAgeMs: Double = -1
    var outputClockCorrectionPpm: Double = 0
    var outputRingFillFrames: Int = 0
    var outputRingTargetFrames: Int = 0
    var recordingDroppedFrames: UInt = 0
    var encoderHealth: StreamEndpointHealth = .disabled
    var egressHealth: StreamEndpointHealth = .disabled
}

struct AlertEvaluator {
    var thresholds = AlertThresholds()

    private var everRunning = false
    private var prevCounters: CounterTelemetry?
    private var previousRecordingDroppedFrames: UInt?
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

        // Callback heartbeat covers the local encoder handoff more directly than
        // meter silence: intentional program silence is valid, a stopped Core Audio
        // callback is not.
        let inputStalled = input.isRunning &&
            input.inputCallbackAgeMs >= thresholds.callbackStallMs
        let outputStalled = input.isRunning &&
            input.outputCallbackAgeMs >= thresholds.callbackStallMs
        if inputStalled || outputStalled {
            let paths = [
                inputStalled ? "input" : nil,
                outputStalled ? "output" : nil
            ].compactMap { $0 }.joined(separator: " + ")
            alerts.append(Alert(id: "callback-stalled", severity: .critical,
                                title: "Audio callback stalled",
                                detail: "\(paths) callback has not advanced for at least 1 second",
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

        if let previousRecordingDroppedFrames,
           input.recordingDroppedFrames > previousRecordingDroppedFrames {
            alerts.append(Alert(id: "recording-drops", severity: .warning,
                                title: "Recording incomplete",
                                detail: "Continuous recorder dropped frames; the live mix remains active",
                                actions: []))
        }
        previousRecordingDroppedFrames = input.recordingDroppedFrames

        let endpointFailures = [
            input.encoderHealth.isFailure ? "encoder: \(input.encoderHealth.detail)" : nil,
            input.egressHealth.isFailure ? "egress: \(input.egressHealth.detail)" : nil
        ].compactMap { $0 }
        if sustained(
            "stream-pipeline-health",
            active: input.isRunning && !endpointFailures.isEmpty,
            nowMs: nowMs,
            requiredMs: thresholds.streamHealthSustainMs
        ) {
            alerts.append(Alert(
                id: "stream-pipeline-health",
                severity: .critical,
                title: "Livestream pipeline unhealthy",
                detail: endpointFailures.joined(separator: " · "),
                actions: []
            ))
        }

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

        let clockFillRisk = input.outputRingTargetFrames > 0 &&
            (input.outputRingFillFrames < max(1, input.outputRingTargetFrames / 4) ||
             input.outputRingFillFrames > input.outputRingTargetFrames * 3)
        let clockCorrectionRisk = input.outputRingTargetFrames > 0 &&
            abs(input.outputClockCorrectionPpm) >= thresholds.clockCorrectionWarningPpm
        if sustained("output-clock-risk",
                     active: input.isRunning && (clockFillRisk || clockCorrectionRisk),
                     nowMs: nowMs,
                     requiredMs: thresholds.clockRiskSustainMs) {
            alerts.append(Alert(
                id: "output-clock-risk",
                severity: .warning,
                title: "Output clock near correction limit",
                detail: String(
                    format: "%+.0f ppm · ring %d/%d frames",
                    input.outputClockCorrectionPpm,
                    input.outputRingFillFrames,
                    input.outputRingTargetFrames
                ),
                actions: []
            ))
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

struct RuntimeHealthSample: Equatable {
    var nowMs: Int64
    var armed: Bool
    var operatorStopped: Bool
    var isRunning: Bool
    var routeHealthy: Bool
    var inputCallbackAgeMs: Double
    var outputCallbackAgeMs: Double
}

enum RuntimeRecoveryAction: Equatable {
    case none
    case attemptRestart(reason: String)
}

// Deterministic restart policy. It never performs I/O itself, which keeps device
// mutation in AppModel and makes the grace/backoff behavior replayable in tests.
struct RuntimeRecoveryCoordinator {
    var unhealthyGraceMs: Int64 = 2_000
    var verificationGraceMs: Int64 = 3_000
    var callbackStallMs = 1_000.0
    var backoffMs: [Int64] = [1_000, 2_000, 5_000, 10_000, 30_000, 60_000]

    private(set) var attemptCount = 0
    private(set) var lastReason: String?
    private var unhealthySinceMs: Int64?
    private var nextAttemptMs: Int64?
    private var verifyingUntilMs: Int64?
    private var awaitingResult = false

    init(unhealthyGraceMs: Int64 = 2_000,
         verificationGraceMs: Int64 = 3_000,
         callbackStallMs: Double = 1_000.0,
         backoffMs: [Int64] = [1_000, 2_000, 5_000, 10_000, 30_000, 60_000]) {
        self.unhealthyGraceMs = unhealthyGraceMs
        self.verificationGraceMs = verificationGraceMs
        self.callbackStallMs = callbackStallMs
        self.backoffMs = backoffMs
    }

    mutating func arm(nowMs: Int64) {
        unhealthySinceMs = nil
        nextAttemptMs = nil
        verifyingUntilMs = nowMs + verificationGraceMs
        awaitingResult = false
        lastReason = nil
    }

    mutating func disarm() {
        attemptCount = 0
        unhealthySinceMs = nil
        nextAttemptMs = nil
        verifyingUntilMs = nil
        awaitingResult = false
        lastReason = nil
    }

    mutating func step(_ sample: RuntimeHealthSample) -> RuntimeRecoveryAction {
        guard sample.armed, !sample.operatorStopped else {
            disarm()
            return .none
        }
        if awaitingResult { return .none }

        let reason = unhealthyReason(sample)
        if reason == nil {
            attemptCount = 0
            unhealthySinceMs = nil
            nextAttemptMs = nil
            verifyingUntilMs = nil
            lastReason = nil
            return .none
        }

        if let verifyingUntilMs, sample.nowMs < verifyingUntilMs {
            return .none
        }
        verifyingUntilMs = nil

        if let nextAttemptMs {
            guard sample.nowMs >= nextAttemptMs else { return .none }
            self.nextAttemptMs = nil
        } else {
            let unhealthySince = unhealthySinceMs ?? sample.nowMs
            unhealthySinceMs = unhealthySince
            guard sample.nowMs - unhealthySince >= unhealthyGraceMs else {
                return .none
            }
        }

        let resolvedReason = reason ?? "runtime health failed"
        awaitingResult = true
        lastReason = resolvedReason
        return .attemptRestart(reason: resolvedReason)
    }

    mutating func noteAttemptResult(success: Bool, nowMs: Int64) {
        guard awaitingResult else { return }
        awaitingResult = false
        if success {
            unhealthySinceMs = nil
            nextAttemptMs = nil
            verifyingUntilMs = nowMs + verificationGraceMs
            return
        }

        attemptCount += 1
        let index = min(max(attemptCount - 1, 0), max(backoffMs.count - 1, 0))
        let delay = backoffMs.isEmpty ? 60_000 : backoffMs[index]
        nextAttemptMs = nowMs + delay
    }

    private func unhealthyReason(_ sample: RuntimeHealthSample) -> String? {
        if !sample.isRunning { return "audio engine stopped unexpectedly" }
        if !sample.routeHealthy { return "Core Audio route is no longer ready" }
        if sample.inputCallbackAgeMs < 0 { return "input callback has not started" }
        if sample.outputCallbackAgeMs < 0 { return "output callback has not started" }
        if sample.inputCallbackAgeMs >= callbackStallMs {
            return "input callback stalled"
        }
        if sample.outputCallbackAgeMs >= callbackStallMs {
            return "output callback stalled"
        }
        return nil
    }
}

struct RuntimeIncident: Codable, Equatable, Sendable {
    var timestampMs: Int64
    var kind: String
    var severity: AlertSeverity
    var message: String
    var details: [String: String]
}

actor RuntimeIncidentJournal {
    nonisolated let fileURL: URL

    init(directory: URL, fileName: String = "runtime-incidents.jsonl") throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        self.fileURL = directory.appendingPathComponent(fileName)
    }

    @discardableResult
    func append(_ incident: RuntimeIncident) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(incident)
        data.append(0x0A)

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try Data().write(to: fileURL, options: .atomic)
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
        return fileURL
    }
}
