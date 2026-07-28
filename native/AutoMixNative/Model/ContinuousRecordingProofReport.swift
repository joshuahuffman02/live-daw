import Foundation

struct ContinuousRecordingSegmentProof: Codable, Equatable, Sendable {
    var path: String
    var byteCount: Int64
    var metadata: WavMetadata
}

struct ContinuousRecordingProofCheck: Codable, Equatable, Identifiable, Sendable {
    var id: String { name }
    var name: String
    var expected: String
    var observed: String
    var passed: Bool
}

struct ContinuousRecordingProofReport: Codable, Equatable, Sendable {
    static let productionDurationSeconds = 7_200.0

    var generatedAt: Date
    var validationSource: AudioValidationSource
    var inputDevice: SoundcheckDeviceSnapshot
    var outputDevice: SoundcheckDeviceSnapshot
    var scene: MixScene
    var expectedInputChannels: Int
    var detectedInputChannels: Int
    var sampleRate: Double
    var requestedDurationSeconds: Double
    var observedDurationSeconds: Double
    var recordingDirectoryPath: String
    var availableBytesAtStart: Int64
    var minimumObservedAvailableBytes: Int64
    var requiredBytesAtStart: Int64
    var minimumReserveBytes: Int64
    var capturedFrameCount: UInt64
    var droppedFrameCount: UInt64
    var reportedSegmentCount: Int
    var stoppedUnexpectedly: Bool
    var writerStatus: String
    var segments: [ContinuousRecordingSegmentProof]
    var checks: [ContinuousRecordingProofCheck]
    var passed: Bool
    var productionProofPassed: Bool

    static func make(
        generatedAt: Date = Date(),
        validationSource: AudioValidationSource,
        inputDevice: SoundcheckDeviceSnapshot,
        outputDevice: SoundcheckDeviceSnapshot,
        scene: MixScene,
        expectedInputChannels: Int,
        detectedInputChannels: Int,
        sampleRate: Double,
        requestedDurationSeconds: Double,
        observedDurationSeconds: Double,
        recordingDirectoryURL: URL,
        availableBytesAtStart: Int64,
        minimumObservedAvailableBytes: Int64,
        requiredBytesAtStart: Int64,
        minimumReserveBytes: Int64,
        capturedFrameCount: UInt64,
        droppedFrameCount: UInt64,
        reportedSegmentCount: Int,
        stoppedUnexpectedly: Bool,
        writerStatus: String,
        fileManager: FileManager = .default
    ) throws -> ContinuousRecordingProofReport {
        let segments = try segmentProofs(in: recordingDirectoryURL, fileManager: fileManager)
        return evaluate(
            generatedAt: generatedAt,
            validationSource: validationSource,
            inputDevice: inputDevice,
            outputDevice: outputDevice,
            scene: scene,
            expectedInputChannels: expectedInputChannels,
            detectedInputChannels: detectedInputChannels,
            sampleRate: sampleRate,
            requestedDurationSeconds: requestedDurationSeconds,
            observedDurationSeconds: observedDurationSeconds,
            recordingDirectoryPath: ".",
            availableBytesAtStart: availableBytesAtStart,
            minimumObservedAvailableBytes: minimumObservedAvailableBytes,
            requiredBytesAtStart: requiredBytesAtStart,
            minimumReserveBytes: minimumReserveBytes,
            capturedFrameCount: capturedFrameCount,
            droppedFrameCount: droppedFrameCount,
            reportedSegmentCount: reportedSegmentCount,
            stoppedUnexpectedly: stoppedUnexpectedly,
            writerStatus: writerStatus,
            segments: segments
        )
    }

