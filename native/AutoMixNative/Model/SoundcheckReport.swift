import Foundation

struct SoundcheckDeviceSnapshot: Codable, Equatable, Sendable {
    var uid: String
    var name: String
    var inputChannels: Int
    var outputChannels: Int
    var sampleRate: Double
    var inputFormatSummary: String
    var outputFormatSummary: String
    var inputFormatSupported: Bool
    var outputFormatSupported: Bool

    init(
        uid: String,
        name: String,
        inputChannels: Int,
        outputChannels: Int,
        sampleRate: Double,
        inputFormatSummary: String = "unknown input format",
        outputFormatSummary: String = "unknown output format",
        inputFormatSupported: Bool = false,
        outputFormatSupported: Bool = false
    ) {
        self.uid = uid
        self.name = name
        self.inputChannels = inputChannels
        self.outputChannels = outputChannels
        self.sampleRate = sampleRate
        self.inputFormatSummary = inputFormatSummary
        self.outputFormatSummary = outputFormatSummary
        self.inputFormatSupported = inputFormatSupported
        self.outputFormatSupported = outputFormatSupported
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uid = try container.decode(String.self, forKey: .uid)
        name = try container.decode(String.self, forKey: .name)
        inputChannels = try container.decode(Int.self, forKey: .inputChannels)
        outputChannels = try container.decode(Int.self, forKey: .outputChannels)
        sampleRate = try container.decode(Double.self, forKey: .sampleRate)
        inputFormatSummary = try container.decodeIfPresent(String.self, forKey: .inputFormatSummary) ?? "unknown input format"
        outputFormatSummary = try container.decodeIfPresent(String.self, forKey: .outputFormatSummary) ?? "unknown output format"
        inputFormatSupported = try container.decodeIfPresent(Bool.self, forKey: .inputFormatSupported) ?? false
        outputFormatSupported = try container.decodeIfPresent(Bool.self, forKey: .outputFormatSupported) ?? false
    }

    static let unknown = SoundcheckDeviceSnapshot(
        uid: "",
        name: "Unknown",
        inputChannels: 0,
        outputChannels: 0,
        sampleRate: 0,
        inputFormatSummary: "unknown input format",
        outputFormatSummary: "unknown output format",
        inputFormatSupported: false,
        outputFormatSupported: false
    )

    init(device: AMDeviceInfo) {
        self.init(
            uid: device.uid,
            name: device.name,
            inputChannels: device.inputChannels,
            outputChannels: device.outputChannels,
            sampleRate: device.sampleRate,
            inputFormatSummary: device.inputFormatSummary,
            outputFormatSummary: device.outputFormatSummary,
            inputFormatSupported: device.inputFormatSupported,
            outputFormatSupported: device.outputFormatSupported
        )
    }
}

extension AMDeviceInfo {
    convenience init(snapshot: SoundcheckDeviceSnapshot) {
        self.init(
            uid: snapshot.uid,
            name: snapshot.name,
            inputChannels: snapshot.inputChannels,
            outputChannels: snapshot.outputChannels,
            sampleRate: snapshot.sampleRate,
            inputFormatSummary: snapshot.inputFormatSummary,
            outputFormatSummary: snapshot.outputFormatSummary,
            inputFormatSupported: snapshot.inputFormatSupported,
            outputFormatSupported: snapshot.outputFormatSupported
        )
    }
}

struct SoundcheckCheck: Codable, Equatable, Identifiable, Sendable {
    var id: String { name }
    var name: String
    var expected: String
    var observed: String
    var passed: Bool
}

enum AudioValidationSource: String, Codable, Equatable, Sendable {
    case simulatedHD96Dante = "simulated-hd96-dante"
    case coreAudioDevice = "core-audio-device"

    var label: String {
        switch self {
        case .simulatedHD96Dante:
            return "Simulated HD96/Dante"
        case .coreAudioDevice:
            return "Core Audio device"
        }
    }

    static func infer(inputDevice: SoundcheckDeviceSnapshot, outputDevice: SoundcheckDeviceSnapshot) -> AudioValidationSource {
        let haystack = [
            inputDevice.uid,
            inputDevice.name,
            outputDevice.uid,
            outputDevice.name
        ]
        .joined(separator: " ")
        .lowercased()

        if haystack.contains("com.livedaw.automix.simulated-hd96-dante") ||
            haystack.contains("simulated hd96 dante") {
            return .simulatedHD96Dante
        }
        return .coreAudioDevice
    }
}

struct LivestreamOutputIsolation: Equatable, Sendable {
    var observed: String
    var passed: Bool

    static func make(inputDevice: AMDeviceInfo?, outputDevice: AMDeviceInfo?) -> LivestreamOutputIsolation {
        make(
            inputName: inputDevice?.name,
            inputUID: inputDevice?.uid,
            outputName: outputDevice?.name,
            outputUID: outputDevice?.uid,
            outputPresent: outputDevice != nil
        )
    }

    static func make(
        inputDevice: SoundcheckDeviceSnapshot,
        outputDevice: SoundcheckDeviceSnapshot
    ) -> LivestreamOutputIsolation {
        make(
            inputName: inputDevice.name,
            inputUID: inputDevice.uid,
            outputName: outputDevice.name,
            outputUID: outputDevice.uid,
            outputPresent: !outputDevice.uid.isEmpty || outputDevice.outputChannels > 0
        )
    }

    private static func make(
        inputName: String?,
        inputUID: String?,
        outputName: String?,
        outputUID: String?,
        outputPresent: Bool
    ) -> LivestreamOutputIsolation {
        guard outputPresent, let outputName, !outputName.isEmpty else {
            return LivestreamOutputIsolation(observed: "no output selected", passed: false)
        }

        let inputUID = inputUID ?? ""
        let outputUID = outputUID ?? ""
        let inputRoute = "\(inputName ?? "") \(inputUID)".lowercased()
        let outputRoute = "\(outputName) \(outputUID)".lowercased()

        if isSimulatedRoute(outputRoute) {
            return LivestreamOutputIsolation(observed: "\(outputName) simulated route", passed: true)
        }

        if inputUID == outputUID && !inputUID.isEmpty {
            if containsStreamOutputKeyword(outputRoute) && !containsConsoleRouteKeyword(outputRoute) {
                return LivestreamOutputIsolation(
                    observed: "\(outputName) is a single aggregate/virtual stream route",
                    passed: true
                )
            }
            return LivestreamOutputIsolation(
                observed: "same Core Audio device as input; route stream mix to a separate encoder/virtual output, not FOH/Dante return",
                passed: false
            )
        }

        if containsConsoleRouteKeyword(outputRoute) {
            return LivestreamOutputIsolation(
                observed: "\(outputName) looks Dante/console-facing; use a stream encoder, BlackHole, Loopback, OBS, or other virtual output",
                passed: false
            )
        }

        if containsStreamOutputKeyword(outputRoute) {
            return LivestreamOutputIsolation(observed: "\(outputName) looks stream/virtual-facing", passed: true)
        }

        if containsConsoleRouteKeyword(inputRoute) {
            return LivestreamOutputIsolation(
                observed: "\(outputName) is separate from Dante input but is not identified as a stream, encoder, virtual, capture, or aggregate output",
                passed: false
            )
        }

        return LivestreamOutputIsolation(
            observed: "\(outputName) selected; output route is not identified as a livestream target",
            passed: false
        )
    }

