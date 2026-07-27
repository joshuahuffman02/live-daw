import Foundation

enum ChannelRole: String, CaseIterable, Codable, Identifiable, Sendable {
    case unknown
    case speech
    case leadVocal
    case bgv
    case acousticGuitar
    case electricGuitar
    case bass
    case kick
    case keys

    var id: String { rawValue }

    var label: String {
        switch self {
        case .unknown: return "Unknown"
        case .speech: return "Speech"
        case .leadVocal: return "Lead Vocal"
        case .bgv: return "BGV"
        case .acousticGuitar: return "Acoustic"
        case .electricGuitar: return "Electric"
        case .bass: return "Bass"
        case .kick: return "Kick"
        case .keys: return "Keys"
        }
    }
}

enum MixScene: String, CaseIterable, Codable, Identifiable, Sendable {
    case preService
    case worship
    case sermon
    case prayer
    case postService

    var id: String { rawValue }

    var label: String {
        switch self {
        case .preService: return "Pre-Service"
        case .worship: return "Worship"
        case .sermon: return "Sermon"
        case .prayer: return "Prayer"
        case .postService: return "Post-Service"
        }
    }
}

struct ChannelMapping: Codable, Identifiable, Equatable, Sendable {
    static let faderDbOverrideRange: ClosedRange<Double> = -80.0...12.0
    static let panOverrideRange: ClosedRange<Double> = -1.0...1.0

    var index: Int
    var inputChannelIndex: Int
    var name: String
    var role: ChannelRole
    var faderOverrideEnabled: Bool
    var faderDb: Double
    var panOverrideEnabled: Bool
    var pan: Double
    // Remote-console mute, layered on the existing fader override (no DSP change):
    // mute forces a fader override at the -80 dB floor; unmute restores the prior
    // fader state captured here. Persisted so a muted channel survives a restart.
    var muted: Bool = false
    var preMuteFaderDb: Double = -6.0
    var preMuteFaderOverrideEnabled: Bool = false

    var id: Int { index }

    init(index: Int, inputChannelIndex: Int? = nil, name: String, role: ChannelRole, faderOverrideEnabled: Bool = false, faderDb: Double = -6.0, panOverrideEnabled: Bool = false, pan: Double = 0.0) {
        self.index = index
        self.inputChannelIndex = max(inputChannelIndex ?? index, 0)
        self.name = name
        self.role = role
        self.faderOverrideEnabled = faderOverrideEnabled
        self.faderDb = faderDb
        self.panOverrideEnabled = panOverrideEnabled
        self.pan = pan
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decode(Int.self, forKey: .index)
        inputChannelIndex = max(try container.decodeIfPresent(Int.self, forKey: .inputChannelIndex) ?? index, 0)
        name = try container.decode(String.self, forKey: .name)
        role = try container.decode(ChannelRole.self, forKey: .role)
        faderOverrideEnabled = try container.decodeIfPresent(Bool.self, forKey: .faderOverrideEnabled) ?? false
        faderDb = try container.decodeIfPresent(Double.self, forKey: .faderDb) ?? -6.0
        panOverrideEnabled = try container.decodeIfPresent(Bool.self, forKey: .panOverrideEnabled) ?? false
        pan = try container.decodeIfPresent(Double.self, forKey: .pan) ?? 0.0
        muted = try container.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        preMuteFaderDb = try container.decodeIfPresent(Double.self, forKey: .preMuteFaderDb) ?? faderDb
        preMuteFaderOverrideEnabled = try container.decodeIfPresent(Bool.self, forKey: .preMuteFaderOverrideEnabled) ?? false
    }

    // Toggle remote mute. Idempotent: re-muting does not overwrite the captured
    // prior fader state, so unmute always returns to the operator's real setting.
    mutating func setMuted(_ on: Bool) {
        if on {
            guard !muted else { return }
            preMuteFaderDb = faderDb
            preMuteFaderOverrideEnabled = faderOverrideEnabled
            muted = true
            faderOverrideEnabled = true
            faderDb = ChannelMapping.faderDbOverrideRange.lowerBound
        } else {
            guard muted else { return }
            muted = false
            faderDb = preMuteFaderDb
            faderOverrideEnabled = preMuteFaderOverrideEnabled
        }
    }

