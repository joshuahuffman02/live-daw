import Foundation

struct ShadowDecisionRecord: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1
    static let kind = "shadow-candidate-snapshot"

    var formatVersion: Int
    var kind: String
    var timestampMs: Int64
    var sessionID: String
    var scene: MixScene
    var shadowMode: Bool
    var programAutomationApplied: Bool
    var safeBypass: Bool
    var frozen: Bool
    var inputName: String
    var inputUID: String
    var outputName: String
    var outputUID: String
    var sampleRate: Double
    var channelCount: Int
    var inputLevelsDb: [Double]
    var candidateAutoTrimDb: [Double]
    var candidateAutoFaderDb: [Double]
    var learnedNoiseFloorDb: [Double]
    var channelActive: [Bool]
    var candidateMasterTrimDb: Double
    var programOutputLevelsDb: [Double]

    init(
        timestampMs: Int64,
        sessionID: String,
        scene: MixScene,
        shadowMode: Bool,
        programAutomationApplied: Bool,
        safeBypass: Bool,
        frozen: Bool,
        inputName: String,
        inputUID: String,
        outputName: String,
        outputUID: String,
        sampleRate: Double,
        channelCount: Int,
        inputLevelsDb: [Double],
        candidateAutoTrimDb: [Double],
        candidateAutoFaderDb: [Double],
        learnedNoiseFloorDb: [Double],
        channelActive: [Bool],
        candidateMasterTrimDb: Double,
        programOutputLevelsDb: [Double]
    ) {
        formatVersion = Self.currentFormatVersion
        kind = Self.kind
        self.timestampMs = timestampMs
        self.sessionID = sessionID
        self.scene = scene
        self.shadowMode = shadowMode
        self.programAutomationApplied = programAutomationApplied
        self.safeBypass = safeBypass
        self.frozen = frozen
        self.inputName = inputName
        self.inputUID = inputUID
        self.outputName = outputName
        self.outputUID = outputUID
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.inputLevelsDb = inputLevelsDb
        self.candidateAutoTrimDb = candidateAutoTrimDb
        self.candidateAutoFaderDb = candidateAutoFaderDb
        self.learnedNoiseFloorDb = learnedNoiseFloorDb
        self.channelActive = channelActive
        self.candidateMasterTrimDb = candidateMasterTrimDb
        self.programOutputLevelsDb = programOutputLevelsDb
    }
}

actor ShadowDecisionJournal {
    nonisolated let fileURL: URL

    init(directory: URL, fileName: String) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        fileURL = directory.appendingPathComponent(fileName)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try Data().write(to: fileURL, options: .atomic)
        }
    }

    @discardableResult
    func append(_ record: ShadowDecisionRecord) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(record)
        data.append(0x0A)

        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
        return fileURL
    }
}
