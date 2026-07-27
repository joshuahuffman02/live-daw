import Foundation

struct StaticResource {
    let data: Data
    let contentType: String
}

// The only surface MonitorServer/HTTPConnection see. Thread-safe: every method may
// be called from the server's background queue. Keeps the transport ignorant of
// Core Audio / AppModel.
protocol MonitorService: AnyObject {
    var pairingCode: String { get }
    var healthName: String { get }
    var isPairingLockedOut: Bool { get }
    func currentSnapshotJSON() -> Data
    func staticResource(forPath path: String) -> StaticResource?
    func pair(code: String, clientLabel: String) -> String?
    func isPaired(token: String) -> Bool
    func applyCommand(_ command: RemoteCommand, completion: @escaping (CommandResult) -> Void)
}

// Concrete, non-isolated, thread-safe implementation. The @MainActor MonitorBridge
// feeds it (publishes snapshots, wires the command handler); the server reads it.
final class MonitorServiceCore: MonitorService, @unchecked Sendable {
    let pairingStore: PairingStore
    let healthName: String

    private let resources: StaticResourceProvider
    private let lock = NSLock()
    private var snapshotData = Data("{}".utf8)
    private var commandHandler: ((RemoteCommand, @escaping (CommandResult) -> Void) -> Void)?

    init(pairingStore: PairingStore,
         healthName: String,
         resources: StaticResourceProvider = BundleStaticResources()) {
        self.pairingStore = pairingStore
        self.healthName = healthName
        self.resources = resources
    }

    var pairingCode: String { pairingStore.code }

    var isPairingLockedOut: Bool { pairingStore.isLockedOut }

    func publish(_ data: Data) {
        lock.lock(); snapshotData = data; lock.unlock()
    }

    func currentSnapshotJSON() -> Data {
        lock.lock(); defer { lock.unlock() }
        return snapshotData
    }

    func setCommandHandler(_ handler: @escaping (RemoteCommand, @escaping (CommandResult) -> Void) -> Void) {
        lock.lock(); commandHandler = handler; lock.unlock()
    }

    func staticResource(forPath path: String) -> StaticResource? {
        resources.resource(forPath: path)
    }

    func pair(code: String, clientLabel: String) -> String? {
        pairingStore.pair(code: code, label: clientLabel)
    }

    func isPaired(token: String) -> Bool {
        pairingStore.isValid(token: token)
    }

    func applyCommand(_ command: RemoteCommand, completion: @escaping (CommandResult) -> Void) {
        lock.lock(); let handler = commandHandler; lock.unlock()
        guard let handler else {
            completion(CommandResult(ok: false, message: "control unavailable"))
            return
        }
        handler(command, completion)
    }
}

// Resolves dashboard asset paths to bundled files under RemoteWeb/.
protocol StaticResourceProvider {
    func resource(forPath path: String) -> StaticResource?
}

struct BundleStaticResources: StaticResourceProvider {
    var bundle: Bundle = .main
    var subdirectory = "RemoteWeb"

    func resource(forPath path: String) -> StaticResource? {
        let cleaned = path == "/" ? "index.html" : String(path.drop(while: { $0 == "/" }))
        guard !cleaned.isEmpty, !cleaned.contains("..") else { return nil }

        let name = (cleaned as NSString).deletingPathExtension
        let ext = (cleaned as NSString).pathExtension
        let dir = (cleaned as NSString).deletingLastPathComponent
        let subdir = dir.isEmpty ? subdirectory : "\(subdirectory)/\(dir)"
        let baseName = (name as NSString).lastPathComponent

        guard let url = bundle.url(forResource: baseName, withExtension: ext, subdirectory: subdir),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return StaticResource(data: data, contentType: Self.contentType(forExtension: ext))
    }

    static func contentType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js": return "application/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "webmanifest": return "application/manifest+json; charset=utf-8"
        case "png": return "image/png"
        case "svg": return "image/svg+xml"
        case "ico": return "image/x-icon"
        default: return "application/octet-stream"
        }
    }
}
