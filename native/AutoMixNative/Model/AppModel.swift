import AVFoundation
import Foundation
import Security
import SwiftUI

extension ChannelMapping {
    var hasAnyManualOverride: Bool {
        faderOverrideEnabled ||
            panOverrideEnabled ||
            processingOverride.enabledFamilyCount > 0
    }

    func makeNativeProcessingOverride() -> AMChannelProcessingOverride {
        let processing = processingOverride
        let settings = AMChannelProcessingOverride()
        var rawMask: UInt = 0
        if processing.trimOverrideEnabled { rawMask |= 1 << 0 }
        if processing.hpfOverrideEnabled { rawMask |= 1 << 1 }
        if processing.gateOverrideEnabled { rawMask |= 1 << 2 }
        if processing.eqOverrideEnabled { rawMask |= 1 << 3 }
        if processing.compressorOverrideEnabled { rawMask |= 1 << 4 }
        if faderOverrideEnabled { rawMask |= 1 << 5 }
        if panOverrideEnabled { rawMask |= 1 << 6 }
        if processing.reverbOverrideEnabled { rawMask |= 1 << 7 }
        settings.overrideMask = AMChannelOverrideMask(rawValue: rawMask)
        settings.trimDb = processing.trimDb
        settings.hpfHz = processing.hpfHz
        settings.gateEnabled = processing.gateEnabled
        settings.gateThresholdDb = processing.gateThresholdDb
        settings.gateRatio = processing.gateRatio
        settings.gateRangeDb = processing.gateRangeDb

        let defaultBands = ChannelProcessingOverride.defaultEQBands
        let orderedBands = ChannelEQBandSlot.allCases.map { slot in
            processing.eqBands.first(where: { $0.slot == slot }) ??
                defaultBands.first(where: { $0.slot == slot })!
        }
        settings.eqTypes = orderedBands.map(\.type.rawValue)
        settings.eqFrequenciesHz = orderedBands.map { NSNumber(value: $0.frequencyHz) }
        settings.eqQs = orderedBands.map { NSNumber(value: $0.q) }
        settings.eqGainsDb = orderedBands.map { NSNumber(value: $0.gainDb) }
        settings.compressorThresholdDb = processing.compressorThresholdDb
        settings.compressorRatio = processing.compressorRatio
        settings.compressorAttackSeconds = processing.compressorAttackSeconds
        settings.compressorReleaseSeconds = processing.compressorReleaseSeconds
        settings.compressorKneeDb = processing.compressorKneeDb
        settings.compressorMakeupDb = processing.compressorMakeupDb
        settings.faderDb = min(
            max(faderDb, Self.faderDbOverrideRange.lowerBound),
            Self.faderDbOverrideRange.upperBound
        )
        settings.pan = min(max(pan, Self.panOverrideRange.lowerBound), Self.panOverrideRange.upperBound)
        settings.reverbSendDb = processing.reverbSendDb
        return settings
    }
}

struct ManualOverrideApplicationSummary: Equatable, Sendable {
    var requestedCount: Int
    var appliedCount: Int
    var failedMixerChannels: [Int]

    var isComplete: Bool {
        requestedCount == appliedCount && failedMixerChannels.isEmpty
    }

    var failureDescription: String {
        let channels = failedMixerChannels
            .map { "Mix Ch \($0 + 1)" }
            .joined(separator: ", ")
        return channels.isEmpty
            ? "manual override application was incomplete"
            : "manual override application failed for \(channels)"
    }
}

enum ManualOverrideApplier {
    static func apply(
        _ mappings: [ChannelMapping],
        to bridge: AutoMixEngineBridge,
        includeClearOperations: Bool = false
    ) -> ManualOverrideApplicationSummary {
        var requestedCount = 0
        var appliedCount = 0
        var failedMixerChannels: [Int] = []

        for mapping in mappings
        where includeClearOperations || mapping.hasAnyManualOverride {
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

        return ManualOverrideApplicationSummary(
            requestedCount: requestedCount,
            appliedCount: appliedCount,
            failedMixerChannels: failedMixerChannels
        )
    }

    static func applyForValidation(
        _ mappings: [ChannelMapping],
        to bridge: AutoMixEngineBridge
    ) -> ManualOverrideApplicationSummary {
        let summary = apply(mappings, to: bridge)
        if !summary.isComplete {
            bridge.stop()
        }
        return summary
    }
}

struct PlanningCenterCredentials: Codable, Equatable, Sendable {
    var applicationID: String
    var secret: String
}

enum PlanningCenterCredentialStore {
    private static let service = "com.livedaw.automixnative.planning-center"
    private static let account = "personal-access-token"

    static func load() -> PlanningCenterCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return try? JSONDecoder().decode(PlanningCenterCredentials.self, from: data)
    }

    static func save(_ credentials: PlanningCenterCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = identity
            add.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw PlanningCenterError.keychain(addStatus)
            }
        } else if status != errSecSuccess {
            throw PlanningCenterError.keychain(status)
        }
    }

    static func remove() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PlanningCenterError.keychain(status)
        }
    }
}

enum PlanningCenterError: LocalizedError, Equatable {
    case invalidCredentials
    case invalidServiceTypeID
    case http(Int)
    case invalidResponse
    case noServiceTypes
    case noPlans
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "Enter a Planning Center Personal Access Token application ID and secret."
        case .invalidServiceTypeID:
            return "Planning Center service type ID contains unsupported characters."
        case let .http(status):
            return "Planning Center returned HTTP \(status)."
        case .invalidResponse:
            return "Planning Center returned an unreadable response."
        case .noServiceTypes:
            return "No Planning Center Services service types were found."
        case .noPlans:
            return "No future or recent Planning Center plan was found."
        case let .keychain(status):
            return "Could not update Planning Center credentials in Keychain (OSStatus \(status))."
        }
    }
}

struct PlanningCenterSceneCue: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var title: String
    var scene: MixScene
    var startsAt: Date?
    var sequence: Int
}

struct PlanningCenterPlan: Codable, Equatable, Sendable {
    var id: String
    var title: String
    var serviceTypeID: String
    var serviceTypeName: String
    var itemCount: Int
    var cues: [PlanningCenterSceneCue]
}

enum PlanningCenterSceneMapper {
    static func scene(
        title: String,
        itemType: String? = nil,
        servicePosition: String? = nil
    ) -> MixScene? {
        switch servicePosition?.lowercased() {
        case "pre":
            return .preService
        case "post":
            return .postService
        default:
            break
        }
        let normalized = "\(itemType ?? "") \(title)"
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()

        if containsAny(normalized, [
            "pre-service", "preservice", "prelude", "countdown", "doors", "walk-in"
        ]) {
            return .preService
        }
        if containsAny(normalized, [
            "post-service", "postservice", "postlude", "dismissal", "walk-out", "walkout"
        ]) {
            return .postService
        }
        if containsAny(normalized, [
            "message", "sermon", "teaching", "homily", "scripture", "bible reading",
            "welcome", "announcement", "offering"
        ]) {
            return .sermon
        }
        if containsAny(normalized, [
            "prayer", "intercession", "altar", "response", "communion"
        ]) {
            return .prayer
        }
        if containsAny(normalized, [
            "song", "worship", "praise", "music", "hymn", "special"
        ]) {
            return .worship
        }
        return nil
    }

    private static func containsAny(_ value: String, _ candidates: [String]) -> Bool {
        candidates.contains { value.contains($0) }
    }

