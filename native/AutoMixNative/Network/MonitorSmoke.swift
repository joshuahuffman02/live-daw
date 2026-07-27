import Foundation

// Headless end-to-end proof of the embedded server: starts it on an ephemeral
// loopback port with a canned snapshot, then exercises static serving, /health,
// auth gating, pairing, command routing, and the SSE stream. Returns a process exit
// code (0 = pass). Run via `AutoMix Native --monitor-smoke`.
enum MonitorSmoke {
    static func run() -> Int32 {
        let store = PairingStore(code: "424242")
        let core = MonitorServiceCore(pairingStore: store, healthName: "smoke-venue")
        core.setCommandHandler { _, done in done(CommandResult(ok: true, message: "echo")) }

        let snapshot = TelemetryAssembler.assemble(
            ts: 1, venueName: "smoke-venue", isRunning: true, safe: false, freeze: false,
            watchdogSafe: false, scene: "worship", scenes: ["worship", "sermon"],
            sampleRate: 96_000, inputChannelCount: 64, bpm: 120, bpmConfidence: 0.8,
            stream: StreamTelemetry(l: -8, r: -8, momentaryLufs: -14, shortLufs: -14,
                                    integratedLufs: -14, limiterGrDb: -1),
            counters: CounterTelemetry(dropouts: 0, callbackOverruns: 0, deadlineMisses: 0,
                                       outputUnderruns: 0, outputOverruns: 0,
                                       lastCallbackFrames: 256, maxCallbackFrames: 256),
            channels: [], alerts: [], severity: .none)
        core.publish((try? JSONEncoder().encode(snapshot)) ?? Data())

        let server = MonitorServer(service: core, port: 0, advertiseBonjour: false, pushInterval: 0.05)
        do { try server.start() } catch {
            print("monitor-smoke FAIL: server start: \(error)"); return 70
        }
        defer { server.stop() }

        guard let port = waitForPort(server) else {
            print("monitor-smoke FAIL: server never reached ready"); return 71
        }
        let base = "http://127.0.0.1:\(port)"
        print("monitor-smoke: listening on \(base)")

        var failures: [String] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("  [\(ok ? "ok" : "FAIL")] \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures.append(name) }
        }

        // 1) health
        if let (status, body) = httpRequest(base + "/health") {
            check("health 200", status == 200, "status \(status)")
            check("health ok:true", String(data: body, encoding: .utf8)?.contains("\"ok\":true") == true)
        } else { check("health reachable", false) }

        // 2) static PWA shell
        if let (status, body) = httpRequest(base + "/index.html") {
            check("static index 200", status == 200, "status \(status)")
            check("static index is the dashboard", String(data: body, encoding: .utf8)?.contains("AutoMix Remote") == true)
        } else { check("static index reachable", false) }

        // 3) command rejected without token
        if let (status, _) = httpRequest(base + "/command", method: "POST",
                                         body: Data(#"{"type":"setSafe","on":true}"#.utf8)) {
            check("command blocked without pairing", status == 401, "status \(status)")
        } else { check("command endpoint reachable", false) }

        // 4) pairing
        var token = ""
        if let (status, body) = httpRequest(base + "/pair", method: "POST",
                                            body: Data(#"{"code":"424242","label":"smoke"}"#.utf8)) {
            check("pair 200", status == 200, "status \(status)")
            if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let t = obj["token"] as? String {
                token = t
            }
            check("pair returns token", !token.isEmpty)
        } else { check("pair reachable", false) }

        // 5) wrong code rejected
        if let (status, _) = httpRequest(base + "/pair", method: "POST",
                                         body: Data(#"{"code":"000000"}"#.utf8)) {
            check("wrong pairing code rejected", status == 401, "status \(status)")
        }

        // 6) command accepted with token
        if let (status, body) = httpRequest(base + "/command", method: "POST",
                                            body: Data(#"{"type":"setSafe","on":true}"#.utf8),
                                            headers: ["X-AMToken": token]) {
            check("command accepted with token", status == 200, "status \(status)")
            check("command ok:true", String(data: body, encoding: .utf8)?.contains("\"ok\":true") == true)
        } else { check("command with token reachable", false) }

        // 7) SSE stream delivers a snapshot frame
        if let frame = readSSEFrame(base + "/events") {
            check("SSE frame is data: event", frame.hasPrefix("data: "))
            check("SSE frame carries snapshot", frame.contains("smoke-venue"))
        } else { check("SSE frame received", false) }

        if failures.isEmpty {
            print("monitor-smoke PASS")
            return 0
        }
        print("monitor-smoke FAIL: \(failures.joined(separator: ", "))")
        return 72
    }

    private static func waitForPort(_ server: MonitorServer, timeout: TimeInterval = 3) -> UInt16? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let port = server.actualPort, port != 0 { return port }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return server.actualPort
    }

    private static func httpRequest(_ urlString: String,
                                    method: String = "GET",
                                    body: Data? = nil,
                                    headers: [String: String] = [:],
                                    timeout: TimeInterval = 3) -> (status: Int, body: Data)? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }

        let semaphore = DispatchSemaphore(value: 0)
        let result = HTTPResultBox()
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse {
                result.store(status: http.statusCode, body: data ?? Data())
            }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + timeout + 1)
        return result.value
    }

    private static func readSSEFrame(_ urlString: String, timeout: TimeInterval = 3) -> String? {
        guard let url = URL(string: urlString) else { return nil }
        let probe = SSEProbe()
        return probe.firstFrame(url: url, timeout: timeout)
    }
}

private final class HTTPResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: (Int, Data)?

    var value: (Int, Data)? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func store(status: Int, body: Data) {
        lock.lock()
        storedValue = (status, body)
        lock.unlock()
    }
}

private final class SSEProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let semaphore = DispatchSemaphore(value: 0)
    private var captured: String?
    private var didCapture = false

    func firstFrame(url: URL, timeout: TimeInterval) -> String? {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        let task = session.dataTask(with: url)
        task.resume()
        _ = semaphore.wait(timeout: .now() + timeout)
        task.cancel()
        session.invalidateAndCancel()
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !didCapture else { return }
        buffer.append(data)
        if let text = String(data: buffer, encoding: .utf8),
           let range = text.range(of: "\n\n") {
            captured = String(text[..<range.lowerBound])
            didCapture = true
            semaphore.signal()
        }
    }
}
