#!/usr/bin/env swift

import Darwin
import Foundation

struct ShadowDecisionRecord: Decodable {
    var formatVersion: Int
    var kind: String
    var timestampMs: Int64
    var sessionID: String
    var scene: String
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
}

struct Options {
    var logPath = ""
    var expectedPhase = ""
    var windowStartMs: Int64?
    var windowEndMs: Int64?
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("SHADOW decision evidence failed: \(message)\n".utf8))
    Darwin.exit(1)
}

func usage() -> Never {
    FileHandle.standardError.write(
        Data(
            """
            Usage: verify-shadow-decision-evidence.swift \\
              --log PATH --expected-phase sermon|worship \\
              --window-start-ms UNIX_MS --window-end-ms UNIX_MS

            """.utf8
        )
    )
    Darwin.exit(2)
}

func parseOptions() -> Options {
    var options = Options()
    var arguments = Array(CommandLine.arguments.dropFirst())
    while !arguments.isEmpty {
        let flag = arguments.removeFirst()
        guard !arguments.isEmpty else { usage() }
        let value = arguments.removeFirst()
        switch flag {
        case "--log":
            options.logPath = value
        case "--expected-phase":
            options.expectedPhase = value
        case "--window-start-ms":
            options.windowStartMs = Int64(value)
        case "--window-end-ms":
            options.windowEndMs = Int64(value)
        default:
            usage()
        }
    }
    guard !options.logPath.isEmpty,
          options.expectedPhase == "sermon" || options.expectedPhase == "worship",
          let start = options.windowStartMs,
          let end = options.windowEndMs,
          start >= 0,
          end > start
    else { usage() }
    return options
}

func isSafeIdentifier(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 128 else { return false }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
    return value.unicodeScalars.allSatisfy { allowed.contains($0) }
}

func allFiniteAndBounded(
    _ values: [Double],
    lower: Double,
    upper: Double
) -> Bool {
    values.allSatisfy { $0.isFinite && $0 >= lower && $0 <= upper }
}

let options = parseOptions()
let logURL = URL(fileURLWithPath: options.logPath)
guard let data = FileManager.default.contents(atPath: logURL.path), !data.isEmpty else {
    fail("log is missing or empty: \(logURL.path)")
}
guard let text = String(data: data, encoding: .utf8) else {
    fail("log is not UTF-8")
}

let rawLines = text.split(
    separator: "\n",
    omittingEmptySubsequences: false
)
var lines = rawLines
if lines.last?.isEmpty == true {
    lines.removeLast()
}
guard !lines.isEmpty, !lines.contains(where: \.isEmpty) else {
    fail("log contains no records or has an empty interior line")
}

let decoder = JSONDecoder()
var records: [ShadowDecisionRecord] = []
records.reserveCapacity(lines.count)
for (offset, line) in lines.enumerated() {
    do {
        records.append(
            try decoder.decode(
                ShadowDecisionRecord.self,
                from: Data(line.utf8)
            )
        )
    } catch {
        fail("line \(offset + 1) is not a valid SHADOW decision record: \(error)")
    }
}

let startMs = options.windowStartMs!
let endMs = options.windowEndMs!
let edgeToleranceMs: Int64 = 15_000
let maximumGapMs: Int64 = 5_000
let validScenes = Set(["preService", "worship", "sermon", "prayer", "postService"])
let first = records[0]
guard isSafeIdentifier(first.sessionID) else {
    fail("sessionID is empty or malformed")
}
let inputRoute = "\(first.inputName) \(first.inputUID)".lowercased()
let outputRoute = "\(first.outputName) \(first.outputUID)".lowercased()
let productionInputKeywords = ["dante", "hd96", "heritage", "midas"]
let streamKeywords = [
    "stream", "encoder", "broadcast", "blackhole", "loopback", "obs", "virtual",
    "aggregate", "restream", "audio hijack", "capture", "cam link", "atem",
    "web presenter", "decklink", "ultrastudio", "usb audio codec", "zoom",
    "teams", "ndi"
]
let consoleKeywords = ["dante", "hd96", "heritage", "midas", "console", "foh"]
let inputLooksProductionFacing = productionInputKeywords.contains { inputRoute.contains($0) }
let outputLooksStreamFacing = streamKeywords.contains { outputRoute.contains($0) }
let outputLooksConsoleFacing = consoleKeywords.contains { outputRoute.contains($0) }
guard !first.inputName.isEmpty,
      !first.outputName.isEmpty,
      !first.inputUID.isEmpty,
      !first.outputUID.isEmpty,
      !inputRoute.contains("simulat"),
      !outputRoute.contains("simulat"),
      inputLooksProductionFacing,
      outputLooksStreamFacing,
      !outputLooksConsoleFacing
else {
    fail("the log is not bound to an identified non-simulated HD96/Dante input and isolated stream-facing output")
}

