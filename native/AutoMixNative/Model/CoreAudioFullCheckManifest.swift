import Foundation

struct CoreAudioFullCheckManifest: Codable, Equatable, Sendable {
    var generatedAt: Date
    var validationSource: AudioValidationSource
    var inputDevice: SoundcheckDeviceSnapshot
    var outputDevice: SoundcheckDeviceSnapshot
    var expectedInputChannels: Int
    var scene: MixScene
    var soundcheckSeconds: Double
    var stabilitySeconds: Double
    var deviceInventoryPath: String?
    var preflightReportPath: String
    var soundcheckRecordingPath: String?
    var soundcheckReportPath: String?
    var stabilityReportPath: String?
    var preflightReady: Bool
    var soundcheckPassed: Bool?
    var stabilityPassed: Bool?
    var failureReason: String?
    var hardwareProofPassed: Bool
    var hardwareProofSummary: String
    var passed: Bool

    init(
        generatedAt: Date = Date(),
        validationSource: AudioValidationSource,
        inputDevice: SoundcheckDeviceSnapshot,
        outputDevice: SoundcheckDeviceSnapshot,
        expectedInputChannels: Int,
        scene: MixScene,
        soundcheckSeconds: Double,
        stabilitySeconds: Double,
        deviceInventoryPath: String? = nil,
        preflightReportPath: String,
        soundcheckRecordingPath: String? = nil,
        soundcheckReportPath: String? = nil,
        stabilityReportPath: String? = nil,
        preflightReady: Bool,
        soundcheckPassed: Bool? = nil,
        stabilityPassed: Bool? = nil,
        failureReason: String? = nil
    ) {
        self.generatedAt = generatedAt
        self.validationSource = validationSource
        self.inputDevice = inputDevice
        self.outputDevice = outputDevice
        self.expectedInputChannels = expectedInputChannels
        self.scene = scene
        self.soundcheckSeconds = soundcheckSeconds
        self.stabilitySeconds = stabilitySeconds
        self.deviceInventoryPath = deviceInventoryPath
        self.preflightReportPath = preflightReportPath
        self.soundcheckRecordingPath = soundcheckRecordingPath
        self.soundcheckReportPath = soundcheckReportPath
        self.stabilityReportPath = stabilityReportPath
        self.preflightReady = preflightReady
        self.soundcheckPassed = soundcheckPassed
        self.stabilityPassed = stabilityPassed
        self.failureReason = failureReason
        self.hardwareProofPassed = false
        self.hardwareProofSummary = "Full check has not passed."
        self.passed = false
        recomputePassed()
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        validationSource = try container.decode(AudioValidationSource.self, forKey: .validationSource)
        inputDevice = try container.decode(SoundcheckDeviceSnapshot.self, forKey: .inputDevice)
        outputDevice = try container.decode(SoundcheckDeviceSnapshot.self, forKey: .outputDevice)
        expectedInputChannels = try container.decode(Int.self, forKey: .expectedInputChannels)
        scene = try container.decode(MixScene.self, forKey: .scene)
        soundcheckSeconds = try container.decode(Double.self, forKey: .soundcheckSeconds)
        stabilitySeconds = try container.decode(Double.self, forKey: .stabilitySeconds)
        deviceInventoryPath = try container.decodeIfPresent(String.self, forKey: .deviceInventoryPath)
        preflightReportPath = try container.decode(String.self, forKey: .preflightReportPath)
        soundcheckRecordingPath = try container.decodeIfPresent(String.self, forKey: .soundcheckRecordingPath)
        soundcheckReportPath = try container.decodeIfPresent(String.self, forKey: .soundcheckReportPath)
        stabilityReportPath = try container.decodeIfPresent(String.self, forKey: .stabilityReportPath)
        preflightReady = try container.decode(Bool.self, forKey: .preflightReady)
        soundcheckPassed = try container.decodeIfPresent(Bool.self, forKey: .soundcheckPassed)
        stabilityPassed = try container.decodeIfPresent(Bool.self, forKey: .stabilityPassed)
        failureReason = try container.decodeIfPresent(String.self, forKey: .failureReason)
        hardwareProofPassed = try container.decodeIfPresent(Bool.self, forKey: .hardwareProofPassed) ?? false
        hardwareProofSummary = try container.decodeIfPresent(String.self, forKey: .hardwareProofSummary) ?? ""
        passed = try container.decodeIfPresent(Bool.self, forKey: .passed) ?? false
        recomputePassed()
    }

    mutating func recordDeviceInventory(path: String) {
        deviceInventoryPath = path
    }

    mutating func recordSoundcheck(recordingPath: String, reportPath: String, passed: Bool) {
        soundcheckRecordingPath = recordingPath
        soundcheckReportPath = reportPath
        soundcheckPassed = passed
        recomputePassed()
    }