    private static func isSimulatedRoute(_ text: String) -> Bool {
        text.contains("com.livedaw.automix.simulated-hd96-dante") ||
            text.contains("simulated hd96 dante")
    }

    private static func containsStreamOutputKeyword(_ text: String) -> Bool {
        [
            "stream",
            "encoder",
            "broadcast",
            "blackhole",
            "loopback",
            "obs",
            "virtual",
            "aggregate",
            "restream",
            "audio hijack",
            "capture",
            "cam link",
            "atem",
            "web presenter",
            "decklink",
            "ultrastudio",
            "usb audio codec",
            "zoom",
            "teams",
            "ndi"
        ].contains { text.contains($0) }
    }

    private static func containsConsoleRouteKeyword(_ text: String) -> Bool {
        [
            "dante",
            "hd96",
            "heritage",
            "midas",
            "console",
            "foh"
        ].contains { text.contains($0) }
    }
}

struct WavMetadata: Codable, Equatable, Sendable {
    var formatCode: Int
    var channelCount: Int
    var sampleRate: Int
    var bitsPerSample: Int
    var dataByteCount: Int

    var bytesPerFrame: Int {
        guard channelCount > 0, bitsPerSample > 0 else { return 0 }
        return channelCount * max(1, bitsPerSample / 8)
    }

    var frameCount: Int {
        let frameBytes = bytesPerFrame
        guard frameBytes > 0 else { return 0 }
        return dataByteCount / frameBytes
    }

    var durationSeconds: Double {
        guard sampleRate > 0 else { return 0 }
        return Double(frameCount) / Double(sampleRate)
    }

    static func read(from url: URL) throws -> WavMetadata {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: 44), data.count >= 44 else {
            throw CocoaError(.fileReadCorruptFile)
        }

        return WavMetadata(
            formatCode: Int(uint16LE(data, at: 20)),
            channelCount: Int(uint16LE(data, at: 22)),
            sampleRate: Int(uint32LE(data, at: 24)),
            bitsPerSample: Int(uint16LE(data, at: 34)),
            dataByteCount: Int(uint32LE(data, at: 40))
        )
    }

    private static func uint16LE(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[data.index(data.startIndex, offsetBy: offset)]) |
            (UInt16(data[data.index(data.startIndex, offsetBy: offset + 1)]) << 8)
    }

    private static func uint32LE(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[data.index(data.startIndex, offsetBy: offset)]) |
            (UInt32(data[data.index(data.startIndex, offsetBy: offset + 1)]) << 8) |
            (UInt32(data[data.index(data.startIndex, offsetBy: offset + 2)]) << 16) |
            (UInt32(data[data.index(data.startIndex, offsetBy: offset + 3)]) << 24)
    }
}

struct WavSignalSummary: Codable, Equatable, Sendable {
    var activeInputChannelCount: Int
    var activeInputChannels: [Int]
    var activeStreamOutputChannelCount: Int
    var inputPeakDb: Double
    var inputPeakDbByChannel: [Double]
    var streamOutputPeakDb: [Double]

    static let activeThresholdDb = -90.0

    static func read(from url: URL, inputChannelCount: Int) throws -> WavSignalSummary {
        let metadata = try WavMetadata.read(from: url)
        guard metadata.formatCode == 3,
              metadata.bitsPerSample == 32,
              metadata.channelCount >= 2 else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let channelCount = metadata.channelCount
        let streamStartChannel = channelCount - 2
        let boundedInputChannelCount = min(max(inputChannelCount, 0), streamStartChannel)
        let frameByteCount = channelCount * MemoryLayout<Float>.size
        guard frameByteCount > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: 44)

        var peakLinear = Array(repeating: 0.0, count: channelCount)
        var carry = Data()
        let framesPerRead = max(1, 1_048_576 / frameByteCount)
        let readByteCount = framesPerRead * frameByteCount

        while let chunk = try handle.read(upToCount: readByteCount), !chunk.isEmpty {
            let data: Data
            if carry.isEmpty {
                data = chunk
            } else {
                carry.append(chunk)
                data = carry
            }

            let usableByteCount = data.count - (data.count % frameByteCount)
            if usableByteCount > 0 {
                scanFloat32Payload(data, usableByteCount: usableByteCount, channelCount: channelCount, peakLinear: &peakLinear)
            }

            if usableByteCount < data.count {
                carry = data.subdata(in: usableByteCount..<data.count)
            } else {
                carry.removeAll(keepingCapacity: true)
            }
        }

        let threshold = linearAmplitude(forDb: activeThresholdDb)
        let inputPeaks = Array(peakLinear.prefix(boundedInputChannelCount))
        let streamPeaks = Array(peakLinear[streamStartChannel..<channelCount])
        let inputPeakDbByChannel = inputPeaks.map(peakDb)
        let activeInputChannels = inputPeaks.enumerated().compactMap { index, peak in
            peak > threshold ? index + 1 : nil
        }
        let inputPeakDb = inputPeakDbByChannel.max() ?? -100.0
        let streamPeakDb = streamPeaks.map(peakDb)

