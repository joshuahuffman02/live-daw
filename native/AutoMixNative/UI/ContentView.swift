import SwiftUI

struct ContentView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        VStack(spacing: 0) {
            StatusStrip(model: model)
            Divider()
            HSplitView {
                DeviceControlPanel(model: model)
                    .frame(minWidth: 330, idealWidth: 390, maxWidth: 460)
                ChannelMappingPanel(model: model)
                    .frame(minWidth: 660)
            }
        }
        .frame(minWidth: 1080, minHeight: 700)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct StatusStrip: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(model.isRunning ? Color.green : Color.secondary)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.statusText)
                    .font(.headline)
                    .lineLimit(1)
                if model.runningInRehearsal {
                    Text("REHEARSAL — not broadcast-safe · \(summaryText)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                } else {
                    Text(summaryText)
                        .font(.caption)
                        .foregroundStyle(model.sampleRateState.isWarning || model.channelCountState.isWarning ? .orange : .secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            Toggle(isOn: $model.safeBypass) {
                Label("SAFE", systemImage: "shield.lefthalf.filled")
            }
            .toggleStyle(.switch)

            Toggle(isOn: $model.frozen) {
                Label("FREEZE", systemImage: "snowflake")
            }
            .toggleStyle(.switch)

            Toggle(isOn: $model.shadowMode) {
                Label("SHADOW", systemImage: "eye")
            }
            .toggleStyle(.switch)
            .help("Compute automation candidates without applying measurement-driven gain, gate, level, or master-loudness moves.")

            Toggle(isOn: $model.rehearsalMode) {
                Label("Rehearsal", systemImage: "figure.run")
            }
            .toggleStyle(.switch)
            .disabled(model.isRunning)
            .help("Relax the rate / isolated-output / channel-count gates so you can verify signal flow during a rehearsal. Not broadcast-safe.")

            Button {
                model.refreshDevices()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }

            if model.isRunning {
                Button(role: .destructive) {
                    model.stopEngine()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
            } else {
                Button {
                    model.startEngine()
                } label: {
                    Label(model.rehearsalMode ? "Start (Rehearsal)" : "Start", systemImage: "play.fill")
                }
                .disabled(!model.canStartEngine)
                .help(model.canStartEngine ? "Start Core Audio" : model.engineStartGate.failureMessage)
                .keyboardShortcut(.return, modifiers: [.command])
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var summaryText: String {
        let rate = model.sampleRateState.label
        let ch = model.channelCountState.label
        let buffer = model.detectedBufferFrames > 0 ? "\(model.detectedBufferFrames) frames" : "buffer pending"
        return "\(rate) · \(ch) · \(buffer)"
    }
}

private struct DeviceControlPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox("Core Audio") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Input", selection: $model.selectedInputUID) {
                            ForEach(model.inputDevices, id: \.uid) { device in
                                Text(deviceLabel(device, input: true)).tag(device.uid)
                            }
                        }
                        Picker("Output", selection: $model.selectedOutputUID) {
                            Text("Select livestream output").tag("")
                            ForEach(model.outputDevices, id: \.uid) { device in
                                Text(deviceLabel(device, input: false)).tag(device.uid)
                            }
                        }
                        Text("Use Dante Virtual Soundcard, Dante Via, or an Aggregate Device when input and stream output are split across devices.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                }

                if let bridge = model.monitorBridge {
                    RemoteMonitoringPanel(model: model, bridge: bridge)
                }

                GroupBox("HD96 Preflight") {
                    VStack(alignment: .leading, spacing: 10) {
                        StatusRow(
                            label: "Route",
                            value: model.hd96Preflight.summary,
                            warning: !model.hd96Preflight.isReady
                        )
                        StatusRow(
                            label: "Audio Permission",
                            value: model.audioInputPermission.label,
                            warning: model.audioInputPermission.isWarning
                        )
                        ForEach(model.hd96Preflight.checks) { check in
                            StatusRow(
                                label: check.name,
                                value: check.observed,
                                warning: !check.passed
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }

                GroupBox("Dante Check") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Scene", selection: $model.selectedScene) {
                            ForEach(MixScene.allCases) { scene in
                                Text(scene.label).tag(scene)
                            }
                        }
                        StatusRow(label: "Sample Rate", value: model.sampleRateState.label, warning: model.sampleRateState.isWarning)
                        HStack {
                            Text("Expected Rate")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Picker("", selection: $model.expectedSampleRate) {
                                Text("48 kHz").tag(48000.0)
                                Text("96 kHz").tag(96000.0)
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 150)
                        }
                        .font(.caption)
                        HStack {
                            Text("Expected Channels")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Stepper(value: $model.expectedInputChannels, in: 1...64) {
                                Text("\(model.expectedInputChannels)")
                                    .monospacedDigit()
                                    .frame(width: 28, alignment: .trailing)
                            }
                        }
                        .font(.caption)
                        StatusRow(label: "Input Channels", value: model.channelCountState.label, warning: model.channelCountState.isWarning)
                        StatusRow(label: "Profile Channels", value: "\(model.channelMappings.count)")
                        StatusRow(label: "Input Map", value: model.channelMapCoverage.summary, warning: !model.channelMapCoverage.isReady)
                        StatusRow(label: "Callback Frames", value: callbackFrameSummary)
                        StatusRow(label: "Dropouts", value: "\(model.dropoutCount)", warning: model.dropoutCount > 0)
                        StatusRow(label: "Callback Overruns", value: "\(model.callbackOverrunCount)", warning: model.callbackOverrunCount > 0)
                        StatusRow(label: "Deadline Misses", value: "\(model.renderDeadlineMissCount)", warning: model.renderDeadlineMissCount > 0)
                        StatusRow(label: "Output Underruns", value: "\(model.outputUnderrunCount)", warning: model.outputUnderrunCount > 0)
                        StatusRow(label: "Output Overruns", value: "\(model.outputOverrunCount)", warning: model.outputOverrunCount > 0)
                        StatusRow(label: "Watchdog SAFE", value: model.watchdogSafeActive ? "active" : "inactive", warning: model.watchdogSafeActive)
                        StatusRow(
                            label: "Automation",
                            value: model.shadowMode ? "shadow (candidates only)" : "enabled",
                            warning: model.shadowMode
                        )
                        StatusRow(
                            label: "Master Candidate",
                            value: String(format: "%+.1f dB", model.autoLoudnessTrimDb)
                        )
                        if let error = model.lastError {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 4)
                }

                GroupBox("Stream Mix") {
                    VStack(alignment: .leading, spacing: 10) {
                        StatusRow(label: "Output Level", value: streamLevelSummary, warning: streamLevelWarning)
                        StatusRow(label: "Momentary", value: lufsLabel(model.momentaryLufs), warning: masterLoudnessWarning)
                        StatusRow(label: "Short-Term", value: lufsLabel(model.shortTermLufs), warning: masterLoudnessWarning)
                        StatusRow(label: "Integrated", value: lufsLabel(model.integratedLufs), warning: masterLoudnessWarning)
                        StatusRow(label: "Limiter GR", value: dbLabel(model.limiterGainReductionDb), warning: limiterWarning)
                        StatusRow(
                            label: "DSP Latency",
                            value: String(format: "%.2f ms", model.algorithmicLatencyMs)
                        )
                        StatusRow(
                            label: "Estimated Audio Path",
                            value: String(format: "%.2f ms", model.estimatedOneWayAudioLatencyMs)
                        )
                        HStack {
                            Text("Measured E2E Audio")
                                .foregroundStyle(.secondary)
                            Spacer()
                            TextField(
                                "0 = estimate",
                                value: $model.measuredEndToEndAudioLatencyMs,
                                format: .number.precision(.fractionLength(1))
                            )
                            .frame(width: 86)
                            Text("ms")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        .help("Enter a real clapper/loopback end-to-end measurement. Zero keeps the Core Audio/DSP estimate.")
                        HStack {
                            Text("Measured E2E Video")
                                .foregroundStyle(.secondary)
                            Spacer()
                            TextField(
                                "required",
                                value: $model.measuredEndToEndVideoLatencyMs,
                                format: .number.precision(.fractionLength(1))
                            )
                            .frame(width: 86)
                            Text("ms")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        .help("Enter the measured camera-to-encoder video path latency from the same sync test.")
                        StatusRow(
                            label: "Audio Reference",
                            value: String(format: "%.2f ms", model.lipSyncAudioLatencyReferenceMs),
                            warning: model.measuredEndToEndAudioLatencyMs <= 0
                        )
                        StatusRow(
                            label: "Lip-sync Action",
                            value: model.lipSyncRecommendation,
                            warning: model.measuredEndToEndAudioLatencyMs <= 0 ||
                                model.measuredEndToEndVideoLatencyMs <= 0
                        )
                        StatusRow(label: "Tempo", value: tempoSummary)
                        HStack(spacing: 8) {
                            Text("L")
                                .font(.caption.weight(.semibold))
                                .frame(width: 14, alignment: .trailing)
                            MeterBar(db: streamLevel(at: 0))
                        }
                        HStack(spacing: 8) {
                            Text("R")
                                .font(.caption.weight(.semibold))
                                .frame(width: 14, alignment: .trailing)
                            MeterBar(db: streamLevel(at: 1))
                        }
                    }
                    .padding(.vertical, 4)
                }

                GroupBox("Continuous Capture") {
                    VStack(alignment: .leading, spacing: 12) {
                        if model.continuousRecordingActive {
                            Button(role: .cancel) {
                                model.stopContinuousRecording()
                            } label: {
                                Label("Stop Continuous Recording", systemImage: "stop.circle.fill")
                            }
                        } else {
                            Button {
                                model.startContinuousRecording()
                            } label: {
                                Label("Start Continuous Recording", systemImage: "record.circle.fill")
                            }
                            .disabled(
                                !model.isRunning ||
                                    model.isRecording ||
                                    model.recordingSaveInProgress ||
                                    model.soundcheckReportInProgress
                            )
                        }

                        StatusRow(
                            label: "State",
                            value: model.continuousRecordingActive ? "recording" : "stopped"
                        )
                        StatusRow(
                            label: "Captured",
                            value: continuousRecordingDurationSummary
                        )
                        StatusRow(
                            label: "Segments",
                            value: "\(model.continuousRecordingSegmentCount)"
                        )
                        StatusRow(
                            label: "Dropped Frames",
                            value: "\(model.continuousRecordingDroppedFrameCount)",
                            warning: model.continuousRecordingDroppedFrameCount > 0
                        )

                        if let directory = model.continuousRecordingDirectoryURL {
                            Label(directory.path, systemImage: "folder")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .textSelection(.enabled)
                        } else {
                            Text("Writes raw inputs in Dante channel order plus stream L/R to checkpointed 60-second float WAV segments. Disk I/O never runs on the audio callback.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 4)
                }

                GroupBox("Stability Monitor") {
                    VStack(alignment: .leading, spacing: 12) {
                        Stepper(value: $model.stabilityMonitorDurationSeconds, in: 30...1_800, step: 30) {
                            Text("Duration \(formatDuration(model.stabilityMonitorDurationSeconds))")
                        }
                        .font(.caption)
                        .disabled(model.stabilityMonitorActive)

                        if model.stabilityMonitorActive {
                            Button(role: .cancel) {
                                model.cancelStabilityMonitor()
                            } label: {
                                Label("Cancel Monitor", systemImage: "xmark.circle")
                            }
                        } else {
                            Button {
                                model.startStabilityMonitor()
                            } label: {
                                Label("Run Stability Monitor", systemImage: "timer")
                            }
                            .disabled(!model.canStartStabilityMonitor)
                        }

                        if model.stabilityMonitorWaitingForStream {
                            StatusRow(
                                label: "Warm-up",
                                value: "waiting for stream L/R · \(formatDuration(model.stabilityWarmupElapsedSeconds))",
                                warning: true
                            )
                        }

                        StatusRow(label: "Elapsed", value: stabilityElapsedSummary)
                        StatusRow(label: "Active Inputs", value: "\(model.stabilityMaxActiveInputChannelCount) max", warning: model.stabilityMonitorActive && !model.stabilityMonitorWaitingForStream && model.stabilityMaxActiveInputChannelCount == 0)
                        StatusRow(label: "Dropout Delta", value: "\(model.stabilityDropoutDelta)", warning: model.stabilityDropoutDelta > 0)
                        StatusRow(label: "Callback Overrun Delta", value: "\(model.stabilityCallbackOverrunDelta)", warning: model.stabilityCallbackOverrunDelta > 0)
                        StatusRow(label: "Deadline Miss Delta", value: "\(model.stabilityRenderDeadlineMissDelta)", warning: model.stabilityRenderDeadlineMissDelta > 0)
                        StatusRow(label: "Output Underrun Delta", value: "\(model.stabilityOutputUnderrunDelta)", warning: model.stabilityOutputUnderrunDelta > 0)
                        StatusRow(label: "Output Overrun Delta", value: "\(model.stabilityOutputOverrunDelta)", warning: model.stabilityOutputOverrunDelta > 0)
                        StatusRow(label: "Min Stream", value: stabilityMinSummary, warning: stabilityLevelWarning)
                        StatusRow(label: "Max Stream", value: stabilityMaxSummary, warning: stabilityLevelWarning)
                        StatusRow(label: "Momentary Range", value: stabilityLoudnessSummary, warning: stabilityLoudnessWarning)
                        StatusRow(label: "Max Limiter GR", value: dbLabel(model.stabilityMinLimiterGainReductionDb), warning: model.stabilityMinLimiterGainReductionDb <= -12.0)

                        if let report = model.lastStabilityReport {
                            Label(report.summary, systemImage: report.passed ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(report.passed ? .green : .orange)
                            StatusRow(
                                label: "Validation Source",
                                value: report.validationSource.label,
                                warning: report.validationSource == .simulatedHD96Dante
                            )
                        }

                        if let url = model.finishedStabilityReportURL {
                            Label(url.lastPathComponent, systemImage: "doc.text.magnifyingglass")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.vertical, 4)
                }

                GroupBox("Soundcheck") {
                    VStack(alignment: .leading, spacing: 12) {
                        Button {
                            model.startTestRecording(seconds: 10)
                        } label: {
                            Label(soundcheckButtonTitle, systemImage: "record.circle")
                        }
                        .disabled(!model.canStartSoundcheck)

                        if model.isRecording {
                            StatusRow(label: "Recording Frames", value: recordingFrameSummary)
                        }

                        if model.recordingSaveInProgress {
                            StatusRow(label: "File", value: "saving WAV")
                        }

                        if model.soundcheckReportInProgress {
                            StatusRow(label: "Report", value: "scanning WAV payload")
                        }

                        if let url = model.finishedRecordingURL {
                            Label(url.lastPathComponent, systemImage: "waveform")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        } else {
                            Text("Enables SAFE and records every active Dante input plus the stereo stream mix to an IEEE-float WAV after the engine is running.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if let report = model.lastSoundcheckReport {
                            Label(report.summary, systemImage: report.passed ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(report.passed ? .green : .orange)
                            StatusRow(
                                label: "Validation Source",
                                value: report.validationSource.label,
                                warning: report.validationSource == .simulatedHD96Dante
                            )
                            StatusRow(
                                label: "Recorded Inputs",
                                value: recordedInputSummary(report)
                            )
                            ForEach(report.checks) { check in
                                StatusRow(label: check.name, value: check.observed, warning: !check.passed)
                            }
                        }

                        if let url = model.finishedReportURL {
                            Label(url.lastPathComponent, systemImage: "doc.text.magnifyingglass")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.vertical, 4)
                }

                GroupBox("Hardware Proof") {
                    VStack(alignment: .leading, spacing: 12) {
                        Button {
                            model.saveFullCheckManifest()
                        } label: {
                            Label("Save Proof Manifest", systemImage: "doc.badge.plus")
                        }
                        .disabled(!model.canSaveFullCheckManifest)

                        if let verification = model.lastFullCheckVerification {
                            Label(
                                verification.hardwareProofPassed ? "HD96/Dante hardware proof verified" : verification.summary,
                                systemImage: verification.hardwareProofPassed ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
                            )
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(verification.hardwareProofPassed ? .green : .orange)

                            StatusRow(
                                label: "Validation Source",
                                value: verification.manifest.validationSource.label,
                                warning: verification.manifest.validationSource == .simulatedHD96Dante
                            )
                            StatusRow(
                                label: "Verification",
                                value: verification.passed ? "passed" : "failed",
                                warning: !verification.passed
                            )
                            StatusRow(
                                label: "Hardware Proof",
                                value: verification.hardwareProofPassed ? "verified" : "not yet",
                                warning: !verification.hardwareProofPassed
                            )
                            StatusRow(
                                label: "Inventory",
                                value: verification.manifest.deviceInventoryPath == nil ? "missing" : "saved",
                                warning: verification.manifest.deviceInventoryPath == nil
                            )
                            StatusRow(label: "Preflight", value: verification.manifest.preflightReady ? "ready" : "not ready", warning: !verification.manifest.preflightReady)
                            StatusRow(label: "Soundcheck", value: passFailLabel(verification.manifest.soundcheckPassed), warning: verification.manifest.soundcheckPassed != true)
                            StatusRow(label: "Stability", value: passFailLabel(verification.manifest.stabilityPassed), warning: verification.manifest.stabilityPassed != true)
                            ForEach(verification.proofChecks) { check in
                                StatusRow(label: check.name, value: check.summary, warning: !check.passed)
                            }
                        } else if let manifest = model.lastFullCheckManifest {
                            Label(
                                manifest.hardwareProofSummary,
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                        }

                        if let inventory = model.lastDeviceInventory {
                            StatusRow(
                                label: "Device Inventory",
                                value: inventory.summary,
                                warning: inventory.readyInputUIDs.isEmpty || inventory.readyOutputUIDs.isEmpty
                            )
                        }

                        if let url = model.finishedDeviceInventoryURL {
                            Label(url.lastPathComponent, systemImage: "doc.text.magnifyingglass")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        if let url = model.finishedFullCheckManifestURL {
                            Label(url.lastPathComponent, systemImage: "doc.text.magnifyingglass")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(18)
        }
    }

    private func recordedInputSummary(_ report: SoundcheckReport) -> String {
        let channels = report.recordedActiveInputChannels
        guard !channels.isEmpty else {
            return "\(report.recordedActiveInputChannelCount) active"
        }

        let visibleChannels = channels.prefix(12).map(String.init).joined(separator: ", ")
        let suffix = channels.count > 12 ? ", +\(channels.count - 12)" : ""
        return "\(channels.count) active (\(visibleChannels)\(suffix))"
    }

    private var callbackFrameSummary: String {
        if model.lastCallbackFrames <= 0 {
            return model.detectedBufferFrames > 0 ? "waiting / max \(model.detectedBufferFrames)" : "waiting"
        }
        return "\(model.lastCallbackFrames) last / \(model.maxObservedCallbackFrames) max"
    }

    private var recordingFrameSummary: String {
        guard model.recordingTargetFrameCount > 0 else { return "starting" }
        return "\(model.recordedFrameCount) / \(model.recordingTargetFrameCount)"
    }

    private var continuousRecordingDurationSummary: String {
        guard model.detectedSampleRate > 0 else {
            return "\(model.continuousRecordingFrameCount) frames"
        }
        let seconds = Double(model.continuousRecordingFrameCount) / model.detectedSampleRate
        return "\(formatDuration(seconds)) · \(model.continuousRecordingFrameCount) frames"
    }

    private var soundcheckButtonTitle: String {
        if model.isRecording { return "Recording..." }
        if model.recordingSaveInProgress { return "Saving..." }
        if model.soundcheckReportInProgress { return "Analyzing..." }
        return "Record 10s Test"
    }

    private var streamLevelSummary: String {
        "L \(dbLabel(streamLevel(at: 0))) / R \(dbLabel(streamLevel(at: 1)))"
    }

    private var tempoSummary: String {
        guard model.isRunning, model.bpm >= 60 else { return "—" }
        let lock = model.bpmConfidence > 0.4 ? "locked" : "searching"
        return "\(Int(model.bpm.rounded())) BPM · \(lock)"
    }

    private var streamLevelWarning: Bool {
        model.isRunning && (streamLevel(at: 0) <= -90.0 || streamLevel(at: 1) <= -90.0 || streamLevel(at: 0) >= -0.1 || streamLevel(at: 1) >= -0.1)
    }

    private var masterLoudnessWarning: Bool {
        model.isRunning && (!model.momentaryLufs.isFinite || model.momentaryLufs <= -99.0)
    }

    private var limiterWarning: Bool {
        model.isRunning && (!model.limiterGainReductionDb.isFinite || model.limiterGainReductionDb <= -12.0)
    }

    private var stabilityElapsedSummary: String {
        if model.stabilityMonitorWaitingForStream {
            return "waiting / \(formatDuration(model.stabilityMonitorDurationSeconds))"
        }
        return "\(formatDuration(model.stabilityElapsedSeconds)) / \(formatDuration(model.stabilityMonitorDurationSeconds))"
    }

    private var stabilityMinSummary: String {
        "L \(dbLabel(stabilityMinLevel(at: 0))) / R \(dbLabel(stabilityMinLevel(at: 1)))"
    }

    private var stabilityMaxSummary: String {
        "L \(dbLabel(stabilityMaxLevel(at: 0))) / R \(dbLabel(stabilityMaxLevel(at: 1)))"
    }

    private var stabilityLoudnessSummary: String {
        "\(lufsLabel(model.stabilityMinMomentaryLufs)) to \(lufsLabel(model.stabilityMaxMomentaryLufs))"
    }

    private var stabilityLevelWarning: Bool {
        model.stabilityMonitorActive &&
            !model.stabilityMonitorWaitingForStream &&
            (stabilityMinLevel(at: 0) <= -90.0 ||
             stabilityMinLevel(at: 1) <= -90.0 ||
             stabilityMaxLevel(at: 0) >= -0.1 ||
             stabilityMaxLevel(at: 1) >= -0.1)
    }

    private var stabilityLoudnessWarning: Bool {
        model.stabilityMonitorActive &&
            !model.stabilityMonitorWaitingForStream &&
            (!model.stabilityMaxMomentaryLufs.isFinite || model.stabilityMaxMomentaryLufs <= -99.0)
    }

    private func streamLevel(at index: Int) -> Double {
        model.streamOutputLevelsDb.indices.contains(index) ? model.streamOutputLevelsDb[index] : -100.0
    }

    private func stabilityMinLevel(at index: Int) -> Double {
        model.stabilityMinStreamOutputLevelsDb.indices.contains(index) ? model.stabilityMinStreamOutputLevelsDb[index] : -100.0
    }

    private func stabilityMaxLevel(at index: Int) -> Double {
        model.stabilityMaxStreamOutputLevelsDb.indices.contains(index) ? model.stabilityMaxStreamOutputLevelsDb[index] : -100.0
    }

    private func dbLabel(_ value: Double) -> String {
        value <= -99 ? "-inf dB" : String(format: "%.1f dB", value)
    }

    private func lufsLabel(_ value: Double) -> String {
        value <= -99 ? "-inf LUFS" : String(format: "%.1f LUFS", value)
    }

    private func passFailLabel(_ value: Bool?) -> String {
        switch value {
        case true:
            return "passed"
        case false:
            return "failed"
        case nil:
            return "pending"
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let minutes = total / 60
        let remainder = total % 60
        return minutes > 0 ? "\(minutes)m \(remainder)s" : "\(remainder)s"
    }

    private func deviceLabel(_ device: AMDeviceInfo, input: Bool) -> String {
        let channels = input ? device.inputChannels : device.outputChannels
        let direction = input ? "in" : "out"
        let rate = device.sampleRate > 0 ? "\(Int(device.sampleRate.rounded())) Hz" : "rate unknown"
        let supported = input ? device.inputFormatSupported : device.outputFormatSupported
        let format = supported ? "format OK" : "unsupported format"
        return "\(device.name) · \(channels) \(direction) · \(rate) · \(format)"
    }
}

private struct StatusRow: View {
    let label: String
    let value: String
    var warning = false

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .foregroundStyle(warning ? .orange : .primary)
                .multilineTextAlignment(.trailing)
        }
        .font(.caption)
    }
}

private struct ChannelMappingPanel: View {
    @ObservedObject var model: AppModel
    @State private var expandedIndex: Int?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Channel Map", systemImage: "slider.horizontal.3")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text("Tap a channel to edit · Dante in → mix ch → role")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    model.applyServiceRoleTemplate()
                } label: {
                    Label("Service Roles", systemImage: "wand.and.stars")
                }
                .help("Apply starter service source roles")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ChannelHeaderRow()
                    ForEach($model.channelMappings) { $channel in
                        ChannelRow(
                            channel: $channel,
                            inputChannelLimit: inputChannelLimit,
                            levelDb: model.levelsDb.indices.contains(channel.index) ? model.levelsDb[channel.index] : -100.0,
                            autoTrimDb: model.autoTrimDb.indices.contains(channel.index) ? model.autoTrimDb[channel.index] : 0.0,
                            autoFaderDb: model.autoFaderDb.indices.contains(channel.index) ? model.autoFaderDb[channel.index] : -6.0,
                            noiseFloorDb: model.learnedNoiseFloorDb.indices.contains(channel.index) ? model.learnedNoiseFloorDb[channel.index] : -60.0,
                            autoActive: model.autoChannelActive.indices.contains(channel.index) ? model.autoChannelActive[channel.index] : false,
                            shadowMode: model.shadowMode,
                            isExpanded: expandedIndex == channel.index,
                            onToggleExpand: {
                                expandedIndex = (expandedIndex == channel.index) ? nil : channel.index
                            }
                        )
                        .onChange(of: channel) { _, _ in
                            model.channelDidChange(channel)
                        }
                        Divider()
                    }
                }
            }
        }
    }

    private var inputChannelLimit: Int {
        min(max(model.detectedInputChannels, model.expectedInputChannels, model.channelMappings.count, 1), 64)
    }
}

private struct ChannelHeaderRow: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("In").frame(width: 40, alignment: .leading)
            Text("Ch").frame(width: 34, alignment: .trailing)
            Text("Name").frame(width: 128, alignment: .leading)
            Text("Role").frame(width: 112, alignment: .leading)
            Text("Input Level").frame(maxWidth: .infinity, alignment: .leading)
            Text("Mute").frame(width: 58, alignment: .center)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct ChannelRow: View {
    @Binding var channel: ChannelMapping
    let inputChannelLimit: Int
    let levelDb: Double
    let autoTrimDb: Double
    let autoFaderDb: Double
    let noiseFloorDb: Double
    let autoActive: Bool
    let shadowMode: Bool
    let isExpanded: Bool
    let onToggleExpand: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            summary
            if isExpanded { editor }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
        .background(isExpanded ? Color(nsColor: .controlBackgroundColor).opacity(0.5) : Color.clear)
    }

    // Lightweight, always-visible summary — pure text + a cheap meter so 64 rows scroll
    // freely. The heavy editing controls live in `editor`, shown only when expanded.
    private var summary: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                Text("\(channel.boundedInputChannelIndex(maxInputChannels: inputChannelLimit) + 1)")
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 40, alignment: .leading)
                Text("\(channel.index + 1)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
                Text(channel.name)
                    .frame(width: 128, alignment: .leading)
                    .lineLimit(1)
                Text(channel.role.label)
                    .foregroundStyle(.secondary)
                    .frame(width: 112, alignment: .leading)
                    .lineLimit(1)
                MeterBar(db: levelDb)
                    .frame(maxWidth: .infinity)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 14)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggleExpand)

            Button {
                channel.setMuted(!channel.muted)
            } label: {
                Image(systemName: channel.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(channel.muted ? .red : .secondary)
            }
            .buttonStyle(.borderless)
            .frame(width: 40, alignment: .center)
            .help(channel.muted ? "Unmute" : "Mute")
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Stepper(value: inputChannelBinding, in: 0...max(inputChannelLimit - 1, 0)) {
                    Text("Dante In \(channel.boundedInputChannelIndex(maxInputChannels: inputChannelLimit) + 1)")
                        .font(.caption)
                }
                TextField("Channel", text: $channel.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                Picker("Role", selection: $channel.role) {
                    ForEach(ChannelRole.allCases) { role in
                        Text(role.label).tag(role)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
            }
            HStack(spacing: 12) {
                Text(shadowMode ? "Candidate" : "Automation")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(shadowMode ? .orange : .secondary)
                Text(autoActive ? "active" : "idle")
                Text(String(format: "trim %+.1f dB", autoTrimDb))
                Text(String(format: "fader %+.1f dB", autoFaderDb))
                Text(String(format: "floor %.1f dBFS", noiseFloorDb))
            }
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            ManualOverrideControls(channel: $channel)
                .frame(maxWidth: 380, alignment: .leading)
        }
        .padding(.leading, 4)
        .padding(.bottom, 4)
    }

    private var inputChannelBinding: Binding<Int> {
        Binding(
            get: { channel.boundedInputChannelIndex(maxInputChannels: inputChannelLimit) },
            set: { channel.inputChannelIndex = $0 }
        )
    }
}

private struct ManualOverrideControls: View {
    @Binding var channel: ChannelMapping

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Toggle("Fader", isOn: $channel.faderOverrideEnabled)
                    .toggleStyle(.checkbox)
                    .frame(width: 72, alignment: .leading)
                Slider(value: $channel.faderDb, in: ChannelMapping.faderDbOverrideRange, step: 0.5)
                    .disabled(!channel.faderOverrideEnabled)
                Text(String(format: "%.1f", channel.faderDb))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(channel.faderOverrideEnabled ? .primary : .secondary)
                    .frame(width: 42, alignment: .trailing)
            }

            HStack(spacing: 8) {
                Toggle("Pan", isOn: $channel.panOverrideEnabled)
                    .toggleStyle(.checkbox)
                    .frame(width: 72, alignment: .leading)
                Slider(value: $channel.pan, in: ChannelMapping.panOverrideRange, step: 0.05)
                    .disabled(!channel.panOverrideEnabled)
                Text(String(format: "%.2f", channel.pan))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(channel.panOverrideEnabled ? .primary : .secondary)
                    .frame(width: 42, alignment: .trailing)
            }
        }
    }
}

private struct MeterBar: View {
    let db: Double

    var body: some View {
        HStack(spacing: 8) {
            // ProgressView is GPU-composited and needs no GeometryReader/layout pass,
            // so 64 of these scroll cheaply.
            ProgressView(value: normalized)
                .progressViewStyle(.linear)
                .tint(fillColor)
                .animation(nil, value: normalized)

            Text(dbLabel)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .trailing)
        }
    }

    private var normalized: Double {
        min(max((db + 80.0) / 80.0, 0.0), 1.0)
    }

    private var fillColor: Color {
        if db > -6 { return .red }
        if db > -18 { return .yellow }
        return .green
    }

    private var dbLabel: String {
        db <= -99 ? "-∞ dB" : String(format: "%.1f dB", db)
    }
}

#Preview {
    ContentView()
}