    mutating func recordStability(reportPath: String, passed: Bool) {
        stabilityReportPath = reportPath
        stabilityPassed = passed
        recomputePassed()
    }

    mutating func markFailure(_ reason: String) {
        failureReason = reason
        recomputePassed()
    }

    mutating func recomputePassed() {
        let hasArtifactPaths = deviceInventoryPath?.isEmpty == false &&
            !preflightReportPath.isEmpty &&
            soundcheckRecordingPath?.isEmpty == false &&
            soundcheckReportPath?.isEmpty == false &&
            stabilityReportPath?.isEmpty == false
        passed = hasArtifactPaths &&
            preflightReady &&
            soundcheckPassed == true &&
            stabilityPassed == true &&
            failureReason == nil
        hardwareProofPassed = passed && validationSource == .coreAudioDevice
        if hardwareProofPassed {
            hardwareProofSummary = "HD96/Dante hardware proof passed."
        } else if passed {
            hardwareProofSummary = "Simulated validation passed; run the same full check on the HD96/Dante Core Audio route."
        } else if !hasArtifactPaths {
            hardwareProofSummary = "Full check is missing one or more proof artifact paths."
        } else if let failureReason {
            hardwareProofSummary = failureReason
        } else {
            hardwareProofSummary = "Full check has not passed."
        }
    }
}

struct CoreAudioDeviceInventory: Codable, Equatable, Sendable {
    var generatedAt: Date
    var expectedInputChannels: Int
    var selectedInputUID: String?
    var selectedOutputUID: String?
    var deviceCount: Int
    var readyInputUIDs: [String]
    var readyOutputUIDs: [String]
    var summary: String
    var devices: [CoreAudioDeviceInventoryDevice]

    static func make(
        generatedAt: Date = Date(),
        devices: [AMDeviceInfo],
        expectedInputChannels: Int,
        selectedInputUID: String? = nil,
        selectedOutputUID: String? = nil
    ) -> CoreAudioDeviceInventory {
        let expectedInputs = min(max(expectedInputChannels, 1), 64)
        let selectedInput = selectedInputUID.flatMap { uid in
            devices.first { $0.uid == uid }
        }
        let entries = devices.map { device in
            CoreAudioDeviceInventoryDevice.make(
                device: device,
                expectedInputChannels: expectedInputs,
                selectedInputDevice: selectedInput
            )
        }
        let readyInputUIDs = entries.filter(\.inputReady).map(\.uid)
        let readyOutputUIDs = entries.filter(\.outputReady).map(\.uid)
        let summary = "\(readyInputUIDs.count) HD96 input candidate(s), \(readyOutputUIDs.count) stream output candidate(s), \(entries.count) Core Audio device(s)"
        return CoreAudioDeviceInventory(
            generatedAt: generatedAt,
            expectedInputChannels: expectedInputs,
            selectedInputUID: selectedInputUID?.nilIfEmpty,
            selectedOutputUID: selectedOutputUID?.nilIfEmpty,
            deviceCount: entries.count,
            readyInputUIDs: readyInputUIDs,
            readyOutputUIDs: readyOutputUIDs,
            summary: summary,
            devices: entries
        )
    }
}

struct CoreAudioFullCheckArtifactCheck: Codable, Equatable, Identifiable, Sendable {
    var id: String { name }
    var name: String
    var path: String
    var exists: Bool
    var byteCount: Int

    var passed: Bool {
        exists && byteCount > 0
    }

    var summary: String {
        if passed { return "\(byteCount) bytes" }
        if exists { return "empty file" }
        return "missing"
    }
}

struct CoreAudioFullCheckProofCheck: Codable, Equatable, Identifiable, Sendable {
    var id: String { name }
    var name: String
    var passed: Bool
    var summary: String
}

struct CoreAudioFullCheckVerificationResult: Codable, Equatable, Sendable {
    var manifestPath: String
    var manifest: CoreAudioFullCheckManifest
    var artifactChecks: [CoreAudioFullCheckArtifactCheck]
    var proofChecks: [CoreAudioFullCheckProofCheck]
    var passed: Bool
    var hardwareProofPassed: Bool
    var summary: String
}

struct CoreAudioPreflightProofArtifact: Codable, Equatable, Sendable {
    var generatedAt: Date
    var inputDevice: SoundcheckDeviceSnapshot
    var outputDevice: SoundcheckDeviceSnapshot
    var expectedInputChannels: Int
    var detectedInputChannels: Int
    var detectedSampleRate: Double
    var channelMappings: [ChannelMapping]
    var validationSource: AudioValidationSource
    var report: HD96PreflightReport
}

