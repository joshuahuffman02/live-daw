import CoreAudio
import Foundation
import XCTest
@testable import AutoMix_Native

final class AutoMixEngineBridgeSimulationTests: XCTestCase {
    private var bridge: AutoMixEngineBridge!

    override func setUp() {
        super.setUp()
        bridge = AutoMixEngineBridge()
    }

    override func tearDown() {
        bridge.stop()
        bridge = nil
        super.tearDown()
    }

    func testAvailableDevicesIncludesSimulatedHD96DanteSplit() throws {
        let simulated = try XCTUnwrap(bridge.availableDevices().first { device in
            device.uid == "com.livedaw.automix.simulated-hd96-dante"
        })

        XCTAssertEqual(simulated.name, "Simulated HD96 Dante Split")
        XCTAssertEqual(simulated.inputChannels, 64)
        XCTAssertEqual(simulated.outputChannels, 2)
        XCTAssertEqual(simulated.sampleRate, 96_000, accuracy: 0.5)
        XCTAssertTrue(simulated.inputFormatSupported)
        XCTAssertTrue(simulated.outputFormatSupported)
        XCTAssertTrue(simulated.inputFormatSummary.localizedCaseInsensitiveContains("float"))
        XCTAssertTrue(simulated.outputFormatSummary.localizedCaseInsensitiveContains("float"))
    }

