import Foundation

// Wire contract shared between the embedded server and the PWA dashboard.
// These types ARE the JSON the phone receives (TelemetrySnapshot) and sends
// (RemoteCommand). Keys here must stay in sync with RemoteWeb/app.js.

enum AlertSeverity: String, Codable, Comparable, CaseIterable, Sendable {
    case none
    case info
    case warning
    case critical

    private var rank: Int {
        switch self {
        case .none: return 0
        case .info: return 1
        case .warning: return 2
        case .critical: return 3
        }
    }

    static func < (lhs: AlertSeverity, rhs: AlertSeverity) -> Bool {
        lhs.rank < rhs.rank
    }
}

struct Alert: Codable, Equatable {
    let id: String
    let severity: AlertSeverity
    let title: String
    let detail: String
    let actions: [String]

    init(id: String, severity: AlertSeverity, title: String, detail: String, actions: [String] = []) {
        self.id = id
        self.severity = severity
        self.title = title
        self.detail = detail
        self.actions = actions
    }
}

struct StreamTelemetry: Codable, Equatable {
    let l: Double
    let r: Double
    let momentaryLufs: Double
    let shortLufs: Double
    let integratedLufs: Double
    let limiterGrDb: Double
}

struct CounterTelemetry: Codable, Equatable {
    let dropouts: UInt
    let callbackOverruns: UInt
    let deadlineMisses: UInt
    let outputUnderruns: UInt
    let outputOverruns: UInt
    let lastCallbackFrames: Int
    let maxCallbackFrames: Int
}

struct PipelineTelemetry: Codable, Equatable {
    let encoderState: StreamHealthState
    let encoderDetail: String
    let egressState: StreamHealthState
    let egressDetail: String

    static let disabled = PipelineTelemetry(
        encoderState: .disabled,
        encoderDetail: "not configured",
        egressState: .disabled,
        egressDetail: "not configured"
    )
}

struct ChannelTelemetry: Codable, Equatable {
    let idx: Int
    let name: String
    let role: String
    let levelDb: Double
    let muted: Bool
    let faderOverride: Bool
    let faderDb: Double
    let panOverride: Bool
    let pan: Double
}

struct TelemetrySnapshot: Codable, Equatable {
    let ts: Int64
    let venueName: String
    let isRunning: Bool
    let safe: Bool
    let freeze: Bool
    let watchdogSafe: Bool
    let scene: String
    let scenes: [String]
    let sampleRate: Int
    let inputChannelCount: Int
    let bpm: Double
    let bpmConfidence: Double
    let stream: StreamTelemetry
    let counters: CounterTelemetry
    let pipeline: PipelineTelemetry
    let channels: [ChannelTelemetry]
    let alerts: [Alert]
    let fault: Bool
    let severity: AlertSeverity
}

struct CommandResult: Codable, Equatable {
    let ok: Bool
    let message: String?

    init(ok: Bool, message: String? = nil) {
        self.ok = ok
        self.message = message
    }
}

// Type-tagged command envelope: {"type": "...", ...payload}.
enum RemoteCommand: Equatable {
    case setSafe(on: Bool)
    case setFreeze(on: Bool)
    case setScene(scene: String)
    case setMute(idx: Int, on: Bool)
    case setFaderOverride(idx: Int, on: Bool, db: Double)
    case setPanOverride(idx: Int, on: Bool, pan: Double)
    case clearOverride(idx: Int)
}

extension RemoteCommand: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, on, scene, idx, db, pan
    }

    var type: String {
        switch self {
        case .setSafe: return "setSafe"
        case .setFreeze: return "setFreeze"
        case .setScene: return "setScene"
        case .setMute: return "setMute"
        case .setFaderOverride: return "setFaderOverride"
        case .setPanOverride: return "setPanOverride"
        case .clearOverride: return "clearOverride"
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "setSafe":
            self = .setSafe(on: try c.decode(Bool.self, forKey: .on))
        case "setFreeze":
            self = .setFreeze(on: try c.decode(Bool.self, forKey: .on))
        case "setScene":
            self = .setScene(scene: try c.decode(String.self, forKey: .scene))
        case "setMute":
            self = .setMute(idx: try c.decode(Int.self, forKey: .idx),
                            on: try c.decode(Bool.self, forKey: .on))
        case "setFaderOverride":
            self = .setFaderOverride(idx: try c.decode(Int.self, forKey: .idx),
                                     on: try c.decode(Bool.self, forKey: .on),
                                     db: try c.decode(Double.self, forKey: .db))
        case "setPanOverride":
            self = .setPanOverride(idx: try c.decode(Int.self, forKey: .idx),
                                   on: try c.decode(Bool.self, forKey: .on),
                                   pan: try c.decode(Double.self, forKey: .pan))
        case "clearOverride":
            self = .clearOverride(idx: try c.decode(Int.self, forKey: .idx))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c,
                debugDescription: "unknown command type \(type)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        switch self {
        case .setSafe(let on), .setFreeze(let on):
            try c.encode(on, forKey: .on)
        case .setScene(let scene):
            try c.encode(scene, forKey: .scene)
        case .setMute(let idx, let on):
            try c.encode(idx, forKey: .idx)
            try c.encode(on, forKey: .on)
        case .setFaderOverride(let idx, let on, let db):
            try c.encode(idx, forKey: .idx)
            try c.encode(on, forKey: .on)
            try c.encode(db, forKey: .db)
        case .setPanOverride(let idx, let on, let pan):
            try c.encode(idx, forKey: .idx)
            try c.encode(on, forKey: .on)
            try c.encode(pan, forKey: .pan)
        case .clearOverride(let idx):
            try c.encode(idx, forKey: .idx)
        }
    }
}