enum CoreAudioFullCheckVerifier {
    static func verifyManifest(at url: URL, fileManager: FileManager = .default) throws -> CoreAudioFullCheckVerificationResult {
        let data = try Data(contentsOf: url)
        var manifest = try manifestDecoder().decode(CoreAudioFullCheckManifest.self, from: data)
        manifest.recomputePassed()
        let artifactChecks = makeArtifactChecks(manifest: manifest, manifestURL: url, fileManager: fileManager)
        let artifactsPassed = artifactChecks.allSatisfy(\.passed)
        let proofChecks = makeProofChecks(
            manifest: manifest,
            manifestURL: url,
            artifactChecksPassed: artifactsPassed,
            fileManager: fileManager
        )
        let proofPassed = proofChecks.allSatisfy(\.passed)
        let passed = manifest.passed && artifactsPassed && proofPassed
        let hardwareProofPassed = passed && manifest.hardwareProofPassed
        let summary: String
        if hardwareProofPassed {
            summary = "HD96/Dante hardware proof verified."
        } else if !artifactsPassed {
            summary = "Full check references missing or empty proof artifacts."
        } else if !proofPassed {
            summary = "Full check proof artifacts failed semantic verification."
        } else if !manifest.passed {
            summary = manifest.hardwareProofSummary
        } else {
            summary = manifest.hardwareProofSummary
        }

        return CoreAudioFullCheckVerificationResult(
            manifestPath: url.path,
            manifest: manifest,
            artifactChecks: artifactChecks,
            proofChecks: proofChecks,
            passed: passed,
            hardwareProofPassed: hardwareProofPassed,
            summary: summary
        )
    }

    private static func manifestDecoder() -> JSONDecoder {
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
        return decoder
    }

    private static func makeProofChecks(
        manifest: CoreAudioFullCheckManifest,
        manifestURL: URL,
        artifactChecksPassed: Bool,
        fileManager: FileManager
    ) -> [CoreAudioFullCheckProofCheck] {
        guard artifactChecksPassed else {
            return [
                CoreAudioFullCheckProofCheck(
                    name: "Proof Artifact Semantics",
                    passed: false,
                    summary: "missing or empty proof artifacts"
                )
            ]
        }

        return [
            verifyManifestRoute(manifest: manifest),
            verifyDeviceInventory(manifest: manifest, manifestURL: manifestURL, fileManager: fileManager),
            verifyPreflightReport(manifest: manifest, manifestURL: manifestURL),
            verifyProfileMapSemantics(manifest: manifest, manifestURL: manifestURL),
            verifySoundcheckReport(manifest: manifest, manifestURL: manifestURL),
            verifySoundcheckWav(manifest: manifest, manifestURL: manifestURL),
            verifySoundcheckWavSignal(manifest: manifest, manifestURL: manifestURL),
            verifyStabilityReport(manifest: manifest, manifestURL: manifestURL)
        ]
    }

    private static func verifyManifestRoute(
        manifest: CoreAudioFullCheckManifest
    ) -> CoreAudioFullCheckProofCheck {
        let passed = proofRouteSnapshotsAreReady(
            inputDevice: manifest.inputDevice,
            outputDevice: manifest.outputDevice,
            expectedInputChannels: manifest.expectedInputChannels
        )
        let summary = passed
            ? "manifest route is ready for \(manifest.expectedInputChannels)-input 96 kHz HD96/Dante proof"
            : "manifest route snapshot is not a ready 96 kHz HD96 input plus isolated stream output"
        return CoreAudioFullCheckProofCheck(name: "Manifest Route Semantics", passed: passed, summary: summary)
    }

    private static func verifyDeviceInventory(
        manifest: CoreAudioFullCheckManifest,
        manifestURL: URL,
        fileManager: FileManager
    ) -> CoreAudioFullCheckProofCheck {
        decodeProof(name: "Device Inventory Semantics", path: manifest.deviceInventoryPath, manifestURL: manifestURL) { (inventory: CoreAudioDeviceInventory) in
            let devicesCountMatches = inventory.deviceCount == inventory.devices.count && inventory.deviceCount > 0
            let expectedInputsMatch = inventory.expectedInputChannels == manifest.expectedInputChannels
            let inputUID = manifest.inputDevice.uid
            let outputUID = manifest.outputDevice.uid
            let inputReady = !inputUID.isEmpty && inventory.readyInputUIDs.contains(inputUID)
            let outputReady = !outputUID.isEmpty && inventory.readyOutputUIDs.contains(outputUID)
            let selectedInputMatches = inventory.selectedInputUID == inputUID
            let selectedOutputMatches = inventory.selectedOutputUID == outputUID
            let inputDevicePresent = inventory.devices.contains { $0.uid == inputUID && $0.inputReady }
            let outputDevicePresent = inventory.devices.contains { $0.uid == outputUID && $0.outputReady }
            let passed = devicesCountMatches &&
                expectedInputsMatch &&
                inputReady &&
                outputReady &&
                selectedInputMatches &&
                selectedOutputMatches &&
                inputDevicePresent &&
                outputDevicePresent
            let summary = passed
                ? "\(inventory.readyInputUIDs.count) input / \(inventory.readyOutputUIDs.count) output ready"
                : !selectedInputMatches || !selectedOutputMatches
                    ? "inventory selected UIDs do not match manifest input/output route"
                    : "inventory does not prove selected \(manifest.expectedInputChannels)-input route and stream output readiness"
            return CoreAudioFullCheckProofCheck(name: "Device Inventory Semantics", passed: passed, summary: summary)
        }
    }