    // Drop all manual intervention: fader override, pan override, and mute. Restores
    // the pre-mute fader value so a cleared-while-muted channel does not leave the
    // -80 dB floor in persisted state / telemetry.
    mutating func clearOverrides() {
        if muted {
            faderDb = preMuteFaderDb
        }
        muted = false
        faderOverrideEnabled = false
        panOverrideEnabled = false
    }

    static func defaults(count: Int) -> [ChannelMapping] {
        (0..<count).map { index in
            ChannelMapping(index: index, name: "Ch \(index + 1)", role: .unknown)
        }
    }

    static func serviceRoleTemplate(count: Int) -> [ChannelMapping] {
        let boundedCount = min(max(count, 0), 64)
        return (0..<boundedCount).map { index in
            let role = serviceRole(for: index)
            return ChannelMapping(
                index: index,
                name: serviceName(for: index, role: role),
                role: role
            )
        }
    }

    static func applyingServiceRoleTemplate(
        to mappings: [ChannelMapping],
        count: Int
    ) -> [ChannelMapping] {
        let template = serviceRoleTemplate(count: count)
        return template.enumerated().map { index, seeded in
            guard mappings.indices.contains(index) else { return seeded }
            var channel = mappings[index]
            channel.index = index
            channel.name = seeded.name
            channel.role = seeded.role
            return channel
        }
    }

    func boundedInputChannelIndex(maxInputChannels: Int) -> Int {
        let upperBound = max(maxInputChannels - 1, 0)
        return min(max(inputChannelIndex, 0), upperBound)
    }

    static func orderedForMixerRows(
        _ mappings: [ChannelMapping],
        mixerChannelCount: Int
    ) -> [ChannelMapping] {
        let count = min(max(mixerChannelCount, 0), 64)
        guard count > 0 else { return [] }

        var ordered = defaults(count: count)
        for mapping in mappings where mapping.index >= 0 && mapping.index < count {
            ordered[mapping.index] = mapping
            ordered[mapping.index].index = mapping.index
        }
        return ordered
    }

    static func inputChannelIndexNumbers(
        for mappings: [ChannelMapping],
        mixerChannelCount: Int,
        maxInputChannels: Int
    ) -> [NSNumber] {
        orderedForMixerRows(mappings, mixerChannelCount: mixerChannelCount).map { mapping in
            NSNumber(value: mapping.boundedInputChannelIndex(maxInputChannels: maxInputChannels))
        }
    }

    private static func serviceRole(for index: Int) -> ChannelRole {
        let seed: [ChannelRole] = [
            .speech,
            .speech,
            .speech,
            .leadVocal,
            .bgv,
            .bgv,
            .bgv,
            .acousticGuitar,
            .electricGuitar,
            .electricGuitar,
            .keys,
            .keys,
            .bass,
            .kick,
            .speech,
            .keys
        ]
        return seed[index % seed.count]
    }

    private static func serviceName(for index: Int, role: ChannelRole) -> String {
        switch role {
        case .speech:
            return ["Pastor", "Host", "Lectern", "Speech Spare"][(index / 2) % 4]
        case .leadVocal:
            return "Lead Vocal"
        case .bgv:
            return "BGV \((index % 3) + 1)"
        case .acousticGuitar:
            return "Acoustic"
        case .electricGuitar:
            return "Electric \((index % 2) + 1)"
        case .bass:
            return "Bass"
        case .kick:
            return "Kick"
        case .keys:
            return "Keys \((index % 2) + 1)"
        case .unknown:
            return "Ch \(index + 1)"
        }
    }
}

struct ChannelMapCoverage: Equatable, Sendable {
    var inputChannelCount: Int
    var uniqueMappedInputCount: Int
    var duplicateInputChannels: [Int]
    var missingInputChannels: [Int]
    var duplicateMixerChannels: [Int]
    var missingMixerChannels: [Int]
    var outOfRangeMixerChannels: [Int]