var previousTimestamp: Int64?
var maximumObservedGapMs: Int64 = 0
var expectedPhaseSeen = false
var signalSeen = false
var programSignalSeen = false
var candidateMoveSeen = false
var usableSnapshotCount = 0
var previousCandidateRecord: ShadowDecisionRecord?

for (offset, record) in records.enumerated() {
    let lineNumber = offset + 1
    guard record.formatVersion == 1,
          record.kind == "shadow-candidate-snapshot",
          record.sessionID == first.sessionID,
          validScenes.contains(record.scene),
          record.shadowMode,
          !record.programAutomationApplied,
          record.inputName == first.inputName,
          record.inputUID == first.inputUID,
          record.outputName == first.outputName,
          record.outputUID == first.outputUID,
          abs(record.sampleRate - 96_000) <= 0.5,
          record.channelCount == 64,
          record.inputLevelsDb.count == 64,
          record.candidateAutoTrimDb.count == 64,
          record.candidateAutoFaderDb.count == 64,
          record.learnedNoiseFloorDb.count == 64,
          record.channelActive.count == 64,
          record.programOutputLevelsDb.count == 2,
          allFiniteAndBounded(record.inputLevelsDb, lower: -160, upper: 24),
          allFiniteAndBounded(record.candidateAutoTrimDb, lower: -30, upper: 30),
          allFiniteAndBounded(record.candidateAutoFaderDb, lower: -100, upper: 24),
          allFiniteAndBounded(record.learnedNoiseFloorDb, lower: -160, upper: 0),
          record.candidateMasterTrimDb.isFinite,
          record.candidateMasterTrimDb >= -30,
          record.candidateMasterTrimDb <= 30,
          allFiniteAndBounded(record.programOutputLevelsDb, lower: -160, upper: 24),
          record.timestampMs >= startMs - edgeToleranceMs,
          record.timestampMs <= endMs + edgeToleranceMs
    else {
        fail("line \(lineNumber) violates the native 64-channel/96 kHz SHADOW record contract")
    }

    if let previousTimestamp {
        let gap = record.timestampMs - previousTimestamp
        guard gap > 0, gap <= maximumGapMs else {
            fail("line \(lineNumber) is out of order or leaves a gap larger than \(maximumGapMs) ms")
        }
        maximumObservedGapMs = max(maximumObservedGapMs, gap)
    }
    previousTimestamp = record.timestampMs

    expectedPhaseSeen = expectedPhaseSeen || record.scene == options.expectedPhase
    signalSeen = signalSeen ||
        record.channelActive.contains(true) ||
        record.inputLevelsDb.contains(where: { $0 > -80 })
    programSignalSeen = programSignalSeen ||
        record.programOutputLevelsDb.contains(where: { $0 > -80 })
    if let previousCandidateRecord {
        candidateMoveSeen = candidateMoveSeen ||
            zip(record.candidateAutoTrimDb, previousCandidateRecord.candidateAutoTrimDb)
                .contains(where: { abs($0.0 - $0.1) >= 0.05 }) ||
            zip(record.candidateAutoFaderDb, previousCandidateRecord.candidateAutoFaderDb)
                .contains(where: { abs($0.0 - $0.1) >= 0.05 }) ||
            zip(record.channelActive, previousCandidateRecord.channelActive)
                .contains(where: { $0.0 != $0.1 }) ||
            abs(record.candidateMasterTrimDb - previousCandidateRecord.candidateMasterTrimDb) >= 0.05
    }
    previousCandidateRecord = record
    if !record.safeBypass && !record.frozen {
        usableSnapshotCount += 1
    }
}

guard records.count >= 2 else {
    fail("at least two native snapshots are required")
}
guard first.timestampMs <= startMs + edgeToleranceMs,
      records.last!.timestampMs >= endMs - edgeToleranceMs
else {
    fail("the native log does not cover both edges of the reported rehearsal window")
}
let requestedDurationMs = endMs - startMs
let coveredDurationMs = records.last!.timestampMs - first.timestampMs
guard Double(coveredDurationMs) / Double(requestedDurationMs) >= 0.95 else {
    fail("native snapshot coverage is below 95% of the reported rehearsal window")
}
guard expectedPhaseSeen else {
    fail("the expected \(options.expectedPhase) scene never appears in the SHADOW log")
}
guard signalSeen else {
    fail("the SHADOW log contains no active input evidence")
}
guard programSignalSeen else {
    fail("the SHADOW log contains no observable program-output signal")
}
guard candidateMoveSeen else {
    fail("the SHADOW log contains no measurable candidate-state change")
}
guard usableSnapshotCount * 10 >= records.count * 9 else {
    fail("SAFE or FREEZE blocks more than 10% of the candidate comparison window")
}

print(
    "SHADOW decision evidence verified: " +
    "session=\(first.sessionID) snapshots=\(records.count) " +
    "coverageMs=\(coveredDurationMs)/\(requestedDurationMs) " +
    "maxGapMs=\(maximumObservedGapMs) route=\(first.inputUID)->\(first.outputUID)"
)