    private static func verifyPreflightReport(
        manifest: CoreAudioFullCheckManifest,
        manifestURL: URL
    ) -> CoreAudioFullCheckProofCheck {
        guard !manifest.preflightReportPath.isEmpty else {
            return CoreAudioFullCheckProofCheck(name: "Preflight Report Semantics", passed: false, summary: "missing path")
        }

        do {
            let url = resolvedURL(path: manifest.preflightReportPath, manifestURL: manifestURL)
            let data = try Data(contentsOf: url)
            let decoder = manifestDecoder()
            if let artifact = try? decoder.decode(CoreAudioPreflightProofArtifact.self, from: data) {
                return validatePreflightProofArtifact(artifact, manifest: manifest)
            }
            let report = try decoder.decode(HD96PreflightReport.self, from: data)
            return validatePreflightReport(report, manifest: manifest)
        } catch {
            return CoreAudioFullCheckProofCheck(name: "Preflight Report Semantics", passed: false, summary: error.localizedDescription)
        }
    }

    private static func validatePreflightProofArtifact(
        _ artifact: CoreAudioPreflightProofArtifact,
        manifest: CoreAudioFullCheckManifest
    ) -> CoreAudioFullCheckProofCheck {
        let metadataMatches = artifact.validationSource == manifest.validationSource &&
            artifact.inputDevice.uid == manifest.inputDevice.uid &&
            artifact.outputDevice.uid == manifest.outputDevice.uid &&
            artifact.expectedInputChannels == manifest.expectedInputChannels &&
            artifact.detectedInputChannels == manifest.expectedInputChannels &&
            abs(artifact.detectedSampleRate - 96_000.0) < 1.0
        let routeSnapshotsReady = proofRouteSnapshotsAreReady(
            inputDevice: artifact.inputDevice,
            outputDevice: artifact.outputDevice,
            expectedInputChannels: manifest.expectedInputChannels
        )
        let reportMatches = artifact.report.isReady == manifest.preflightReady && artifact.report.isReady
        let passed = metadataMatches && routeSnapshotsReady && reportMatches
        let summary = passed
            ? artifact.report.summary
            : "preflight artifact does not match manifest route, source, channel count, format, or readiness"
        return CoreAudioFullCheckProofCheck(name: "Preflight Report Semantics", passed: passed, summary: summary)
    }

    private static func validatePreflightReport(
        _ report: HD96PreflightReport,
        manifest: CoreAudioFullCheckManifest
    ) -> CoreAudioFullCheckProofCheck {
        let passed = report.isReady == manifest.preflightReady && report.isReady
        let summary = passed ? report.summary : "preflight report is not ready or does not match manifest"
        return CoreAudioFullCheckProofCheck(name: "Preflight Report Semantics", passed: passed, summary: summary)
    }

