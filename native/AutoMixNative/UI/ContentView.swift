import AppKit
import SwiftUI

private enum AutoMixPalette {
    static let canvas = Color(red: 0.035, green: 0.039, blue: 0.055)
    static let header = Color(red: 0.047, green: 0.051, blue: 0.067)
    static let panel = Color(red: 0.063, green: 0.071, blue: 0.094)
    static let panelRaised = Color(red: 0.082, green: 0.090, blue: 0.118)
    static let control = Color(red: 0.102, green: 0.114, blue: 0.145)
    static let border = Color.white.opacity(0.09)
    static let subtleBorder = Color.white.opacity(0.055)
    static let cyan = Color(red: 0.13, green: 0.76, blue: 0.91)
    static let cyanStrong = Color(red: 0.05, green: 0.55, blue: 0.72)
    static let green = Color(red: 0.20, green: 0.83, blue: 0.60)
    static let amber = Color(red: 0.96, green: 0.67, blue: 0.16)
    static let red = Color(red: 0.90, green: 0.15, blue: 0.18)
    static let purple = Color(red: 0.63, green: 0.52, blue: 0.94)
    static let primaryText = Color.white.opacity(0.94)
    static let secondaryText = Color.white.opacity(0.62)
    static let tertiaryText = Color.white.opacity(0.42)
}

private enum ControlWorkspace: String, CaseIterable, Identifiable {
    case live = "Live"
    case setup = "Setup"
    case validate = "Validate"

    var id: String { rawValue }
}

struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var workspace: ControlWorkspace = .live

    var body: some View {
        GeometryReader { geometry in
            let scale = operatorScale(for: geometry.size)

            operatorShell
                .frame(
                    width: geometry.size.width / scale,
                    height: geometry.size.height / scale,
                    alignment: .topLeading
                )
                .scaleEffect(scale, anchor: .topLeading)
        }
        .frame(minWidth: 1180, minHeight: 720)
        .background(AutoMixPalette.canvas)
        .tint(AutoMixPalette.cyan)
        .preferredColorScheme(.dark)
    }

    private var operatorShell: some View {
        VStack(spacing: 0) {
            StatusStrip(model: model, workspace: $workspace)
            if workspace == .live {
                ServiceSceneStrip(model: model)
                LiveOperatorConsole(model: model)
            } else {
                HSplitView {
                    DeviceControlPanel(model: model, workspace: $workspace)
                        .frame(minWidth: 340, idealWidth: 410, maxWidth: 480)
                    ChannelMappingPanel(model: model)
                        .frame(minWidth: 700)
                }
            }
        }
        .background(AutoMixPalette.canvas)
    }

    private func operatorScale(for size: CGSize) -> CGFloat {
        let widthScale = size.width / 1920
        let heightScale = size.height / 720
        return min(2, max(1, min(widthScale, heightScale)))
    }
}

private struct StatusStrip: View {
    @ObservedObject var model: AppModel
    @Binding var workspace: ControlWorkspace
    @State private var showSafeReleaseConfirmation = false
    @State private var showStopConfirmation = false

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.isRunning ? AutoMixPalette.green : AutoMixPalette.tertiaryText)
                    .frame(width: 9, height: 9)
                    .shadow(color: model.isRunning ? AutoMixPalette.green.opacity(0.5) : .clear, radius: 4)
                Text("AutoMix")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(AutoMixPalette.primaryText)
                Text("BROADCAST")
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(1.6)
                    .foregroundStyle(AutoMixPalette.tertiaryText)
            }

            HStack(spacing: 6) {
                Image(systemName: model.isRunning ? "waveform" : "waveform.slash")
                    .foregroundStyle(model.isRunning ? AutoMixPalette.green : AutoMixPalette.secondaryText)
                Text("\(model.selectedScene.label) · \(model.isRunning ? "Engine live" : "Engine idle")")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AutoMixPalette.secondaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(AutoMixPalette.panel)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(AutoMixPalette.subtleBorder))

            Spacer(minLength: 8)

            HeaderReadout(label: "SHORT", value: lufs(model.shortTermLufs), unit: "LUFS")
            HeaderReadout(label: "INTEG", value: lufs(model.integratedLufs), unit: "LUFS")
            HeaderReadout(label: "PEAK", value: peak, unit: "dBFS", warning: peakWarning)

            HStack(spacing: 4) {
                Circle()
                    .fill(healthColor)
                    .frame(width: 6, height: 6)
                Text(healthLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(healthColor)
            }
            .padding(.trailing, 4)

            HStack(spacing: 3) {
                ForEach(ControlWorkspace.allCases) { item in
                    Button(item.rawValue.uppercased()) {
                        workspace = item
                    }
                    .buttonStyle(
                        OperatorTabButtonStyle(
                            selected: workspace == item,
                            emphasis: item == .live
                        )
                    )
                    .accessibilityAddTraits(workspace == item ? .isSelected : [])
                }
            }

            Button {
                if model.safeBypass {
                    showSafeReleaseConfirmation = true
                } else {
                    model.safeBypass = true
                }
            } label: {
                Label(model.safeBypass ? "SAFE ACTIVE" : "SAFE", systemImage: "shield.fill")
            }
            .buttonStyle(
                OperatorActionButtonStyle(
                    foreground: model.safeBypass ? .white : AutoMixPalette.red,
                    background: model.safeBypass ? AutoMixPalette.red : AutoMixPalette.control
                )
            )
            .help("Engage immediately. Releasing SAFE requires confirmation.")

            Button {
                model.frozen.toggle()
            } label: {
                Label(model.frozen ? "FROZEN" : "FREEZE", systemImage: "snowflake")
            }
            .buttonStyle(
                OperatorActionButtonStyle(
                    foreground: model.frozen ? .black : AutoMixPalette.amber,
                    background: model.frozen ? AutoMixPalette.amber : AutoMixPalette.control
                )
            )

            if model.isRunning {
                Button {
                    showStopConfirmation = true
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(
                    OperatorActionButtonStyle(
                        foreground: AutoMixPalette.secondaryText,
                        background: AutoMixPalette.control
                    )
                )
            } else {
                Button {
                    model.startEngine()
                } label: {
                    Label(model.rehearsalMode ? "Rehearse" : "Start", systemImage: "play.fill")
                }
                .buttonStyle(
                    OperatorActionButtonStyle(
                        foreground: model.canStartEngine ? AutoMixPalette.green : AutoMixPalette.tertiaryText,
                        background: AutoMixPalette.control
                    )
                )
                .disabled(!model.canStartEngine)
                .help(model.canStartEngine ? "Start Core Audio" : model.engineStartGate.failureMessage)
                .keyboardShortcut(.return, modifiers: [.command])
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(AutoMixPalette.header)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AutoMixPalette.border).frame(height: 1)
        }
        .confirmationDialog(
            "Release SAFE?",
            isPresented: $showSafeReleaseConfirmation,
            titleVisibility: .visible
        ) {
            Button("Release SAFE", role: .destructive) {
                model.safeBypass = false
            }
            Button("Keep SAFE Engaged", role: .cancel) {}
        } message: {
            Text("Autonomous changes will resume. Confirm only after the live mix is stable.")
        }
        .confirmationDialog(
            "Stop the audio engine?",
            isPresented: $showStopConfirmation,
            titleVisibility: .visible
        ) {
            Button("Stop Audio Engine", role: .destructive) {
                model.stopEngine()
            }
            Button("Keep Running", role: .cancel) {}
        } message: {
            Text("Program audio and automation will stop immediately.")
        }
    }

    private var peakValue: Double {
        model.streamOutputLevelsDb.max() ?? -100
    }

    private var peak: String {
        peakValue <= -99 ? "—" : String(format: "%.1f", peakValue)
    }

    private var peakWarning: Bool { peakValue > -1 }

    private var healthColor: Color {
        if model.lastError != nil || model.watchdogSafeActive { return AutoMixPalette.red }
        if model.sampleRateState.isWarning || model.channelCountState.isWarning { return AutoMixPalette.amber }
        return model.isRunning ? AutoMixPalette.green : AutoMixPalette.secondaryText
    }

    private var healthLabel: String {
        if model.lastError != nil { return "Attention" }
        if model.watchdogSafeActive { return "Watchdog SAFE" }
        if model.sampleRateState.isWarning || model.channelCountState.isWarning { return "Route check" }
        return model.isRunning ? "Engine OK" : "Ready"
    }

    private func lufs(_ value: Double) -> String {
        value <= -99 ? "—" : String(format: "%.1f", value)
    }
}

