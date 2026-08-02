import AVFoundation
import Foundation

enum RecordingSessionStatus: String, Codable, CaseIterable, Sendable {
    case recording
    case ready
    case interrupted
    case needsAttention

    var label: String {
        switch self {
        case .recording: return "Recording"
        case .ready: return "Ready"
        case .interrupted: return "Interrupted"
        case .needsAttention: return "Needs attention"
        }
    }
}

enum RecordingSessionOrigin: String, Codable, Sendable {
    case liveCapture
    case importedFiles
}

enum RecordingSessionAssetKind: String, Codable, Sendable {
    case captureSegment
    case importedAudio
    case programPreview
    case replayOutput
    case metrics
    case decisions
}

struct RecordingSessionAsset: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var relativePath: String
    var kind: RecordingSessionAssetKind
    var byteCount: Int64
    var durationSeconds: Double?
    var sampleRate: Double?
    var channelCount: Int?
    var validationError: String?

    var displayName: String {
        URL(fileURLWithPath: relativePath).lastPathComponent
    }

    var isPlayable: Bool {
        validationError == nil && (kind == .importedAudio || kind == .programPreview || kind == .replayOutput)
    }
}

struct RecordingSession: Identifiable, Codable, Equatable, Sendable {
    static let schemaVersion = 1
    static let manifestName = ".automix-session.json"

    var schemaVersion: Int
    var id: UUID
    var name: String
    var notes: String
    var createdAt: Date
    var updatedAt: Date
    var startedAt: Date?
    var endedAt: Date?
    var status: RecordingSessionStatus
    var origin: RecordingSessionOrigin
    var directoryPath: String
    var continuedFromSessionID: UUID?
    var scene: String?
    var channelRoles: [String]?
    var stereoPairs: [String]?
    var capturedFrames: UInt64
    var droppedFrames: UInt64
    var assets: [RecordingSessionAsset]
    var lastError: String?

    var directoryURL: URL {
        URL(fileURLWithPath: directoryPath, isDirectory: true)
    }

    var totalByteCount: Int64 {
        assets.reduce(0) { partial, asset in
            let (sum, overflow) = partial.addingReportingOverflow(max(asset.byteCount, 0))
            return overflow ? Int64.max : sum
        }
    }

    var durationSeconds: Double {
        assets
            .filter { $0.kind == .captureSegment || $0.kind == .importedAudio }
            .compactMap(\.durationSeconds)
            .reduce(0, +)
    }

    var hasUsableAudio: Bool {
        assets.contains { asset in
            asset.validationError == nil &&
                (asset.kind == .captureSegment || asset.kind == .importedAudio || asset.kind == .programPreview)
        }
    }
}

enum RecordingSessionLibraryError: LocalizedError, Equatable {
    case noSupportedFiles
    case fileMissing(String)
    case unsupportedFile(String)
    case emptyFile(String)
    case insufficientCapacity
    case sessionNotFound
    case activeSessionLocked
    case noPreviewableAudio
    case incompatibleSegments
    case unreadableAudio(String)

    var errorDescription: String? {
        switch self {
        case .noSupportedFiles:
            return "Choose at least one supported audio file."
        case let .fileMissing(name):
            return "The recording file is missing: \(name)."
        case let .unsupportedFile(name):
            return "This audio format is not supported: \(name)."
        case let .emptyFile(name):
            return "The recording file is empty: \(name)."
        case .insufficientCapacity:
            return "There is not enough free space to import these recordings safely."
        case .sessionNotFound:
            return "That recording session is no longer available."
        case .activeSessionLocked:
            return "Stop the active recording before changing or removing its session."
        case .noPreviewableAudio:
            return "This session does not contain audio that can be previewed."
        case .incompatibleSegments:
            return "The session segments do not share one sample rate and channel layout."
        case let .unreadableAudio(name):
            return "The audio file could not be read: \(name)."
        }
    }
}