        return WavSignalSummary(
            activeInputChannelCount: activeInputChannels.count,
            activeInputChannels: activeInputChannels,
            activeStreamOutputChannelCount: streamPeaks.filter { $0 > threshold }.count,
            inputPeakDb: inputPeakDb,
            inputPeakDbByChannel: inputPeakDbByChannel,
            streamOutputPeakDb: streamPeakDb
        )
    }

    private static func scanFloat32Payload(
        _ data: Data,
        usableByteCount: Int,
        channelCount: Int,
        peakLinear: inout [Double]
    ) {
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            var offset = 0
            var channel = 0
            while offset + 3 < usableByteCount {
                let bits = UInt32(base[offset]) |
                    (UInt32(base[offset + 1]) << 8) |
                    (UInt32(base[offset + 2]) << 16) |
                    (UInt32(base[offset + 3]) << 24)
                let sample = Float(bitPattern: bits)
                let magnitude = Double(abs(sample))
                if magnitude.isFinite && magnitude > peakLinear[channel] {
                    peakLinear[channel] = magnitude
                }
                offset += MemoryLayout<Float>.size
                channel += 1
                if channel == channelCount {
                    channel = 0
                }
            }
        }
    }

    private static func linearAmplitude(forDb db: Double) -> Double {
        pow(10.0, db / 20.0)
    }

    private static func peakDb(_ peak: Double) -> Double {
        peak > 0 ? 20.0 * log10(peak) : -100.0
    }
}

struct SoundcheckReportInput: Sendable {
    var recordingURL: URL
    var expectedRecordingDurationSeconds: Double?
    var inputDevice: SoundcheckDeviceSnapshot
    var outputDevice: SoundcheckDeviceSnapshot
    var scene: MixScene
    var expectedInputChannels: Int
    var detectedInputChannels: Int
    var detectedSampleRate: Double
    var bufferFrameSize: Int
    var lastCallbackFrames: Int
    var maxObservedCallbackFrames: Int
    var dropoutCount: UInt
    var callbackOverrunCount: UInt = 0
    var renderDeadlineMissCount: UInt = 0
    var outputUnderrunCount: UInt
    var outputOverrunCount: UInt = 0
    var watchdogSafeActive: Bool
    var safeBypassEnabled: Bool
    var frozen: Bool
    var channelMappings: [ChannelMapping]
    var latestInputLevelsDb: [Double]
    var latestStreamOutputLevelsDb: [Double]
    var latestMomentaryLufs: Double
    var latestShortTermLufs: Double
    var latestIntegratedLufs: Double
    var latestLimiterGainReductionDb: Double
}

struct SoundcheckReport: Codable, Equatable, Sendable {
    var generatedAt: Date
    var recordingPath: String
    var recordingByteCount: Int
    var recordingChannelCount: Int
    var recordingSampleRate: Int
    var recordingFrameCount: Int
    var recordingDurationSeconds: Double
    var expectedRecordingDurationSeconds: Double?
    var inputDevice: SoundcheckDeviceSnapshot
    var outputDevice: SoundcheckDeviceSnapshot
    var validationSource: AudioValidationSource
    var scene: MixScene
    var expectedInputChannels: Int
    var detectedInputChannels: Int
    var detectedSampleRate: Double
    var bufferFrameSize: Int
    var lastCallbackFrames: Int
    var maxObservedCallbackFrames: Int
    var dropoutCount: UInt
    var callbackOverrunCount: UInt?
    var renderDeadlineMissCount: UInt?
    var outputUnderrunCount: UInt
    var outputOverrunCount: UInt?
    var watchdogSafeActive: Bool
    var safeBypassEnabled: Bool
    var frozen: Bool
    var channelMappings: [ChannelMapping]
    var latestInputLevelsDb: [Double]
    var latestStreamOutputLevelsDb: [Double]
    var latestMomentaryLufs: Double
    var latestShortTermLufs: Double
    var latestIntegratedLufs: Double
    var latestLimiterGainReductionDb: Double
    var recordedActiveInputChannelCount: Int
    var recordedActiveInputChannels: [Int]
    var recordedStreamOutputActiveChannelCount: Int
    var recordedInputPeakDb: Double
    var recordedInputPeakDbByChannel: [Double]
    var recordedStreamOutputPeakDb: [Double]
    var checks: [SoundcheckCheck]
    var passed: Bool

    var summary: String {
        passed ? "Soundcheck passed" : "Soundcheck needs attention"
    }