private struct HeaderReadout: View {
    let label: String
    let value: String
    let unit: String
    var warning = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(label)
                .font(.system(size: 8, weight: .semibold))
                .tracking(1)
                .foregroundStyle(AutoMixPalette.tertiaryText)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .foregroundStyle(warning ? AutoMixPalette.red : AutoMixPalette.primaryText)
                Text(unit)
                    .font(.system(size: 8))
                    .foregroundStyle(AutoMixPalette.tertiaryText)
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
        }
        .frame(minWidth: 46, alignment: .trailing)
        .accessibilityElement(children: .combine)
    }
}

private struct OperatorTabButtonStyle: ButtonStyle {
    let selected: Bool
    let emphasis: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(
                selected
                    ? (emphasis ? Color.white : AutoMixPalette.primaryText)
                    : AutoMixPalette.secondaryText
            )
            .padding(.horizontal, 9)
            .frame(height: 32)
            .background(
                selected
                    ? (emphasis ? AutoMixPalette.cyanStrong : AutoMixPalette.panelRaised)
                    : AutoMixPalette.panel
            )
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(selected ? AutoMixPalette.cyan.opacity(0.45) : AutoMixPalette.subtleBorder)
            )
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}

private struct OperatorActionButtonStyle: ButtonStyle {
    let foreground: Color
    let background: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(AutoMixPalette.subtleBorder))
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}

private struct ServiceSceneStrip: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Button {
                if model.planningCenterCredentialStored {
                    model.refreshPlanningCenterPlan()
                }
            } label: {
                HStack(spacing: 7) {
                    Circle()
                        .fill(model.planningCenterPlan == nil ? AutoMixPalette.secondaryText : AutoMixPalette.cyan)
                        .frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Planning Center")
                            .font(.system(size: 11, weight: .semibold))
                        Text(model.planningCenterStatus)
                            .font(.system(size: 8))
                            .foregroundStyle(AutoMixPalette.secondaryText)
                            .lineLimit(1)
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .frame(width: 182, height: 38, alignment: .leading)
            .background(AutoMixPalette.panel)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(AutoMixPalette.subtleBorder))
            .help(
                model.planningCenterCredentialStored
                    ? "Refresh the current Planning Center service plan"
                    : "Configure Planning Center in Setup"
            )

            if let plan = model.planningCenterPlan, !plan.cues.isEmpty {
                Button {
                    model.previousPlanningCenterCue()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(SceneNavigationButtonStyle())
                .help("Previous Planning Center cue")
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(MixScene.allCases) { scene in
                        Button {
                            model.selectedScene = scene
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 5) {
                                    Circle()
                                        .fill(model.selectedScene == scene ? AutoMixPalette.cyan : AutoMixPalette.tertiaryText)
                                        .frame(width: 6, height: 6)
                                    Text(scene.label)
                                        .font(.system(size: 10, weight: .semibold))
                                }
                                Text(sceneDescription(scene))
                                    .font(.system(size: 8, weight: .medium))
                                    .tracking(0.7)
                                    .foregroundStyle(AutoMixPalette.secondaryText)
                            }
                            .frame(width: 132, alignment: .leading)
                        }
                        .buttonStyle(ScenePillButtonStyle(selected: model.selectedScene == scene))
                        .accessibilityAddTraits(model.selectedScene == scene ? .isSelected : [])
                    }
                }
            }

            if let plan = model.planningCenterPlan, !plan.cues.isEmpty {
                Button {
                    model.advancePlanningCenterCue()
                } label: {
                    Label("Next", systemImage: "chevron.right")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(
                    OperatorActionButtonStyle(
                        foreground: .white,
                        background: AutoMixPalette.cyanStrong
                    )
                )
                .help("Next Planning Center cue")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(AutoMixPalette.header)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AutoMixPalette.border).frame(height: 1)
        }
    }

    private func sceneDescription(_ scene: MixScene) -> String {
        switch scene {
        case .preService: return "AMBIENT · WALK-IN"
        case .worship: return "MUSIC · VOCALS"
        case .sermon: return "SPEECH · PRIORITY"
        case .prayer: return "SPEECH · RESPONSE"
        case .postService: return "AMBIENT · WALK-OUT"
        }
    }
}

private struct SceneNavigationButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(AutoMixPalette.secondaryText)
            .frame(width: 30, height: 38)
            .background(AutoMixPalette.panel)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(AutoMixPalette.subtleBorder))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

private struct ScenePillButtonStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(AutoMixPalette.primaryText)
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(selected ? AutoMixPalette.cyan.opacity(0.08) : AutoMixPalette.panel)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(selected ? AutoMixPalette.cyan.opacity(0.75) : AutoMixPalette.subtleBorder)
            )
            .opacity(configuration.isPressed ? 0.76 : 1)
    }
}