    private static func verifyProfileMapSemantics(
        manifest: CoreAudioFullCheckManifest,
        manifestURL: URL
    ) -> CoreAudioFullCheckProofCheck {
        do {
            let preflightMappings = try decodePreflightChannelMappings(manifest: manifest, manifestURL: manifestURL)
            let soundcheck: SoundcheckReport = try decodeProofValue(path: manifest.soundcheckReportPath, manifestURL: manifestURL)
            let stability: StabilityMonitorReport = try decodeProofValue(path: manifest.stabilityReportPath, manifestURL: manifestURL)

            let expectedCount = manifest.expectedInputChannels
            let countsMatch = preflightMappings.count == expectedCount &&
                soundcheck.channelMappings.count == expectedCount &&
                stability.channelMappings.count == expectedCount
            let mapsMatch = soundcheck.channelMappings == preflightMappings &&
                stability.channelMappings == preflightMappings
            let preflightCoverage = ChannelMapCoverage.make(
                channelMappings: preflightMappings,
                inputChannelCount: expectedCount
            )
            let soundcheckCoverage = ChannelMapCoverage.make(
                channelMappings: soundcheck.channelMappings,
                inputChannelCount: expectedCount
            )
            let stabilityCoverage = ChannelMapCoverage.make(
                channelMappings: stability.channelMappings,
                inputChannelCount: expectedCount
            )
            let sourceRoleCoverage = SourceRoleCoverage.make(channelMappings: preflightMappings)
            let stereoLinkCoverage = StereoLinkCoverage.make(channelMappings: preflightMappings)
            let manualOverrideCoverage = ManualOverrideCoverage.make(channelMappings: preflightMappings)
            let passed = countsMatch &&
                mapsMatch &&
                preflightCoverage.isReady &&
                soundcheckCoverage.isReady &&
                stabilityCoverage.isReady &&
                sourceRoleCoverage.isReady &&
                stereoLinkCoverage.isReady &&
                manualOverrideCoverage.isReady

            let summary: String
            if passed {
                summary = "\(expectedCount) mapped inputs match preflight/soundcheck/stability; \(sourceRoleCoverage.summary); stereo \(stereoLinkCoverage.summary); manual \(manualOverrideCoverage.summary)"
            } else if !countsMatch {
                summary = "channel-map counts do not match expected \(expectedCount) inputs"
            } else if !mapsMatch {
                summary = "preflight, soundcheck, and stability channel maps do not match"
            } else if !preflightCoverage.isReady {
                summary = "preflight channel map is not ready: \(preflightCoverage.summary)"
            } else if !soundcheckCoverage.isReady {
                summary = "soundcheck channel map is not ready: \(soundcheckCoverage.summary)"
            } else if !stabilityCoverage.isReady {
                summary = "stability channel map is not ready: \(stabilityCoverage.summary)"
            } else if !sourceRoleCoverage.isReady {
                summary = "source roles are not ready: \(sourceRoleCoverage.summary)"
            } else if !stereoLinkCoverage.isReady {
                summary = "stereo links are invalid: \(stereoLinkCoverage.summary)"
            } else {
                summary = "manual overrides are invalid: \(manualOverrideCoverage.summary)"
            }

            return CoreAudioFullCheckProofCheck(name: "Profile Map Semantics", passed: passed, summary: summary)
        } catch {
            return CoreAudioFullCheckProofCheck(name: "Profile Map Semantics", passed: false, summary: error.localizedDescription)
        }
    }

    private static func verifySoundcheckReport(
        manifest: CoreAudioFullCheckManifest,
        manifestURL: URL
    ) -> CoreAudioFullCheckProofCheck {
        decodeProof(name: "Soundcheck Report Semantics", path: manifest.soundcheckReportPath, manifestURL: manifestURL) { (report: SoundcheckReport) in
            let recordingPath = manifest.soundcheckRecordingPath.map {
                resolvedURL(path: $0, manifestURL: manifestURL).path
            }
            let reportRecordingPath = resolvedURL(path: report.recordingPath, manifestURL: manifestURL).path
            let durationFloor = max(0.0, manifest.soundcheckSeconds * 0.95)
            let reportCheckNames = Set(report.checks.map(\.name))
            let hasProofControlChecks = reportCheckNames.contains("Watchdog SAFE") &&
                reportCheckNames.contains("SAFE Bypass")
            let reportChecksPassed = report.checks.allSatisfy(\.passed)
            let passed = report.passed &&
                reportChecksPassed &&
                manifest.soundcheckPassed == true &&
                report.validationSource == manifest.validationSource &&
                report.inputDevice.uid == manifest.inputDevice.uid &&
                report.outputDevice.uid == manifest.outputDevice.uid &&
                proofRouteSnapshotsAreReady(
                    inputDevice: report.inputDevice,
                    outputDevice: report.outputDevice,
                    expectedInputChannels: manifest.expectedInputChannels
                ) &&
                report.scene == manifest.scene &&
                report.expectedInputChannels == manifest.expectedInputChannels &&
                report.detectedInputChannels == manifest.expectedInputChannels &&
                abs(report.detectedSampleRate - 96_000.0) < 1.0 &&
                report.recordingChannelCount == manifest.expectedInputChannels + 2 &&
                report.recordingSampleRate == 96_000 &&
                hasProofControlChecks &&
                report.watchdogSafeActive == false &&
                report.safeBypassEnabled == true &&
                report.recordingDurationSeconds >= durationFloor &&
                (recordingPath == nil || reportRecordingPath == recordingPath)
            let summary = passed
                ? "passed \(report.detectedInputChannels) inputs at \(Int(report.detectedSampleRate.rounded())) Hz"
                : "soundcheck report does not match manifest, route, source, or pass criteria"
            return CoreAudioFullCheckProofCheck(name: "Soundcheck Report Semantics", passed: passed, summary: summary)
        }
    }