    var isReady: Bool {
        inputChannelCount > 0 &&
            uniqueMappedInputCount == inputChannelCount &&
            duplicateInputChannels.isEmpty &&
            missingInputChannels.isEmpty &&
            duplicateMixerChannels.isEmpty &&
            missingMixerChannels.isEmpty &&
            outOfRangeMixerChannels.isEmpty
    }

    var summary: String {
        guard inputChannelCount > 0 else { return "input device unknown" }
        if isReady { return "\(uniqueMappedInputCount)/\(inputChannelCount) Dante inputs mapped once" }

        var parts: [String] = ["\(uniqueMappedInputCount)/\(inputChannelCount) unique"]
        if !duplicateInputChannels.isEmpty {
            parts.append("duplicate \(Self.channelList(duplicateInputChannels, label: "Dante In"))")
        }
        if !missingInputChannels.isEmpty {
            parts.append("missing \(Self.channelList(missingInputChannels, label: "Dante In"))")
        }
        if !duplicateMixerChannels.isEmpty {
            parts.append("duplicate \(Self.channelList(duplicateMixerChannels, label: "Mix Ch"))")
        }
        if !missingMixerChannels.isEmpty {
            parts.append("missing \(Self.channelList(missingMixerChannels, label: "Mix Ch"))")
        }
        if !outOfRangeMixerChannels.isEmpty {
            parts.append("out-of-range \(Self.channelList(outOfRangeMixerChannels, label: "Mix Ch"))")
        }
        return parts.joined(separator: "; ")
    }

    static func make(channelMappings: [ChannelMapping], inputChannelCount: Int) -> ChannelMapCoverage {
        let count = max(inputChannelCount, 0)
        guard count > 0 else {
            return ChannelMapCoverage(
                inputChannelCount: 0,
                uniqueMappedInputCount: 0,
                duplicateInputChannels: [],
                missingInputChannels: [],
                duplicateMixerChannels: [],
                missingMixerChannels: [],
                outOfRangeMixerChannels: channelMappings.map(\.index)
            )
        }

        var inputOccurrences = Array(repeating: 0, count: count)
        var mixerOccurrences = Array(repeating: 0, count: count)
        var outOfRangeMixerChannels: [Int] = []

        for mapping in channelMappings {
            let mixerIndex = mapping.index
            let inputIndex = mapping.inputChannelIndex
            var outOfRange = false

            if mixerIndex >= 0 && mixerIndex < count {
                mixerOccurrences[mixerIndex] += 1
            } else {
                outOfRange = true
            }

            if inputIndex >= 0 && inputIndex < count {
                inputOccurrences[inputIndex] += 1
            } else {
                outOfRange = true
            }

            if outOfRange {
                outOfRangeMixerChannels.append(mapping.index)
            }
        }

        let duplicateInputChannels = inputOccurrences.enumerated()
            .filter { $0.element > 1 }
            .map { $0.offset }
        let missingInputChannels = inputOccurrences.enumerated()
            .filter { $0.element == 0 }
            .map { $0.offset }
        let duplicateMixerChannels = mixerOccurrences.enumerated()
            .filter { $0.element > 1 }
            .map { $0.offset }
        let missingMixerChannels = mixerOccurrences.enumerated()
            .filter { $0.element == 0 }
            .map { $0.offset }
        let uniqueMappedInputCount = inputOccurrences.filter { $0 > 0 }.count

        return ChannelMapCoverage(
            inputChannelCount: count,
            uniqueMappedInputCount: uniqueMappedInputCount,
            duplicateInputChannels: duplicateInputChannels,
            missingInputChannels: missingInputChannels,
            duplicateMixerChannels: duplicateMixerChannels,
            missingMixerChannels: missingMixerChannels,
            outOfRangeMixerChannels: outOfRangeMixerChannels
        )
    }

    private static func channelList(_ zeroBasedChannels: [Int], label: String, limit: Int = 6) -> String {
        let visible = zeroBasedChannels.prefix(limit).map { "\($0 + 1)" }.joined(separator: ", ")
        let suffix = zeroBasedChannels.count > limit ? ", +" + "\(zeroBasedChannels.count - limit)" : ""
        return "\(label) \(visible)\(suffix)"
    }
}