private struct LiveOperatorConsole: View {
    @ObservedObject var model: AppModel
    @State private var selectedChannelIndex: Int?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 8) {
                        ForEach($model.channelMappings) { $channel in
                            NativeChannelStrip(
                                channel: $channel,
                                levelDb: value(model.levelsDb, at: channel.index, fallback: -100),
                                autoTrimDb: value(model.autoTrimDb, at: channel.index, fallback: 0),
                                autoFaderDb: value(model.autoFaderDb, at: channel.index, fallback: -6),
                                noiseFloorDb: value(model.learnedNoiseFloorDb, at: channel.index, fallback: -60),
                                autoActive: value(model.autoChannelActive, at: channel.index, fallback: false),
                                shadowMode: model.shadowMode,
                                selected: selectedChannelIndex == channel.index,
                                onSelect: { selectedChannelIndex = channel.index }
                            )
                            .onChange(of: channel) { _, updated in
                                model.channelDidChange(updated)
                            }
                        }
                    }
                    .padding(10)
                }
                .scrollIndicators(.visible)
                .background(AutoMixPalette.canvas)

                Rectangle()
                    .fill(AutoMixPalette.border)
                    .frame(width: 1)

                NativeMasterRail(
                    model: model,
                    selectedChannelIndex: $selectedChannelIndex
                )
                .frame(width: 324)
            }

            NativeConsoleBar(model: model)
        }
        .background(AutoMixPalette.canvas)
    }

    private func value<T>(_ values: [T], at index: Int, fallback: T) -> T {
        values.indices.contains(index) ? values[index] : fallback
    }
}