    private static func verifySoundcheckWav(
        manifest: CoreAudioFullCheckManifest,
        manifestURL: URL
    ) -> CoreAudioFullCheckProofCheck {
        guard let path = manifest.soundcheckRecordingPath, !path.isEmpty else {
            return CoreAudioFullCheckProofCheck(name: "Soundcheck WAV Semantics", passed: false, summary: "missing recording path")
        }
        do {
            let url = resolvedURL(path: path, manifestURL: manifestURL)
            let metadata = try WavMetadata.read(from: url)
            let durationFloor = max(0.0, manifest.soundcheckSeconds * 0.95)
            let passed = metadata.formatCode == 3 &&
                metadata.bitsPerSample == 32 &&
                metadata.sampleRate == 96_000 &&
                metadata.channelCount == manifest.expectedInputChannels + 2 &&
                metadata.dataByteCount > 0 &&
                metadata.durationSeconds >= durationFloor
            let summary = passed
                ? "\(metadata.channelCount)ch \(metadata.sampleRate) Hz \(String(format: "%.1f", metadata.durationSeconds))s"
                : "WAV metadata does not match expected IEEE-float \(manifest.expectedInputChannels + 2)ch/96 kHz recording"
            return CoreAudioFullCheckProofCheck(name: "Soundcheck WAV Semantics", passed: passed, summary: summary)
        } catch {
            return CoreAudioFullCheckProofCheck(name: "Soundcheck WAV Semantics", passed: false, summary: error.localizedDescription)
        }
    }

    private static func verifySoundcheckWavSignal(
        manifest: CoreAudioFullCheckManifest,
        manifestURL: URL
    ) -> CoreAudioFullCheckProofCheck {
        guard let recordingPath = manifest.soundcheckRecordingPath, !recordingPath.isEmpty else {
            return CoreAudioFullCheckProofCheck(name: "Soundcheck WAV Signal Semantics", passed: false, summary: "missing recording path")
        }
        guard let reportPath = manifest.soundcheckReportPath, !reportPath.isEmpty else {
            return CoreAudioFullCheckProofCheck(name: "Soundcheck WAV Signal Semantics", passed: false, summary: "missing soundcheck report path")
        }

        do {
            let recordingURL = resolvedURL(path: recordingPath, manifestURL: manifestURL)
            let reportURL = resolvedURL(path: reportPath, manifestURL: manifestURL)
            let reportData = try Data(contentsOf: reportURL)
            let report = try manifestDecoder().decode(SoundcheckReport.self, from: reportData)
            let signal = try WavSignalSummary.read(
                from: recordingURL,
                inputChannelCount: manifest.expectedInputChannels
            )
            let inputActivityMatches = signal.activeInputChannelCount > 0 &&
                signal.activeInputChannelCount == report.recordedActiveInputChannelCount &&
                signal.activeInputChannels == report.recordedActiveInputChannels
            let streamActivityMatches = signal.activeStreamOutputChannelCount == 2 &&
                signal.activeStreamOutputChannelCount == report.recordedStreamOutputActiveChannelCount
            let inputPeaksMatch = dbValuesMatch(
                signal.inputPeakDbByChannel,
                report.recordedInputPeakDbByChannel,
                toleranceDb: 0.25
            )
            let streamPeaksMatch = dbValuesMatch(
                signal.streamOutputPeakDb,
                report.recordedStreamOutputPeakDb,
                toleranceDb: 0.25
            )
            let passed = inputActivityMatches &&
                streamActivityMatches &&
                inputPeaksMatch &&
                streamPeaksMatch
            let summary = passed
                ? "\(signal.activeInputChannelCount) recorded input(s), \(signal.activeStreamOutputChannelCount) stream channel(s) active"
                : "WAV payload activity does not match soundcheck report or required stream/input activity"
            return CoreAudioFullCheckProofCheck(name: "Soundcheck WAV Signal Semantics", passed: passed, summary: summary)
        } catch {
            return CoreAudioFullCheckProofCheck(name: "Soundcheck WAV Signal Semantics", passed: false, summary: error.localizedDescription)
        }
    }