    static func verify(
        reportAt reportURL: URL,
        fileManager: FileManager = .default
    ) throws -> ContinuousRecordingProofReport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: value)
            }
            let value = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: value) {
                return date
            }
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected ISO-8601 or epoch timestamp date."
            )
        }
        let encoded = try decoder.decode(
            ContinuousRecordingProofReport.self,
            from: Data(contentsOf: reportURL)
        )
        let reportDirectory = reportURL.deletingLastPathComponent()
        let recordingDirectoryURL = resolvedURL(
            path: encoded.recordingDirectoryPath,
            relativeTo: reportDirectory
        )
        let actualSegments = try segmentProofs(in: recordingDirectoryURL, fileManager: fileManager)
        return evaluate(
            generatedAt: encoded.generatedAt,
            validationSource: encoded.validationSource,
            inputDevice: encoded.inputDevice,
            outputDevice: encoded.outputDevice,
            scene: encoded.scene,
            expectedInputChannels: encoded.expectedInputChannels,
            detectedInputChannels: encoded.detectedInputChannels,
            sampleRate: encoded.sampleRate,
            requestedDurationSeconds: encoded.requestedDurationSeconds,
            observedDurationSeconds: encoded.observedDurationSeconds,
            recordingDirectoryPath: encoded.recordingDirectoryPath,
            availableBytesAtStart: encoded.availableBytesAtStart,
            minimumObservedAvailableBytes: encoded.minimumObservedAvailableBytes,
            requiredBytesAtStart: encoded.requiredBytesAtStart,
            minimumReserveBytes: encoded.minimumReserveBytes,
            capturedFrameCount: encoded.capturedFrameCount,
            droppedFrameCount: encoded.droppedFrameCount,
            reportedSegmentCount: encoded.reportedSegmentCount,
            stoppedUnexpectedly: encoded.stoppedUnexpectedly,
            writerStatus: encoded.writerStatus,
            segments: actualSegments,
            encodedSegments: encoded.segments
        )
    }

    private static func evaluate(
        generatedAt: Date,
        validationSource: AudioValidationSource,
        inputDevice: SoundcheckDeviceSnapshot,
        outputDevice: SoundcheckDeviceSnapshot,
        scene: MixScene,
        expectedInputChannels: Int,
        detectedInputChannels: Int,
        sampleRate: Double,
        requestedDurationSeconds: Double,
        observedDurationSeconds: Double,
        recordingDirectoryPath: String,
        availableBytesAtStart: Int64,
        minimumObservedAvailableBytes: Int64,
        requiredBytesAtStart: Int64,
        minimumReserveBytes: Int64,
        capturedFrameCount: UInt64,
        droppedFrameCount: UInt64,
        reportedSegmentCount: Int,
        stoppedUnexpectedly: Bool,
        writerStatus: String,
        segments: [ContinuousRecordingSegmentProof],
        encodedSegments: [ContinuousRecordingSegmentProof]? = nil
    ) -> ContinuousRecordingProofReport {
        let expectedRecordingChannels = expectedInputChannels + 2
        let totalFrames = segments.reduce(UInt64(0)) { partial, segment in
            partial + UInt64(max(segment.metadata.frameCount, 0))
        }
        let expectedFrameFloor = UInt64(
            max(0, sampleRate * max(0, requestedDurationSeconds - 1.0))
        )
        let actualByteCountMatchesHeaders = segments.allSatisfy { segment in
            segment.byteCount == Int64(44 + segment.metadata.dataByteCount)
        }
        let segmentFormatsReady = !segments.isEmpty && segments.allSatisfy { segment in
            segment.metadata.formatCode == 3 &&
                segment.metadata.channelCount == expectedRecordingChannels &&
                segment.metadata.sampleRate == Int(sampleRate.rounded()) &&
                segment.metadata.bitsPerSample == 32 &&
                segment.metadata.frameCount > 0
        }
        let checks = [
            ContinuousRecordingProofCheck(
                name: "Recording Capacity At Start",
                expected: "available >= planned recording + reserve",
                observed: "\(availableBytesAtStart) available / \(requiredBytesAtStart) required",
                passed: availableBytesAtStart >= requiredBytesAtStart
            ),
            ContinuousRecordingProofCheck(
                name: "Minimum Live Reserve",
                expected: ">= \(minimumReserveBytes) bytes",
                observed: "\(minimumObservedAvailableBytes) bytes",
                passed: minimumObservedAvailableBytes >= minimumReserveBytes
            ),
            ContinuousRecordingProofCheck(
                name: "Recorder Completion",
                expected: "recorder remained active until deliberate stop",
                observed: stoppedUnexpectedly ? "stopped unexpectedly: \(writerStatus)" : "deliberate stop",
                passed: !stoppedUnexpectedly
            ),
            ContinuousRecordingProofCheck(
                name: "Recorder Drops",
                expected: "0 frames",
                observed: "\(droppedFrameCount) frames",
                passed: droppedFrameCount == 0
            ),
            ContinuousRecordingProofCheck(
                name: "Segment Count",
                expected: "\(reportedSegmentCount) non-empty WAV segment(s)",
                observed: "\(segments.count) segment(s)",
                passed: reportedSegmentCount > 0 && segments.count == reportedSegmentCount
            ),
            ContinuousRecordingProofCheck(
                name: "Segment Format",
                expected: "\(expectedRecordingChannels)-channel 96 kHz IEEE-float WAV",
                observed: segmentFormatsReady ? "all segments match" : "one or more segments mismatch",
                passed: segmentFormatsReady && BroadcastSampleRate.isSupported(sampleRate) &&
                    Int(sampleRate.rounded()) == 96_000
            ),
            ContinuousRecordingProofCheck(
                name: "Segment File Length",
                expected: "file bytes match checkpointed WAV headers",
                observed: actualByteCountMatchesHeaders ? "all segment lengths match" : "one or more segments are truncated or extended",
                passed: actualByteCountMatchesHeaders
            ),
            ContinuousRecordingProofCheck(
                name: "Captured Frame Accounting",
                expected: "\(capturedFrameCount) captured frames",
                observed: "\(totalFrames) persisted frames",
                passed: capturedFrameCount > 0 && totalFrames == capturedFrameCount
            ),
            ContinuousRecordingProofCheck(
                name: "Requested Duration",
                expected: ">= \(String(format: "%.1f", requestedDurationSeconds))s",
                observed: "\(String(format: "%.1f", observedDurationSeconds))s wall / \(String(format: "%.1f", Double(totalFrames) / max(sampleRate, 1)))s recorded",
                passed: observedDurationSeconds + 0.25 >= requestedDurationSeconds &&
                    totalFrames >= expectedFrameFloor
            ),
            ContinuousRecordingProofCheck(
                name: "Encoded Segment Index",
                expected: "report index matches files on disk",
                observed: encodedSegments == nil || encodedSegments == segments ? "matched" : "mismatch",
                passed: encodedSegments == nil || encodedSegments == segments
            )
        ]
        let passed = checks.allSatisfy(\.passed)
        let routeIsHardware = validationSource == .coreAudioDevice &&
            expectedInputChannels == 64 &&
            detectedInputChannels == expectedInputChannels &&
            Int(sampleRate.rounded()) == 96_000 &&
            !inputDevice.uid.isEmpty &&
            !outputDevice.uid.isEmpty &&
            AutoMixEngineBridge.isLivestreamSafeOutputRoute(
                forInputName: inputDevice.name,
                inputUID: inputDevice.uid,
                outputName: outputDevice.name,
                outputUID: outputDevice.uid
            )
        let productionDurationPassed = requestedDurationSeconds >= productionDurationSeconds &&
            observedDurationSeconds >= productionDurationSeconds &&
            totalFrames >= UInt64(sampleRate * productionDurationSeconds)

        return ContinuousRecordingProofReport(
            generatedAt: generatedAt,
            validationSource: validationSource,
            inputDevice: inputDevice,
            outputDevice: outputDevice,
            scene: scene,
            expectedInputChannels: expectedInputChannels,
            detectedInputChannels: detectedInputChannels,
            sampleRate: sampleRate,
            requestedDurationSeconds: requestedDurationSeconds,
            observedDurationSeconds: observedDurationSeconds,
            recordingDirectoryPath: recordingDirectoryPath,
            availableBytesAtStart: availableBytesAtStart,
            minimumObservedAvailableBytes: minimumObservedAvailableBytes,
            requiredBytesAtStart: requiredBytesAtStart,
            minimumReserveBytes: minimumReserveBytes,
            capturedFrameCount: capturedFrameCount,
            droppedFrameCount: droppedFrameCount,
            reportedSegmentCount: reportedSegmentCount,
            stoppedUnexpectedly: stoppedUnexpectedly,
            writerStatus: writerStatus,
            segments: segments,
            checks: checks,
            passed: passed,
            productionProofPassed: passed && routeIsHardware && productionDurationPassed
        )
    }

    private static func segmentProofs(
        in directoryURL: URL,
        fileManager: FileManager
    ) throws -> [ContinuousRecordingSegmentProof] {
        try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants, .skipsSubdirectoryDescendants]
        )
        .filter { $0.pathExtension.lowercased() == "wav" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .map { url in
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
            return ContinuousRecordingSegmentProof(
                path: url.lastPathComponent,
                byteCount: Int64(values.fileSize ?? 0),
                metadata: try WavMetadata.read(from: url)
            )
        }
    }

    private static func resolvedURL(path: String, relativeTo directory: URL) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return directory.appendingPathComponent(path, isDirectory: true).standardizedFileURL
    }
}