    static func make(
        generatedAt: Date = Date(),
        recordingPath: String,
        recordingByteCount: Int,
        recordingChannelCount: Int,
        recordingSampleRate: Int,
        recordingFrameCount: Int? = nil,
        recordingDurationSeconds: Double? = nil,
        expectedRecordingDurationSeconds: Double? = nil,
        inputDevice: SoundcheckDeviceSnapshot,
        outputDevice: SoundcheckDeviceSnapshot,
        validationSource: AudioValidationSource? = nil,
        scene: MixScene,
        expectedInputChannels: Int,
        detectedInputChannels: Int,
        detectedSampleRate: Double,
        bufferFrameSize: Int,
        lastCallbackFrames: Int,
        maxObservedCallbackFrames: Int,
        dropoutCount: UInt,
        callbackOverrunCount: UInt = 0,
        renderDeadlineMissCount: UInt = 0,
        outputUnderrunCount: UInt,
        outputOverrunCount: UInt = 0,
        watchdogSafeActive: Bool,
        safeBypassEnabled: Bool,
        frozen: Bool,
        channelMappings: [ChannelMapping],
        latestInputLevelsDb: [Double],
        latestStreamOutputLevelsDb: [Double],
        latestMomentaryLufs: Double,
        latestShortTermLufs: Double,
        latestIntegratedLufs: Double,
        latestLimiterGainReductionDb: Double,
        recordedActiveInputChannelCount: Int = 0,
        recordedActiveInputChannels: [Int] = [],
        recordedStreamOutputActiveChannelCount: Int = 0,
        recordedInputPeakDb: Double = -100.0,
        recordedInputPeakDbByChannel: [Double] = [],
        recordedStreamOutputPeakDb: [Double] = [-100.0, -100.0]
    ) -> SoundcheckReport {
        let boundedDetectedInputChannels = max(0, detectedInputChannels)
        let sameDevice = inputDevice.uid == outputDevice.uid && !inputDevice.uid.isEmpty
        let routeClockObserved = sameDevice
            ? "same Core Audio device · detected \(Int(detectedSampleRate.rounded())) Hz / listed \(Int(inputDevice.sampleRate.rounded())) Hz"
            : "input \(Int(detectedSampleRate.rounded())) Hz / output \(Int(outputDevice.sampleRate.rounded())) Hz"
        let routeClockPassed = sameDevice
            ? detectedSampleRate > 0 && inputDevice.sampleRate > 0 && abs(detectedSampleRate - inputDevice.sampleRate) < 1.0
            : detectedSampleRate > 0 && outputDevice.sampleRate > 0 && abs(detectedSampleRate - outputDevice.sampleRate) < 1.0
        let streamLevels = Array((latestStreamOutputLevelsDb + [-100.0, -100.0]).prefix(2))
        let recordedStreamLevels = Array((recordedStreamOutputPeakDb + [-100.0, -100.0]).prefix(2))
        let normalizedRecordingFrameCount = recordingFrameCount ?? estimatedRecordingFrameCount(
            byteCount: recordingByteCount,
            channelCount: recordingChannelCount
        )
        let normalizedRecordingDurationSeconds = recordingDurationSeconds ??
            recordingDuration(frameCount: normalizedRecordingFrameCount, sampleRate: recordingSampleRate)
        let recordingDurationPassed: Bool
        let recordingDurationExpected: String
        if let expectedRecordingDurationSeconds {
            let toleranceSeconds = max(0.1, expectedRecordingDurationSeconds * 0.05)
            let minimumDuration = max(0.0, expectedRecordingDurationSeconds - toleranceSeconds)
            recordingDurationPassed = normalizedRecordingDurationSeconds >= minimumDuration
            recordingDurationExpected = ">= \(formatSeconds(minimumDuration))"
        } else {
            recordingDurationPassed = normalizedRecordingFrameCount > 0
            recordingDurationExpected = "recorded frames present"
        }
        let normalizedRecordedInputPeakDbByChannel = normalizeRecordedInputPeaks(
            recordedInputPeakDbByChannel,
            detectedInputChannels: boundedDetectedInputChannels,
            recordedActiveInputChannelCount: recordedActiveInputChannelCount,
            recordedInputPeakDb: recordedInputPeakDb
        )
        let normalizedRecordedActiveInputChannels = normalizeActiveInputChannels(
            recordedActiveInputChannels,
            fallbackPeakDbByChannel: normalizedRecordedInputPeakDbByChannel
        )
        let normalizedRecordedActiveInputChannelCount = normalizedRecordedActiveInputChannels.count
        let normalizedRecordedInputPeakDb = normalizedRecordedInputPeakDbByChannel.max() ?? -100.0
        let activeInputCount = latestInputLevelsDb.prefix(max(0, detectedInputChannels)).filter { $0 > -90.0 }.count
        let streamMixPassed = streamLevels.allSatisfy { $0 > -90.0 && $0 < -0.1 }
        let streamMixObserved = "L \(formatDb(streamLevels[0])) / R \(formatDb(streamLevels[1]))"
        let resolvedValidationSource = validationSource ?? AudioValidationSource.infer(
            inputDevice: inputDevice,
            outputDevice: outputDevice
        )
        let coreAudioFormatObserved = "input \(inputDevice.inputFormatSummary) / output \(outputDevice.outputFormatSummary)"
        let coreAudioFormatPassed = inputDevice.inputFormatSupported && outputDevice.outputFormatSupported
        let outputIsolation = LivestreamOutputIsolation.make(
            inputDevice: inputDevice,
            outputDevice: outputDevice
        )
        let channelMapCoverage = ChannelMapCoverage.make(
            channelMappings: channelMappings,
            inputChannelCount: detectedInputChannels
        )
        let sourceRoleCoverage = SourceRoleCoverage.make(channelMappings: channelMappings)
        let manualOverrideCoverage = ManualOverrideCoverage.make(channelMappings: channelMappings)
        let loudnessTelemetryPassed = latestMomentaryLufs.isFinite &&
            latestShortTermLufs.isFinite &&
            latestIntegratedLufs.isFinite &&
            latestMomentaryLufs > -99.0
        let limiterPassed = latestLimiterGainReductionDb.isFinite &&
            latestLimiterGainReductionDb <= 0.5 &&
            latestLimiterGainReductionDb > -12.0
        let checks = [
            SoundcheckCheck(
                name: "Sample Rate",
                expected: "broadcast rate (48/96 kHz)",
                observed: detectedSampleRate > 0 ? "\(Int(detectedSampleRate.rounded())) Hz" : "unknown",
                passed: BroadcastSampleRate.isSupported(detectedSampleRate)
            ),
            SoundcheckCheck(
                name: "Input Channels",
                expected: "\(expectedInputChannels)",
                observed: "\(detectedInputChannels)",
                passed: detectedInputChannels == expectedInputChannels
            ),
            SoundcheckCheck(
                name: "Mapped Channels",
                expected: "\(detectedInputChannels)",
                observed: "\(channelMappings.count)",
                passed: detectedInputChannels > 0 && channelMappings.count == detectedInputChannels
            ),
            SoundcheckCheck(
                name: "Input Map Coverage",
                expected: "each Dante input mapped once",
                observed: channelMapCoverage.summary,
                passed: channelMapCoverage.isReady
            ),
            SoundcheckCheck(
                name: "Source Roles",
                expected: "1+ non-unknown source role",
                observed: sourceRoleCoverage.summary,
                passed: sourceRoleCoverage.isReady
            ),
            SoundcheckCheck(
                name: "Manual Overrides",
                expected: "disabled or within fader/pan range",
                observed: manualOverrideCoverage.summary,
                passed: manualOverrideCoverage.isReady
            ),
            SoundcheckCheck(
                name: "Input Activity",
                expected: "1+ active input",
                observed: "\(activeInputCount) active above -90 dBFS",
                passed: activeInputCount > 0
            ),
            SoundcheckCheck(
                name: "Stream Output",
                expected: "2+ output channels",
                observed: "\(outputDevice.outputChannels)",
                passed: outputDevice.outputChannels >= 2
            ),
            SoundcheckCheck(
                name: "Output Isolation",
                expected: "stream encoder or virtual output, not HD96/FOH return",
                observed: outputIsolation.observed,
                passed: outputIsolation.passed
            ),
            SoundcheckCheck(
                name: "Core Audio Format",
                expected: "32-bit little-endian float PCM input/output",
                observed: coreAudioFormatObserved,
                passed: coreAudioFormatPassed
            ),
            SoundcheckCheck(
                name: "Route Clock",
                expected: "input/output sample rates match",
                observed: routeClockObserved,
                passed: routeClockPassed
            ),
            SoundcheckCheck(
                name: "Stream Mix Level",
                expected: "L/R active below clip",
                observed: streamMixObserved,
                passed: streamMixPassed
            ),
            SoundcheckCheck(
                name: "Master Loudness",
                expected: "LUFS telemetry active",
                observed: "M \(formatLufs(latestMomentaryLufs)) / S \(formatLufs(latestShortTermLufs)) / I \(formatLufs(latestIntegratedLufs))",
                passed: loudnessTelemetryPassed
            ),
            SoundcheckCheck(
                name: "Limiter Gain Reduction",
                expected: "> -12 dB",
                observed: formatDb(latestLimiterGainReductionDb),
                passed: limiterPassed
            ),
            SoundcheckCheck(
                name: "Callbacks",
                expected: "active",
                observed: lastCallbackFrames > 0 ? "\(lastCallbackFrames) last / \(maxObservedCallbackFrames) max" : "none",
                passed: lastCallbackFrames > 0 && maxObservedCallbackFrames >= lastCallbackFrames
            ),
            SoundcheckCheck(
                name: "Callback Frame Size",
                expected: "<= prepared \(bufferFrameSize) frames",
                observed: maxObservedCallbackFrames > 0 ? "\(maxObservedCallbackFrames) max" : "none",
                passed: maxObservedCallbackFrames == 0 ||
                    (bufferFrameSize > 0 && maxObservedCallbackFrames <= bufferFrameSize)
            ),
            SoundcheckCheck(
                name: "Dropouts",
                expected: "0",
                observed: "\(dropoutCount)",
                passed: dropoutCount == 0
            ),
            SoundcheckCheck(
                name: "Callback Overruns",
                expected: "0",
                observed: "\(callbackOverrunCount)",
                passed: callbackOverrunCount == 0
            ),
            SoundcheckCheck(
                name: "Render Deadline Misses",
                expected: "0",
                observed: "\(renderDeadlineMissCount)",
                passed: renderDeadlineMissCount == 0
            ),
            SoundcheckCheck(
                name: "Output Underruns",
                expected: "0",
                observed: "\(outputUnderrunCount)",
                passed: outputUnderrunCount == 0
            ),
            SoundcheckCheck(
                name: "Output Overruns",
                expected: "0",
                observed: "\(outputOverrunCount)",
                passed: outputOverrunCount == 0
            ),
            SoundcheckCheck(
                name: "Watchdog SAFE",
                expected: "inactive",
                observed: watchdogSafeActive ? "active" : "inactive",
                passed: !watchdogSafeActive
            ),
            SoundcheckCheck(
                name: "SAFE Bypass",
                expected: "enabled for proof recording",
                observed: safeBypassEnabled ? "enabled" : "disabled",
                passed: safeBypassEnabled
            ),
            SoundcheckCheck(
                name: "Recording",
                expected: "WAV payload",
                observed: "\(recordingByteCount) bytes",
                passed: recordingByteCount > 44
            ),
            SoundcheckCheck(
                name: "Recording Duration",
                expected: recordingDurationExpected,
                observed: "\(normalizedRecordingFrameCount) frames / \(formatSeconds(normalizedRecordingDurationSeconds))",
                passed: recordingDurationPassed
            ),
            SoundcheckCheck(
                name: "Recorded Input Activity",
                expected: "1+ active recorded input",
                observed: "\(normalizedRecordedActiveInputChannelCount) active, peak \(formatDb(normalizedRecordedInputPeakDb))",
                passed: normalizedRecordedActiveInputChannelCount > 0
            ),
            SoundcheckCheck(
                name: "Recorded Stream Activity",
                expected: "2 active recorded stream channels",
                observed: "L \(formatDb(recordedStreamLevels[0])) / R \(formatDb(recordedStreamLevels[1]))",
                passed: recordedStreamOutputActiveChannelCount == 2
            ),
            SoundcheckCheck(
                name: "Recording Channels",
                expected: "\(detectedInputChannels + 2) (inputs + stream L/R)",
                observed: "\(recordingChannelCount)",
                passed: detectedInputChannels > 0 && recordingChannelCount == detectedInputChannels + 2
            ),
            SoundcheckCheck(
                name: "Recording Sample Rate",
                expected: "broadcast rate (48/96 kHz)",
                observed: recordingSampleRate > 0 ? "\(recordingSampleRate) Hz" : "unknown",
                passed: BroadcastSampleRate.isSupported(Double(recordingSampleRate)) && recordingSampleRate == Int(detectedSampleRate.rounded())
            )
        ]

        return SoundcheckReport(
            generatedAt: generatedAt,
            recordingPath: recordingPath,
            recordingByteCount: recordingByteCount,
            recordingChannelCount: recordingChannelCount,
            recordingSampleRate: recordingSampleRate,
            recordingFrameCount: normalizedRecordingFrameCount,
            recordingDurationSeconds: normalizedRecordingDurationSeconds,
            expectedRecordingDurationSeconds: expectedRecordingDurationSeconds,
            inputDevice: inputDevice,
            outputDevice: outputDevice,
            validationSource: resolvedValidationSource,
            scene: scene,
            expectedInputChannels: min(max(expectedInputChannels, 1), 64),
            detectedInputChannels: detectedInputChannels,
            detectedSampleRate: detectedSampleRate,
            bufferFrameSize: bufferFrameSize,
            lastCallbackFrames: lastCallbackFrames,
            maxObservedCallbackFrames: maxObservedCallbackFrames,
            dropoutCount: dropoutCount,
            callbackOverrunCount: callbackOverrunCount,
            renderDeadlineMissCount: renderDeadlineMissCount,
            outputUnderrunCount: outputUnderrunCount,
            outputOverrunCount: outputOverrunCount,
            watchdogSafeActive: watchdogSafeActive,
            safeBypassEnabled: safeBypassEnabled,
            frozen: frozen,
            channelMappings: channelMappings,
            latestInputLevelsDb: latestInputLevelsDb,
            latestStreamOutputLevelsDb: streamLevels,
            latestMomentaryLufs: latestMomentaryLufs,
            latestShortTermLufs: latestShortTermLufs,
            latestIntegratedLufs: latestIntegratedLufs,
            latestLimiterGainReductionDb: latestLimiterGainReductionDb,
            recordedActiveInputChannelCount: normalizedRecordedActiveInputChannelCount,
            recordedActiveInputChannels: normalizedRecordedActiveInputChannels,
            recordedStreamOutputActiveChannelCount: recordedStreamOutputActiveChannelCount,
            recordedInputPeakDb: normalizedRecordedInputPeakDb,
            recordedInputPeakDbByChannel: normalizedRecordedInputPeakDbByChannel,
            recordedStreamOutputPeakDb: recordedStreamLevels,
            checks: checks,
            passed: checks.allSatisfy(\.passed)
        )
    }