private struct NativeChannelStrip: View {
    @Binding var channel: ChannelMapping
    let levelDb: Double
    let autoTrimDb: Double
    let autoFaderDb: Double
    let noiseFloorDb: Double
    let autoActive: Bool
    let shadowMode: Bool
    let selected: Bool
    let onSelect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button(action: onSelect) {
                HStack(alignment: .top, spacing: 6) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Text(channel.role.label)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(AutoMixPalette.primaryText)
                            if autoActive {
                                Circle()
                                    .fill(AutoMixPalette.green)
                                    .frame(width: 6, height: 6)
                            }
                        }
                        Text("CH \(channel.index + 1) · IN \(channel.inputChannelIndex + 1)")
                            .font(.system(size: 8, weight: .semibold, design: .monospaced))
                            .tracking(0.6)
                            .foregroundStyle(AutoMixPalette.tertiaryText)
                        Text(channel.name)
                            .font(.system(size: 9))
                            .foregroundStyle(AutoMixPalette.secondaryText)
                            .lineLimit(1)
                    }
                    Spacer()
                    if channel.hasAnyManualOverride {
                        Text("MANUAL")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(AutoMixPalette.amber)
                    }
                }
            }
            .buttonStyle(.plain)

            Picker("Role", selection: $channel.role) {
                ForEach(ChannelRole.allCases) { role in
                    Text(role.label).tag(role)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity)
            .background(AutoMixPalette.control)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .accessibilityLabel("Role for channel \(channel.index + 1)")

            HStack(spacing: 6) {
                Button {
                    channel.setMuted(!channel.muted)
                } label: {
                    Label(
                        channel.muted ? "MUTED" : "MUTE",
                        systemImage: channel.muted ? "speaker.slash.fill" : "speaker.wave.2"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(
                    OperatorActionButtonStyle(
                        foreground: channel.muted ? .white : AutoMixPalette.secondaryText,
                        background: channel.muted ? AutoMixPalette.red : AutoMixPalette.control
                    )
                )

                Text(channel.stereoLinkedToNext ? "ST" : "MONO")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(channel.stereoLinkedToNext ? AutoMixPalette.purple : AutoMixPalette.tertiaryText)
                    .frame(width: 32, height: 34)
                    .background(AutoMixPalette.control)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            HStack(alignment: .bottom, spacing: 10) {
                NativeVerticalMeter(db: levelDb)
                    .frame(width: 13, height: 145)

                VStack(spacing: 7) {
                    ChannelStat(label: "INPUT", value: db(levelDb))
                    ChannelStat(label: "TRIM", value: signed(autoTrimDb))
                    ChannelStat(label: "FADER", value: signed(currentFaderDb))
                    ChannelStat(label: "FLOOR", value: db(noiseFloorDb))
                    ChannelStat(
                        label: "STATE",
                        value: autoActive ? "ACTIVE" : "IDLE",
                        color: autoActive ? AutoMixPalette.green : AutoMixPalette.secondaryText
                    )
                }
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("LEVEL")
                        .font(.system(size: 8, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(AutoMixPalette.tertiaryText)
                    Spacer()
                    Text(signed(currentFaderDb))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(AutoMixPalette.primaryText)
                }
                Slider(value: manualFader, in: ChannelMapping.faderDbOverrideRange, step: 0.5)
                    .controlSize(.mini)
            }

            HStack(spacing: 5) {
                Button {
                    if channel.faderOverrideEnabled {
                        channel.faderOverrideEnabled = false
                    } else {
                        channel.faderDb = autoFaderDb
                        channel.faderOverrideEnabled = true
                    }
                } label: {
                    Text(channel.faderOverrideEnabled ? "MANUAL" : "AUTO")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(
                    MiniChipButtonStyle(
                        active: channel.faderOverrideEnabled,
                        activeColor: AutoMixPalette.amber
                    )
                )

                Button {
                    channel.processingOverride.eqOverrideEnabled.toggle()
                } label: {
                    Text("EQ")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(
                    MiniChipButtonStyle(
                        active: channel.processingOverride.eqOverrideEnabled,
                        activeColor: AutoMixPalette.amber
                    )
                )

                Button {
                    channel.processingOverride.compressorOverrideEnabled.toggle()
                } label: {
                    Text("DYN")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(
                    MiniChipButtonStyle(
                        active: channel.processingOverride.compressorOverrideEnabled,
                        activeColor: AutoMixPalette.amber
                    )
                )
            }

            Text(operatorReason)
                .font(.system(size: 8))
                .foregroundStyle(AutoMixPalette.cyan.opacity(0.76))
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .topLeading)

            Spacer(minLength: 0)
        }
        .padding(11)
        .frame(width: 174)
        .frame(minHeight: 430, maxHeight: .infinity, alignment: .top)
        .background(selected ? AutoMixPalette.panelRaised : AutoMixPalette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(selected ? AutoMixPalette.cyan.opacity(0.9) : AutoMixPalette.border, lineWidth: selected ? 1.5 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture(perform: onSelect)
    }

    private var currentFaderDb: Double {
        channel.faderOverrideEnabled ? channel.faderDb : autoFaderDb
    }

    private var manualFader: Binding<Double> {
        Binding(
            get: { currentFaderDb },
            set: { value in
                channel.faderOverrideEnabled = true
                channel.faderDb = value
            }
        )
    }

    private var operatorReason: String {
        if channel.muted { return "Operator mute is active." }
        if channel.hasAnyManualOverride { return "Manual controls override autonomous moves." }
        if shadowMode { return "Shadow candidate · automation is observing only." }
        if autoActive { return "Automation active · level and dynamics tracking." }
        return "Awaiting signal above the learned noise floor."
    }

    private func signed(_ value: Double) -> String {
        value <= -99 ? "−∞" : String(format: "%+.1f", value)
    }

    private func db(_ value: Double) -> String {
        value <= -99 ? "−∞" : String(format: "%.1f", value)
    }
}

private struct MiniChipButtonStyle: ButtonStyle {
    let active: Bool
    let activeColor: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(active ? Color.black : AutoMixPalette.secondaryText)
            .padding(.horizontal, 6)
            .frame(height: 27)
            .background(active ? activeColor : AutoMixPalette.control)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

private struct ChannelStat: View {
    let label: String
    let value: String
    var color = AutoMixPalette.secondaryText

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(AutoMixPalette.tertiaryText)
            Spacer()
            Text(value)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(color)
        }
    }
}

private struct NativeVerticalMeter: View {
    let db: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(AutoMixPalette.control)
                RoundedRectangle(cornerRadius: 3)
                    .fill(meterColor)
                    .frame(height: max(2, geometry.size.height * normalized))
            }
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(AutoMixPalette.red.opacity(0.8))
                .frame(height: 1)
                .padding(.top, 4)
        }
        .accessibilityLabel("Input level")
        .accessibilityValue(db <= -99 ? "silence" : String(format: "%.1f decibels", db))
    }

    private var normalized: Double {
        min(max((db + 80) / 80, 0), 1)
    }

    private var meterColor: Color {
        if db > -6 { return AutoMixPalette.red }
        if db > -18 { return AutoMixPalette.amber }
        return AutoMixPalette.green
    }
}

private struct NativeMasterRail: View {
    @ObservedObject var model: AppModel
    @Binding var selectedChannelIndex: Int?

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                NativePanelCard(title: "STREAM MIX", trailing: model.isRunning ? "LIVE" : "IDLE") {
                    VStack(spacing: 8) {
                        MasterMeterRow(label: "L", db: value(model.streamOutputLevelsDb, at: 0))
                        MasterMeterRow(label: "R", db: value(model.streamOutputLevelsDb, at: 1))

                        HStack(alignment: .firstTextBaseline) {
                            Text(lufs(model.integratedLufs))
                                .font(.system(size: 25, weight: .bold, design: .rounded))
                                .foregroundStyle(AutoMixPalette.primaryText)
                            Text("LUFS")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(AutoMixPalette.tertiaryText)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 1) {
                                Text("TARGET")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(AutoMixPalette.tertiaryText)
                                Text("\(sceneTarget) LUFS")
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(AutoMixPalette.amber)
                            }
                        }

                        Divider().overlay(AutoMixPalette.border)
                        NativeMetricRow(label: "Short-term", value: "\(lufs(model.shortTermLufs)) LUFS")
                        NativeMetricRow(label: "Momentary", value: "\(lufs(model.momentaryLufs)) LUFS")
                        NativeMetricRow(label: "Limiter GR", value: "\(String(format: "%.1f", model.limiterGainReductionDb)) dB")
                        NativeMetricRow(label: "Tempo", value: tempo)
                    }
                }

                selectedChannelCard

                NativePanelCard(title: "SYSTEM HEALTH", trailing: healthTrailing) {
                    VStack(spacing: 7) {
                        NativeMetricRow(
                            label: "Route",
                            value: "\(model.sampleRateState.label) · \(model.channelCountState.label)",
                            warning: model.sampleRateState.isWarning || model.channelCountState.isWarning
                        )
                        NativeMetricRow(
                            label: "Buffer",
                            value: model.detectedBufferFrames > 0 ? "\(model.detectedBufferFrames) frames" : "pending"
                        )
                        NativeMetricRow(
                            label: "Dropouts",
                            value: "\(model.dropoutCount)",
                            warning: model.dropoutCount > 0
                        )
                        NativeMetricRow(
                            label: "Recovery",
                            value: model.automaticRecoveryStatus,
                            warning: model.automaticRecoveryWarning
                        )
                        NativeMetricRow(
                            label: "Encoder",
                            value: model.encoderHealth.summary,
                            warning: model.encoderHealth.isFailure
                        )
                        NativeMetricRow(
                            label: "Egress",
                            value: model.egressHealth.summary,
                            warning: model.egressHealth.isFailure
                        )
                    }
                }

                NativePanelCard(title: "ACTIVITY", trailing: model.shadowMode ? "SHADOW" : "AUTO") {
                    VStack(alignment: .leading, spacing: 6) {
                        if let error = model.lastError {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(AutoMixPalette.amber)
                        } else if let incident = model.lastRuntimeIncident {
                            Label(incident, systemImage: "waveform.path.ecg")
                                .foregroundStyle(AutoMixPalette.secondaryText)
                        } else {
                            Label(
                                model.isRunning
                                    ? "Automation is supervising the live route."
                                    : "Start the engine after Setup passes.",
                                systemImage: model.isRunning ? "checkmark.circle.fill" : "info.circle"
                            )
                            .foregroundStyle(model.isRunning ? AutoMixPalette.green : AutoMixPalette.secondaryText)
                        }
                    }
                    .font(.system(size: 9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(10)
        }
        .background(AutoMixPalette.header)
    }

    @ViewBuilder
    private var selectedChannelCard: some View {
        if let index = selectedChannelIndex, model.channelMappings.indices.contains(index) {
            NativePanelCard(title: "SELECTED CHANNEL", trailing: "CH \(index + 1)") {
                SelectedChannelControls(
                    channel: Binding(
                        get: { model.channelMappings[index] },
                        set: { updated in
                            model.channelMappings[index] = updated
                            model.channelDidChange(updated)
                        }
                    )
                )
            }
        } else {
            NativePanelCard(title: "SELECTED CHANNEL", trailing: "—") {
                Text("Select a channel strip to edit its manual level, pan, and override state.")
                    .font(.system(size: 9))
                    .foregroundStyle(AutoMixPalette.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            }
        }
    }

    private var sceneTarget: Int {
        switch model.selectedScene {
        case .preService, .postService: return -18
        case .worship: return -14
        case .sermon, .prayer: return -16
        }
    }

    private var tempo: String {
        model.bpm >= 60 ? "\(Int(model.bpm.rounded())) BPM" : "— BPM"
    }

    private var healthTrailing: String {
        if model.watchdogSafeActive { return "SAFE" }
        if model.lastError != nil { return "ATTENTION" }
        return model.isRunning ? "OK" : "IDLE"
    }

    private func value(_ values: [Double], at index: Int) -> Double {
        values.indices.contains(index) ? values[index] : -100
    }

    private func lufs(_ value: Double) -> String {
        value <= -99 ? "—" : String(format: "%.1f", value)
    }
}

private struct NativePanelCard<Content: View>: View {
    let title: String
    let trailing: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(title)
                    .font(.system(size: 9, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(AutoMixPalette.secondaryText)
                Spacer()
                Text(trailing)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(AutoMixPalette.cyan)
            }
            content()
        }
        .padding(11)
        .background(AutoMixPalette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AutoMixPalette.border))
    }
}

private struct MasterMeterRow: View {
    let label: String
    let db: Double

    var body: some View {
        HStack(spacing: 7) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(AutoMixPalette.secondaryText)
                .frame(width: 10)
            ProgressView(value: normalized)
                .progressViewStyle(.linear)
                .tint(meterColor)
            Text(db <= -99 ? "−∞" : String(format: "%.1f", db))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(AutoMixPalette.secondaryText)
                .frame(width: 38, alignment: .trailing)
        }
    }

    private var normalized: Double {
        min(max((db + 80) / 80, 0), 1)
    }

    private var meterColor: Color {
        if db > -6 { return AutoMixPalette.red }
        if db > -18 { return AutoMixPalette.amber }
        return AutoMixPalette.cyan
    }
}

