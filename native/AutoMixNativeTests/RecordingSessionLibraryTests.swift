import AVFoundation
import Foundation
import XCTest
@testable import AutoMix_Native

final class RecordingSessionLibraryTests: XCTestCase {
    func testCaptureSessionTransitionsFromRecordingToReady() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("capture", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let session = try RecordingSessionLibrary.bootstrapCaptureSession(
            directory: directory,
            name: "Sunday Service",
            notes: "First service",
            scene: "worship",
            channelRoles: ["keys", "keys"],
            stereoPairs: ["1-2"]
        )
        try writeFixtureWAV(
            directory.appendingPathComponent("capture-part-0001.wav"),
            channels: 66,
            frames: 480,
            sampleRate: 48_000
        )

        let library = RecordingSessionLibrary()
        let active = try await library.load(root: root, activeDirectory: directory)
        XCTAssertEqual(active.first?.id, session.id)
        XCTAssertEqual(active.first?.status, .recording)
        XCTAssertEqual(active.first?.assets.first?.channelCount, 66)

        let completedAt = Date()
        let marker: [String: Any] = [
            "completedAtMs": Int64(completedAt.timeIntervalSince1970 * 1_000),
            "capturedFrames": 480,
            "droppedFrames": 0,
            "segments": 1
        ]
        try JSONSerialization.data(withJSONObject: marker).write(
            to: directory.appendingPathComponent(ContinuousRecordingStorageManager.completionMarkerName)
        )
        let completed = try await library.load(root: root, activeDirectory: nil)
        XCTAssertEqual(completed.first?.status, .ready)
        XCTAssertEqual(completed.first?.capturedFrames, 480)
        XCTAssertEqual(completed.first?.droppedFrames, 0)
        XCTAssertEqual(completed.first?.channelRoles, ["keys", "keys"])
        XCTAssertEqual(completed.first?.stereoPairs, ["1-2"])
    }