struct SourceRoleCoverage: Equatable, Sendable {
    var channelCount: Int
    var assignedRoleCount: Int
    var speechRoleCount: Int
    var musicRoleCount: Int
    var unknownRoleCount: Int

    var isReady: Bool {
        channelCount > 0 && assignedRoleCount > 0
    }

    var summary: String {
        guard channelCount > 0 else { return "no mapped channels" }
        if isReady {
            return "\(assignedRoleCount)/\(channelCount) assigned · speech \(speechRoleCount) · music \(musicRoleCount) · unknown \(unknownRoleCount)"
        }
        return "0/\(channelCount) assigned; set source roles before autonomous mix"
    }

    static func make(channelMappings: [ChannelMapping]) -> SourceRoleCoverage {
        let channelCount = channelMappings.count
        var speechRoleCount = 0
        var musicRoleCount = 0
        var unknownRoleCount = 0

        for mapping in channelMappings {
            switch mapping.role {
            case .unknown:
                unknownRoleCount += 1
            case .speech:
                speechRoleCount += 1
            case .leadVocal, .bgv, .acousticGuitar, .electricGuitar, .bass, .kick, .keys:
                musicRoleCount += 1
            }
        }

        return SourceRoleCoverage(
            channelCount: channelCount,
            assignedRoleCount: speechRoleCount + musicRoleCount,
            speechRoleCount: speechRoleCount,
            musicRoleCount: musicRoleCount,
            unknownRoleCount: unknownRoleCount
        )
    }
}

struct ManualOverrideCoverage: Equatable, Sendable {
    var channelCount: Int
    var faderOverrideCount: Int
    var panOverrideCount: Int
    var invalidOverrideChannels: [Int]

    var isReady: Bool {
        invalidOverrideChannels.isEmpty
    }

    var summary: String {
        var parts: [String] = []
        if faderOverrideCount == 0 && panOverrideCount == 0 {
            parts.append("none enabled")
        } else {
            parts.append("fader \(faderOverrideCount)")
            parts.append("pan \(panOverrideCount)")
        }
        if !invalidOverrideChannels.isEmpty {
            parts.append("invalid \(Self.channelList(invalidOverrideChannels, label: "Mix Ch"))")
        }
        return parts.joined(separator: " · ")
    }

    static func make(channelMappings: [ChannelMapping]) -> ManualOverrideCoverage {
        var faderOverrideCount = 0
        var panOverrideCount = 0
        var invalidOverrideChannels: [Int] = []

        for mapping in channelMappings {
            var invalid = false
            if mapping.faderOverrideEnabled {
                faderOverrideCount += 1
                invalid = invalid || !ChannelMapping.faderDbOverrideRange.contains(mapping.faderDb)
            }
            if mapping.panOverrideEnabled {
                panOverrideCount += 1
                invalid = invalid || !ChannelMapping.panOverrideRange.contains(mapping.pan)
            }
            if invalid {
                invalidOverrideChannels.append(mapping.index)
            }
        }

        return ManualOverrideCoverage(
            channelCount: channelMappings.count,
            faderOverrideCount: faderOverrideCount,
            panOverrideCount: panOverrideCount,
            invalidOverrideChannels: invalidOverrideChannels
        )
    }

    private static func channelList(_ zeroBasedChannels: [Int], label: String, limit: Int = 6) -> String {
        let visible = zeroBasedChannels.prefix(limit).map { "\($0 + 1)" }.joined(separator: ", ")
        let suffix = zeroBasedChannels.count > limit ? ", +" + "\(zeroBasedChannels.count - limit)" : ""
        return "\(label) \(visible)\(suffix)"
    }
}

struct VenueProfile: Codable, Sendable {
    var inputDeviceUID: String
    var outputDeviceUID: String
    var scene: MixScene
    var shadowMode: Bool
    var measuredEndToEndAudioLatencyMs: Double
    var measuredEndToEndVideoLatencyMs: Double
    var encoderHealthURL: String
    var egressHealthURL: String
    var expectedInputChannels: Int
    var expectedSampleRate: Double
    var channelMappings: [ChannelMapping]

