import Foundation

// Main-actor glue between AppModel and the embedded server. Builds telemetry
// snapshots from published state (called from AppModel.pollEngine), runs the alert
// evaluator, and routes inbound commands back onto the main actor. UI observes this
// for server status. The server itself only ever sees the non-isolated service core.
@MainActor
final class MonitorBridge: ObservableObject {
    @Published private(set) var listeningStatus = "stopped"
    @Published private(set) var connectedClientCount = 0
    @Published private(set) var pairedClientCount = 0

    let pairingStore = PairingStore()

    private weak var appModel: AppModel?
    private let core: MonitorServiceCore
    private var server: MonitorServer?
    private var evaluator = AlertEvaluator()
    private let port: UInt16
    private let advertiseBonjour: Bool
    // Resolved once at init — Host.current() lookups can block, so never call them on
    // the poll/render path.
    private let venueName: String
    private let host: String

    init(appModel: AppModel, port: UInt16 = 8420, advertiseBonjour: Bool = true) {
        self.appModel = appModel
        self.port = port
        self.advertiseBonjour = advertiseBonjour
        self.venueName = Self.machineName()
        self.host = Self.machineHost()
        self.core = MonitorServiceCore(
            pairingStore: pairingStore,
            healthName: venueName
        )
        core.setCommandHandler { [weak self] command, completion in
            Task { @MainActor in
                guard let self, let model = self.appModel else {
                    completion(CommandResult(ok: false, message: "control unavailable"))
                    return
                }
                completion(RemoteCommandRouter.apply(command, to: model))
            }
        }
    }

    var pairingCode: String { pairingStore.code }

    var urlString: String {
        let port = server?.actualPort ?? self.port
        return "http://\(host):\(port)"
    }

    func start() {
        guard server == nil else { return }
        let server = MonitorServer(service: core, port: port, advertiseBonjour: advertiseBonjour)
        server.onStateChange = { [weak self] status in
            Task { @MainActor in self?.listeningStatus = status }
        }
        do {
            try server.start()
            self.server = server
            listeningStatus = "starting"
        } catch {
            listeningStatus = "failed: \(error.localizedDescription)"
        }
    }

    func stop() {
        server?.stop()
        server = nil
        listeningStatus = "stopped"
        connectedClientCount = 0
    }

    func revokeAllPairings() {
        pairingStore.revokeAll()
        pairedClientCount = 0
    }

    // Called each poll tick from AppModel on the main actor. Builds + publishes the
    // snapshot read by all SSE clients.
    func captureAndPublish(nowMs: Int64) {
        guard let model = appModel else { return }

        // Skip the snapshot build + JSON encode + alert pass entirely when nothing is
        // watching and nothing is running — keeps an idle app at zero cost.
        let clients = server?.connectedClientCount ?? 0
        guard model.isRunning || clients > 0 else {
            if connectedClientCount != 0 { connectedClientCount = 0 }
            return
        }

        let levels = model.levelsDb
        let stream = StreamTelemetry(
            l: model.streamOutputLevelsDb.first ?? -100,
            r: model.streamOutputLevelsDb.indices.contains(1) ? model.streamOutputLevelsDb[1] : -100,
            momentaryLufs: model.momentaryLufs,
            shortLufs: model.shortTermLufs,
            integratedLufs: model.integratedLufs,
            limiterGrDb: model.limiterGainReductionDb
        )
        let counters = CounterTelemetry(
            dropouts: model.dropoutCount,
            callbackOverruns: model.callbackOverrunCount,
            deadlineMisses: model.renderDeadlineMissCount,
            outputUnderruns: model.outputUnderrunCount,
            outputOverruns: model.outputOverrunCount,
            lastCallbackFrames: model.lastCallbackFrames,
            maxCallbackFrames: model.maxObservedCallbackFrames
        )
        let alertChannels = model.channelMappings.map {
            AlertInput.Channel(idx: $0.index, role: $0.role.rawValue,
                               levelDb: levels.indices.contains($0.index) ? levels[$0.index] : -100)
        }
        let alertInput = AlertInput(
            isRunning: model.isRunning,
            operatorStopped: model.operatorStoppedEngine,
            streamL: stream.l,
            streamR: stream.r,
            watchdogSafe: model.watchdogSafeActive,
            integratedLufs: model.integratedLufs,
            counters: counters,
            routeHealthy: model.remoteRouteHealthy,
            channels: alertChannels
        )
        let (alerts, severity) = evaluator.step(alertInput, nowMs: nowMs)

        let snapshot = TelemetryAssembler.assemble(
            ts: nowMs,
            venueName: venueName,
            isRunning: model.isRunning,
            safe: model.safeBypass,
            freeze: model.frozen,
            watchdogSafe: model.watchdogSafeActive,
            scene: model.selectedScene.rawValue,
            scenes: MixScene.allCases.map(\.rawValue),
            sampleRate: Int(model.detectedSampleRate.rounded()),
            inputChannelCount: model.detectedInputChannels,
            bpm: model.bpm,
            bpmConfidence: model.bpmConfidence,
            stream: stream,
            counters: counters,
            channels: TelemetryAssembler.channelTelemetry(model.channelMappings, levelsDb: levels),
            alerts: alerts,
            severity: severity
        )

        if let data = try? JSONEncoder().encode(snapshot) {
            core.publish(data)
        }
        // Only publish when changed — reassigning @Published every tick forces the whole
        // UI to re-render 10x/sec for nothing.
        if clients != connectedClientCount { connectedClientCount = clients }
        let paired = pairingStore.pairedClientCount
        if paired != pairedClientCount { pairedClientCount = paired }
    }

    static func machineName() -> String {
        Host.current().localizedName ?? "AutoMix Native"
    }

    static func machineHost() -> String {
        if let name = Host.current().names.first(where: { $0.hasSuffix(".local") }) {
            return name
        }
        let host = ProcessInfo.processInfo.hostName
        return host.isEmpty ? "automix.local" : host
    }
}