    static func make(from input: SoundcheckReportInput) throws -> SoundcheckReport {
        let attributes = try FileManager.default.attributesOfItem(atPath: input.recordingURL.path)
        let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let wavMetadata = try WavMetadata.read(from: input.recordingURL)
        let signalSummary = try WavSignalSummary.read(
            from: input.recordingURL,
            inputChannelCount: input.detectedInputChannels
        )

        return SoundcheckReport.make(
            recordingPath: input.recordingURL.path,
            recordingByteCount: byteCount,
            recordingChannelCount: wavMetadata.channelCount,
            recordingSampleRate: wavMetadata.sampleRate,
            recordingFrameCount: wavMetadata.frameCount,
            recordingDurationSeconds: wavMetadata.durationSeconds,
            expectedRecordingDurationSeconds: input.expectedRecordingDurationSeconds,
            inputDevice: input.inputDevice,
            outputDevice: input.outputDevice,
            scene: input.scene,
            expectedInputChannels: input.expectedInputChannels,
            detectedInputChannels: input.detectedInputChannels,
            detectedSampleRate: input.detectedSampleRate,
            bufferFrameSize: input.bufferFrameSize,
            lastCallbackFrames: input.lastCallbackFrames,
            maxObservedCallbackFrames: input.maxObservedCallbackFrames,
            dropoutCount: input.dropoutCount,
            callbackOverrunCount: input.callbackOverrunCount,
            renderDeadlineMissCount: input.renderDeadlineMissCount,
            outputUnderrunCount: input.outputUnderrunCount,
            outputOverrunCount: input.outputOverrunCount,
            watchdogSafeActive: input.watchdogSafeActive,
            safeBypassEnabled: input.safeBypassEnabled,
            frozen: input.frozen,
            channelMappings: input.channelMappings,
            latestInputLevelsDb: input.latestInputLevelsDb,
            latestStreamOutputLevelsDb: input.latestStreamOutputLevelsDb,
            latestMomentaryLufs: input.latestMomentaryLufs,
            latestShortTermLufs: input.latestShortTermLufs,
            latestIntegratedLufs: input.latestIntegratedLufs,
            latestLimiterGainReductionDb: input.latestLimiterGainReductionDb,
            recordedActiveInputChannelCount: signalSummary.activeInputChannelCount,
            recordedActiveInputChannels: signalSummary.activeInputChannels,
            recordedStreamOutputActiveChannelCount: signalSummary.activeStreamOutputChannelCount,
            recordedInputPeakDb: signalSummary.inputPeakDb,
            recordedInputPeakDbByChannel: signalSummary.inputPeakDbByChannel,
            recordedStreamOutputPeakDb: signalSummary.streamOutputPeakDb
        )
    }