private struct NativeMetricRow: View {
    let label: String
    let value: String
    var warning = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(AutoMixPalette.secondaryText)
            Spacer()
            Text(value)
                .foregroundStyle(warning ? AutoMixPalette.amber : AutoMixPalette.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 9))
    }
}

private struct SelectedChannelControls: View {
    @Binding var channel: ChannelMapping

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(channel.role.label)
                        .font(.system(size: 12, weight: .bold))
                    Text(channel.name)
                        .font(.system(size: 9))
                        .foregroundStyle(AutoMixPalette.secondaryText)
                }
                Spacer()
                Button(channel.muted ? "Unmute" : "Mute") {
                    channel.setMuted(!channel.muted)
                }
                .buttonStyle(
                    MiniChipButtonStyle(
                        active: channel.muted,
                        activeColor: AutoMixPalette.red
                    )
                )
            }

            OverrideSliderRow(
                label: "Fader",
                enabled: $channel.faderOverrideEnabled,
                value: $channel.faderDb,
                range: ChannelMapping.faderDbOverrideRange,
                step: 0.5,
                format: "%.1f dB"
            )
            OverrideSliderRow(
                label: "Pan",
                enabled: $channel.panOverrideEnabled,
                value: $channel.pan,
                range: ChannelMapping.panOverrideRange,
                step: 0.05,
                format: "%.2f"
            )

            Button("Clear manual overrides") {
                channel.clearOverrides()
            }
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(AutoMixPalette.cyan)
            .buttonStyle(.plain)
            .disabled(!channel.hasAnyManualOverride && !channel.muted)
        }
    }
}

private struct NativeConsoleBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 18) {
                ConsoleBarGroup(title: "AUTOMATION") {
                    HStack(spacing: 10) {
                        Toggle("Shadow", isOn: $model.shadowMode)
                            .toggleStyle(.switch)
                        Toggle("Recovery", isOn: $model.automaticRecoveryEnabled)
                            .toggleStyle(.switch)
                    }
                    HStack(spacing: 5) {
                        Circle()
                            .fill(shadowDecisionStatusColor)
                            .frame(width: 6, height: 6)
                        Text(model.shadowDecisionCaptureStatus)
                            .foregroundStyle(
                                model.shadowDecisionCaptureStatus.hasPrefix("capture failed")
                                    ? AutoMixPalette.red
                                    : AutoMixPalette.secondaryText
                            )
                            .lineLimit(1)
                        if let url = model.shadowDecisionLogURL {
                            Button("Reveal") {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(AutoMixPalette.cyan)
                            .accessibilityLabel("Reveal SHADOW candidate-decision log")
                        }
                    }
                    .font(.system(size: 9, weight: .medium))
                }

                ConsoleBarGroup(title: "REHEARSAL") {
                    Toggle("Relax go-live gates", isOn: $model.rehearsalMode)
                        .toggleStyle(.switch)
                        .disabled(model.isRunning)
                }

                ConsoleBarGroup(title: "CONTINUOUS CAPTURE") {
                    Button {
                        if model.continuousRecordingActive || model.continuousRecordingRequested {
                            model.stopContinuousRecording()
                        } else {
                            model.startContinuousRecording()
                        }
                    } label: {
                        Label(
                            model.continuousRecordingActive ? "Recording" : "Record program",
                            systemImage: model.continuousRecordingActive ? "record.circle.fill" : "record.circle"
                        )
                    }
                    .buttonStyle(
                        OperatorActionButtonStyle(
                            foreground: model.continuousRecordingActive ? .white : AutoMixPalette.red,
                            background: model.continuousRecordingActive ? AutoMixPalette.red : AutoMixPalette.control
                        )
                    )
                    .disabled(!model.isRunning && !model.continuousRecordingActive)
                }

                ConsoleBarGroup(title: "REMOTE") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(model.remoteMonitoringEnabled ? AutoMixPalette.green : AutoMixPalette.tertiaryText)
                            .frame(width: 7, height: 7)
                        Text(model.monitorBridge?.listeningStatus ?? "stopped")
                        if let bridge = model.monitorBridge {
                            Text("· \(bridge.connectedClientCount) linked")
                                .foregroundStyle(AutoMixPalette.secondaryText)
                            Text(
                                bridge.primaryHeartbeatStatus.hasPrefix("healthy")
                                    ? "· primary ready"
                                    : "· backup required"
                            )
                            .foregroundStyle(
                                bridge.primaryHeartbeatStatus.hasPrefix("healthy")
                                    ? AutoMixPalette.green
                                    : AutoMixPalette.amber
                            )
                        }
                    }
                    .font(.system(size: 10, weight: .medium))
                }

                ConsoleBarGroup(title: "RUNTIME") {
                    HStack(spacing: 14) {
                        ConsoleCounter(label: "DROPS", value: "\(model.dropoutCount)", warning: model.dropoutCount > 0)
                        ConsoleCounter(label: "XRUN", value: "\(model.callbackOverrunCount + model.outputUnderrunCount)", warning: model.callbackOverrunCount + model.outputUnderrunCount > 0)
                        ConsoleCounter(label: "LATENCY", value: String(format: "%.1f ms", model.estimatedOneWayAudioLatencyMs))
                    }
                }
            }
            .padding(.horizontal, 14)
        }
        .frame(height: 66)
        .background(AutoMixPalette.header)
        .overlay(alignment: .top) {
            Rectangle().fill(AutoMixPalette.border).frame(height: 1)
        }
    }

    private var shadowDecisionStatusColor: Color {
        if model.shadowDecisionCaptureStatus.hasPrefix("capture failed") {
            return AutoMixPalette.red
        }
        if model.shadowDecisionCaptureStatus.hasPrefix("finalizing") {
            return AutoMixPalette.amber
        }
        return model.shadowDecisionRecordCount > 0
            ? AutoMixPalette.cyan
            : AutoMixPalette.tertiaryText
    }
}