    func testUnclosedCaptureIsRecoveredAsInterruptedWithoutDeletingSegments() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("capture", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        _ = try RecordingSessionLibrary.bootstrapCaptureSession(
            directory: directory,
            name: "Interrupted",
            notes: "",
            scene: "sermon",
            channelRoles: ["speech"],
            stereoPairs: []
        )
        let segment = directory.appendingPathComponent("capture-part-0001.wav")
        try writeFixtureWAV(segment, channels: 3, frames: 96, sampleRate: 48_000)

        let sessions = try await RecordingSessionLibrary().load(root: root, activeDirectory: nil)

        XCTAssertEqual(sessions.first?.status, .interrupted)
        XCTAssertTrue(sessions.first?.lastError?.contains("completion marker") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: segment.path))
    }

    func testImportedFilesAreCopiedAndOriginalsRemainUntouched() async throws {
        let root = try temporaryDirectory()
        let sources = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sources)
        }
        let original = sources.appendingPathComponent("program.wav")
        try writeFixtureWAV(original, channels: 2, frames: 240, sampleRate: 48_000)

        let library = RecordingSessionLibrary()
        let session = try await library.importFiles(
            [original],
            root: root,
            name: "Imported program",
            minimumRemainingBytes: 0
        )

        XCTAssertEqual(session.origin, .importedFiles)
        XCTAssertEqual(session.status, .ready)
        XCTAssertEqual(session.assets.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: session.directoryURL.appendingPathComponent(session.assets[0].relativePath).path
        ))
    }

    func testProgramPreviewExtractsLastStereoPairAcrossSegments() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("capture", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        _ = try RecordingSessionLibrary.bootstrapCaptureSession(
            directory: directory,
            name: "Preview",
            notes: "",
            scene: "worship",
            channelRoles: ["keys", "keys"],
            stereoPairs: ["1-2"]
        )
        try writeFixtureWAV(
            directory.appendingPathComponent("capture-part-0001.wav"),
            channels: 4,
            frames: 128,
            sampleRate: 48_000,
            channelValues: [0.1, 0.2, 0.3, 0.4]
        )
        try writeFixtureWAV(
            directory.appendingPathComponent("capture-part-0002.wav"),
            channels: 4,
            frames: 64,
            sampleRate: 48_000,
            channelValues: [0.5, 0.6, 0.7, 0.8]
        )
        let marker = directory.appendingPathComponent(ContinuousRecordingStorageManager.completionMarkerName)
        try Data("{\"capturedFrames\":192,\"droppedFrames\":0}".utf8).write(to: marker)
        let library = RecordingSessionLibrary()
        let loaded = try await library.load(root: root, activeDirectory: nil)
        let session = try XCTUnwrap(loaded.first)

        let previewURL = try await library.renderProgramPreview(session: session)
        let preview = try AVAudioFile(forReading: previewURL)
        XCTAssertEqual(preview.processingFormat.channelCount, 2)
        XCTAssertEqual(preview.length, 192)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: preview.processingFormat,
            frameCapacity: AVAudioFrameCount(preview.length)
        ))
        try preview.read(into: buffer)
        let data = try XCTUnwrap(buffer.floatChannelData)
        XCTAssertEqual(data[0][0], 0.3, accuracy: 0.0001)
        XCTAssertEqual(data[1][0], 0.4, accuracy: 0.0001)
        XCTAssertEqual(data[0][128], 0.7, accuracy: 0.0001)
        XCTAssertEqual(data[1][128], 0.8, accuracy: 0.0001)
    }

    func testDroppedFramesAndUnreadableAssetRequireAttention() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("capture", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        _ = try RecordingSessionLibrary.bootstrapCaptureSession(
            directory: directory,
            name: "Damaged",
            notes: "",
            scene: "sermon",
            channelRoles: ["speech"],
            stereoPairs: []
        )
        try Data("not a wav".utf8).write(to: directory.appendingPathComponent("capture-part-0001.wav"))
        try Data("{\"capturedFrames\":96,\"droppedFrames\":48}".utf8).write(
            to: directory.appendingPathComponent(ContinuousRecordingStorageManager.completionMarkerName)
        )

        let loaded = try await RecordingSessionLibrary().load(root: root, activeDirectory: nil)
        let session = try XCTUnwrap(loaded.first)
        XCTAssertEqual(session.status, .needsAttention)
        XCTAssertEqual(session.droppedFrames, 48)
        XCTAssertNotNil(session.assets.first?.validationError)
    }

    func testCorruptCompletionMarkerRequiresAttentionWithoutDiscardingAudio() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("capture", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        _ = try RecordingSessionLibrary.bootstrapCaptureSession(
            directory: directory,
            name: "Bad marker",
            notes: "",
            scene: "sermon",
            channelRoles: ["speech"],
            stereoPairs: []
        )
        let segment = directory.appendingPathComponent("capture-part-0001.wav")
        try writeFixtureWAV(segment, channels: 3, frames: 96, sampleRate: 48_000)
        try Data("not json".utf8).write(
            to: directory.appendingPathComponent(ContinuousRecordingStorageManager.completionMarkerName)
        )

        let sessions = try await RecordingSessionLibrary().load(root: root, activeDirectory: nil)
        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(session.status, .needsAttention)
        XCTAssertTrue(session.lastError?.contains("completion marker") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: segment.path))
    }

    func testCleanMarkerWithoutAudioRequiresAttention() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("capture", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        _ = try RecordingSessionLibrary.bootstrapCaptureSession(
            directory: directory,
            name: "Empty capture",
            notes: "",
            scene: "sermon",
            channelRoles: ["speech"],
            stereoPairs: []
        )
        try Data("{\"capturedFrames\":0,\"droppedFrames\":0,\"segments\":0}".utf8).write(
            to: directory.appendingPathComponent(ContinuousRecordingStorageManager.completionMarkerName)
        )

        let sessions = try await RecordingSessionLibrary().load(root: root, activeDirectory: nil)
        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(session.status, .needsAttention)
        XCTAssertTrue(session.lastError?.contains("without a readable audio segment") == true)
    }

    func testMissingManagedImportRequiresAttention() async throws {
        let root = try temporaryDirectory()
        let sources = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sources)
        }
        let original = sources.appendingPathComponent("program.wav")
        try writeFixtureWAV(original, channels: 2, frames: 240, sampleRate: 48_000)
        let library = RecordingSessionLibrary()
        let imported = try await library.importFiles(
            [original],
            root: root,
            name: "Missing import",
            minimumRemainingBytes: 0
        )
        let managed = imported.directoryURL.appendingPathComponent(imported.assets[0].relativePath)
        try FileManager.default.removeItem(at: managed)

        let sessions = try await library.load(root: root, activeDirectory: nil)
        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(session.status, .needsAttention)
        XCTAssertTrue(session.lastError?.contains("missing") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }

    func testLibraryDoesNotFollowSessionDirectorySymlinks() async throws {
        let root = try temporaryDirectory()
        let external = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: external)
        }
        let externalAudio = external.appendingPathComponent("outside.wav")
        try writeFixtureWAV(externalAudio, channels: 2, frames: 96, sampleRate: 48_000)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked-session"),
            withDestinationURL: external
        )

        let sessions = try await RecordingSessionLibrary().load(root: root, activeDirectory: nil)
        XCTAssertTrue(sessions.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalAudio.path))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("recording-session-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func writeFixtureWAV(
        _ url: URL,
        channels: AVAudioChannelCount,
        frames: AVAudioFrameCount,
        sampleRate: Double,
        channelValues: [Float]? = nil
    ) throws {
        let layout = try XCTUnwrap(AVAudioChannelLayout(
            layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(channels)
        ))
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            interleaved: false,
            channelLayout: layout
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let data = try XCTUnwrap(buffer.floatChannelData)
        for channel in 0..<Int(channels) {
            let value = channelValues?[safe: channel] ?? Float(channel + 1) * 0.01
            for frame in 0..<Int(frames) {
                data[channel][frame] = value
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