    func writeJSON(beside recordingURL: URL) throws -> URL {
        let name = recordingURL.deletingPathExtension().lastPathComponent + "-soundcheck.json"
        let url = recordingURL.deletingLastPathComponent().appendingPathComponent(name)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func formatDb(_ value: Double) -> String {
        value <= -99 ? "-inf dB" : String(format: "%.1f dB", value)
    }

    private static func formatLufs(_ value: Double) -> String {
        value <= -99 ? "-inf LUFS" : String(format: "%.1f LUFS", value)
    }

    private static func formatSeconds(_ value: Double) -> String {
        String(format: "%.2fs", value)
    }

    private static func estimatedRecordingFrameCount(byteCount: Int, channelCount: Int) -> Int {
        let frameBytes = channelCount * MemoryLayout<Float>.size
        guard byteCount > 44, frameBytes > 0 else { return 0 }
        return (byteCount - 44) / frameBytes
    }

    private static func recordingDuration(frameCount: Int, sampleRate: Int) -> Double {
        guard frameCount > 0, sampleRate > 0 else { return 0 }
        return Double(frameCount) / Double(sampleRate)
    }

    private static func normalizeRecordedInputPeaks(
        _ inputPeaks: [Double],
        detectedInputChannels: Int,
        recordedActiveInputChannelCount: Int,
        recordedInputPeakDb: Double
    ) -> [Double] {
        guard detectedInputChannels > 0 else { return [] }
        if !inputPeaks.isEmpty {
            return Array((inputPeaks + Array(repeating: -100.0, count: max(0, detectedInputChannels - inputPeaks.count))).prefix(detectedInputChannels))
        }

        let activeCount = min(max(0, recordedActiveInputChannelCount), detectedInputChannels)
        return (0..<detectedInputChannels).map { index in
            index < activeCount ? recordedInputPeakDb : -100.0
        }
    }

    private static func normalizeActiveInputChannels(
        _ channels: [Int],
        fallbackPeakDbByChannel: [Double]
    ) -> [Int] {
        guard !fallbackPeakDbByChannel.isEmpty else { return [] }
        if channels.isEmpty {
            return fallbackPeakDbByChannel.enumerated().compactMap { index, peakDb in
                peakDb > WavSignalSummary.activeThresholdDb ? index + 1 : nil
            }
        }

        let channelLimit = fallbackPeakDbByChannel.count
        var seen = Set<Int>()
        return channels.filter { channel in
            channel >= 1 && channel <= channelLimit && seen.insert(channel).inserted
        }
    }
}

struct StabilityMonitorReport: Codable, Equatable, Sendable {
    var generatedAt: Date
    var durationSeconds: Double
    var inputDevice: SoundcheckDeviceSnapshot
    var outputDevice: SoundcheckDeviceSnapshot
    var validationSource: AudioValidationSource
    var scene: MixScene
    var expectedInputChannels: Int
    var detectedInputChannels: Int
    var detectedSampleRate: Double
    var bufferFrameSize: Int
    var lastCallbackFrames: Int
    var maxObservedCallbackFrames: Int
    var dropoutDelta: UInt
    var callbackOverrunDelta: UInt?
    var renderDeadlineMissDelta: UInt?
    var outputUnderrunDelta: UInt
    var outputOverrunDelta: UInt?
    var outputRingTargetFrames: Int?
    var minOutputRingFillFrames: Int?
    var maxOutputRingFillFrames: Int?
    var maxAbsOutputClockCorrectionPpm: Double?
    var watchdogSafeActive: Bool
    var safeBypassEnabled: Bool?
    var frozen: Bool?
    var channelMappings: [ChannelMapping]
    var minStreamOutputLevelsDb: [Double]
    var maxStreamOutputLevelsDb: [Double]
    var maxActiveInputChannelCount: Int
    var minMomentaryLufs: Double
    var maxMomentaryLufs: Double
    var minLimiterGainReductionDb: Double
    var checks: [SoundcheckCheck]
    var passed: Bool