    init(inputDeviceUID: String, outputDeviceUID: String, scene: MixScene = .worship, shadowMode: Bool = true, measuredEndToEndAudioLatencyMs: Double = 0, measuredEndToEndVideoLatencyMs: Double = 0, encoderHealthURL: String = "", egressHealthURL: String = "", expectedInputChannels: Int = 64, expectedSampleRate: Double = 96000, channelMappings: [ChannelMapping]) {
        self.inputDeviceUID = inputDeviceUID
        self.outputDeviceUID = outputDeviceUID
        self.scene = scene
        self.shadowMode = shadowMode
        self.measuredEndToEndAudioLatencyMs = min(max(measuredEndToEndAudioLatencyMs, 0), 1_000)
        self.measuredEndToEndVideoLatencyMs = min(max(measuredEndToEndVideoLatencyMs, 0), 1_000)
        self.encoderHealthURL = encoderHealthURL
        self.egressHealthURL = egressHealthURL
        self.expectedInputChannels = min(max(expectedInputChannels, 1), 64)
        self.expectedSampleRate = BroadcastSampleRate.nearestSupported(expectedSampleRate)
        self.channelMappings = Self.normalizedChannelMappingsIfReady(
            channelMappings,
            expectedInputChannels: self.expectedInputChannels
        )
    }

    static func serviceRoleTemplate(
        inputDeviceUID: String,
        outputDeviceUID: String,
        expectedInputChannels: Int = 64,
        scene: MixScene = .worship
    ) -> VenueProfile {
        let boundedInputChannels = min(max(expectedInputChannels, 1), 64)
        return VenueProfile(
            inputDeviceUID: inputDeviceUID,
            outputDeviceUID: outputDeviceUID,
            scene: scene,
            expectedInputChannels: boundedInputChannels,
            channelMappings: ChannelMapping.serviceRoleTemplate(count: boundedInputChannels)
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputDeviceUID = try container.decode(String.self, forKey: .inputDeviceUID)
        outputDeviceUID = try container.decode(String.self, forKey: .outputDeviceUID)
        scene = try container.decodeIfPresent(MixScene.self, forKey: .scene) ?? .worship
        shadowMode = try container.decodeIfPresent(Bool.self, forKey: .shadowMode) ?? true
        measuredEndToEndAudioLatencyMs = min(
            max(try container.decodeIfPresent(Double.self, forKey: .measuredEndToEndAudioLatencyMs) ?? 0, 0),
            1_000
        )
        measuredEndToEndVideoLatencyMs = min(
            max(try container.decodeIfPresent(Double.self, forKey: .measuredEndToEndVideoLatencyMs) ?? 0, 0),
            1_000
        )
        encoderHealthURL = try container.decodeIfPresent(String.self, forKey: .encoderHealthURL) ?? ""
        egressHealthURL = try container.decodeIfPresent(String.self, forKey: .egressHealthURL) ?? ""
        expectedInputChannels = min(max(try container.decodeIfPresent(Int.self, forKey: .expectedInputChannels) ?? 64, 1), 64)
        expectedSampleRate = BroadcastSampleRate.nearestSupported(try container.decodeIfPresent(Double.self, forKey: .expectedSampleRate) ?? 96000)
        let decodedMappings = try container.decode([ChannelMapping].self, forKey: .channelMappings)
        channelMappings = Self.normalizedChannelMappingsIfReady(
            decodedMappings,
            expectedInputChannels: expectedInputChannels
        )
    }

    private static func normalizedChannelMappingsIfReady(
        _ mappings: [ChannelMapping],
        expectedInputChannels: Int
    ) -> [ChannelMapping] {
        guard !mappings.isEmpty else { return mappings }
        let coverage = ChannelMapCoverage.make(
            channelMappings: mappings,
            inputChannelCount: expectedInputChannels
        )
        guard coverage.isReady else { return mappings }
        return ChannelMapping.orderedForMixerRows(
            mappings,
            mixerChannelCount: expectedInputChannels
        )
    }
}
