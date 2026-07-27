import Darwin
import AVFoundation
import Foundation
import SwiftUI

@main
struct AutoMixNativeApp: App {
    init() {
        if CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h") {
            printCommandHelp()
            Darwin.exit(0)
        }

        if CommandLine.arguments.contains("--monitor-smoke") {
            Darwin.exit(MonitorSmoke.run())
        }

        guard CommandLine.arguments.contains("--smoke-test") else { return }
        let bridge = AutoMixEngineBridge()
        let devices = bridge.availableDevices()
        print("AutoMix Native smoke: \(devices.count) Core Audio devices")
        for device in devices.prefix(12) {
            let inputFormat = device.inputFormatSupported ? "input format OK" : "input format unsupported"
            let outputFormat = device.outputFormatSupported ? "output format OK" : "output format unsupported"
            print(
                "\(device.name) | in=\(device.inputChannels) out=\(device.outputChannels) rate=\(Int(device.sampleRate.rounded())) \(inputFormat) \(outputFormat) uid=\(device.uid)"
            )
        }
        let runsSimulatedAudio = CommandLine.arguments.contains("--simulate-audio")
        let runsSimulatedStability = CommandLine.arguments.contains("--simulate-stability")
        let runsCoreAudioPreflight = CommandLine.arguments.contains("--core-audio-preflight")
        let runsCoreAudioSoundcheck = CommandLine.arguments.contains("--core-audio-soundcheck")
        let runsCoreAudioStability = CommandLine.arguments.contains("--core-audio-stability")
        let runsCoreAudioFullCheck = CommandLine.arguments.contains("--core-audio-full-check")
        let verifiesFullCheck = CommandLine.arguments.contains("--verify-full-check")
        let verifiesRealtimeNoAllocation = CommandLine.arguments.contains("--verify-realtime-no-allocation")
        let writesServiceProfile = CommandLine.arguments.contains("--write-service-profile")
        let writesDeviceInventory = CommandLine.arguments.contains("--write-device-inventory")
        if writesDeviceInventory {
            writeCoreAudioDeviceInventory(bridge: bridge)
        }
        if writesServiceProfile {
            writeServiceProfile()
        }
        if runsSimulatedAudio {
            runSimulatedAudioSmoke(bridge: bridge)
        }
        if runsSimulatedStability {
            runSimulatedStabilitySmoke(bridge: runsSimulatedAudio ? AutoMixEngineBridge() : bridge)
        }
        if runsCoreAudioPreflight {
            runCoreAudioPreflight(bridge: (runsSimulatedAudio || runsSimulatedStability) ? AutoMixEngineBridge() : bridge)
        }
        if runsCoreAudioSoundcheck {
            runCoreAudioSoundcheck(bridge: (runsSimulatedAudio || runsSimulatedStability || runsCoreAudioPreflight) ? AutoMixEngineBridge() : bridge)
        }
        if runsCoreAudioStability {
            runCoreAudioStability(bridge: (runsSimulatedAudio || runsSimulatedStability || runsCoreAudioPreflight || runsCoreAudioSoundcheck) ? AutoMixEngineBridge() : bridge)
        }
        if runsCoreAudioFullCheck {
            runCoreAudioFullCheck()
        }
        if verifiesFullCheck {
            verifyCoreAudioFullCheckManifest()
        }
        if verifiesRealtimeNoAllocation {
            verifyRealtimeNoAllocation(bridge: bridge)
        }
        Darwin.exit(0)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }

    private func printCommandHelp() {
        print("""
        AutoMix Native

        Launch without flags to open the macOS app.

        Headless validation commands:
          --smoke-test
              List current Core Audio devices and exit.
          --smoke-test --simulate-audio
              Run simulated 64-channel/96 kHz HD96 audio, meters, SAFE/FREEZE, and soundcheck.
          --smoke-test --simulate-stability
              Run simulated separate-output stability validation.
          --smoke-test --verify-realtime-no-allocation
              Run DEBUG realtime allocation probes.
          --smoke-test --write-device-inventory [--input-uid UID] [--output-uid UID]
              Write a no-audio Core Audio device inventory JSON.
          --smoke-test --write-service-profile --input-uid UID [--output-uid UID] [--profile PATH]
              Write a starter one-to-one service profile without changing HD96 or Dante config.
          --smoke-test --core-audio-preflight --input-uid UID --output-uid UID [--profile PATH]
              Write route, clock, format, channel-map, role, and output-isolation preflight JSON.
          --smoke-test --core-audio-soundcheck --input-uid UID --output-uid UID [--profile PATH]
              Record raw inputs plus stream L/R and write soundcheck JSON.
          --smoke-test --core-audio-stability --input-uid UID --output-uid UID [--profile PATH]
              Run non-recording drift/dropout validation and write stability JSON.
          --smoke-test --core-audio-full-check --input-uid UID --output-uid UID [--profile PATH]
              Run inventory, preflight, soundcheck, stability, manifest generation, and proof verification.
          --smoke-test --verify-full-check --manifest PATH
              Verify a full-check manifest and require real Core Audio hardware proof.

        Common options:
          --expected-inputs N
          --soundcheck-seconds N
          --stability-seconds N
          --scene preService|worship|sermon|prayer|postService
          --output-dir PATH
          --profile PATH
        """)
    }

    private func runSimulatedStabilitySmoke(bridge: AutoMixEngineBridge) {
        let roles = simulatedRoles(count: 64)
        let mappings = simulatedMappingsWithManualOverride(count: 64)
        let durationSeconds = 30.0

        do {
            try bridge.startSimulatedSeparateOutput(
                withChannelCount: 64,
                sampleRate: 96_000,
                inputBufferFrameSize: 256,
                outputBufferFrameSize: 256,
                channelRoles: roles,
                inputChannelIndices: identityInputMap(count: 64)
            )
            defer { bridge.stop() }

            let manualSummary = CLIManualOverrideApplier.apply(mappings, to: bridge)
            bridge.setSceneName(MixScene.worship.rawValue)
            bridge.setSafeBypass(false)
            bridge.setFrozen(false)
            waitForCallbacks(bridge: bridge, timeout: 5.0)
            let initialOutputLevels = waitForActiveStreamOutput(bridge: bridge, timeout: 5.0)

            let startDropouts = bridge.dropoutCount
            let startCallbackOverruns = bridge.callbackOverrunCount
            let startRenderDeadlineMisses = bridge.renderDeadlineMissCount
            let startOutputUnderruns = bridge.outputUnderrunCount
            let startOutputOverruns = bridge.outputOverrunCount
            var minOutputLevels = initialOutputLevels
            var maxOutputLevels = minOutputLevels
            var maxActiveInputChannelCount = activeInputChannelCount(bridge.inputLevelsDb().map { $0.doubleValue }, channelCount: 64)
            var minMomentaryLufs = finiteOrSilence(bridge.momentaryLufs)
            var maxMomentaryLufs = minMomentaryLufs
            var minLimiterGainReductionDb = finiteOrSilence(bridge.limiterGainReductionDb)
            let outputRingTargetFrames = bridge.separateOutputPrebufferFrames
            var minOutputRingFillFrames = bridge.separateOutputRingFillFrames
            var maxOutputRingFillFrames = bridge.separateOutputRingFillFrames
            var maxAbsOutputClockCorrectionPpm = abs(bridge.outputClockCorrectionPpm)

            let startedAt = Date()
            while Date().timeIntervalSince(startedAt) < durationSeconds {
                let inputLevels = bridge.inputLevelsDb().map { $0.doubleValue }
                let outputLevels = normalizedStereoLevels(bridge.outputLevelsDb().map { $0.doubleValue })
                for index in 0..<2 {
                    minOutputLevels[index] = min(minOutputLevels[index], outputLevels[index])
                    maxOutputLevels[index] = max(maxOutputLevels[index], outputLevels[index])
                }
                maxActiveInputChannelCount = max(
                    maxActiveInputChannelCount,
                    activeInputChannelCount(inputLevels, channelCount: 64)
                )
                if bridge.momentaryLufs.isFinite {
                    minMomentaryLufs = min(minMomentaryLufs, bridge.momentaryLufs)
                    maxMomentaryLufs = max(maxMomentaryLufs, bridge.momentaryLufs)
                }
                if bridge.limiterGainReductionDb.isFinite {
                    minLimiterGainReductionDb = min(minLimiterGainReductionDb, bridge.limiterGainReductionDb)
                }
                if outputRingTargetFrames > 0 {
                    minOutputRingFillFrames = min(
                        minOutputRingFillFrames,
                        bridge.separateOutputRingFillFrames
                    )
                    maxOutputRingFillFrames = max(
                        maxOutputRingFillFrames,
                        bridge.separateOutputRingFillFrames
                    )
                    maxAbsOutputClockCorrectionPpm = max(
                        maxAbsOutputClockCorrectionPpm,
                        abs(bridge.outputClockCorrectionPpm)
                    )
                }
                Thread.sleep(forTimeInterval: 0.1)
            }

            let observedDurationSeconds = Date().timeIntervalSince(startedAt)
            let simulatedDevice = bridge.availableDevices().first { $0.uid == "com.livedaw.automix.simulated-hd96-dante" }
            let dropoutDelta = bridge.dropoutCount >= startDropouts ? bridge.dropoutCount - startDropouts : 0
            let callbackOverrunDelta = bridge.callbackOverrunCount >= startCallbackOverruns ? bridge.callbackOverrunCount - startCallbackOverruns : 0
            let renderDeadlineMissDelta = bridge.renderDeadlineMissCount >= startRenderDeadlineMisses ? bridge.renderDeadlineMissCount - startRenderDeadlineMisses : 0
            let outputUnderrunDelta = bridge.outputUnderrunCount >= startOutputUnderruns ? bridge.outputUnderrunCount - startOutputUnderruns : 0
            let outputOverrunDelta = bridge.outputOverrunCount >= startOutputOverruns ? bridge.outputOverrunCount - startOutputOverruns : 0
            let report = StabilityMonitorReport.make(
                durationSeconds: observedDurationSeconds,
                inputDevice: snapshot(for: simulatedDevice),
                outputDevice: snapshot(for: simulatedDevice),
                scene: .worship,
                expectedInputChannels: 64,
                detectedInputChannels: bridge.inputChannelCount,
                detectedSampleRate: bridge.sampleRate,
                bufferFrameSize: bridge.bufferFrameSize,
                lastCallbackFrames: bridge.lastCallbackFrameCount,
                maxObservedCallbackFrames: bridge.maxObservedCallbackFrameCount,
                dropoutDelta: dropoutDelta,
                callbackOverrunDelta: callbackOverrunDelta,
                renderDeadlineMissDelta: renderDeadlineMissDelta,
                outputUnderrunDelta: outputUnderrunDelta,
                outputOverrunDelta: outputOverrunDelta,
                outputRingTargetFrames: outputRingTargetFrames,
                minOutputRingFillFrames: minOutputRingFillFrames,
                maxOutputRingFillFrames: maxOutputRingFillFrames,
                maxAbsOutputClockCorrectionPpm: maxAbsOutputClockCorrectionPpm,
                watchdogSafeActive: bridge.watchdogSafeActive,
                safeBypassEnabled: false,
                frozen: false,
                channelMappings: mappings,
                minStreamOutputLevelsDb: minOutputLevels,
                maxStreamOutputLevelsDb: maxOutputLevels,
                maxActiveInputChannelCount: maxActiveInputChannelCount,
                minMomentaryLufs: minMomentaryLufs,
                maxMomentaryLufs: maxMomentaryLufs,
                minLimiterGainReductionDb: minLimiterGainReductionDb
            )
            let reportURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("automix-native-sim-stability.json")
            try writeStabilityReport(report, to: reportURL)

            print(
                String(
                    format: "Simulated stability: %@ passed=%@ duration=%.1fs manualOverrides=%d/%d dropouts=%lu callbackOverruns=%lu deadlineMisses=%lu underruns=%lu outputOverruns=%lu",
                    reportURL.path,
                    report.passed ? "true" : "false",
                    observedDurationSeconds,
                    manualSummary.appliedCount,
                    manualSummary.requestedCount,
                    dropoutDelta,
                    callbackOverrunDelta,
                    renderDeadlineMissDelta,
                    outputUnderrunDelta,
                    outputOverrunDelta
                )
            )
            if !report.passed {
                for check in report.checks where !check.passed {
                    print("Stability check failed: \(check.name) expected=\(check.expected) observed=\(check.observed)")
                }
                Darwin.exit(4)
            }
        } catch {
            print("Simulated stability failed: \(error.localizedDescription)")
            Darwin.exit(5)
        }
    }

    private func runSimulatedAudioSmoke(bridge: AutoMixEngineBridge) {
        let mappings = simulatedMappingsWithManualOverride(count: 64)
        let roles = mappings.map(\.role.rawValue)
        do {
            try bridge.startSimulated(
                withChannelCount: 64,
                sampleRate: 96_000,
                bufferFrameSize: 256,
                channelRoles: roles,
                inputChannelIndices: identityInputMap(count: 64)
            )
            bridge.setSceneName(MixScene.sermon.rawValue)
            let roleApplied = bridge.setChannelRoleForChannel(0, role: ChannelRole.speech.rawValue)
            let manualSummary = CLIManualOverrideApplier.apply(mappings, to: bridge)
            Thread.sleep(forTimeInterval: 0.25)
            let levels = bridge.inputLevelsDb().prefix(8).map { String(format: "%.1f", $0.doubleValue) }.joined(separator: ", ")
            let outputLevels = bridge.outputLevelsDb().map { String(format: "%.1f", $0.doubleValue) }.joined(separator: ", ")
            let masterTelemetry = String(
                format: "M %.1f / S %.1f / I %.1f LUFS, limiter %.1f dB",
                bridge.momentaryLufs,
                bridge.shortTermLufs,
                bridge.integratedLufs,
                bridge.limiterGainReductionDb
            )
            print("Simulated engine: \(bridge.status)")
            print("Scene/role/manual override smoke: scene=sermon ch=1 roleApplied=\(roleApplied) manualOverridesApplied=\(manualSummary.appliedCount)/\(manualSummary.requestedCount)")
            print("Callback frames: last=\(bridge.lastCallbackFrameCount) max=\(bridge.maxObservedCallbackFrameCount) dropouts=\(bridge.dropoutCount) callbackOverruns=\(bridge.callbackOverrunCount) deadlineMisses=\(bridge.renderDeadlineMissCount)")
            print("First 8 input meters dBFS: \(levels)")
            print("Stream output meters dBFS: \(outputLevels)")
            print("Master telemetry: \(masterTelemetry)")

            bridge.setFrozen(true)
            Thread.sleep(forTimeInterval: 0.15)
            let frozenOutputLevels = bridge.outputLevelsDb().map { String(format: "%.1f", $0.doubleValue) }.joined(separator: ", ")
            print("FREEZE stream output meters dBFS: \(frozenOutputLevels)")

            bridge.setSafeBypass(true)
            Thread.sleep(forTimeInterval: 0.15)
            let safeOutputLevels = bridge.outputLevelsDb().map { String(format: "%.1f", $0.doubleValue) }.joined(separator: ", ")
            print("SAFE stream output meters dBFS: \(safeOutputLevels)")

            let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("automix-native-sim.wav")
            try? FileManager.default.removeItem(at: url)
            try bridge.startTestRecording(at: url, seconds: 1.0)
            var finalLevels: [Double] = []
            var finishedRecording: URL?
            let deadline = Date().addingTimeInterval(20.0)
            while Date() < deadline {
                finalLevels = bridge.inputLevelsDb().map { $0.doubleValue }
                if let finished = bridge.consumeFinishedRecordingURL() {
                    finishedRecording = finished
                    break
                }
                Thread.sleep(forTimeInterval: 0.025)
            }
            print("Post-record realtime counters: dropouts=\(bridge.dropoutCount) callbackOverruns=\(bridge.callbackOverrunCount) deadlineMisses=\(bridge.renderDeadlineMissCount) outputUnderruns=\(bridge.outputUnderrunCount) outputOverruns=\(bridge.outputOverrunCount)")
            if let finished = finishedRecording {
                let finalOutputLevels = bridge.outputLevelsDb().map { $0.doubleValue }
                let simulatedDevice = bridge.availableDevices().first { $0.uid == "com.livedaw.automix.simulated-hd96-dante" }
                let reportInput = SoundcheckReportInput(
                    recordingURL: finished,
                    expectedRecordingDurationSeconds: 1.0,
                    inputDevice: snapshot(for: simulatedDevice),
                    outputDevice: snapshot(for: simulatedDevice),
                    scene: .sermon,
                    expectedInputChannels: 64,
                    detectedInputChannels: bridge.inputChannelCount,
                    detectedSampleRate: bridge.sampleRate,
                    bufferFrameSize: bridge.bufferFrameSize,
                    lastCallbackFrames: bridge.lastCallbackFrameCount,
                    maxObservedCallbackFrames: bridge.maxObservedCallbackFrameCount,
                    dropoutCount: bridge.dropoutCount,
                    callbackOverrunCount: bridge.callbackOverrunCount,
                    renderDeadlineMissCount: bridge.renderDeadlineMissCount,
                    outputUnderrunCount: bridge.outputUnderrunCount,
                    outputOverrunCount: bridge.outputOverrunCount,
                    watchdogSafeActive: bridge.watchdogSafeActive,
                    safeBypassEnabled: true,
                    frozen: true,
                    channelMappings: mappings,
                    latestInputLevelsDb: finalLevels,
                    latestStreamOutputLevelsDb: finalOutputLevels,
                    latestMomentaryLufs: bridge.momentaryLufs,
                    latestShortTermLufs: bridge.shortTermLufs,
                    latestIntegratedLufs: bridge.integratedLufs,
                    latestLimiterGainReductionDb: bridge.limiterGainReductionDb
                )
                let report = try SoundcheckReport.make(from: reportInput)
                let reportURL = try report.writeJSON(beside: finished)
                print("Simulated recording: \(finished.path) bytes=\(report.recordingByteCount)")
                print("Simulated soundcheck report: \(reportURL.path) passed=\(report.passed)")
            } else {
                print("Simulated recording: not finished recording=\(bridge.recording) frames=\(bridge.recordedFrameCount)/\(bridge.recordingTargetFrameCount) status=\(bridge.status)")
                Darwin.exit(3)
            }
            bridge.stop()
        } catch {
            print("Simulated engine failed: \(error.localizedDescription)")
            Darwin.exit(2)
        }
    }

    private func verifyRealtimeNoAllocation(bridge: AutoMixEngineBridge) {
        #if DEBUG
        let roles = simulatedRoles(count: 64)
        do {
            try bridge.startSimulated(
                withChannelCount: 64,
                sampleRate: 96_000,
                bufferFrameSize: 256,
                channelRoles: roles,
                inputChannelIndices: identityInputMap(count: 64)
            )
            defer { bridge.stop() }

            waitForCallbacks(bridge: bridge, timeout: 5.0)
            let simulatedAllocations = bridge.debugRunRealtimeNoAllocationProbe(
                withFrameCount: 256,
                blocks: 128
            )
            let interleavedInputAllocations = bridge.debugRunRealtimeCoreAudioInputNoAllocationProbe(
                withFrameCount: 256,
                blocks: 128,
                channelsPerBuffer: 64
            )
            let monoInputAllocations = bridge.debugRunRealtimeCoreAudioInputNoAllocationProbe(
                withFrameCount: 256,
                blocks: 128,
                channelsPerBuffer: 1
            )

            print("Realtime no-allocation probe: simulatedRender=\(simulatedAllocations) coreAudioInterleaved=\(interleavedInputAllocations) coreAudioMonoBuffers=\(monoInputAllocations)")
            print("Realtime counters: dropouts=\(bridge.dropoutCount) callbackOverruns=\(bridge.callbackOverrunCount) deadlineMisses=\(bridge.renderDeadlineMissCount)")
            guard simulatedAllocations == 0,
                  interleavedInputAllocations == 0,
                  monoInputAllocations == 0,
                  bridge.dropoutCount == 0,
                  bridge.callbackOverrunCount == 0,
                  bridge.renderDeadlineMissCount == 0
            else {
                Darwin.exit(70)
            }
        } catch {
            print("Realtime no-allocation probe failed: \(error.localizedDescription)")
            Darwin.exit(70)
        }
        #else
        print("Realtime no-allocation probe is only available in DEBUG builds.")
        Darwin.exit(71)
        #endif
    }

    private func runCoreAudioPreflight(bridge: AutoMixEngineBridge) {
        do {
            let options = try coreAudioValidationOptions()
            let result = try performCoreAudioPreflight(bridge: bridge, options: options)
            printPreflightResult(result)
            if !result.artifact.report.isReady {
                Darwin.exit(30)
            }
        } catch {
            print("Core Audio preflight failed: \(error.localizedDescription)")
            Darwin.exit(31)
        }
    }

    private func writeCoreAudioDeviceInventory(bridge: AutoMixEngineBridge) {
        do {
            let profile = loadCLIProfile()
            let selectedInputUID = argumentValue("--input-uid") ?? profile?.inputDeviceUID
            let selectedOutputUID = argumentValue("--output-uid") ?? profile?.outputDeviceUID
            let expectedInputChannels = min(max(intArgument("--expected-inputs") ?? profile?.expectedInputChannels ?? 64, 1), 64)
            let result = try writeCoreAudioDeviceInventoryArtifact(
                bridge: bridge,
                expectedInputChannels: expectedInputChannels,
                selectedInputUID: selectedInputUID,
                selectedOutputUID: selectedOutputUID,
                outputDirectory: try validationOutputDirectory()
            )
            printDeviceInventoryResult(result)
        } catch {
            print("Core Audio device inventory failed: \(error.localizedDescription)")
            Darwin.exit(32)
        }
    }

    private func writeCoreAudioDeviceInventoryArtifact(
        bridge: AutoMixEngineBridge,
        expectedInputChannels: Int,
        selectedInputUID: String?,
        selectedOutputUID: String?,
        outputDirectory: URL
    ) throws -> CoreAudioDeviceInventoryRunResult {
        let inventory = CoreAudioDeviceInventory.make(
            devices: bridge.availableDevices(),
            expectedInputChannels: expectedInputChannels,
            selectedInputUID: selectedInputUID,
            selectedOutputUID: selectedOutputUID
        )
        let url = timestampedURL(
            directory: outputDirectory,
            prefix: "automix-core-audio-device-inventory",
            extension: "json"
        )
        try writeJSON(inventory, to: url)
        return CoreAudioDeviceInventoryRunResult(reportURL: url, inventory: inventory)
    }

    private func printDeviceInventoryResult(_ result: CoreAudioDeviceInventoryRunResult) {
        let inventory = result.inventory
        print("Core Audio device inventory: \(result.reportURL.path)")
        print("Inventory summary: \(inventory.summary)")
        if inventory.selectedInputUID == nil {
            print("Inventory output isolation: pass --input-uid <Dante input UID> to score stream outputs against the selected HD96/Dante route.")
        }
        if inventory.selectedOutputUID == nil {
            print("Inventory proof warning: pass --output-uid <stream output UID>; final full-check verification requires selected input/output UIDs to match the manifest route.")
        }
        if inventory.readyInputUIDs.isEmpty {
            print("Inventory warning: no input device currently looks ready for \(inventory.expectedInputChannels) channels at 96 kHz.")
        }
        if inventory.readyOutputUIDs.isEmpty {
            print("Inventory warning: no output device currently looks ready for isolated stereo stream output at 96 kHz.")
        }
    }

    private func performCoreAudioPreflight(
        bridge: AutoMixEngineBridge,
        options: CoreAudioValidationOptions
    ) throws -> CoreAudioPreflightRunResult {
        let devices = bridge.availableDevices()
        let inputDevice = try coreAudioDevice(uid: options.inputUID, input: true, devices: devices)
        let outputDevice = try coreAudioDevice(uid: options.outputUID, input: false, devices: devices)
        let report = HD96PreflightReport.make(
            inputDevice: inputDevice,
            outputDevice: outputDevice,
            expectedInputChannels: options.expectedInputChannels,
            detectedInputChannels: inputDevice.inputChannels,
            detectedSampleRate: inputDevice.sampleRate,
            channelMappings: options.channelMappings
        )
        let inputSnapshot = snapshot(for: inputDevice)
        let outputSnapshot = snapshot(for: outputDevice)
        let artifact = CoreAudioPreflightProofArtifact(
            generatedAt: Date(),
            inputDevice: inputSnapshot,
            outputDevice: outputSnapshot,
            expectedInputChannels: options.expectedInputChannels,
            detectedInputChannels: inputDevice.inputChannels,
            detectedSampleRate: inputDevice.sampleRate,
            channelMappings: options.channelMappings,
            validationSource: AudioValidationSource.infer(
                inputDevice: inputSnapshot,
                outputDevice: outputSnapshot
            ),
            report: report
        )
        let reportURL = timestampedURL(
            directory: options.outputDirectory,
            prefix: "automix-core-audio-preflight",
            extension: "json"
        )
        try writeJSON(artifact, to: reportURL)
        return CoreAudioPreflightRunResult(reportURL: reportURL, artifact: artifact)
    }

    private func printPreflightResult(_ result: CoreAudioPreflightRunResult) {
        let report = result.artifact.report
        print("Core Audio preflight report: \(result.reportURL.path) ready=\(report.isReady) summary=\"\(report.summary)\" validationSource=\(result.artifact.validationSource.rawValue)")
        if !report.checks.allSatisfy(\.passed) {
            printFailedPreflightChecks(report.checks)
        }
    }

    private func runCoreAudioSoundcheck(bridge: AutoMixEngineBridge) {
        do {
            let options = try coreAudioValidationOptions()
            try ensureCoreAudioPreflightReady(options: options, commandName: "soundcheck")
            guard !requiresAudioInputPermission(for: options) || ensureAudioInputPermission() else {
                print("Core Audio soundcheck failed: audio input permission is not granted.")
                Darwin.exit(10)
            }
            let result = try performCoreAudioSoundcheck(bridge: bridge, options: options)
            printSoundcheckResult(result)
            if !result.report.passed {
                Darwin.exit(12)
            }
        } catch {
            print("Core Audio soundcheck failed: \(error.localizedDescription)")
            Darwin.exit(13)
        }
    }

    private func performCoreAudioSoundcheck(
        bridge: AutoMixEngineBridge,
        options: CoreAudioValidationOptions
    ) throws -> CoreAudioSoundcheckRunResult {
        let devices = bridge.availableDevices()
        let inputDevice = try coreAudioDevice(uid: options.inputUID, input: true, devices: devices)
        let outputDevice = try coreAudioDevice(uid: options.outputUID, input: false, devices: devices)
        let recordingURL = timestampedURL(
            directory: options.outputDirectory,
            prefix: "automix-core-audio-soundcheck",
            extension: "wav"
        )
        try? FileManager.default.removeItem(at: recordingURL)

        try startCoreAudioValidationBridge(bridge, options: options)
        defer { bridge.stop() }

        bridge.setSceneName(options.scene.rawValue)
        bridge.setSafeBypass(true)
        waitForCallbacks(bridge: bridge, timeout: 5.0)

        try bridge.startTestRecording(at: recordingURL, seconds: options.soundcheckSeconds)
        var finalInputLevels: [Double] = []
        var finishedRecording: URL?
        let deadline = Date().addingTimeInterval(max(20.0, options.soundcheckSeconds + 20.0))
        while Date() < deadline {
            finalInputLevels = bridge.inputLevelsDb().map { $0.doubleValue }
            if let finished = bridge.consumeFinishedRecordingURL() {
                finishedRecording = finished
                break
            }
            Thread.sleep(forTimeInterval: 0.025)
        }

        guard let finishedRecording else {
            throw CLIValidationError("recording did not finish recording=\(bridge.recording) frames=\(bridge.recordedFrameCount)/\(bridge.recordingTargetFrameCount) status=\(bridge.status)")
        }

        let inputSnapshot = snapshot(for: bridge.runningInputDeviceInfo() ?? inputDevice)
        let outputSnapshot = snapshot(for: bridge.runningOutputDeviceInfo() ?? outputDevice)
        let reportInput = SoundcheckReportInput(
            recordingURL: finishedRecording,
            expectedRecordingDurationSeconds: options.soundcheckSeconds,
            inputDevice: inputSnapshot,
            outputDevice: outputSnapshot,
            scene: options.scene,
            expectedInputChannels: options.expectedInputChannels,
            detectedInputChannels: bridge.inputChannelCount,
            detectedSampleRate: bridge.sampleRate,
            bufferFrameSize: bridge.bufferFrameSize,
            lastCallbackFrames: bridge.lastCallbackFrameCount,
            maxObservedCallbackFrames: bridge.maxObservedCallbackFrameCount,
            dropoutCount: bridge.dropoutCount,
            callbackOverrunCount: bridge.callbackOverrunCount,
            renderDeadlineMissCount: bridge.renderDeadlineMissCount,
            outputUnderrunCount: bridge.outputUnderrunCount,
            outputOverrunCount: bridge.outputOverrunCount,
            watchdogSafeActive: bridge.watchdogSafeActive,
            safeBypassEnabled: true,
            frozen: false,
            channelMappings: options.channelMappings,
            latestInputLevelsDb: finalInputLevels,
            latestStreamOutputLevelsDb: bridge.outputLevelsDb().map { $0.doubleValue },
            latestMomentaryLufs: bridge.momentaryLufs,
            latestShortTermLufs: bridge.shortTermLufs,
            latestIntegratedLufs: bridge.integratedLufs,
            latestLimiterGainReductionDb: bridge.limiterGainReductionDb
        )
        let report = try SoundcheckReport.make(from: reportInput)
        let reportURL = try report.writeJSON(beside: finishedRecording)
        return CoreAudioSoundcheckRunResult(
            recordingURL: finishedRecording,
            reportURL: reportURL,
            report: report
        )
    }

    private func printSoundcheckResult(_ result: CoreAudioSoundcheckRunResult) {
        print("Core Audio soundcheck recording: \(result.recordingURL.path) bytes=\(result.report.recordingByteCount)")
        print("Core Audio soundcheck report: \(result.reportURL.path) passed=\(result.report.passed) validationSource=\(result.report.validationSource.rawValue)")
        if !result.report.passed {
            printFailedChecks(result.report.checks, prefix: "Soundcheck")
        }
    }

    private func runCoreAudioStability(bridge: AutoMixEngineBridge) {
        do {
            let options = try coreAudioValidationOptions()
            try ensureCoreAudioPreflightReady(options: options, commandName: "stability")
            guard !requiresAudioInputPermission(for: options) || ensureAudioInputPermission() else {
                print("Core Audio stability failed: audio input permission is not granted.")
                Darwin.exit(20)
            }
            let result = try performCoreAudioStability(bridge: bridge, options: options)
            printStabilityResult(result)
            if !result.report.passed {
                Darwin.exit(21)
            }
        } catch {
            print("Core Audio stability failed: \(error.localizedDescription)")
            Darwin.exit(22)
        }
    }

    private func performCoreAudioStability(
        bridge: AutoMixEngineBridge,
        options: CoreAudioValidationOptions
    ) throws -> CoreAudioStabilityRunResult {
        let devices = bridge.availableDevices()
        let inputDevice = try coreAudioDevice(uid: options.inputUID, input: true, devices: devices)
        let outputDevice = try coreAudioDevice(uid: options.outputUID, input: false, devices: devices)
        try startCoreAudioValidationBridge(bridge, options: options)
        defer { bridge.stop() }

        bridge.setSceneName(options.scene.rawValue)
        bridge.setSafeBypass(false)
        bridge.setFrozen(false)
        waitForCallbacks(bridge: bridge, timeout: 5.0)
        let initialOutputLevels = waitForActiveStreamOutput(bridge: bridge, timeout: 5.0)

        let startDropouts = bridge.dropoutCount
        let startCallbackOverruns = bridge.callbackOverrunCount
        let startRenderDeadlineMisses = bridge.renderDeadlineMissCount
        let startOutputUnderruns = bridge.outputUnderrunCount
        let startOutputOverruns = bridge.outputOverrunCount
        var minOutputLevels = initialOutputLevels
        var maxOutputLevels = minOutputLevels
        var maxActiveInputChannelCount = activeInputChannelCount(
            bridge.inputLevelsDb().map { $0.doubleValue },
            channelCount: bridge.inputChannelCount
        )
        var minMomentaryLufs = finiteOrSilence(bridge.momentaryLufs)
        var maxMomentaryLufs = minMomentaryLufs
        var minLimiterGainReductionDb = finiteOrSilence(bridge.limiterGainReductionDb)
        let outputRingTargetFrames = bridge.separateOutputPrebufferFrames
        var minOutputRingFillFrames = bridge.separateOutputRingFillFrames
        var maxOutputRingFillFrames = bridge.separateOutputRingFillFrames
        var maxAbsOutputClockCorrectionPpm = abs(bridge.outputClockCorrectionPpm)

        let startedAt = Date()
        while Date().timeIntervalSince(startedAt) < options.stabilitySeconds {
            let inputLevels = bridge.inputLevelsDb().map { $0.doubleValue }
            let outputLevels = normalizedStereoLevels(bridge.outputLevelsDb().map { $0.doubleValue })
            for index in 0..<2 {
                minOutputLevels[index] = min(minOutputLevels[index], outputLevels[index])
                maxOutputLevels[index] = max(maxOutputLevels[index], outputLevels[index])
            }
            maxActiveInputChannelCount = max(
                maxActiveInputChannelCount,
                activeInputChannelCount(inputLevels, channelCount: bridge.inputChannelCount)
            )
            if bridge.momentaryLufs.isFinite {
                minMomentaryLufs = min(minMomentaryLufs, bridge.momentaryLufs)
                maxMomentaryLufs = max(maxMomentaryLufs, bridge.momentaryLufs)
            }
            if bridge.limiterGainReductionDb.isFinite {
                minLimiterGainReductionDb = min(minLimiterGainReductionDb, bridge.limiterGainReductionDb)
            }
            if outputRingTargetFrames > 0 {
                minOutputRingFillFrames = min(
                    minOutputRingFillFrames,
                    bridge.separateOutputRingFillFrames
                )
                maxOutputRingFillFrames = max(
                    maxOutputRingFillFrames,
                    bridge.separateOutputRingFillFrames
                )
                maxAbsOutputClockCorrectionPpm = max(
                    maxAbsOutputClockCorrectionPpm,
                    abs(bridge.outputClockCorrectionPpm)
                )
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        let observedDurationSeconds = Date().timeIntervalSince(startedAt)
        let dropoutDelta = bridge.dropoutCount >= startDropouts ? bridge.dropoutCount - startDropouts : 0
        let callbackOverrunDelta = bridge.callbackOverrunCount >= startCallbackOverruns ? bridge.callbackOverrunCount - startCallbackOverruns : 0
        let renderDeadlineMissDelta = bridge.renderDeadlineMissCount >= startRenderDeadlineMisses ? bridge.renderDeadlineMissCount - startRenderDeadlineMisses : 0
        let outputUnderrunDelta = bridge.outputUnderrunCount >= startOutputUnderruns ? bridge.outputUnderrunCount - startOutputUnderruns : 0
        let outputOverrunDelta = bridge.outputOverrunCount >= startOutputOverruns ? bridge.outputOverrunCount - startOutputOverruns : 0
        let inputSnapshot = snapshot(for: bridge.runningInputDeviceInfo() ?? inputDevice)
        let outputSnapshot = snapshot(for: bridge.runningOutputDeviceInfo() ?? outputDevice)
        let report = StabilityMonitorReport.make(
            durationSeconds: observedDurationSeconds,
            inputDevice: inputSnapshot,
            outputDevice: outputSnapshot,
            validationSource: AudioValidationSource.infer(
                inputDevice: inputSnapshot,
                outputDevice: outputSnapshot
            ),
            scene: options.scene,
            expectedInputChannels: options.expectedInputChannels,
            detectedInputChannels: bridge.inputChannelCount,
            detectedSampleRate: bridge.sampleRate,
            bufferFrameSize: bridge.bufferFrameSize,
            lastCallbackFrames: bridge.lastCallbackFrameCount,
            maxObservedCallbackFrames: bridge.maxObservedCallbackFrameCount,
            dropoutDelta: dropoutDelta,
            callbackOverrunDelta: callbackOverrunDelta,
            renderDeadlineMissDelta: renderDeadlineMissDelta,
            outputUnderrunDelta: outputUnderrunDelta,
            outputOverrunDelta: outputOverrunDelta,
            outputRingTargetFrames: outputRingTargetFrames,
            minOutputRingFillFrames: minOutputRingFillFrames,
            maxOutputRingFillFrames: maxOutputRingFillFrames,
            maxAbsOutputClockCorrectionPpm: maxAbsOutputClockCorrectionPpm,
            watchdogSafeActive: bridge.watchdogSafeActive,
            safeBypassEnabled: false,
            frozen: false,
            channelMappings: options.channelMappings,
            minStreamOutputLevelsDb: minOutputLevels,
            maxStreamOutputLevelsDb: maxOutputLevels,
            maxActiveInputChannelCount: maxActiveInputChannelCount,
            minMomentaryLufs: minMomentaryLufs,
            maxMomentaryLufs: maxMomentaryLufs,
            minLimiterGainReductionDb: minLimiterGainReductionDb
        )
        let reportURL = timestampedURL(
            directory: options.outputDirectory,
            prefix: "automix-core-audio-stability",
            extension: "json"
        )
        try writeStabilityReport(report, to: reportURL)
        return CoreAudioStabilityRunResult(reportURL: reportURL, report: report)
    }

    private func printStabilityResult(_ result: CoreAudioStabilityRunResult) {
        print(
            String(
                format: "Core Audio stability report: %@ passed=%@ validationSource=%@ duration=%.1fs dropouts=%lu callbackOverruns=%lu deadlineMisses=%lu underruns=%lu outputOverruns=%lu",
                result.reportURL.path,
                result.report.passed ? "true" : "false",
                result.report.validationSource.rawValue,
                result.report.durationSeconds,
                result.report.dropoutDelta,
                result.report.callbackOverrunDelta ?? 0,
                result.report.renderDeadlineMissDelta ?? 0,
                result.report.outputUnderrunDelta,
                result.report.outputOverrunDelta ?? 0
            )
        )
        if !result.report.passed {
            printFailedChecks(result.report.checks, prefix: "Stability")
        }
    }

    private func ensureCoreAudioPreflightReady(
        options: CoreAudioValidationOptions,
        commandName: String
    ) throws {
        let preflight = try performCoreAudioPreflight(bridge: AutoMixEngineBridge(), options: options)
        printPreflightResult(preflight)
        guard preflight.artifact.report.isReady else {
            throw CLIValidationError("\(commandName) preflight not ready: \(preflight.artifact.report.summary)")
        }
    }

    private func runCoreAudioFullCheck() {
        do {
            let options = try coreAudioValidationOptions()
            let manifestURL = timestampedURL(
                directory: options.outputDirectory,
                prefix: "automix-core-audio-full-check",
                extension: "json"
            )
            let inventory = try writeCoreAudioDeviceInventoryArtifact(
                bridge: AutoMixEngineBridge(),
                expectedInputChannels: options.expectedInputChannels,
                selectedInputUID: options.inputUID,
                selectedOutputUID: options.outputUID,
                outputDirectory: options.outputDirectory
            )
            printDeviceInventoryResult(inventory)
            let preflight = try performCoreAudioPreflight(bridge: AutoMixEngineBridge(), options: options)
            printPreflightResult(preflight)

            var manifest = CoreAudioFullCheckManifest(
                validationSource: preflight.artifact.validationSource,
                inputDevice: preflight.artifact.inputDevice,
                outputDevice: preflight.artifact.outputDevice,
                expectedInputChannels: options.expectedInputChannels,
                scene: options.scene,
                soundcheckSeconds: options.soundcheckSeconds,
                stabilitySeconds: options.stabilitySeconds,
                deviceInventoryPath: inventory.reportURL.path,
                preflightReportPath: preflight.reportURL.path,
                preflightReady: preflight.artifact.report.isReady
            )

            guard preflight.artifact.report.isReady else {
                manifest.markFailure("preflight not ready: \(preflight.artifact.report.summary)")
                try writeAndVerifyFullCheckManifest(manifest, to: manifestURL)
                Darwin.exit(41)
            }

            guard !requiresAudioInputPermission(for: options) || ensureAudioInputPermission() else {
                manifest.markFailure("audio input permission is not granted")
                try writeAndVerifyFullCheckManifest(manifest, to: manifestURL)
                print("Core Audio full-check failed: audio input permission is not granted.")
                Darwin.exit(40)
            }

            do {
                let soundcheck = try performCoreAudioSoundcheck(bridge: AutoMixEngineBridge(), options: options)
                printSoundcheckResult(soundcheck)
                manifest.recordSoundcheck(
                    recordingPath: soundcheck.recordingURL.path,
                    reportPath: soundcheck.reportURL.path,
                    passed: soundcheck.report.passed
                )
                guard soundcheck.report.passed else {
                    manifest.markFailure("soundcheck report did not pass")
                    try writeAndVerifyFullCheckManifest(manifest, to: manifestURL)
                    Darwin.exit(42)
                }
            } catch {
                manifest.markFailure("soundcheck failed: \(error.localizedDescription)")
                writeAndVerifyFullCheckManifestIfPossible(manifest, to: manifestURL)
                print("Core Audio full-check failed: \(error.localizedDescription)")
                Darwin.exit(44)
            }

            do {
                let stability = try performCoreAudioStability(bridge: AutoMixEngineBridge(), options: options)
                printStabilityResult(stability)
                manifest.recordStability(
                    reportPath: stability.reportURL.path,
                    passed: stability.report.passed
                )
                guard stability.report.passed else {
                    manifest.markFailure("stability report did not pass")
                    try writeAndVerifyFullCheckManifest(manifest, to: manifestURL)
                    Darwin.exit(43)
                }
            } catch {
                manifest.markFailure("stability failed: \(error.localizedDescription)")
                writeAndVerifyFullCheckManifestIfPossible(manifest, to: manifestURL)
                print("Core Audio full-check failed: \(error.localizedDescription)")
                Darwin.exit(44)
            }

            manifest.recomputePassed()
            let verification = try writeAndVerifyFullCheckManifest(manifest, to: manifestURL)
            guard verification.hardwareProofPassed else {
                Darwin.exit(60)
            }
        } catch {
            print("Core Audio full-check failed: \(error.localizedDescription)")
            Darwin.exit(44)
        }
    }

    private func verifyCoreAudioFullCheckManifest() {
        do {
            let path = argumentValue("--manifest") ?? argumentValue("--full-check-manifest") ?? ""
            guard !path.isEmpty else {
                throw CLIValidationError("Pass --manifest <automix-core-audio-full-check.json> to verify a full-check manifest.")
            }
            let result = try verifyAndPrintFullCheckManifest(at: URL(fileURLWithPath: path))
            guard result.hardwareProofPassed else {
                Darwin.exit(60)
            }
        } catch {
            print("Full-check verification failed: \(error.localizedDescription)")
            Darwin.exit(61)
        }
    }

    @discardableResult
    private func writeAndVerifyFullCheckManifest(
        _ manifest: CoreAudioFullCheckManifest,
        to url: URL
    ) throws -> CoreAudioFullCheckVerificationResult {
        try writeFullCheckManifest(manifest, to: url)
        return try verifyAndPrintFullCheckManifest(at: url)
    }

    private func writeAndVerifyFullCheckManifestIfPossible(
        _ manifest: CoreAudioFullCheckManifest,
        to url: URL
    ) {
        do {
            try writeAndVerifyFullCheckManifest(manifest, to: url)
        } catch {
            print("Core Audio full-check manifest verification failed: \(error.localizedDescription)")
        }
    }

    @discardableResult
    private func verifyAndPrintFullCheckManifest(at url: URL) throws -> CoreAudioFullCheckVerificationResult {
        let result = try CoreAudioFullCheckVerifier.verifyManifest(at: url)
        printFullCheckVerificationResult(result)
        return result
    }

    private func printFullCheckVerificationResult(_ result: CoreAudioFullCheckVerificationResult) {
        print("Full-check verification: \(result.manifestPath)")
        print("Validation passed: \(result.passed)")
        print("Hardware proof passed: \(result.hardwareProofPassed)")
        print("Validation source: \(result.manifest.validationSource.rawValue)")
        print("Summary: \(result.summary)")
        for check in result.artifactChecks {
            print("Artifact \(check.name): \(check.summary) path=\(check.path.isEmpty ? "missing path" : check.path)")
        }
        for check in result.proofChecks {
            print("Proof \(check.name): \(check.passed ? "passed" : "failed") - \(check.summary)")
        }
    }

    private func writeServiceProfile() {
        do {
            let inputUID = argumentValue("--input-uid") ?? ""
            guard !inputUID.isEmpty else {
                throw CLIValidationError("Pass --input-uid <Core Audio UID> when writing a service profile.")
            }
            let devices = AutoMixEngineBridge().availableDevices()
            let selectedInput = devices.first { $0.uid == inputUID }
            guard let outputUID = CoreAudioRouteSelection.resolvedOutputUID(
                explicitOutputUID: argumentValue("--output-uid"),
                profileOutputUID: nil,
                devices: devices,
                selectedInput: selectedInput
            ) else {
                throw CLIValidationError("Pass --output-uid <stream output UID>; no livestream-safe output was auto-detected for the service profile.")
            }
            let expectedInputChannels = min(max(intArgument("--expected-inputs") ?? 64, 1), 64)
            let scene = sceneArgument() ?? .worship
            let profile = VenueProfile.serviceRoleTemplate(
                inputDeviceUID: inputUID,
                outputDeviceUID: outputUID,
                expectedInputChannels: expectedInputChannels,
                scene: scene
            )
            let url = try profileWriteURL()
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try writeJSON(profile, to: url)
            let mapCoverage = ChannelMapCoverage.make(
                channelMappings: profile.channelMappings,
                inputChannelCount: profile.expectedInputChannels
            )
            let roleCoverage = SourceRoleCoverage.make(channelMappings: profile.channelMappings)
            print("Service role profile: \(url.path)")
            print("Profile input UID: \(profile.inputDeviceUID)")
            print("Profile output UID: \(profile.outputDeviceUID)")
            print("Profile expected inputs: \(profile.expectedInputChannels)")
            print("Profile scene: \(profile.scene.rawValue)")
            print("Profile input map: \(mapCoverage.summary)")
            print("Profile source roles: \(roleCoverage.summary)")
        } catch {
            print("Service profile write failed: \(error.localizedDescription)")
            Darwin.exit(50)
        }
    }

    private func simulatedRoles(count: Int) -> [String] {
        let seed = [
            ChannelRole.speech,
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

    private func simulatedMappingsWithManualOverride(count: Int) -> [ChannelMapping] {
        var mappings = simulatedMappings(count: count)
        guard !mappings.isEmpty else { return mappings }
        mappings[0].faderOverrideEnabled = true
        mappings[0].faderDb = -18.0
        mappings[0].panOverrideEnabled = true
        mappings[0].pan = -0.25
        return mappings
    }

    private func identityInputMap(count: Int) -> [NSNumber] {
        (0..<count).map { NSNumber(value: $0) }
    }

    private func normalizedStereoLevels(_ levels: [Double]) -> [Double] {
        Array((levels + [-100.0, -100.0]).prefix(2))
    }

    private func activeInputChannelCount(_ levels: [Double], channelCount: Int) -> Int {
        levels.prefix(max(0, channelCount)).filter { $0 > -90.0 }.count
    }

    private func finiteOrSilence(_ value: Double) -> Double {
        value.isFinite ? value : -100.0
    }

    private struct CoreAudioValidationOptions {
        var inputUID: String
        var outputUID: String
        var expectedInputChannels: Int
        var channelMappings: [ChannelMapping]
        var scene: MixScene
        var soundcheckSeconds: Double
        var stabilitySeconds: Double
        var outputDirectory: URL
    }

    private struct CoreAudioPreflightRunResult {
        var reportURL: URL
        var artifact: CoreAudioPreflightProofArtifact
    }

    private struct CoreAudioDeviceInventoryRunResult {
        var reportURL: URL
        var inventory: CoreAudioDeviceInventory
    }

    private struct CoreAudioSoundcheckRunResult {
        var recordingURL: URL
        var reportURL: URL
        var report: SoundcheckReport
    }

    private struct CoreAudioStabilityRunResult {
        var reportURL: URL
        var report: StabilityMonitorReport
    }

    private func coreAudioValidationOptions() throws -> CoreAudioValidationOptions {
        let profile = loadCLIProfile()
        let inputUID = argumentValue("--input-uid") ?? profile?.inputDeviceUID ?? ""
        guard !inputUID.isEmpty else {
            throw CLIValidationError("Pass --input-uid <Core Audio UID>, or run the UI once so the saved venue profile has an input device UID.")
        }

        let devices = AutoMixEngineBridge().availableDevices()
        let selectedInput = devices.first { $0.uid == inputUID }
        guard let outputUID = CoreAudioRouteSelection.resolvedOutputUID(
            explicitOutputUID: argumentValue("--output-uid"),
            profileOutputUID: profile?.outputDeviceUID,
            devices: devices,
            selectedInput: selectedInput
        ) else {
            throw CLIValidationError("Pass --output-uid <stream output UID>; no livestream-safe Core Audio output was auto-detected.")
        }
        let expectedInputChannels = min(max(intArgument("--expected-inputs") ?? profile?.expectedInputChannels ?? 64, 1), 64)
        let channelMappings = normalizedMappings(
            profile?.channelMappings,
            expectedInputChannels: expectedInputChannels
        )
        let scene = sceneArgument() ?? profile?.scene ?? .worship
        let soundcheckSeconds = min(max(doubleArgument("--soundcheck-seconds") ?? 10.0, 1.0), 30.0)
        let stabilitySeconds = min(max(doubleArgument("--stability-seconds") ?? 300.0, 30.0), 14_400.0)
        let outputDirectory = try validationOutputDirectory()

        return CoreAudioValidationOptions(
            inputUID: inputUID,
            outputUID: outputUID,
            expectedInputChannels: expectedInputChannels,
            channelMappings: channelMappings,
            scene: scene,
            soundcheckSeconds: soundcheckSeconds,
            stabilitySeconds: stabilitySeconds,
            outputDirectory: outputDirectory
        )
    }

    private func startCoreAudioValidationBridge(
        _ bridge: AutoMixEngineBridge,
        options: CoreAudioValidationOptions
    ) throws {
        let mapCoverage = ChannelMapCoverage.make(
            channelMappings: options.channelMappings,
            inputChannelCount: options.expectedInputChannels
        )
        guard mapCoverage.isReady else {
            throw CLIValidationError("Core Audio validation input map is not ready: \(mapCoverage.summary)")
        }
        let orderedMappings = ChannelMapping.orderedForMixerRows(
            options.channelMappings,
            mixerChannelCount: options.expectedInputChannels
        )
        print("Core Audio validation input UID: \(options.inputUID)")
        print("Core Audio validation output UID: \(options.outputUID)")
        print("Core Audio validation expected inputs: \(options.expectedInputChannels)")
        try bridge.start(
            withInputDeviceUID: options.inputUID,
            outputDeviceUID: options.outputUID,
            channelRoles: orderedMappings.map(\.role.rawValue),
            inputChannelIndices: ChannelMapping.inputChannelIndexNumbers(
                for: orderedMappings,
                mixerChannelCount: options.expectedInputChannels,
                maxInputChannels: options.expectedInputChannels
            )
        )
        let manualSummary = CLIManualOverrideApplier.apply(orderedMappings, to: bridge)
        if manualSummary.requestedCount > 0 {
            print("Core Audio validation manual overrides applied: \(manualSummary.appliedCount)/\(manualSummary.requestedCount)")
        }
    }

    private func coreAudioDevice(uid: String, input: Bool, devices: [AMDeviceInfo]) throws -> AMDeviceInfo {
        guard let device = devices.first(where: { $0.uid == uid }) else {
            throw CLIValidationError("Core Audio device UID not found: \(uid). Run --smoke-test to list current device UIDs.")
        }
        if input && device.inputChannels <= 0 {
            throw CLIValidationError("Core Audio input device has no input channels: \(device.name)")
        }
        if !input && device.outputChannels < 2 {
            throw CLIValidationError("Core Audio output device needs at least two output channels: \(device.name)")
        }
        return device
    }

    private func requiresAudioInputPermission(for options: CoreAudioValidationOptions) -> Bool {
        !isSimulatedValidationRoute(options)
    }

    private func isSimulatedValidationRoute(_ options: CoreAudioValidationOptions) -> Bool {
        options.inputUID == "com.livedaw.automix.simulated-hd96-dante"
    }

    private func normalizedMappings(_ mappings: [ChannelMapping]?, expectedInputChannels: Int) -> [ChannelMapping] {
        let source = mappings?.isEmpty == false ? mappings ?? [] : simulatedMappings(count: expectedInputChannels)
        let bounded = Array(source.prefix(expectedInputChannels))
        if bounded.count == expectedInputChannels { return bounded }
        return bounded + (bounded.count..<expectedInputChannels).map { index in
            ChannelMapping(index: index, name: "Ch \(index + 1)", role: .unknown)
        }
    }

    private func loadCLIProfile() -> VenueProfile? {
        let explicitPath = argumentValue("--profile")
        let url: URL
        if let explicitPath, !explicitPath.isEmpty {
            url = URL(fileURLWithPath: explicitPath)
        } else {
            guard let defaultURL = try? defaultProfileURL() else { return nil }
            url = defaultURL
        }
        guard let data = try? Data(contentsOf: url),
              let profile = try? JSONDecoder().decode(VenueProfile.self, from: data)
        else { return nil }
        print("Core Audio validation profile: \(url.path)")
        return profile
    }

    private func profileWriteURL() throws -> URL {
        if let path = argumentValue("--profile"), !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return try defaultProfileURL(createDirectory: true)
    }

    private func defaultProfileURL(createDirectory: Bool = false) throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: createDirectory
        )
        let directory = root.appendingPathComponent("AutoMix Native", isDirectory: true)
        if createDirectory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
            .appendingPathComponent("VenueProfile.json", conformingTo: .json)
    }

    private func validationOutputDirectory() throws -> URL {
        let directory: URL
        if let path = argumentValue("--output-dir"), !path.isEmpty {
            directory = URL(fileURLWithPath: path)
        } else {
            directory = URL(fileURLWithPath: NSTemporaryDirectory())
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func timestampedURL(directory: URL, prefix: String, extension pathExtension: String) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "\(prefix)-\(formatter.string(from: Date())).\(pathExtension)"
        return directory.appendingPathComponent(name)
    }

    @discardableResult
    private func waitForCallbacks(bridge: AutoMixEngineBridge, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if bridge.lastCallbackFrameCount > 0 { return true }
            Thread.sleep(forTimeInterval: 0.025)
        }
        return bridge.lastCallbackFrameCount > 0
    }

    private func waitForActiveStreamOutput(bridge: AutoMixEngineBridge, timeout: TimeInterval) -> [Double] {
        let deadline = Date().addingTimeInterval(timeout)
        var levels = normalizedStereoLevels(bridge.outputLevelsDb().map { $0.doubleValue })
        while Date() < deadline {
            levels = normalizedStereoLevels(bridge.outputLevelsDb().map { $0.doubleValue })
            if levels.allSatisfy({ $0 > -90.0 && $0 < -0.1 }) {
                return levels
            }
            Thread.sleep(forTimeInterval: 0.025)
        }
        return levels
    }

    private func printFailedChecks(_ checks: [SoundcheckCheck], prefix: String) {
        for check in checks where !check.passed {
            print("\(prefix) check failed: \(check.name) expected=\(check.expected) observed=\(check.observed)")
        }
    }

    private func printFailedPreflightChecks(_ checks: [HD96PreflightCheck]) {
        for check in checks where !check.passed {
            let severity = check.blocking ? "blocking" : "note"
            print("Preflight \(severity): \(check.name) expected=\(check.expected) observed=\(check.observed)")
        }
    }

    private func writeFullCheckManifest(_ manifest: CoreAudioFullCheckManifest, to url: URL) throws {
        try writeJSON(manifest, to: url)
        print("Core Audio full-check manifest: \(url.path) passed=\(manifest.passed) hardwareProofPassed=\(manifest.hardwareProofPassed) validationSource=\(manifest.validationSource.rawValue)")
    }

    private func ensureAudioInputPermission() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            let semaphore = DispatchSemaphore(value: 0)
            let result = PermissionResultBox()
            AVCaptureDevice.requestAccess(for: .audio) { allowed in
                result.set(allowed)
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 60.0)
            return result.get()
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func argumentValue(_ name: String) -> String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: name),
              index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    private func intArgument(_ name: String) -> Int? {
        argumentValue(name).flatMap(Int.init)
    }

    private func doubleArgument(_ name: String) -> Double? {
        argumentValue(name).flatMap(Double.init)
    }

    private func sceneArgument() -> MixScene? {
        argumentValue("--scene").flatMap(MixScene.init(rawValue:))
    }

    private struct CLIValidationError: LocalizedError {
        var message: String

        init(_ message: String) {
            self.message = message
        }

        var errorDescription: String? {
            message
        }
    }

    private final class PermissionResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var granted = false

        func set(_ value: Bool) {
            lock.lock()
            granted = value
            lock.unlock()
        }

        func get() -> Bool {
            lock.lock()
            let value = granted
            lock.unlock()
            return value
        }
    }

    private func snapshot(for device: AMDeviceInfo?) -> SoundcheckDeviceSnapshot {
        guard let device else { return .unknown }
        return SoundcheckDeviceSnapshot(
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

    private func writeStabilityReport(_ report: StabilityMonitorReport, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        try writeJSON(report, to: url)
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

}

struct CLIManualOverrideSummary: Equatable, Sendable {
    var requestedCount: Int
    var appliedCount: Int
    var failedMixerChannels: [Int]
}

enum CLIManualOverrideApplier {
    static func apply(_ mappings: [ChannelMapping], to bridge: AutoMixEngineBridge) -> CLIManualOverrideSummary {
        var requestedCount = 0
        var appliedCount = 0
        var failedMixerChannels: [Int] = []

        for mapping in mappings where mapping.hasAnyManualOverride {
            requestedCount += 1
            let applied = bridge.setManualChannelProcessing(
                mapping.makeNativeProcessingOverride(),
                forChannel: mapping.index
            )
            if applied {
                appliedCount += 1
            } else {
                failedMixerChannels.append(mapping.index)
            }
        }

        return CLIManualOverrideSummary(
            requestedCount: requestedCount,
            appliedCount: appliedCount,
            failedMixerChannels: failedMixerChannels
        )
    }
}