    func testAppBundleDeclaresAudioInputUsageDescription() throws {
        let description = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String)
        XCTAssertTrue(description.localizedCaseInsensitiveContains("Dante Virtual Soundcard"))
        XCTAssertTrue(description.localizedCaseInsensitiveContains("Core Audio"))
    }

    func testBridgeAcceptsSupportedBroadcastRates() {
        // The bridge accepts the standard broadcast rates (48k and 96k) as a safety net;
        // the Swift start gate enforces the operator's exact expected rate.
        XCTAssertTrue(AutoMixEngineBridge.isHD96TargetSampleRate(96_000.0))
        XCTAssertTrue(AutoMixEngineBridge.isHD96TargetSampleRate(48_000.0))
        XCTAssertTrue(AutoMixEngineBridge.isHD96TargetSampleRate(47_999.5))
        XCTAssertFalse(AutoMixEngineBridge.isHD96TargetSampleRate(44_100.0))
        XCTAssertFalse(AutoMixEngineBridge.isHD96TargetSampleRate(88_200.0))
    }

    func testLatencyReportIncludesLimiterBuffersAndSeparateOutputPrebuffer() throws {
        try bridge.startSimulated(
            withChannelCount: 2,
            sampleRate: 96_000,
            bufferFrameSize: 256,
            channelRoles: [ChannelRole.speech.rawValue, ChannelRole.bass.rawValue],
            inputChannelIndices: [0, 1]
        )
        XCTAssertEqual(bridge.algorithmicLatencyFrames, 144)
        XCTAssertEqual(bridge.algorithmicLatencyMs, 1.5, accuracy: 0.001)
        XCTAssertEqual(bridge.inputHardwareLatencyFrames, 0)
        XCTAssertEqual(bridge.outputHardwareLatencyFrames, 0)
        XCTAssertEqual(bridge.separateOutputPrebufferFrames, 0)
        XCTAssertEqual(bridge.estimatedOneWayLatencyMs, 6.833, accuracy: 0.01)
        XCTAssertTrue(waitUntil(timeout: 1.0) {
            self.bridge.inputCallbackAgeMs >= 0 &&
                self.bridge.outputCallbackAgeMs >= 0
        })

        bridge.stop()
        try bridge.startSimulatedSeparateOutput(
            withChannelCount: 2,
            sampleRate: 96_000,
            inputBufferFrameSize: 256,
            outputBufferFrameSize: 512,
            channelRoles: [ChannelRole.speech.rawValue, ChannelRole.bass.rawValue],
            inputChannelIndices: [0, 1]
        )
        XCTAssertEqual(bridge.separateOutputPrebufferFrames, 8_192)
        XCTAssertEqual(bridge.estimatedOneWayLatencyMs, 94.833, accuracy: 0.01)
        XCTAssertTrue(waitUntil(timeout: 1.0) {
            self.bridge.separateOutputRingFillFrames > 0 &&
                self.bridge.inputCallbackAgeMs >= 0 &&
                self.bridge.outputCallbackAgeMs >= 0
        })
        XCTAssertLessThanOrEqual(abs(bridge.outputClockCorrectionPpm), 1_000.1)
    }

    func testBridgeOutputIsolationHelperMatchesHD96RouteSafety() {
        XCTAssertFalse(AutoMixEngineBridge.isLivestreamSafeOutputRoute(
            forInputName: "Dante Virtual Soundcard",
            inputUID: "com.audinate.dantevirtualsoundcard",
            outputName: "Dante Virtual Soundcard",
            outputUID: "com.audinate.dantevirtualsoundcard"
        ))
        XCTAssertTrue(AutoMixEngineBridge.isLivestreamSafeOutputRoute(
            forInputName: "Dante Virtual Soundcard",
            inputUID: "com.audinate.dantevirtualsoundcard",
            outputName: "OBS Virtual Output",
            outputUID: "obs.virtual.output"
        ))
        XCTAssertTrue(AutoMixEngineBridge.isLivestreamSafeOutputRoute(
            forInputName: "Dante Virtual Soundcard",
            inputUID: "com.audinate.dantevirtualsoundcard",
            outputName: "",
            outputUID: "blackhole.stream.output"
        ))
        XCTAssertFalse(AutoMixEngineBridge.isLivestreamSafeOutputRoute(
            forInputName: "Dante Virtual Soundcard",
            inputUID: "com.audinate.dantevirtualsoundcard",
            outputName: "Midas HD96 Dante Return",
            outputUID: "hd96.dante.return"
        ))
        XCTAssertTrue(AutoMixEngineBridge.isLivestreamSafeOutputRoute(
            forInputName: "Broadcast Aggregate Device",
            inputUID: "broadcast.aggregate",
            outputName: "Broadcast Aggregate Device",
            outputUID: "broadcast.aggregate"
        ))
        XCTAssertFalse(AutoMixEngineBridge.isLivestreamSafeOutputRoute(
            forInputName: "Dante Aggregate Device",
            inputUID: "dante.aggregate",
            outputName: "Dante Aggregate Device",
            outputUID: "dante.aggregate"
        ))
    }

    func testCoreAudioDeviceInventoryScoresHD96InputAndIsolatedOutput() throws {
        let dante = AMDeviceInfo(
            uid: "com.audinate.dantevirtualsoundcard",
            name: "Dante Virtual Soundcard",
            inputChannels: 64,
            outputChannels: 2,
            sampleRate: 96_000
        )
        let stream = AMDeviceInfo(
            uid: "stream.encoder.output",
            name: "Stream Encoder Output",
            inputChannels: 0,
            outputChannels: 2,
            sampleRate: 96_000
        )
        let laptopMic = AMDeviceInfo(
            uid: "macbook.microphone",
            name: "MacBook Microphone",
            inputChannels: 1,
            outputChannels: 0,
            sampleRate: 48_000,
            inputFormatSummary: "32-bit little-endian float PCM",
            outputFormatSummary: "no output streams",
            inputFormatSupported: true,
            outputFormatSupported: false
        )

        let inventory = CoreAudioDeviceInventory.make(
            generatedAt: Date(timeIntervalSince1970: 0),
            devices: [dante, stream, laptopMic],
            expectedInputChannels: 64,
            selectedInputUID: dante.uid,
            selectedOutputUID: stream.uid
        )

        XCTAssertEqual(inventory.deviceCount, 3)
        XCTAssertEqual(inventory.readyInputUIDs, [dante.uid])
        XCTAssertEqual(inventory.readyOutputUIDs, [stream.uid])
        XCTAssertTrue(inventory.summary.localizedCaseInsensitiveContains("1 HD96 input candidate"))

        let danteEntry = try XCTUnwrap(inventory.devices.first { $0.uid == dante.uid })
        XCTAssertTrue(danteEntry.inputReady)
        XCTAssertFalse(danteEntry.outputReady)
        XCTAssertEqual(danteEntry.outputIsolationReady, false)
        XCTAssertTrue(danteEntry.outputReadiness.localizedCaseInsensitiveContains("same Core Audio device"))

        let streamEntry = try XCTUnwrap(inventory.devices.first { $0.uid == stream.uid })
        XCTAssertFalse(streamEntry.inputReady)
        XCTAssertTrue(streamEntry.outputReady)
        XCTAssertEqual(streamEntry.outputIsolationReady, true)
    }

    func testCoreAudioDeviceInventoryWithoutSelectedInputDoesNotScoreIsolation() throws {
        let output = AMDeviceInfo(
            uid: "stream.encoder.output",
            name: "Stream Encoder Output",
            inputChannels: 0,
            outputChannels: 2,
            sampleRate: 96_000
        )

        let inventory = CoreAudioDeviceInventory.make(
            generatedAt: Date(timeIntervalSince1970: 0),
            devices: [output],
            expectedInputChannels: 64
        )

        let entry = try XCTUnwrap(inventory.devices.first)
        XCTAssertTrue(entry.outputReady)
        XCTAssertNil(entry.outputIsolationReady)
        XCTAssertNil(entry.outputIsolationObserved)
    }

    func testCoreAudioRouteSelectionPrefersDanteInputAndLivestreamOutput() throws {
        let dante = AMDeviceInfo(
            uid: "com.audinate.dantevirtualsoundcard",
            name: "Dante Virtual Soundcard",
            inputChannels: 64,
            outputChannels: 2,
            sampleRate: 96_000
        )
        let speakers = AMDeviceInfo(
            uid: "com.apple.built-in-output",
            name: "MacBook Pro Speakers",
            inputChannels: 0,
            outputChannels: 2,
            sampleRate: 96_000
        )
        let stream = AMDeviceInfo(
            uid: "stream.encoder.output",
            name: "Stream Encoder Output",
            inputChannels: 0,
            outputChannels: 2,
            sampleRate: 96_000
        )

        let selectedInput = try XCTUnwrap(CoreAudioRouteSelection.preferredInputDevice(
            from: [speakers, stream, dante]
        ))
        let selectedOutput = try XCTUnwrap(CoreAudioRouteSelection.preferredOutputDevice(
            from: [dante, speakers, stream],
            selectedInput: selectedInput
        ))

        XCTAssertEqual(selectedInput.uid, dante.uid)
        XCTAssertEqual(selectedOutput.uid, stream.uid)
    }

    func testCoreAudioRouteSelectionPreservesMissingSavedInputUID() {
        let simulated = AMDeviceInfo(
            uid: "com.livedaw.automix.simulated-hd96-dante",
            name: "Simulated HD96 Dante Split",
            inputChannels: 64,
            outputChannels: 2,
            sampleRate: 96_000
        )
        let stream = AMDeviceInfo(
            uid: "stream.encoder.output",
            name: "Stream Encoder Output",
            inputChannels: 0,
            outputChannels: 2,
            sampleRate: 96_000
        )

        let resolved = CoreAudioRouteSelection.validatedInputUID(
            currentInputUID: "com.audinate.real-dvs",
            devices: [simulated, stream]
        )

        XCTAssertEqual(resolved, "com.audinate.real-dvs")
    }

    func testCoreAudioRouteSelectionAutoselectsOnlyWhenInputUIDIsEmpty() {
        let simulated = AMDeviceInfo(
            uid: "com.livedaw.automix.simulated-hd96-dante",
            name: "Simulated HD96 Dante Split",
            inputChannels: 64,
            outputChannels: 2,
            sampleRate: 96_000
        )

        XCTAssertEqual(
            CoreAudioRouteSelection.validatedInputUID(
                currentInputUID: "",
                devices: [simulated]
            ),
            simulated.uid
        )
    }

    func testCoreAudioRouteSelectionLeavesOutputUnselectedWithoutLivestreamTarget() {
        let dante = AMDeviceInfo(
            uid: "com.audinate.dantevirtualsoundcard",
            name: "Dante Virtual Soundcard",
            inputChannels: 64,
            outputChannels: 2,
            sampleRate: 96_000
        )
        let speakers = AMDeviceInfo(
            uid: "com.apple.built-in-output",
            name: "MacBook Pro Speakers",
            inputChannels: 0,
            outputChannels: 2,
            sampleRate: 96_000
        )

        XCTAssertNil(CoreAudioRouteSelection.preferredOutputDevice(
            from: [dante, speakers],
            selectedInput: dante
        ))
    }

    func testCoreAudioRouteSelectionClearsUnsafeCurrentOutputAfterInputChange() {
        let dante = AMDeviceInfo(
            uid: "com.audinate.dantevirtualsoundcard",
            name: "Dante Virtual Soundcard",
            inputChannels: 64,
            outputChannels: 2,
            sampleRate: 96_000
        )
        let speakers = AMDeviceInfo(
            uid: "com.apple.built-in-output",
            name: "MacBook Pro Speakers",
            inputChannels: 0,
            outputChannels: 2,
            sampleRate: 96_000
        )

        let resolved = CoreAudioRouteSelection.validatedOutputUID(
            currentOutputUID: speakers.uid,
            devices: [dante, speakers],
            selectedInput: dante
        )

        XCTAssertEqual(resolved, "")
    }

    func testCoreAudioRouteSelectionReplacesUnsafeCurrentOutputWithSafeTarget() {
        let dante = AMDeviceInfo(
            uid: "com.audinate.dantevirtualsoundcard",
            name: "Dante Virtual Soundcard",
            inputChannels: 64,
            outputChannels: 2,
            sampleRate: 96_000
        )
        let speakers = AMDeviceInfo(
            uid: "com.apple.built-in-output",
            name: "MacBook Pro Speakers",
            inputChannels: 0,
            outputChannels: 2,
            sampleRate: 96_000
        )
        let stream = AMDeviceInfo(
            uid: "stream.encoder.output",
            name: "Stream Encoder Output",
            inputChannels: 0,
            outputChannels: 2,
            sampleRate: 96_000
        )

        let resolved = CoreAudioRouteSelection.validatedOutputUID(
            currentOutputUID: speakers.uid,
            devices: [dante, speakers, stream],
            selectedInput: dante
        )

        XCTAssertEqual(resolved, stream.uid)
    }

    func testCoreAudioRouteSelectionKeepsSafeCurrentOutput() {
        let dante = AMDeviceInfo(
            uid: "com.audinate.dantevirtualsoundcard",
            name: "Dante Virtual Soundcard",
            inputChannels: 64,
            outputChannels: 2,
            sampleRate: 96_000
        )
        let stream = AMDeviceInfo(
            uid: "stream.encoder.output",
            name: "Stream Encoder Output",
            inputChannels: 0,
            outputChannels: 2,
            sampleRate: 96_000
        )
        let backupStream = AMDeviceInfo(
            uid: "backup.stream.output",
            name: "Backup Stream Output",
            inputChannels: 0,
            outputChannels: 2,
            sampleRate: 96_000
        )

        let resolved = CoreAudioRouteSelection.validatedOutputUID(
            currentOutputUID: stream.uid,
            devices: [dante, backupStream, stream],
            selectedInput: dante
        )

        XCTAssertEqual(resolved, stream.uid)
    }

    func testCoreAudioRouteSelectionResolvesExplicitProfileAndDetectedOutputUIDs() {
        let dante = AMDeviceInfo(
            uid: "com.audinate.dantevirtualsoundcard",
            name: "Dante Virtual Soundcard",
            inputChannels: 64,
            outputChannels: 2,
            sampleRate: 96_000
        )
        let stream = AMDeviceInfo(
            uid: "stream.encoder.output",
            name: "Stream Encoder Output",
            inputChannels: 0,
            outputChannels: 2,
            sampleRate: 96_000
        )

        XCTAssertEqual(
            CoreAudioRouteSelection.resolvedOutputUID(
                explicitOutputUID: "explicit.stream",
                profileOutputUID: "profile.stream",
                devices: [dante, stream],
                selectedInput: dante
            ),
            "explicit.stream"
        )
        XCTAssertEqual(
            CoreAudioRouteSelection.resolvedOutputUID(
                explicitOutputUID: nil,
                profileOutputUID: "profile.stream",
                devices: [dante, stream],
                selectedInput: dante
            ),
            "profile.stream"
        )
        XCTAssertEqual(
            CoreAudioRouteSelection.resolvedOutputUID(
                explicitOutputUID: "",
                profileOutputUID: "",
                devices: [dante, stream],
                selectedInput: dante
            ),
            stream.uid
        )
    }

    func testCoreAudioRouteSnapshotPreservesOpenedRouteForProofReports() throws {
        let dante = AMDeviceInfo(
            uid: "com.audinate.dantevirtualsoundcard",
            name: "Dante Virtual Soundcard",
            inputChannels: 64,
            outputChannels: 0,
            sampleRate: 96_000,
            inputFormatSummary: "32-bit little-endian float PCM",
            outputFormatSummary: "no output streams",
            inputFormatSupported: true,
            outputFormatSupported: false
        )
        let stream = AMDeviceInfo(
            uid: "stream.encoder.output",
            name: "Stream Encoder Output",
            inputChannels: 0,
            outputChannels: 2,
            sampleRate: 96_000,
            inputFormatSummary: "no input streams",
            outputFormatSummary: "32-bit little-endian float PCM",
            inputFormatSupported: false,
            outputFormatSupported: true
        )
        let laterSpeakerSelection = AMDeviceInfo(
            uid: "com.apple.built-in-output",
            name: "MacBook Pro Speakers",
            inputChannels: 0,
            outputChannels: 2,
            sampleRate: 96_000
        )

        let snapshot = CoreAudioRouteSnapshot.make(
            inputUID: dante.uid,
            outputUID: stream.uid,
            devices: [dante, stream, laterSpeakerSelection]
        )
        let reconstructedInput = try XCTUnwrap(snapshot.inputDeviceInfo(availableDevices: [dante, laterSpeakerSelection]))
        let reconstructedOutput = try XCTUnwrap(snapshot.outputDeviceInfo(availableDevices: [dante, laterSpeakerSelection]))

        XCTAssertEqual(snapshot.inputDevice.uid, dante.uid)
        XCTAssertEqual(snapshot.outputDevice.uid, stream.uid)
        XCTAssertEqual(reconstructedInput.uid, dante.uid)
        XCTAssertEqual(reconstructedOutput.uid, stream.uid)
        XCTAssertEqual(reconstructedOutput.name, stream.name)
        XCTAssertTrue(reconstructedOutput.outputFormatSupported)
    }

    func testCoreAudioFormatValidationRequiresFloat32PCM() {
        XCTAssertTrue(AutoMixEngineBridge.isSupportedCoreAudioPCMFormatID(
            kAudioFormatLinearPCM,
            flags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            bitsPerChannel: 32
        ))
        XCTAssertFalse(AutoMixEngineBridge.isSupportedCoreAudioPCMFormatID(
            kAudioFormatLinearPCM,
            flags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            bitsPerChannel: 32
        ))
        XCTAssertFalse(AutoMixEngineBridge.isSupportedCoreAudioPCMFormatID(
            kAudioFormatLinearPCM,
            flags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsBigEndian,
            bitsPerChannel: 32
        ))
        XCTAssertFalse(AutoMixEngineBridge.isSupportedCoreAudioPCMFormatID(
            kAudioFormatMPEG4AAC,
            flags: 0,
            bitsPerChannel: 0
        ))
    }

    #if DEBUG
    func testCoreAudioInputExtractionHandlesNonInterleavedDanteBuffers() {
        let channels = debugExtractChannels(
            buffers: [
                [1, 2, 3],
                [10, 11, 12],
                [20, 21, 22]
            ],
            channelCounts: [1, 1, 1],
            expectedChannels: 4,
            frames: 3
        )

        XCTAssertEqual(channels, [
            [1, 2, 3],
            [10, 11, 12],
            [20, 21, 22],
            [0, 0, 0]
        ])
    }

    func testCoreAudioInputExtractionDeinterleavesSingleMultichannelBuffer() {
        let channels = debugExtractChannels(
            buffers: [
                [
                    1, 10, 100,
                    2, 20, 200,
                    3, 30, 300
                ]
            ],
            channelCounts: [3],
            expectedChannels: 3,
            frames: 3
        )

        XCTAssertEqual(channels, [
            [1, 2, 3],
            [10, 20, 30],
            [100, 200, 300]
        ])
    }

    func testCoreAudioInputExtractionSupportsGroupedMultibufferLayouts() {
        let channels = debugExtractChannels(
            buffers: [
                [
                    1, 10,
                    2, 20,
                    3, 30
                ],
                [
                    100, 1000,
                    200, 2000,
                    300, 3000
                ]
            ],
            channelCounts: [2, 2],
            expectedChannels: 4,
            frames: 3
        )

        XCTAssertEqual(channels, [
            [1, 2, 3],
            [10, 20, 30],
            [100, 200, 300],
            [1000, 2000, 3000]
        ])
    }

    func testCoreAudioInputExtractionZeroPadsShortAndNullBuffers() {
        let channels = debugExtractChannels(
            buffers: [
                [1, 2],
                [],
                [7, 8]
            ],
            channelCounts: [1, 1, 2],
            expectedChannels: 4,
            frames: 3
        )

        XCTAssertEqual(channels, [
            [1, 2, 0],
            [0, 0, 0],
            [7, 0, 0],
            [8, 0, 0]
        ])
    }
    #endif

    func testSimulatedHD96BridgeRunsMetersControlsAndRecording() throws {
        let roles = simulatedRoles(count: 64)
        try bridge.startSimulated(
            withChannelCount: 64,
            sampleRate: 96_000,
            bufferFrameSize: 256,
            channelRoles: roles,
            inputChannelIndices: identityInputMap(count: 64)
        )

        bridge.setSceneName(MixScene.sermon.rawValue)
        XCTAssertTrue(bridge.setChannelRoleForChannel(0, role: ChannelRole.speech.rawValue))
        XCTAssertTrue(bridge.setManualMixOverrideForChannel(
            0,
            faderDb: -18,
            pan: -0.25,
            overrideFader: true,
            overridePan: true
        ))

        XCTAssertTrue(bridge.running)
        XCTAssertEqual(bridge.inputChannelCount, 64)
        XCTAssertEqual(bridge.sampleRate, 96_000, accuracy: 0.5)
        XCTAssertEqual(bridge.bufferFrameSize, 256)
        let runningInput = try XCTUnwrap(bridge.runningInputDeviceInfo())
        let runningOutput = try XCTUnwrap(bridge.runningOutputDeviceInfo())
        XCTAssertEqual(runningInput.uid, "com.livedaw.automix.simulated-hd96-dante")
        XCTAssertEqual(runningInput.inputChannels, 64)
        XCTAssertEqual(runningInput.sampleRate, 96_000, accuracy: 0.5)
        XCTAssertEqual(runningOutput.uid, runningInput.uid)
        XCTAssertEqual(runningOutput.outputChannels, 2)
        XCTAssertTrue(runningInput.inputFormatSupported)
        XCTAssertTrue(runningOutput.outputFormatSupported)

        XCTAssertTrue(waitUntil(timeout: 2.0) {
            self.bridge.lastCallbackFrameCount > 0 &&
                self.bridge.inputLevelsDb().prefix(8).contains { $0.doubleValue > -90.0 }
        })
        XCTAssertEqual(bridge.lastCallbackFrameCount, 256)
        XCTAssertEqual(bridge.maxObservedCallbackFrameCount, 256)
        XCTAssertFalse(bridge.watchdogSafeActive)

        let levels = bridge.inputLevelsDb()
        XCTAssertEqual(levels.count, 64)
        XCTAssertTrue(levels.prefix(8).contains { $0.doubleValue > -90.0 })
        let streamLevels = bridge.outputLevelsDb()
        XCTAssertEqual(streamLevels.count, 2)
        XCTAssertTrue(streamLevels.allSatisfy { $0.doubleValue > -90.0 && $0.doubleValue < -0.1 })
        XCTAssertEqual(bridge.dropoutCount, 0)

        let recordingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        try? FileManager.default.removeItem(at: recordingURL)
        bridge.setSafeBypass(true)
        try bridge.startTestRecording(at: recordingURL, seconds: 1.0)

        XCTAssertTrue(waitUntil(timeout: 5.0) {
            self.bridge.recordingTargetFrameCount > 0 &&
                self.bridge.recordedFrameCount >= self.bridge.recordingTargetFrameCount &&
                !self.bridge.recording &&
                self.bridge.recordingSaveInProgress
        })
        XCTAssertTrue(bridge.recordingSaveInProgress)

        var finishedRecordingURL: URL?
        XCTAssertTrue(waitUntil(timeout: 5.0) {
            if let url = self.bridge.consumeFinishedRecordingURL() {
                finishedRecordingURL = url
                return true
            }
            return false
        })
        XCTAssertFalse(bridge.recordingSaveInProgress)

        let finished = try XCTUnwrap(finishedRecordingURL)
        let attributes = try FileManager.default.attributesOfItem(atPath: finished.path)
        let byteCount = try XCTUnwrap(attributes[.size] as? NSNumber).intValue
        XCTAssertGreaterThan(byteCount, 1_000_000)

        let header = try readWavHeader(from: finished)
        XCTAssertEqual(String(data: header.subdata(in: 0..<4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: header.subdata(in: 8..<12), encoding: .ascii), "WAVE")
        XCTAssertEqual(uint16LE(header, at: 20), 3)
        XCTAssertEqual(uint16LE(header, at: 22), 66)
        XCTAssertEqual(uint32LE(header, at: 24), 96_000)
        XCTAssertEqual(uint16LE(header, at: 34), 32)
        let metadata = try WavMetadata.read(from: finished)
        XCTAssertEqual(metadata.channelCount, 66)
        XCTAssertEqual(metadata.sampleRate, 96_000)
        XCTAssertEqual(metadata.bitsPerSample, 32)
        XCTAssertEqual(metadata.dataByteCount, byteCount - 44)
        XCTAssertEqual(metadata.frameCount, 96_000)
        XCTAssertEqual(metadata.durationSeconds, 1.0, accuracy: 0.001)
        let signalSummary = try WavSignalSummary.read(from: finished, inputChannelCount: 64)
        XCTAssertGreaterThan(signalSummary.activeInputChannelCount, 0)
        XCTAssertEqual(signalSummary.activeInputChannels.count, 64)
        XCTAssertEqual(signalSummary.activeInputChannels.first, 1)
        XCTAssertEqual(signalSummary.activeInputChannels.last, 64)
        XCTAssertEqual(signalSummary.inputPeakDbByChannel.count, 64)
        XCTAssertTrue(signalSummary.inputPeakDbByChannel.allSatisfy { $0 > -90.0 })
        XCTAssertEqual(signalSummary.activeStreamOutputChannelCount, 2)
        XCTAssertGreaterThan(signalSummary.inputPeakDb, -90.0)
        XCTAssertTrue(signalSummary.streamOutputPeakDb.allSatisfy { $0 > -90.0 && $0 < -0.1 })
        let report = try SoundcheckReport.make(from: SoundcheckReportInput(
            recordingURL: finished,
            expectedRecordingDurationSeconds: 1.0,
            inputDevice: simulatedDeviceSnapshot(),
            outputDevice: simulatedDeviceSnapshot(),
            scene: .sermon,
            expectedInputChannels: 64,
            detectedInputChannels: 64,
            detectedSampleRate: 96_000,
            bufferFrameSize: bridge.bufferFrameSize,
            lastCallbackFrames: bridge.lastCallbackFrameCount,
            maxObservedCallbackFrames: bridge.maxObservedCallbackFrameCount,
            dropoutCount: bridge.dropoutCount,
            outputUnderrunCount: bridge.outputUnderrunCount,
            watchdogSafeActive: bridge.watchdogSafeActive,
            safeBypassEnabled: true,
            frozen: false,
            channelMappings: simulatedMappings(count: 64),
            latestInputLevelsDb: Array(repeating: -30.0, count: 64),
            latestStreamOutputLevelsDb: [-30.0, -30.0],
            latestMomentaryLufs: -23.0,
            latestShortTermLufs: -24.0,
            latestIntegratedLufs: -25.0,
            latestLimiterGainReductionDb: -1.0
        ))
        XCTAssertTrue(report.passed)
        XCTAssertEqual(report.expectedRecordingDurationSeconds, 1.0)
        XCTAssertEqual(report.recordingFrameCount, 96_000)
        XCTAssertEqual(report.recordingDurationSeconds, 1.0, accuracy: 0.001)
        XCTAssertEqual(report.recordedActiveInputChannelCount, 64)
        XCTAssertEqual(report.recordedActiveInputChannels.count, 64)
        XCTAssertEqual(report.recordedActiveInputChannels.first, 1)
        XCTAssertEqual(report.recordedActiveInputChannels.last, 64)
        XCTAssertEqual(report.recordedInputPeakDbByChannel.count, 64)
        XCTAssertTrue(report.recordedInputPeakDbByChannel.allSatisfy { $0 > -90.0 })
        XCTAssertEqual(report.recordedStreamOutputActiveChannelCount, 2)
        XCTAssertEqual(bridge.dropoutCount, 0)
        bridge.stop()
        XCTAssertNil(bridge.runningInputDeviceInfo())
        XCTAssertNil(bridge.runningOutputDeviceInfo())
    }

    func testRunningSimulatedBridgeCanDeallocateWithoutAudioCallbackCrash() throws {
        weak var weakBridge: AutoMixEngineBridge?

        do {
            var localBridge: AutoMixEngineBridge? = AutoMixEngineBridge()
            weakBridge = localBridge
            try localBridge?.startSimulated(
                withChannelCount: 64,
                sampleRate: 96_000,
                bufferFrameSize: 256,
                channelRoles: simulatedRoles(count: 64),
                inputChannelIndices: identityInputMap(count: 64)
            )

            XCTAssertTrue(waitUntil(timeout: 2.0) {
                localBridge?.lastCallbackFrameCount == 256
            })

            localBridge = nil
        }

        XCTAssertNil(weakBridge)
        Thread.sleep(forTimeInterval: 0.05)
    }

    func testContinuouslyRecordingBridgeCanDeallocateAndFinalizeItsSegment() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        weak var weakBridge: AutoMixEngineBridge?

        do {
            var localBridge: AutoMixEngineBridge? = AutoMixEngineBridge()
            weakBridge = localBridge
            try localBridge?.startSimulated(
                withChannelCount: 4,
                sampleRate: 48_000,
                bufferFrameSize: 256,
                channelRoles: simulatedRoles(count: 4),
                inputChannelIndices: identityInputMap(count: 4)
            )
            try localBridge?.startContinuousRecording(atDirectoryURL: directory)
            XCTAssertTrue(waitUntil(timeout: 2.0) {
                (localBridge?.continuousRecordingFrameCount ?? 0) >= 1_024
            })

            localBridge = nil
        }

        XCTAssertNil(weakBridge)
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension.lowercased() == "wav" }
        XCTAssertEqual(files.count, 1)
        XCTAssertGreaterThan(try WavMetadata.read(from: XCTUnwrap(files.first)).frameCount, 0)
    }

    #if DEBUG
    func testSimulatedNativeRealtimeRenderDoesNotAllocateAfterPrepare() throws {
        try bridge.startSimulated(
            withChannelCount: 64,
            sampleRate: 96_000,
            bufferFrameSize: 256,
            channelRoles: simulatedRoles(count: 64),
            inputChannelIndices: identityInputMap(count: 64)
        )

        XCTAssertTrue(waitUntil(timeout: 2.0) {
            self.bridge.lastCallbackFrameCount == 256 &&
                self.bridge.outputLevelsDb().allSatisfy { $0.doubleValue > -90.0 && $0.doubleValue < -0.1 }
        })

        let allocationCount = bridge.debugRunRealtimeNoAllocationProbe(withFrameCount: 256, blocks: 128)

        XCTAssertEqual(allocationCount, 0)
        XCTAssertEqual(bridge.dropoutCount, 0)
        XCTAssertEqual(bridge.callbackOverrunCount, 0)
        XCTAssertEqual(bridge.renderDeadlineMissCount, 0)
    }

    func testCoreAudioInputRenderPathDoesNotAllocateAfterPrepare() throws {
        try bridge.startSimulated(
            withChannelCount: 64,
            sampleRate: 96_000,
            bufferFrameSize: 256,
            channelRoles: simulatedRoles(count: 64),
            inputChannelIndices: identityInputMap(count: 64)
        )

        XCTAssertTrue(waitUntil(timeout: 2.0) {
            self.bridge.lastCallbackFrameCount == 256
        })

        let interleavedAllocations = bridge.debugRunRealtimeCoreAudioInputNoAllocationProbe(
            withFrameCount: 256,
            blocks: 128,
            channelsPerBuffer: 64
        )
        let nonInterleavedAllocations = bridge.debugRunRealtimeCoreAudioInputNoAllocationProbe(
            withFrameCount: 256,
            blocks: 128,
            channelsPerBuffer: 1
        )

        XCTAssertEqual(interleavedAllocations, 0)
        XCTAssertEqual(nonInterleavedAllocations, 0)
        XCTAssertEqual(bridge.dropoutCount, 0)
        XCTAssertEqual(bridge.callbackOverrunCount, 0)
        XCTAssertEqual(bridge.renderDeadlineMissCount, 0)
    }

    func testCoreAudioInputRecordingPathDoesNotAllocateAfterPrepare() throws {
        try bridge.startSimulated(
            withChannelCount: 64,
            sampleRate: 96_000,
            bufferFrameSize: 256,
            channelRoles: simulatedRoles(count: 64),
            inputChannelIndices: identityInputMap(count: 64)
        )

        XCTAssertTrue(waitUntil(timeout: 2.0) {
            self.bridge.lastCallbackFrameCount == 256 &&
                self.bridge.outputLevelsDb().allSatisfy { $0.doubleValue > -90.0 && $0.doubleValue < -0.1 }
        })

        let recordingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        try? FileManager.default.removeItem(at: recordingURL)
        bridge.setSafeBypass(true)
        try bridge.startTestRecording(at: recordingURL, seconds: 1.0)

        let recordedFrameCountBefore = bridge.recordedFrameCount
        let allocationCount = bridge.debugRunRealtimeCoreAudioInputNoAllocationProbe(
            withFrameCount: 256,
            blocks: 16,
            channelsPerBuffer: 64
        )

        XCTAssertEqual(allocationCount, 0)
        XCTAssertGreaterThan(bridge.recordedFrameCount, recordedFrameCountBefore)
        XCTAssertTrue(bridge.recording)
        XCTAssertFalse(bridge.recordingSaveInProgress)
        XCTAssertEqual(bridge.dropoutCount, 0)
        XCTAssertEqual(bridge.callbackOverrunCount, 0)
        XCTAssertEqual(bridge.renderDeadlineMissCount, 0)
    }

    func testContinuousRecordingSegmentsRawInputsAndProgramWithoutRealtimeAllocation() throws {
        try bridge.startSimulated(
            withChannelCount: 4,
            sampleRate: 48_000,
            bufferFrameSize: 256,
            channelRoles: simulatedRoles(count: 4),
            inputChannelIndices: identityInputMap(count: 4)
        )
        XCTAssertTrue(waitUntil(timeout: 2.0) {
            self.bridge.lastCallbackFrameCount == 256
        })

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        bridge.debugSetContinuousRecordingSegmentFrameLimit(1_024)
        try bridge.startContinuousRecording(atDirectoryURL: directory)

        let allocationCount = bridge.debugRunRealtimeCoreAudioInputNoAllocationProbe(
            withFrameCount: 256,
            blocks: 16,
            channelsPerBuffer: 4
        )
        XCTAssertEqual(allocationCount, 0)
        XCTAssertTrue(waitUntil(timeout: 2.0) {
            self.bridge.continuousRecordingFrameCount >= 8_192 &&
                self.bridge.continuousRecordingSegmentCount >= 4
        })

        bridge.stopContinuousRecording()
        XCTAssertFalse(bridge.continuousRecording)
        XCTAssertEqual(bridge.continuousRecordingDroppedFrameCount, 0)
        XCTAssertGreaterThanOrEqual(bridge.continuousRecordingSegmentCount, 4)

        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension.lowercased() == "wav" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertEqual(files.count, Int(bridge.continuousRecordingSegmentCount))
        let firstSignalSummary = try WavSignalSummary.read(
            from: try XCTUnwrap(files.first),
            inputChannelCount: 4
        )
        XCTAssertEqual(firstSignalSummary.activeInputChannelCount, 4)
        XCTAssertEqual(firstSignalSummary.activeStreamOutputChannelCount, 2)

        var totalFrames: UInt64 = 0
        for file in files {
            let header = try readWavHeader(from: file)
            XCTAssertEqual(String(data: header.subdata(in: 0..<4), encoding: .ascii), "RIFF")
            XCTAssertEqual(String(data: header.subdata(in: 8..<12), encoding: .ascii), "WAVE")
            XCTAssertEqual(uint16LE(header, at: 20), 3)
            XCTAssertEqual(uint16LE(header, at: 22), 6)
            XCTAssertEqual(uint32LE(header, at: 24), 48_000)
            XCTAssertEqual(uint16LE(header, at: 34), 32)

            let metadata = try WavMetadata.read(from: file)
            XCTAssertGreaterThan(metadata.frameCount, 0)
            XCTAssertLessThanOrEqual(metadata.frameCount, 1_024)
            totalFrames += UInt64(metadata.frameCount)
        }
        XCTAssertEqual(totalFrames, UInt64(bridge.continuousRecordingFrameCount))
    }

    func testRecordingCapturePreservesRawDanteOrderWhenMixerInputMapIsRemapped() throws {
        try bridge.startSimulated(
            withChannelCount: 4,
            sampleRate: 96_000,
            bufferFrameSize: 256,
            channelRoles: simulatedRoles(count: 4),
            inputChannelIndices: [3, 2, 1, 0]
        )

        let firstFrame = bridge.debugCaptureRecordingFirstInputFrame(
            withFrameCount: 16,
            channelsPerBuffer: 4
        ).map(\.doubleValue)

        XCTAssertEqual(firstFrame.count, 4)
        XCTAssertEqual(firstFrame[0], 0.01, accuracy: 0.0001)
        XCTAssertEqual(firstFrame[1], 0.02, accuracy: 0.0001)
        XCTAssertEqual(firstFrame[2], 0.03, accuracy: 0.0001)
        XCTAssertEqual(firstFrame[3], 0.04, accuracy: 0.0001)
    }

    func testCoreAudioInputOverrunPathDoesNotAllocateAfterPrepare() throws {
        try bridge.startSimulated(
            withChannelCount: 64,
            sampleRate: 96_000,
            bufferFrameSize: 256,
            channelRoles: simulatedRoles(count: 64),
            inputChannelIndices: identityInputMap(count: 64)
        )

        XCTAssertTrue(waitUntil(timeout: 2.0) {
            self.bridge.lastCallbackFrameCount == 256
        })

        let dropoutCountBefore = bridge.dropoutCount
        let callbackOverrunCountBefore = bridge.callbackOverrunCount
        let overrunBlocks = UInt(16)

        let interleavedAllocations = bridge.debugRunRealtimeCoreAudioInputNoAllocationProbe(
            withFrameCount: 512,
            blocks: overrunBlocks,
            channelsPerBuffer: 64
        )
        let nonInterleavedAllocations = bridge.debugRunRealtimeCoreAudioInputNoAllocationProbe(
            withFrameCount: 512,
            blocks: overrunBlocks,
            channelsPerBuffer: 1
        )

        XCTAssertEqual(interleavedAllocations, 0)
        XCTAssertEqual(nonInterleavedAllocations, 0)
        XCTAssertGreaterThanOrEqual(bridge.dropoutCount, dropoutCountBefore + (overrunBlocks * 2))
        XCTAssertGreaterThanOrEqual(bridge.callbackOverrunCount, callbackOverrunCountBefore + (overrunBlocks * 2))
        XCTAssertEqual(bridge.maxObservedCallbackFrameCount, 512)
        XCTAssertEqual(bridge.renderDeadlineMissCount, 0)
    }

    func testCoreAudioOutputWriterSilencesExtraMonoBuffers() throws {
        try bridge.startSimulated(
            withChannelCount: 64,
            sampleRate: 96_000,
            bufferFrameSize: 256,
            channelRoles: simulatedRoles(count: 64),
            inputChannelIndices: identityInputMap(count: 64)
        )

        XCTAssertTrue(waitUntil(timeout: 2.0) {
            self.bridge.outputLevelsDb().allSatisfy { $0.doubleValue > -90.0 && $0.doubleValue < -0.1 }
        })

        let buffers = bridge.debugRenderCoreAudioMonoOutputBuffers(
            withFrameCount: 256,
            outputBufferCount: 4
        ).map { $0.map(\.doubleValue) }

        XCTAssertEqual(buffers.count, 4)
        XCTAssertTrue(outputBufferIsActive(buffers[0]))
        XCTAssertTrue(outputBufferIsActive(buffers[1]))
        XCTAssertTrue(outputBufferIsSilent(buffers[2]))
        XCTAssertTrue(outputBufferIsSilent(buffers[3]))
    }

    func testCoreAudioOutputWriterSilencesExtraInterleavedChannels() throws {
        try bridge.startSimulated(
            withChannelCount: 64,
            sampleRate: 96_000,
            bufferFrameSize: 256,
            channelRoles: simulatedRoles(count: 64),
            inputChannelIndices: identityInputMap(count: 64)
        )

        XCTAssertTrue(waitUntil(timeout: 2.0) {
            self.bridge.outputLevelsDb().allSatisfy { $0.doubleValue > -90.0 && $0.doubleValue < -0.1 }
        })

        let channels = bridge.debugRenderCoreAudioInterleavedOutputChannels(
            withFrameCount: 256,
            outputChannelCount: 4
        ).map { $0.map(\.doubleValue) }

        XCTAssertEqual(channels.count, 4)
        XCTAssertTrue(outputBufferIsActive(channels[0]))
        XCTAssertTrue(outputBufferIsActive(channels[1]))
        XCTAssertTrue(outputBufferIsSilent(channels[2]))
        XCTAssertTrue(outputBufferIsSilent(channels[3]))
    }

    func testCoreAudioInputOverrunSilencesOutputAndCountsDropout() throws {
        try bridge.startSimulated(
            withChannelCount: 64,
            sampleRate: 96_000,
            bufferFrameSize: 256,
            channelRoles: simulatedRoles(count: 64),
            inputChannelIndices: identityInputMap(count: 64)
        )

        XCTAssertTrue(waitUntil(timeout: 2.0) {
            self.bridge.outputLevelsDb().allSatisfy { $0.doubleValue > -90.0 && $0.doubleValue < -0.1 }
        })

        let dropoutCountBefore = bridge.dropoutCount
        let callbackOverrunCountBefore = bridge.callbackOverrunCount

        let buffers = bridge.debugRenderCoreAudioMonoOutputBuffers(
            withFrameCount: 512,
            outputBufferCount: 2
        ).map { $0.map(\.doubleValue) }

        XCTAssertEqual(buffers.count, 2)
        XCTAssertEqual(buffers[0].count, 512)
        XCTAssertEqual(buffers[1].count, 512)
        XCTAssertTrue(outputBufferIsSilent(buffers[0]))
        XCTAssertTrue(outputBufferIsSilent(buffers[1]))
        XCTAssertGreaterThanOrEqual(bridge.dropoutCount, dropoutCountBefore + 1)
        XCTAssertGreaterThanOrEqual(bridge.callbackOverrunCount, callbackOverrunCountBefore + 1)
        XCTAssertEqual(bridge.maxObservedCallbackFrameCount, 512)
    }
    #endif

    func testSafeBypassStillPassesStereoStreamAudioInNativeBridge() throws {
        try bridge.startSimulated(
            withChannelCount: 64,
            sampleRate: 96_000,
            bufferFrameSize: 256,
            channelRoles: simulatedRoles(count: 64),
            inputChannelIndices: identityInputMap(count: 64)
        )

        XCTAssertTrue(waitUntil(timeout: 2.0) {
            self.bridge.outputLevelsDb().allSatisfy { $0.doubleValue > -90.0 && $0.doubleValue < -0.1 }
        })

        let normalLevels = bridge.outputLevelsDb().map(\.doubleValue)
        bridge.setSafeBypass(true)

        XCTAssertTrue(waitUntil(timeout: 2.0) {
            self.bridge.outputLevelsDb().allSatisfy { $0.doubleValue > -90.0 && $0.doubleValue < -0.1 }
        })

        let safeLevels = bridge.outputLevelsDb().map(\.doubleValue)
        XCTAssertEqual(safeLevels.count, 2)
        XCTAssertTrue(safeLevels.allSatisfy { $0 > -90.0 && $0 < -0.1 })
        XCTAssertTrue(normalLevels.allSatisfy { $0 > -90.0 && $0 < -0.1 })
        XCTAssertEqual(bridge.dropoutCount, 0)
        XCTAssertFalse(bridge.watchdogSafeActive)
    }

    func testShadowModeStatePersistsAcrossNativeBridgeStart() throws {
        XCTAssertFalse(bridge.shadowModeEnabled)
        bridge.setShadowMode(true)
        XCTAssertTrue(bridge.shadowModeEnabled)

        try bridge.startSimulated(
            withChannelCount: 1,
            sampleRate: 96_000,
            bufferFrameSize: 256,
            channelRoles: [ChannelRole.speech.rawValue],
            inputChannelIndices: [0]
        )
        XCTAssertTrue(waitUntil(timeout: 2.0) {
            self.bridge.lastCallbackFrameCount == 256
        })
        XCTAssertTrue(bridge.shadowModeEnabled)

        bridge.setShadowMode(false)
        XCTAssertFalse(bridge.shadowModeEnabled)
    }

    #if DEBUG
    func testSafeBypassAppliesOnNextRenderWhileBrainIsFrozen() throws {
        try bridge.startSimulated(
            withChannelCount: 64,
            sampleRate: 96_000,
            bufferFrameSize: 256,
            channelRoles: simulatedRoles(count: 64),
            inputChannelIndices: identityInputMap(count: 64)
        )

        XCTAssertTrue(waitUntil(timeout: 2.0) {
            self.bridge.lastCallbackFrameCount == 256
        })

        // Dry scene so the production reverb/delay tail (Worship default) does not mask
        // the muted-channel SAFE precondition below.
        bridge.setSceneName("sermon")

        XCTAssertTrue(bridge.setManualMixOverrideForChannel(
            0,
            faderDb: -120,
            pan: 0,
            overrideFader: true,
            overridePan: false
        ))

        XCTAssertTrue(waitUntil(timeout: 3.0) {
            let buffers = self.bridge.debugRenderCoreAudioMonoOutputBuffers(
                withFrameCount: 256,
                outputBufferCount: 2,
                activeInputChannel: 0,
                warmupBlocks: 8
            ).map { $0.map(\.doubleValue) }
            return buffers.count == 2 &&
                self.outputBufferPeak(buffers[0]) < 0.002 &&
                self.outputBufferPeak(buffers[1]) < 0.002
        })

        bridge.setFrozen(true)
        bridge.setSafeBypass(true)

        let safeBuffers = bridge.debugRenderCoreAudioMonoOutputBuffers(
            withFrameCount: 256,
            outputBufferCount: 2,
            activeInputChannel: 0,
            warmupBlocks: 0
        ).map { $0.map(\.doubleValue) }

        XCTAssertEqual(safeBuffers.count, 2)
        XCTAssertGreaterThan(outputBufferPeak(safeBuffers[0]), 0.01)
        XCTAssertGreaterThan(outputBufferPeak(safeBuffers[1]), 0.01)
        XCTAssertEqual(bridge.dropoutCount, 0)
        XCTAssertEqual(bridge.callbackOverrunCount, 0)
        XCTAssertEqual(bridge.renderDeadlineMissCount, 0)
    }

    func testMetersResetToSilenceAfterStop() throws {
        try bridge.startSimulated(
            withChannelCount: 8,
            sampleRate: 96_000,
            bufferFrameSize: 256,
            channelRoles: simulatedRoles(count: 8),
            inputChannelIndices: identityInputMap(count: 8)
        )
        // Run until at least one input meter is non-silent.
        XCTAssertTrue(waitUntil(timeout: 2.0) {
            self.bridge.inputLevelsDb().contains { $0.doubleValue > -90.0 }
        })

        bridge.stop()

        let inputs = bridge.inputLevelsDb().map(\.doubleValue)
        XCTAssertTrue(inputs.allSatisfy { $0 <= -99.0 },
                      "input meters must reset to silence after stop, got \(inputs)")
        let outputs = bridge.outputLevelsDb().map(\.doubleValue)
        XCTAssertTrue(outputs.allSatisfy { $0 <= -99.0 },
                      "output meters must reset to silence after stop, got \(outputs)")
    }

    func testCoreAudioInputMapRoutesSelectedDanteInputToMixerChannel() throws {
        try bridge.startSimulated(
            withChannelCount: 4,
            sampleRate: 96_000,
            bufferFrameSize: 256,
            channelRoles: simulatedRoles(count: 4),
            inputChannelIndices: [2, 0, 1, 3]
        )

        XCTAssertTrue(waitUntil(timeout: 2.0) {
            self.bridge.lastCallbackFrameCount == 256
        })

        // Dry scene so the production reverb/delay tail (Worship default) does not mask
        // the muted-channel routing precondition below.
        bridge.setSceneName("sermon")

        for mixerChannel in 1..<4 {
            XCTAssertTrue(bridge.setManualMixOverrideForChannel(
                mixerChannel,
                faderDb: -120,
                pan: 0,
                overrideFader: true,
                overridePan: false
            ))
        }

        XCTAssertTrue(waitUntil(timeout: 3.0) {
            let buffers = self.bridge.debugRenderCoreAudioMonoOutputBuffers(
                withFrameCount: 256,
                outputBufferCount: 2,
                activeInputChannel: 0,
                warmupBlocks: 8
            ).map { $0.map(\.doubleValue) }
            return buffers.count == 2 &&
                self.outputBufferPeak(buffers[0]) < 0.002 &&
                self.outputBufferPeak(buffers[1]) < 0.002
        })

        let mappedInputBuffers = bridge.debugRenderCoreAudioMonoOutputBuffers(
            withFrameCount: 256,
            outputBufferCount: 2,
            activeInputChannel: 2,
            warmupBlocks: 8
        ).map { $0.map(\.doubleValue) }

        XCTAssertEqual(mappedInputBuffers.count, 2)
        XCTAssertGreaterThan(outputBufferPeak(mappedInputBuffers[0]), 0.005)
        XCTAssertGreaterThan(outputBufferPeak(mappedInputBuffers[1]), 0.005)
        XCTAssertEqual(bridge.dropoutCount, 0)
        XCTAssertEqual(bridge.callbackOverrunCount, 0)
        XCTAssertEqual(bridge.renderDeadlineMissCount, 0)
    }

    func testInputMetersFollowEditableDanteInputMap() throws {
        try bridge.startSimulated(
            withChannelCount: 4,
            sampleRate: 96_000,
            bufferFrameSize: 256,
            channelRoles: simulatedRoles(count: 4),
            inputChannelIndices: [2, 0, 1, 3]
        )

        XCTAssertTrue(waitUntil(timeout: 2.0) {
            self.bridge.lastCallbackFrameCount == 256
        })

        let levels = bridge.debugRenderCoreAudioInputLevels(
            withFrameCount: 256,
            activeInputChannel: 2
        ).map(\.doubleValue)
        XCTAssertEqual(levels.count, 4)
        XCTAssertGreaterThan(levels[0], -30.0)
        XCTAssertLessThan(levels[1], -90.0)
        XCTAssertLessThan(levels[2], -90.0)
        XCTAssertLessThan(levels[3], -90.0)
        XCTAssertEqual(bridge.dropoutCount, 0)
        XCTAssertEqual(bridge.callbackOverrunCount, 0)
        XCTAssertEqual(bridge.renderDeadlineMissCount, 0)
    }

    func testLiveSourceRoleChangeAffectsNativeBridgeRenderTargets() throws {
        try bridge.startSimulated(
            withChannelCount: 1,
            sampleRate: 96_000,
            bufferFrameSize: 256,
            channelRoles: [ChannelRole.bass.rawValue],
            inputChannelIndices: [0]
        )

        bridge.setSceneName(MixScene.sermon.rawValue)
        XCTAssertTrue(waitUntil(timeout: 2.0) {
            self.bridge.lastCallbackFrameCount == 256
        })
        XCTAssertTrue(waitUntil(timeout: 3.0) {
            self.bridge.autoFaderDb(forChannel: 0) < -15.5
        })
        let bassAutoFaderDb = bridge.autoFaderDb(forChannel: 0)

        let bassBuffers = bridge.debugRenderCoreAudioMonoOutputBuffers(
            withFrameCount: 256,
            outputBufferCount: 2,
            activeInputChannel: 0,
            warmupBlocks: 64
        ).map { $0.map(\.doubleValue) }
        XCTAssertEqual(bassBuffers.count, 2)
        let bassPeak = max(outputBufferPeak(bassBuffers[0]), outputBufferPeak(bassBuffers[1]))
        XCTAssertGreaterThan(bassPeak, 0.001)
        XCTAssertLessThan(bassPeak, 0.05)

        XCTAssertTrue(bridge.setChannelRoleForChannel(0, role: ChannelRole.speech.rawValue))
        XCTAssertTrue(waitUntil(timeout: 3.0) {
            self.bridge.autoFaderDb(forChannel: 0) > -2.0
        })
        let speechAutoFaderDb = bridge.autoFaderDb(forChannel: 0)

        let speechBuffers = bridge.debugRenderCoreAudioMonoOutputBuffers(
            withFrameCount: 256,
            outputBufferCount: 2,
            activeInputChannel: 0,
            warmupBlocks: 64
        ).map { $0.map(\.doubleValue) }
        XCTAssertEqual(speechBuffers.count, 2)
        let speechPeak = max(outputBufferPeak(speechBuffers[0]), outputBufferPeak(speechBuffers[1]))

        XCTAssertGreaterThan(speechPeak, 0.01)
        XCTAssertGreaterThan(speechAutoFaderDb - bassAutoFaderDb, 12.0)
        XCTAssertGreaterThan(speechPeak, bassPeak * 2.0)
        XCTAssertEqual(bridge.dropoutCount, 0)
        XCTAssertEqual(bridge.callbackOverrunCount, 0)
        XCTAssertEqual(bridge.renderDeadlineMissCount, 0)
    }

    func testManualFaderPanOverrideAffectsNativeBridgeRender() throws {
        try bridge.startSimulated(
            withChannelCount: 1,
            sampleRate: 96_000,
            bufferFrameSize: 256,
            channelRoles: [ChannelRole.keys.rawValue],
            inputChannelIndices: [0]
        )

        XCTAssertTrue(waitUntil(timeout: 2.0) {
            self.bridge.lastCallbackFrameCount == 256
        })

        XCTAssertTrue(bridge.setManualMixOverrideForChannel(
            0,
            faderDb: 0,
            pan: 1,
            overrideFader: true,
            overridePan: true
        ))

        XCTAssertTrue(waitUntil(timeout: 2.0) {
            let buffers = self.bridge.debugRenderCoreAudioMonoOutputBuffers(
                withFrameCount: 256,
                outputBufferCount: 2,
                activeInputChannel: 0,
                warmupBlocks: 64
            ).map { $0.map(\.doubleValue) }
            guard buffers.count == 2 else { return false }
            let leftPeak = self.outputBufferPeak(buffers[0])
            let rightPeak = self.outputBufferPeak(buffers[1])
            return rightPeak > 0.01 && rightPeak > leftPeak * 3.0
        })

        XCTAssertTrue(bridge.setManualMixOverrideForChannel(
            0,
            faderDb: -80,
            pan: 1,
            overrideFader: true,
            overridePan: true
        ))

        XCTAssertTrue(waitUntil(timeout: 2.0) {
            let buffers = self.bridge.debugRenderCoreAudioMonoOutputBuffers(
                withFrameCount: 256,
                outputBufferCount: 2,
                activeInputChannel: 0,
                warmupBlocks: 64
            ).map { $0.map(\.doubleValue) }
            return buffers.count == 2 &&
                self.outputBufferPeak(buffers[0]) < 0.001 &&
                self.outputBufferPeak(buffers[1]) < 0.001
        })

        XCTAssertTrue(bridge.clearManualMixOverride(forChannel: 0))
        XCTAssertTrue(waitUntil(timeout: 2.0) {
            let buffers = self.bridge.debugRenderCoreAudioMonoOutputBuffers(
                withFrameCount: 256,
                outputBufferCount: 2,
                activeInputChannel: 0,
                warmupBlocks: 64
            ).map { $0.map(\.doubleValue) }
            return buffers.count == 2 &&
                max(self.outputBufferPeak(buffers[0]), self.outputBufferPeak(buffers[1])) > 0.005
        })

        XCTAssertEqual(bridge.dropoutCount, 0)
        XCTAssertEqual(bridge.callbackOverrunCount, 0)
        XCTAssertEqual(bridge.renderDeadlineMissCount, 0)
    }

    func testSceneChangeAffectsNativeBridgeRenderTargets() throws {
        try bridge.startSimulated(
            withChannelCount: 1,
            sampleRate: 96_000,
            bufferFrameSize: 256,
            channelRoles: [ChannelRole.bass.rawValue],
            inputChannelIndices: [0]
        )

        XCTAssertTrue(waitUntil(timeout: 2.0) {
            self.bridge.lastCallbackFrameCount == 256
        })

        bridge.setSceneName(MixScene.worship.rawValue)
        var worshipPeak = 0.0
        XCTAssertTrue(waitUntil(timeout: 2.0) {
            let buffers = self.bridge.debugRenderCoreAudioMonoOutputBuffers(
                withFrameCount: 256,
                outputBufferCount: 2,
                activeInputChannel: 0,
                warmupBlocks: 64
            ).map { $0.map(\.doubleValue) }
            guard buffers.count == 2 else { return false }
            worshipPeak = max(self.outputBufferPeak(buffers[0]), self.outputBufferPeak(buffers[1]))
            return worshipPeak > 0.01
        })

        bridge.setSceneName(MixScene.sermon.rawValue)
        var sermonPeak = worshipPeak
        XCTAssertTrue(waitUntil(timeout: 2.0) {
            let buffers = self.bridge.debugRenderCoreAudioMonoOutputBuffers(
                withFrameCount: 256,
                outputBufferCount: 2,
                activeInputChannel: 0,
                warmupBlocks: 64
            ).map { $0.map(\.doubleValue) }
            guard buffers.count == 2 else { return false }
            sermonPeak = max(self.outputBufferPeak(buffers[0]), self.outputBufferPeak(buffers[1]))
            return sermonPeak > 0.0 && sermonPeak < worshipPeak * 0.55
        })

        XCTAssertLessThan(sermonPeak, worshipPeak * 0.55)
        XCTAssertEqual(bridge.dropoutCount, 0)
        XCTAssertEqual(bridge.callbackOverrunCount, 0)
        XCTAssertEqual(bridge.renderDeadlineMissCount, 0)
    }

    func testWatchdogSafeActivatesThroughNativeBridgeRenderPath() throws {
        try bridge.startSimulated(
            withChannelCount: 1,
            sampleRate: 96_000,
            bufferFrameSize: 256,
            channelRoles: [ChannelRole.bass.rawValue],
            inputChannelIndices: [0]
        )

        XCTAssertTrue(waitUntil(timeout: 2.0) {
            self.bridge.lastCallbackFrameCount == 256
        })

        XCTAssertTrue(bridge.setManualMixOverrideForChannel(
            0,
            faderDb: -80,
            pan: 0,
            overrideFader: true,
            overridePan: false
        ))

        XCTAssertTrue(waitUntil(timeout: 2.0) {
            let buffers = self.bridge.debugRenderCoreAudioMonoOutputBuffers(
                withFrameCount: 256,
                outputBufferCount: 2,
                activeInputChannel: 0,
                warmupBlocks: 64
            ).map { $0.map(\.doubleValue) }
            return buffers.count == 2 &&
                self.outputBufferPeak(buffers[0]) < 0.001 &&
                self.outputBufferPeak(buffers[1]) < 0.001
        })

        bridge.debugSetBrainTickPaused(forWatchdogProbe: true)
        defer { bridge.debugSetBrainTickPaused(forWatchdogProbe: false) }

        XCTAssertTrue(waitUntil(timeout: 2.0) {
            let buffers = self.bridge.debugRenderCoreAudioMonoOutputBuffers(
                withFrameCount: 256,
                outputBufferCount: 2,
                activeInputChannel: 0,
                warmupBlocks: 0
            ).map { $0.map(\.doubleValue) }
            return buffers.count == 2 &&
                self.bridge.watchdogSafeActive &&
                self.outputBufferPeak(buffers[0]) > 0.01 &&
                self.outputBufferPeak(buffers[1]) > 0.01
        })

        XCTAssertTrue(bridge.watchdogSafeActive)
        XCTAssertEqual(bridge.dropoutCount, 0)
        XCTAssertEqual(bridge.callbackOverrunCount, 0)
        XCTAssertEqual(bridge.renderDeadlineMissCount, 0)
    }
    #endif

    func testFreezeStillPassesStereoStreamAudioInNativeBridge() throws {
        try bridge.startSimulated(
            withChannelCount: 64,
            sampleRate: 96_000,
            bufferFrameSize: 256,
            channelRoles: simulatedRoles(count: 64),
            inputChannelIndices: identityInputMap(count: 64)
        )

        XCTAssertTrue(waitUntil(timeout: 2.0) {
            self.bridge.outputLevelsDb().allSatisfy { $0.doubleValue > -90.0 && $0.doubleValue < -0.1 }
        })

        bridge.setFrozen(true)

        XCTAssertTrue(waitUntil(timeout: 2.0) {
            self.bridge.outputLevelsDb().allSatisfy { $0.doubleValue > -90.0 && $0.doubleValue < -0.1 }
        })

        let frozenLevels = bridge.outputLevelsDb().map(\.doubleValue)
        XCTAssertEqual(frozenLevels.count, 2)
        XCTAssertTrue(frozenLevels.allSatisfy { $0 > -90.0 && $0 < -0.1 })
        XCTAssertEqual(bridge.dropoutCount, 0)
        XCTAssertFalse(bridge.watchdogSafeActive)
    }

    func testSimulatedSeparateOutputPathRunsWithoutAggregateDevice() throws {
        try bridge.startSimulatedSeparateOutput(
            withChannelCount: 64,
            sampleRate: 96_000,
            inputBufferFrameSize: 256,
            outputBufferFrameSize: 256,
            channelRoles: simulatedRoles(count: 64),
            inputChannelIndices: identityInputMap(count: 64)
        )

        XCTAssertTrue(bridge.running)
        XCTAssertTrue(bridge.status.contains("separate output"))
        XCTAssertEqual(bridge.inputChannelCount, 64)
        XCTAssertEqual(bridge.sampleRate, 96_000, accuracy: 0.5)

        XCTAssertTrue(waitUntil(timeout: 2.0) {
            self.bridge.lastCallbackFrameCount > 0 &&
                self.bridge.inputLevelsDb().prefix(8).contains { $0.doubleValue > -90.0 }
        })
        Thread.sleep(forTimeInterval: 0.12)
        _ = bridge.inputLevelsDb()

        XCTAssertGreaterThan(bridge.separateOutputRingFillFrames, 0)
        XCTAssertLessThanOrEqual(abs(bridge.outputClockCorrectionPpm), 1_000.1)
        XCTAssertGreaterThanOrEqual(bridge.inputCallbackAgeMs, 0)
        XCTAssertGreaterThanOrEqual(bridge.outputCallbackAgeMs, 0)
        XCTAssertEqual(bridge.outputUnderrunCount, 0)
        XCTAssertEqual(bridge.dropoutCount, 0)
    }

    func testSeparateOutputWriterSilencesExtraInterleavedChannels() throws {
        try bridge.startSimulatedSeparateOutput(
            withChannelCount: 64,
            sampleRate: 96_000,
            inputBufferFrameSize: 256,
            outputBufferFrameSize: 256,
            channelRoles: simulatedRoles(count: 64),
            inputChannelIndices: identityInputMap(count: 64)
        )

        XCTAssertTrue(waitUntil(timeout: 2.0) {
            self.bridge.lastCallbackFrameCount > 0 &&
                self.bridge.inputLevelsDb().prefix(8).contains { $0.doubleValue > -90.0 }
        })

        let channels = bridge.debugRenderSeparateCoreAudioInterleavedOutputChannels(
            withFrameCount: 256,
            outputChannelCount: 4,
            warmupBlocks: 32
        ).map { $0.map(\.doubleValue) }

        XCTAssertEqual(channels.count, 4)
        XCTAssertTrue(outputBufferIsActive(channels[0]))
        XCTAssertTrue(outputBufferIsActive(channels[1]))
        XCTAssertTrue(outputBufferIsSilent(channels[2]))
        XCTAssertTrue(outputBufferIsSilent(channels[3]))
    }

    func testChannelCountStateLabelsExpectedHD96MismatchClearly() {
        XCTAssertEqual(ChannelCountState.unknown(expected: 64).label, "Expected 64, device unknown")
        XCTAssertFalse(ChannelCountState.unknown(expected: 64).isWarning)

        XCTAssertEqual(ChannelCountState.ready(actual: 64).label, "64 channels ready")
        XCTAssertFalse(ChannelCountState.ready(actual: 64).isWarning)

        XCTAssertEqual(ChannelCountState.mismatch(expected: 64, actual: 32).label, "Expected 64, got 32")
        XCTAssertTrue(ChannelCountState.mismatch(expected: 64, actual: 32).isWarning)
    }

    func testHD96PreflightPassesSimulatedDanteRoute() {
        let device = AMDeviceInfo(
            uid: "com.livedaw.automix.simulated-hd96-dante",
            name: "Simulated HD96 Dante Split",
            inputChannels: 64,
            outputChannels: 2,
            sampleRate: 96_000
        )

        let report = HD96PreflightReport.make(
            inputDevice: device,
            outputDevice: device,
            expectedInputChannels: 64,
            detectedInputChannels: 64,
            detectedSampleRate: 96_000
        )

        XCTAssertEqual(report.summary, "HD96 route ready")
        XCTAssertTrue(report.isReady)
        XCTAssertTrue(report.checks.allSatisfy(\.passed))
    }

    func testHD96PreflightTreatsDanteNameAsAdvisoryForAggregateDevices() throws {
        let input = AMDeviceInfo(
            uid: "aggregate.broadcast.input",
            name: "Broadcast Aggregate Input",
            inputChannels: 64,
            outputChannels: 0,
            sampleRate: 96_000
        )
        let output = AMDeviceInfo(
            uid: "aggregate.broadcast.output",
            name: "Broadcast Aggregate Output",
            inputChannels: 0,
            outputChannels: 2,
            sampleRate: 96_000
        )

        let report = HD96PreflightReport.make(
            inputDevice: input,
            outputDevice: output,
            expectedInputChannels: 64,
            detectedInputChannels: 64,
            detectedSampleRate: 96_000
        )

        XCTAssertEqual(report.summary, "HD96 route ready with notes")
        XCTAssertTrue(report.isReady)
        XCTAssertFalse(try XCTUnwrap(report.checks.first { $0.name == "Dante Route" }).passed)
        XCTAssertFalse(try XCTUnwrap(report.checks.first { $0.name == "Dante Route" }).blocking)
    }

    func testHD96PreflightBlocksWhenOutputSharesDanteInputRoute() throws {
        let danteDevice = AMDeviceInfo(
            uid: "com.audinate.dantevirtualsoundcard",
            name: "Dante Virtual Soundcard",
            inputChannels: 64,
            outputChannels: 2,
            sampleRate: 96_000
        )

        let report = HD96PreflightReport.make(
            inputDevice: danteDevice,
            outputDevice: danteDevice,
            expectedInputChannels: 64,
            detectedInputChannels: 64,
            detectedSampleRate: 96_000
        )

        let isolationCheck = try XCTUnwrap(report.checks.first { $0.name == "Output Isolation" })
        XCTAssertEqual(report.summary, "HD96 route not ready")
        XCTAssertFalse(report.isReady)
        XCTAssertFalse(isolationCheck.passed)
        XCTAssertTrue(isolationCheck.blocking)
        XCTAssertTrue(isolationCheck.observed.localizedCaseInsensitiveContains("same Core Audio device"))
        XCTAssertTrue(isolationCheck.observed.localizedCaseInsensitiveContains("Dante"))
    }

    func testHD96PreflightAcceptsSingleAggregateStreamRoute() throws {
        let aggregate = AMDeviceInfo(
            uid: "aggregate.broadcast.route",
            name: "Broadcast Aggregate Device",
            inputChannels: 64,
            outputChannels: 2,
            sampleRate: 96_000
        )

        let report = HD96PreflightReport.make(
            inputDevice: aggregate,
            outputDevice: aggregate,
            expectedInputChannels: 64,
            detectedInputChannels: 64,
            detectedSampleRate: 96_000
        )

        let isolationCheck = try XCTUnwrap(report.checks.first { $0.name == "Output Isolation" })
        XCTAssertEqual(report.summary, "HD96 route ready with notes")
        XCTAssertTrue(report.isReady)
        XCTAssertTrue(isolationCheck.passed)
        XCTAssertTrue(isolationCheck.blocking)
        XCTAssertTrue(isolationCheck.observed.localizedCaseInsensitiveContains("aggregate"))
    }

    func testHD96PreflightAcceptsDedicatedStreamOutputRoute() throws {
        let input = AMDeviceInfo(
            uid: "com.audinate.dantevirtualsoundcard.input",
            name: "Dante Virtual Soundcard",
            inputChannels: 64,
            outputChannels: 0,
            sampleRate: 96_000
        )
        let output = AMDeviceInfo(
            uid: "com.local.stream.encoder",
            name: "Stream Encoder Output",
            inputChannels: 0,
            outputChannels: 2,
            sampleRate: 96_000
        )

        let report = HD96PreflightReport.make(
            inputDevice: input,
            outputDevice: output,
            expectedInputChannels: 64,
            detectedInputChannels: 64,
            detectedSampleRate: 96_000
        )

        let isolationCheck = try XCTUnwrap(report.checks.first { $0.name == "Output Isolation" })
        XCTAssertEqual(report.summary, "HD96 route ready")
        XCTAssertTrue(report.isReady)
        XCTAssertTrue(isolationCheck.passed)
        XCTAssertTrue(isolationCheck.blocking)
        XCTAssertTrue(isolationCheck.observed.localizedCaseInsensitiveContains("stream"))
    }

    func testHD96PreflightBlocksGenericLocalOutputRoute() throws {
        let input = AMDeviceInfo(
            uid: "com.audinate.dantevirtualsoundcard.input",
            name: "Dante Virtual Soundcard",
            inputChannels: 64,
            outputChannels: 0,
            sampleRate: 96_000
        )
        let output = AMDeviceInfo(
            uid: "com.apple.built-in-output",
            name: "MacBook Pro Speakers",
            inputChannels: 0,
            outputChannels: 2,
            sampleRate: 96_000
        )

        let report = HD96PreflightReport.make(
            inputDevice: input,
            outputDevice: output,
            expectedInputChannels: 64,
            detectedInputChannels: 64,
            detectedSampleRate: 96_000
        )

        let isolationCheck = try XCTUnwrap(report.checks.first { $0.name == "Output Isolation" })
        XCTAssertEqual(report.summary, "HD96 route not ready")
        XCTAssertFalse(report.isReady)
        XCTAssertFalse(isolationCheck.passed)
        XCTAssertTrue(isolationCheck.blocking)
        XCTAssertTrue(isolationCheck.observed.localizedCaseInsensitiveContains("not identified as a stream"))
    }

    func testHD96PreflightPassesOneToOneInputMapWhenProvided() throws {
        let input = AMDeviceInfo(
            uid: "com.audinate.dantevirtualsoundcard.input",
            name: "Dante Virtual Soundcard",
            inputChannels: 64,
            outputChannels: 0,
            sampleRate: 96_000
        )
        let output = AMDeviceInfo(
            uid: "stream.encoder.output",
            name: "Stream Encoder Output",
            inputChannels: 0,
            outputChannels: 2,
            sampleRate: 96_000
        )

        let report = HD96PreflightReport.make(
            inputDevice: input,
            outputDevice: output,
            expectedInputChannels: 64,
            detectedInputChannels: 64,
            detectedSampleRate: 96_000,
            channelMappings: simulatedMappings(count: 64)
        )

        let mapCheck = try XCTUnwrap(report.checks.first { $0.name == "Input Map Coverage" })
        XCTAssertEqual(report.summary, "HD96 route ready")
        XCTAssertTrue(report.isReady)
        XCTAssertTrue(mapCheck.passed)
        XCTAssertTrue(mapCheck.blocking)
        XCTAssertEqual(mapCheck.observed, "64/64 Dante inputs mapped once")
    }

    func testHD96PreflightBlocksDuplicateDanteInputMap() throws {
        let input = AMDeviceInfo(
            uid: "com.audinate.dantevirtualsoundcard.input",
            name: "Dante Virtual Soundcard",
            inputChannels: 64,
            outputChannels: 0,
            sampleRate: 96_000
        )
        let output = AMDeviceInfo(
            uid: "stream.encoder.output",
            name: "Stream Encoder Output",
            inputChannels: 0,
            outputChannels: 2,
            sampleRate: 96_000
        )
        var mappings = simulatedMappings(count: 64)
        mappings[1].inputChannelIndex = 0

        let report = HD96PreflightReport.make(
            inputDevice: input,
            outputDevice: output,
            expectedInputChannels: 64,
            detectedInputChannels: 64,
            detectedSampleRate: 96_000,
            channelMappings: mappings
        )

        let mapCheck = try XCTUnwrap(report.checks.first { $0.name == "Input Map Coverage" })
        XCTAssertEqual(report.summary, "HD96 route not ready")
        XCTAssertFalse(report.isReady)
        XCTAssertFalse(mapCheck.passed)
        XCTAssertTrue(mapCheck.blocking)
        XCTAssertTrue(mapCheck.observed.localizedCaseInsensitiveContains("duplicate Dante In 1"))
        XCTAssertTrue(mapCheck.observed.localizedCaseInsensitiveContains("missing Dante In 2"))
    }

    func testHD96PreflightBlocksDuplicateMixerRows() throws {
        let input = AMDeviceInfo(
            uid: "com.audinate.dantevirtualsoundcard.input",
            name: "Dante Virtual Soundcard",
            inputChannels: 4,
            outputChannels: 0,
            sampleRate: 96_000
        )
        let output = AMDeviceInfo(
            uid: "stream.encoder.output",
            name: "Stream Encoder Output",
            inputChannels: 0,
            outputChannels: 2,
            sampleRate: 96_000
        )
        var mappings = simulatedMappings(count: 4)
        mappings[1].index = 0

        let report = HD96PreflightReport.make(
            inputDevice: input,
            outputDevice: output,
            expectedInputChannels: 4,
            detectedInputChannels: 4,
            detectedSampleRate: 96_000,
            channelMappings: mappings
        )

        let mapCheck = try XCTUnwrap(report.checks.first { $0.name == "Input Map Coverage" })
        XCTAssertEqual(report.summary, "HD96 route not ready")
        XCTAssertFalse(report.isReady)
        XCTAssertFalse(mapCheck.passed)
        XCTAssertTrue(mapCheck.blocking)
        XCTAssertTrue(mapCheck.observed.localizedCaseInsensitiveContains("duplicate Mix Ch 1"))
        XCTAssertTrue(mapCheck.observed.localizedCaseInsensitiveContains("missing Mix Ch 2"))
    }

    func testHD96PreflightBlocksAllUnknownSourceRoles() throws {
        let input = AMDeviceInfo(
            uid: "com.audinate.dantevirtualsoundcard.input",
            name: "Dante Virtual Soundcard",
            inputChannels: 64,
            outputChannels: 0,
            sampleRate: 96_000
        )
        let output = AMDeviceInfo(
            uid: "stream.encoder.output",
            name: "Stream Encoder Output",
            inputChannels: 0,
            outputChannels: 2,
            sampleRate: 96_000
        )

        let report = HD96PreflightReport.make(
            inputDevice: input,
            outputDevice: output,
            expectedInputChannels: 64,
            detectedInputChannels: 64,
            detectedSampleRate: 96_000,
            channelMappings: ChannelMapping.defaults(count: 64)
        )

        let rolesCheck = try XCTUnwrap(report.checks.first { $0.name == "Source Roles" })
        XCTAssertEqual(report.summary, "HD96 route not ready")
        XCTAssertFalse(report.isReady)
        XCTAssertFalse(rolesCheck.passed)
        XCTAssertTrue(rolesCheck.blocking)
        XCTAssertTrue(rolesCheck.observed.localizedCaseInsensitiveContains("set source roles"))
    }

    func testEngineStartGateBlocksUnsafeDanteOutputRoute() throws {
        let danteDevice = AMDeviceInfo(
            uid: "com.audinate.dantevirtualsoundcard",
            name: "Dante Virtual Soundcard",
            inputChannels: 64,
            outputChannels: 2,
            sampleRate: 96_000
        )

        let preflight = HD96PreflightReport.make(
            inputDevice: danteDevice,
            outputDevice: danteDevice,
            expectedInputChannels: 64,
            detectedInputChannels: 64,
            detectedSampleRate: 96_000,
            channelMappings: simulatedMappings(count: 64)
        )
        let gate = HD96EngineStartGate.make(from: preflight)

        XCTAssertFalse(gate.isAllowed)
        XCTAssertEqual(gate.failedChecks.map(\.name), ["Output Isolation"])
        XCTAssertTrue(gate.failureMessage.localizedCaseInsensitiveContains("same Core Audio device"))
    }

    func testEngineStartGateBlocksDuplicateDanteInputMap() throws {
        let input = AMDeviceInfo(
            uid: "com.audinate.dantevirtualsoundcard.input",
            name: "Dante Virtual Soundcard",
            inputChannels: 64,
            outputChannels: 0,
            sampleRate: 96_000
        )
        let output = AMDeviceInfo(
            uid: "stream.encoder.output",
            name: "Stream Encoder Output",
            inputChannels: 0,
            outputChannels: 2,
            sampleRate: 96_000
        )
        var mappings = simulatedMappings(count: 64)
        mappings[1].inputChannelIndex = 0

        let preflight = HD96PreflightReport.make(
            inputDevice: input,
            outputDevice: output,
            expectedInputChannels: 64,
            detectedInputChannels: 64,
            detectedSampleRate: 96_000,
            channelMappings: mappings
        )
        let gate = HD96EngineStartGate.make(from: preflight)

        XCTAssertFalse(gate.isAllowed)
        XCTAssertEqual(gate.failedChecks.map(\.name), ["Input Map Coverage"])
        XCTAssertTrue(gate.failureMessage.localizedCaseInsensitiveContains("duplicate Dante In 1"))
        XCTAssertTrue(gate.failureMessage.localizedCaseInsensitiveContains("missing Dante In 2"))
    }

    func testEngineStartGateAllowsUnknownRolesForInitialMetering() throws {
        let input = AMDeviceInfo(
            uid: "com.audinate.dantevirtualsoundcard.input",
            name: "Dante Virtual Soundcard",
            inputChannels: 64,
            outputChannels: 0,
            sampleRate: 96_000
        )
        let output = AMDeviceInfo(
            uid: "stream.encoder.output",
            name: "Stream Encoder Output",
            inputChannels: 0,
            outputChannels: 2,
            sampleRate: 96_000
        )

        let preflight = HD96PreflightReport.make(
            inputDevice: input,
            outputDevice: output,
            expectedInputChannels: 64,
            detectedInputChannels: 64,
            detectedSampleRate: 96_000,
            channelMappings: ChannelMapping.defaults(count: 64)
        )
        let gate = HD96EngineStartGate.make(from: preflight)

        XCTAssertFalse(preflight.isReady)
        XCTAssertEqual(preflight.checks.first { $0.name == "Source Roles" }?.passed, false)
        XCTAssertTrue(gate.isAllowed)
    }

    func testHD96PreflightFlagsBlockingRouteProblems() {
        let input = AMDeviceInfo(
            uid: "dante.bad.input",
            name: "Dante Virtual Soundcard",
            inputChannels: 32,
            outputChannels: 0,
            sampleRate: 48_000
        )
        let output = AMDeviceInfo(
            uid: "stream.output",
            name: "Stream Output",
            inputChannels: 0,
            outputChannels: 1,
            sampleRate: 96_000
        )

        let report = HD96PreflightReport.make(
            inputDevice: input,
            outputDevice: output,
            expectedInputChannels: 64,
            detectedInputChannels: 32,
            detectedSampleRate: 48_000
        )

        XCTAssertEqual(report.summary, "HD96 route not ready")
        XCTAssertFalse(report.isReady)
        XCTAssertEqual(Set(report.checks.filter { !$0.passed && $0.blocking }.map(\.name)), [
            "Sample Rate",
            "Input Channels",
            "Stream Output",
            "Route Clock"
        ])
    }

    func testHD96PreflightBlocksUnsupportedCoreAudioFormat() throws {
        let input = AMDeviceInfo(
            uid: "dante.input",
            name: "Dante Virtual Soundcard",
            inputChannels: 64,
            outputChannels: 0,
            sampleRate: 96_000,
            inputFormatSummary: "lpcm signed-int 24-bit",
            outputFormatSummary: "no output streams",
            inputFormatSupported: false,
            outputFormatSupported: false
        )
        let output = AMDeviceInfo(
            uid: "stream.output",
            name: "Stream Output",
            inputChannels: 0,
            outputChannels: 2,
            sampleRate: 96_000,
            inputFormatSummary: "no input streams",
            outputFormatSummary: "32-bit little-endian float PCM",
            inputFormatSupported: false,
            outputFormatSupported: true
        )

        let report = HD96PreflightReport.make(
            inputDevice: input,
            outputDevice: output,
            expectedInputChannels: 64,
            detectedInputChannels: 64,
            detectedSampleRate: 96_000
        )

        let formatCheck = try XCTUnwrap(report.checks.first { $0.name == "Core Audio Format" })
        XCTAssertFalse(report.isReady)
        XCTAssertFalse(formatCheck.passed)
        XCTAssertTrue(formatCheck.blocking)
        XCTAssertTrue(formatCheck.observed.localizedCaseInsensitiveContains("signed-int"))
    }

    func testRunningRouteHealthPassesCleanHD96Route() {
        let input = AMDeviceInfo(
            uid: "dante.input",
            name: "Dante Virtual Soundcard",
            inputChannels: 64,
            outputChannels: 0,
            sampleRate: 96_000
        )
        let output = AMDeviceInfo(
            uid: "stream.output",
            name: "Stream Encoder Output",
            inputChannels: 0,
            outputChannels: 2,
            sampleRate: 96_000
        )

        let health = HD96RunningRouteHealth.make(
            inputDevice: input,
            outputDevice: output,
            expectedInputChannels: 64,
            detectedInputChannels: 64,
            detectedSampleRate: 96_000
        )

        XCTAssertTrue(health.isReady)
        XCTAssertEqual(health.warningMessage, "")
    }

    func testRunningRouteHealthWarnsForClockChannelFormatAndOutputProblems() {
        let input = AMDeviceInfo(
            uid: "dante.input",
            name: "Dante Virtual Soundcard",
            inputChannels: 32,
            outputChannels: 0,
            sampleRate: 48_000,
            inputFormatSummary: "lpcm signed-int 24-bit",
            outputFormatSummary: "no output streams",
            inputFormatSupported: false,
            outputFormatSupported: false
        )
        let output = AMDeviceInfo(
            uid: "foh.return",
            name: "Midas HD96 Dante Return",
            inputChannels: 0,
            outputChannels: 2,
            sampleRate: 48_000
        )

        let health = HD96RunningRouteHealth.make(
            inputDevice: input,
            outputDevice: output,
            expectedInputChannels: 64,
            detectedInputChannels: 32,
            detectedSampleRate: 48_000
        )

        XCTAssertFalse(health.isReady)
        XCTAssertEqual(Set(health.failedChecks.map(\.name)), [
            "Sample Rate",
            "Input Channels",
            "Output Isolation",
            "Core Audio Format"
        ])
        XCTAssertTrue(health.warningMessage.hasPrefix("Running Core Audio route warning:"))
        XCTAssertTrue(health.warningMessage.localizedCaseInsensitiveContains("48000 Hz"))
        XCTAssertTrue(health.warningMessage.localizedCaseInsensitiveContains("Input Channels: 32"))
        XCTAssertTrue(health.warningMessage.localizedCaseInsensitiveContains("signed-int"))
        XCTAssertTrue(health.warningMessage.localizedCaseInsensitiveContains("Midas HD96"))
    }

    func testVenueProfileDefaultsExpectedInputChannelsForOlderProfiles() throws {
        let data = Data("""
        {
          "inputDeviceUID": "input",
          "outputDeviceUID": "output",
          "scene": "worship",
          "channelMappings": [
            { "index": 0, "name": "Ch 1", "role": "speech" }
          ]
        }
        """.utf8)

        let profile = try JSONDecoder().decode(VenueProfile.self, from: data)
        XCTAssertEqual(profile.expectedInputChannels, 64)
        XCTAssertEqual(profile.expectedSampleRate, 96_000)
        XCTAssertTrue(profile.shadowMode)
        XCTAssertEqual(profile.measuredEndToEndAudioLatencyMs, 0)
        XCTAssertEqual(profile.measuredEndToEndVideoLatencyMs, 0)
        XCTAssertEqual(profile.encoderHealthURL, "")
        XCTAssertEqual(profile.egressHealthURL, "")
        XCTAssertEqual(profile.planningCenterServiceTypeID, "")
        XCTAssertFalse(profile.planningCenterFollowTimedCues)
        XCTAssertEqual(profile.channelMappings.first?.inputChannelIndex, 0)
        XCTAssertEqual(profile.channelMappings.first?.faderOverrideEnabled, false)
        XCTAssertEqual(profile.channelMappings.first?.panOverrideEnabled, false)
    }

    func testVenueProfilePersistsDanteInputToMixerChannelMap() throws {
        let profile = VenueProfile(
            inputDeviceUID: "input",
            outputDeviceUID: "output",
            shadowMode: false,
            measuredEndToEndAudioLatencyMs: 37.5,
            measuredEndToEndVideoLatencyMs: 55.0,
            encoderHealthURL: "http://127.0.0.1:9000/health",
            egressHealthURL: "https://status.example.test/live",
            planningCenterServiceTypeID: "12345",
            planningCenterFollowTimedCues: true,
            expectedInputChannels: 64,
            channelMappings: [
                ChannelMapping(
                    index: 0,
                    inputChannelIndex: 7,
                    name: "Lead",
                    role: .leadVocal,
                    faderOverrideEnabled: true,
                    faderDb: -11.5,
                    panOverrideEnabled: true,
                    pan: -0.35
                ),
                ChannelMapping(index: 1, inputChannelIndex: 3, name: "Pastor", role: .speech)
            ]
        )

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(VenueProfile.self, from: data)

        XCTAssertEqual(decoded.channelMappings.map(\.index), [0, 1])
        XCTAssertEqual(decoded.channelMappings.map(\.inputChannelIndex), [7, 3])
        XCTAssertEqual(decoded.channelMappings.map(\.role), [.leadVocal, .speech])
        XCTAssertEqual(decoded.channelMappings[0].faderOverrideEnabled, true)
        XCTAssertEqual(decoded.channelMappings[0].faderDb, -11.5)
        XCTAssertEqual(decoded.channelMappings[0].panOverrideEnabled, true)
        XCTAssertEqual(decoded.channelMappings[0].pan, -0.35)
        XCTAssertFalse(decoded.shadowMode)
        XCTAssertEqual(decoded.measuredEndToEndAudioLatencyMs, 37.5)
        XCTAssertEqual(decoded.measuredEndToEndVideoLatencyMs, 55.0)
        XCTAssertEqual(decoded.encoderHealthURL, "http://127.0.0.1:9000/health")
        XCTAssertEqual(decoded.egressHealthURL, "https://status.example.test/live")
        XCTAssertEqual(decoded.planningCenterServiceTypeID, "12345")
        XCTAssertTrue(decoded.planningCenterFollowTimedCues)
    }

    func testPlanningCenterMapperBuildsOrderedTimedSceneCues() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-27T15:00:00Z"))
        let items: [[String: Any]] = [
            [
                "id": "item-sermon",
                "attributes": ["title": "Sunday Message", "item_type": "item", "sequence": 30],
                "relationships": ["item_times": ["data": [["id": "time-sermon"]]]]
            ],
            [
                "id": "item-song",
                "attributes": ["title": "Opening Song", "item_type": "song", "sequence": 20],
                "relationships": ["item_times": ["data": [["id": "time-song-old"], ["id": "time-song"]]]]
            ],
            [
                "id": "item-note",
                "attributes": ["title": "Volunteer note", "item_type": "item", "sequence": 10]
            ]
        ]
        let included: [[String: Any]] = [
            ["id": "time-song-old", "attributes": ["live_start_at": "2026-07-27T09:00:00Z"]],
            ["id": "time-song", "attributes": ["live_start_at": "2026-07-27T14:55:00Z"]],
            ["id": "time-sermon", "attributes": ["live_start_at": "2026-07-27T15:20:00Z"]]
        ]

        let cues = PlanningCenterSceneMapper.cues(
            itemResources: items,
            includedResources: included,
            now: now
        )

        XCTAssertEqual(cues.map(\.id), ["item-song", "item-sermon"])
        XCTAssertEqual(cues.map(\.scene), [.worship, .sermon])
        XCTAssertEqual(cues[0].startsAt, ISO8601DateFormatter().date(from: "2026-07-27T14:55:00Z"))
        XCTAssertEqual(cues[1].sequence, 30)
    }

    func testPlanningCenterSceneMapperCoversServiceVocabulary() {
        XCTAssertEqual(PlanningCenterSceneMapper.scene(title: "Countdown"), .preService)
        XCTAssertEqual(PlanningCenterSceneMapper.scene(title: "Great Is Thy Faithfulness", itemType: "song"), .worship)
        XCTAssertEqual(PlanningCenterSceneMapper.scene(title: "Bible Reading"), .sermon)
        XCTAssertEqual(PlanningCenterSceneMapper.scene(title: "Prayer and Response"), .prayer)
        XCTAssertEqual(PlanningCenterSceneMapper.scene(title: "Walk-Out Music"), .postService)
        XCTAssertEqual(
            PlanningCenterSceneMapper.scene(
                title: "Instrumental",
                itemType: "song",
                servicePosition: "post"
            ),
            .postService
        )
        XCTAssertEqual(PlanningCenterSceneMapper.scene(title: "Announcements"), .sermon)
        XCTAssertNil(PlanningCenterSceneMapper.scene(title: "Technical note"))
    }

    @MainActor
    func testPlanningCenterTimedCueDrivesNativeSceneOnlyAfterStartTime() throws {
        let profileDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let model = AppModel(profileDirectory: profileDirectory, autoStartRemoteMonitoring: false)
        defer {
            model.debugStopPollingForTesting()
            try? FileManager.default.removeItem(at: profileDirectory)
        }
        let now = Date(timeIntervalSince1970: 1_000)
        let plan = PlanningCenterPlan(
            id: "plan-1",
            title: "Sunday",
            serviceTypeID: "service-1",
            serviceTypeName: "Sunday Services",
            cues: [
                PlanningCenterSceneCue(
                    id: "song",
                    title: "Worship Song",
                    scene: .worship,
                    startsAt: now.addingTimeInterval(-60),
                    sequence: 1
                ),
                PlanningCenterSceneCue(
                    id: "message",
                    title: "Message",
                    scene: .sermon,
                    startsAt: now.addingTimeInterval(60),
                    sequence: 2
                )
            ]
        )
        model.selectedScene = .preService
        model.debugSetPlanningCenterFollowForTesting(true)
        model.debugSetPlanningCenterPlanForTesting(plan)

        model.debugUpdatePlanningCenterSceneForTesting(now: now)
        XCTAssertEqual(model.selectedScene, .worship)
        XCTAssertEqual(model.planningCenterCurrentCueIndex, 0)

        model.activatePlanningCenterCue(at: 1)
        XCTAssertEqual(model.selectedScene, .sermon)
        model.debugUpdatePlanningCenterSceneForTesting(now: now)
        XCTAssertEqual(
            model.selectedScene,
            .sermon,
            "manual plan-cue advance must remain in control until the next timed boundary"
        )

        model.debugUpdatePlanningCenterSceneForTesting(now: now.addingTimeInterval(120))
        XCTAssertEqual(model.selectedScene, .sermon)
        XCTAssertEqual(model.planningCenterCurrentCueIndex, 1)
    }

    @MainActor
    func testLipSyncRecommendationNamesThePathThatNeedsDelay() {
        let profileDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let model = AppModel(profileDirectory: profileDirectory)
        defer { model.debugStopPollingForTesting() }

        XCTAssertTrue(model.lipSyncRecommendation.localizedCaseInsensitiveContains("measure"))
        model.measuredEndToEndAudioLatencyMs = 20
        model.measuredEndToEndVideoLatencyMs = 50
        XCTAssertEqual(model.lipSyncRecommendation, "Delay audio 30.0 ms")

        model.measuredEndToEndAudioLatencyMs = 70
        XCTAssertEqual(model.lipSyncRecommendation, "Delay video 20.0 ms")

        model.measuredEndToEndVideoLatencyMs = 70.5
        XCTAssertEqual(model.lipSyncRecommendation, "Aligned within 1.0 ms")
    }

    @MainActor
    func testStabilityMonitorSupportsFourHourHardwareProofWindow() {
        let profileDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let model = AppModel(profileDirectory: profileDirectory, autoStartRemoteMonitoring: false)
        defer {
            model.debugStopPollingForTesting()
            try? FileManager.default.removeItem(at: profileDirectory)
        }

        model.stabilityMonitorDurationSeconds = 20_000
        XCTAssertEqual(model.stabilityMonitorDurationSeconds, 14_400)
        model.stabilityMonitorDurationSeconds = 1
        XCTAssertEqual(model.stabilityMonitorDurationSeconds, 30)
    }

    @MainActor
    func testAppModelAutomaticallyRestartsUnexpectedEngineStopAndResumesContinuousCapture() async throws {
        let profileDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let model = AppModel(profileDirectory: profileDirectory, autoStartRemoteMonitoring: false)
        model.debugStopPollingForTesting()

        try model.debugStartSimulatedForRecoveryTesting(nowMs: 0)
        XCTAssertTrue(model.isRunning)
        XCTAssertEqual(model.automaticRecoveryStatus, "armed · healthy")
        XCTAssertEqual(model.debugAutonomousSessionIntentForTesting()?.active, true)
        XCTAssertEqual(model.debugAutonomousSessionIntentForTesting()?.continuousRecording, false)

        model.startContinuousRecording()
        let firstRecordingDirectory = try XCTUnwrap(model.continuousRecordingDirectoryURL)
        XCTAssertTrue(model.continuousRecordingActive)
        XCTAssertEqual(model.debugAutonomousSessionIntentForTesting()?.continuousRecording, true)

        model.debugForceUnexpectedEngineStopForTesting()
        XCTAssertFalse(model.isRunning)
        model.debugEvaluateAutomaticRecoveryForTesting(nowMs: 3_100)
        XCTAssertFalse(model.isRunning, "unhealthy grace must elapse before restart")
        model.debugEvaluateAutomaticRecoveryForTesting(nowMs: 5_200)

        XCTAssertTrue(model.isRunning)
        XCTAssertTrue(model.continuousRecordingActive)
        XCTAssertEqual(model.automaticRecoveryAttemptCount, 1)
        XCTAssertNotEqual(model.continuousRecordingDirectoryURL, firstRecordingDirectory)
        XCTAssertEqual(model.automaticRecoveryStatus, "armed · healthy")

        await model.debugWaitForIncidentWritesForTesting()
        let incidentURL = try XCTUnwrap(model.incidentLogURL)
        let incidentKinds = try String(contentsOf: incidentURL, encoding: .utf8)
        XCTAssertTrue(incidentKinds.contains("automatic-restart-attempt"))
        XCTAssertTrue(incidentKinds.contains("automatic-restart-succeeded"))

        model.stopEngine()
        await model.debugWaitForIncidentWritesForTesting()
        XCTAssertNil(model.debugAutonomousSessionIntentForTesting())
        model.debugStopPollingForTesting()
        try FileManager.default.removeItem(at: profileDirectory)
    }

    func testVenueProfileNormalizesReadyChannelMapByMixerIndex() throws {
        let profile = VenueProfile(
            inputDeviceUID: "input",
            outputDeviceUID: "output",
            expectedInputChannels: 3,
            channelMappings: [
                ChannelMapping(index: 2, inputChannelIndex: 0, name: "Bass", role: .bass),
                ChannelMapping(index: 0, inputChannelIndex: 2, name: "Pastor", role: .speech),
                ChannelMapping(index: 1, inputChannelIndex: 1, name: "Keys", role: .keys)
            ]
        )

        XCTAssertEqual(profile.channelMappings.map(\.index), [0, 1, 2])
        XCTAssertEqual(profile.channelMappings.map(\.name), ["Pastor", "Keys", "Bass"])
        XCTAssertEqual(profile.channelMappings.map(\.inputChannelIndex), [2, 1, 0])

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(VenueProfile.self, from: data)
        XCTAssertEqual(decoded.channelMappings.map(\.index), [0, 1, 2])
        XCTAssertEqual(decoded.channelMappings.map(\.name), ["Pastor", "Keys", "Bass"])
        XCTAssertEqual(decoded.channelMappings.map(\.inputChannelIndex), [2, 1, 0])
    }

    func testVenueProfilePreservesMalformedChannelMapForPreflightWarnings() {
        let profile = VenueProfile(
            inputDeviceUID: "input",
            outputDeviceUID: "output",
            expectedInputChannels: 3,
            channelMappings: [
                ChannelMapping(index: 2, inputChannelIndex: 0, name: "Bass", role: .bass),
                ChannelMapping(index: 0, inputChannelIndex: 0, name: "Duplicate Input", role: .speech)
            ]
        )

        XCTAssertEqual(profile.channelMappings.map(\.index), [2, 0])
        XCTAssertEqual(profile.channelMappings.map(\.name), ["Bass", "Duplicate Input"])
        XCTAssertFalse(ChannelMapCoverage.make(
            channelMappings: profile.channelMappings,
            inputChannelCount: 3
        ).isReady)
    }

    func testVenueProfileServiceRoleTemplateIsReadyForPreflight() throws {
        let profile = VenueProfile.serviceRoleTemplate(
            inputDeviceUID: "dante.input",
            outputDeviceUID: "stream.output",
            expectedInputChannels: 64,
            scene: .sermon
        )

        XCTAssertEqual(profile.inputDeviceUID, "dante.input")
        XCTAssertEqual(profile.outputDeviceUID, "stream.output")
        XCTAssertEqual(profile.expectedInputChannels, 64)
        XCTAssertEqual(profile.scene, .sermon)
        XCTAssertEqual(profile.channelMappings.count, 64)
        XCTAssertEqual(profile.channelMappings.map(\.index), Array(0..<64))
        XCTAssertEqual(profile.channelMappings.map(\.inputChannelIndex), Array(0..<64))
        XCTAssertTrue(ChannelMapCoverage.make(
            channelMappings: profile.channelMappings,
            inputChannelCount: 64
        ).isReady)
        XCTAssertTrue(SourceRoleCoverage.make(channelMappings: profile.channelMappings).isReady)

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(VenueProfile.self, from: data)
        XCTAssertEqual(decoded.channelMappings.count, 64)
        XCTAssertEqual(decoded.channelMappings.first?.role, .speech)
    }

    func testVenueProfileServiceRoleTemplateDoesNotDefaultMissingOutputToInput() {
        let profile = VenueProfile.serviceRoleTemplate(
            inputDeviceUID: "dante.input",
            outputDeviceUID: "",
            expectedInputChannels: 64
        )

        XCTAssertEqual(profile.inputDeviceUID, "dante.input")
        XCTAssertEqual(profile.outputDeviceUID, "")
    }

    func testChannelMapCoverageDetectsDuplicateAndMissingDanteInputs() {
        let mappings = [
            ChannelMapping(index: 0, inputChannelIndex: 0, name: "Ch 1", role: .speech),
            ChannelMapping(index: 1, inputChannelIndex: 0, name: "Ch 2", role: .speech),
            ChannelMapping(index: 2, inputChannelIndex: 4, name: "Ch 3", role: .speech)
        ]

        let coverage = ChannelMapCoverage.make(channelMappings: mappings, inputChannelCount: 3)

        XCTAssertFalse(coverage.isReady)
        XCTAssertEqual(coverage.uniqueMappedInputCount, 1)
        XCTAssertEqual(coverage.duplicateInputChannels, [0])
        XCTAssertEqual(coverage.missingInputChannels, [1, 2])
        XCTAssertEqual(coverage.outOfRangeMixerChannels, [2])
        XCTAssertTrue(coverage.summary.localizedCaseInsensitiveContains("duplicate Dante In 1"))
        XCTAssertTrue(coverage.summary.localizedCaseInsensitiveContains("missing Dante In 2, 3"))
        XCTAssertTrue(coverage.summary.localizedCaseInsensitiveContains("out-of-range Mix Ch 3"))
    }

    func testChannelMapCoverageDetectsDuplicateAndMissingMixerRows() {
        let mappings = [
            ChannelMapping(index: 0, inputChannelIndex: 0, name: "Ch 1", role: .speech),
            ChannelMapping(index: 0, inputChannelIndex: 1, name: "Duplicate Row", role: .speech),
            ChannelMapping(index: 2, inputChannelIndex: 2, name: "Ch 3", role: .speech)
        ]

        let coverage = ChannelMapCoverage.make(channelMappings: mappings, inputChannelCount: 3)

        XCTAssertFalse(coverage.isReady)
        XCTAssertEqual(coverage.uniqueMappedInputCount, 3)
        XCTAssertEqual(coverage.duplicateInputChannels, [])
        XCTAssertEqual(coverage.missingInputChannels, [])
        XCTAssertEqual(coverage.duplicateMixerChannels, [0])
        XCTAssertEqual(coverage.missingMixerChannels, [1])
        XCTAssertEqual(coverage.outOfRangeMixerChannels, [])
        XCTAssertTrue(coverage.summary.localizedCaseInsensitiveContains("duplicate Mix Ch 1"))
        XCTAssertTrue(coverage.summary.localizedCaseInsensitiveContains("missing Mix Ch 2"))
    }

    func testChannelMappingOrdersRowsByMixerIndexForBridgeStart() {
        let mappings = [
            ChannelMapping(index: 2, inputChannelIndex: 0, name: "Bass", role: .bass),
            ChannelMapping(index: 0, inputChannelIndex: 2, name: "Pastor", role: .speech),
            ChannelMapping(index: 1, inputChannelIndex: 1, name: "Keys", role: .keys)
        ]

        let ordered = ChannelMapping.orderedForMixerRows(mappings, mixerChannelCount: 3)
        let inputNumbers = ChannelMapping.inputChannelIndexNumbers(
            for: mappings,
            mixerChannelCount: 3,
            maxInputChannels: 3
        ).map(\.intValue)

        XCTAssertEqual(ordered.map(\.index), [0, 1, 2])
        XCTAssertEqual(ordered.map(\.name), ["Pastor", "Keys", "Bass"])
        XCTAssertEqual(ordered.map(\.role), [.speech, .keys, .bass])
        XCTAssertEqual(inputNumbers, [2, 1, 0])
    }

    @MainActor
    func testValidationSettingChangeCancelsActiveStabilityMonitor() throws {
        let profileDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let model = AppModel(profileDirectory: profileDirectory)
        defer { model.debugStopPollingForTesting() }

        model.debugActivateStabilityMonitorForInvalidationProbe()
        XCTAssertTrue(model.stabilityMonitorActive)
        XCTAssertTrue(model.stabilityMonitorWaitingForStream)

        model.selectedScene = model.selectedScene == .worship ? .sermon : .worship

        XCTAssertFalse(model.stabilityMonitorActive)
        XCTAssertFalse(model.stabilityMonitorWaitingForStream)
        XCTAssertTrue(model.statusText.localizedCaseInsensitiveContains("stability monitor canceled"))
        XCTAssertTrue(model.statusText.localizedCaseInsensitiveContains("validation settings changed"))
    }

    @MainActor
    func testSoundcheckCannotStartWhileStabilityMonitorIsActive() throws {
        let profileDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let model = AppModel(profileDirectory: profileDirectory)
        defer { model.debugStopPollingForTesting() }

        model.debugActivateStabilityMonitorForInvalidationProbe()
        XCTAssertTrue(model.stabilityMonitorActive)
        XCTAssertFalse(model.canStartSoundcheck)

        model.startTestRecording(seconds: 1)

        XCTAssertTrue(model.stabilityMonitorActive)
        XCTAssertTrue(model.statusText.localizedCaseInsensitiveContains("stability monitor"))
        XCTAssertTrue(model.statusText.localizedCaseInsensitiveContains("before starting a soundcheck"))
        XCTAssertNil(model.finishedRecordingURL)
        XCTAssertNil(model.lastSoundcheckReport)
    }

    @MainActor
    func testSoundcheckReportInputUsesCapturedProofControls() throws {
        let profileDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let model = AppModel(profileDirectory: profileDirectory)
        defer { model.debugStopPollingForTesting() }
        let recordingURL = profileDirectory.appendingPathComponent("soundcheck.wav")

        model.safeBypass = false
        model.frozen = false
        let liveInput = model.debugMakeSoundcheckReportInputForTesting(recordingURL: recordingURL)
        XCTAssertFalse(liveInput.safeBypassEnabled)
        XCTAssertFalse(liveInput.frozen)

        model.debugSetPendingSoundcheckProofControlsForTesting(safeBypassEnabled: true, frozen: true)
        model.safeBypass = false
        model.frozen = false

        let capturedInput = model.debugMakeSoundcheckReportInputForTesting(recordingURL: recordingURL)

        XCTAssertTrue(capturedInput.safeBypassEnabled)
        XCTAssertTrue(capturedInput.frozen)
        XCTAssertFalse(model.safeBypass)
        XCTAssertFalse(model.frozen)
    }

    @MainActor
    func testStabilityProofModeDisablesSafeFreezeAndShadow() throws {
        let profileDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let model = AppModel(profileDirectory: profileDirectory)
        defer { model.debugStopPollingForTesting() }

        model.safeBypass = true
        model.frozen = true
        model.shadowMode = true

        model.debugPrepareAutonomousStabilityProofModeForTesting()

        XCTAssertFalse(model.safeBypass)
        XCTAssertFalse(model.frozen)
        XCTAssertFalse(model.shadowMode)
    }

    @MainActor
    func testSafeOrFreezeChangeCancelsActiveStabilityMonitor() throws {
        let profileDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let model = AppModel(profileDirectory: profileDirectory)
        defer { model.debugStopPollingForTesting() }

        model.debugActivateStabilityMonitorForInvalidationProbe()
        XCTAssertTrue(model.stabilityMonitorActive)

        model.safeBypass = true

        XCTAssertFalse(model.stabilityMonitorActive)
        XCTAssertFalse(model.stabilityMonitorWaitingForStream)
        XCTAssertTrue(model.statusText.localizedCaseInsensitiveContains("stability monitor canceled"))
        XCTAssertTrue(model.statusText.localizedCaseInsensitiveContains("SAFE"))
        XCTAssertNil(model.lastStabilityReport)
        XCTAssertNil(model.lastFullCheckManifest)

        model.safeBypass = false
        model.debugActivateStabilityMonitorForInvalidationProbe()
        XCTAssertTrue(model.stabilityMonitorActive)

        model.frozen = true

        XCTAssertFalse(model.stabilityMonitorActive)
        XCTAssertTrue(model.statusText.localizedCaseInsensitiveContains("FREEZE"))
        XCTAssertNil(model.finishedFullCheckManifestURL)
        XCTAssertNil(model.lastFullCheckVerification)

        model.frozen = false
        model.debugActivateStabilityMonitorForInvalidationProbe()
        XCTAssertTrue(model.stabilityMonitorActive)

        model.shadowMode.toggle()

        XCTAssertFalse(model.stabilityMonitorActive)
        XCTAssertTrue(model.statusText.localizedCaseInsensitiveContains("SHADOW"))
    }

    func testSourceRoleCoverageRequiresAtLeastOneAssignedRole() {
        let unknownCoverage = SourceRoleCoverage.make(channelMappings: ChannelMapping.defaults(count: 4))
        XCTAssertFalse(unknownCoverage.isReady)
        XCTAssertEqual(unknownCoverage.assignedRoleCount, 0)
        XCTAssertTrue(unknownCoverage.summary.localizedCaseInsensitiveContains("set source roles"))

        let mixedCoverage = SourceRoleCoverage.make(channelMappings: [
            ChannelMapping(index: 0, name: "Pastor", role: .speech),
            ChannelMapping(index: 1, name: "Lead", role: .leadVocal),
            ChannelMapping(index: 2, name: "Spare", role: .unknown)
        ])
        XCTAssertTrue(mixedCoverage.isReady)
        XCTAssertEqual(mixedCoverage.assignedRoleCount, 2)
        XCTAssertEqual(mixedCoverage.speechRoleCount, 1)
        XCTAssertEqual(mixedCoverage.musicRoleCount, 1)
        XCTAssertEqual(mixedCoverage.unknownRoleCount, 1)
    }

    func testManualOverrideCoverageReportsEnabledAndInvalidOverrides() {
        var mappings = simulatedMappings(count: 4)
        mappings[0].faderOverrideEnabled = true
        mappings[0].faderDb = -12.0
        mappings[1].panOverrideEnabled = true
        mappings[1].pan = 0.25
        mappings[2].faderOverrideEnabled = true
        mappings[2].faderDb = 18.0

        let coverage = ManualOverrideCoverage.make(channelMappings: mappings)

        XCTAssertFalse(coverage.isReady)
        XCTAssertEqual(coverage.channelCount, 4)
        XCTAssertEqual(coverage.faderOverrideCount, 2)
        XCTAssertEqual(coverage.panOverrideCount, 1)
        XCTAssertEqual(coverage.invalidOverrideChannels, [2])
        XCTAssertTrue(coverage.summary.localizedCaseInsensitiveContains("fader 2"))
        XCTAssertTrue(coverage.summary.localizedCaseInsensitiveContains("pan 1"))
        XCTAssertTrue(coverage.summary.localizedCaseInsensitiveContains("invalid Mix Ch 3"))
    }

    func testManualOverrideCoverageAcceptsNativeRangeEdges() {
        var mappings = simulatedMappings(count: 2)
        mappings[0].faderOverrideEnabled = true
        mappings[0].faderDb = ChannelMapping.faderDbOverrideRange.lowerBound
        mappings[0].panOverrideEnabled = true
        mappings[0].pan = ChannelMapping.panOverrideRange.lowerBound
        mappings[1].faderOverrideEnabled = true
        mappings[1].faderDb = ChannelMapping.faderDbOverrideRange.upperBound
        mappings[1].panOverrideEnabled = true
        mappings[1].pan = ChannelMapping.panOverrideRange.upperBound

        let coverage = ManualOverrideCoverage.make(channelMappings: mappings)

        XCTAssertTrue(coverage.isReady)
        XCTAssertEqual(coverage.faderOverrideCount, 2)
        XCTAssertEqual(coverage.panOverrideCount, 2)
        XCTAssertEqual(coverage.invalidOverrideChannels, [])
    }

    func testCLIManualOverrideApplierPushesProfileOverridesToRunningBridge() throws {
        try bridge.startSimulated(
            withChannelCount: 4,
            sampleRate: 96_000,
            bufferFrameSize: 256,
            channelRoles: simulatedRoles(count: 4),
            inputChannelIndices: identityInputMap(count: 4)
        )

        var mappings = simulatedMappings(count: 4)
        mappings[0].faderOverrideEnabled = true
        mappings[0].faderDb = -18.0
        mappings[1].panOverrideEnabled = true
        mappings[1].pan = 0.35
        mappings.append(ChannelMapping(
            index: 7,
            name: "Invalid",
            role: .speech,
            faderOverrideEnabled: true,
            faderDb: -10.0
        ))

        let summary = CLIManualOverrideApplier.apply(mappings, to: bridge)

        XCTAssertEqual(summary.requestedCount, 3)
        XCTAssertEqual(summary.appliedCount, 2)
        XCTAssertEqual(summary.failedMixerChannels, [7])
    }

    func testServiceRoleTemplateSeedsUsefulRolesAndPreservesRoutingFields() {
        var existing = ChannelMapping.defaults(count: 3)
        existing[0].inputChannelIndex = 7
        existing[0].faderOverrideEnabled = true
        existing[0].faderDb = -12.0
        existing[0].panOverrideEnabled = true
        existing[0].pan = -0.25

        let seeded = ChannelMapping.applyingServiceRoleTemplate(to: existing, count: 4)

        XCTAssertEqual(seeded.count, 4)
        XCTAssertEqual(seeded[0].inputChannelIndex, 7)
        XCTAssertTrue(seeded[0].faderOverrideEnabled)
        XCTAssertEqual(seeded[0].faderDb, -12.0)
        XCTAssertTrue(seeded[0].panOverrideEnabled)
        XCTAssertEqual(seeded[0].pan, -0.25)
        XCTAssertEqual(seeded[0].role, .speech)
        XCTAssertEqual(seeded[1].role, .speech)
        XCTAssertEqual(seeded[2].role, .speech)
        XCTAssertEqual(seeded[3].role, .leadVocal)
        XCTAssertTrue(SourceRoleCoverage.make(channelMappings: seeded).isReady)
    }

    func testSimulatedInputMapFeedsSelectedDanteChannelIntoMixerChannel() throws {
        var inputMap = identityInputMap(count: 64)
        inputMap[0] = NSNumber(value: 7)

        try bridge.startSimulated(
            withChannelCount: 64,
            sampleRate: 96_000,
            bufferFrameSize: 256,
            channelRoles: simulatedRoles(count: 64),
            inputChannelIndices: inputMap
        )

        XCTAssertTrue(waitUntil(timeout: 2.0) {
            let levels = self.bridge.inputLevelsDb()
            guard levels.count >= 8 else { return false }
            return levels[0].doubleValue > levels[1].doubleValue + 4.0
        })
        XCTAssertTrue(bridge.setInputChannelIndex(0, forMixerChannel: 0))
        XCTAssertFalse(bridge.setInputChannelIndex(64, forMixerChannel: 0))
        XCTAssertFalse(bridge.setInputChannelIndex(0, forMixerChannel: 64))
    }

    func testVenueProfileClampsExpectedInputChannels() throws {
        let tooHigh = VenueProfile(
            inputDeviceUID: "input",
            outputDeviceUID: "output",
            expectedInputChannels: 128,
            channelMappings: ChannelMapping.defaults(count: 1)
        )
        XCTAssertEqual(tooHigh.expectedInputChannels, 64)

        let data = Data("""
        {
          "inputDeviceUID": "input",
          "outputDeviceUID": "output",
          "expectedInputChannels": 0,
          "channelMappings": [
            { "index": 0, "name": "Ch 1", "role": "speech" }
          ]
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(VenueProfile.self, from: data)
        XCTAssertEqual(decoded.expectedInputChannels, 1)
    }

    func testSoundcheckReportPassesCleanHD96Run() {
        let report = SoundcheckReport.make(
            generatedAt: Date(timeIntervalSince1970: 0),
            recordingPath: "/tmp/test.wav",
            recordingByteCount: 1_000_000,
            recordingChannelCount: 66,
            recordingSampleRate: 96_000,
            inputDevice: simulatedDeviceSnapshot(),
            outputDevice: simulatedDeviceSnapshot(),
            scene: .sermon,
            expectedInputChannels: 64,
            detectedInputChannels: 64,
            detectedSampleRate: 96_000,
            bufferFrameSize: 256,
            lastCallbackFrames: 256,
            maxObservedCallbackFrames: 256,
            dropoutCount: 0,
            outputUnderrunCount: 0,
            watchdogSafeActive: false,
            safeBypassEnabled: true,
            frozen: false,
            channelMappings: simulatedMappings(count: 64),
            latestInputLevelsDb: Array(repeating: -30.0, count: 64),
            latestStreamOutputLevelsDb: [-24.0, -24.0],
            latestMomentaryLufs: -23.0,
            latestShortTermLufs: -24.0,
            latestIntegratedLufs: -25.0,
            latestLimiterGainReductionDb: -1.0,
            recordedActiveInputChannelCount: 12,
            recordedStreamOutputActiveChannelCount: 2,
            recordedInputPeakDb: -28.0,
            recordedStreamOutputPeakDb: [-24.0, -24.0]
        )

        XCTAssertTrue(report.passed)
        XCTAssertEqual(report.summary, "Soundcheck passed")
        XCTAssertEqual(report.validationSource, .simulatedHD96Dante)
        XCTAssertEqual(report.recordedActiveInputChannelCount, 12)
        XCTAssertEqual(report.recordedActiveInputChannels, Array(1...12))
        XCTAssertEqual(report.recordedInputPeakDbByChannel.count, 64)
        XCTAssertEqual(Array(report.recordedInputPeakDbByChannel.prefix(12)), Array(repeating: -28.0, count: 12))
        XCTAssertEqual(Array(report.recordedInputPeakDbByChannel.dropFirst(12)), Array(repeating: -100.0, count: 52))
    }

    func testSoundcheckReportRequiresSafeBypassForProofRecording() throws {
        let report = SoundcheckReport.make(
            generatedAt: Date(timeIntervalSince1970: 0),
            recordingPath: "/tmp/test.wav",
            recordingByteCount: 1_000_000,
            recordingChannelCount: 66,
            recordingSampleRate: 96_000,
            inputDevice: simulatedDeviceSnapshot(),
            outputDevice: simulatedDeviceSnapshot(),
            scene: .sermon,
            expectedInputChannels: 64,
            detectedInputChannels: 64,
            detectedSampleRate: 96_000,
            bufferFrameSize: 256,
            lastCallbackFrames: 256,
            maxObservedCallbackFrames: 256,
            dropoutCount: 0,
            outputUnderrunCount: 0,
            watchdogSafeActive: false,
            safeBypassEnabled: false,
            frozen: false,
            channelMappings: simulatedMappings(count: 64),
            latestInputLevelsDb: Array(repeating: -30.0, count: 64),
            latestStreamOutputLevelsDb: [-24.0, -24.0],
            latestMomentaryLufs: -23.0,
            latestShortTermLufs: -24.0,
            latestIntegratedLufs: -25.0,
            latestLimiterGainReductionDb: -1.0,
            recordedActiveInputChannelCount: 12,
            recordedStreamOutputActiveChannelCount: 2,
            recordedInputPeakDb: -28.0,
            recordedStreamOutputPeakDb: [-24.0, -24.0]
        )

        let safeCheck = try XCTUnwrap(report.checks.first { $0.name == "SAFE Bypass" })
        XCTAssertFalse(report.passed)
        XCTAssertFalse(safeCheck.passed)
        XCTAssertEqual(safeCheck.observed, "disabled")
    }

    func testSoundcheckReportIncludesManualOverrideCoverage() throws {
        var mappings = simulatedMappings(count: 4)
        mappings[0].faderOverrideEnabled = true
        mappings[0].faderDb = -12.0
        mappings[1].panOverrideEnabled = true
        mappings[1].pan = -0.25

        let report = SoundcheckReport.make(
            generatedAt: Date(timeIntervalSince1970: 0),
            recordingPath: "/tmp/test.wav",
            recordingByteCount: 2_000_000,
            recordingChannelCount: 6,
            recordingSampleRate: 96_000,
            recordingFrameCount: 96_000,
            recordingDurationSeconds: 1.0,
            expectedRecordingDurationSeconds: 1.0,
            inputDevice: simulatedDeviceSnapshot(),
            outputDevice: simulatedDeviceSnapshot(),
            scene: .worship,
            expectedInputChannels: 4,
            detectedInputChannels: 4,
            detectedSampleRate: 96_000,
            bufferFrameSize: 256,
            lastCallbackFrames: 256,
            maxObservedCallbackFrames: 256,
            dropoutCount: 0,
            outputUnderrunCount: 0,
            watchdogSafeActive: false,
            safeBypassEnabled: true,
            frozen: false,
            channelMappings: mappings,
            latestInputLevelsDb: Array(repeating: -30.0, count: 4),
            latestStreamOutputLevelsDb: [-24.0, -24.0],
            latestMomentaryLufs: -23.0,
            latestShortTermLufs: -24.0,
            latestIntegratedLufs: -25.0,
            latestLimiterGainReductionDb: -1.0,
            recordedActiveInputChannelCount: 4,
            recordedActiveInputChannels: [1, 2, 3, 4],
            recordedStreamOutputActiveChannelCount: 2,
            recordedInputPeakDb: -28.0,
            recordedInputPeakDbByChannel: Array(repeating: -28.0, count: 4),
            recordedStreamOutputPeakDb: [-24.0, -24.0]
        )

        let manualCheck = try XCTUnwrap(report.checks.first { $0.name == "Manual Overrides" })
        XCTAssertTrue(report.passed)
        XCTAssertTrue(manualCheck.passed)
        XCTAssertEqual(manualCheck.observed, "fader 1 · pan 1")
    }

    func testStabilityReportIncludesManualOverrideCoverage() throws {
        var mappings = simulatedMappings(count: 4)
        mappings[0].faderOverrideEnabled = true
        mappings[0].faderDb = -12.0
        mappings[1].panOverrideEnabled = true
        mappings[1].pan = 0.25

        let report = StabilityMonitorReport.make(
            generatedAt: Date(timeIntervalSince1970: 0),
            durationSeconds: 30.0,
            inputDevice: simulatedDeviceSnapshot(),
            outputDevice: simulatedDeviceSnapshot(),
            scene: .worship,
            expectedInputChannels: 4,
            detectedInputChannels: 4,
            detectedSampleRate: 96_000,
            bufferFrameSize: 256,
            lastCallbackFrames: 256,
            maxObservedCallbackFrames: 256,
            dropoutDelta: 0,
            outputUnderrunDelta: 0,
            watchdogSafeActive: false,
            channelMappings: mappings,
            minStreamOutputLevelsDb: [-24.0, -24.0],
            maxStreamOutputLevelsDb: [-12.0, -12.0],
            maxActiveInputChannelCount: 4,
            minMomentaryLufs: -24.0,
            maxMomentaryLufs: -18.0,
            minLimiterGainReductionDb: -1.0
        )

        let manualCheck = try XCTUnwrap(report.checks.first { $0.name == "Manual Overrides" })
        XCTAssertTrue(report.passed)
        XCTAssertTrue(manualCheck.passed)
        XCTAssertEqual(manualCheck.observed, "fader 1 · pan 1")
    }

    func testSoundcheckReportFlagsCallbackFramesAbovePreparedBuffer() throws {
        let report = SoundcheckReport.make(
            generatedAt: Date(timeIntervalSince1970: 0),
            recordingPath: "/tmp/test.wav",
            recordingByteCount: 1_000_000,
            recordingChannelCount: 66,
            recordingSampleRate: 96_000,
            inputDevice: simulatedDeviceSnapshot(),
            outputDevice: simulatedDeviceSnapshot(),
            scene: .sermon,
            expectedInputChannels: 64,
            detectedInputChannels: 64,
            detectedSampleRate: 96_000,
            bufferFrameSize: 256,
            lastCallbackFrames: 512,
            maxObservedCallbackFrames: 512,
            dropoutCount: 0,
            outputUnderrunCount: 0,
            watchdogSafeActive: false,
            safeBypassEnabled: true,
            frozen: false,
            channelMappings: simulatedMappings(count: 64),
            latestInputLevelsDb: Array(repeating: -30.0, count: 64),
            latestStreamOutputLevelsDb: [-24.0, -24.0],
            latestMomentaryLufs: -23.0,
            latestShortTermLufs: -24.0,
            latestIntegratedLufs: -25.0,
            latestLimiterGainReductionDb: -1.0,
            recordedActiveInputChannelCount: 12,
            recordedStreamOutputActiveChannelCount: 2,
            recordedInputPeakDb: -28.0,
            recordedStreamOutputPeakDb: [-24.0, -24.0]
        )

        let callbackFrameSize = try XCTUnwrap(report.checks.first { $0.name == "Callback Frame Size" })
        XCTAssertFalse(report.passed)
        XCTAssertFalse(callbackFrameSize.passed)
        XCTAssertEqual(callbackFrameSize.expected, "<= prepared 256 frames")
        XCTAssertEqual(callbackFrameSize.observed, "512 max")
    }

    func testSoundcheckReportFlagsRealtimeCounterBreakdown() throws {
        let report = SoundcheckReport.make(
            generatedAt: Date(timeIntervalSince1970: 0),
            recordingPath: "/tmp/test.wav",
            recordingByteCount: 1_000_000,
            recordingChannelCount: 66,
            recordingSampleRate: 96_000,
            inputDevice: simulatedDeviceSnapshot(),
            outputDevice: simulatedDeviceSnapshot(),
            scene: .sermon,
            expectedInputChannels: 64,
            detectedInputChannels: 64,
            detectedSampleRate: 96_000,
            bufferFrameSize: 256,
            lastCallbackFrames: 256,
            maxObservedCallbackFrames: 256,
            dropoutCount: 0,
            callbackOverrunCount: 1,
            renderDeadlineMissCount: 2,
            outputUnderrunCount: 0,
            outputOverrunCount: 3,
            watchdogSafeActive: false,
            safeBypassEnabled: true,
            frozen: false,
            channelMappings: simulatedMappings(count: 64),
            latestInputLevelsDb: Array(repeating: -30.0, count: 64),
            latestStreamOutputLevelsDb: [-24.0, -24.0],
            latestMomentaryLufs: -23.0,
            latestShortTermLufs: -24.0,
            latestIntegratedLufs: -25.0,
            latestLimiterGainReductionDb: -1.0,
            recordedActiveInputChannelCount: 12,
            recordedStreamOutputActiveChannelCount: 2,
            recordedInputPeakDb: -28.0,
            recordedStreamOutputPeakDb: [-24.0, -24.0]
        )

        XCTAssertFalse(report.passed)
        XCTAssertEqual(report.callbackOverrunCount, 1)
        XCTAssertEqual(report.renderDeadlineMissCount, 2)
        XCTAssertEqual(report.outputOverrunCount, 3)
        XCTAssertEqual(Set(report.checks.filter { !$0.passed }.map(\.name)), [
            "Callback Overruns",
            "Render Deadline Misses",
            "Output Overruns"
        ])
    }

    func testSoundcheckReportPersistsRecordedInputPeakList() {
        let report = SoundcheckReport.make(
            generatedAt: Date(timeIntervalSince1970: 0),
            recordingPath: "/tmp/test.wav",
            recordingByteCount: 1_000_000,
            recordingChannelCount: 5,
            recordingSampleRate: 96_000,
            inputDevice: SoundcheckDeviceSnapshot(
                uid: "real-dante-input",
                name: "Dante Virtual Soundcard",
                inputChannels: 3,
                outputChannels: 0,
                sampleRate: 96_000,
                inputFormatSummary: "32-bit little-endian float PCM",
                outputFormatSummary: "no output streams",
                inputFormatSupported: true,
                outputFormatSupported: false
            ),
            outputDevice: SoundcheckDeviceSnapshot(
                uid: "stream-output",
                name: "Stream Output",
                inputChannels: 0,
                outputChannels: 2,
                sampleRate: 96_000,
                inputFormatSummary: "no input streams",
                outputFormatSummary: "32-bit little-endian float PCM",
                inputFormatSupported: false,
                outputFormatSupported: true
            ),
            scene: .sermon,
            expectedInputChannels: 3,
            detectedInputChannels: 3,
            detectedSampleRate: 96_000,
            bufferFrameSize: 256,
            lastCallbackFrames: 256,
            maxObservedCallbackFrames: 256,
            dropoutCount: 0,
            outputUnderrunCount: 0,
            watchdogSafeActive: false,
            safeBypassEnabled: true,
            frozen: false,
            channelMappings: [
                ChannelMapping(index: 0, name: "Pastor", role: .speech),
                ChannelMapping(index: 1, name: "Spare", role: .unknown),
                ChannelMapping(index: 2, name: "Keys", role: .keys)
            ],
            latestInputLevelsDb: [-30.0, -40.0, -50.0],
            latestStreamOutputLevelsDb: [-24.0, -24.0],
            latestMomentaryLufs: -23.0,
            latestShortTermLufs: -24.0,
            latestIntegratedLufs: -25.0,
            latestLimiterGainReductionDb: -1.0,
            recordedActiveInputChannelCount: 2,
            recordedActiveInputChannels: [1, 3],
            recordedStreamOutputActiveChannelCount: 2,
            recordedInputPeakDb: -20.0,
            recordedInputPeakDbByChannel: [-20.0, -100.0, -35.0],
            recordedStreamOutputPeakDb: [-24.0, -24.0]
        )

        XCTAssertTrue(report.passed)
        XCTAssertEqual(report.validationSource, .coreAudioDevice)
        XCTAssertEqual(report.recordedActiveInputChannelCount, 2)
        XCTAssertEqual(report.recordedActiveInputChannels, [1, 3])
        XCTAssertEqual(report.recordedInputPeakDb, -20.0)
        XCTAssertEqual(report.recordedInputPeakDbByChannel, [-20.0, -100.0, -35.0])
    }

    func testSoundcheckDeviceSnapshotDefaultsFormatFieldsForOlderReports() throws {
        let data = Data("""
        {
          "uid": "legacy",
          "name": "Legacy Device",
          "inputChannels": 64,
          "outputChannels": 2,
          "sampleRate": 96000
        }
        """.utf8)

        let snapshot = try JSONDecoder().decode(SoundcheckDeviceSnapshot.self, from: data)

        XCTAssertEqual(snapshot.inputFormatSummary, "unknown input format")
        XCTAssertEqual(snapshot.outputFormatSummary, "unknown output format")
        XCTAssertFalse(snapshot.inputFormatSupported)
        XCTAssertFalse(snapshot.outputFormatSupported)
    }

    func testReportsLabelRealCoreAudioDeviceValidationSource() {
        let input = SoundcheckDeviceSnapshot(
            uid: "com.audinate.dantevirtualsoundcard.input",
            name: "Dante Virtual Soundcard",
            inputChannels: 64,
            outputChannels: 0,
            sampleRate: 96_000,
            inputFormatSummary: "32-bit little-endian float PCM",
            outputFormatSummary: "no output streams",
            inputFormatSupported: true,
            outputFormatSupported: false
        )
        let output = SoundcheckDeviceSnapshot(
            uid: "stream.encoder.output",
            name: "Stream Encoder Output",
            inputChannels: 0,
            outputChannels: 2,
            sampleRate: 96_000,
            inputFormatSummary: "no input streams",
            outputFormatSummary: "32-bit little-endian float PCM",
            inputFormatSupported: false,
            outputFormatSupported: true
        )
        let soundcheck = SoundcheckReport.make(
            generatedAt: Date(timeIntervalSince1970: 0),
            recordingPath: "/tmp/test.wav",
            recordingByteCount: 1_000_000,
            recordingChannelCount: 66,
            recordingSampleRate: 96_000,
            inputDevice: input,
            outputDevice: output,
            scene: .sermon,
            expectedInputChannels: 64,
            detectedInputChannels: 64,
            detectedSampleRate: 96_000,
            bufferFrameSize: 256,
            lastCallbackFrames: 256,
            maxObservedCallbackFrames: 256,
            dropoutCount: 0,
            outputUnderrunCount: 0,
            watchdogSafeActive: false,
            safeBypassEnabled: true,
            frozen: false,
            channelMappings: simulatedMappings(count: 64),
            latestInputLevelsDb: Array(repeating: -30.0, count: 64),
            latestStreamOutputLevelsDb: [-24.0, -24.0],
            latestMomentaryLufs: -23.0,
            latestShortTermLufs: -24.0,
            latestIntegratedLufs: -25.0,
            latestLimiterGainReductionDb: -1.0,
            recordedActiveInputChannelCount: 12,
            recordedStreamOutputActiveChannelCount: 2,
            recordedInputPeakDb: -28.0,
            recordedStreamOutputPeakDb: [-24.0, -24.0]
        )
        let stability = StabilityMonitorReport.make(
            generatedAt: Date(timeIntervalSince1970: 0),
            durationSeconds: 300,
            inputDevice: input,
            outputDevice: output,
            scene: .worship,
            expectedInputChannels: 64,
            detectedInputChannels: 64,
            detectedSampleRate: 96_000,
            bufferFrameSize: 256,
            lastCallbackFrames: 256,
            maxObservedCallbackFrames: 256,
            dropoutDelta: 0,
            outputUnderrunDelta: 0,
            outputRingTargetFrames: 4_096,
            minOutputRingFillFrames: 3_500,
            maxOutputRingFillFrames: 4_500,
            maxAbsOutputClockCorrectionPpm: 120,
            watchdogSafeActive: false,
            channelMappings: simulatedMappings(count: 64),
            minStreamOutputLevelsDb: [-42.0, -41.0],
            maxStreamOutputLevelsDb: [-12.0, -11.0],
            maxActiveInputChannelCount: 12,
            minMomentaryLufs: -34.0,
            maxMomentaryLufs: -18.0,
            minLimiterGainReductionDb: -2.0
        )

        XCTAssertTrue(soundcheck.passed)
        XCTAssertTrue(stability.passed)
        XCTAssertEqual(soundcheck.validationSource, .coreAudioDevice)
        XCTAssertEqual(stability.validationSource, .coreAudioDevice)
    }

    func testValidationReportsBlockOutputSharedWithDanteInputRoute() throws {
        let danteDevice = SoundcheckDeviceSnapshot(
            uid: "com.audinate.dantevirtualsoundcard",
            name: "Dante Virtual Soundcard",
            inputChannels: 64,
            outputChannels: 2,
            sampleRate: 96_000,
            inputFormatSummary: "32-bit little-endian float PCM",
            outputFormatSummary: "32-bit little-endian float PCM",
            inputFormatSupported: true,
            outputFormatSupported: true
        )

        let soundcheck = SoundcheckReport.make(
            generatedAt: Date(timeIntervalSince1970: 0),
            recordingPath: "/tmp/test.wav",
            recordingByteCount: 1_000_000,
            recordingChannelCount: 66,
            recordingSampleRate: 96_000,
            inputDevice: danteDevice,
            outputDevice: danteDevice,
            scene: .sermon,
            expectedInputChannels: 64,
            detectedInputChannels: 64,
            detectedSampleRate: 96_000,
            bufferFrameSize: 256,
            lastCallbackFrames: 256,
            maxObservedCallbackFrames: 256,
            dropoutCount: 0,
            outputUnderrunCount: 0,
            watchdogSafeActive: false,
            safeBypassEnabled: true,
            frozen: false,
            channelMappings: simulatedMappings(count: 64),
            latestInputLevelsDb: Array(repeating: -30.0, count: 64),
            latestStreamOutputLevelsDb: [-24.0, -24.0],
            latestMomentaryLufs: -23.0,
            latestShortTermLufs: -24.0,
            latestIntegratedLufs: -25.0,
            latestLimiterGainReductionDb: -1.0,
            recordedActiveInputChannelCount: 12,
            recordedActiveInputChannels: Array(1...12),
            recordedStreamOutputActiveChannelCount: 2,
            recordedInputPeakDb: -28.0,
            recordedInputPeakDbByChannel: Array(repeating: -28.0, count: 12) + Array(repeating: -100.0, count: 52),
            recordedStreamOutputPeakDb: [-24.0, -24.0]
        )
        let stability = StabilityMonitorReport.make(
            generatedAt: Date(timeIntervalSince1970: 0),
            durationSeconds: 300,
            inputDevice: danteDevice,
            outputDevice: danteDevice,
            scene: .worship,
            expectedInputChannels: 64,
            detectedInputChannels: 64,
            detectedSampleRate: 96_000,
            bufferFrameSize: 256,
            lastCallbackFrames: 256,
            maxObservedCallbackFrames: 256,
            dropoutDelta: 0,
            outputUnderrunDelta: 0,
            watchdogSafeActive: false,
            channelMappings: simulatedMappings(count: 64),
            minStreamOutputLevelsDb: [-42.0, -41.0],
            maxStreamOutputLevelsDb: [-12.0, -11.0],
            maxActiveInputChannelCount: 12,
            minMomentaryLufs: -34.0,
            maxMomentaryLufs: -18.0,
            minLimiterGainReductionDb: -2.0
        )

        let soundcheckIsolation = try XCTUnwrap(soundcheck.checks.first { $0.name == "Output Isolation" })
        let stabilityIsolation = try XCTUnwrap(stability.checks.first { $0.name == "Output Isolation" })
        XCTAssertFalse(soundcheck.passed)
        XCTAssertFalse(stability.passed)
        XCTAssertFalse(soundcheckIsolation.passed)
        XCTAssertFalse(stabilityIsolation.passed)
        XCTAssertTrue(soundcheckIsolation.observed.localizedCaseInsensitiveContains("same Core Audio device"))
        XCTAssertTrue(stabilityIsolation.observed.localizedCaseInsensitiveContains("Dante"))
    }

    func testSoundcheckReportFlagsUnsupportedCoreAudioFormat() throws {
        let badInput = SoundcheckDeviceSnapshot(
            uid: "dante.input",
            name: "Dante Virtual Soundcard",
            inputChannels: 64,
            outputChannels: 0,
            sampleRate: 96_000,
            inputFormatSummary: "lpcm signed-int 24-bit",
            outputFormatSummary: "no output streams",
            inputFormatSupported: false,
            outputFormatSupported: false
        )

        let report = SoundcheckReport.make(
            generatedAt: Date(timeIntervalSince1970: 0),
            recordingPath: "/tmp/test.wav",
            recordingByteCount: 1_000_000,
            recordingChannelCount: 66,
            recordingSampleRate: 96_000,
            inputDevice: badInput,
            outputDevice: simulatedDeviceSnapshot(),
            scene: .sermon,
            expectedInputChannels: 64,
            detectedInputChannels: 64,
            detectedSampleRate: 96_000,
            bufferFrameSize: 256,
            lastCallbackFrames: 256,
            maxObservedCallbackFrames: 256,
            dropoutCount: 0,
            outputUnderrunCount: 0,
            watchdogSafeActive: false,
            safeBypassEnabled: true,
            frozen: true,
            channelMappings: simulatedMappings(count: 64),
            latestInputLevelsDb: Array(repeating: -30.0, count: 64),
            latestStreamOutputLevelsDb: [-24.0, -24.0],
            latestMomentaryLufs: -23.0,
            latestShortTermLufs: -24.0,
            latestIntegratedLufs: -25.0,
            latestLimiterGainReductionDb: -1.0,
            recordedActiveInputChannelCount: 12,
            recordedStreamOutputActiveChannelCount: 2,
            recordedInputPeakDb: -28.0,
            recordedStreamOutputPeakDb: [-24.0, -24.0]
        )

        let formatCheck = try XCTUnwrap(report.checks.first { $0.name == "Core Audio Format" })
        XCTAssertFalse(report.passed)
        XCTAssertFalse(formatCheck.passed)
        XCTAssertTrue(formatCheck.observed.localizedCaseInsensitiveContains("signed-int"))
    }

    func testSoundcheckReportFlagsDuplicateDanteInputMap() throws {
        var mappings = simulatedMappings(count: 64)
        mappings[1].inputChannelIndex = 0

        let report = SoundcheckReport.make(
            generatedAt: Date(timeIntervalSince1970: 0),
            recordingPath: "/tmp/test.wav",
            recordingByteCount: 1_000_000,
            recordingChannelCount: 66,
            recordingSampleRate: 96_000,
            inputDevice: simulatedDeviceSnapshot(),
            outputDevice: simulatedDeviceSnapshot(),
            scene: .sermon,
            expectedInputChannels: 64,
            detectedInputChannels: 64,
            detectedSampleRate: 96_000,
            bufferFrameSize: 256,
            lastCallbackFrames: 256,
            maxObservedCallbackFrames: 256,
            dropoutCount: 0,
            outputUnderrunCount: 0,
            watchdogSafeActive: false,
            safeBypassEnabled: true,
            frozen: false,
            channelMappings: mappings,
            latestInputLevelsDb: Array(repeating: -30.0, count: 64),
            latestStreamOutputLevelsDb: [-24.0, -24.0],
            latestMomentaryLufs: -23.0,
            latestShortTermLufs: -24.0,
            latestIntegratedLufs: -25.0,
            latestLimiterGainReductionDb: -1.0,
            recordedActiveInputChannelCount: 12,
            recordedStreamOutputActiveChannelCount: 2,
            recordedInputPeakDb: -28.0,
            recordedStreamOutputPeakDb: [-24.0, -24.0]
        )

        let coverageCheck = try XCTUnwrap(report.checks.first { $0.name == "Input Map Coverage" })
        XCTAssertFalse(report.passed)
        XCTAssertEqual(report.summary, "Soundcheck needs attention")
        XCTAssertFalse(coverageCheck.passed)
        XCTAssertTrue(coverageCheck.observed.localizedCaseInsensitiveContains("duplicate Dante In 1"))
        XCTAssertTrue(coverageCheck.observed.localizedCaseInsensitiveContains("missing Dante In 2"))
    }

    func testSoundcheckReportFlagsHD96ReadinessProblems() {
        let report = SoundcheckReport.make(
            generatedAt: Date(timeIntervalSince1970: 0),
            recordingPath: "/tmp/test.wav",
            recordingByteCount: 44,
            recordingChannelCount: 32,
            recordingSampleRate: 44_100,
            inputDevice: simulatedDeviceSnapshot(),
            outputDevice: simulatedDeviceSnapshot(),
            scene: .worship,
            expectedInputChannels: 64,
            detectedInputChannels: 32,
            detectedSampleRate: 44_100,
            bufferFrameSize: 256,
            lastCallbackFrames: 0,
            maxObservedCallbackFrames: 0,
            dropoutCount: 2,
            outputUnderrunCount: 1,
            watchdogSafeActive: true,
            safeBypassEnabled: true,
            frozen: true,
            channelMappings: simulatedMappings(count: 32),
            latestInputLevelsDb: Array(repeating: -100.0, count: 32),
            latestStreamOutputLevelsDb: [-100.0, 0.0],
            latestMomentaryLufs: -100.0,
            latestShortTermLufs: -100.0,
            latestIntegratedLufs: -100.0,
            latestLimiterGainReductionDb: -18.0,
            recordedActiveInputChannelCount: 0,
            recordedStreamOutputActiveChannelCount: 1,
            recordedInputPeakDb: -100.0,
            recordedStreamOutputPeakDb: [-100.0, -30.0]
        )

        XCTAssertFalse(report.passed)
        XCTAssertEqual(report.summary, "Soundcheck needs attention")
        XCTAssertEqual(Set(report.checks.filter { !$0.passed }.map(\.name)), [
            "Sample Rate",
            "Input Channels",
            "Input Activity",
            "Route Clock",
            "Stream Mix Level",
            "Master Loudness",
            "Limiter Gain Reduction",
            "Callbacks",
            "Dropouts",
            "Output Underruns",
            "Watchdog SAFE",
            "Recording",
            "Recording Duration",
            "Recorded Input Activity",
            "Recorded Stream Activity",
            "Recording Channels",
            "Recording Sample Rate"
        ])
    }

    func testStabilityStreamWarmupWaitsForActiveStereoOutput() {
        XCTAssertFalse(StabilityStreamWarmup.isActiveStream([-100.0, -42.0]))
        XCTAssertFalse(StabilityStreamWarmup.shouldBeginMeasurement(
            levels: [-100.0, -42.0],
            warmupElapsed: 4.9,
            timeout: 5.0
        ))

        XCTAssertTrue(StabilityStreamWarmup.isActiveStream([-42.0, -41.0]))
        XCTAssertTrue(StabilityStreamWarmup.shouldBeginMeasurement(
            levels: [-42.0, -41.0],
            warmupElapsed: 0,
            timeout: 5.0
        ))
    }

    func testStabilityStreamWarmupRejectsClippingUntilTimeout() {
        XCTAssertFalse(StabilityStreamWarmup.isActiveStream([-12.0, 0.0]))
        XCTAssertFalse(StabilityStreamWarmup.shouldBeginMeasurement(
            levels: [-12.0, 0.0],
            warmupElapsed: 4.9,
            timeout: 5.0
        ))
        XCTAssertTrue(StabilityStreamWarmup.shouldBeginMeasurement(
            levels: [-12.0, 0.0],
            warmupElapsed: 5.0,
            timeout: 5.0
        ))
    }

    func testStabilityMonitorReportPassesCleanLongRun() {
        let report = StabilityMonitorReport.make(
            generatedAt: Date(timeIntervalSince1970: 0),
            durationSeconds: 300,
            inputDevice: simulatedDeviceSnapshot(),
            outputDevice: simulatedDeviceSnapshot(),
            scene: .worship,
            expectedInputChannels: 64,
            detectedInputChannels: 64,
            detectedSampleRate: 96_000,
            bufferFrameSize: 256,
            lastCallbackFrames: 256,
            maxObservedCallbackFrames: 256,
            dropoutDelta: 0,
            outputUnderrunDelta: 0,
            watchdogSafeActive: false,
            channelMappings: simulatedMappings(count: 64),
            minStreamOutputLevelsDb: [-42.0, -41.0],
            maxStreamOutputLevelsDb: [-12.0, -11.0],
            maxActiveInputChannelCount: 12,
            minMomentaryLufs: -34.0,
            maxMomentaryLufs: -18.0,
            minLimiterGainReductionDb: -2.0
        )

        XCTAssertTrue(report.passed)
        XCTAssertEqual(report.summary, "Stability monitor passed")
        XCTAssertEqual(report.validationSource, .simulatedHD96Dante)
        XCTAssertEqual(report.checks.first { $0.name == "Route Clock" }?.passed, true)
    }

    func testStabilityMonitorReportRequiresAutonomousProofControlsDisabled() throws {
        let report = StabilityMonitorReport.make(
            generatedAt: Date(timeIntervalSince1970: 0),
            durationSeconds: 300,
            inputDevice: simulatedDeviceSnapshot(),
            outputDevice: simulatedDeviceSnapshot(),
            scene: .worship,
            expectedInputChannels: 64,
            detectedInputChannels: 64,
            detectedSampleRate: 96_000,
            bufferFrameSize: 256,
            lastCallbackFrames: 256,
            maxObservedCallbackFrames: 256,
            dropoutDelta: 0,
            outputUnderrunDelta: 0,
            watchdogSafeActive: false,
            safeBypassEnabled: true,
            frozen: true,
            channelMappings: simulatedMappings(count: 64),
            minStreamOutputLevelsDb: [-42.0, -41.0],
            maxStreamOutputLevelsDb: [-12.0, -11.0],
            maxActiveInputChannelCount: 12,
            minMomentaryLufs: -34.0,
            maxMomentaryLufs: -18.0,
            minLimiterGainReductionDb: -2.0
        )

        let safeBypass = try XCTUnwrap(report.checks.first { $0.name == "SAFE Bypass" })
        let freeze = try XCTUnwrap(report.checks.first { $0.name == "FREEZE" })

        XCTAssertFalse(report.passed)
        XCTAssertEqual(report.safeBypassEnabled, true)
        XCTAssertEqual(report.frozen, true)
        XCTAssertFalse(safeBypass.passed)
        XCTAssertFalse(freeze.passed)
        XCTAssertEqual(safeBypass.expected, "disabled for autonomous proof")
        XCTAssertEqual(freeze.expected, "disabled for autonomous proof")
        XCTAssertEqual(Set(report.checks.filter { !$0.passed }.map(\.name)), [
            "SAFE Bypass",
            "FREEZE"
        ])
    }

    func testStabilityMonitorReportFlagsCallbackFramesAbovePreparedBuffer() throws {
        let report = StabilityMonitorReport.make(
            generatedAt: Date(timeIntervalSince1970: 0),
            durationSeconds: 300,
            inputDevice: simulatedDeviceSnapshot(),
            outputDevice: simulatedDeviceSnapshot(),
            scene: .worship,
            expectedInputChannels: 64,
            detectedInputChannels: 64,
            detectedSampleRate: 96_000,
            bufferFrameSize: 256,
            lastCallbackFrames: 512,
            maxObservedCallbackFrames: 512,
            dropoutDelta: 0,
            outputUnderrunDelta: 0,
            watchdogSafeActive: false,
            channelMappings: simulatedMappings(count: 64),
            minStreamOutputLevelsDb: [-42.0, -41.0],
            maxStreamOutputLevelsDb: [-12.0, -11.0],
            maxActiveInputChannelCount: 12,
            minMomentaryLufs: -34.0,
            maxMomentaryLufs: -18.0,
            minLimiterGainReductionDb: -2.0
        )

        let callbackFrameSize = try XCTUnwrap(report.checks.first { $0.name == "Callback Frame Size" })
        XCTAssertFalse(report.passed)
        XCTAssertFalse(callbackFrameSize.passed)
        XCTAssertEqual(callbackFrameSize.expected, "<= prepared 256 frames")
        XCTAssertEqual(callbackFrameSize.observed, "512 max")
    }

    func testStabilityMonitorReportFlagsRealtimeCounterBreakdown() throws {
        let report = StabilityMonitorReport.make(
            generatedAt: Date(timeIntervalSince1970: 0),
            durationSeconds: 300,
            inputDevice: simulatedDeviceSnapshot(),
            outputDevice: simulatedDeviceSnapshot(),
            scene: .worship,
            expectedInputChannels: 64,
            detectedInputChannels: 64,
            detectedSampleRate: 96_000,
            bufferFrameSize: 256,
            lastCallbackFrames: 256,
            maxObservedCallbackFrames: 256,
            dropoutDelta: 0,
            callbackOverrunDelta: 1,
            renderDeadlineMissDelta: 2,
            outputUnderrunDelta: 0,
            outputOverrunDelta: 3,
            watchdogSafeActive: false,
            channelMappings: simulatedMappings(count: 64),
            minStreamOutputLevelsDb: [-42.0, -41.0],
            maxStreamOutputLevelsDb: [-12.0, -11.0],
            maxActiveInputChannelCount: 12,
            minMomentaryLufs: -34.0,
            maxMomentaryLufs: -18.0,
            minLimiterGainReductionDb: -2.0
        )

        XCTAssertFalse(report.passed)
        XCTAssertEqual(report.callbackOverrunDelta, 1)
        XCTAssertEqual(report.renderDeadlineMissDelta, 2)
        XCTAssertEqual(report.outputOverrunDelta, 3)
        XCTAssertEqual(Set(report.checks.filter { !$0.passed }.map(\.name)), [
            "Callback Overruns",
            "Render Deadline Misses",
            "Output Overruns"
        ])
    }

    func testStabilityMonitorReportFlagsDriftAndStreamProblems() {
        let report = StabilityMonitorReport.make(
            generatedAt: Date(timeIntervalSince1970: 0),
            durationSeconds: 20,
            inputDevice: simulatedDeviceSnapshot(),
            outputDevice: simulatedDeviceSnapshot(),
            scene: .worship,
            expectedInputChannels: 64,
            detectedInputChannels: 32,
            detectedSampleRate: 44_100,
            bufferFrameSize: 256,
            lastCallbackFrames: 0,
            maxObservedCallbackFrames: 0,
            dropoutDelta: 3,
            outputUnderrunDelta: 2,
            watchdogSafeActive: true,
            channelMappings: simulatedMappings(count: 32),
            minStreamOutputLevelsDb: [-100.0, -38.0],
            maxStreamOutputLevelsDb: [-6.0, 0.0],
            maxActiveInputChannelCount: 0,
            minMomentaryLufs: -100.0,
            maxMomentaryLufs: -100.0,
            minLimiterGainReductionDb: -15.0
        )

        XCTAssertFalse(report.passed)
        XCTAssertEqual(report.summary, "Stability monitor needs attention")
        XCTAssertEqual(Set(report.checks.filter { !$0.passed }.map(\.name)), [
            "Duration",
            "Sample Rate",
            "Input Channels",
            "Route Clock",
            "Input Activity",
            "Callbacks",
            "Dropouts",
            "Output Underruns",
            "Watchdog SAFE",
            "Stream Mix Level",
            "Master Loudness",
            "Limiter Gain Reduction"
        ])
    }

    func testStabilityMonitorReportFlagsSeparateOutputRouteClockMismatch() throws {
        let input = SoundcheckDeviceSnapshot(
            uid: "dante.input",
            name: "Dante Virtual Soundcard",
            inputChannels: 64,
            outputChannels: 0,
            sampleRate: 96_000,
            inputFormatSummary: "32-bit little-endian float PCM",
            outputFormatSummary: "no output streams",
            inputFormatSupported: true,
            outputFormatSupported: false
        )
        let output = SoundcheckDeviceSnapshot(
            uid: "stream.output",
            name: "Stream Encoder Output",
            inputChannels: 0,
            outputChannels: 2,
            sampleRate: 48_000,
            inputFormatSummary: "no input streams",
            outputFormatSummary: "32-bit little-endian float PCM",
            inputFormatSupported: false,
            outputFormatSupported: true
        )

        let report = StabilityMonitorReport.make(
            generatedAt: Date(timeIntervalSince1970: 0),
            durationSeconds: 300,
            inputDevice: input,
            outputDevice: output,
            scene: .worship,
            expectedInputChannels: 64,
            detectedInputChannels: 64,
            detectedSampleRate: 96_000,
            bufferFrameSize: 256,
            lastCallbackFrames: 256,
            maxObservedCallbackFrames: 256,
            dropoutDelta: 0,
            outputUnderrunDelta: 0,
            outputRingTargetFrames: 4_096,
            minOutputRingFillFrames: 3_500,
            maxOutputRingFillFrames: 4_500,
            maxAbsOutputClockCorrectionPpm: 120,
            watchdogSafeActive: false,
            channelMappings: simulatedMappings(count: 64),
            minStreamOutputLevelsDb: [-42.0, -41.0],
            maxStreamOutputLevelsDb: [-12.0, -11.0],
            maxActiveInputChannelCount: 12,
            minMomentaryLufs: -34.0,
            maxMomentaryLufs: -18.0,
            minLimiterGainReductionDb: -2.0
        )

        let routeClock = try XCTUnwrap(report.checks.first { $0.name == "Route Clock" })
        XCTAssertFalse(report.passed)
        XCTAssertFalse(routeClock.passed)
        XCTAssertEqual(routeClock.observed, "input 96000 Hz / output 48000 Hz")
        XCTAssertEqual(Set(report.checks.filter { !$0.passed }.map(\.name)), ["Route Clock"])
    }

    func testStabilityMonitorReportRejectsSeparateOutputClockAtCorrectionLimit() throws {
        let input = SoundcheckDeviceSnapshot(
            uid: "dante.input",
            name: "Dante Virtual Soundcard",
            inputChannels: 64,
            outputChannels: 0,
            sampleRate: 96_000,
            inputFormatSummary: "32-bit little-endian float PCM",
            outputFormatSummary: "no output streams",
            inputFormatSupported: true,
            outputFormatSupported: false
        )
        let output = SoundcheckDeviceSnapshot(
            uid: "stream.output",
            name: "Stream Encoder Output",
            inputChannels: 0,
            outputChannels: 2,
            sampleRate: 96_000,
            inputFormatSummary: "no input streams",
            outputFormatSummary: "32-bit little-endian float PCM",
            inputFormatSupported: false,
            outputFormatSupported: true
        )

        let report = StabilityMonitorReport.make(
            generatedAt: Date(timeIntervalSince1970: 0),
            durationSeconds: 300,
            inputDevice: input,
            outputDevice: output,
            scene: .worship,
            expectedInputChannels: 64,
            detectedInputChannels: 64,
            detectedSampleRate: 96_000,
            bufferFrameSize: 256,
            lastCallbackFrames: 256,
            maxObservedCallbackFrames: 256,
            dropoutDelta: 0,
            outputUnderrunDelta: 0,
            outputRingTargetFrames: 4_096,
            minOutputRingFillFrames: 3_200,
            maxOutputRingFillFrames: 5_000,
            maxAbsOutputClockCorrectionPpm: 950,
            watchdogSafeActive: false,
            channelMappings: simulatedMappings(count: 64),
            minStreamOutputLevelsDb: [-42.0, -41.0],
            maxStreamOutputLevelsDb: [-12.0, -11.0],
            maxActiveInputChannelCount: 12,
            minMomentaryLufs: -34.0,
            maxMomentaryLufs: -18.0,
            minLimiterGainReductionDb: -2.0
        )

        let drift = try XCTUnwrap(report.checks.first { $0.name == "Output Clock Drift" })
        XCTAssertFalse(report.passed)
        XCTAssertFalse(drift.passed)
        XCTAssertEqual(Set(report.checks.filter { !$0.passed }.map(\.name)), ["Output Clock Drift"])
    }

    func testStabilityMonitorReportFlagsFormatAndInputMapProblems() throws {
        var mappings = simulatedMappings(count: 64)
        mappings[1].inputChannelIndex = 0
        let badInput = SoundcheckDeviceSnapshot(
            uid: "dante.input",
            name: "Dante Virtual Soundcard",
            inputChannels: 64,
            outputChannels: 0,
            sampleRate: 96_000,
            inputFormatSummary: "lpcm signed-int 24-bit",
            outputFormatSummary: "no output streams",
            inputFormatSupported: false,
            outputFormatSupported: false
        )

        let report = StabilityMonitorReport.make(
            generatedAt: Date(timeIntervalSince1970: 0),
            durationSeconds: 300,
            inputDevice: badInput,
            outputDevice: simulatedDeviceSnapshot(),
            scene: .worship,
            expectedInputChannels: 64,
            detectedInputChannels: 64,
            detectedSampleRate: 96_000,
            bufferFrameSize: 256,
            lastCallbackFrames: 256,
            maxObservedCallbackFrames: 256,
            dropoutDelta: 0,
            outputUnderrunDelta: 0,
            watchdogSafeActive: false,
            channelMappings: mappings,
            minStreamOutputLevelsDb: [-42.0, -41.0],
            maxStreamOutputLevelsDb: [-12.0, -11.0],
            maxActiveInputChannelCount: 12,
            minMomentaryLufs: -34.0,
            maxMomentaryLufs: -18.0,
            minLimiterGainReductionDb: -2.0
        )

        let formatCheck = try XCTUnwrap(report.checks.first { $0.name == "Core Audio Format" })
        let mapCheck = try XCTUnwrap(report.checks.first { $0.name == "Input Map Coverage" })
        XCTAssertFalse(report.passed)
        XCTAssertFalse(formatCheck.passed)
        XCTAssertFalse(mapCheck.passed)
        XCTAssertTrue(formatCheck.observed.localizedCaseInsensitiveContains("signed-int"))
        XCTAssertTrue(mapCheck.observed.localizedCaseInsensitiveContains("duplicate Dante In 1"))
    }

    func testCoreAudioFullCheckManifestRequiresAllHardwareReportsToPass() throws {
        var manifest = CoreAudioFullCheckManifest(
            generatedAt: Date(timeIntervalSince1970: 0),
            validationSource: .simulatedHD96Dante,
            inputDevice: simulatedDeviceSnapshot(),
            outputDevice: simulatedDeviceSnapshot(),
            expectedInputChannels: 64,
            scene: .worship,
            soundcheckSeconds: 10,
            stabilitySeconds: 300,
            preflightReportPath: "/tmp/preflight.json",
            preflightReady: true
        )

        XCTAssertFalse(manifest.passed)
        XCTAssertNil(manifest.deviceInventoryPath)
        XCTAssertNil(manifest.soundcheckPassed)
        XCTAssertNil(manifest.stabilityPassed)

        manifest.recordDeviceInventory(path: "/tmp/inventory.json")
        XCTAssertEqual(manifest.deviceInventoryPath, "/tmp/inventory.json")
        XCTAssertFalse(manifest.passed)

        manifest.recordSoundcheck(
            recordingPath: "/tmp/soundcheck.wav",
            reportPath: "/tmp/soundcheck.json",
            passed: true
        )
        XCTAssertFalse(manifest.passed)

        manifest.recordStability(reportPath: "/tmp/stability.json", passed: true)
        XCTAssertTrue(manifest.passed)
        XCTAssertFalse(manifest.hardwareProofPassed)
        XCTAssertTrue(manifest.hardwareProofSummary.localizedCaseInsensitiveContains("simulated validation passed"))

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(CoreAudioFullCheckManifest.self, from: data)
        XCTAssertEqual(decoded, manifest)

        manifest.markFailure("stability report did not pass")
        XCTAssertFalse(manifest.passed)
        XCTAssertEqual(manifest.failureReason, "stability report did not pass")
    }

    func testCoreAudioFullCheckManifestRequiresInventoryAndHardwareSourceForHardwareProof() throws {
        var missingInventory = CoreAudioFullCheckManifest(
            generatedAt: Date(timeIntervalSince1970: 0),
            validationSource: .coreAudioDevice,
            inputDevice: simulatedDeviceSnapshot(),
            outputDevice: simulatedDeviceSnapshot(),
            expectedInputChannels: 64,
            scene: .worship,
            soundcheckSeconds: 10,
            stabilitySeconds: 300,
            preflightReportPath: "/tmp/preflight.json",
            preflightReady: true
        )

        missingInventory.recordSoundcheck(
            recordingPath: "/tmp/soundcheck.wav",
            reportPath: "/tmp/soundcheck.json",
            passed: true
        )
        missingInventory.recordStability(reportPath: "/tmp/stability.json", passed: true)
        XCTAssertFalse(missingInventory.passed)
        XCTAssertFalse(missingInventory.hardwareProofPassed)
        XCTAssertTrue(missingInventory.hardwareProofSummary.localizedCaseInsensitiveContains("missing"))

        var hardwareManifest = CoreAudioFullCheckManifest(
            generatedAt: Date(timeIntervalSince1970: 0),
            validationSource: .coreAudioDevice,
            inputDevice: simulatedDeviceSnapshot(),
            outputDevice: simulatedDeviceSnapshot(),
            expectedInputChannels: 64,
            scene: .worship,
            soundcheckSeconds: 10,
            stabilitySeconds: 300,
            deviceInventoryPath: "/tmp/inventory.json",
            preflightReportPath: "/tmp/preflight.json",
            preflightReady: true
        )
        hardwareManifest.recordSoundcheck(
            recordingPath: "/tmp/soundcheck.wav",
            reportPath: "/tmp/soundcheck.json",
            passed: true
        )
        hardwareManifest.recordStability(reportPath: "/tmp/stability.json", passed: true)

        XCTAssertTrue(hardwareManifest.passed)
        XCTAssertTrue(hardwareManifest.hardwareProofPassed)
        XCTAssertEqual(hardwareManifest.hardwareProofSummary, "HD96/Dante hardware proof passed.")
    }

    func testCoreAudioFullCheckManifestDefaultsHardwareProofFieldsForOlderJSON() throws {
        let data = Data("""
        {
          "generatedAt": 0,
          "validationSource": "simulated-hd96-dante",
          "inputDevice": {
            "uid": "com.livedaw.automix.simulated-hd96-dante",
            "name": "Simulated HD96 Dante Split",
            "inputChannels": 64,
            "outputChannels": 2,
            "sampleRate": 96000,
            "inputFormatSummary": "32-bit little-endian float PCM",
            "outputFormatSummary": "32-bit little-endian float PCM",
            "inputFormatSupported": true,
            "outputFormatSupported": true
          },
          "outputDevice": {
            "uid": "com.livedaw.automix.simulated-hd96-dante",
            "name": "Simulated HD96 Dante Split",
            "inputChannels": 64,
            "outputChannels": 2,
            "sampleRate": 96000,
            "inputFormatSummary": "32-bit little-endian float PCM",
            "outputFormatSummary": "32-bit little-endian float PCM",
            "inputFormatSupported": true,
            "outputFormatSupported": true
          },
          "expectedInputChannels": 64,
          "scene": "worship",
          "soundcheckSeconds": 10,
          "stabilitySeconds": 300,
          "deviceInventoryPath": "/tmp/inventory.json",
          "preflightReportPath": "/tmp/preflight.json",
          "soundcheckRecordingPath": "/tmp/soundcheck.wav",
          "soundcheckReportPath": "/tmp/soundcheck.json",
          "stabilityReportPath": "/tmp/stability.json",
          "preflightReady": true,
          "soundcheckPassed": true,
          "stabilityPassed": true,
          "passed": true
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(CoreAudioFullCheckManifest.self, from: data)

        XCTAssertTrue(decoded.passed)
        XCTAssertFalse(decoded.hardwareProofPassed)
        XCTAssertTrue(decoded.hardwareProofSummary.localizedCaseInsensitiveContains("simulated validation passed"))
    }

    func testCoreAudioFullCheckVerifierRequiresHardwareProofAndArtifacts() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let manifestURL = try writeFullCheckProofFixture(
            in: directory,
            validationSource: .coreAudioDevice
        )

        let result = try CoreAudioFullCheckVerifier.verifyManifest(at: manifestURL)

        XCTAssertTrue(result.passed)
        XCTAssertTrue(result.hardwareProofPassed)
        XCTAssertEqual(result.summary, "HD96/Dante hardware proof verified.")
        XCTAssertTrue(result.artifactChecks.allSatisfy(\.passed))
        XCTAssertTrue(result.proofChecks.allSatisfy(\.passed))
        XCTAssertTrue(result.artifactChecks.allSatisfy { $0.path.hasPrefix(directory.path) })
    }

    func testCoreAudioFullCheckVerifierRejectsManifestRouteSampleRateDrift() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let manifestURL = try writeFullCheckProofFixture(
            in: directory,
            validationSource: .coreAudioDevice
        )
        var manifest = try readJSON(CoreAudioFullCheckManifest.self, from: manifestURL)
        manifest.inputDevice.sampleRate = 48_000
        try writeJSON(manifest, to: manifestURL)

        let result = try CoreAudioFullCheckVerifier.verifyManifest(at: manifestURL)
        let routeCheck = try XCTUnwrap(result.proofChecks.first { $0.name == "Manifest Route Semantics" })

        XCTAssertFalse(result.passed)
        XCTAssertFalse(result.hardwareProofPassed)
        XCTAssertFalse(routeCheck.passed)
        XCTAssertTrue(result.artifactChecks.allSatisfy(\.passed))
        XCTAssertEqual(routeCheck.summary, "manifest route snapshot is not a ready 96 kHz HD96 input plus isolated stream output")
    }

    func testCoreAudioFullCheckVerifierRejectsManifestRouteOutputIsolationDrift() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let manifestURL = try writeFullCheckProofFixture(
            in: directory,
            validationSource: .coreAudioDevice
        )
        var manifest = try readJSON(CoreAudioFullCheckManifest.self, from: manifestURL)
        manifest.outputDevice.name = "Midas HD96 Dante Return"
        try writeJSON(manifest, to: manifestURL)

        let result = try CoreAudioFullCheckVerifier.verifyManifest(at: manifestURL)
        let routeCheck = try XCTUnwrap(result.proofChecks.first { $0.name == "Manifest Route Semantics" })

        XCTAssertFalse(result.passed)
        XCTAssertFalse(result.hardwareProofPassed)
        XCTAssertFalse(routeCheck.passed)
        XCTAssertTrue(result.artifactChecks.allSatisfy(\.passed))
        XCTAssertEqual(routeCheck.summary, "manifest route snapshot is not a ready 96 kHz HD96 input plus isolated stream output")
    }

    func testCoreAudioFullCheckVerifierRequiresInventorySelectedUIDsToMatchManifestRoute() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let manifestURL = try writeFullCheckProofFixture(
            in: directory,
            validationSource: .coreAudioDevice
        )
        let inventoryURL = directory.appendingPathComponent("inventory.json")
        var inventory = try readJSON(CoreAudioDeviceInventory.self, from: inventoryURL)
        inventory.selectedInputUID = nil
        inventory.selectedOutputUID = nil
        try writeJSON(inventory, to: inventoryURL)

        let result = try CoreAudioFullCheckVerifier.verifyManifest(at: manifestURL)
        let inventoryCheck = try XCTUnwrap(result.proofChecks.first { $0.name == "Device Inventory Semantics" })

        XCTAssertFalse(result.passed)
        XCTAssertFalse(result.hardwareProofPassed)
        XCTAssertFalse(inventoryCheck.passed)
        XCTAssertEqual(result.summary, "Full check proof artifacts failed semantic verification.")
        XCTAssertEqual(inventoryCheck.summary, "inventory selected UIDs do not match manifest input/output route")
    }

    func testCoreAudioFullCheckVerifierAcceptsWrappedPreflightProofArtifact() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let manifestURL = try writeFullCheckProofFixture(
            in: directory,
            validationSource: .coreAudioDevice
        )
        let mappings = simulatedMappings(count: 64)
        let preflight = HD96PreflightReport.make(
            inputDevice: hardwareInputDeviceInfo(),
            outputDevice: hardwareOutputDeviceInfo(),
            expectedInputChannels: 64,
            detectedInputChannels: 64,
            detectedSampleRate: 96_000,
            channelMappings: mappings
        )
        let artifact = CoreAudioPreflightProofArtifact(
            generatedAt: Date(timeIntervalSince1970: 0),
            inputDevice: hardwareInputSnapshot(),
            outputDevice: hardwareOutputSnapshot(),
            expectedInputChannels: 64,
            detectedInputChannels: 64,
            detectedSampleRate: 96_000,
            channelMappings: mappings,
            validationSource: .coreAudioDevice,
            report: preflight
        )
        try writeJSON(artifact, to: directory.appendingPathComponent("preflight.json"))

        let result = try CoreAudioFullCheckVerifier.verifyManifest(at: manifestURL)
        let preflightCheck = try XCTUnwrap(result.proofChecks.first { $0.name == "Preflight Report Semantics" })

        XCTAssertTrue(result.passed)
        XCTAssertTrue(result.hardwareProofPassed)
        XCTAssertTrue(preflightCheck.passed)
        XCTAssertEqual(preflightCheck.summary, "HD96 route ready")
    }

    func testCoreAudioFullCheckVerifierRejectsWrappedPreflightProofRouteMismatch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let manifestURL = try writeFullCheckProofFixture(
            in: directory,
            validationSource: .coreAudioDevice
        )
        let mappings = simulatedMappings(count: 64)
        let preflight = HD96PreflightReport.make(
            inputDevice: hardwareInputDeviceInfo(),
            outputDevice: hardwareOutputDeviceInfo(),
            expectedInputChannels: 64,
            detectedInputChannels: 64,
            detectedSampleRate: 96_000,
            channelMappings: mappings
        )
        let artifact = CoreAudioPreflightProofArtifact(
            generatedAt: Date(timeIntervalSince1970: 0),
            inputDevice: simulatedDeviceSnapshot(),
            outputDevice: hardwareOutputSnapshot(),
            expectedInputChannels: 64,
            detectedInputChannels: 64,
            detectedSampleRate: 96_000,
            channelMappings: mappings,
            validationSource: .simulatedHD96Dante,
            report: preflight
        )
        try writeJSON(artifact, to: directory.appendingPathComponent("preflight.json"))

        let result = try CoreAudioFullCheckVerifier.verifyManifest(at: manifestURL)
        let preflightCheck = try XCTUnwrap(result.proofChecks.first { $0.name == "Preflight Report Semantics" })

        XCTAssertFalse(result.passed)
        XCTAssertFalse(result.hardwareProofPassed)
        XCTAssertFalse(preflightCheck.passed)
        XCTAssertEqual(result.summary, "Full check proof artifacts failed semantic verification.")
        XCTAssertEqual(preflightCheck.summary, "preflight artifact does not match manifest route, source, channel count, format, or readiness")
    }

    func testCoreAudioFullCheckVerifierRejectsSoundcheckRouteSnapshotDrift() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let manifestURL = try writeFullCheckProofFixture(
            in: directory,
            validationSource: .coreAudioDevice
        )
        let soundcheckURL = directory.appendingPathComponent("soundcheck.json")
        var soundcheck = try readJSON(SoundcheckReport.self, from: soundcheckURL)
        soundcheck.inputDevice.sampleRate = 48_000
        try writeJSON(soundcheck, to: soundcheckURL)

        let result = try CoreAudioFullCheckVerifier.verifyManifest(at: manifestURL)
        let soundcheckCheck = try XCTUnwrap(result.proofChecks.first { $0.name == "Soundcheck Report Semantics" })

        XCTAssertFalse(result.passed)
        XCTAssertFalse(result.hardwareProofPassed)
        XCTAssertFalse(soundcheckCheck.passed)
        XCTAssertEqual(result.summary, "Full check proof artifacts failed semantic verification.")
        XCTAssertEqual(soundcheckCheck.summary, "soundcheck report does not match manifest, route, source, or pass criteria")
    }

    func testCoreAudioFullCheckVerifierRejectsStabilityRouteSnapshotDrift() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let manifestURL = try writeFullCheckProofFixture(
            in: directory,
            validationSource: .coreAudioDevice
        )
        let stabilityURL = directory.appendingPathComponent("stability.json")
        var stability = try readJSON(StabilityMonitorReport.self, from: stabilityURL)
        stability.outputDevice.sampleRate = 48_000
        try writeJSON(stability, to: stabilityURL)

        let result = try CoreAudioFullCheckVerifier.verifyManifest(at: manifestURL)
        let stabilityCheck = try XCTUnwrap(result.proofChecks.first { $0.name == "Stability Report Semantics" })

        XCTAssertFalse(result.passed)
        XCTAssertFalse(result.hardwareProofPassed)
        XCTAssertFalse(stabilityCheck.passed)
        XCTAssertEqual(result.summary, "Full check proof artifacts failed semantic verification.")
        XCTAssertEqual(stabilityCheck.summary, "stability report does not match manifest, route, source, duration, or pass criteria")
    }

    func testCoreAudioFullCheckVerifierRejectsSoundcheckProofControlDrift() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let manifestURL = try writeFullCheckProofFixture(
            in: directory,
            validationSource: .coreAudioDevice
        )
        let soundcheckURL = directory.appendingPathComponent("soundcheck.json")
        var soundcheck = try readJSON(SoundcheckReport.self, from: soundcheckURL)
        soundcheck.safeBypassEnabled = false
        try writeJSON(soundcheck, to: soundcheckURL)

        let result = try CoreAudioFullCheckVerifier.verifyManifest(at: manifestURL)
        let soundcheckCheck = try XCTUnwrap(result.proofChecks.first { $0.name == "Soundcheck Report Semantics" })

        XCTAssertFalse(result.passed)
        XCTAssertFalse(result.hardwareProofPassed)
        XCTAssertFalse(soundcheckCheck.passed)
        XCTAssertEqual(result.summary, "Full check proof artifacts failed semantic verification.")
        XCTAssertEqual(soundcheckCheck.summary, "soundcheck report does not match manifest, route, source, or pass criteria")
    }

    func testCoreAudioFullCheckVerifierRejectsFailedSoundcheckEmbeddedCheck() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let manifestURL = try writeFullCheckProofFixture(
            in: directory,
            validationSource: .coreAudioDevice
        )
        let soundcheckURL = directory.appendingPathComponent("soundcheck.json")
        var soundcheck = try readJSON(SoundcheckReport.self, from: soundcheckURL)
        let dropoutCheckIndex = try XCTUnwrap(soundcheck.checks.firstIndex { $0.name == "Dropouts" })
        soundcheck.checks[dropoutCheckIndex].passed = false
        XCTAssertTrue(soundcheck.passed)
        try writeJSON(soundcheck, to: soundcheckURL)

        let result = try CoreAudioFullCheckVerifier.verifyManifest(at: manifestURL)
        let soundcheckCheck = try XCTUnwrap(result.proofChecks.first { $0.name == "Soundcheck Report Semantics" })

        XCTAssertFalse(result.passed)
        XCTAssertFalse(result.hardwareProofPassed)
        XCTAssertFalse(soundcheckCheck.passed)
        XCTAssertEqual(result.summary, "Full check proof artifacts failed semantic verification.")
        XCTAssertEqual(soundcheckCheck.summary, "soundcheck report does not match manifest, route, source, or pass criteria")
    }

    func testCoreAudioFullCheckVerifierRejectsStabilityProofControlDrift() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let manifestURL = try writeFullCheckProofFixture(
            in: directory,
            validationSource: .coreAudioDevice
        )
        let stabilityURL = directory.appendingPathComponent("stability.json")
        var stability = try readJSON(StabilityMonitorReport.self, from: stabilityURL)
        stability.safeBypassEnabled = true
        try writeJSON(stability, to: stabilityURL)

        let result = try CoreAudioFullCheckVerifier.verifyManifest(at: manifestURL)
        let stabilityCheck = try XCTUnwrap(result.proofChecks.first { $0.name == "Stability Report Semantics" })

        XCTAssertFalse(result.passed)
        XCTAssertFalse(result.hardwareProofPassed)
        XCTAssertFalse(stabilityCheck.passed)
        XCTAssertEqual(result.summary, "Full check proof artifacts failed semantic verification.")
        XCTAssertEqual(stabilityCheck.summary, "stability report does not match manifest, route, source, duration, or pass criteria")
    }

    func testCoreAudioFullCheckVerifierRejectsFailedStabilityEmbeddedCheck() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let manifestURL = try writeFullCheckProofFixture(
            in: directory,
            validationSource: .coreAudioDevice
        )
        let stabilityURL = directory.appendingPathComponent("stability.json")
        var stability = try readJSON(StabilityMonitorReport.self, from: stabilityURL)
        let underrunCheckIndex = try XCTUnwrap(stability.checks.firstIndex { $0.name == "Output Underruns" })
        stability.checks[underrunCheckIndex].passed = false
        XCTAssertTrue(stability.passed)
        try writeJSON(stability, to: stabilityURL)

        let result = try CoreAudioFullCheckVerifier.verifyManifest(at: manifestURL)
        let stabilityCheck = try XCTUnwrap(result.proofChecks.first { $0.name == "Stability Report Semantics" })

        XCTAssertFalse(result.passed)
        XCTAssertFalse(result.hardwareProofPassed)
        XCTAssertFalse(stabilityCheck.passed)
        XCTAssertEqual(result.summary, "Full check proof artifacts failed semantic verification.")
        XCTAssertEqual(stabilityCheck.summary, "stability report does not match manifest, route, source, duration, or pass criteria")
    }

    func testCoreAudioFullCheckVerifierRejectsSoundcheckProfileMapMismatch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let manifestURL = try writeFullCheckProofFixture(
            in: directory,
            validationSource: .coreAudioDevice
        )
        let soundcheckURL = directory.appendingPathComponent("soundcheck.json")
        var soundcheck = try readJSON(SoundcheckReport.self, from: soundcheckURL)
        soundcheck.channelMappings[0].inputChannelIndex = 1
        try writeJSON(soundcheck, to: soundcheckURL)

        let result = try CoreAudioFullCheckVerifier.verifyManifest(at: manifestURL)
        let profileMapCheck = try XCTUnwrap(result.proofChecks.first { $0.name == "Profile Map Semantics" })

        XCTAssertFalse(result.passed)
        XCTAssertFalse(result.hardwareProofPassed)
        XCTAssertFalse(profileMapCheck.passed)
        XCTAssertEqual(result.summary, "Full check proof artifacts failed semantic verification.")
        XCTAssertEqual(profileMapCheck.summary, "preflight, soundcheck, and stability channel maps do not match")
    }

    func testCoreAudioFullCheckVerifierRejectsStabilityProfileMapMismatch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let manifestURL = try writeFullCheckProofFixture(
            in: directory,
            validationSource: .coreAudioDevice
        )
        let stabilityURL = directory.appendingPathComponent("stability.json")
        var stability = try readJSON(StabilityMonitorReport.self, from: stabilityURL)
        stability.channelMappings[0].panOverrideEnabled = true
        stability.channelMappings[0].pan = 0.5
        try writeJSON(stability, to: stabilityURL)

        let result = try CoreAudioFullCheckVerifier.verifyManifest(at: manifestURL)
        let profileMapCheck = try XCTUnwrap(result.proofChecks.first { $0.name == "Profile Map Semantics" })

        XCTAssertFalse(result.passed)
        XCTAssertFalse(result.hardwareProofPassed)
        XCTAssertFalse(profileMapCheck.passed)
        XCTAssertEqual(result.summary, "Full check proof artifacts failed semantic verification.")
        XCTAssertEqual(profileMapCheck.summary, "preflight, soundcheck, and stability channel maps do not match")
    }

    func testCoreAudioFullCheckVerifierRejectsSimulatedOrMissingArtifactProof() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let manifestURL = try writeFullCheckProofFixture(
            in: directory,
            validationSource: .simulatedHD96Dante
        )
        try FileManager.default.removeItem(at: directory.appendingPathComponent("stability.json"))

        let result = try CoreAudioFullCheckVerifier.verifyManifest(at: manifestURL)

        XCTAssertFalse(result.passed)
        XCTAssertFalse(result.hardwareProofPassed)
        XCTAssertEqual(result.summary, "Full check references missing or empty proof artifacts.")
        let stabilityArtifact = try XCTUnwrap(result.artifactChecks.first { $0.name == "Stability Report" })
        XCTAssertFalse(stabilityArtifact.passed)
        XCTAssertFalse(stabilityArtifact.exists)

        _ = try writeFullCheckProofFixture(
            in: directory,
            validationSource: .simulatedHD96Dante
        )
        let simulatedResult = try CoreAudioFullCheckVerifier.verifyManifest(at: manifestURL)
        XCTAssertTrue(simulatedResult.passed)
        XCTAssertFalse(simulatedResult.hardwareProofPassed)
        XCTAssertTrue(simulatedResult.proofChecks.allSatisfy(\.passed))
        XCTAssertTrue(simulatedResult.summary.localizedCaseInsensitiveContains("simulated validation passed"))
    }

    func testCoreAudioFullCheckVerifierRejectsDummyProofArtifacts() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for name in ["inventory.json", "preflight.json", "soundcheck.wav", "soundcheck.json", "stability.json"] {
            try Data("proof".utf8).write(to: directory.appendingPathComponent(name))
        }

        var manifest = CoreAudioFullCheckManifest(
            generatedAt: Date(timeIntervalSince1970: 0),
            validationSource: .coreAudioDevice,
            inputDevice: hardwareInputSnapshot(),
            outputDevice: hardwareOutputSnapshot(),
            expectedInputChannels: 64,
            scene: .worship,
            soundcheckSeconds: 0.05,
            stabilitySeconds: 30,
            deviceInventoryPath: "inventory.json",
            preflightReportPath: "preflight.json",
            preflightReady: true
        )
        manifest.recordSoundcheck(
            recordingPath: "soundcheck.wav",
            reportPath: "soundcheck.json",
            passed: true
        )
        manifest.recordStability(reportPath: "stability.json", passed: true)

        let manifestURL = directory.appendingPathComponent("manifest.json")
        try writeJSON(manifest, to: manifestURL)

        let result = try CoreAudioFullCheckVerifier.verifyManifest(at: manifestURL)

        XCTAssertFalse(result.passed)
        XCTAssertFalse(result.hardwareProofPassed)
        XCTAssertEqual(result.summary, "Full check proof artifacts failed semantic verification.")
        XCTAssertTrue(result.artifactChecks.allSatisfy(\.passed))
        XCTAssertFalse(result.proofChecks.allSatisfy(\.passed))
    }

    func testCoreAudioFullCheckVerifierRejectsSilentWavDespitePassingReport() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let manifestURL = try writeFullCheckProofFixture(
            in: directory,
            validationSource: .coreAudioDevice
        )
        _ = try writeFloatWavFixture(
            to: directory.appendingPathComponent("soundcheck.wav"),
            channelCount: 66,
            sampleRate: 96_000,
            seconds: 0.05,
            activeSignal: false
        )

        let result = try CoreAudioFullCheckVerifier.verifyManifest(at: manifestURL)
        let signalCheck = try XCTUnwrap(result.proofChecks.first { $0.name == "Soundcheck WAV Signal Semantics" })

        XCTAssertFalse(result.passed)
        XCTAssertFalse(result.hardwareProofPassed)
        XCTAssertFalse(signalCheck.passed)
        XCTAssertEqual(result.summary, "Full check proof artifacts failed semantic verification.")
        XCTAssertEqual(signalCheck.summary, "WAV payload activity does not match soundcheck report or required stream/input activity")
    }

    private func writeFullCheckProofFixture(
        in directory: URL,
        validationSource: AudioValidationSource
    ) throws -> URL {
        let inputSnapshot: SoundcheckDeviceSnapshot
        let outputSnapshot: SoundcheckDeviceSnapshot
        let inputInfo: AMDeviceInfo
        let outputInfo: AMDeviceInfo
        switch validationSource {
        case .coreAudioDevice:
            inputSnapshot = hardwareInputSnapshot()
            outputSnapshot = hardwareOutputSnapshot()
            inputInfo = hardwareInputDeviceInfo()
            outputInfo = hardwareOutputDeviceInfo()
        case .simulatedHD96Dante:
            inputSnapshot = simulatedDeviceSnapshot()
            outputSnapshot = simulatedDeviceSnapshot()
            inputInfo = AMDeviceInfo(
                uid: inputSnapshot.uid,
                name: inputSnapshot.name,
                inputChannels: inputSnapshot.inputChannels,
                outputChannels: inputSnapshot.outputChannels,
                sampleRate: inputSnapshot.sampleRate
            )
            outputInfo = inputInfo
        }

        let soundcheckSeconds = 0.05
        let stabilitySeconds = 30.0
        let soundcheckWavURL = directory.appendingPathComponent("soundcheck.wav")
        let wavMetadata = try writeFloatWavFixture(
            to: soundcheckWavURL,
            channelCount: 66,
            sampleRate: 96_000,
            seconds: soundcheckSeconds
        )
        let wavByteCount = 44 + wavMetadata.dataByteCount
        let mappings = simulatedMappings(count: 64)

        let inventory = CoreAudioDeviceInventory.make(
            generatedAt: Date(timeIntervalSince1970: 0),
            devices: [inputInfo, outputInfo],
            expectedInputChannels: 64,
            selectedInputUID: inputSnapshot.uid,
            selectedOutputUID: outputSnapshot.uid
        )
        try writeJSON(inventory, to: directory.appendingPathComponent("inventory.json"))

        let preflight = HD96PreflightReport.make(
            inputDevice: inputInfo,
            outputDevice: outputInfo,
            expectedInputChannels: 64,
            detectedInputChannels: 64,
            detectedSampleRate: 96_000,
            channelMappings: mappings
        )
        let preflightArtifact = CoreAudioPreflightProofArtifact(
            generatedAt: Date(timeIntervalSince1970: 0),
            inputDevice: inputSnapshot,
            outputDevice: outputSnapshot,
            expectedInputChannels: 64,
            detectedInputChannels: 64,
            detectedSampleRate: 96_000,
            channelMappings: mappings,
            validationSource: validationSource,
            report: preflight
        )
        try writeJSON(preflightArtifact, to: directory.appendingPathComponent("preflight.json"))

        let soundcheck = SoundcheckReport.make(
            generatedAt: Date(timeIntervalSince1970: 0),
            recordingPath: "soundcheck.wav",
            recordingByteCount: wavByteCount,
            recordingChannelCount: wavMetadata.channelCount,
            recordingSampleRate: wavMetadata.sampleRate,
            recordingFrameCount: wavMetadata.frameCount,
            recordingDurationSeconds: wavMetadata.durationSeconds,
            expectedRecordingDurationSeconds: soundcheckSeconds,
            inputDevice: inputSnapshot,
            outputDevice: outputSnapshot,
            validationSource: validationSource,
            scene: .worship,
            expectedInputChannels: 64,
            detectedInputChannels: 64,
            detectedSampleRate: 96_000,
            bufferFrameSize: 256,
            lastCallbackFrames: 256,
            maxObservedCallbackFrames: 256,
            dropoutCount: 0,
            outputUnderrunCount: 0,
            watchdogSafeActive: false,
            safeBypassEnabled: true,
            frozen: false,
            channelMappings: mappings,
            latestInputLevelsDb: Array(repeating: -30.0, count: 64),
            latestStreamOutputLevelsDb: [-24.0, -24.0],
            latestMomentaryLufs: -23.0,
            latestShortTermLufs: -24.0,
            latestIntegratedLufs: -25.0,
            latestLimiterGainReductionDb: -1.0,
            recordedActiveInputChannelCount: 64,
            recordedActiveInputChannels: Array(1...64),
            recordedStreamOutputActiveChannelCount: 2,
            recordedInputPeakDb: -28.0,
            recordedInputPeakDbByChannel: Array(repeating: -28.0, count: 64),
            recordedStreamOutputPeakDb: [-24.0, -24.0]
        )
        XCTAssertTrue(soundcheck.passed)
        try writeJSON(soundcheck, to: directory.appendingPathComponent("soundcheck.json"))

        let stability = StabilityMonitorReport.make(
            generatedAt: Date(timeIntervalSince1970: 0),
            durationSeconds: stabilitySeconds,
            inputDevice: inputSnapshot,
            outputDevice: outputSnapshot,
            validationSource: validationSource,
            scene: .worship,
            expectedInputChannels: 64,
            detectedInputChannels: 64,
            detectedSampleRate: 96_000,
            bufferFrameSize: 256,
            lastCallbackFrames: 256,
            maxObservedCallbackFrames: 256,
            dropoutDelta: 0,
            outputUnderrunDelta: 0,
            outputRingTargetFrames: 4_096,
            minOutputRingFillFrames: 3_500,
            maxOutputRingFillFrames: 4_600,
            maxAbsOutputClockCorrectionPpm: 150,
            watchdogSafeActive: false,
            channelMappings: mappings,
            minStreamOutputLevelsDb: [-42.0, -41.0],
            maxStreamOutputLevelsDb: [-12.0, -11.0],
            maxActiveInputChannelCount: 64,
            minMomentaryLufs: -34.0,
            maxMomentaryLufs: -18.0,
            minLimiterGainReductionDb: -2.0
        )
        XCTAssertTrue(stability.passed)
        try writeJSON(stability, to: directory.appendingPathComponent("stability.json"))

        var manifest = CoreAudioFullCheckManifest(
            generatedAt: Date(timeIntervalSince1970: 0),
            validationSource: validationSource,
            inputDevice: inputSnapshot,
            outputDevice: outputSnapshot,
            expectedInputChannels: 64,
            scene: .worship,
            soundcheckSeconds: soundcheckSeconds,
            stabilitySeconds: stabilitySeconds,
            deviceInventoryPath: "inventory.json",
            preflightReportPath: "preflight.json",
            preflightReady: preflight.isReady
        )
        manifest.recordSoundcheck(
            recordingPath: "soundcheck.wav",
            reportPath: "soundcheck.json",
            passed: soundcheck.passed
        )
        manifest.recordStability(reportPath: "stability.json", passed: stability.passed)

        let manifestURL = directory.appendingPathComponent("manifest.json")
        try writeJSON(manifest, to: manifestURL)
        return manifestURL
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    private func readJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: url)
        return try decoder.decode(T.self, from: data)
    }

    @discardableResult
    private func writeFloatWavFixture(
        to url: URL,
        channelCount: Int,
        sampleRate: Int,
        seconds: Double,
        activeSignal: Bool = true
    ) throws -> WavMetadata {
        let frameCount = max(1, Int((Double(sampleRate) * seconds).rounded()))
        let bitsPerSample = 32
        let bytesPerSample = bitsPerSample / 8
        let blockAlign = channelCount * bytesPerSample
        let dataByteCount = frameCount * blockAlign
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(contentsOf: uint32LE(36 + dataByteCount))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        data.append(contentsOf: uint32LE(16))
        data.append(contentsOf: uint16LE(3))
        data.append(contentsOf: uint16LE(UInt16(channelCount)))
        data.append(contentsOf: uint32LE(UInt32(sampleRate)))
        data.append(contentsOf: uint32LE(UInt32(sampleRate * blockAlign)))
        data.append(contentsOf: uint16LE(UInt16(blockAlign)))
        data.append(contentsOf: uint16LE(UInt16(bitsPerSample)))
        data.append(contentsOf: Array("data".utf8))
        data.append(contentsOf: uint32LE(dataByteCount))
        for frame in 0..<frameCount {
            for channel in 0..<channelCount {
                data.append(contentsOf: float32LE(sampleFixtureValue(frame: frame, channel: channel, channelCount: channelCount, activeSignal: activeSignal)))
            }
        }
        try data.write(to: url, options: .atomic)
        return try WavMetadata.read(from: url)
    }

    private func sampleFixtureValue(frame: Int, channel: Int, channelCount: Int, activeSignal: Bool) -> Float {
        guard activeSignal else { return 0.0 }
        let streamStartChannel = max(0, channelCount - 2)
        let magnitude: Float = channel >= streamStartChannel ? 0.063095734 : 0.039810717
        return (frame + channel).isMultiple(of: 2) ? magnitude : -magnitude
    }

    private func float32LE(_ value: Float) -> [UInt8] {
        uint32LE(value.bitPattern)
    }

    private func uint16LE(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0x00ff), UInt8((value >> 8) & 0x00ff)]
    }

    private func uint32LE(_ value: Int) -> [UInt8] {
        uint32LE(UInt32(value))
    }

    private func uint32LE(_ value: UInt32) -> [UInt8] {
        [
            UInt8(value & 0x000000ff),
            UInt8((value >> 8) & 0x000000ff),
            UInt8((value >> 16) & 0x000000ff),
            UInt8((value >> 24) & 0x000000ff)
        ]
    }

    private func hardwareInputDeviceInfo() -> AMDeviceInfo {
        AMDeviceInfo(
            uid: "com.audinate.dantevirtualsoundcard",
            name: "Dante Virtual Soundcard",
            inputChannels: 64,
            outputChannels: 0,
            sampleRate: 96_000,
            inputFormatSummary: "32-bit little-endian float PCM",
            outputFormatSummary: "no output streams",
            inputFormatSupported: true,
            outputFormatSupported: false
        )
    }

    private func hardwareOutputDeviceInfo() -> AMDeviceInfo {
        AMDeviceInfo(
            uid: "stream.encoder.output",
            name: "Stream Encoder Output",
            inputChannels: 0,
            outputChannels: 2,
            sampleRate: 96_000,
            inputFormatSummary: "no input streams",
            outputFormatSummary: "32-bit little-endian float PCM",
            inputFormatSupported: false,
            outputFormatSupported: true
        )
    }

    private func hardwareInputSnapshot() -> SoundcheckDeviceSnapshot {
        SoundcheckDeviceSnapshot(
            uid: "com.audinate.dantevirtualsoundcard",
            name: "Dante Virtual Soundcard",
            inputChannels: 64,
            outputChannels: 0,
            sampleRate: 96_000,
            inputFormatSummary: "32-bit little-endian float PCM",
            outputFormatSummary: "no output streams",
            inputFormatSupported: true,
            outputFormatSupported: false
        )
    }

    private func hardwareOutputSnapshot() -> SoundcheckDeviceSnapshot {
        SoundcheckDeviceSnapshot(
            uid: "stream.encoder.output",
            name: "Stream Encoder Output",
            inputChannels: 0,
            outputChannels: 2,
            sampleRate: 96_000,
            inputFormatSummary: "no input streams",
            outputFormatSummary: "32-bit little-endian float PCM",
            inputFormatSupported: false,
            outputFormatSupported: true
        )
    }

    private func simulatedRoles(count: Int) -> [String] {
        let seed: [ChannelRole] = [
            .speech,
            .speech,
            .leadVocal,
            .bgv,
            .acousticGuitar,
            .electricGuitar,
            .bass,
            .kick,
            .keys
        ]
        return (0..<count).map { seed[$0 % seed.count].rawValue }
    }

    private func simulatedMappings(count: Int) -> [ChannelMapping] {
        let roles = simulatedRoles(count: count)
        return roles.enumerated().map { index, role in
            ChannelMapping(index: index, name: "Ch \(index + 1)", role: ChannelRole(rawValue: role) ?? .unknown)
        }
    }

    private func identityInputMap(count: Int) -> [NSNumber] {
        (0..<count).map { NSNumber(value: $0) }
    }

    #if DEBUG
    private func debugExtractChannels(
        buffers: [[Float]],
        channelCounts: [Int],
        expectedChannels: Int,
        frames: Int
    ) -> [[Float]] {
        let numberBuffers = buffers.map { buffer in
            buffer.map { NSNumber(value: $0) }
        }
        let numberChannelCounts = channelCounts.map { NSNumber(value: $0) }
        let channels = AutoMixEngineBridge.debugExtractFloat32InputChannels(
            fromBuffers: numberBuffers,
            channelCounts: numberChannelCounts,
            expectedChannels: expectedChannels,
            frames: frames
        )
        return channels.map { channel in
            channel.map(\.floatValue)
        }
    }

    private func outputBufferIsActive(_ samples: [Double]) -> Bool {
        samples.contains { abs($0) > 0.000001 }
    }

    private func outputBufferIsSilent(_ samples: [Double]) -> Bool {
        samples.allSatisfy { abs($0) <= 0.000001 }
    }

    private func outputBufferPeak(_ samples: [Double]) -> Double {
        samples.map { abs($0) }.max() ?? 0
    }
    #endif

    private func simulatedDeviceSnapshot() -> SoundcheckDeviceSnapshot {
        SoundcheckDeviceSnapshot(
            uid: "com.livedaw.automix.simulated-hd96-dante",
            name: "Simulated HD96 Dante Split",
            inputChannels: 64,
            outputChannels: 2,
            sampleRate: 96_000,
            inputFormatSummary: "32-bit little-endian float PCM",
            outputFormatSummary: "32-bit little-endian float PCM",
            inputFormatSupported: true,
            outputFormatSupported: true
        )
    }

    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.025)
        }
        return condition()
    }

    private func readWavHeader(from url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try XCTUnwrap(try handle.read(upToCount: 44))
        XCTAssertGreaterThanOrEqual(data.count, 44)
        return data
    }

    private func uint16LE(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(byte(data, at: offset)) |
            (UInt16(byte(data, at: offset + 1)) << 8)
    }

    private func uint32LE(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(byte(data, at: offset)) |
            (UInt32(byte(data, at: offset + 1)) << 8) |
            (UInt32(byte(data, at: offset + 2)) << 16) |
            (UInt32(byte(data, at: offset + 3)) << 24)
    }

    private func byte(_ data: Data, at offset: Int) -> UInt8 {
        data[data.index(data.startIndex, offsetBy: offset)]
    }
}
