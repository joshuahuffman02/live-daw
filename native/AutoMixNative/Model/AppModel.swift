import AVFoundation
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var devices: [AMDeviceInfo] = []
    @Published var selectedInputUID = "" {
        didSet {
            selectedOutputUID = CoreAudioRouteSelection.validatedOutputUID(
                currentOutputUID: selectedOutputUID,
                devices: devices,
                selectedInput: selectedInputDevice
            )
            if selectedOutputUID.isEmpty {
                selectedOutputUID = CoreAudioRouteSelection.preferredOutputDevice(
                    from: devices,
                    selectedInput: selectedInputDevice
                )?.uid ?? ""
            }
            syncChannelCountFromSelectedInput()
            invalidateValidationEvidence()
            saveProfile()
        }
    }
    @Published var selectedOutputUID = "" {
        didSet {
            invalidateValidationEvidence()
            saveProfile()
        }
    }
    @Published var selectedScene: MixScene = .worship {
        didSet {
            engine.setSceneName(selectedScene.rawValue)
            invalidateValidationEvidence()
            saveProfile()
        }
    }
    @Published var expectedInputChannels = 64 {
        didSet {
            let clamped = min(max(expectedInputChannels, 1), 64)
            if expectedInputChannels != clamped {
                expectedInputChannels = clamped
                return
            }
            invalidateValidationEvidence()
            saveProfile()
        }
    }
    @Published var expectedSampleRate: Double = 48000 {
        didSet {
            let clamped = BroadcastSampleRate.nearestSupported(expectedSampleRate)
            if expectedSampleRate != clamped {
                expectedSampleRate = clamped
                return
            }
            invalidateValidationEvidence()
            saveProfile()
        }
    }
    @Published var measuredEndToEndAudioLatencyMs = 0.0 {
        didSet {
            let clamped = min(max(measuredEndToEndAudioLatencyMs, 0), 1_000)
            if measuredEndToEndAudioLatencyMs != clamped {
                measuredEndToEndAudioLatencyMs = clamped
                return
            }
            invalidateValidationEvidence()
            saveProfile()
        }
    }
    @Published var measuredEndToEndVideoLatencyMs = 0.0 {
        didSet {
            let clamped = min(max(measuredEndToEndVideoLatencyMs, 0), 1_000)
            if measuredEndToEndVideoLatencyMs != clamped {
                measuredEndToEndVideoLatencyMs = clamped
                return
            }
            invalidateValidationEvidence()
            saveProfile()
        }
    }
    @Published var channelMappings = ChannelMapping.defaults(count: 32) {
        didSet {
            invalidateValidationEvidence()
            saveProfile()
        }
    }
    @Published private(set) var levelsDb: [Double] = Array(repeating: -100.0, count: 32)
    @Published private(set) var streamOutputLevelsDb: [Double] = [-100.0, -100.0]
    @Published private(set) var momentaryLufs = -100.0
    @Published private(set) var shortTermLufs = -100.0
    @Published private(set) var integratedLufs = -100.0
    @Published private(set) var limiterGainReductionDb = 0.0
    @Published private(set) var bpm = 0.0
    @Published private(set) var bpmConfidence = 0.0
    @Published private(set) var autoLoudnessTrimDb = 0.0
    @Published private(set) var autoTrimDb: [Double] = Array(repeating: 0.0, count: 32)
    @Published private(set) var autoFaderDb: [Double] = Array(repeating: -6.0, count: 32)
    @Published private(set) var learnedNoiseFloorDb: [Double] = Array(repeating: -60.0, count: 32)
    @Published private(set) var autoChannelActive: [Bool] = Array(repeating: false, count: 32)
    @Published private(set) var audioInputPermission: AudioInputPermissionState = .unknown
    @Published private(set) var statusText = "Idle"
    @Published private(set) var lastError: String?
    @Published private(set) var finishedRecordingURL: URL?
    @Published private(set) var finishedReportURL: URL?
    @Published private(set) var lastSoundcheckReport: SoundcheckReport?
    @Published private(set) var soundcheckReportInProgress = false
    @Published private(set) var finishedDeviceInventoryURL: URL?
    @Published private(set) var lastDeviceInventory: CoreAudioDeviceInventory?
    @Published private(set) var finishedStabilityReportURL: URL?
    @Published private(set) var lastStabilityReport: StabilityMonitorReport?
    @Published private(set) var finishedFullCheckManifestURL: URL?
    @Published private(set) var lastFullCheckManifest: CoreAudioFullCheckManifest?
    @Published private(set) var lastFullCheckVerification: CoreAudioFullCheckVerificationResult?
    @Published private(set) var dropoutCount: UInt = 0
    @Published private(set) var callbackOverrunCount: UInt = 0
    @Published private(set) var renderDeadlineMissCount: UInt = 0
    @Published private(set) var outputUnderrunCount: UInt = 0
    @Published private(set) var outputOverrunCount: UInt = 0
    @Published private(set) var separateOutputRingFillFrames = 0
    @Published private(set) var outputClockCorrectionPpm = 0.0
    @Published private(set) var inputCallbackAgeMs = -1.0
    @Published private(set) var outputCallbackAgeMs = -1.0
    @Published private(set) var watchdogSafeActive = false
    @Published private(set) var recordingSaveInProgress = false
    @Published private(set) var recordedFrameCount: UInt = 0
    @Published private(set) var recordingTargetFrameCount: UInt = 0
    @Published private(set) var continuousRecordingActive = false
    @Published private(set) var continuousRecordingFrameCount: UInt = 0
    @Published private(set) var continuousRecordingDroppedFrameCount: UInt = 0
    @Published private(set) var continuousRecordingSegmentCount: UInt = 0
    @Published private(set) var continuousRecordingDirectoryURL: URL?
    @Published var automaticRecoveryEnabled = true {
        didSet { applyAutomaticRecoveryState() }
    }
    @Published private(set) var automaticRecoveryStatus = "disarmed"
    @Published private(set) var automaticRecoveryAttemptCount = 0
    @Published private(set) var lastRuntimeIncident: String?
    @Published private(set) var incidentLogURL: URL?
    @Published var encoderHealthURL = "" {
        didSet {
            resetStreamHealthMonitoring()
            saveProfile()
        }
    }
    @Published var egressHealthURL = "" {
        didSet {
            resetStreamHealthMonitoring()
            saveProfile()
        }
    }
    @Published private(set) var encoderHealth: StreamEndpointHealth = .disabled
    @Published private(set) var egressHealth: StreamEndpointHealth = .disabled
    @Published var stabilityMonitorDurationSeconds = 300.0 {
        didSet {
            let clamped = min(max(stabilityMonitorDurationSeconds, 30.0), 1_800.0)
            if stabilityMonitorDurationSeconds != clamped {
                stabilityMonitorDurationSeconds = clamped
            }
        }
    }
    @Published private(set) var stabilityMonitorActive = false
    @Published private(set) var stabilityMonitorWaitingForStream = false
    @Published private(set) var stabilityWarmupElapsedSeconds = 0.0
    @Published private(set) var stabilityElapsedSeconds = 0.0
    @Published private(set) var stabilityDropoutDelta: UInt = 0
    @Published private(set) var stabilityCallbackOverrunDelta: UInt = 0
    @Published private(set) var stabilityRenderDeadlineMissDelta: UInt = 0
    @Published private(set) var stabilityOutputUnderrunDelta: UInt = 0
    @Published private(set) var stabilityOutputOverrunDelta: UInt = 0
    @Published private(set) var stabilityOutputRingTargetFrames = 0
    @Published private(set) var stabilityMinOutputRingFillFrames = 0
    @Published private(set) var stabilityMaxOutputRingFillFrames = 0
    @Published private(set) var stabilityMaxAbsOutputClockCorrectionPpm = 0.0
    @Published private(set) var stabilityMinStreamOutputLevelsDb: [Double] = [-100.0, -100.0]
    @Published private(set) var stabilityMaxStreamOutputLevelsDb: [Double] = [-100.0, -100.0]
    @Published private(set) var stabilityMaxActiveInputChannelCount = 0
    @Published private(set) var stabilityMinMomentaryLufs = -100.0
    @Published private(set) var stabilityMaxMomentaryLufs = -100.0
    @Published private(set) var stabilityMinLimiterGainReductionDb = 0.0
    @Published private(set) var lastCallbackFrames: Int = 0
    @Published private(set) var maxObservedCallbackFrames: Int = 0
    @Published var safeBypass = false {
        didSet {
            engine.setSafeBypass(safeBypass)
            if oldValue != safeBypass {
                cancelActiveStabilityMonitorForProofControlChange("SAFE")
            }
        }
    }
    @Published var frozen = false {
        didSet {
            engine.setFrozen(frozen)
            if oldValue != frozen {
                cancelActiveStabilityMonitorForProofControlChange("FREEZE")
            }
        }
    }
    @Published var shadowMode = true {
        didSet {
            engine.setShadowMode(shadowMode)
            if oldValue != shadowMode {
                cancelActiveStabilityMonitorForProofControlChange("SHADOW")
                invalidateValidationEvidence()
                saveProfile()
            }
        }
    }

    private let engine = AutoMixEngineBridge()
    private var meterTimer: Timer?
    private var soundcheckReportTask: Task<Void, Never>?
    private var loadingProfile = false
    private var pendingSoundcheckDurationSeconds = 10.0
    private var pendingSoundcheckProofControls: SoundcheckProofControlSnapshot?
    private var stabilityStartedAt: Date?
    private var stabilityWarmupStartedAt: Date?
    private let stabilityWarmupTimeoutSeconds = 5.0
    private var stabilityStartDropouts: UInt = 0
    private var stabilityStartCallbackOverruns: UInt = 0
    private var stabilityStartRenderDeadlineMisses: UInt = 0
    private var stabilityStartOutputUnderruns: UInt = 0
    private var stabilityStartOutputOverruns: UInt = 0
    private var runningRouteSnapshot: CoreAudioRouteSnapshot?
    private let profileDirectoryOverride: URL?
    private var runtimeRecoveryCoordinator = RuntimeRecoveryCoordinator()
    private var automaticRecoveryArmed = false
    private var recoveryInFlight = false
    private var incidentJournal: RuntimeIncidentJournal?
    private var incidentWriteTask: Task<Void, Never>?
    private var continuousRecordingRequested = false
    private let streamHealthProbe = StreamHealthProbe()
    private var streamHealthTask: Task<Void, Never>?
    private var nextStreamHealthProbeMs: Int64 = 0
    private var resumingAutonomousSession = false
    private var previousRecordingDroppedFrameCount: UInt = 0
    private var previousOutputClockWarning = false
    private var previousWatchdogSafeActive = false
    private var previousRuntimeRouteHealthy = true

    // Rehearsal/monitor mode: relaxes the broadcast go-live gates so the operator can
    // verify signal flow before the rig is fully configured. Not broadcast-safe.
    @Published var rehearsalMode = false
    private(set) var runningInRehearsal = false

    // Remote operator console (same-Wi-Fi monitoring + control).
    private(set) var operatorStoppedEngine = false
    private(set) var monitorBridge: MonitorBridge?
    @Published var remoteMonitoringEnabled = true {
        didSet { applyRemoteMonitoringState() }
    }

    init(profileDirectory: URL? = nil, autoStartRemoteMonitoring: Bool = true) {
        self.profileDirectoryOverride = profileDirectory
        loadProfile()
        refreshDevices()
        refreshAudioInputPermission()
        startPolling()
        monitorBridge = MonitorBridge(appModel: self)
        remoteMonitoringEnabled = autoStartRemoteMonitoring
        resumeAutonomousSessionIfNeeded()
    }

    private func applyRemoteMonitoringState() {
        guard let monitorBridge else { return }
        if remoteMonitoringEnabled {
            monitorBridge.start()
        } else {
            monitorBridge.stop()
        }
    }

    private func applyAutomaticRecoveryState() {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1_000)
        guard automaticRecoveryEnabled, engine.running, !operatorStoppedEngine else {
            automaticRecoveryArmed = false
            runtimeRecoveryCoordinator.disarm()
            automaticRecoveryStatus = "disarmed"
            if !automaticRecoveryEnabled {
                clearAutonomousSessionIntent()
            }
            return
        }
        automaticRecoveryArmed = true
        runtimeRecoveryCoordinator.arm(nowMs: nowMs)
        automaticRecoveryStatus = "armed · verifying"
        saveAutonomousSessionIntent()
    }

    // Whether the running Core Audio route still matches HD96/Dante proof criteria.
    // Drives the remote route-drift alert. Conservative v1 approximation from the
    // sample-rate and channel-count states already surfaced in the desktop UI.
    var remoteRouteHealthy: Bool {
        guard isRunning else { return true }
        guard case .ready = sampleRateState else { return false }
        return !channelCountState.isWarning
    }

    var inputDevices: [AMDeviceInfo] {
        devices.filter { $0.inputChannels > 0 }
    }

    var outputDevices: [AMDeviceInfo] {
        devices.filter { $0.outputChannels >= 2 }
    }

    var selectedInputDevice: AMDeviceInfo? {
        devices.first { $0.uid == selectedInputUID }
    }

    var selectedOutputDevice: AMDeviceInfo? {
        devices.first { $0.uid == selectedOutputUID }
    }

    var isRunning: Bool {
        engine.running
    }

    var isRecording: Bool {
        engine.recording
    }

    var detectedSampleRate: Double {
        engine.running ? engine.sampleRate : (selectedInputDevice?.sampleRate ?? 0)
    }

    var detectedInputChannels: Int {
        engine.running ? engine.inputChannelCount : (selectedInputDevice?.inputChannels ?? channelMappings.count)
    }

    var detectedBufferFrames: Int {
        engine.bufferFrameSize
    }
    var algorithmicLatencyMs: Double { engine.algorithmicLatencyMs }
    var estimatedOneWayAudioLatencyMs: Double { engine.estimatedOneWayLatencyMs }
    var separateOutputPrebufferFrames: Int { engine.separateOutputPrebufferFrames }
    var lipSyncAudioLatencyReferenceMs: Double {
        measuredEndToEndAudioLatencyMs > 0
            ? measuredEndToEndAudioLatencyMs
            : estimatedOneWayAudioLatencyMs
    }
    var lipSyncRecommendation: String {
        guard measuredEndToEndAudioLatencyMs > 0, measuredEndToEndVideoLatencyMs > 0 else {
            return "Measure audio + video paths"
        }
        let offset = measuredEndToEndAudioLatencyMs - measuredEndToEndVideoLatencyMs
        if abs(offset) < 1 {
            return "Aligned within 1.0 ms"
        }
        if offset > 0 {
            return String(format: "Delay video %.1f ms", offset)
        }
        return String(format: "Delay audio %.1f ms", -offset)
    }

    var callbackHealthWarning: Bool {
        guard isRunning else { return false }
        return inputCallbackAgeMs < 0 ||
            outputCallbackAgeMs < 0 ||
            inputCallbackAgeMs > 1_000 ||
            outputCallbackAgeMs > 1_000
    }

    var outputClockWarning: Bool {
        guard isRunning, separateOutputPrebufferFrames > 0 else { return false }
        let lowerBound = max(detectedBufferFrames * 2, 1)
        let upperBound = max(separateOutputPrebufferFrames * 2, lowerBound)
        return separateOutputRingFillFrames < lowerBound ||
            separateOutputRingFillFrames > upperBound ||
            abs(outputClockCorrectionPpm) >= 900
    }

    var automaticRecoveryWarning: Bool {
        automaticRecoveryEnabled &&
            (automaticRecoveryStatus.contains("failed") ||
                automaticRecoveryStatus.contains("restarting"))
    }

    var sampleRateState: SampleRateState {
        SampleRateState.make(detected: detectedSampleRate, expected: expectedSampleRate)
    }

    var channelCountState: ChannelCountState {
        if !engine.running && selectedInputDevice == nil { return .unknown(expected: expectedInputChannels) }
        let actual = detectedInputChannels
        guard actual > 0 else { return .unknown(expected: expectedInputChannels) }
        return actual == expectedInputChannels ? .ready(actual: actual) : .mismatch(expected: expectedInputChannels, actual: actual)
    }

    var channelMapCoverage: ChannelMapCoverage {
        ChannelMapCoverage.make(
            channelMappings: channelMappings,
            inputChannelCount: detectedInputChannels
        )
    }

    var hd96Preflight: HD96PreflightReport {
        HD96PreflightReport.make(
            inputDevice: selectedInputDevice,
            outputDevice: selectedOutputDevice,
            expectedInputChannels: expectedInputChannels,
            detectedInputChannels: detectedInputChannels,
            detectedSampleRate: detectedSampleRate,
            expectedSampleRate: expectedSampleRate,
            channelMappings: channelMappings
        )
    }

    var engineStartGate: HD96EngineStartGate {
        HD96EngineStartGate.make(from: hd96Preflight, rehearsal: rehearsalMode)
    }

    // Size the expected channel count + map to whatever the selected input actually
    // exposes, and seed service roles, so a rehearsal run is one tap rather than manual
    // setup. Only rebuilds the map when the row count is wrong, to avoid clobbering an
    // already-configured layout.
    private func autoFitForRehearsal() {
        let detected = detectedInputChannels
        guard detected > 0 else { return }
        let count = min(max(detected, 1), 64)
        if channelMappings.count != count {
            channelMappings = ChannelMapping.applyingServiceRoleTemplate(
                to: ChannelMapping.defaults(count: count),
                count: count
            )
        }
        expectedInputChannels = count
    }

    var canStartEngine: Bool {
        engineStartGate.isAllowed
    }

    var canSaveFullCheckManifest: Bool {
        finishedRecordingURL != nil &&
            finishedReportURL != nil &&
            lastSoundcheckReport != nil &&
            finishedStabilityReportURL != nil &&
            lastStabilityReport != nil
    }

    var canStartSoundcheck: Bool {
        isRunning &&
            !isRecording &&
            !continuousRecordingActive &&
            !recordingSaveInProgress &&
            !soundcheckReportInProgress &&
            !stabilityMonitorActive
    }

    var canStartStabilityMonitor: Bool {
        isRunning &&
            !isRecording &&
            !recordingSaveInProgress &&
            !soundcheckReportInProgress &&
            !stabilityMonitorActive
    }

    func refreshDevices() {
        refreshAudioInputPermission()
        devices = engine.availableDevices().sorted { lhs, rhs in
            lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        var routeWarning: String?
        let resolvedInputUID = CoreAudioRouteSelection.validatedInputUID(
            currentInputUID: selectedInputUID,
            devices: devices
        )
        if resolvedInputUID != selectedInputUID {
            selectedInputUID = resolvedInputUID
        }
        if !selectedInputUID.isEmpty && selectedInputDevice == nil {
            routeWarning = "Saved Core Audio input device was not found: \(selectedInputUID). Connect Dante Virtual Soundcard/HD96 or choose a new input."
        }
        if selectedInputDevice != nil {
            selectedOutputUID = CoreAudioRouteSelection.validatedOutputUID(
                currentOutputUID: selectedOutputUID,
                devices: devices,
                selectedInput: selectedInputDevice
            )
        } else if !selectedOutputUID.isEmpty,
                  !devices.contains(where: { $0.uid == selectedOutputUID && $0.outputChannels >= 2 }) {
            routeWarning = [routeWarning, "Saved Core Audio output device was not found: \(selectedOutputUID)."]
                .compactMap { $0 }
                .joined(separator: " ")
        }
        syncChannelCountFromSelectedInput()
        pollEngine()
        if let routeWarning {
            lastError = routeWarning
            statusText = routeWarning
        } else if lastError?.hasPrefix("Saved Core Audio ") == true {
            lastError = nil
        }
    }

    func startEngine() {
        operatorStoppedEngine = false
        resumingAutonomousSession = false
        continuousRecordingRequested = false
        Task { @MainActor in
            await startEngineAfterPermissionCheck()
        }
    }

    private func startEngineAfterPermissionCheck() async {
        lastError = nil
        runningRouteSnapshot = nil
        finishedRecordingURL = nil
        finishedReportURL = nil
        lastSoundcheckReport = nil
        recordingSaveInProgress = false
        pendingSoundcheckProofControls = nil
        cancelSoundcheckReportTask()
        finishedDeviceInventoryURL = nil
        lastDeviceInventory = nil
        finishedStabilityReportURL = nil
        lastStabilityReport = nil
        finishedFullCheckManifestURL = nil
        lastFullCheckManifest = nil
        lastFullCheckVerification = nil

        let inputUID = selectedInputUID
        let outputUID = selectedOutputUID
        let routeSnapshot = CoreAudioRouteSnapshot.make(
            inputUID: inputUID,
            outputUID: outputUID,
            devices: devices
        )
        guard !inputUID.isEmpty else {
            lastError = "Select a Core Audio input device."
            statusText = lastError ?? statusText
            armRelaunchRetryIfNeeded()
            return
        }
        guard !outputUID.isEmpty else {
            lastError = rehearsalMode
                ? "Select a separate output device (built-in speakers, BlackHole, or an Aggregate) to monitor the rehearsal mix."
                : "Select a stream encoder, virtual, capture, or Aggregate Device output."
            statusText = lastError ?? statusText
            armRelaunchRetryIfNeeded()
            return
        }

        if rehearsalMode {
            autoFitForRehearsal()
        }

        let startGate = engineStartGate
        guard startGate.isAllowed else {
            lastError = startGate.failureMessage
            statusText = startGate.failureMessage
            armRelaunchRetryIfNeeded()
            return
        }

        guard await ensureAudioInputPermission() else {
            lastError = audioInputPermission.deniedMessage
            statusText = lastError ?? statusText
            armRelaunchRetryIfNeeded()
            return
        }
        guard !operatorStoppedEngine else {
            statusText = "Start canceled by operator"
            return
        }

        do {
            if let failure = automaticRecoveryPreflightFailure(
                inputUID: inputUID,
                outputUID: outputUID,
                rehearsal: rehearsalMode
            ) {
                throw NSError(
                    domain: "AutoMixRuntimeRecovery",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: failure]
                )
            }
            try engine.start(
                withInputDeviceUID: inputUID,
                outputDeviceUID: outputUID,
                channelRoles: channelMappings.map(\.role.rawValue),
                inputChannelIndices: channelInputIndexNumbers(),
                rehearsal: rehearsalMode
            )
            runningInRehearsal = rehearsalMode
            runningRouteSnapshot = routeSnapshot
            syncChannelCount(engine.inputChannelCount)
            engine.setSceneName(selectedScene.rawValue)
            engine.setSafeBypass(safeBypass)
            engine.setFrozen(frozen)
            engine.setShadowMode(shadowMode)
            applyAllManualOverrides()
            statusText = engine.status
            nextStreamHealthProbeMs = 0
            armAutomaticRecoveryAfterSuccessfulStart(nowMs: Int64(Date().timeIntervalSince1970 * 1_000))
            if resumingAutonomousSession && continuousRecordingRequested {
                resumeContinuousRecordingAfterRecovery(nowMs: Int64(Date().timeIntervalSince1970 * 1_000))
            }
            recordRuntimeIncident(
                kind: resumingAutonomousSession ? "engine-resumed-after-relaunch" : "engine-started",
                severity: .info,
                message: resumingAutonomousSession
                    ? "Core Audio engine resumed from the autonomous-session marker"
                    : "Core Audio engine started",
                details: runtimeRouteDetails()
            )
            resumingAutonomousSession = false
        } catch {
            lastError = error.localizedDescription
            statusText = error.localizedDescription
            recordRuntimeIncident(
                kind: "engine-start-failed",
                severity: .warning,
                message: error.localizedDescription,
                details: [
                    "inputUID": inputUID,
                    "outputUID": outputUID
                ]
            )
            if resumingAutonomousSession && automaticRecoveryEnabled {
                let nowMs = Int64(Date().timeIntervalSince1970 * 1_000)
                automaticRecoveryArmed = true
                runtimeRecoveryCoordinator.arm(nowMs: nowMs)
                automaticRecoveryStatus = "relaunch resume failed · retrying"
            }
        }
    }

    func stopEngine() {
        operatorStoppedEngine = true
        automaticRecoveryArmed = false
        runtimeRecoveryCoordinator.disarm()
        automaticRecoveryStatus = "disarmed by operator"
        continuousRecordingRequested = false
        resumingAutonomousSession = false
        clearAutonomousSessionIntent()
        streamHealthTask?.cancel()
        streamHealthTask = nil
        nextStreamHealthProbeMs = 0
        encoderHealth = encoderHealth.isConfigured
            ? StreamEndpointHealth(state: .checking, detail: "engine stopped", checkedAtMs: nil, observedAtMs: nil)
            : .disabled
        egressHealth = egressHealth.isConfigured
            ? StreamEndpointHealth(state: .checking, detail: "engine stopped", checkedAtMs: nil, observedAtMs: nil)
            : .disabled
        recordRuntimeIncident(
            kind: "engine-stopped-by-operator",
            severity: .info,
            message: "Operator stopped the Core Audio engine",
            details: runtimeRouteDetails()
        )
        cancelStabilityMonitor()
        engine.stop()
        runningInRehearsal = false
        runningRouteSnapshot = nil
        pollEngine()
    }

    func startTestRecording(seconds: Double = 10.0) {
        guard !stabilityMonitorActive else {
            lastError = "Cancel or finish the stability monitor before starting a soundcheck."
            statusText = lastError ?? statusText
            return
        }
        guard !continuousRecordingActive else {
            lastError = "Stop continuous recording before starting a soundcheck."
            statusText = lastError ?? statusText
            return
        }
        guard !recordingSaveInProgress && !soundcheckReportInProgress else {
            lastError = "Wait for the current soundcheck recording/report to finish before starting another soundcheck."
            statusText = lastError ?? statusText
            return
        }
        lastError = nil
        finishedRecordingURL = nil
        finishedReportURL = nil
        lastSoundcheckReport = nil
        finishedDeviceInventoryURL = nil
        lastDeviceInventory = nil
        finishedFullCheckManifestURL = nil
        lastFullCheckManifest = nil
        lastFullCheckVerification = nil
        recordingSaveInProgress = false
        cancelSoundcheckReportTask()
        do {
            pendingSoundcheckDurationSeconds = seconds
            let url = try nextRecordingURL()
            safeBypass = true
            pendingSoundcheckProofControls = SoundcheckProofControlSnapshot(
                safeBypassEnabled: safeBypass,
                frozen: frozen
            )
            try engine.startTestRecording(at: url, seconds: seconds)
            pollEngine()
        } catch {
            pendingSoundcheckProofControls = nil
            lastError = error.localizedDescription
            statusText = error.localizedDescription
        }
    }

    func startContinuousRecording() {
        guard engine.running else {
            lastError = "Start the audio engine before continuous recording."
            statusText = lastError ?? statusText
            return
        }
        guard !engine.recording && !engine.recordingSaveInProgress && !soundcheckReportInProgress else {
            lastError = "Wait for the soundcheck recording/report to finish before starting continuous recording."
            statusText = lastError ?? statusText
            return
        }

        do {
            let directory = try nextContinuousRecordingDirectory()
            try engine.startContinuousRecording(atDirectoryURL: directory)
            continuousRecordingDirectoryURL = directory
            continuousRecordingRequested = true
            saveAutonomousSessionIntent()
            lastError = nil
            pollEngine()
        } catch {
            lastError = error.localizedDescription
            statusText = error.localizedDescription
        }
    }

    func stopContinuousRecording() {
        continuousRecordingRequested = false
        saveAutonomousSessionIntent()
        engine.stopContinuousRecording()
        pollEngine()
    }

    func channelDidChange(_ channel: ChannelMapping) {
        applyInputChannelMap(channel)
        applyChannelRole(channel)
        applyManualOverride(channel)
        saveProfile()
    }

    func applyServiceRoleTemplate() {
        let templateCount = min(max(expectedInputChannels, detectedInputChannels, channelMappings.count, 1), 64)
        channelMappings = ChannelMapping.applyingServiceRoleTemplate(
            to: channelMappings,
            count: templateCount
        )

        for channel in channelMappings {
            applyInputChannelMap(channel)
            applyChannelRole(channel)
            applyManualOverride(channel)
        }
        saveProfile()
    }

    func startStabilityMonitor(seconds: Double? = nil) {
        guard engine.running else {
            lastError = "Start the audio engine before running a stability monitor."
            statusText = lastError ?? statusText
            return
        }
        guard !engine.recording && !engine.recordingSaveInProgress && !soundcheckReportInProgress else {
            lastError = "Wait for the soundcheck recording/report to finish before running a stability monitor."
            statusText = lastError ?? statusText
            return
        }
        prepareAutonomousStabilityProofMode()
        let duration = min(max(seconds ?? stabilityMonitorDurationSeconds, 30.0), 1_800.0)
        stabilityMonitorDurationSeconds = duration
        let now = Date()
        stabilityStartedAt = nil
        stabilityWarmupStartedAt = now
        stabilityElapsedSeconds = 0
        stabilityWarmupElapsedSeconds = 0
        stabilityDropoutDelta = 0
        stabilityCallbackOverrunDelta = 0
        stabilityRenderDeadlineMissDelta = 0
        stabilityOutputUnderrunDelta = 0
        stabilityOutputOverrunDelta = 0
        stabilityOutputRingTargetFrames = separateOutputPrebufferFrames
        stabilityMinOutputRingFillFrames = separateOutputRingFillFrames
        stabilityMaxOutputRingFillFrames = separateOutputRingFillFrames
        stabilityMaxAbsOutputClockCorrectionPpm = abs(outputClockCorrectionPpm)
        let levels = normalizedStreamOutputLevels()
        stabilityMinStreamOutputLevelsDb = levels
        stabilityMaxStreamOutputLevelsDb = levels
        stabilityMaxActiveInputChannelCount = activeInputChannelCount()
        stabilityMinMomentaryLufs = momentaryLufs
        stabilityMaxMomentaryLufs = momentaryLufs
        stabilityMinLimiterGainReductionDb = limiterGainReductionDb
        stabilityMonitorActive = true
        stabilityMonitorWaitingForStream = true
        finishedDeviceInventoryURL = nil
        lastDeviceInventory = nil
        finishedStabilityReportURL = nil
        lastStabilityReport = nil
        finishedFullCheckManifestURL = nil
        lastFullCheckManifest = nil
        lastFullCheckVerification = nil
        lastError = nil
        if StabilityStreamWarmup.isActiveStream(levels) {
            beginStabilityMeasurement(now: now, initialLevels: levels)
        }
    }

    func cancelStabilityMonitor() {
        stabilityMonitorActive = false
        stabilityMonitorWaitingForStream = false
        stabilityStartedAt = nil
        stabilityWarmupStartedAt = nil
        stabilityWarmupElapsedSeconds = 0
    }

    private func cancelActiveStabilityMonitorForProofControlChange(_ controlName: String) {
        guard stabilityMonitorActive else { return }
        cancelStabilityMonitor()
        finishedStabilityReportURL = nil
        lastStabilityReport = nil
        finishedFullCheckManifestURL = nil
        lastFullCheckManifest = nil
        lastFullCheckVerification = nil
        lastError = "Stability monitor canceled because \(controlName) changed."
        statusText = lastError ?? statusText
    }

    private func invalidateValidationEvidence() {
        guard !loadingProfile else { return }
        let canceledStabilityMonitor = stabilityMonitorActive
        cancelStabilityMonitor()
        cancelSoundcheckReportTask()
        finishedRecordingURL = nil
        finishedReportURL = nil
        lastSoundcheckReport = nil
        finishedDeviceInventoryURL = nil
        lastDeviceInventory = nil
        finishedStabilityReportURL = nil
        lastStabilityReport = nil
        finishedFullCheckManifestURL = nil
        lastFullCheckManifest = nil
        lastFullCheckVerification = nil
        if canceledStabilityMonitor {
            lastError = "Stability monitor canceled because validation settings changed."
            statusText = lastError ?? statusText
        }
    }

    func saveFullCheckManifest() {
        lastError = nil
        guard let recordingURL = finishedRecordingURL,
              let soundcheckReportURL = finishedReportURL,
              let soundcheckReport = lastSoundcheckReport,
              let stabilityReportURL = finishedStabilityReportURL,
              let stabilityReport = lastStabilityReport
        else {
            lastError = "Run soundcheck and stability monitor before saving a proof manifest."
            statusText = lastError ?? statusText
            return
        }

        do {
            let routeSnapshot = CoreAudioRouteSnapshot(
                inputDevice: soundcheckReport.inputDevice,
                outputDevice: soundcheckReport.outputDevice
            )
            let inputSnapshot = routeSnapshot.inputDevice
            let outputSnapshot = routeSnapshot.outputDevice
            let validationSource = AudioValidationSource.infer(
                inputDevice: inputSnapshot,
                outputDevice: outputSnapshot
            )
            let deviceInventory = CoreAudioDeviceInventory.make(
                devices: devices,
                expectedInputChannels: soundcheckReport.expectedInputChannels,
                selectedInputUID: inputSnapshot.uid.isEmpty ? nil : inputSnapshot.uid,
                selectedOutputUID: outputSnapshot.uid.isEmpty ? nil : outputSnapshot.uid
            )
            let deviceInventoryURL = try writeDeviceInventory(deviceInventory)
            let preflight = HD96PreflightReport.make(
                inputDevice: routeSnapshot.inputDeviceInfo(availableDevices: devices),
                outputDevice: routeSnapshot.outputDeviceInfo(availableDevices: devices),
                expectedInputChannels: soundcheckReport.expectedInputChannels,
                detectedInputChannels: soundcheckReport.detectedInputChannels,
                detectedSampleRate: soundcheckReport.detectedSampleRate,
                channelMappings: soundcheckReport.channelMappings
            )
            let preflightArtifact = CoreAudioPreflightProofArtifact(
                generatedAt: Date(),
                inputDevice: inputSnapshot,
                outputDevice: outputSnapshot,
                expectedInputChannels: soundcheckReport.expectedInputChannels,
                detectedInputChannels: soundcheckReport.detectedInputChannels,
                detectedSampleRate: soundcheckReport.detectedSampleRate,
                channelMappings: soundcheckReport.channelMappings,
                validationSource: validationSource,
                report: preflight
            )
            let preflightURL = try writePreflightReport(preflightArtifact)
            var manifest = CoreAudioFullCheckManifest(
                validationSource: validationSource,
                inputDevice: inputSnapshot,
                outputDevice: outputSnapshot,
                expectedInputChannels: soundcheckReport.expectedInputChannels,
                scene: soundcheckReport.scene,
                soundcheckSeconds: soundcheckReport.expectedRecordingDurationSeconds ?? 0,
                stabilitySeconds: stabilityReport.durationSeconds,
                deviceInventoryPath: deviceInventoryURL.path,
                preflightReportPath: preflightURL.path,
                preflightReady: preflight.isReady
            )
            manifest.recordSoundcheck(
                recordingPath: recordingURL.path,
                reportPath: soundcheckReportURL.path,
                passed: soundcheckReport.passed
            )
            manifest.recordStability(
                reportPath: stabilityReportURL.path,
                passed: stabilityReport.passed
            )

            if !preflight.isReady {
                manifest.markFailure("preflight not ready: \(preflight.summary)")
            } else if !routeSnapshot.matches(stabilityReport: stabilityReport) {
                manifest.markFailure("soundcheck and stability route evidence do not match")
            } else if !soundcheckReport.passed {
                manifest.markFailure("soundcheck report did not pass")
            } else if !stabilityReport.passed {
                manifest.markFailure("stability report did not pass")
            }

            let manifestURL = try writeFullCheckManifest(manifest)
            let verification = try CoreAudioFullCheckVerifier.verifyManifest(at: manifestURL)
            lastDeviceInventory = deviceInventory
            finishedDeviceInventoryURL = deviceInventoryURL
            lastFullCheckManifest = verification.manifest
            lastFullCheckVerification = verification
            finishedFullCheckManifestURL = manifestURL
            statusText = verification.summary
        } catch {
            lastError = error.localizedDescription
            statusText = error.localizedDescription
        }
    }

    private func startPolling() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollEngine()
            }
        }
    }

    // Assign a @Published only when it actually changes. @Published fires
    // objectWillChange on every set regardless of equality, so reassigning the same
    // value 10x/sec from the poll re-renders the whole UI (64 channel rows) for
    // nothing. Guarding makes an idle poll produce zero re-renders.
    private func update<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<AppModel, T>, _ value: T) {
        if self[keyPath: keyPath] != value {
            self[keyPath: keyPath] = value
        }
    }

    private func pollEngine() {
        let engineStatus = engine.status
        update(\.dropoutCount, engine.dropoutCount)
        update(\.callbackOverrunCount, engine.callbackOverrunCount)
        update(\.renderDeadlineMissCount, engine.renderDeadlineMissCount)
        update(\.outputUnderrunCount, engine.outputUnderrunCount)
        update(\.outputOverrunCount, engine.outputOverrunCount)
        update(\.separateOutputRingFillFrames, engine.separateOutputRingFillFrames)
        update(\.outputClockCorrectionPpm, engine.outputClockCorrectionPpm)
        update(\.inputCallbackAgeMs, engine.inputCallbackAgeMs)
        update(\.outputCallbackAgeMs, engine.outputCallbackAgeMs)
        update(\.watchdogSafeActive, engine.watchdogSafeActive)
        update(\.lastCallbackFrames, engine.lastCallbackFrameCount)
        update(\.maxObservedCallbackFrames, engine.maxObservedCallbackFrameCount)
        update(\.momentaryLufs, engine.momentaryLufs)
        update(\.shortTermLufs, engine.shortTermLufs)
        update(\.integratedLufs, engine.integratedLufs)
        update(\.limiterGainReductionDb, engine.limiterGainReductionDb)
        update(\.bpm, engine.currentBpm)
        update(\.bpmConfidence, engine.currentBpmConfidence)
        update(\.autoLoudnessTrimDb, engine.autoLoudnessTrimDb)
        update(\.recordingSaveInProgress, engine.recordingSaveInProgress)
        update(\.recordedFrameCount, engine.recordedFrameCount)
        update(\.recordingTargetFrameCount, engine.recordingTargetFrameCount)
        update(\.continuousRecordingActive, engine.continuousRecording)
        update(\.continuousRecordingFrameCount, engine.continuousRecordingFrameCount)
        update(\.continuousRecordingDroppedFrameCount, engine.continuousRecordingDroppedFrameCount)
        update(\.continuousRecordingSegmentCount, engine.continuousRecordingSegmentCount)
        update(\.statusText, runningRouteHealthStatus(baseStatus: engineStatus))

        var levels = engine.inputLevelsDb().map { $0.doubleValue }
        if levels.count < channelMappings.count {
            levels.append(contentsOf: Array(repeating: -100.0, count: channelMappings.count - levels.count))
        }
        update(\.levelsDb, levels)
        let automationChannels = channelMappings.indices
        update(\.autoTrimDb, automationChannels.map { engine.autoTrimDb(forChannel: $0) })
        update(\.autoFaderDb, automationChannels.map { engine.autoFaderDb(forChannel: $0) })
        update(\.learnedNoiseFloorDb, automationChannels.map {
            engine.learnedNoiseFloorDb(forChannel: $0)
        })
        update(\.autoChannelActive, automationChannels.map {
            engine.autoChannelActive(forChannel: $0)
        })

        var streamLevels = engine.outputLevelsDb().map { $0.doubleValue }
        if streamLevels.count < 2 {
            streamLevels.append(contentsOf: Array(repeating: -100.0, count: 2 - streamLevels.count))
        }
        update(\.streamOutputLevelsDb, streamLevels)

        updateStabilityMonitor()
        if let url = engine.consumeFinishedRecordingURL() {
            finishedRecordingURL = url
            scheduleSoundcheckReport(for: url)
        }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1_000)
        updateRuntimeIncidentTransitions(nowMs: nowMs)
        updateAutomaticRecovery(nowMs: nowMs)
        updateStreamHealthMonitoring(nowMs: nowMs)
        monitorBridge?.captureAndPublish(nowMs: nowMs)
    }

    private func resetStreamHealthMonitoring() {
        streamHealthTask?.cancel()
        streamHealthTask = nil
        nextStreamHealthProbeMs = 0
        encoderHealth = encoderHealthURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? .disabled
            : StreamEndpointHealth(state: .checking, detail: "waiting", checkedAtMs: nil, observedAtMs: nil)
        egressHealth = egressHealthURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? .disabled
            : StreamEndpointHealth(state: .checking, detail: "waiting", checkedAtMs: nil, observedAtMs: nil)
    }

    private func updateStreamHealthMonitoring(nowMs: Int64) {
        guard engine.running else { return }
        guard streamHealthTask == nil, nowMs >= nextStreamHealthProbeMs else { return }
        let encoderURL = encoderHealthURL
        let egressURL = egressHealthURL
        guard !encoderURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                !egressURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }

        nextStreamHealthProbeMs = nowMs + 2_000
        if !encoderURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           encoderHealth.checkedAtMs == nil {
            encoderHealth = StreamEndpointHealth(
                state: .checking,
                detail: encoderHealth.detail,
                checkedAtMs: encoderHealth.checkedAtMs,
                observedAtMs: encoderHealth.observedAtMs
            )
        }
        if !egressURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           egressHealth.checkedAtMs == nil {
            egressHealth = StreamEndpointHealth(
                state: .checking,
                detail: egressHealth.detail,
                checkedAtMs: egressHealth.checkedAtMs,
                observedAtMs: egressHealth.observedAtMs
            )
        }

        let probe = streamHealthProbe
        streamHealthTask = Task { [weak self] in
            async let encoderResult = probe.probe(urlString: encoderURL, nowMs: nowMs)
            async let egressResult = probe.probe(urlString: egressURL, nowMs: nowMs)
            let results = await (encoderResult, egressResult)
            guard !Task.isCancelled else { return }
            self?.finishStreamHealthProbe(
                encoder: results.0,
                egress: results.1,
                nowMs: nowMs
            )
        }
    }

    private func finishStreamHealthProbe(
        encoder: StreamEndpointHealth,
        egress: StreamEndpointHealth,
        nowMs: Int64
    ) {
        let previousEncoderFailure = encoderHealth.isFailure
        let previousEgressFailure = egressHealth.isFailure
        encoderHealth = encoder
        egressHealth = egress
        streamHealthTask = nil

        if encoder.isFailure && !previousEncoderFailure {
            recordRuntimeIncident(
                timestampMs: nowMs,
                kind: "encoder-health-failed",
                severity: .critical,
                message: encoder.detail,
                details: ["probe": "encoder"]
            )
        }
        if egress.isFailure && !previousEgressFailure {
            recordRuntimeIncident(
                timestampMs: nowMs,
                kind: "egress-health-failed",
                severity: .critical,
                message: egress.detail,
                details: ["probe": "public-egress"]
            )
        }
        if encoder.state == .healthy && previousEncoderFailure {
            recordRuntimeIncident(
                timestampMs: nowMs,
                kind: "encoder-health-recovered",
                severity: .info,
                message: encoder.detail,
                details: ["probe": "encoder"]
            )
        }
        if egress.state == .healthy && previousEgressFailure {
            recordRuntimeIncident(
                timestampMs: nowMs,
                kind: "egress-health-recovered",
                severity: .info,
                message: egress.detail,
                details: ["probe": "public-egress"]
            )
        }
    }

    private func armAutomaticRecoveryAfterSuccessfulStart(nowMs: Int64) {
        guard automaticRecoveryEnabled, !operatorStoppedEngine else {
            automaticRecoveryArmed = false
            runtimeRecoveryCoordinator.disarm()
            automaticRecoveryStatus = "disarmed"
            return
        }
        automaticRecoveryArmed = true
        runtimeRecoveryCoordinator.arm(nowMs: nowMs)
        automaticRecoveryStatus = "armed · verifying"
        saveAutonomousSessionIntent()
        previousRuntimeRouteHealthy = true
        previousOutputClockWarning = false
        previousWatchdogSafeActive = false
        previousRecordingDroppedFrameCount = engine.continuousRecordingDroppedFrameCount
    }

    private func updateAutomaticRecovery(nowMs: Int64) {
        guard !recoveryInFlight else { return }
        let routeHealthy = runtimeRouteHealthy()
        let sample = RuntimeHealthSample(
            nowMs: nowMs,
            armed: automaticRecoveryArmed && automaticRecoveryEnabled,
            operatorStopped: operatorStoppedEngine,
            isRunning: engine.running,
            routeHealthy: routeHealthy,
            inputCallbackAgeMs: engine.inputCallbackAgeMs,
            outputCallbackAgeMs: engine.outputCallbackAgeMs
        )

        switch runtimeRecoveryCoordinator.step(sample) {
        case .none:
            if automaticRecoveryArmed,
               engine.running,
               routeHealthy,
               engine.inputCallbackAgeMs >= 0,
               engine.outputCallbackAgeMs >= 0,
               engine.inputCallbackAgeMs < 1_000,
               engine.outputCallbackAgeMs < 1_000 {
                update(\.automaticRecoveryStatus, "armed · healthy")
            }
        case let .attemptRestart(reason):
            attemptAutomaticRecovery(reason: reason, nowMs: nowMs)
        }
    }

    private func attemptAutomaticRecovery(reason: String, nowMs: Int64) {
        guard automaticRecoveryEnabled,
              automaticRecoveryArmed,
              !operatorStoppedEngine,
              !recoveryInFlight
        else { return }

        recoveryInFlight = true
        automaticRecoveryAttemptCount += 1
        automaticRecoveryStatus = "restarting · attempt \(automaticRecoveryAttemptCount)"
        let shouldResumeContinuousRecording = continuousRecordingRequested
        let rehearsal = runningInRehearsal
        let inputUID = selectedInputUID
        let outputUID = selectedOutputUID

        recordRuntimeIncident(
            timestampMs: nowMs,
            kind: "automatic-restart-attempt",
            severity: .critical,
            message: reason,
            details: runtimeRouteDetails().merging([
                "attempt": "\(automaticRecoveryAttemptCount)",
                "resumeContinuousRecording": "\(shouldResumeContinuousRecording)"
            ]) { _, new in new }
        )

        invalidateValidationEvidence()
        engine.stop()
        runningRouteSnapshot = nil

        do {
            if let failure = automaticRecoveryPreflightFailure(
                inputUID: inputUID,
                outputUID: outputUID,
                rehearsal: rehearsal
            ) {
                throw NSError(
                    domain: "AutoMixRuntimeRecovery",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: failure]
                )
            }
            try engine.start(
                withInputDeviceUID: inputUID,
                outputDeviceUID: outputUID,
                channelRoles: channelMappings.map(\.role.rawValue),
                inputChannelIndices: channelInputIndexNumbers(),
                rehearsal: rehearsal
            )
            runningInRehearsal = rehearsal
            syncChannelCount(engine.inputChannelCount)
            engine.setSceneName(selectedScene.rawValue)
            engine.setSafeBypass(safeBypass)
            engine.setFrozen(frozen)
            engine.setShadowMode(shadowMode)
            applyAllManualOverrides()
            runningRouteSnapshot = liveRouteSnapshot()
            runtimeRecoveryCoordinator.noteAttemptResult(success: true, nowMs: nowMs)
            automaticRecoveryStatus = "restarted · verifying"
            statusText = engine.status
            lastError = nil

            if shouldResumeContinuousRecording {
                resumeContinuousRecordingAfterRecovery(nowMs: nowMs)
            }

            recordRuntimeIncident(
                timestampMs: nowMs,
                kind: "automatic-restart-succeeded",
                severity: .info,
                message: "Core Audio engine restarted and entered verification",
                details: runtimeRouteDetails()
            )
        } catch {
            runtimeRecoveryCoordinator.noteAttemptResult(success: false, nowMs: nowMs)
            automaticRecoveryStatus = "restart failed · retry scheduled"
            lastError = "Automatic audio recovery failed: \(error.localizedDescription)"
            statusText = lastError ?? statusText
            recordRuntimeIncident(
                timestampMs: nowMs,
                kind: "automatic-restart-failed",
                severity: .critical,
                message: error.localizedDescription,
                details: runtimeRouteDetails().merging([
                    "attempt": "\(automaticRecoveryAttemptCount)"
                ]) { _, new in new }
            )
        }
        recoveryInFlight = false
    }

    private func armRelaunchRetryIfNeeded() {
        guard resumingAutonomousSession,
              automaticRecoveryEnabled,
              !operatorStoppedEngine
        else { return }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1_000)
        automaticRecoveryArmed = true
        runtimeRecoveryCoordinator.arm(nowMs: nowMs)
        automaticRecoveryStatus = "relaunch resume blocked · retrying"
    }

    private func automaticRecoveryPreflightFailure(
        inputUID: String,
        outputUID: String,
        rehearsal: Bool
    ) -> String? {
        let currentDevices = engine.availableDevices()
        guard let input = currentDevices.first(where: { $0.uid == inputUID }) else {
            return "Configured Core Audio input is not available"
        }
        guard let output = currentDevices.first(where: { $0.uid == outputUID }) else {
            return "Configured Core Audio output is not available"
        }
        if rehearsal {
            guard input.inputChannels > 0, output.outputChannels >= 2 else {
                return "Configured rehearsal route no longer has the required channels"
            }
            return nil
        }

        let health = HD96RunningRouteHealth.make(
            inputDevice: input,
            outputDevice: output,
            expectedInputChannels: expectedInputChannels,
            detectedInputChannels: input.inputChannels,
            detectedSampleRate: input.sampleRate
        )
        return health.isReady ? nil : health.warningMessage
    }

    private func resumeContinuousRecordingAfterRecovery(nowMs: Int64) {
        do {
            let directory = try nextContinuousRecordingDirectory()
            try engine.startContinuousRecording(atDirectoryURL: directory)
            continuousRecordingDirectoryURL = directory
            continuousRecordingRequested = true
            saveAutonomousSessionIntent()
        } catch {
            recordRuntimeIncident(
                timestampMs: nowMs,
                kind: "recording-resume-failed",
                severity: .critical,
                message: error.localizedDescription,
                details: runtimeRouteDetails()
            )
            lastError = "Audio recovered, but continuous recording did not resume: \(error.localizedDescription)"
        }
    }

    private func updateRuntimeIncidentTransitions(nowMs: Int64) {
        let droppedFrames = engine.continuousRecordingDroppedFrameCount
        if droppedFrames > previousRecordingDroppedFrameCount {
            recordRuntimeIncident(
                timestampMs: nowMs,
                kind: "recording-frames-dropped",
                severity: .warning,
                message: "Continuous recording dropped \(droppedFrames - previousRecordingDroppedFrameCount) frames",
                details: [
                    "totalDroppedFrames": "\(droppedFrames)",
                    "recordingDirectory": continuousRecordingDirectoryURL?.path ?? ""
                ]
            )
        }
        previousRecordingDroppedFrameCount = droppedFrames

        let clockWarning = outputClockWarning
        if clockWarning && !previousOutputClockWarning {
            recordRuntimeIncident(
                timestampMs: nowMs,
                kind: "output-clock-risk",
                severity: .warning,
                message: "Separate output clock follower is near its safe operating limit",
                details: [
                    "correctionPpm": String(format: "%.1f", outputClockCorrectionPpm),
                    "ringFillFrames": "\(separateOutputRingFillFrames)",
                    "ringTargetFrames": "\(separateOutputPrebufferFrames)"
                ]
            )
        }
        previousOutputClockWarning = clockWarning

        if watchdogSafeActive && !previousWatchdogSafeActive {
            recordRuntimeIncident(
                timestampMs: nowMs,
                kind: "watchdog-safe-engaged",
                severity: .critical,
                message: "Realtime watchdog forced the role-aware SAFE path",
                details: runtimeRouteDetails()
            )
        }
        previousWatchdogSafeActive = watchdogSafeActive

        let routeHealthy = runtimeRouteHealthy()
        if automaticRecoveryArmed && !routeHealthy && previousRuntimeRouteHealthy {
            recordRuntimeIncident(
                timestampMs: nowMs,
                kind: "runtime-route-unhealthy",
                severity: .warning,
                message: "The running Core Audio route no longer satisfies the configured route",
                details: runtimeRouteDetails()
            )
        }
        previousRuntimeRouteHealthy = routeHealthy
    }

    private func runtimeRouteHealthy() -> Bool {
        guard engine.running else { return false }
        if runningInRehearsal {
            guard let input = engine.runningInputDeviceInfo(),
                  let output = engine.runningOutputDeviceInfo()
            else { return false }
            return input.uid == selectedInputUID &&
                output.uid == selectedOutputUID &&
                input.inputChannels > 0 &&
                output.outputChannels >= 2 &&
                engine.sampleRate > 0
        }
        return HD96RunningRouteHealth.make(
            inputDevice: engine.runningInputDeviceInfo(),
            outputDevice: engine.runningOutputDeviceInfo(),
            expectedInputChannels: expectedInputChannels,
            detectedInputChannels: engine.inputChannelCount,
            detectedSampleRate: engine.sampleRate
        ).isReady
    }

    private func liveRouteSnapshot() -> CoreAudioRouteSnapshot {
        CoreAudioRouteSnapshot(
            inputDevice: engine.runningInputDeviceInfo().map { SoundcheckDeviceSnapshot(device: $0) } ??
                snapshot(for: selectedInputDevice),
            outputDevice: engine.runningOutputDeviceInfo().map { SoundcheckDeviceSnapshot(device: $0) } ??
                snapshot(for: selectedOutputDevice)
        )
    }

    private func runtimeRouteDetails() -> [String: String] {
        [
            "inputUID": engine.runningInputDeviceInfo()?.uid ?? selectedInputUID,
            "outputUID": engine.runningOutputDeviceInfo()?.uid ?? selectedOutputUID,
            "sampleRate": String(format: "%.1f", engine.sampleRate),
            "inputChannels": "\(engine.inputChannelCount)",
            "inputCallbackAgeMs": String(format: "%.1f", engine.inputCallbackAgeMs),
            "outputCallbackAgeMs": String(format: "%.1f", engine.outputCallbackAgeMs)
        ]
    }

    private func recordRuntimeIncident(
        timestampMs: Int64 = Int64(Date().timeIntervalSince1970 * 1_000),
        kind: String,
        severity: AlertSeverity,
        message: String,
        details: [String: String]
    ) {
        let incident = RuntimeIncident(
            timestampMs: timestampMs,
            kind: kind,
            severity: severity,
            message: message,
            details: details
        )
        lastRuntimeIncident = "\(kind): \(message)"

        do {
            let journal: RuntimeIncidentJournal
            if let incidentJournal {
                journal = incidentJournal
            } else {
                let directory = try appSupportDirectory()
                    .appendingPathComponent("Incidents", isDirectory: true)
                let created = try RuntimeIncidentJournal(directory: directory)
                incidentJournal = created
                incidentLogURL = created.fileURL
                journal = created
            }
            let previousWrite = incidentWriteTask
            incidentWriteTask = Task {
                if let previousWrite {
                    await previousWrite.value
                }
                _ = try? await journal.append(incident)
            }
        } catch {
            lastRuntimeIncident = "incident journal unavailable: \(error.localizedDescription)"
        }
    }

    private func runningRouteHealthStatus(baseStatus: String) -> String {
        guard engine.running else { return baseStatus }
        let health = HD96RunningRouteHealth.make(
            inputDevice: engine.runningInputDeviceInfo(),
            outputDevice: engine.runningOutputDeviceInfo(),
            expectedInputChannels: expectedInputChannels,
            detectedInputChannels: engine.inputChannelCount,
            detectedSampleRate: engine.sampleRate
        )
        guard !health.isReady else { return baseStatus }
        return "\(baseStatus) - \(health.warningMessage)"
    }

    private func syncChannelCountFromSelectedInput() {
        guard !loadingProfile else { return }
        guard let input = selectedInputDevice else { return }
        syncChannelCount(min(max(input.inputChannels, 1), 64))
    }

    private func syncChannelCount(_ count: Int) {
        guard count > 0 else { return }
        let bounded = min(count, 64)
        if channelMappings.count == bounded {
            if levelsDb.count != bounded {
                levelsDb = Array(levelsDb.prefix(bounded)) + Array(repeating: -100.0, count: max(0, bounded - levelsDb.count))
            }
            return
        }

        if channelMappings.count < bounded {
            let existing = channelMappings.count
            channelMappings.append(contentsOf: (existing..<bounded).map { index in
                ChannelMapping(index: index, name: "Ch \(index + 1)", role: .unknown)
            })
        } else {
            channelMappings = Array(channelMappings.prefix(bounded))
        }
        levelsDb = Array(levelsDb.prefix(bounded)) + Array(repeating: -100.0, count: max(0, bounded - levelsDb.count))
    }

    private func profileURL() throws -> URL {
        let base = try appSupportDirectory()
        return base.appendingPathComponent("VenueProfile.json", conformingTo: .json)
    }

    private func appSupportDirectory() throws -> URL {
        if let profileDirectoryOverride {
            try FileManager.default.createDirectory(at: profileDirectoryOverride, withIntermediateDirectories: true)
            return profileDirectoryOverride
        }
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let appDirectory = root.appendingPathComponent("AutoMix Native", isDirectory: true)
        try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        return appDirectory
    }

    private struct AutonomousSessionIntent: Codable, Equatable {
        var active: Bool
        var continuousRecording: Bool
        var armedAtMs: Int64
    }

    private func autonomousSessionIntentURL() throws -> URL {
        try appSupportDirectory()
            .appendingPathComponent("AutonomousSession.json", conformingTo: .json)
    }

    private func saveAutonomousSessionIntent() {
        guard automaticRecoveryEnabled, automaticRecoveryArmed, !operatorStoppedEngine else {
            return
        }
        let intent = AutonomousSessionIntent(
            active: true,
            continuousRecording: continuousRecordingRequested,
            armedAtMs: Int64(Date().timeIntervalSince1970 * 1_000)
        )
        guard let data = try? JSONEncoder().encode(intent),
              let url = try? autonomousSessionIntentURL()
        else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func clearAutonomousSessionIntent() {
        guard let url = try? autonomousSessionIntentURL(),
              FileManager.default.fileExists(atPath: url.path)
        else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func resumeAutonomousSessionIfNeeded() {
        guard let url = try? autonomousSessionIntentURL(),
              let data = try? Data(contentsOf: url),
              let intent = try? JSONDecoder().decode(AutonomousSessionIntent.self, from: data),
              intent.active
        else { return }

        operatorStoppedEngine = false
        continuousRecordingRequested = intent.continuousRecording
        resumingAutonomousSession = true
        automaticRecoveryStatus = "resuming after relaunch"
        recordRuntimeIncident(
            kind: "relaunch-resume-requested",
            severity: .warning,
            message: "A persisted autonomous session requested engine recovery",
            details: [
                "continuousRecording": "\(intent.continuousRecording)",
                "previouslyArmedAtMs": "\(intent.armedAtMs)"
            ]
        )
        Task { @MainActor in
            await startEngineAfterPermissionCheck()
        }
    }

    private func loadProfile() {
        loadingProfile = true
        defer { loadingProfile = false }
        guard let url = try? profileURL(),
              let data = try? Data(contentsOf: url),
              let profile = try? JSONDecoder().decode(VenueProfile.self, from: data)
        else { return }

        selectedInputUID = profile.inputDeviceUID
        selectedOutputUID = profile.outputDeviceUID
        selectedScene = profile.scene
        shadowMode = profile.shadowMode
        measuredEndToEndAudioLatencyMs = profile.measuredEndToEndAudioLatencyMs
        measuredEndToEndVideoLatencyMs = profile.measuredEndToEndVideoLatencyMs
        encoderHealthURL = profile.encoderHealthURL
        egressHealthURL = profile.egressHealthURL
        expectedInputChannels = profile.expectedInputChannels
        expectedSampleRate = profile.expectedSampleRate
        channelMappings = profile.channelMappings.isEmpty ? ChannelMapping.defaults(count: 32) : profile.channelMappings
        levelsDb = Array(repeating: -100.0, count: channelMappings.count)
    }

    private func saveProfile() {
        guard !loadingProfile else { return }
        let profile = VenueProfile(
            inputDeviceUID: selectedInputUID,
            outputDeviceUID: selectedOutputUID,
            scene: selectedScene,
            shadowMode: shadowMode,
            measuredEndToEndAudioLatencyMs: measuredEndToEndAudioLatencyMs,
            measuredEndToEndVideoLatencyMs: measuredEndToEndVideoLatencyMs,
            encoderHealthURL: encoderHealthURL,
            egressHealthURL: egressHealthURL,
            expectedInputChannels: expectedInputChannels,
            expectedSampleRate: expectedSampleRate,
            channelMappings: channelMappings
        )
        guard let data = try? JSONEncoder().encode(profile),
              let url = try? profileURL()
        else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func nextRecordingURL() throws -> URL {
        let directory = try appSupportDirectory().appendingPathComponent("Dante Tests", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "automix-dante-test-\(formatter.string(from: Date())).wav"
        return directory.appendingPathComponent(name)
    }

    private func nextContinuousRecordingDirectory() throws -> URL {
        let root = try appSupportDirectory()
            .appendingPathComponent("Continuous Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = UUID().uuidString.prefix(8)
        let directory = root.appendingPathComponent(
            "automix-live-\(formatter.string(from: Date()))-\(suffix)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func nextStabilityReportURL() throws -> URL {
        let directory = try appSupportDirectory().appendingPathComponent("Dante Tests", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "automix-stability-\(formatter.string(from: Date())).json"
        return directory.appendingPathComponent(name)
    }

    private func nextPreflightReportURL() throws -> URL {
        try nextDanteTestURL(prefix: "automix-preflight", pathExtension: "json")
    }

    private func nextDeviceInventoryURL() throws -> URL {
        try nextDanteTestURL(prefix: "automix-device-inventory", pathExtension: "json")
    }

    private func nextFullCheckManifestURL() throws -> URL {
        try nextDanteTestURL(prefix: "automix-full-check", pathExtension: "json")
    }

    private func nextDanteTestURL(prefix: String, pathExtension: String) throws -> URL {
        let directory = try appSupportDirectory().appendingPathComponent("Dante Tests", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "\(prefix)-\(formatter.string(from: Date())).\(pathExtension)"
        return directory.appendingPathComponent(name)
    }

    private func scheduleSoundcheckReport(for recordingURL: URL) {
        cancelSoundcheckReportTask()
        let input = makeSoundcheckReportInput(recordingURL: recordingURL)
        soundcheckReportInProgress = true
        lastSoundcheckReport = nil
        finishedReportURL = nil

        soundcheckReportTask = Task.detached(priority: .utility) { [weak self, input] in
            do {
                let report = try SoundcheckReport.make(from: input)
                let reportURL = try report.writeJSON(beside: input.recordingURL)
                guard !Task.isCancelled else { return }
                await self?.finishSoundcheckReport(report, reportURL: reportURL, recordingURL: input.recordingURL)
            } catch {
                guard !Task.isCancelled else { return }
                await self?.finishSoundcheckReport(error: error, recordingURL: input.recordingURL)
            }
        }
    }

    private func makeSoundcheckReportInput(recordingURL: URL) -> SoundcheckReportInput {
        let routeSnapshot = proofRouteSnapshot()
        let proofControls = pendingSoundcheckProofControls ??
            SoundcheckProofControlSnapshot(safeBypassEnabled: safeBypass, frozen: frozen)
        return SoundcheckReportInput(
            recordingURL: recordingURL,
            expectedRecordingDurationSeconds: pendingSoundcheckDurationSeconds,
            inputDevice: routeSnapshot.inputDevice,
            outputDevice: routeSnapshot.outputDevice,
            scene: selectedScene,
            expectedInputChannels: expectedInputChannels,
            detectedInputChannels: detectedInputChannels,
            detectedSampleRate: detectedSampleRate,
            bufferFrameSize: detectedBufferFrames,
            lastCallbackFrames: lastCallbackFrames,
            maxObservedCallbackFrames: maxObservedCallbackFrames,
            dropoutCount: dropoutCount,
            callbackOverrunCount: callbackOverrunCount,
            renderDeadlineMissCount: renderDeadlineMissCount,
            outputUnderrunCount: outputUnderrunCount,
            outputOverrunCount: outputOverrunCount,
            watchdogSafeActive: watchdogSafeActive,
            safeBypassEnabled: proofControls.safeBypassEnabled,
            frozen: proofControls.frozen,
            channelMappings: channelMappings,
            latestInputLevelsDb: Array(levelsDb.prefix(channelMappings.count)),
            latestStreamOutputLevelsDb: Array(streamOutputLevelsDb.prefix(2)),
            latestMomentaryLufs: momentaryLufs,
            latestShortTermLufs: shortTermLufs,
            latestIntegratedLufs: integratedLufs,
            latestLimiterGainReductionDb: limiterGainReductionDb
        )
    }

    private func finishSoundcheckReport(_ report: SoundcheckReport, reportURL: URL, recordingURL: URL) {
        guard finishedRecordingURL == recordingURL else { return }
        soundcheckReportInProgress = false
        soundcheckReportTask = nil
        pendingSoundcheckProofControls = nil
        lastSoundcheckReport = report
        finishedReportURL = reportURL
    }

    private func finishSoundcheckReport(error: Error, recordingURL: URL) {
        guard finishedRecordingURL == recordingURL else { return }
        soundcheckReportInProgress = false
        soundcheckReportTask = nil
        pendingSoundcheckProofControls = nil
        lastError = error.localizedDescription
    }

    private func cancelSoundcheckReportTask() {
        soundcheckReportTask?.cancel()
        soundcheckReportTask = nil
        soundcheckReportInProgress = false
        pendingSoundcheckProofControls = nil
    }

    private func writeStabilityReport(_ report: StabilityMonitorReport) throws -> URL {
        let url = try nextStabilityReportURL()
        try writeJSON(report, to: url)
        return url
    }

    private func writePreflightReport(_ artifact: CoreAudioPreflightProofArtifact) throws -> URL {
        let url = try nextPreflightReportURL()
        try writeJSON(artifact, to: url)
        return url
    }

    private func writeDeviceInventory(_ inventory: CoreAudioDeviceInventory) throws -> URL {
        let url = try nextDeviceInventoryURL()
        try writeJSON(inventory, to: url)
        return url
    }

    private func writeFullCheckManifest(_ manifest: CoreAudioFullCheckManifest) throws -> URL {
        let url = try nextFullCheckManifestURL()
        try writeJSON(manifest, to: url)
        return url
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    private func updateStabilityMonitor(now: Date = Date()) {
        guard stabilityMonitorActive else { return }

        let levels = normalizedStreamOutputLevels()
        if stabilityMonitorWaitingForStream {
            let warmupStartedAt = stabilityWarmupStartedAt ?? now
            stabilityWarmupStartedAt = warmupStartedAt
            stabilityWarmupElapsedSeconds = max(0, now.timeIntervalSince(warmupStartedAt))
            guard StabilityStreamWarmup.shouldBeginMeasurement(
                levels: levels,
                warmupElapsed: stabilityWarmupElapsedSeconds,
                timeout: stabilityWarmupTimeoutSeconds
            ) else {
                return
            }
            beginStabilityMeasurement(now: now, initialLevels: levels)
        }

        guard let startedAt = stabilityStartedAt else { return }
        stabilityElapsedSeconds = min(now.timeIntervalSince(startedAt), stabilityMonitorDurationSeconds)
        stabilityDropoutDelta = dropoutCount >= stabilityStartDropouts ? dropoutCount - stabilityStartDropouts : 0
        stabilityCallbackOverrunDelta = callbackOverrunCount >= stabilityStartCallbackOverruns ? callbackOverrunCount - stabilityStartCallbackOverruns : 0
        stabilityRenderDeadlineMissDelta = renderDeadlineMissCount >= stabilityStartRenderDeadlineMisses ? renderDeadlineMissCount - stabilityStartRenderDeadlineMisses : 0
        stabilityOutputUnderrunDelta = outputUnderrunCount >= stabilityStartOutputUnderruns ? outputUnderrunCount - stabilityStartOutputUnderruns : 0
        stabilityOutputOverrunDelta = outputOverrunCount >= stabilityStartOutputOverruns ? outputOverrunCount - stabilityStartOutputOverruns : 0
        if stabilityOutputRingTargetFrames > 0 {
            stabilityMinOutputRingFillFrames = min(
                stabilityMinOutputRingFillFrames,
                separateOutputRingFillFrames
            )
            stabilityMaxOutputRingFillFrames = max(
                stabilityMaxOutputRingFillFrames,
                separateOutputRingFillFrames
            )
            stabilityMaxAbsOutputClockCorrectionPpm = max(
                stabilityMaxAbsOutputClockCorrectionPpm,
                abs(outputClockCorrectionPpm)
            )
        }

        for index in 0..<2 {
            stabilityMinStreamOutputLevelsDb[index] = min(stabilityMinStreamOutputLevelsDb[index], levels[index])
            stabilityMaxStreamOutputLevelsDb[index] = max(stabilityMaxStreamOutputLevelsDb[index], levels[index])
        }
        stabilityMaxActiveInputChannelCount = max(stabilityMaxActiveInputChannelCount, activeInputChannelCount())
        if momentaryLufs.isFinite {
            stabilityMinMomentaryLufs = min(stabilityMinMomentaryLufs, momentaryLufs)
            stabilityMaxMomentaryLufs = max(stabilityMaxMomentaryLufs, momentaryLufs)
        }
        if limiterGainReductionDb.isFinite {
            stabilityMinLimiterGainReductionDb = min(stabilityMinLimiterGainReductionDb, limiterGainReductionDb)
        }

        guard now.timeIntervalSince(startedAt) >= stabilityMonitorDurationSeconds else { return }
        let report = makeStabilityReport(durationSeconds: stabilityElapsedSeconds)
        stabilityMonitorActive = false
        stabilityMonitorWaitingForStream = false
        stabilityStartedAt = nil
        stabilityWarmupStartedAt = nil
        lastStabilityReport = report
        do {
            finishedStabilityReportURL = try writeStabilityReport(report)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func beginStabilityMeasurement(now: Date, initialLevels: [Double]) {
        let levels = StabilityStreamWarmup.normalizedStereoLevels(initialLevels)
        stabilityStartedAt = now
        stabilityWarmupStartedAt = nil
        stabilityMonitorWaitingForStream = false
        stabilityWarmupElapsedSeconds = 0
        stabilityStartDropouts = dropoutCount
        stabilityStartCallbackOverruns = callbackOverrunCount
        stabilityStartRenderDeadlineMisses = renderDeadlineMissCount
        stabilityStartOutputUnderruns = outputUnderrunCount
        stabilityStartOutputOverruns = outputOverrunCount
        stabilityOutputRingTargetFrames = separateOutputPrebufferFrames
        stabilityMinOutputRingFillFrames = separateOutputRingFillFrames
        stabilityMaxOutputRingFillFrames = separateOutputRingFillFrames
        stabilityMaxAbsOutputClockCorrectionPpm = abs(outputClockCorrectionPpm)
        stabilityMinStreamOutputLevelsDb = levels
        stabilityMaxStreamOutputLevelsDb = levels
        stabilityMaxActiveInputChannelCount = activeInputChannelCount()
        stabilityMinMomentaryLufs = momentaryLufs
        stabilityMaxMomentaryLufs = momentaryLufs
        stabilityMinLimiterGainReductionDb = limiterGainReductionDb
    }

    private func prepareAutonomousStabilityProofMode() {
        if safeBypass {
            safeBypass = false
        }
        if frozen {
            frozen = false
        }
        if shadowMode {
            shadowMode = false
        }
    }

    private func makeStabilityReport(durationSeconds: Double) -> StabilityMonitorReport {
        let routeSnapshot = proofRouteSnapshot()
        return StabilityMonitorReport.make(
            durationSeconds: durationSeconds,
            inputDevice: routeSnapshot.inputDevice,
            outputDevice: routeSnapshot.outputDevice,
            scene: selectedScene,
            expectedInputChannels: expectedInputChannels,
            detectedInputChannels: detectedInputChannels,
            detectedSampleRate: detectedSampleRate,
            bufferFrameSize: detectedBufferFrames,
            lastCallbackFrames: lastCallbackFrames,
            maxObservedCallbackFrames: maxObservedCallbackFrames,
            dropoutDelta: stabilityDropoutDelta,
            callbackOverrunDelta: stabilityCallbackOverrunDelta,
            renderDeadlineMissDelta: stabilityRenderDeadlineMissDelta,
            outputUnderrunDelta: stabilityOutputUnderrunDelta,
            outputOverrunDelta: stabilityOutputOverrunDelta,
            outputRingTargetFrames: stabilityOutputRingTargetFrames,
            minOutputRingFillFrames: stabilityMinOutputRingFillFrames,
            maxOutputRingFillFrames: stabilityMaxOutputRingFillFrames,
            maxAbsOutputClockCorrectionPpm: stabilityMaxAbsOutputClockCorrectionPpm,
            watchdogSafeActive: watchdogSafeActive,
            safeBypassEnabled: safeBypass,
            frozen: frozen,
            channelMappings: channelMappings,
            minStreamOutputLevelsDb: stabilityMinStreamOutputLevelsDb,
            maxStreamOutputLevelsDb: stabilityMaxStreamOutputLevelsDb,
            maxActiveInputChannelCount: stabilityMaxActiveInputChannelCount,
            minMomentaryLufs: stabilityMinMomentaryLufs,
            maxMomentaryLufs: stabilityMaxMomentaryLufs,
            minLimiterGainReductionDb: stabilityMinLimiterGainReductionDb
        )
    }

    private func normalizedStreamOutputLevels() -> [Double] {
        Array((streamOutputLevelsDb + [-100.0, -100.0]).prefix(2))
    }

    private func activeInputChannelCount() -> Int {
        levelsDb.prefix(max(0, detectedInputChannels)).filter { $0 > -90.0 }.count
    }

    private func proofRouteSnapshot() -> CoreAudioRouteSnapshot {
        let openedSnapshot = runningRouteSnapshot ?? CoreAudioRouteSnapshot(
            inputDevice: snapshot(for: selectedInputDevice),
            outputDevice: snapshot(for: selectedOutputDevice)
        )
        guard engine.running else { return openedSnapshot }

        let liveInput = engine.runningInputDeviceInfo().map { SoundcheckDeviceSnapshot(device: $0) } ??
            openedSnapshot.inputDevice
        let liveOutput = engine.runningOutputDeviceInfo().map { SoundcheckDeviceSnapshot(device: $0) } ??
            openedSnapshot.outputDevice
        return CoreAudioRouteSnapshot(inputDevice: liveInput, outputDevice: liveOutput)
    }

    private func snapshot(for device: AMDeviceInfo?) -> SoundcheckDeviceSnapshot {
        guard let device else { return .unknown }
        return SoundcheckDeviceSnapshot(device: device)
    }

    private func applyAllManualOverrides() {
        for channel in channelMappings {
            applyManualOverride(channel)
        }
    }

    private func channelInputIndexNumbers() -> [NSNumber] {
        let maxInputs = max(detectedInputChannels, channelMappings.count)
        return ChannelMapping.inputChannelIndexNumbers(
            for: channelMappings,
            mixerChannelCount: channelMappings.count,
            maxInputChannels: maxInputs
        )
    }

    private func applyInputChannelMap(_ channel: ChannelMapping) {
        guard engine.running else { return }
        let maxInputs = max(detectedInputChannels, channelMappings.count)
        _ = engine.setInputChannelIndex(
            channel.boundedInputChannelIndex(maxInputChannels: maxInputs),
            forMixerChannel: channel.index
        )
    }

    private func applyChannelRole(_ channel: ChannelMapping) {
        guard engine.running else { return }
        _ = engine.setChannelRoleForChannel(channel.index, role: channel.role.rawValue)
    }

    private func applyManualOverride(_ channel: ChannelMapping) {
        guard engine.running else { return }
        let fader = min(
            max(channel.faderDb, ChannelMapping.faderDbOverrideRange.lowerBound),
            ChannelMapping.faderDbOverrideRange.upperBound
        )
        let pan = min(
            max(channel.pan, ChannelMapping.panOverrideRange.lowerBound),
            ChannelMapping.panOverrideRange.upperBound
        )
        _ = engine.setManualMixOverrideForChannel(
            channel.index,
            faderDb: fader,
            pan: pan,
            overrideFader: channel.faderOverrideEnabled,
            overridePan: channel.panOverrideEnabled
        )
    }

    private func refreshAudioInputPermission() {
        audioInputPermission = AudioInputPermissionState(status: AVCaptureDevice.authorizationStatus(for: .audio))
    }

    private func ensureAudioInputPermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            audioInputPermission = .authorized
            return true
        case .notDetermined:
            audioInputPermission = .notDetermined
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
            audioInputPermission = granted ? .authorized : .denied
            return granted
        case .denied:
            audioInputPermission = .denied
            return false
        case .restricted:
            audioInputPermission = .restricted
            return false
        @unknown default:
            audioInputPermission = .unknown
            return false
        }
    }

#if DEBUG
    func debugAutonomousSessionIntentForTesting() -> (active: Bool, continuousRecording: Bool)? {
        guard let url = try? autonomousSessionIntentURL(),
              let data = try? Data(contentsOf: url),
              let intent = try? JSONDecoder().decode(AutonomousSessionIntent.self, from: data)
        else { return nil }
        return (intent.active, intent.continuousRecording)
    }

    func debugStartSimulatedForRecoveryTesting(nowMs: Int64 = 0) throws {
        let uid = "com.livedaw.automix.simulated-hd96-dante"
        operatorStoppedEngine = false
        selectedInputUID = uid
        selectedOutputUID = uid
        expectedInputChannels = 64
        expectedSampleRate = 96_000
        try engine.start(
            withInputDeviceUID: uid,
            outputDeviceUID: uid,
            channelRoles: channelMappings.map(\.role.rawValue),
            inputChannelIndices: channelInputIndexNumbers(),
            rehearsal: false
        )
        runningInRehearsal = false
        runningRouteSnapshot = liveRouteSnapshot()
        armAutomaticRecoveryAfterSuccessfulStart(nowMs: nowMs)
        pollEngine()
    }

    func debugForceUnexpectedEngineStopForTesting() {
        engine.stop()
    }

    func debugEvaluateAutomaticRecoveryForTesting(nowMs: Int64) {
        updateAutomaticRecovery(nowMs: nowMs)
        if engine.running {
            pollEngine()
        }
    }

    func debugWaitForIncidentWritesForTesting() async {
        await incidentWriteTask?.value
    }

    func debugActivateStabilityMonitorForInvalidationProbe() {
        stabilityMonitorActive = true
        stabilityMonitorWaitingForStream = true
        stabilityWarmupStartedAt = Date()
        stabilityStartedAt = nil
        stabilityWarmupElapsedSeconds = 0
        stabilityElapsedSeconds = 0
    }

    func debugStopPollingForTesting() {
        meterTimer?.invalidate()
        meterTimer = nil
    }

    func debugPrepareAutonomousStabilityProofModeForTesting() {
        prepareAutonomousStabilityProofMode()
    }

    func debugSetPendingSoundcheckProofControlsForTesting(safeBypassEnabled: Bool, frozen: Bool) {
        pendingSoundcheckProofControls = SoundcheckProofControlSnapshot(
            safeBypassEnabled: safeBypassEnabled,
            frozen: frozen
        )
    }

    func debugMakeSoundcheckReportInputForTesting(recordingURL: URL) -> SoundcheckReportInput {
        makeSoundcheckReportInput(recordingURL: recordingURL)
    }
#endif
}

private struct SoundcheckProofControlSnapshot {
    var safeBypassEnabled: Bool
    var frozen: Bool
}

struct StabilityStreamWarmup: Equatable {
    static let activeFloorDb = -90.0
    static let clippingCeilingDb = -0.1

    static func normalizedStereoLevels(_ levels: [Double]) -> [Double] {
        Array((levels + [-100.0, -100.0]).prefix(2))
    }

    static func isActiveStream(_ levels: [Double]) -> Bool {
        normalizedStereoLevels(levels).allSatisfy { level in
            level > activeFloorDb && level < clippingCeilingDb
        }
    }

    static func shouldBeginMeasurement(
        levels: [Double],
        warmupElapsed: TimeInterval,
        timeout: TimeInterval
    ) -> Bool {
        isActiveStream(levels) || warmupElapsed >= timeout
    }
}

struct CoreAudioRouteSelection: Equatable {
    static func validatedInputUID(
        currentInputUID: String,
        devices: [AMDeviceInfo]
    ) -> String {
        if currentInputUID.isEmpty {
            return preferredInputDevice(from: devices)?.uid ?? ""
        }
        if devices.contains(where: { $0.uid == currentInputUID && $0.inputChannels > 0 }) {
            return currentInputUID
        }
        return currentInputUID
    }

    static func preferredInputDevice(from devices: [AMDeviceInfo]) -> AMDeviceInfo? {
        let inputDevices = devices.filter { $0.inputChannels > 0 }
        return inputDevices.first { device in
            routeText(device).contains("dante")
        } ?? inputDevices.first
    }

    static func preferredOutputDevice(
        from devices: [AMDeviceInfo],
        selectedInput: AMDeviceInfo?
    ) -> AMDeviceInfo? {
        devices
            .filter { $0.outputChannels >= 2 }
            .first { output in
                LivestreamOutputIsolation.make(
                    inputDevice: selectedInput,
                    outputDevice: output
                ).passed
            }
    }

    static func validatedOutputUID(
        currentOutputUID: String,
        devices: [AMDeviceInfo],
        selectedInput: AMDeviceInfo?
    ) -> String {
        if !currentOutputUID.isEmpty,
           let currentOutput = devices.first(where: { $0.uid == currentOutputUID && $0.outputChannels >= 2 }),
           LivestreamOutputIsolation.make(inputDevice: selectedInput, outputDevice: currentOutput).passed {
            return currentOutputUID
        }

        return preferredOutputDevice(from: devices, selectedInput: selectedInput)?.uid ?? ""
    }

    static func resolvedOutputUID(
        explicitOutputUID: String?,
        profileOutputUID: String?,
        devices: [AMDeviceInfo],
        selectedInput: AMDeviceInfo?
    ) -> String? {
        if let explicitOutputUID, !explicitOutputUID.isEmpty { return explicitOutputUID }
        if let profileOutputUID, !profileOutputUID.isEmpty { return profileOutputUID }
        return preferredOutputDevice(from: devices, selectedInput: selectedInput)?.uid
    }

    private static func routeText(_ device: AMDeviceInfo) -> String {
        "\(device.name) \(device.uid)".lowercased()
    }
}

struct CoreAudioRouteSnapshot: Equatable, Sendable {
    var inputDevice: SoundcheckDeviceSnapshot
    var outputDevice: SoundcheckDeviceSnapshot

    static func make(
        inputUID: String,
        outputUID: String,
        devices: [AMDeviceInfo]
    ) -> CoreAudioRouteSnapshot {
        CoreAudioRouteSnapshot(
            inputDevice: snapshot(uid: inputUID, devices: devices),
            outputDevice: snapshot(uid: outputUID, devices: devices)
        )
    }

    func inputDeviceInfo(availableDevices: [AMDeviceInfo]) -> AMDeviceInfo? {
        deviceInfo(for: inputDevice, availableDevices: availableDevices)
    }

    func outputDeviceInfo(availableDevices: [AMDeviceInfo]) -> AMDeviceInfo? {
        deviceInfo(for: outputDevice, availableDevices: availableDevices)
    }

    func matches(stabilityReport: StabilityMonitorReport) -> Bool {
        inputDevice == stabilityReport.inputDevice &&
            outputDevice == stabilityReport.outputDevice
    }

    private static func snapshot(uid: String, devices: [AMDeviceInfo]) -> SoundcheckDeviceSnapshot {
        guard !uid.isEmpty,
              let device = devices.first(where: { $0.uid == uid }) else {
            return .unknown
        }
        return SoundcheckDeviceSnapshot(device: device)
    }

    private func deviceInfo(
        for snapshot: SoundcheckDeviceSnapshot,
        availableDevices: [AMDeviceInfo]
    ) -> AMDeviceInfo? {
        if let device = availableDevices.first(where: { $0.uid == snapshot.uid }) {
            return device
        }
        guard snapshot != .unknown else { return nil }
        return AMDeviceInfo(snapshot: snapshot)
    }
}

// Supported broadcast operating rates. The DSP runs at any rate; these are the
// standard pro rates the broadcast path accepts. The operator picks the exact expected
// rate (drift is then caught at the start gate); proof artifacts accept any of these.
enum BroadcastSampleRate {
    static let supported: [Double] = [48000, 96000]

    static func isSupported(_ rate: Double) -> Bool {
        supported.contains { abs($0 - rate) < 1.0 }
    }

    static func nearestSupported(_ rate: Double) -> Double {
        supported.min(by: { abs($0 - rate) < abs($1 - rate) }) ?? 48000
    }

    static func label(_ rate: Double) -> String {
        "\(Int((rate / 1000.0).rounded())) kHz"
    }
}

enum SampleRateState: Equatable {
    case unknown
    case ready(Double)
    case mismatch(expected: Double, actual: Double)

    static func make(detected: Double, expected: Double) -> SampleRateState {
        if detected <= 0 { return .unknown }
        return abs(detected - expected) < 1.0 ? .ready(detected) : .mismatch(expected: expected, actual: detected)
    }

    var label: String {
        switch self {
        case .unknown: return "Sample rate unknown"
        case .ready(let rate): return "\(BroadcastSampleRate.label(rate)) ready"
        case .mismatch(let expected, let actual):
            return "Expected \(BroadcastSampleRate.label(expected)), got \(Int(actual.rounded())) Hz"
        }
    }

    var isWarning: Bool {
        if case .mismatch = self { return true }
        return false
    }
}

enum ChannelCountState: Equatable {
    case unknown(expected: Int)
    case ready(actual: Int)
    case mismatch(expected: Int, actual: Int)

    var label: String {
        switch self {
        case .unknown(let expected):
            return "Expected \(expected), device unknown"
        case .ready(let actual):
            return "\(actual) channels ready"
        case .mismatch(let expected, let actual):
            return "Expected \(expected), got \(actual)"
        }
    }

    var isWarning: Bool {
        if case .mismatch = self { return true }
        return false
    }
}

struct HD96PreflightCheck: Codable, Equatable, Identifiable, Sendable {
    var id: String { name }
    var name: String
    var expected: String
    var observed: String
    var passed: Bool
    var blocking: Bool
}

struct HD96PreflightReport: Codable, Equatable, Sendable {
    var checks: [HD96PreflightCheck]

    var isReady: Bool {
        checks.filter(\.blocking).allSatisfy(\.passed)
    }

    var summary: String {
        if isReady && checks.allSatisfy(\.passed) {
            return "HD96 route ready"
        }
        if isReady {
            return "HD96 route ready with notes"
        }
        return "HD96 route not ready"
    }

    static func make(
        inputDevice: AMDeviceInfo?,
        outputDevice: AMDeviceInfo?,
        expectedInputChannels: Int,
        detectedInputChannels: Int,
        detectedSampleRate: Double,
        // Defaults to 96k so the existing (96k) hardware-proof verifier paths are
        // unchanged; the live operator gate passes the chosen expected rate explicitly.
        expectedSampleRate: Double = 96000,
        channelMappings: [ChannelMapping]? = nil
    ) -> HD96PreflightReport {
        let expectedChannels = min(max(expectedInputChannels, 1), 64)
        let inputName = inputDevice?.name ?? "none"
        let outputName = outputDevice?.name ?? "none"
        let outputRate = outputDevice?.sampleRate ?? 0
        let outputChannels = outputDevice?.outputChannels ?? 0
        let sameDevice = inputDevice?.uid == outputDevice?.uid && inputDevice != nil
        let inputFormatSummary = inputDevice?.inputFormatSummary ?? "unknown input format"
        let outputFormatSummary = outputDevice?.outputFormatSummary ?? "unknown output format"
        let inputFormatReady = inputDevice?.inputFormatSupported ?? false
        let outputFormatReady = outputDevice?.outputFormatSupported ?? false
        let danteHaystack = "\(inputDevice?.name ?? "") \(inputDevice?.uid ?? "")".lowercased()
        let danteNamed = danteHaystack.contains("dante")
        let outputIsolation = LivestreamOutputIsolation.make(
            inputDevice: inputDevice,
            outputDevice: outputDevice
        )
        let inputDeviceRate = inputDevice?.sampleRate ?? 0
        let clockReady = sameDevice
            ? detectedSampleRate > 0 && inputDeviceRate > 0 && abs(detectedSampleRate - inputDeviceRate) < 1.0
            : detectedSampleRate > 0 && outputRate > 0 && abs(detectedSampleRate - outputRate) < 1.0
        let channelMapCoverage = channelMappings.map {
            ChannelMapCoverage.make(
                channelMappings: $0,
                inputChannelCount: detectedInputChannels
            )
        }
        let sourceRoleCoverage = channelMappings.map(SourceRoleCoverage.make)

        var checks = [
            HD96PreflightCheck(
                name: "Input Device",
                expected: "Core Audio input selected",
                observed: inputName,
                passed: inputDevice != nil,
                blocking: true
            ),
            HD96PreflightCheck(
                name: "Dante Route",
                expected: "Dante-named Core Audio route",
                observed: danteNamed ? inputName : "\(inputName) (name not Dante-labeled)",
                passed: danteNamed,
                blocking: false
            ),
            HD96PreflightCheck(
                name: "Sample Rate",
                expected: "\(Int(expectedSampleRate.rounded())) Hz",
                observed: detectedSampleRate > 0 ? "\(Int(detectedSampleRate.rounded())) Hz" : "unknown",
                passed: abs(detectedSampleRate - expectedSampleRate) < 1.0,
                blocking: true
            ),
            HD96PreflightCheck(
                name: "Input Channels",
                expected: "\(expectedChannels)",
                observed: detectedInputChannels > 0 ? "\(detectedInputChannels)" : "unknown",
                passed: detectedInputChannels == expectedChannels,
                blocking: true
            ),
            HD96PreflightCheck(
                name: "Stream Output",
                expected: "2+ output channels",
                observed: "\(outputName) · \(outputChannels) out",
                passed: outputChannels >= 2,
                blocking: true
            ),
            HD96PreflightCheck(
                name: "Output Isolation",
                expected: "stream encoder or virtual output, not HD96/FOH return",
                observed: outputIsolation.observed,
                passed: outputIsolation.passed,
                blocking: true
            )
        ]

        if let channelMapCoverage {
            checks.append(
                HD96PreflightCheck(
                    name: "Input Map Coverage",
                    expected: "each Dante input mapped once",
                    observed: channelMapCoverage.summary,
                    passed: channelMapCoverage.isReady,
                    blocking: true
                )
            )
        }

        if let sourceRoleCoverage {
            checks.append(
                HD96PreflightCheck(
                    name: "Source Roles",
                    expected: "1+ non-unknown source role",
                    observed: sourceRoleCoverage.summary,
                    passed: sourceRoleCoverage.isReady,
                    blocking: true
                )
            )
        }

        checks.append(contentsOf: [
            HD96PreflightCheck(
                name: "Core Audio Format",
                expected: "32-bit little-endian float PCM input/output",
                observed: sameDevice
                    ? "input \(inputFormatSummary) / output \(outputFormatSummary)"
                    : "input \(inputFormatSummary) / output \(outputFormatSummary)",
                passed: inputFormatReady && outputFormatReady,
                blocking: true
            ),
            HD96PreflightCheck(
                name: "Route Clock",
                expected: "input/output sample rates match",
                observed: sameDevice
                    ? "same Core Audio device · detected \(Int(detectedSampleRate.rounded())) Hz / listed \(Int(inputDeviceRate.rounded())) Hz"
                    : "input \(Int(detectedSampleRate.rounded())) Hz / output \(Int(outputRate.rounded())) Hz",
                passed: clockReady,
                blocking: true
            )
        ])

        return HD96PreflightReport(checks: checks)
    }
}

struct HD96EngineStartGate: Equatable {
    private static let routeSafetyCheckNames: Set<String> = [
        "Input Device",
        "Sample Rate",
        "Input Channels",
        "Stream Output",
        "Output Isolation",
        "Input Map Coverage",
        "Core Audio Format",
        "Route Clock"
    ]

    var failedChecks: [HD96PreflightCheck]

    var isAllowed: Bool {
        failedChecks.isEmpty
    }

    var failureMessage: String {
        guard !failedChecks.isEmpty else { return "" }
        let details = failedChecks
            .map { "\($0.name): \($0.observed)" }
            .joined(separator: "; ")
        return "Core Audio start blocked: \(details)"
    }

    // Policy gates relaxed in rehearsal/monitor mode. These protect a broadcast
    // go-live (must be 96 kHz, output isolated from FOH/Dante, full channel coverage)
    // but should not stop an operator from verifying signal flow during a rehearsal.
    // The technical gates (Input Device, Stream Output, Core Audio Format, Route Clock)
    // stay enforced because the audio path genuinely needs them.
    private static let rehearsalRelaxedCheckNames: Set<String> = [
        "Sample Rate",
        "Input Channels",
        "Output Isolation",
        "Input Map Coverage"
    ]

    static func make(from preflight: HD96PreflightReport, rehearsal: Bool = false) -> HD96EngineStartGate {
        HD96EngineStartGate(
            failedChecks: preflight.checks.filter { check in
                guard routeSafetyCheckNames.contains(check.name), !check.passed else { return false }
                if rehearsal && rehearsalRelaxedCheckNames.contains(check.name) { return false }
                return true
            }
        )
    }
}

struct HD96RunningRouteHealth: Equatable {
    private static let runtimeCheckNames: Set<String> = [
        "Input Device",
        "Sample Rate",
        "Input Channels",
        "Stream Output",
        "Output Isolation",
        "Core Audio Format",
        "Route Clock"
    ]

    var failedChecks: [HD96PreflightCheck]

    var isReady: Bool {
        failedChecks.isEmpty
    }

    var warningMessage: String {
        guard !failedChecks.isEmpty else { return "" }
        let details = failedChecks
            .map { "\($0.name): \($0.observed)" }
            .joined(separator: "; ")
        return "Running Core Audio route warning: \(details)"
    }

    static func make(
        inputDevice: AMDeviceInfo?,
        outputDevice: AMDeviceInfo?,
        expectedInputChannels: Int,
        detectedInputChannels: Int,
        detectedSampleRate: Double
    ) -> HD96RunningRouteHealth {
        let report = HD96PreflightReport.make(
            inputDevice: inputDevice,
            outputDevice: outputDevice,
            expectedInputChannels: expectedInputChannels,
            detectedInputChannels: detectedInputChannels,
            detectedSampleRate: detectedSampleRate
        )
        return HD96RunningRouteHealth(
            failedChecks: report.checks.filter { check in
                runtimeCheckNames.contains(check.name) && !check.passed
            }
        )
    }
}

enum AudioInputPermissionState: String, Equatable {
    case unknown
    case notDetermined
    case authorized
    case denied
    case restricted

    init(status: AVAuthorizationStatus) {
        switch status {
        case .authorized: self = .authorized
        case .notDetermined: self = .notDetermined
        case .denied: self = .denied
        case .restricted: self = .restricted
        @unknown default: self = .unknown
        }
    }

    var label: String {
        switch self {
        case .unknown: return "Audio input permission unknown"
        case .notDetermined: return "Permission will be requested on Start"
        case .authorized: return "Audio input permission granted"
        case .denied: return "Audio input permission denied"
        case .restricted: return "Audio input permission restricted"
        }
    }

    var isWarning: Bool {
        self == .denied || self == .restricted || self == .unknown
    }

    var deniedMessage: String {
        switch self {
        case .denied:
            return "AutoMix does not have audio input permission. Enable it in System Settings > Privacy & Security > Microphone, then start again."
        case .restricted:
            return "Audio input permission is restricted by macOS policy. Allow microphone/audio input access before opening Dante Virtual Soundcard."
        case .unknown:
            return "Could not determine macOS audio input permission."
        case .notDetermined:
            return "Audio input permission has not been granted yet."
        case .authorized:
            return ""
        }
    }
}