    private static func verifyStabilityReport(
        manifest: CoreAudioFullCheckManifest,
        manifestURL: URL
    ) -> CoreAudioFullCheckProofCheck {
        decodeProof(name: "Stability Report Semantics", path: manifest.stabilityReportPath, manifestURL: manifestURL) { (report: StabilityMonitorReport) in
            let durationFloor = max(30.0, manifest.stabilitySeconds * 0.95)
            let reportCheckNames = Set(report.checks.map(\.name))
            let hasRequiredProofChecks =
                reportCheckNames.contains("SAFE Bypass") &&
                reportCheckNames.contains("FREEZE") &&
                reportCheckNames.contains("Output Clock Drift")
            let reportChecksPassed = report.checks.allSatisfy(\.passed)
            let passed = report.passed &&
                reportChecksPassed &&
                manifest.stabilityPassed == true &&
                report.validationSource == manifest.validationSource &&
                report.inputDevice.uid == manifest.inputDevice.uid &&
                report.outputDevice.uid == manifest.outputDevice.uid &&
                proofRouteSnapshotsAreReady(
                    inputDevice: report.inputDevice,
                    outputDevice: report.outputDevice,
                    expectedInputChannels: manifest.expectedInputChannels
                ) &&
                report.scene == manifest.scene &&
                report.expectedInputChannels == manifest.expectedInputChannels &&
                report.detectedInputChannels == manifest.expectedInputChannels &&
                abs(report.detectedSampleRate - 96_000.0) < 1.0 &&
                hasRequiredProofChecks &&
                report.safeBypassEnabled == false &&
                report.frozen == false &&
                report.durationSeconds >= durationFloor
            let summary = passed
                ? "passed for \(String(format: "%.1f", report.durationSeconds))s"
                : "stability report does not match manifest, route, source, duration, or pass criteria"
            return CoreAudioFullCheckProofCheck(name: "Stability Report Semantics", passed: passed, summary: summary)
        }
    }

    private static func decodeProof<T: Decodable>(
        name: String,
        path: String?,
        manifestURL: URL,
        validate: (T) -> CoreAudioFullCheckProofCheck
    ) -> CoreAudioFullCheckProofCheck {
        guard let path, !path.isEmpty else {
            return CoreAudioFullCheckProofCheck(name: name, passed: false, summary: "missing path")
        }
        do {
            let url = resolvedURL(path: path, manifestURL: manifestURL)
            let data = try Data(contentsOf: url)
            let decoded = try manifestDecoder().decode(T.self, from: data)
            return validate(decoded)
        } catch {
            return CoreAudioFullCheckProofCheck(name: name, passed: false, summary: error.localizedDescription)
        }
    }

    private static func decodeProofValue<T: Decodable>(
        path: String?,
        manifestURL: URL
    ) throws -> T {
        guard let path, !path.isEmpty else {
            throw ProofSemanticError.missingPath
        }
        let url = resolvedURL(path: path, manifestURL: manifestURL)
        let data = try Data(contentsOf: url)
        return try manifestDecoder().decode(T.self, from: data)
    }

    private static func decodePreflightChannelMappings(
        manifest: CoreAudioFullCheckManifest,
        manifestURL: URL
    ) throws -> [ChannelMapping] {
        guard !manifest.preflightReportPath.isEmpty else {
            throw ProofSemanticError.missingPath
        }
        let url = resolvedURL(path: manifest.preflightReportPath, manifestURL: manifestURL)
        let data = try Data(contentsOf: url)
        let decoder = manifestDecoder()
        if let artifact = try? decoder.decode(CoreAudioPreflightProofArtifact.self, from: data) {
            return artifact.channelMappings
        }
        _ = try decoder.decode(HD96PreflightReport.self, from: data)
        throw ProofSemanticError.legacyPreflightMissingChannelMap
    }

    private static func makeArtifactChecks(
        manifest: CoreAudioFullCheckManifest,
        manifestURL: URL,
        fileManager: FileManager
    ) -> [CoreAudioFullCheckArtifactCheck] {
        [
            ("Device Inventory", manifest.deviceInventoryPath),
            ("Preflight Report", manifest.preflightReportPath),
            ("Soundcheck WAV", manifest.soundcheckRecordingPath),
            ("Soundcheck Report", manifest.soundcheckReportPath),
            ("Stability Report", manifest.stabilityReportPath)
        ].map { name, path in
            makeArtifactCheck(
                name: name,
                path: path,
                manifestURL: manifestURL,
                fileManager: fileManager
            )
        }
    }

    private static func makeArtifactCheck(
        name: String,
        path: String?,
        manifestURL: URL,
        fileManager: FileManager
    ) -> CoreAudioFullCheckArtifactCheck {
        guard let path, !path.isEmpty else {
            return CoreAudioFullCheckArtifactCheck(name: name, path: "", exists: false, byteCount: 0)
        }
        let url = resolvedURL(path: path, manifestURL: manifestURL)
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        let byteCount = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        return CoreAudioFullCheckArtifactCheck(
            name: name,
            path: url.path,
            exists: attributes != nil,
            byteCount: byteCount
        )
    }