    var summary: String {
        passed ? "Stability monitor passed" : "Stability monitor needs attention"
    }

    static func make(
        generatedAt: Date = Date(),
        durationSeconds: Double,
        inputDevice: SoundcheckDeviceSnapshot,
        outputDevice: SoundcheckDeviceSnapshot,
        validationSource: AudioValidationSource? = nil,
        scene: MixScene,
        expectedInputChannels: Int,
        detectedInputChannels: Int,
        detectedSampleRate: Double,
        bufferFrameSize: Int,
        lastCallbackFrames: Int,
        maxObservedCallbackFrames: Int,
        dropoutDelta: UInt,
        callbackOverrunDelta: UInt = 0,
        renderDeadlineMissDelta: UInt = 0,
        outputUnderrunDelta: UInt,
        outputOverrunDelta: UInt = 0,
        outputRingTargetFrames: Int = 0,
        minOutputRingFillFrames: Int = 0,
        maxOutputRingFillFrames: Int = 0,
        maxAbsOutputClockCorrectionPpm: Double = 0,
        watchdogSafeActive: Bool,
        safeBypassEnabled: Bool = false,
        frozen: Bool = false,
        channelMappings: [ChannelMapping],
        minStreamOutputLevelsDb: [Double],
        maxStreamOutputLevelsDb: [Double],
        maxActiveInputChannelCount: Int,
        minMomentaryLufs: Double,
        maxMomentaryLufs: Double,
        minLimiterGainReductionDb: Double
    ) -> StabilityMonitorReport {
        let minLevels = Array((minStreamOutputLevelsDb + [-100.0, -100.0]).prefix(2))
        let maxLevels = Array((maxStreamOutputLevelsDb + [-100.0, -100.0]).prefix(2))
        let streamActive = minLevels.allSatisfy { $0 > -90.0 }
        let streamNotClipping = maxLevels.allSatisfy { $0 < -0.1 }
        let loudnessPassed = minMomentaryLufs.isFinite && maxMomentaryLufs.isFinite && maxMomentaryLufs > -99.0
        let limiterPassed = minLimiterGainReductionDb.isFinite && minLimiterGainReductionDb > -12.0
        let resolvedValidationSource = validationSource ?? AudioValidationSource.infer(
            inputDevice: inputDevice,
            outputDevice: outputDevice
        )
        let coreAudioFormatObserved = "input \(inputDevice.inputFormatSummary) / output \(outputDevice.outputFormatSummary)"
        let coreAudioFormatPassed = inputDevice.inputFormatSupported && outputDevice.outputFormatSupported
        let sameDevice = inputDevice.uid == outputDevice.uid && !inputDevice.uid.isEmpty
        let routeClockObserved = sameDevice
            ? "same Core Audio device · detected \(Int(detectedSampleRate.rounded())) Hz / listed \(Int(inputDevice.sampleRate.rounded())) Hz"
            : "input \(Int(detectedSampleRate.rounded())) Hz / output \(Int(outputDevice.sampleRate.rounded())) Hz"
        let routeClockPassed = sameDevice
            ? detectedSampleRate > 0 && inputDevice.sampleRate > 0 && abs(detectedSampleRate - inputDevice.sampleRate) < 1.0
            : detectedSampleRate > 0 && outputDevice.sampleRate > 0 && abs(detectedSampleRate - outputDevice.sampleRate) < 1.0
        let outputIsolation = LivestreamOutputIsolation.make(
            inputDevice: inputDevice,
            outputDevice: outputDevice
        )
        let channelMapCoverage = ChannelMapCoverage.make(
            channelMappings: channelMappings,
            inputChannelCount: detectedInputChannels
        )
        let sourceRoleCoverage = SourceRoleCoverage.make(channelMappings: channelMappings)
        let manualOverrideCoverage = ManualOverrideCoverage.make(channelMappings: channelMappings)
        let separateClockPath = inputDevice.uid != outputDevice.uid &&
            !inputDevice.uid.isEmpty &&
            !outputDevice.uid.isEmpty
        let clockFollowerPassed = !separateClockPath ||
            (outputRingTargetFrames > 0 &&
             minOutputRingFillFrames >= max(1, outputRingTargetFrames / 4) &&
             maxOutputRingFillFrames <= outputRingTargetFrames * 3 &&
             maxAbsOutputClockCorrectionPpm < 900)
        let clockFollowerObserved = separateClockPath
            ? String(
                format: "max |%.0f| ppm · ring %d...%d / %d target frames",
                maxAbsOutputClockCorrectionPpm,
                minOutputRingFillFrames,
                maxOutputRingFillFrames,
                outputRingTargetFrames
            )
            : "shared Core Audio callback"
        let checks = [
            SoundcheckCheck(
                name: "Duration",
                expected: "30s+",
                observed: "\(Int(durationSeconds.rounded()))s",
                passed: durationSeconds >= 30.0
            ),
            SoundcheckCheck(
                name: "Sample Rate",
                expected: "broadcast rate (48/96 kHz)",
                observed: detectedSampleRate > 0 ? "\(Int(detectedSampleRate.rounded())) Hz" : "unknown",
                passed: BroadcastSampleRate.isSupported(detectedSampleRate)
            ),
            SoundcheckCheck(
                name: "Input Channels",
                expected: "\(expectedInputChannels)",
                observed: "\(detectedInputChannels)",
                passed: detectedInputChannels == expectedInputChannels
            ),
            SoundcheckCheck(
                name: "Core Audio Format",
                expected: "32-bit little-endian float PCM input/output",
                observed: coreAudioFormatObserved,
                passed: coreAudioFormatPassed
            ),
            SoundcheckCheck(
                name: "Route Clock",
                expected: "input/output sample rates match",
                observed: routeClockObserved,
                passed: routeClockPassed
            ),
            SoundcheckCheck(
                name: "Output Isolation",
                expected: "stream encoder or virtual output, not HD96/FOH return",
                observed: outputIsolation.observed,
                passed: outputIsolation.passed
            ),
            SoundcheckCheck(
                name: "Input Map Coverage",
                expected: "each Dante input mapped once",
                observed: channelMapCoverage.summary,
                passed: channelMapCoverage.isReady
            ),
            SoundcheckCheck(
                name: "Source Roles",
                expected: "1+ non-unknown source role",
                observed: sourceRoleCoverage.summary,
                passed: sourceRoleCoverage.isReady
            ),
            SoundcheckCheck(
                name: "Manual Overrides",
                expected: "disabled or within fader/pan range",
                observed: manualOverrideCoverage.summary,
                passed: manualOverrideCoverage.isReady
            ),
            SoundcheckCheck(
                name: "Input Activity",
                expected: "1+ active input",
                observed: "\(maxActiveInputChannelCount) max active above -90 dBFS",
                passed: maxActiveInputChannelCount > 0
            ),
            SoundcheckCheck(
                name: "Callbacks",
                expected: "active",
                observed: lastCallbackFrames > 0 ? "\(lastCallbackFrames) last / \(maxObservedCallbackFrames) max" : "none",
                passed: lastCallbackFrames > 0 && maxObservedCallbackFrames >= lastCallbackFrames
            ),
            SoundcheckCheck(
                name: "Callback Frame Size",
                expected: "<= prepared \(bufferFrameSize) frames",
                observed: maxObservedCallbackFrames > 0 ? "\(maxObservedCallbackFrames) max" : "none",
                passed: maxObservedCallbackFrames == 0 ||
                    (bufferFrameSize > 0 && maxObservedCallbackFrames <= bufferFrameSize)
            ),
            SoundcheckCheck(
                name: "Dropouts",
                expected: "0",
                observed: "\(dropoutDelta)",
                passed: dropoutDelta == 0
            ),
            SoundcheckCheck(
                name: "Callback Overruns",
                expected: "0",
                observed: "\(callbackOverrunDelta)",
                passed: callbackOverrunDelta == 0
            ),
            SoundcheckCheck(
                name: "Render Deadline Misses",
                expected: "0",
                observed: "\(renderDeadlineMissDelta)",
                passed: renderDeadlineMissDelta == 0
            ),
            SoundcheckCheck(
                name: "Output Underruns",
                expected: "0",
                observed: "\(outputUnderrunDelta)",
                passed: outputUnderrunDelta == 0
            ),
            SoundcheckCheck(
                name: "Output Overruns",
                expected: "0",
                observed: "\(outputOverrunDelta)",
                passed: outputOverrunDelta == 0
            ),
            SoundcheckCheck(
                name: "Output Clock Drift",
                expected: "shared callback or bounded follower below 900 ppm with ring in range",
                observed: clockFollowerObserved,
                passed: clockFollowerPassed
            ),
            SoundcheckCheck(
                name: "Watchdog SAFE",
                expected: "inactive",
                observed: watchdogSafeActive ? "active" : "inactive",
                passed: !watchdogSafeActive
            ),
            SoundcheckCheck(
                name: "SAFE Bypass",
                expected: "disabled for autonomous proof",
                observed: safeBypassEnabled ? "enabled" : "disabled",
                passed: !safeBypassEnabled
            ),
            SoundcheckCheck(
                name: "FREEZE",
                expected: "disabled for autonomous proof",
                observed: frozen ? "enabled" : "disabled",
                passed: !frozen
            ),
            SoundcheckCheck(
                name: "Stream Mix Level",
                expected: "L/R active below clip",
                observed: "min L \(formatDb(minLevels[0])) / R \(formatDb(minLevels[1])), max L \(formatDb(maxLevels[0])) / R \(formatDb(maxLevels[1]))",
                passed: streamActive && streamNotClipping
            ),
            SoundcheckCheck(
                name: "Master Loudness",
                expected: "momentary LUFS telemetry active",
                observed: "min \(formatLufs(minMomentaryLufs)) / max \(formatLufs(maxMomentaryLufs))",
                passed: loudnessPassed
            ),
            SoundcheckCheck(
                name: "Limiter Gain Reduction",
                expected: "> -12 dB",
                observed: formatDb(minLimiterGainReductionDb),
                passed: limiterPassed
            )
        ]

        return StabilityMonitorReport(
            generatedAt: generatedAt,
            durationSeconds: durationSeconds,
            inputDevice: inputDevice,
            outputDevice: outputDevice,
            validationSource: resolvedValidationSource,
            scene: scene,
            expectedInputChannels: min(max(expectedInputChannels, 1), 64),
            detectedInputChannels: detectedInputChannels,
            detectedSampleRate: detectedSampleRate,
            bufferFrameSize: bufferFrameSize,
            lastCallbackFrames: lastCallbackFrames,
            maxObservedCallbackFrames: maxObservedCallbackFrames,
            dropoutDelta: dropoutDelta,
            callbackOverrunDelta: callbackOverrunDelta,
            renderDeadlineMissDelta: renderDeadlineMissDelta,
            outputUnderrunDelta: outputUnderrunDelta,
            outputOverrunDelta: outputOverrunDelta,
            outputRingTargetFrames: outputRingTargetFrames,
            minOutputRingFillFrames: minOutputRingFillFrames,
            maxOutputRingFillFrames: maxOutputRingFillFrames,
            maxAbsOutputClockCorrectionPpm: maxAbsOutputClockCorrectionPpm,
            watchdogSafeActive: watchdogSafeActive,
            safeBypassEnabled: safeBypassEnabled,
            frozen: frozen,
            channelMappings: channelMappings,
            minStreamOutputLevelsDb: minLevels,
            maxStreamOutputLevelsDb: maxLevels,
            maxActiveInputChannelCount: maxActiveInputChannelCount,
            minMomentaryLufs: minMomentaryLufs,
            maxMomentaryLufs: maxMomentaryLufs,
            minLimiterGainReductionDb: minLimiterGainReductionDb,
            checks: checks,
            passed: checks.allSatisfy(\.passed)
        )
    }

    private static func formatDb(_ value: Double) -> String {
        value <= -99 ? "-inf dB" : String(format: "%.1f dB", value)
    }

    private static func formatLufs(_ value: Double) -> String {
        value <= -99 ? "-inf LUFS" : String(format: "%.1f LUFS", value)
    }
}