    static func cues(
        itemResources: [[String: Any]],
        includedResources: [[String: Any]],
        now: Date
    ) -> [PlanningCenterSceneCue] {
        var includedByID: [String: [String: Any]] = [:]
        for resource in includedResources {
            if let id = string(resource["id"]) {
                includedByID[id] = resource
            }
        }

        return itemResources.compactMap { resource -> PlanningCenterSceneCue? in
            guard let id = string(resource["id"]) else { return nil }
            let attributes = self.attributes(resource)
            let title = (attributes["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ??
                (attributes["description"] as? String).flatMap { $0.isEmpty ? nil : $0 } ??
                "Plan Item"
            let itemType = attributes["item_type"] as? String
            let servicePosition = attributes["service_position"] as? String
            guard let scene = scene(
                title: title,
                itemType: itemType,
                servicePosition: servicePosition
            ) else { return nil }
            let sequence = int(attributes["sequence"]) ?? Int.max
            let itemTimes = relationshipIDs(resource, name: "item_times")
                .compactMap { includedByID[$0] }
                .compactMap { itemTime -> Date? in
                    let itemTimeAttributes = self.attributes(itemTime)
                    guard itemTimeAttributes["exclude"] as? Bool != true else { return nil }
                    let value = itemTimeAttributes["live_start_at"] as? String ??
                        itemTimeAttributes["starts_at"] as? String
                    return value.flatMap(parseDate)
                }
            let serviceWindowStart = now.addingTimeInterval(-4 * 60 * 60)
            let startsAt = itemTimes.filter { $0 >= serviceWindowStart }.min() ?? itemTimes.max()
            return PlanningCenterSceneCue(
                id: id,
                title: title,
                scene: scene,
                startsAt: startsAt,
                sequence: sequence
            )
        }
        .sorted {
            if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
            return ($0.startsAt ?? .distantFuture) < ($1.startsAt ?? .distantFuture)
        }
    }

    private static func string(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func attributes(_ resource: [String: Any]) -> [String: Any] {
        resource["attributes"] as? [String: Any] ?? [:]
    }

    private static func relationshipIDs(_ resource: [String: Any], name: String) -> [String] {
        guard let relationships = resource["relationships"] as? [String: Any],
              let relationship = relationships[name] as? [String: Any],
              let data = relationship["data"]
        else { return [] }
        if let one = data as? [String: Any], let id = string(one["id"]) {
            return [id]
        }
        return (data as? [[String: Any]] ?? []).compactMap { string($0["id"]) }
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

actor PlanningCenterAPIClient {
    private let credentials: PlanningCenterCredentials
    private let session: URLSession
    private let baseURL: URL

    init(
        credentials: PlanningCenterCredentials,
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://api.planningcenteronline.com/services/v2/")!
    ) {
        self.credentials = credentials
        self.session = session
        self.baseURL = baseURL
    }

    func fetchPlan(serviceTypeID explicitServiceTypeID: String?) async throws -> PlanningCenterPlan {
        guard !credentials.applicationID.isEmpty, !credentials.secret.isEmpty else {
            throw PlanningCenterError.invalidCredentials
        }

        let serviceTypeID: String
        let serviceTypeName: String
        if let explicit = explicitServiceTypeID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            guard Self.validID(explicit) else { throw PlanningCenterError.invalidServiceTypeID }
            serviceTypeID = explicit
            let types = try await resources(path: "service_types?per_page=100")
            serviceTypeName = types.data.first(where: { Self.string($0["id"]) == explicit })
                .flatMap { Self.attributes($0)["name"] as? String } ?? "Service Type \(explicit)"
        } else {
            let types = try await resources(path: "service_types?per_page=100")
            guard let first = types.data.first,
                  let id = Self.string(first["id"])
            else { throw PlanningCenterError.noServiceTypes }
            serviceTypeID = id
            serviceTypeName = Self.attributes(first)["name"] as? String ?? "Service Type \(id)"
        }

        var plans = try await resources(
            path: "service_types/\(serviceTypeID)/plans?filter=future&per_page=1&order=sort_date",
            maxPages: 1
        )
        if plans.data.isEmpty {
            plans = try await resources(
                path: "service_types/\(serviceTypeID)/plans?per_page=1&order=-sort_date",
                maxPages: 1
            )
        }
        guard let planResource = plans.data.first,
              let planID = Self.string(planResource["id"])
        else { throw PlanningCenterError.noPlans }
        let planAttributes = Self.attributes(planResource)
        let planTitle = (planAttributes["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ??
            (planAttributes["dates"] as? String).flatMap { $0.isEmpty ? nil : $0 } ??
            "Plan \(planID)"

        let items = try await resources(
            path: "service_types/\(serviceTypeID)/plans/\(planID)/items?per_page=100&include=item_times"
        )
        let cues = PlanningCenterSceneMapper.cues(
            itemResources: items.data,
            includedResources: items.included,
            now: Date()
        )

        return PlanningCenterPlan(
            id: planID,
            title: planTitle,
            serviceTypeID: serviceTypeID,
            serviceTypeName: serviceTypeName,
            itemCount: items.data.count,
            cues: cues
        )
    }

    private struct Resources {
        var data: [[String: Any]]
        var included: [[String: Any]]
    }

    private func resources(path: String, maxPages: Int = 100) async throws -> Resources {
        guard let firstURL = URL(string: path, relativeTo: baseURL) else {
            throw PlanningCenterError.invalidResponse
        }
        var nextURL: URL? = firstURL
        var allData: [[String: Any]] = []
        var allIncluded: [[String: Any]] = []
        var pageCount = 0

        while let url = nextURL, pageCount < maxPages {
            guard url.scheme == baseURL.scheme, url.host == baseURL.host else {
                throw PlanningCenterError.invalidResponse
            }
            let page = try await resourcePage(url: url)
            allData.append(contentsOf: page.data)
            allIncluded.append(contentsOf: page.included)
            nextURL = page.next
            pageCount += 1
        }

        return Resources(data: allData, included: allIncluded)
    }

    private func resourcePage(url: URL) async throws -> (
        data: [[String: Any]],
        included: [[String: Any]],
        next: URL?
    ) {
        var request = URLRequest(url: url)
        let token = Data("\(credentials.applicationID):\(credentials.secret)".utf8)
            .base64EncodedString()
        request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PlanningCenterError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw PlanningCenterError.http(http.statusCode)
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resources = root["data"] as? [[String: Any]]
        else {
            throw PlanningCenterError.invalidResponse
        }
        let nextString = (root["links"] as? [String: Any])?["next"] as? String
        let nextURL = nextString.flatMap { URL(string: $0, relativeTo: url) }
        return (
            data: resources,
            included: root["included"] as? [[String: Any]] ?? [],
            next: nextURL
        )
    }

    private static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0)
        }
    }

    private static func string(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func attributes(_ resource: [String: Any]) -> [String: Any] {
        resource["attributes"] as? [String: Any] ?? [:]
    }

}

struct ContinuousRecordingStorageEstimate: Equatable, Sendable {
    static let bytesPerSample = 4.0
    static let programChannelCount = 2

    var inputChannelCount: Int
    var sampleRate: Double
    var plannedDurationHours: Double
    var minimumReserveBytes: Int64

    var recordingBytes: Int64 {
        let bytes = Double(max(inputChannelCount, 0) + Self.programChannelCount) *
            max(sampleRate, 0) *
            Self.bytesPerSample *
            max(plannedDurationHours, 0) *
            3_600
        return Int64(min(bytes.rounded(.up), Double(Int64.max)))
    }

    var requiredFreeBytes: Int64 {
        let (sum, overflow) = recordingBytes.addingReportingOverflow(max(minimumReserveBytes, 0))
        return overflow ? Int64.max : sum
    }

    func canStart(availableBytes: Int64) -> Bool {
        availableBytes >= requiredFreeBytes
    }
}

struct ContinuousRecordingStorageReport: Equatable, Sendable {
    var availableBytes: Int64
    var estimate: ContinuousRecordingStorageEstimate
    var movedToTrashCount: Int

    var canStart: Bool {
        estimate.canStart(availableBytes: availableBytes)
    }

    func decision(
        recordingActive: Bool,
        recordingRequested: Bool
    ) -> ContinuousRecordingStorageDecision {
        if recordingActive {
            return availableBytes < estimate.minimumReserveBytes
                ? .stopForMinimumReserve
                : .continueRecording
        }
        guard recordingRequested else { return .idle }
        return canStart ? .startRecording : .waitForCapacity
    }
}

enum ContinuousRecordingStorageDecision: Equatable, Sendable {
    case idle
    case waitForCapacity
    case startRecording
    case continueRecording
    case stopForMinimumReserve
}

enum ContinuousRecordingStorageError: LocalizedError, Equatable {
    case capacityUnavailable

    var errorDescription: String? {
        switch self {
        case .capacityUnavailable:
            return "Could not verify free recording capacity."
        }
    }
}

actor ContinuousRecordingStorageManager {
    static let completionMarkerName = ".automix-session-complete.json"

    func inspect(
        root: URL,
        estimate: ContinuousRecordingStorageEstimate,
        retentionDays: Int,
        applyRetention: Bool,
        availableCapacityOverrideBytes: Int64? = nil,
        now: Date = Date()
    ) throws -> ContinuousRecordingStorageReport {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        var movedToTrashCount = 0

        if applyRetention, retentionDays > 0 {
            for child in try retentionCandidates(
                root: root,
                retentionDays: retentionDays,
                now: now
            ) {
                try Task.checkCancellation()
                var trashedURL: NSURL?
                try fileManager.trashItem(at: child, resultingItemURL: &trashedURL)
                movedToTrashCount += 1
            }
        }

        let availableBytes: Int64
        if let availableCapacityOverrideBytes {
            availableBytes = max(availableCapacityOverrideBytes, 0)
        } else {
            let attributes = try fileManager.attributesOfFileSystem(forPath: root.path)
            guard let freeNumber = attributes[.systemFreeSize] as? NSNumber else {
                throw ContinuousRecordingStorageError.capacityUnavailable
            }
            availableBytes = freeNumber.int64Value
        }
        return ContinuousRecordingStorageReport(
            availableBytes: availableBytes,
            estimate: estimate,
            movedToTrashCount: movedToTrashCount
        )
    }

    func retentionCandidates(
        root: URL,
        retentionDays: Int,
        now: Date = Date()
    ) throws -> [URL] {
        guard retentionDays > 0 else { return [] }
        let fileManager = FileManager.default
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .contentModificationDateKey,
            .creationDateKey,
            .isHiddenKey
        ]
        return try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants]
        )
        .filter { child in
            let values = try child.resourceValues(forKeys: keys)
            return values.isDirectory == true &&
                values.isHidden != true &&
                fileManager.fileExists(
                    atPath: child
                        .appendingPathComponent(Self.completionMarkerName, isDirectory: false)
                        .path
                ) &&
                (values.contentModificationDate ?? values.creationDate ?? .distantFuture) < cutoff
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

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
    @Published var expectedSampleRate: Double = 96000 {
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
    @Published private(set) var continuousRecordingRequested = false
    @Published var automaticContinuousRecordingEnabled = true {
        didSet { saveProfile() }
    }
    @Published var plannedRecordingDurationHours = 3.0 {
        didSet {
            let clamped = min(max(plannedRecordingDurationHours, 0.25), 12)
            if plannedRecordingDurationHours != clamped {
                plannedRecordingDurationHours = clamped
                return
            }
            nextRecordingStorageCheckMs = 0
            saveProfile()
        }
    }
    @Published var recordingMinimumReserveGB = 20.0 {
        didSet {
            let clamped = min(max(recordingMinimumReserveGB, 5), 500)
            if recordingMinimumReserveGB != clamped {
                recordingMinimumReserveGB = clamped
                return
            }
            nextRecordingStorageCheckMs = 0
            saveProfile()
        }
    }
    @Published var recordingRetentionDays = 0 {
        didSet {
            let clamped = min(max(recordingRetentionDays, 0), 365)
            if recordingRetentionDays != clamped {
                recordingRetentionDays = clamped
                return
            }
            saveProfile()
        }
    }
    @Published private(set) var recordingStorageStatus = "not checked"
    @Published private(set) var recordingAvailableCapacityBytes: Int64 = 0
    @Published private(set) var recordingEstimatedSessionBytes: Int64 = 0
    @Published private(set) var recordingSessions: [RecordingSession] = []
    @Published var selectedRecordingSessionID: UUID?
    @Published var nextRecordingSessionName = ""
    @Published var nextRecordingSessionNotes = ""
    @Published private(set) var recordingSessionLibraryStatus = "loading sessions"
    @Published private(set) var recordingSessionActionInProgress = false
    @Published private(set) var recordingPreviewSessionID: UUID?
    @Published private(set) var recordingPreviewAssetID: UUID?
    @Published private(set) var recordingPreviewPlaying = false
    @Published private(set) var lastReplayRequestURL: URL?
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
    @Published var planningCenterApplicationID = ""
    @Published var planningCenterSecret = ""
    @Published var planningCenterServiceTypeID = "" {
        didSet {
            if oldValue != planningCenterServiceTypeID {
                planningCenterPlan = nil
                planningCenterCurrentCueIndex = nil
                nextPlanningCenterRefreshMs = 0
            }
            saveProfile()
        }
    }
    @Published var planningCenterFollowTimedCues = false {
        didSet {
            saveProfile()
            guard !loadingProfile else { return }
            if planningCenterFollowTimedCues {
                refreshPlanningCenterPlan()
            } else {
                planningCenterStatus = planningCenterPlan == nil ? "not following" : "plan loaded · manual"
            }
        }
    }
    @Published private(set) var planningCenterCredentialStored = false
    @Published private(set) var planningCenterStatus = "not connected"
    @Published private(set) var planningCenterPlan: PlanningCenterPlan?
    @Published private(set) var planningCenterCurrentCueIndex: Int?
    @Published var stabilityMonitorDurationSeconds = 300.0 {
        didSet {
            let clamped = min(max(stabilityMonitorDurationSeconds, 30.0), 14_400.0)
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
    @Published private(set) var shadowDecisionLogURL: URL?
    @Published private(set) var shadowDecisionCaptureStatus = "idle"
    @Published private(set) var shadowDecisionRecordCount = 0
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
                if engine.running {
                    if shadowMode {
                        startShadowDecisionCaptureIfNeeded(
                            nowMs: Int64(Date().timeIntervalSince1970 * 1_000)
                        )
                    } else {
                        finishShadowDecisionCapture(reason: "SHADOW disabled")
                    }
                }
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
    private var shadowDecisionJournal: ShadowDecisionJournal?
    private var shadowDecisionWriteTask: Task<Void, Never>?
    private var shadowDecisionWriteFailureSessionIDs = Set<String>()
    private var shadowDecisionSessionID = ""
    private var shadowDecisionStartedAtMs: Int64 = 0
    private var shadowDecisionLastSnapshotMs: Int64 = 0
    private let recordingStorageManager = ContinuousRecordingStorageManager()
    private var recordingStorageTask: Task<Void, Never>?
    private let recordingSessionLibrary = RecordingSessionLibrary()
    private var recordingSessionLibraryTask: Task<Void, Never>?
    private var recordingPreviewPlayer: AVPlayer?
    private var recordingPreviewEndObserver: NSObjectProtocol?
    private var activeRecordingSessionID: UUID?
    private var pendingRecordingContinuationID: UUID?
    private var nextRecordingStorageCheckMs: Int64 = 0
    private var previousContinuousRecordingActive = false
    private var lastRecordingStorageIncidentKey: String?
    private var recordingAvailableCapacityOverrideBytesForTesting: Int64?
    private let streamHealthProbe = StreamHealthProbe()
    private var streamHealthTask: Task<Void, Never>?
    private var nextStreamHealthProbeMs: Int64 = 0
    private var resumingAutonomousSession = false
    private var planningCenterCredentials: PlanningCenterCredentials?
    private var planningCenterTask: Task<Void, Never>?
    private var nextPlanningCenterRefreshMs: Int64 = 0
    private var planningCenterLastAppliedCueID: String?
    private var previousRecordingDroppedFrameCount: UInt = 0
    private var previousOutputClockWarning = false
    private var previousWatchdogSafeActive = false
    private var previousRuntimeRouteHealthy = true
    private var manualOverrideApplicationFailed = false

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
        loadPlanningCenterCredentials()
        refreshDevices()
        refreshAudioInputPermission()
        startPolling()
        monitorBridge = MonitorBridge(appModel: self)
        remoteMonitoringEnabled = autoStartRemoteMonitoring
        refreshRecordingSessions()
        resumeAutonomousSessionIfNeeded()
        if planningCenterFollowTimedCues {
            refreshPlanningCenterPlan()
        }
    }

    private func applyRemoteMonitoringState() {
        guard let monitorBridge else { return }
        if remoteMonitoringEnabled {
            monitorBridge.start()
        } else {
            monitorBridge.stop()
        }
    }

    func savePlanningCenterCredentials() {
        let credentials = PlanningCenterCredentials(
            applicationID: planningCenterApplicationID.trimmingCharacters(in: .whitespacesAndNewlines),
            secret: planningCenterSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !credentials.applicationID.isEmpty, !credentials.secret.isEmpty else {
            planningCenterStatus = PlanningCenterError.invalidCredentials.localizedDescription
            return
        }
        do {
            try PlanningCenterCredentialStore.save(credentials)
            planningCenterCredentials = credentials
            planningCenterCredentialStored = true
            planningCenterSecret = ""
            planningCenterStatus = "credentials saved in Keychain"
            refreshPlanningCenterPlan()
        } catch {
            planningCenterStatus = error.localizedDescription
        }
    }

    func disconnectPlanningCenter() {
        do {
            try PlanningCenterCredentialStore.remove()
        } catch {
            planningCenterStatus = error.localizedDescription
            return
        }
        planningCenterTask?.cancel()
        planningCenterTask = nil
        planningCenterCredentials = nil
        planningCenterCredentialStored = false
        planningCenterApplicationID = ""
        planningCenterSecret = ""
        planningCenterPlan = nil
        planningCenterCurrentCueIndex = nil
        planningCenterLastAppliedCueID = nil
        planningCenterFollowTimedCues = false
        planningCenterStatus = "disconnected"
    }

    func refreshPlanningCenterPlan() {
        guard planningCenterTask == nil else { return }
        guard let credentials = planningCenterCredentials else {
            planningCenterStatus = "save Planning Center credentials first"
            return
        }
        planningCenterStatus = "loading service plan"
        let serviceTypeID = planningCenterServiceTypeID
        let client = PlanningCenterAPIClient(credentials: credentials)
        planningCenterTask = Task { [weak self] in
            do {
                let plan = try await client.fetchPlan(serviceTypeID: serviceTypeID)
                guard !Task.isCancelled else { return }
                self?.finishPlanningCenterRefresh(plan: plan)
            } catch {
                guard !Task.isCancelled else { return }
                self?.finishPlanningCenterRefresh(error: error)
            }
        }
    }

    func activatePlanningCenterCue(at index: Int) {
        guard let plan = planningCenterPlan, plan.cues.indices.contains(index) else { return }
        applyPlanningCenterCue(plan.cues[index], index: index, source: "operator")
    }

    func advancePlanningCenterCue() {
        guard let plan = planningCenterPlan, !plan.cues.isEmpty else { return }
        let next = min((planningCenterCurrentCueIndex ?? -1) + 1, plan.cues.count - 1)
        activatePlanningCenterCue(at: next)
    }

    func previousPlanningCenterCue() {
        guard let plan = planningCenterPlan, !plan.cues.isEmpty else { return }
        let previous = max((planningCenterCurrentCueIndex ?? 1) - 1, 0)
        activatePlanningCenterCue(at: previous)
    }

    private func loadPlanningCenterCredentials() {
        guard let credentials = PlanningCenterCredentialStore.load() else { return }
        planningCenterCredentials = credentials
        planningCenterApplicationID = credentials.applicationID
        planningCenterCredentialStored = true
        planningCenterStatus = "credentials loaded from Keychain"
    }

    private func finishPlanningCenterRefresh(plan: PlanningCenterPlan) {
        planningCenterTask = nil
        planningCenterServiceTypeID = plan.serviceTypeID
        planningCenterPlan = plan
        nextPlanningCenterRefreshMs = Int64(Date().timeIntervalSince1970 * 1_000) + 300_000
        planningCenterStatus = plan.cues.isEmpty
            ? "\(plan.title) · \(plan.itemCount) items · no recognized scene cues"
            : "\(plan.title) · \(plan.itemCount) items · \(plan.cues.count) scene cues"
        recordPlanningCenterPlanLoaded(plan)
        updatePlanningCenterScene(now: Date())
    }

    private func recordPlanningCenterPlanLoaded(_ plan: PlanningCenterPlan) {
        recordRuntimeIncident(
            kind: "planning-center-plan-loaded",
            severity: .info,
            message: "\(plan.title) loaded from Planning Center",
            details: [
                "planID": plan.id,
                "serviceTypeID": plan.serviceTypeID,
                "itemCount": "\(plan.itemCount)",
                "cueCount": "\(plan.cues.count)"
            ]
        )
    }

    private func finishPlanningCenterRefresh(error: Error) {
        planningCenterTask = nil
        nextPlanningCenterRefreshMs = Int64(Date().timeIntervalSince1970 * 1_000) + 60_000
        planningCenterStatus = error.localizedDescription
        recordRuntimeIncident(
            kind: "planning-center-refresh-failed",
            severity: .warning,
            message: error.localizedDescription,
            details: ["serviceTypeID": planningCenterServiceTypeID]
        )
    }

    private func updatePlanningCenterScene(now: Date) {
        guard planningCenterFollowTimedCues, let plan = planningCenterPlan else { return }
        let eligible = plan.cues.enumerated().filter { _, cue in
            guard let startsAt = cue.startsAt else { return false }
            return startsAt <= now
        }
        guard let latest = eligible.max(by: {
            ($0.element.startsAt ?? .distantPast) < ($1.element.startsAt ?? .distantPast)
        }) else { return }
        guard latest.element.id != planningCenterLastAppliedCueID else { return }
        applyPlanningCenterCue(latest.element, index: latest.offset, source: "timed plan")
    }

    private func applyPlanningCenterCue(
        _ cue: PlanningCenterSceneCue,
        index: Int,
        source: String
    ) {
        planningCenterCurrentCueIndex = index
        if source == "timed plan" {
            planningCenterLastAppliedCueID = cue.id
        }
        selectedScene = cue.scene
        planningCenterStatus = "\(cue.title) → \(cue.scene.label) · \(source)"
        recordRuntimeIncident(
            kind: "planning-center-scene-applied",
            severity: .info,
            message: "\(cue.title) mapped to \(cue.scene.label)",
            details: [
                "planID": planningCenterPlan?.id ?? "",
                "cueID": cue.id,
                "cueIndex": "\(index)",
                "scene": cue.scene.rawValue,
                "source": source
            ]
        )
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

    var primaryAudioHeartbeatRouteHealth: PrimaryAudioHeartbeatRouteHealth {
        PrimaryAudioHeartbeatRouteHealth.make(
            inputDevice: engine.runningInputDeviceInfo(),
            outputDevice: engine.runningOutputDeviceInfo(),
            selectedInputUID: selectedInputUID,
            selectedOutputUID: selectedOutputUID,
            detectedInputChannels: engine.inputChannelCount,
            detectedSampleRate: engine.sampleRate
        )
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

    var stereoLinkCoverage: StereoLinkCoverage {
        StereoLinkCoverage.make(channelMappings: channelMappings)
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
            applyAllStereoLinks()
            try requireAllManualOverridesApplied(context: "Core Audio engine start")
            statusText = engine.status
            nextStreamHealthProbeMs = 0
            armAutomaticRecoveryAfterSuccessfulStart(nowMs: Int64(Date().timeIntervalSince1970 * 1_000))
            if resumingAutonomousSession && continuousRecordingRequested {
                resumeContinuousRecordingAfterRecovery(nowMs: Int64(Date().timeIntervalSince1970 * 1_000))
            } else if automaticContinuousRecordingEnabled {
                continuousRecordingRequested = true
                nextRecordingStorageCheckMs = 0
                saveAutonomousSessionIntent()
            }
            recordRuntimeIncident(
                kind: resumingAutonomousSession ? "engine-resumed-after-relaunch" : "engine-started",
                severity: .info,
                message: resumingAutonomousSession
                    ? "Core Audio engine resumed from the autonomous-session marker"
                    : "Core Audio engine started",
                details: runtimeRouteDetails()
            )
            startShadowDecisionCaptureIfNeeded(
                nowMs: Int64(Date().timeIntervalSince1970 * 1_000)
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
        recordingStorageTask?.cancel()
        recordingStorageTask = nil
        nextRecordingStorageCheckMs = 0
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
        finishShadowDecisionCapture(reason: "operator stopped engine")
        cancelStabilityMonitor()
        let wasContinuouslyRecording = engine.continuousRecording
        engine.stop()
        if wasContinuouslyRecording {
            markContinuousRecordingSessionComplete()
        }
        runningInRehearsal = false
        runningRouteSnapshot = nil
        pollEngine()
        refreshRecordingSessions()
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

        continuousRecordingRequested = true
        nextRecordingStorageCheckMs = 0
        saveAutonomousSessionIntent()
        updateRecordingStorage(nowMs: Int64(Date().timeIntervalSince1970 * 1_000))
    }

    func stopContinuousRecording() {
        continuousRecordingRequested = false
        recordingStorageTask?.cancel()
        recordingStorageTask = nil
        nextRecordingStorageCheckMs = 0
        recordingStorageStatus = "stopped by operator"
        saveAutonomousSessionIntent()
        let wasContinuouslyRecording = engine.continuousRecording
        engine.stopContinuousRecording()
        if wasContinuouslyRecording {
            markContinuousRecordingSessionComplete()
        }
        pollEngine()
        refreshRecordingSessions()
    }

    var selectedRecordingSession: RecordingSession? {
        guard let selectedRecordingSessionID else { return nil }
        return recordingSessions.first { $0.id == selectedRecordingSessionID }
    }

    func refreshRecordingSessions(selecting sessionID: UUID? = nil) {
        recordingSessionLibraryTask?.cancel()
        recordingSessionLibraryTask = Task { [weak self] in
            guard let self else { return }
            do {
                let root = try continuousRecordingRootDirectory()
                let activeDirectory = engine.continuousRecording
                    ? continuousRecordingDirectoryURL
                    : nil
                let sessions = try await recordingSessionLibrary.load(
                    root: root,
                    activeDirectory: activeDirectory
                )
                guard !Task.isCancelled else { return }
                recordingSessions = sessions
                if let sessionID, sessions.contains(where: { $0.id == sessionID }) {
                    selectedRecordingSessionID = sessionID
                } else if let selectedRecordingSessionID,
                          sessions.contains(where: { $0.id == selectedRecordingSessionID }) {
                    self.selectedRecordingSessionID = selectedRecordingSessionID
                } else {
                    selectedRecordingSessionID = sessions.first?.id
                }
                recordingSessionLibraryStatus = sessions.isEmpty
                    ? "No sessions yet"
                    : "\(sessions.count) session\(sessions.count == 1 ? "" : "s")"
            } catch is CancellationError {
                return
            } catch {
                recordingSessionLibraryStatus = "Session scan failed · \(error.localizedDescription)"
                lastError = error.localizedDescription
            }
            recordingSessionLibraryTask = nil
        }
    }

    func importRecordingFiles(_ urls: [URL], name: String? = nil) {
        guard !urls.isEmpty, !recordingSessionActionInProgress else { return }
        guard !engine.continuousRecording, !continuousRecordingRequested else {
            lastError = "Stop the live capture before importing recordings."
            recordingSessionLibraryStatus = "Import paused while recording"
            return
        }
        let securityScopedURLs = urls.filter { $0.startAccessingSecurityScopedResource() }
        recordingSessionActionInProgress = true
        recordingSessionLibraryStatus = "Importing \(urls.count) file\(urls.count == 1 ? "" : "s")…"
        Task { [weak self] in
            guard let self else { return }
            defer {
                securityScopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
                recordingSessionActionInProgress = false
            }
            do {
                let root = try continuousRecordingRootDirectory()
                let session = try await recordingSessionLibrary.importFiles(
                    urls,
                    root: root,
                    name: name
                )
                recordingSessionLibraryStatus = "Imported \(session.assets.count) file\(session.assets.count == 1 ? "" : "s")"
                refreshRecordingSessions(selecting: session.id)
            } catch {
                lastError = error.localizedDescription
                recordingSessionLibraryStatus = "Import failed · \(error.localizedDescription)"
            }
        }
    }

    func recordingFileImporterFailed(_ error: Error) {
        lastError = error.localizedDescription
        recordingSessionLibraryStatus = "Import failed · \(error.localizedDescription)"
    }

    func updateRecordingSession(sessionID: UUID, name: String, notes: String) {
        guard !recordingSessionActionInProgress else { return }
        recordingSessionActionInProgress = true
        Task { [weak self] in
            guard let self else { return }
            defer { recordingSessionActionInProgress = false }
            do {
                let root = try continuousRecordingRootDirectory()
                _ = try await recordingSessionLibrary.update(
                    sessionID: sessionID,
                    root: root,
                    activeDirectory: engine.continuousRecording ? continuousRecordingDirectoryURL : nil,
                    name: name,
                    notes: notes
                )
                recordingSessionLibraryStatus = "Session details saved"
                refreshRecordingSessions(selecting: sessionID)
            } catch {
                lastError = error.localizedDescription
                recordingSessionLibraryStatus = "Save failed · \(error.localizedDescription)"
            }
        }
    }

    func moveRecordingSessionToTrash(_ sessionID: UUID) {
        guard !recordingSessionActionInProgress else { return }
        recordingSessionActionInProgress = true
        stopRecordingPreview()
        Task { [weak self] in
            guard let self else { return }
            defer { recordingSessionActionInProgress = false }
            do {
                let root = try continuousRecordingRootDirectory()
                try await recordingSessionLibrary.moveToTrash(
                    sessionID: sessionID,
                    root: root,
                    activeDirectory: engine.continuousRecording ? continuousRecordingDirectoryURL : nil
                )
                recordingSessionLibraryStatus = "Session moved to Trash"
                selectedRecordingSessionID = nil
                refreshRecordingSessions()
            } catch {
                lastError = error.localizedDescription
                recordingSessionLibraryStatus = "Could not move session · \(error.localizedDescription)"
            }
        }
    }

    func toggleRecordingPreview(_ sessionID: UUID) {
        if recordingPreviewSessionID == sessionID, recordingPreviewPlayer != nil {
            if recordingPreviewPlaying {
                recordingPreviewPlayer?.pause()
                recordingPreviewPlaying = false
            } else {
                recordingPreviewPlayer?.play()
                recordingPreviewPlaying = true
            }
            return
        }
        guard !recordingSessionActionInProgress,
              let session = recordingSessions.first(where: { $0.id == sessionID }),
              session.status != .recording
        else { return }
        let requiresDerivedRender = session.origin == .liveCapture &&
            !session.assets.contains(where: { $0.kind == .programPreview && $0.validationError == nil })
        guard !continuousRecordingActive || !requiresDerivedRender else {
            lastError = "Generate this program preview after the active live capture stops."
            recordingSessionLibraryStatus = "Preview render paused while recording"
            return
        }
        stopRecordingPreview()
        recordingSessionActionInProgress = true
        recordingSessionLibraryStatus = "Preparing program preview…"
        Task { [weak self] in
            guard let self else { return }
            defer { recordingSessionActionInProgress = false }
            do {
                let url = try await recordingSessionLibrary.renderProgramPreview(session: session)
                startRecordingPreview(
                    url: url,
                    sessionID: sessionID,
                    assetID: nil,
                    status: "Playing program preview"
                )
                refreshRecordingSessions(selecting: sessionID)
            } catch {
                lastError = error.localizedDescription
                recordingSessionLibraryStatus = "Preview failed · \(error.localizedDescription)"
            }
        }
    }

    func toggleRecordingAssetPreview(sessionID: UUID, assetID: UUID) {
        if recordingPreviewSessionID == sessionID,
           recordingPreviewAssetID == assetID,
           recordingPreviewPlayer != nil {
            if recordingPreviewPlaying {
                recordingPreviewPlayer?.pause()
                recordingPreviewPlaying = false
            } else {
                recordingPreviewPlayer?.play()
                recordingPreviewPlaying = true
            }
            return
        }
        guard !recordingSessionActionInProgress,
              let session = recordingSessions.first(where: { $0.id == sessionID }),
              session.status != .recording,
              let asset = session.assets.first(where: { $0.id == assetID }),
              asset.isPlayable
        else { return }
        let url = session.directoryURL.appendingPathComponent(asset.relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            lastError = RecordingSessionLibraryError.fileMissing(asset.displayName).localizedDescription
            return
        }
        stopRecordingPreview()
        startRecordingPreview(
            url: url,
            sessionID: sessionID,
            assetID: assetID,
            status: "Playing \(asset.displayName)"
        )
    }

    private func startRecordingPreview(
        url: URL,
        sessionID: UUID,
        assetID: UUID?,
        status: String
    ) {
        stopRecordingPreview()
        let player = AVPlayer(url: url)
        recordingPreviewPlayer = player
        recordingPreviewSessionID = sessionID
        recordingPreviewAssetID = assetID
        recordingPreviewPlaying = true
        recordingSessionLibraryStatus = status
        recordingPreviewEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.recordingPreviewPlaying = false
                self?.recordingPreviewPlayer?.seek(to: .zero)
            }
        }
        player.play()
    }

    func stopRecordingPreview() {
        if let recordingPreviewEndObserver {
            NotificationCenter.default.removeObserver(recordingPreviewEndObserver)
            self.recordingPreviewEndObserver = nil
        }
        recordingPreviewPlayer?.pause()
        recordingPreviewPlayer = nil
        recordingPreviewSessionID = nil
        recordingPreviewAssetID = nil
        recordingPreviewPlaying = false
    }

    func continueRecordingSession(_ sessionID: UUID) {
        guard let session = recordingSessions.first(where: { $0.id == sessionID }) else {
            lastError = RecordingSessionLibraryError.sessionNotFound.localizedDescription
            return
        }
        guard session.status != .recording else { return }
        pendingRecordingContinuationID = session.id
        nextRecordingSessionName = "\(session.name) · continuation"
        nextRecordingSessionNotes = session.notes
        startContinuousRecording()
    }

    func prepareReplayRequest(_ sessionID: UUID) {
        guard let session = recordingSessions.first(where: { $0.id == sessionID }) else {
            lastError = RecordingSessionLibraryError.sessionNotFound.localizedDescription
            return
        }
        guard session.status != .recording else {
            lastError = "Stop and finalize this recording before preparing replay."
            return
        }
        let segments = session.assets
            .filter { $0.kind == .captureSegment && $0.validationError == nil }
            .sorted { $0.relativePath < $1.relativePath }
        guard !segments.isEmpty else {
            lastError = "Replay rendering requires a native multitrack capture session."
            return
        }
        guard let roles = session.channelRoles,
              let sourceChannelCount = segments.first?.channelCount,
              sourceChannelCount == roles.count + 2,
              let scene = session.scene,
              !scene.isEmpty
        else {
            lastError = "This capture does not contain a trustworthy saved scene/role map matching its multitrack channels. Use the manual replay CLI after verifying the legacy session map."
            return
        }
        do {
            let derived = session.directoryURL.appendingPathComponent("Derived", isDirectory: true)
            try FileManager.default.createDirectory(at: derived, withIntermediateDirectories: true)
            let url = derived.appendingPathComponent("Replay Request.json")
            let payload: [String: Any] = [
                "schemaVersion": 1,
                "sessionID": session.id.uuidString,
                "sessionName": session.name,
                "scene": scene,
                "roles": roles,
                "stereoPairs": session.stereoPairs ?? [],
                "inputs": segments.map { session.directoryURL.appendingPathComponent($0.relativePath).path },
                "outputDirectory": derived.path,
                "createdAtMs": Int64(Date().timeIntervalSince1970 * 1_000)
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            lastReplayRequestURL = url
            recordingSessionLibraryStatus = "Replay request prepared"
            refreshRecordingSessions(selecting: sessionID)
        } catch {
            lastError = error.localizedDescription
            recordingSessionLibraryStatus = "Replay request failed · \(error.localizedDescription)"
        }
    }

    @discardableResult
    func channelDidChange(_ channel: ChannelMapping) -> Bool {
        synchronizeStereoPairAfterEdit(channelIndex: channel.index)
        for mappedChannel in channelMappings {
            applyInputChannelMap(mappedChannel)
            applyChannelRole(mappedChannel)
        }
        applyAllStereoLinks()
        let manualSummary = applyAllManualOverrides()
        saveProfile()
        return manualSummary.isComplete
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
        }
        applyAllStereoLinks()
        applyAllManualOverrides()
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
        let duration = min(max(seconds ?? stabilityMonitorDurationSeconds, 30.0), 14_400.0)
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
        captureShadowDecisionSnapshot(nowMs: nowMs)
        updateRuntimeIncidentTransitions(nowMs: nowMs)
        updateAutomaticRecovery(nowMs: nowMs)
        updateRecordingStorage(nowMs: nowMs)
        updateStreamHealthMonitoring(nowMs: nowMs)
        updatePlanningCenterScene(now: Date(timeIntervalSince1970: Double(nowMs) / 1_000))
        if planningCenterFollowTimedCues,
           planningCenterTask == nil,
           nowMs >= nextPlanningCenterRefreshMs {
            refreshPlanningCenterPlan()
        }
        monitorBridge?.captureAndPublish(nowMs: nowMs)
    }

    private func updateRecordingStorage(nowMs: Int64) {
        let isActive = engine.continuousRecording
        if previousContinuousRecordingActive,
           !isActive,
           continuousRecordingRequested {
            recordRuntimeIncident(
                timestampMs: nowMs,
                kind: "continuous-recording-stopped-unexpectedly",
                severity: .critical,
                message: "Continuous recording stopped while capture was still requested",
                details: [
                    "recordingDirectory": continuousRecordingDirectoryURL?.path ?? "",
                    "droppedFrames": "\(engine.continuousRecordingDroppedFrameCount)"
                ]
            )
            nextRecordingStorageCheckMs = 0
        }
        previousContinuousRecordingActive = isActive

        guard engine.running,
              recordingStorageTask == nil,
              nowMs >= nextRecordingStorageCheckMs
        else { return }

        let inputChannels = max(engine.inputChannelCount, detectedInputChannels, 1)
        let sampleRate = engine.sampleRate > 0
            ? engine.sampleRate
            : max(detectedSampleRate, expectedSampleRate)
        let reserveBytes = Int64(
            min(
                (recordingMinimumReserveGB * 1_000_000_000).rounded(.up),
                Double(Int64.max)
            )
        )
        let estimate = ContinuousRecordingStorageEstimate(
            inputChannelCount: inputChannels,
            sampleRate: sampleRate,
            plannedDurationHours: plannedRecordingDurationHours,
            minimumReserveBytes: reserveBytes
        )
        recordingEstimatedSessionBytes = estimate.recordingBytes
        let shouldStart = continuousRecordingRequested && !isActive
        let root: URL
        do {
            root = try continuousRecordingRootDirectory()
        } catch {
            finishRecordingStorageCheck(error: error, nowMs: nowMs)
            return
        }

        recordingStorageStatus = shouldStart ? "checking before capture" : "checking capacity"
        recordingStorageTask = Task { [weak self] in
            guard let self else { return }
            do {
                let report = try await recordingStorageManager.inspect(
                    root: root,
                    estimate: estimate,
                    retentionDays: recordingRetentionDays,
                    applyRetention: shouldStart,
                    availableCapacityOverrideBytes: recordingAvailableCapacityOverrideBytesForTesting
                )
                guard !Task.isCancelled else { return }
                finishRecordingStorageCheck(
                    report: report,
                    nowMs: nowMs
                )
            } catch is CancellationError {
                recordingStorageTask = nil
            } catch {
                finishRecordingStorageCheck(error: error, nowMs: nowMs)
            }
        }
    }

    private func finishRecordingStorageCheck(
        report: ContinuousRecordingStorageReport,
        nowMs: Int64
    ) {
        recordingStorageTask = nil
        recordingAvailableCapacityBytes = report.availableBytes
        recordingEstimatedSessionBytes = report.estimate.recordingBytes

        if report.movedToTrashCount > 0 {
            recordRuntimeIncident(
                timestampMs: nowMs,
                kind: "recording-retention-cleanup",
                severity: .info,
                message: "Moved \(report.movedToTrashCount) expired recording session(s) to Trash",
                details: ["retentionDays": "\(recordingRetentionDays)"]
            )
        }

        switch report.decision(
            recordingActive: engine.continuousRecording,
            recordingRequested: continuousRecordingRequested
        ) {
        case .stopForMinimumReserve:
            continuousRecordingRequested = false
            saveAutonomousSessionIntent()
            engine.stopContinuousRecording()
            markContinuousRecordingSessionComplete()
            recordingStorageStatus = "stopped · minimum free-space reserve reached"
            recordRuntimeIncident(
                timestampMs: nowMs,
                kind: "recording-stopped-low-space",
                severity: .critical,
                message: "Continuous recording stopped before exhausting the storage volume",
                details: [
                    "availableBytes": "\(report.availableBytes)",
                    "minimumReserveBytes": "\(report.estimate.minimumReserveBytes)",
                    "recordingDirectory": continuousRecordingDirectoryURL?.path ?? ""
                ]
            )
            nextRecordingStorageCheckMs = nowMs + 60_000
            pollEngine()
            refreshRecordingSessions()
            return

        case .continueRecording:
            recordingStorageStatus = "recording · capacity monitored"
            lastRecordingStorageIncidentKey = nil
            nextRecordingStorageCheckMs = nowMs + 30_000
            return

        case .idle:
            recordingStorageStatus = report.canStart
                ? "ready for planned capture"
                : "planned capture exceeds free capacity"
            nextRecordingStorageCheckMs = nowMs + 60_000
            return

        case .waitForCapacity:
            recordingStorageStatus = "waiting · insufficient space for planned capture + reserve"
            recordRecordingStorageIncidentOnce(
                key: "insufficient-capacity",
                nowMs: nowMs,
                kind: "recording-start-blocked-low-space",
                severity: .critical,
                message: "Continuous recording is requested but the planned capture does not fit",
                details: [
                    "availableBytes": "\(report.availableBytes)",
                    "plannedRecordingBytes": "\(report.estimate.recordingBytes)",
                    "minimumReserveBytes": "\(report.estimate.minimumReserveBytes)"
                ]
            )
            nextRecordingStorageCheckMs = nowMs + 60_000
            return

        case .startRecording:
            break
        }

        guard engine.running,
              !engine.recording,
              !engine.recordingSaveInProgress,
              !soundcheckReportInProgress
        else {
            recordingStorageStatus = "waiting for audio/soundcheck state"
            nextRecordingStorageCheckMs = nowMs + 5_000
            return
        }

        do {
            let directory = try nextContinuousRecordingDirectory()
            let sessionName = defaultRecordingSessionName()
            let stereoPairs = channelMappings
                .filter(\.stereoLinkedToNext)
                .map { "\($0.index + 1)-\($0.index + 2)" }
            let session = try RecordingSessionLibrary.bootstrapCaptureSession(
                directory: directory,
                name: sessionName,
                notes: nextRecordingSessionNotes,
                scene: selectedScene.rawValue,
                channelRoles: channelMappings.map(\.role.rawValue),
                stereoPairs: stereoPairs,
                continuedFromSessionID: pendingRecordingContinuationID
            )
            do {
                try engine.startContinuousRecording(atDirectoryURL: directory)
            } catch {
                removeUnusedRecordingSessionDirectory(directory)
                throw error
            }
            continuousRecordingDirectoryURL = directory
            activeRecordingSessionID = session.id
            pendingRecordingContinuationID = nil
            nextRecordingSessionName = ""
            nextRecordingSessionNotes = ""
            previousContinuousRecordingActive = true
            recordingStorageStatus = "recording · capacity gate passed"
            lastRecordingStorageIncidentKey = nil
            nextRecordingStorageCheckMs = nowMs + 30_000
            saveAutonomousSessionIntent()
            recordRuntimeIncident(
                timestampMs: nowMs,
                kind: "continuous-recording-started",
                severity: .info,
                message: "Continuous raw-input and program capture started",
                details: [
                    "recordingDirectory": directory.path,
                    "availableBytes": "\(report.availableBytes)",
                    "plannedRecordingBytes": "\(report.estimate.recordingBytes)"
                ]
            )
            pollEngine()
            refreshRecordingSessions(selecting: session.id)
        } catch {
            recordingStorageStatus = "start failed · \(error.localizedDescription)"
            recordRecordingStorageIncidentOnce(
                key: "recording-start-failed",
                nowMs: nowMs,
                kind: "recording-start-failed",
                severity: .critical,
                message: error.localizedDescription,
                details: runtimeRouteDetails()
            )
            nextRecordingStorageCheckMs = nowMs + 60_000
        }
    }

    private func finishRecordingStorageCheck(error: Error, nowMs: Int64) {
        recordingStorageTask = nil
        recordingStorageStatus = "capacity check failed · \(error.localizedDescription)"
        recordRecordingStorageIncidentOnce(
            key: "capacity-check-failed",
            nowMs: nowMs,
            kind: "recording-capacity-check-failed",
            severity: .critical,
            message: error.localizedDescription,
            details: [:]
        )
        nextRecordingStorageCheckMs = nowMs + 60_000
    }

    private func recordRecordingStorageIncidentOnce(
        key: String,
        nowMs: Int64,
        kind: String,
        severity: AlertSeverity,
        message: String,
        details: [String: String]
    ) {
        guard lastRecordingStorageIncidentKey != key else { return }
        lastRecordingStorageIncidentKey = key
        recordRuntimeIncident(
            timestampMs: nowMs,
            kind: kind,
            severity: severity,
            message: message,
            details: details
        )
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
            async let encoderResult = probe.probe(
                urlString: encoderURL,
                nowMs: nowMs,
                role: .encoder
            )
            async let egressResult = probe.probe(
                urlString: egressURL,
                nowMs: nowMs,
                role: .egress
            )
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
        let wasContinuouslyRecording = engine.continuousRecording
        engine.stop()
        if wasContinuouslyRecording {
            markContinuousRecordingSessionComplete()
        }
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
            applyAllStereoLinks()
            try requireAllManualOverridesApplied(context: "automatic audio recovery")
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
        continuousRecordingRequested = true
        nextRecordingStorageCheckMs = 0
        recordingStorageStatus = "checking before recovery capture resumes"
        saveAutonomousSessionIntent()
        updateRecordingStorage(nowMs: nowMs)
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

    private func startShadowDecisionCaptureIfNeeded(nowMs: Int64) {
        guard engine.running, shadowMode, shadowDecisionJournal == nil else { return }

        do {
            let directory = try appSupportDirectory()
                .appendingPathComponent("Shadow Decisions", isDirectory: true)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            let sessionID = UUID().uuidString.lowercased()
            let fileName = "shadow-decisions-\(formatter.string(from: Date()))-\(sessionID.prefix(8)).jsonl"
            let journal = try ShadowDecisionJournal(directory: directory, fileName: fileName)
            shadowDecisionJournal = journal
            shadowDecisionSessionID = sessionID
            shadowDecisionStartedAtMs = nowMs
            shadowDecisionLastSnapshotMs = 0
            shadowDecisionRecordCount = 0
            shadowDecisionLogURL = journal.fileURL
            shadowDecisionCaptureStatus = "recording · waiting for first snapshot"
            recordRuntimeIncident(
                timestampMs: nowMs,
                kind: "shadow-decision-capture-started",
                severity: .info,
                message: "Native SHADOW candidate-decision capture started",
                details: [
                    "sessionID": sessionID,
                    "path": journal.fileURL.path,
                    "scene": selectedScene.rawValue
                ]
            )
        } catch {
            shadowDecisionCaptureStatus = "capture failed · \(error.localizedDescription)"
            recordRuntimeIncident(
                timestampMs: nowMs,
                kind: "shadow-decision-capture-failed",
                severity: .warning,
                message: error.localizedDescription,
                details: runtimeRouteDetails()
            )
        }
    }

    private func finishShadowDecisionCapture(reason: String) {
        guard let journal = shadowDecisionJournal else { return }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1_000)
        let durationMs = max(nowMs - shadowDecisionStartedAtMs, 0)
        let sessionID = shadowDecisionSessionID
        let recordCount = shadowDecisionRecordCount
        let pendingWrite = shadowDecisionWriteTask
        shadowDecisionJournal = nil
        shadowDecisionSessionID = ""
        shadowDecisionStartedAtMs = 0
        shadowDecisionLastSnapshotMs = 0
        shadowDecisionCaptureStatus = "finalizing · \(recordCount) snapshots"
        shadowDecisionWriteTask = Task { [weak self] in
            await pendingWrite?.value
            guard let self else { return }

            let writeFailed = self.shadowDecisionWriteFailureSessionIDs.remove(sessionID) != nil
            if self.shadowDecisionLogURL == journal.fileURL,
               self.shadowDecisionJournal == nil {
                self.shadowDecisionCaptureStatus = writeFailed
                    ? "capture failed · incomplete log"
                    : "saved · \(recordCount) snapshots"
            }
            self.recordRuntimeIncident(
                timestampMs: nowMs,
                kind: writeFailed
                    ? "shadow-decision-capture-incomplete"
                    : "shadow-decision-capture-stopped",
                severity: writeFailed ? .warning : .info,
                message: writeFailed
                    ? "Native SHADOW candidate-decision capture ended with a write failure"
                    : "Native SHADOW candidate-decision capture stopped",
                details: [
                    "sessionID": sessionID,
                    "path": journal.fileURL.path,
                    "recordCount": "\(recordCount)",
                    "durationMs": "\(durationMs)",
                    "reason": reason
                ]
            )
        }
    }

    private func captureShadowDecisionSnapshot(nowMs: Int64) {
        guard engine.running, shadowMode else { return }
        startShadowDecisionCaptureIfNeeded(nowMs: nowMs)
        guard let journal = shadowDecisionJournal,
              nowMs - shadowDecisionLastSnapshotMs >= 1_000
        else { return }

        let channelCount = channelMappings.count
        let inputLevels = Array(levelsDb.prefix(channelCount))
        let candidateTrim = Array(autoTrimDb.prefix(channelCount))
        let candidateFader = Array(autoFaderDb.prefix(channelCount))
        let noiseFloors = Array(learnedNoiseFloorDb.prefix(channelCount))
        let active = Array(autoChannelActive.prefix(channelCount))
        let programLevels = Array(streamOutputLevelsDb.prefix(2))
        let numericValues = inputLevels + candidateTrim + candidateFader + noiseFloors +
            [autoLoudnessTrimDb] + programLevels
        guard channelCount > 0,
              inputLevels.count == channelCount,
              candidateTrim.count == channelCount,
              candidateFader.count == channelCount,
              noiseFloors.count == channelCount,
              active.count == channelCount,
              programLevels.count == 2,
              numericValues.allSatisfy(\.isFinite)
        else { return }

        let engineShadowMode = engine.shadowModeEnabled
        let runningInput = engine.runningInputDeviceInfo()
        let runningOutput = engine.runningOutputDeviceInfo()
        let record = ShadowDecisionRecord(
            timestampMs: nowMs,
            sessionID: shadowDecisionSessionID,
            scene: selectedScene,
            shadowMode: engineShadowMode,
            programAutomationApplied: !engineShadowMode,
            safeBypass: safeBypass,
            frozen: frozen,
            inputName: runningInput?.name ?? selectedInputDevice?.name ?? "",
            inputUID: runningInput?.uid ?? selectedInputUID,
            outputName: runningOutput?.name ?? selectedOutputDevice?.name ?? "",
            outputUID: runningOutput?.uid ?? selectedOutputUID,
            sampleRate: engine.sampleRate,
            channelCount: channelCount,
            inputLevelsDb: inputLevels,
            candidateAutoTrimDb: candidateTrim,
            candidateAutoFaderDb: candidateFader,
            learnedNoiseFloorDb: noiseFloors,
            channelActive: active,
            candidateMasterTrimDb: autoLoudnessTrimDb,
            programOutputLevelsDb: programLevels
        )
        shadowDecisionLastSnapshotMs = nowMs
        shadowDecisionRecordCount += 1
        shadowDecisionCaptureStatus = "recording · \(shadowDecisionRecordCount) snapshots"
        let sessionID = shadowDecisionSessionID
        let previousWrite = shadowDecisionWriteTask
        shadowDecisionWriteTask = Task { [weak self] in
            if let previousWrite {
                await previousWrite.value
            }
            do {
                _ = try await journal.append(record)
            } catch {
                guard let self else { return }
                self.shadowDecisionWriteFailureSessionIDs.insert(sessionID)
                if self.shadowDecisionSessionID == sessionID {
                    self.shadowDecisionJournal = nil
                    self.shadowDecisionCaptureStatus = "capture failed · \(error.localizedDescription)"
                }
                self.recordRuntimeIncident(
                    timestampMs: nowMs,
                    kind: "shadow-decision-write-failed",
                    severity: .warning,
                    message: error.localizedDescription,
                    details: [
                        "sessionID": sessionID,
                        "path": journal.fileURL.path
                    ]
                )
            }
        }
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
        planningCenterServiceTypeID = profile.planningCenterServiceTypeID
        planningCenterFollowTimedCues = profile.planningCenterFollowTimedCues
        automaticContinuousRecordingEnabled = profile.automaticContinuousRecordingEnabled
        plannedRecordingDurationHours = profile.plannedRecordingDurationHours
        recordingMinimumReserveGB = profile.recordingMinimumReserveGB
        recordingRetentionDays = profile.recordingRetentionDays
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
            planningCenterServiceTypeID: planningCenterServiceTypeID,
            planningCenterFollowTimedCues: planningCenterFollowTimedCues,
            automaticContinuousRecordingEnabled: automaticContinuousRecordingEnabled,
            plannedRecordingDurationHours: plannedRecordingDurationHours,
            recordingMinimumReserveGB: recordingMinimumReserveGB,
            recordingRetentionDays: recordingRetentionDays,
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

    private func continuousRecordingRootDirectory() throws -> URL {
        let root = try appSupportDirectory()
            .appendingPathComponent("Continuous Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func markContinuousRecordingSessionComplete() {
        guard let directory = continuousRecordingDirectoryURL else { return }
        let markerURL = directory.appendingPathComponent(
            ContinuousRecordingStorageManager.completionMarkerName,
            isDirectory: false
        )
        let payload: [String: Any] = [
            "completedAtMs": Int64(Date().timeIntervalSince1970 * 1_000),
            "capturedFrames": engine.continuousRecordingFrameCount,
            "droppedFrames": engine.continuousRecordingDroppedFrameCount,
            "segments": engine.continuousRecordingSegmentCount
        ]
        do {
            let data = try JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: markerURL, options: .atomic)
            activeRecordingSessionID = nil
        } catch {
            recordRuntimeIncident(
                kind: "recording-completion-marker-failed",
                severity: .warning,
                message: error.localizedDescription,
                details: ["recordingDirectory": directory.path]
            )
        }
    }

    private func nextContinuousRecordingDirectory() throws -> URL {
        let root = try continuousRecordingRootDirectory()
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

    /// A recorder-open failure can happen after the session manifest is written but
    /// before the audio writer creates its first segment. Remove only that known-empty
    /// bootstrap directory; any directory containing audio or diagnostics is retained
    /// and will be recovered by the session library on the next scan.
    private func removeUnusedRecordingSessionDirectory(_ directory: URL) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        ),
        contents.allSatisfy({ $0.lastPathComponent == RecordingSession.manifestName })
        else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    private func defaultRecordingSessionName() -> String {
        let explicit = nextRecordingSessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty { return String(explicit.prefix(120)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, yyyy · h:mm a"
        return "\(selectedScene.label) · \(formatter.string(from: Date()))"
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

    @discardableResult
    private func applyAllManualOverrides(
        reportFailure: Bool = true
    ) -> ManualOverrideApplicationSummary {
        guard engine.running else {
            return ManualOverrideApplicationSummary(
                requestedCount: 0,
                appliedCount: 0,
                failedMixerChannels: []
            )
        }
        let summary = ManualOverrideApplier.apply(
            channelMappings,
            to: engine,
            includeClearOperations: true
        )
        if reportFailure {
            if !summary.isComplete {
                manualOverrideApplicationFailed = true
                let message = "Manual control was not applied: \(summary.failureDescription)."
                lastError = message
                statusText = message
                recordRuntimeIncident(
                    kind: "manual-override-application-failed",
                    severity: .critical,
                    message: message,
                    details: [
                        "attemptedChannels": "\(summary.requestedCount)",
                        "appliedChannels": "\(summary.appliedCount)",
                        "failedMixerChannels": summary.failedMixerChannels
                            .map { "\($0 + 1)" }
                            .joined(separator: ",")
                    ]
                )
            } else if manualOverrideApplicationFailed {
                manualOverrideApplicationFailed = false
                if lastError?.hasPrefix("Manual control was not applied:") == true {
                    lastError = nil
                }
                statusText = engine.status
                recordRuntimeIncident(
                    kind: "manual-override-application-recovered",
                    severity: .info,
                    message: "All manual channel controls were applied after retry",
                    details: [
                        "appliedChannels": "\(summary.appliedCount)"
                    ]
                )
            }
        }
        return summary
    }

    private func requireAllManualOverridesApplied(context: String) throws {
        let summary = applyAllManualOverrides(reportFailure: false)
        guard summary.isComplete else {
            engine.stop()
            runningRouteSnapshot = nil
            throw NSError(
                domain: "AutoMixManualOverrideApplication",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "\(context) blocked because \(summary.failureDescription)"
                ]
            )
        }
        manualOverrideApplicationFailed = false
        if lastError?.hasPrefix("Manual control was not applied:") == true {
            lastError = nil
        }
    }

    private func synchronizeStereoPairAfterEdit(channelIndex: Int) {
        guard let editedPosition = channelMappings.firstIndex(where: { $0.index == channelIndex }) else {
            return
        }

        if channelMappings[editedPosition].stereoLinkedToNext {
            guard let rightPosition = channelMappings.firstIndex(where: {
                $0.index == channelIndex + 1
            }),
            channelMappings[editedPosition].role.supportsStereoLink
            else {
                channelMappings[editedPosition].stereoLinkedToNext = false
                lastError = "Stereo links require an adjacent non-speech source pair."
                return
            }
            if let priorPosition = channelMappings.firstIndex(where: {
                $0.index == channelIndex - 1
            }) {
                channelMappings[priorPosition].stereoLinkedToNext = false
            }
            channelMappings[rightPosition].stereoLinkedToNext = false
        }

        let leftChannelIndex: Int?
        if channelMappings[editedPosition].stereoLinkedToNext {
            leftChannelIndex = channelIndex
        } else if let priorPosition = channelMappings.firstIndex(where: {
            $0.index == channelIndex - 1
        }),
        channelMappings[priorPosition].stereoLinkedToNext {
            leftChannelIndex = channelIndex - 1
        } else {
            leftChannelIndex = nil
        }
        guard let leftChannelIndex,
              let leftPosition = channelMappings.firstIndex(where: {
                  $0.index == leftChannelIndex
              })
        else { return }

        guard let rightPosition = channelMappings.firstIndex(where: {
            $0.index == leftChannelIndex + 1
        }) else {
            channelMappings[leftPosition].stereoLinkedToNext = false
            return
        }
        let source = channelMappings[editedPosition]
        guard source.role.supportsStereoLink else {
            channelMappings[leftPosition].stereoLinkedToNext = false
            lastError = "Stereo link removed because \(source.role.label) is not a stereo source role."
            return
        }

        let partnerPosition = editedPosition == leftPosition ? rightPosition : leftPosition
        channelMappings[partnerPosition].role = source.role
        channelMappings[partnerPosition].faderOverrideEnabled = source.faderOverrideEnabled
        channelMappings[partnerPosition].faderDb = source.faderDb
        channelMappings[partnerPosition].muted = source.muted
        channelMappings[partnerPosition].preMuteFaderDb = source.preMuteFaderDb
        channelMappings[partnerPosition].preMuteFaderOverrideEnabled =
            source.preMuteFaderOverrideEnabled
        channelMappings[partnerPosition].processingOverride = source.processingOverride
    }

    private func applyAllStereoLinks() {
        guard engine.running else { return }
        for channel in channelMappings {
            _ = engine.clearStereoLink(forChannel: channel.index)
        }
        for pair in stereoLinkCoverage.pairs {
            _ = engine.setStereoLinkForLeftChannel(
                pair.leftChannelIndex,
                rightChannel: pair.rightChannelIndex
            )
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
    func debugSetPlanningCenterPlanForTesting(_ plan: PlanningCenterPlan) {
        planningCenterPlan = plan
        planningCenterCurrentCueIndex = nil
        planningCenterLastAppliedCueID = nil
        recordPlanningCenterPlanLoaded(plan)
    }

    func debugSetPlanningCenterFollowForTesting(_ enabled: Bool) {
        loadingProfile = true
        planningCenterFollowTimedCues = enabled
        loadingProfile = false
    }

    func debugUpdatePlanningCenterSceneForTesting(now: Date) {
        updatePlanningCenterScene(now: now)
    }

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
        engine.setSceneName(selectedScene.rawValue)
        engine.setSafeBypass(safeBypass)
        engine.setFrozen(frozen)
        engine.setShadowMode(shadowMode)
        applyAllStereoLinks()
        try requireAllManualOverridesApplied(context: "simulated recovery test start")
        armAutomaticRecoveryAfterSuccessfulStart(nowMs: nowMs)
        if automaticContinuousRecordingEnabled {
            continuousRecordingRequested = true
            nextRecordingStorageCheckMs = 0
            saveAutonomousSessionIntent()
        }
        startShadowDecisionCaptureIfNeeded(
            nowMs: Int64(Date().timeIntervalSince1970 * 1_000)
        )
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

    func debugWaitForShadowDecisionWritesForTesting() async {
        await shadowDecisionWriteTask?.value
    }

    func debugCaptureShadowDecisionSnapshotForTesting(nowMs: Int64) {
        captureShadowDecisionSnapshot(nowMs: nowMs)
    }

    func debugSetRecordingAvailableCapacityForTesting(_ bytes: Int64?) {
        recordingAvailableCapacityOverrideBytesForTesting = bytes
        nextRecordingStorageCheckMs = 0
    }

    func debugWaitForRecordingStorageForTesting() async {
        await recordingStorageTask?.value
        pollEngine()
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
        let stereoLinkCoverage = channelMappings.map {
            StereoLinkCoverage.make(channelMappings: $0)
        }

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

        if let stereoLinkCoverage {
            checks.append(
                HD96PreflightCheck(
                    name: "Stereo Links",
                    expected: "adjacent, same-role, non-overlapping pairs",
                    observed: stereoLinkCoverage.summary,
                    passed: stereoLinkCoverage.isReady,
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

struct PrimaryAudioHeartbeatRouteHealth: Equatable {
    var isReady: Bool
    var summary: String

    static func make(
        inputDevice: AMDeviceInfo?,
        outputDevice: AMDeviceInfo?,
        selectedInputUID: String,
        selectedOutputUID: String,
        detectedInputChannels: Int,
        detectedSampleRate: Double
    ) -> PrimaryAudioHeartbeatRouteHealth {
        guard let inputDevice, let outputDevice else {
            return PrimaryAudioHeartbeatRouteHealth(
                isReady: false,
                summary: "production Core Audio route is not running"
            )
        }
        guard !selectedInputUID.isEmpty,
              !selectedOutputUID.isEmpty,
              inputDevice.uid == selectedInputUID,
              outputDevice.uid == selectedOutputUID
        else {
            return PrimaryAudioHeartbeatRouteHealth(
                isReady: false,
                summary: "running route does not match the configured input/output UIDs"
            )
        }

        let inputIdentity = "\(inputDevice.name) \(inputDevice.uid)".lowercased()
        let outputIdentity = "\(outputDevice.name) \(outputDevice.uid)".lowercased()
        let productionRouteIdentified =
            inputIdentity.contains("dante") ||
            inputIdentity.contains("hd96") ||
            inputIdentity.contains("heritage-d") ||
            inputIdentity.contains("heritage d")
        guard productionRouteIdentified,
              !inputIdentity.contains("simulat"),
              !outputIdentity.contains("simulat")
        else {
            return PrimaryAudioHeartbeatRouteHealth(
                isReady: false,
                summary: "route is not an identified non-simulated HD96/Dante production path"
            )
        }

        let runningHealth = HD96RunningRouteHealth.make(
            inputDevice: inputDevice,
            outputDevice: outputDevice,
            expectedInputChannels: 64,
            detectedInputChannels: detectedInputChannels,
            detectedSampleRate: detectedSampleRate
        )
        guard runningHealth.isReady else {
            return PrimaryAudioHeartbeatRouteHealth(
                isReady: false,
                summary: runningHealth.warningMessage
            )
        }

        return PrimaryAudioHeartbeatRouteHealth(
            isReady: true,
            summary: "64-channel/96 kHz HD96/Dante route and isolated output ready"
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