    private static func resolvedURL(path: String, manifestURL: URL) -> URL {
        let url = URL(fileURLWithPath: path)
        if url.path == path, path.hasPrefix("/") {
            return url
        }
        return manifestURL.deletingLastPathComponent().appendingPathComponent(path)
    }

    private static func dbValuesMatch(_ lhs: [Double], _ rhs: [Double], toleranceDb: Double) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { left, right in
            if left <= -99.0 && right <= -99.0 {
                return true
            }
            return left.isFinite &&
                right.isFinite &&
                abs(left - right) <= toleranceDb
        }
    }

    private static func proofRouteSnapshotsAreReady(
        inputDevice: SoundcheckDeviceSnapshot,
        outputDevice: SoundcheckDeviceSnapshot,
        expectedInputChannels: Int
    ) -> Bool {
        let inputReady = !inputDevice.uid.isEmpty &&
            inputDevice.inputChannels >= expectedInputChannels &&
            abs(inputDevice.sampleRate - 96_000.0) < 1.0 &&
            inputDevice.inputFormatSupported
        let outputReady = !outputDevice.uid.isEmpty &&
            outputDevice.outputChannels >= 2 &&
            abs(outputDevice.sampleRate - 96_000.0) < 1.0 &&
            outputDevice.outputFormatSupported
        let isolation = LivestreamOutputIsolation.make(
            inputDevice: AMDeviceInfo(snapshot: inputDevice),
            outputDevice: AMDeviceInfo(snapshot: outputDevice)
        )
        return inputReady && outputReady && isolation.passed
    }

    private enum ProofSemanticError: LocalizedError {
        case missingPath
        case legacyPreflightMissingChannelMap

        var errorDescription: String? {
            switch self {
            case .missingPath:
                return "missing path"
            case .legacyPreflightMissingChannelMap:
                return "preflight proof artifact does not include channel mappings"
            }
        }
    }
}

struct CoreAudioDeviceInventoryDevice: Codable, Equatable, Sendable {
    var uid: String
    var name: String
    var inputChannels: Int
    var outputChannels: Int
    var sampleRate: Double
    var inputFormatSummary: String
    var outputFormatSummary: String
    var inputFormatSupported: Bool
    var outputFormatSupported: Bool
    var inputReady: Bool
    var inputReadiness: String
    var outputReady: Bool
    var outputReadiness: String
    var outputIsolationReady: Bool?
    var outputIsolationObserved: String?

    static func make(
        device: AMDeviceInfo,
        expectedInputChannels: Int,
        selectedInputDevice: AMDeviceInfo?
    ) -> CoreAudioDeviceInventoryDevice {
        let sampleRateReady = abs(device.sampleRate - 96_000.0) < 1.0
        let inputFailures = readinessFailures([
            (device.inputChannels >= expectedInputChannels, "\(device.inputChannels)/\(expectedInputChannels) inputs"),
            (sampleRateReady, "\(Int(device.sampleRate.rounded())) Hz"),
            (device.inputFormatSupported, device.inputFormatSummary)
        ])
        let inputReady = inputFailures.isEmpty

        var outputFailures = readinessFailures([
            (device.outputChannels >= 2, "\(device.outputChannels) outputs"),
            (sampleRateReady, "\(Int(device.sampleRate.rounded())) Hz"),
            (device.outputFormatSupported, device.outputFormatSummary)
        ])
        var isolationReady: Bool?
        var isolationObserved: String?
        if let selectedInputDevice, device.outputChannels > 0 {
            let isolation = LivestreamOutputIsolation.make(
                inputDevice: selectedInputDevice,
                outputDevice: device
            )
            isolationReady = isolation.passed
            isolationObserved = isolation.observed
            if !isolation.passed {
                outputFailures.append(isolation.observed)
            }
        }
        let outputReady = outputFailures.isEmpty

        return CoreAudioDeviceInventoryDevice(
            uid: device.uid,
            name: device.name,
            inputChannels: device.inputChannels,
            outputChannels: device.outputChannels,
            sampleRate: device.sampleRate,
            inputFormatSummary: device.inputFormatSummary,
            outputFormatSummary: device.outputFormatSummary,
            inputFormatSupported: device.inputFormatSupported,
            outputFormatSupported: device.outputFormatSupported,
            inputReady: inputReady,
            inputReadiness: inputReady ? "ready for \(expectedInputChannels) input channels at 96 kHz" : inputFailures.joined(separator: "; "),
            outputReady: outputReady,
            outputReadiness: outputReady ? "ready for stereo stream output at 96 kHz" : outputFailures.joined(separator: "; "),
            outputIsolationReady: isolationReady,
            outputIsolationObserved: isolationObserved
        )
    }

    private static func readinessFailures(_ checks: [(Bool, String)]) -> [String] {
        checks.compactMap { passed, observed in passed ? nil : observed }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