actor RecordingSessionLibrary {
    static let supportedAudioExtensions: Set<String> = [
        "wav", "wave", "aif", "aiff", "caf", "m4a", "mp3", "flac"
    ]
    private static let derivedDirectoryName = "Derived"

    func load(root: URL, activeDirectory: URL?) throws -> [RecordingSession] {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isHiddenKey, .isSymbolicLinkKey, .creationDateKey
        ]
        let directories = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants]
        )
        .filter { url in
            let values = try? url.resourceValues(forKeys: keys)
            return values?.isDirectory == true &&
                values?.isHidden != true &&
                values?.isSymbolicLink != true
        }

        return try directories.map { directory in
            try loadSession(directory: directory, activeDirectory: activeDirectory)
        }
        .sorted { lhs, rhs in
            if lhs.status == .recording && rhs.status != .recording { return true }
            if rhs.status == .recording && lhs.status != .recording { return false }
            return lhs.createdAt > rhs.createdAt
        }
    }

    nonisolated static func bootstrapCaptureSession(
        directory: URL,
        name: String,
        notes: String,
        scene: String,
        channelRoles: [String],
        stereoPairs: [String],
        continuedFromSessionID: UUID? = nil,
        now: Date = Date()
    ) throws -> RecordingSession {
        let cleanedName = sanitizedName(name, fallback: "Live capture")
        let session = RecordingSession(
            schemaVersion: RecordingSession.schemaVersion,
            id: UUID(),
            name: cleanedName,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: now,
            updatedAt: now,
            startedAt: now,
            endedAt: nil,
            status: .recording,
            origin: .liveCapture,
            directoryPath: directory.path,
            continuedFromSessionID: continuedFromSessionID,
            scene: scene,
            channelRoles: channelRoles,
            stereoPairs: stereoPairs,
            capturedFrames: 0,
            droppedFrames: 0,
            assets: [],
            lastError: nil
        )
        try writeManifest(session)
        return session
    }

    func importFiles(
        _ sourceURLs: [URL],
        root: URL,
        name: String?,
        notes: String = "",
        minimumRemainingBytes: Int64 = 1_000_000_000,
        now: Date = Date()
    ) throws -> RecordingSession {
        let sources = try validatedSources(sourceURLs)
        let requiredBytes = sources.reduce(Int64(0)) { partial, item in
            let (sum, overflow) = partial.addingReportingOverflow(item.size)
            return overflow ? Int64.max : sum
        }
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: root.path)
        if let available = (attributes[.systemFreeSize] as? NSNumber)?.int64Value,
           available < requiredBytes + max(minimumRemainingBytes, 0) {
            throw RecordingSessionLibraryError.insufficientCapacity
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let directory = root.appendingPathComponent(
            "automix-import-\(formatter.string(from: now))-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)

        do {
            var assets: [RecordingSessionAsset] = []
            for (index, source) in sources.enumerated() {
                try Task.checkCancellation()
                let destination = uniqueDestination(
                    in: directory,
                    preferredName: String(format: "%03d-%@", index + 1, source.url.lastPathComponent)
                )
                try FileManager.default.copyItem(at: source.url, to: destination)
                assets.append(inspectAudioAsset(
                    url: destination,
                    relativeTo: directory,
                    kind: .importedAudio
                ))
            }
            let fallbackName = sources.count == 1
                ? sources[0].url.deletingPathExtension().lastPathComponent
                : "Imported recordings"
            let session = RecordingSession(
                schemaVersion: RecordingSession.schemaVersion,
                id: UUID(),
                name: Self.sanitizedName(name ?? "", fallback: fallbackName),
                notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
                createdAt: now,
                updatedAt: now,
                startedAt: nil,
                endedAt: now,
                status: assets.contains(where: { $0.validationError != nil }) ? .needsAttention : .ready,
                origin: .importedFiles,
                directoryPath: directory.path,
                continuedFromSessionID: nil,
                scene: nil,
                channelRoles: nil,
                stereoPairs: nil,
                capturedFrames: 0,
                droppedFrames: 0,
                assets: assets,
                lastError: assets.compactMap(\.validationError).first
            )
            try Self.writeManifest(session)
            return session
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func update(
        sessionID: UUID,
        root: URL,
        activeDirectory: URL?,
        name: String,
        notes: String
    ) throws -> RecordingSession {
        guard var session = try load(root: root, activeDirectory: activeDirectory)
            .first(where: { $0.id == sessionID })
        else { throw RecordingSessionLibraryError.sessionNotFound }
        if session.status == .recording {
            throw RecordingSessionLibraryError.activeSessionLocked
        }
        session.name = Self.sanitizedName(name, fallback: session.name)
        session.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        session.updatedAt = Date()
        try Self.writeManifest(session)
        return session
    }

    func moveToTrash(
        sessionID: UUID,
        root: URL,
        activeDirectory: URL?
    ) throws {
        guard let session = try load(root: root, activeDirectory: activeDirectory)
            .first(where: { $0.id == sessionID })
        else { throw RecordingSessionLibraryError.sessionNotFound }
        if session.status == .recording || session.directoryURL.standardizedFileURL == activeDirectory?.standardizedFileURL {
            throw RecordingSessionLibraryError.activeSessionLocked
        }
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: session.directoryURL, resultingItemURL: &resultingURL)
    }

    func renderProgramPreview(session: RecordingSession) throws -> URL {
        if let existing = session.assets.first(where: { $0.kind == .programPreview && $0.validationError == nil }) {
            let url = session.directoryURL.appendingPathComponent(existing.relativePath)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        if let imported = session.assets.first(where: { $0.kind == .importedAudio && $0.validationError == nil }) {
            return session.directoryURL.appendingPathComponent(imported.relativePath)
        }

        let segments = session.assets
            .filter { $0.kind == .captureSegment && $0.validationError == nil }
            .sorted { $0.relativePath < $1.relativePath }
        guard !segments.isEmpty else { throw RecordingSessionLibraryError.noPreviewableAudio }

        let derived = session.directoryURL.appendingPathComponent(Self.derivedDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: derived, withIntermediateDirectories: true)
        let destination = derived.appendingPathComponent("Program Preview.caf")
        let temporary = derived.appendingPathComponent(".Program Preview-\(UUID().uuidString).caf")
        try? FileManager.default.removeItem(at: temporary)

        var outputFile: AVAudioFile?
        var expectedRate: Double?
        var expectedChannels: AVAudioChannelCount?
        do {
            for segment in segments {
                try Task.checkCancellation()
                let sourceURL = session.directoryURL.appendingPathComponent(segment.relativePath)
                let input = try AVAudioFile(forReading: sourceURL)
                let format = input.processingFormat
                guard format.channelCount >= 2 else {
                    throw RecordingSessionLibraryError.incompatibleSegments
                }
                if let expectedRate,
                   abs(expectedRate - format.sampleRate) > 0.5 || expectedChannels != format.channelCount {
                    throw RecordingSessionLibraryError.incompatibleSegments
                }
                expectedRate = format.sampleRate
                expectedChannels = format.channelCount
                let stereoFormat = AVAudioFormat(
                    standardFormatWithSampleRate: format.sampleRate,
                    channels: 2
                )!
                if outputFile == nil {
                    outputFile = try AVAudioFile(forWriting: temporary, settings: stereoFormat.settings)
                }
                let capacity: AVAudioFrameCount = 4_096
                guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity),
                      let outputBuffer = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: capacity),
                      let outputData = outputBuffer.floatChannelData
                else { throw RecordingSessionLibraryError.unreadableAudio(segment.displayName) }
                while input.framePosition < input.length {
                    try Task.checkCancellation()
                    try input.read(into: inputBuffer, frameCount: capacity)
                    let frames = inputBuffer.frameLength
                    guard frames > 0, let inputData = inputBuffer.floatChannelData else { break }
                    outputBuffer.frameLength = frames
                    let left = Int(format.channelCount) - 2
                    let right = left + 1
                    memcpy(outputData[0], inputData[left], Int(frames) * MemoryLayout<Float>.size)
                    memcpy(outputData[1], inputData[right], Int(frames) * MemoryLayout<Float>.size)
                    try outputFile?.write(from: outputBuffer)
                }
            }
            outputFile = nil
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: temporary, to: destination)
            return destination
        } catch {
            outputFile = nil
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private func loadSession(directory: URL, activeDirectory: URL?) throws -> RecordingSession {
        let manifestURL = directory.appendingPathComponent(RecordingSession.manifestName)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var session: RecordingSession
        var manifestAssets: [RecordingSessionAsset] = []
        if let data = try? Data(contentsOf: manifestURL),
           let decoded = try? decoder.decode(RecordingSession.self, from: data),
           decoded.schemaVersion == RecordingSession.schemaVersion {
            session = decoded
            manifestAssets = decoded.assets
        } else {
            let values = try directory.resourceValues(forKeys: [.creationDateKey])
            let createdAt = values.creationDate ?? Date()
            session = RecordingSession(
                schemaVersion: RecordingSession.schemaVersion,
                id: UUID(),
                name: directory.lastPathComponent,
                notes: "",
                createdAt: createdAt,
                updatedAt: createdAt,
                startedAt: createdAt,
                endedAt: nil,
                status: .interrupted,
                origin: .liveCapture,
                directoryPath: directory.path,
                continuedFromSessionID: nil,
                scene: nil,
                channelRoles: nil,
                stereoPairs: nil,
                capturedFrames: 0,
                droppedFrames: 0,
                assets: [],
                lastError: nil
            )
        }

        session.directoryPath = directory.path
        session.assets = inspectAssets(directory: directory, origin: session.origin)
        let discoveredPaths = Set(session.assets.map(\.relativePath))
        let missingExpectedAudio = manifestAssets.filter {
            ($0.kind == .captureSegment || $0.kind == .importedAudio) &&
                !discoveredPaths.contains($0.relativePath)
        }
        let completeMarker = directory.appendingPathComponent(
            ContinuousRecordingStorageManager.completionMarkerName
        )
        let isActive = activeDirectory?.standardizedFileURL == directory.standardizedFileURL
        if isActive {
            session.status = .recording
            session.endedAt = nil
        } else if FileManager.default.fileExists(atPath: completeMarker.path) {
            let completion = readCompletionMarker(at: completeMarker)
            if let completion {
                session.capturedFrames = completion.capturedFrames
                session.droppedFrames = completion.droppedFrames
                session.endedAt = completion.completedAt ?? session.endedAt
            }
            let captureSegments = session.assets.filter { $0.kind == .captureSegment }
            let segmentCountMismatch = completion?.segments.map { $0 != captureSegments.count } ?? false
            let problem: String?
            if completion == nil {
                problem = "The capture completion marker is unreadable. Recorded files were retained."
            } else if captureSegments.isEmpty {
                problem = "The capture completed without a readable audio segment."
            } else if !missingExpectedAudio.isEmpty {
                problem = "A recorded segment is missing: \(missingExpectedAudio[0].displayName)."
            } else if segmentCountMismatch {
                problem = "The completion marker's segment count does not match the recorded files."
            } else if let invalid = captureSegments.first(where: { $0.validationError != nil }) {
                problem = invalid.validationError ?? "A recorded file is unreadable."
            } else if session.droppedFrames > 0 {
                problem = "Capture dropped \(session.droppedFrames) frames and is not a trustworthy replay source."
            } else {
                problem = nil
            }
            session.status = problem == nil ? .ready : .needsAttention
            session.lastError = problem
        } else if session.origin == .importedFiles {
            let importedAssets = session.assets.filter { $0.kind == .importedAudio }
            let problem: String?
            if !missingExpectedAudio.isEmpty {
                problem = "An imported recording is missing: \(missingExpectedAudio[0].displayName)."
            } else if importedAssets.isEmpty {
                problem = "This imported session no longer contains an audio file."
            } else if let invalid = importedAssets.first(where: { $0.validationError != nil }) {
                problem = invalid.validationError ?? "An imported recording is unreadable."
            } else {
                problem = nil
            }
            session.status = problem == nil ? .ready : .needsAttention
            session.lastError = problem
        } else {
            session.status = session.assets.contains(where: { $0.validationError != nil })
                ? .needsAttention
                : .interrupted
            session.lastError = session.lastError ?? "Capture ended without a clean completion marker. Completed segments remain available."
        }
        try Self.writeManifest(session)
        return session
    }

    private func inspectAssets(directory: URL, origin: RecordingSessionOrigin) -> [RecordingSessionAsset] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var assets: [RecordingSessionAsset] = []
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                enumerator.skipDescendants()
                continue
            }
            let relative = url.path.replacingOccurrences(of: directory.path + "/", with: "")
            let ext = url.pathExtension.lowercased()
            if Self.supportedAudioExtensions.contains(ext) {
                let kind: RecordingSessionAssetKind
                if relative.hasPrefix(Self.derivedDirectoryName + "/") && url.lastPathComponent == "Program Preview.caf" {
                    kind = .programPreview
                } else if relative.hasPrefix(Self.derivedDirectoryName + "/") {
                    kind = .replayOutput
                } else {
                    kind = origin == .liveCapture ? .captureSegment : .importedAudio
                }
                assets.append(inspectAudioAsset(url: url, relativeTo: directory, kind: kind))
            } else if ext == "json" && relative.hasPrefix(Self.derivedDirectoryName + "/") {
                assets.append(nonAudioAsset(url: url, relativeTo: directory, kind: .metrics))
            } else if ext == "jsonl" && relative.hasPrefix(Self.derivedDirectoryName + "/") {
                assets.append(nonAudioAsset(url: url, relativeTo: directory, kind: .decisions))
            }
        }
        return assets.sorted { $0.relativePath < $1.relativePath }
    }

    private func inspectAudioAsset(
        url: URL,
        relativeTo directory: URL,
        kind: RecordingSessionAssetKind
    ) -> RecordingSessionAsset {
        let relative = url.path.replacingOccurrences(of: directory.path + "/", with: "")
        let size = ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)) ?? 0
        do {
            let audio = try AVAudioFile(forReading: url)
            let rate = audio.processingFormat.sampleRate
            let duration = rate > 0 ? Double(audio.length) / rate : nil
            return RecordingSessionAsset(
                id: stableAssetID(relativePath: relative),
                relativePath: relative,
                kind: kind,
                byteCount: size,
                durationSeconds: duration,
                sampleRate: rate,
                channelCount: Int(audio.processingFormat.channelCount),
                validationError: audio.length > 0 ? nil : "The audio file has no complete frames."
            )
        } catch {
            return RecordingSessionAsset(
                id: stableAssetID(relativePath: relative),
                relativePath: relative,
                kind: kind,
                byteCount: size,
                durationSeconds: nil,
                sampleRate: nil,
                channelCount: nil,
                validationError: error.localizedDescription
            )
        }
    }

    private func nonAudioAsset(
        url: URL,
        relativeTo directory: URL,
        kind: RecordingSessionAssetKind
    ) -> RecordingSessionAsset {
        let relative = url.path.replacingOccurrences(of: directory.path + "/", with: "")
        let size = ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)) ?? 0
        return RecordingSessionAsset(
            id: stableAssetID(relativePath: relative),
            relativePath: relative,
            kind: kind,
            byteCount: size,
            durationSeconds: nil,
            sampleRate: nil,
            channelCount: nil,
            validationError: nil
        )
    }

    private struct CompletionMarker {
        var completedAt: Date?
        var capturedFrames: UInt64
        var droppedFrames: UInt64
        var segments: Int?
    }

    private func readCompletionMarker(at url: URL) -> CompletionMarker? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let capturedFrames = root["capturedFrames"] as? NSNumber,
              let droppedFrames = root["droppedFrames"] as? NSNumber
        else { return nil }
        let completedAt = (root["completedAtMs"] as? NSNumber).map {
            Date(timeIntervalSince1970: Double($0.int64Value) / 1_000)
        }
        return CompletionMarker(
            completedAt: completedAt,
            capturedFrames: capturedFrames.uint64Value,
            droppedFrames: droppedFrames.uint64Value,
            segments: (root["segments"] as? NSNumber)?.intValue
        )
    }

    private func validatedSources(_ urls: [URL]) throws -> [(url: URL, size: Int64)] {
        guard !urls.isEmpty else { throw RecordingSessionLibraryError.noSupportedFiles }
        return try urls.map { url in
            let normalized = url.standardizedFileURL
            guard FileManager.default.fileExists(atPath: normalized.path) else {
                throw RecordingSessionLibraryError.fileMissing(normalized.lastPathComponent)
            }
            let values = try normalized.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw RecordingSessionLibraryError.unsupportedFile(normalized.lastPathComponent)
            }
            guard Self.supportedAudioExtensions.contains(normalized.pathExtension.lowercased()) else {
                throw RecordingSessionLibraryError.unsupportedFile(normalized.lastPathComponent)
            }
            let size = Int64(values.fileSize ?? 0)
            guard size > 0 else { throw RecordingSessionLibraryError.emptyFile(normalized.lastPathComponent) }
            _ = try AVAudioFile(forReading: normalized)
            return (normalized, size)
        }
    }

    private func uniqueDestination(in directory: URL, preferredName: String) -> URL {
        let safeName = preferredName.replacingOccurrences(of: "/", with: "-")
        var candidate = directory.appendingPathComponent(safeName)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let base = candidate.deletingPathExtension().lastPathComponent
            let ext = candidate.pathExtension
            candidate = directory.appendingPathComponent("\(base)-\(suffix)").appendingPathExtension(ext)
            suffix += 1
        }
        return candidate
    }

    private func stableAssetID(relativePath: String) -> UUID {
        var left: UInt64 = 0xcbf29ce484222325
        var right: UInt64 = 0x9e3779b97f4a7c15
        for byte in relativePath.utf8 {
            left = (left ^ UInt64(byte)) &* 0x100000001b3
            right ^= UInt64(byte) &+ 0x9e3779b97f4a7c15 &+ (right << 6) &+ (right >> 2)
        }
        var bytes = withUnsafeBytes(of: left.bigEndian, Array.init) +
            withUnsafeBytes(of: right.bigEndian, Array.init)
        bytes[6] = (bytes[6] & 0x0f) | 0x40
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    nonisolated private static func sanitizedName(_ value: String, fallback: String) -> String {
        let compact = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[\\r\\n\\t]+", with: " ", options: .regularExpression)
        return String((compact.isEmpty ? fallback : compact).prefix(120))
    }

    nonisolated private static func writeManifest(_ session: RecordingSession) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifest = session.directoryURL.appendingPathComponent(RecordingSession.manifestName)
        try encoder.encode(session).write(to: manifest, options: .atomic)
    }
}
