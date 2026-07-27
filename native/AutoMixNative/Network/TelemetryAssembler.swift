import Foundation

// Pure assembly of the published state into the wire snapshot. Kept separate from
// AppModel so the field mapping is unit-testable without a running engine.
enum TelemetryAssembler {
    static func channelTelemetry(_ mappings: [ChannelMapping], levelsDb: [Double]) -> [ChannelTelemetry] {
        mappings.map { m in
            let level = levelsDb.indices.contains(m.index) ? levelsDb[m.index] : -100.0
            return ChannelTelemetry(
                idx: m.index,
                name: m.name,
                role: m.role.rawValue,
                levelDb: level,
                muted: m.muted,
                faderOverride: m.faderOverrideEnabled,
                faderDb: m.faderDb,
                panOverride: m.panOverrideEnabled,
                pan: m.pan
            )
        }
    }

    static func assemble(
        ts: Int64,
        venueName: String,
        isRunning: Bool,
        safe: Bool,
        freeze: Bool,
        watchdogSafe: Bool,
        scene: String,
        scenes: [String],
        sampleRate: Int,
        inputChannelCount: Int,
        bpm: Double,
        bpmConfidence: Double,
        stream: StreamTelemetry,
        counters: CounterTelemetry,
        channels: [ChannelTelemetry],
        alerts: [Alert],
        severity: AlertSeverity
    ) -> TelemetrySnapshot {
        TelemetrySnapshot(
            ts: ts,
            venueName: venueName,
            isRunning: isRunning,
            safe: safe,
            freeze: freeze,
            watchdogSafe: watchdogSafe,
            scene: scene,
            scenes: scenes,
            sampleRate: sampleRate,
            inputChannelCount: inputChannelCount,
            bpm: bpm,
            bpmConfidence: bpmConfidence,
            stream: stream,
            counters: counters,
            channels: channels,
            alerts: alerts,
            fault: severity == .critical,
            severity: severity
        )
    }
}