private struct ConsoleBarGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 8, weight: .bold))
                .tracking(1)
                .foregroundStyle(AutoMixPalette.tertiaryText)
            HStack(spacing: 12) {
                content()
            }
            .font(.system(size: 9))
        }
        .padding(.trailing, 18)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(AutoMixPalette.border)
                .frame(width: 1)
        }
    }
}

private struct ConsoleCounter: View {
    let label: String
    let value: String
    var warning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(AutoMixPalette.tertiaryText)
            Text(value)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(warning ? AutoMixPalette.amber : AutoMixPalette.primaryText)
        }
    }
}

private struct DeviceControlPanel: View {
    @ObservedObject var model: AppModel
    @Binding var workspace: ControlWorkspace

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(workspaceDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

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
                        Divider()
                        Toggle("Automatic Audio Recovery", isOn: $model.automaticRecoveryEnabled)
                            .toggleStyle(.switch)
                            .help("Restart the exact configured Core Audio route after a sustained route failure or callback stall. Operator Stop always disarms recovery.")
                        StatusRow(
                            label: "Recovery",
                            value: model.automaticRecoveryStatus,
                            warning: model.automaticRecoveryWarning
                        )
                        if model.automaticRecoveryAttemptCount > 0 {
                            StatusRow(
                                label: "Restart Attempts",
                                value: "\(model.automaticRecoveryAttemptCount)"
                            )
                        }
                        if let incident = model.lastRuntimeIncident {
                            Text(incident)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let url = model.incidentLogURL {
                            Label(url.path, systemImage: "doc.text")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 4)
                }

                if workspace == .live {
                    GroupBox("Planning Center Scenes") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField(
                            "Personal Access Token application ID",
                            text: $model.planningCenterApplicationID
                        )
                        .textFieldStyle(.roundedBorder)
                        SecureField(
                            model.planningCenterCredentialStored
                                ? "Secret saved in Keychain"
                                : "Personal Access Token secret",
                            text: $model.planningCenterSecret
                        )
                        .textFieldStyle(.roundedBorder)
                        TextField(
                            "Service type ID (blank = first)",
                            text: $model.planningCenterServiceTypeID
                        )
                        .textFieldStyle(.roundedBorder)

                        HStack {
                            Button("Save Credentials") {
                                model.savePlanningCenterCredentials()
                            }
                            .disabled(
                                model.planningCenterApplicationID.trimmingCharacters(
                                    in: .whitespacesAndNewlines
                                ).isEmpty ||
                                    model.planningCenterSecret.trimmingCharacters(
                                        in: .whitespacesAndNewlines
                                    ).isEmpty
                            )

                            Button("Refresh Plan") {
                                model.refreshPlanningCenterPlan()
                            }
                            .disabled(!model.planningCenterCredentialStored)

                            if model.planningCenterCredentialStored {
                                Button("Disconnect", role: .destructive) {
                                    model.disconnectPlanningCenter()
                                }
                            }
                        }
                        .font(.caption)

                        Toggle(
                            "Follow timed plan cues",
                            isOn: $model.planningCenterFollowTimedCues
                        )
                        .toggleStyle(.switch)
                        .disabled(
                            !model.planningCenterCredentialStored ||
                                model.planningCenterPlan == nil
                        )
                        .help("Only timed, recognized plan items drive scenes. Manual scene selection, SAFE, FREEZE, and channel overrides remain available.")

                        StatusRow(
                            label: "Plan",
                            value: model.planningCenterStatus,
                            warning: model.planningCenterStatus.localizedCaseInsensitiveContains("failed") ||
                                model.planningCenterStatus.localizedCaseInsensitiveContains("error")
                        )

                        if let plan = model.planningCenterPlan {
                            Text("\(plan.serviceTypeName) · \(plan.title)")
                                .font(.caption.weight(.semibold))
                            Text("\(plan.itemCount) plan items · \(plan.cues.count) recognized scene cues · Plan \(plan.id)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            HStack {
                                Button {
                                    model.previousPlanningCenterCue()
                                } label: {
                                    Label("Previous", systemImage: "backward.end")
                                }
                                Button {
                                    model.advancePlanningCenterCue()
                                } label: {
                                    Label("Next", systemImage: "forward.end")
                                }
                            }
                            .font(.caption)
                            .disabled(plan.cues.isEmpty)

                            ForEach(Array(plan.cues.prefix(16).enumerated()), id: \.element.id) { index, cue in
                                Button {
                                    model.activatePlanningCenterCue(at: index)
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: model.planningCenterCurrentCueIndex == index
                                              ? "play.circle.fill"
                                              : "circle")
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(cue.title)
                                                .lineLimit(1)
                                            Text("\(cue.scene.label)\(planningCenterCueTime(cue))")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                            if plan.cues.count > 16 {
                                Text("+\(plan.cues.count - 16) more cues")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Text("Credentials are stored only in macOS Keychain. Scene changes use the existing smoothed 1–2 second DSP transition path.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                }

                    if let bridge = model.monitorBridge {
                        RemoteMonitoringPanel(model: model, bridge: bridge)
                    }
                }

                if workspace == .setup {
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
                        StatusRow(
                            label: "Callback Age",
                            value: callbackAgeSummary,
                            warning: model.callbackHealthWarning
                        )
                        StatusRow(
                            label: "Output Clock",
                            value: outputClockSummary,
                            warning: model.outputClockWarning
                        )
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

                }

                if workspace == .live {
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

                GroupBox("Livestream Health") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Encoder health URL", text: $model.encoderHealthURL)
                            .textFieldStyle(.roundedBorder)
                        StatusRow(
                            label: "Encoder / Ingest",
                            value: model.encoderHealth.summary,
                            warning: model.encoderHealth.isFailure
                        )
                        TextField("Public egress health URL", text: $model.egressHealthURL)
                            .textFieldStyle(.roundedBorder)
                        StatusRow(
                            label: "Public Egress",
                            value: model.egressHealth.summary,
                            warning: model.egressHealth.isFailure
                        )
                        Text("Use the local OBS bridge for Encoder Health and an offsite playback observer for Public Egress. Each endpoint must return fresh JSON: {\"healthy\":true,\"streaming\":true,\"audioActive\":true,\"timestampMs\":…}. Use token-free health URLs; configured URLs are stored in the local venue profile.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                }

                GroupBox("Continuous Capture") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(
                            "Automatically record when the engine starts",
                            isOn: $model.automaticContinuousRecordingEnabled
                        )
                        .toggleStyle(.switch)

                        Stepper(
                            value: $model.plannedRecordingDurationHours,
                            in: 0.25...12,
                            step: 0.25
                        ) {
                            Text(
                                String(
                                    format: "Planned capture %.2g hours",
                                    model.plannedRecordingDurationHours
                                )
                            )
                        }
                        .font(.caption)

                        Stepper(
                            value: $model.recordingMinimumReserveGB,
                            in: 5...500,
                            step: 5
                        ) {
                            Text(
                                String(
                                    format: "Keep at least %.0f GB free",
                                    model.recordingMinimumReserveGB
                                )
                            )
                        }
                        .font(.caption)

                        Stepper(value: $model.recordingRetentionDays, in: 0...365) {
                            Text(
                                model.recordingRetentionDays == 0
                                    ? "Retention cleanup disabled"
                                    : "Move completed captures older than \(model.recordingRetentionDays) day(s) to Trash"
                            )
                        }
                        .font(.caption)

                        if model.continuousRecordingActive || model.continuousRecordingRequested {
                            Button(role: .cancel) {
                                model.stopContinuousRecording()
                            } label: {
                                Label(
                                    model.continuousRecordingActive
                                        ? "Stop Continuous Recording"
                                        : "Cancel Recording Request",
                                    systemImage: "stop.circle.fill"
                                )
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
                            value: model.continuousRecordingActive
                                ? "recording"
                                : (model.continuousRecordingRequested ? "waiting to record" : "stopped")
                        )
                        StatusRow(
                            label: "Storage",
                            value: model.recordingStorageStatus,
                            warning: recordingStorageWarning
                        )
                        StatusRow(
                            label: "Capacity",
                            value: "\(byteCount(model.recordingAvailableCapacityBytes)) free · \(byteCount(model.recordingEstimatedSessionBytes)) planned"
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
                            Text("Before capture, the app requires enough free space for the planned duration plus the reserve. It rechecks every 30 seconds while recording and stops capture before consuming the reserve. Optional retention moves expired completed sessions to Trash; it never hard-deletes them.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 4)
                }

                }

                if workspace == .validate {
                    GroupBox("Stability Monitor") {
                    VStack(alignment: .leading, spacing: 12) {
                        Stepper(value: $model.stabilityMonitorDurationSeconds, in: 30...14_400, step: 300) {
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
                        if model.stabilityOutputRingTargetFrames > 0 {
                            StatusRow(
                                label: "Clock Correction",
                                value: String(format: "%.0f ppm max", model.stabilityMaxAbsOutputClockCorrectionPpm),
                                warning: model.stabilityMaxAbsOutputClockCorrectionPpm >= 900
                            )
                            StatusRow(
                                label: "Clock Ring",
                                value: "\(model.stabilityMinOutputRingFillFrames)...\(model.stabilityMaxOutputRingFillFrames) / \(model.stabilityOutputRingTargetFrames)",
                                warning: model.stabilityMinOutputRingFillFrames <
                                    max(1, model.stabilityOutputRingTargetFrames / 4) ||
                                    model.stabilityMaxOutputRingFillFrames >
                                    model.stabilityOutputRingTargetFrames * 3
                            )
                        }
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
            }
            .padding(18)
        }
    }

    private var workspaceDescription: String {
        switch workspace {
        case .live:
            "Service operation, stream health, remote control, and continuous capture."
        case .setup:
            "Audio routing, HD96 readiness, and Dante expectations."
        case .validate:
            "Soundcheck, stability monitoring, and hardware-proof artifacts."
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

    private func planningCenterCueTime(_ cue: PlanningCenterSceneCue) -> String {
        guard let startsAt = cue.startsAt else { return " · manual cue" }
        return " · \(startsAt.formatted(date: .omitted, time: .shortened))"
    }

    private var callbackAgeSummary: String {
        guard model.inputCallbackAgeMs >= 0, model.outputCallbackAgeMs >= 0 else {
            return model.isRunning ? "waiting" : "stopped"
        }
        return String(
            format: "input %.1f ms / output %.1f ms",
            model.inputCallbackAgeMs,
            model.outputCallbackAgeMs
        )
    }

    private var outputClockSummary: String {
        guard model.separateOutputPrebufferFrames > 0 else {
            return "shared Core Audio callback"
        }
        return String(
            format: "%+.0f ppm · %d / %d frames",
            model.outputClockCorrectionPpm,
            model.separateOutputRingFillFrames,
            model.separateOutputPrebufferFrames
        )
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

    private var recordingStorageWarning: Bool {
        let status = model.recordingStorageStatus.lowercased()
        return status.contains("insufficient") ||
            status.contains("exceeds") ||
            status.contains("failed") ||
            status.contains("minimum free-space")
    }

    private func byteCount(_ value: Int64) -> String {
        guard value > 0 else { return "unknown" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
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
        case .some(true):
            return "passed"
        case .some(false):
            return "failed"
        case .none:
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
                Toggle(
                    "Stereo → Ch \(channel.index + 2)",
                    isOn: $channel.stereoLinkedToNext
                )
                .toggleStyle(.checkbox)
                .disabled(
                    channel.index + 1 >= inputChannelLimit ||
                        !channel.role.supportsStereoLink
                )
                .help("Links adjacent channel dynamics and automation, with this channel hard left and the next hard right. Manual overrides remain authoritative.")
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
                .frame(maxWidth: 780, alignment: .leading)
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
        VStack(alignment: .leading, spacing: 6) {
            OverrideSliderRow(
                label: "Fader",
                enabled: $channel.faderOverrideEnabled,
                value: $channel.faderDb,
                range: ChannelMapping.faderDbOverrideRange,
                step: 0.5,
                format: "%.1f dB"
            )
            OverrideSliderRow(
                label: "Pan",
                enabled: $channel.panOverrideEnabled,
                value: $channel.pan,
                range: ChannelMapping.panOverrideRange,
                step: 0.05,
                format: "%.2f"
            )

            DisclosureGroup {
                VStack(alignment: .leading, spacing: 10) {
                    OverrideSliderRow(
                        label: "Trim",
                        enabled: $channel.processingOverride.trimOverrideEnabled,
                        value: $channel.processingOverride.trimDb,
                        range: ChannelProcessingOverride.trimDbRange,
                        step: 0.5,
                        format: "%+.1f dB"
                    )
                    OverrideSliderRow(
                        label: "HPF",
                        enabled: $channel.processingOverride.hpfOverrideEnabled,
                        value: $channel.processingOverride.hpfHz,
                        range: ChannelProcessingOverride.hpfHzRange,
                        step: 1,
                        format: "%.0f Hz"
                    )

                    GroupBox("Gate") {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Toggle(
                                    "Override",
                                    isOn: $channel.processingOverride.gateOverrideEnabled
                                )
                                .toggleStyle(.checkbox)
                                Toggle(
                                    "Gate enabled",
                                    isOn: $channel.processingOverride.gateEnabled
                                )
                                .toggleStyle(.checkbox)
                                .disabled(!channel.processingOverride.gateOverrideEnabled)
                            }
                            ParameterSliderRow(
                                label: "Threshold",
                                value: $channel.processingOverride.gateThresholdDb,
                                range: ChannelProcessingOverride.gateThresholdDbRange,
                                step: 0.5,
                                format: "%.1f dB",
                                enabled: channel.processingOverride.gateOverrideEnabled
                            )
                            ParameterSliderRow(
                                label: "Ratio",
                                value: $channel.processingOverride.gateRatio,
                                range: ChannelProcessingOverride.gateRatioRange,
                                step: 0.1,
                                format: "%.1f:1",
                                enabled: channel.processingOverride.gateOverrideEnabled
                            )
                            ParameterSliderRow(
                                label: "Range",
                                value: $channel.processingOverride.gateRangeDb,
                                range: ChannelProcessingOverride.gateRangeDbRange,
                                step: 0.5,
                                format: "%.1f dB",
                                enabled: channel.processingOverride.gateOverrideEnabled
                            )
                        }
                    }

                    GroupBox("Equalizer") {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle(
                                "Override all eight bands",
                                isOn: $channel.processingOverride.eqOverrideEnabled
                            )
                            .toggleStyle(.checkbox)
                            ForEach($channel.processingOverride.eqBands) { $band in
                                HStack(spacing: 8) {
                                    Text(band.slot.label)
                                        .frame(width: 90, alignment: .leading)
                                    Picker("Type", selection: $band.type) {
                                        ForEach(ChannelEQFilterType.allCases) { type in
                                            Text(type.label).tag(type)
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(width: 105)
                                    TextField(
                                        "Hz",
                                        value: $band.frequencyHz,
                                        format: .number.precision(.fractionLength(0))
                                    )
                                    .frame(width: 72)
                                    Text("Hz")
                                    TextField(
                                        "Q",
                                        value: $band.q,
                                        format: .number.precision(.fractionLength(2))
                                    )
                                    .frame(width: 58)
                                    Text("Q")
                                    TextField(
                                        "dB",
                                        value: $band.gainDb,
                                        format: .number.precision(.fractionLength(1))
                                    )
                                    .frame(width: 58)
                                    Text("dB")
                                }
                                .disabled(!channel.processingOverride.eqOverrideEnabled)
                            }
                        }
                    }

                    GroupBox("Compressor") {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle(
                                "Override",
                                isOn: $channel.processingOverride.compressorOverrideEnabled
                            )
                            .toggleStyle(.checkbox)
                            ParameterSliderRow(
                                label: "Threshold",
                                value: $channel.processingOverride.compressorThresholdDb,
                                range: ChannelProcessingOverride.compressorThresholdDbRange,
                                step: 0.5,
                                format: "%.1f dB",
                                enabled: channel.processingOverride.compressorOverrideEnabled
                            )
                            ParameterSliderRow(
                                label: "Ratio",
                                value: $channel.processingOverride.compressorRatio,
                                range: ChannelProcessingOverride.compressorRatioRange,
                                step: 0.1,
                                format: "%.1f:1",
                                enabled: channel.processingOverride.compressorOverrideEnabled
                            )
                            ParameterSliderRow(
                                label: "Attack",
                                value: $channel.processingOverride.compressorAttackSeconds,
                                range: ChannelProcessingOverride.compressorAttackSecondsRange,
                                step: 0.001,
                                format: "%.3f s",
                                enabled: channel.processingOverride.compressorOverrideEnabled
                            )
                            ParameterSliderRow(
                                label: "Release",
                                value: $channel.processingOverride.compressorReleaseSeconds,
                                range: ChannelProcessingOverride.compressorReleaseSecondsRange,
                                step: 0.01,
                                format: "%.2f s",
                                enabled: channel.processingOverride.compressorOverrideEnabled
                            )
                            ParameterSliderRow(
                                label: "Knee",
                                value: $channel.processingOverride.compressorKneeDb,
                                range: ChannelProcessingOverride.compressorKneeDbRange,
                                step: 0.5,
                                format: "%.1f dB",
                                enabled: channel.processingOverride.compressorOverrideEnabled
                            )
                            ParameterSliderRow(
                                label: "Makeup",
                                value: $channel.processingOverride.compressorMakeupDb,
                                range: ChannelProcessingOverride.compressorMakeupDbRange,
                                step: 0.5,
                                format: "%+.1f dB",
                                enabled: channel.processingOverride.compressorOverrideEnabled
                            )
                        }
                    }

                    OverrideSliderRow(
                        label: "Reverb",
                        enabled: $channel.processingOverride.reverbOverrideEnabled,
                        value: $channel.processingOverride.reverbSendDb,
                        range: ChannelProcessingOverride.reverbSendDbRange,
                        step: 0.5,
                        format: "%.1f dB"
                    )

                    Button("Clear all manual overrides") {
                        channel.clearOverrides()
                    }
                    .disabled(!channel.hasAnyManualOverride && !channel.muted)
                }
                .padding(.top, 6)
            } label: {
                Text(
                    "Advanced processing · \(channel.processingOverride.enabledFamilyCount) override(s)"
                )
            }
            .font(.caption)
        }
    }
}

private struct OverrideSliderRow: View {
    let label: String
    @Binding var enabled: Bool
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: String

    var body: some View {
        HStack(spacing: 8) {
            Toggle(label, isOn: $enabled)
                .toggleStyle(.checkbox)
                .frame(width: 82, alignment: .leading)
            Slider(value: $value, in: range, step: step)
                .disabled(!enabled)
            Text(String(format: format, value))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(enabled ? .primary : .secondary)
                .frame(width: 72, alignment: .trailing)
        }
    }
}

private struct ParameterSliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: String
    let enabled: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .frame(width: 72, alignment: .leading)
            Slider(value: $value, in: range, step: step)
                .disabled(!enabled)
            Text(String(format: format, value))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(enabled ? .primary : .secondary)
                .frame(width: 72, alignment: .trailing)
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
