import Foundation
import Security

// Gates remote control. Monitoring is view-open; issuing a command requires a token
// minted by entering the per-launch 6-digit code. Tokens are random, stored
// server-side, and die when the app (and this store) is recreated, so they never
// cross a launch boundary. Thread-safe: touched from both the server queue and the
// main actor.

struct PairedClient: Equatable {
    let label: String
    let firstSeen: Date
}

final class PairingStore {
    // Throttle brute-force guessing of the 6-digit code (1M keyspace). After this many
    // consecutive wrong codes the pairing endpoint locks out for a cooldown, so the
    // keyspace cannot be enumerated over the LAN during a service.
    static let maxFailedAttempts = 10
    static let lockoutSeconds: TimeInterval = 30
    static let maxPairedClients = 16
    static let maxClientLabelCharacters = 64

    let code: String

    private let now: () -> Date
    private let lock = NSLock()
    private var clientsByToken: [String: PairedClient] = [:]
    private var failedAttempts = 0
    private var lockoutUntil: Date?

    init(now: @escaping () -> Date = Date.init) {
        self.code = Self.randomCode()
        self.now = now
    }

    // Deterministic code (and injectable clock) for tests; token randomness is still real.
    init(code: String, now: @escaping () -> Date = Date.init) {
        self.code = code
        self.now = now
    }

    var isLockedOut: Bool {
        lock.lock(); defer { lock.unlock() }
        return lockedLocked()
    }

    // Caller must hold `lock`. Clears an expired lockout (and its counter) as a side effect.
    private func lockedLocked() -> Bool {
        guard let until = lockoutUntil else { return false }
        if now() >= until {
            lockoutUntil = nil
            failedAttempts = 0
            return false
        }
        return true
    }

    func pair(code enteredCode: String, label: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if lockedLocked() { return nil }
        guard enteredCode == code else {
            failedAttempts += 1
            if failedAttempts >= Self.maxFailedAttempts {
                lockoutUntil = now().addingTimeInterval(Self.lockoutSeconds)
            }
            return nil
        }
        failedAttempts = 0
        lockoutUntil = nil
        if clientsByToken.count >= Self.maxPairedClients,
           let oldestToken = clientsByToken.min(by: {
               $0.value.firstSeen < $1.value.firstSeen
           })?.key {
            clientsByToken.removeValue(forKey: oldestToken)
        }
        let token = Self.randomToken()
        clientsByToken[token] = PairedClient(
            label: Self.normalizedLabel(label),
            firstSeen: now()
        )
        return token
    }

    func isValid(token: String) -> Bool {
        guard !token.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        return clientsByToken[token] != nil
    }

    func revokeAll() {
        lock.lock()
        clientsByToken.removeAll()
        lock.unlock()
    }

    var pairedClients: [PairedClient] {
        lock.lock()
        defer { lock.unlock() }
        return Array(clientsByToken.values)
    }

    var pairedClientCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return clientsByToken.count
    }

    private static func randomCode() -> String {
        let value = secureRandomUInt32() % 1_000_000
        return String(format: "%06u", value)
    }

    private static func normalizedLabel(_ label: String) -> String {
        let withoutControls = label.components(separatedBy: .controlCharacters).joined()
        let trimmed = withoutControls.trimmingCharacters(in: .whitespacesAndNewlines)
        let bounded = String(trimmed.prefix(maxClientLabelCharacters))
        return bounded.isEmpty ? "device" : bounded
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            for i in bytes.indices { bytes[i] = UInt8(secureRandomUInt32() & 0xFF) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func secureRandomUInt32() -> UInt32 {
        var value: UInt32 = 0
        let status = withUnsafeMutableBytes(of: &value) {
            SecRandomCopyBytes(kSecRandomDefault, 4, $0.baseAddress!)
        }
        if status != errSecSuccess {
            value = UInt32(truncatingIfNeeded: UInt(bitPattern: ObjectIdentifier(NSObject()).hashValue))
        }
        return value
    }
}
