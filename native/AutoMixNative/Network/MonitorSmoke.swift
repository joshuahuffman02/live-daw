import Foundation

// Headless end-to-end proof of the embedded server: starts it on an ephemeral
// loopback port with a canned snapshot, then exercises static serving, /health,
// auth gating, pairing, command routing, and the SSE stream. Returns a process exit
// code (0 = pass). Run via `AutoMix Native --monitor-smoke`.
enum MonitorSmoke {
    static func run() -> Int32 {
        let store = PairingStore(code: "424242")
        let core = MonitorServiceCore(pairingStore: store, healthName: "smoke-venue")
        core.setCommandHandler { _, _, done in
            done(CommandResult(ok: true, message: "echo"))
        }
        let heartbeatNowMs = Int64(Date().timeIntervalSince1970 * 1_000)
        let healthyHeartbeat = PrimaryAudioHeartbeat.make(
            name: "smoke-venue",
            nowMs: heartbeatNowMs,
            operatorStopped: false,
            engineRunning: true,
            routeHealthy: true,
            routeDetail: "fixture route ready",
            inputCallbackAgeMs: 10,
            outputCallbackAgeMs: 12
        )
        core.publishPrimaryAudioHeartbeat(healthyHeartbeat)

        func publishSnapshot(at timestampMs: Int64) {
            let snapshot = TelemetryAssembler.assemble(
                ts: timestampMs,
                venueName: "smoke-venue",
                isRunning: true,
                safe: false,
                freeze: false,
                watchdogSafe: false,
                scene: "worship",
                scenes: ["worship", "sermon"],
                sampleRate: 96_000,
                inputChannelCount: 64,
                bpm: 120,
                bpmConfidence: 0.8,
                stream: StreamTelemetry(
                    l: -8,
                    r: -8,
                    momentaryLufs: -14,
                    shortLufs: -14,
                    integratedLufs: -14,
                    limiterGrDb: -1
                ),
                counters: CounterTelemetry(
                    dropouts: 0,
                    callbackOverruns: 0,
                    deadlineMisses: 0,
                    outputUnderruns: 0,
                    outputOverruns: 0,
                    lastCallbackFrames: 256,
                    maxCallbackFrames: 256
                ),
                channels: [],
                alerts: [],
                severity: .none
            )
            core.publish(
                (try? JSONEncoder().encode(snapshot)) ?? Data(),
                timestampMs: timestampMs
            )
        }
        publishSnapshot(at: heartbeatNowMs)

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
        if let (status, body, headers) = httpRequest(base + "/health") {
            check("health 200", status == 200, "status \(status)")
            let heartbeat = try? JSONDecoder().decode(PrimaryAudioHeartbeat.self, from: body)
            check("health contract decodes", heartbeat != nil)
            check("health is primary-audio ready",
                  heartbeat?.ok == true &&
                    heartbeat?.healthy == true &&
                    heartbeat?.streaming == true &&
                    heartbeat?.audioActive == true)
            check("health requires manual return", heartbeat?.manualReturnRequired == true)
            check("health response is not cacheable", headers["cache-control"] == "no-store")
        } else { check("health reachable", false) }

        let stoppedHeartbeat = PrimaryAudioHeartbeat.make(
            name: "smoke-venue",
            nowMs: Int64(Date().timeIntervalSince1970 * 1_000),
            operatorStopped: true,
            engineRunning: false,
            routeHealthy: false,
            routeDetail: "fixture route stopped",
            inputCallbackAgeMs: -1,
            outputCallbackAgeMs: -1
        )
        core.publishPrimaryAudioHeartbeat(stoppedHeartbeat)
        if let (status, body, _) = httpRequest(base + "/health") {
            let heartbeat = try? JSONDecoder().decode(PrimaryAudioHeartbeat.self, from: body)
            check("stopped primary returns 503", status == 503, "status \(status)")
            check("stopped primary fails closed", heartbeat?.healthy == false)
        } else { check("stopped health reachable", false) }

        var staleHeartbeat = healthyHeartbeat
        staleHeartbeat.timestampMs =
            Int64(Date().timeIntervalSince1970 * 1_000) -
            PrimaryAudioHeartbeat.maximumFreshAgeMs -
            1
        core.publishPrimaryAudioHeartbeat(staleHeartbeat)
        if let (status, body, _) = httpRequest(base + "/health") {
            let heartbeat = try? JSONDecoder().decode(PrimaryAudioHeartbeat.self, from: body)
            check("stale primary returns 503", status == 503, "status \(status)")
            check("stale primary fails closed",
                  heartbeat?.healthy == false && heartbeat?.detail == "heartbeat stale")
        } else { check("stale health reachable", false) }
        var refreshedHeartbeat = healthyHeartbeat
        refreshedHeartbeat.timestampMs = Int64(Date().timeIntervalSince1970 * 1_000)
        core.publishPrimaryAudioHeartbeat(refreshedHeartbeat)

        // 2) static PWA shell
        if let (status, body, headers) = httpRequest(base + "/index.html") {
            check("static index 200", status == 200, "status \(status)")
            check("static index is the dashboard", String(data: body, encoding: .utf8)?.contains("AutoMix Remote") == true)
            check("static index loads safety gate",
                  String(data: body, encoding: .utf8)?.contains("/safety.js?v=6") == true)
            check("static response blocks framing", headers["x-frame-options"] == "DENY")
            check("static response has CSP",
                  headers["content-security-policy"]?.contains("default-src 'self'") == true)
        } else { check("static index reachable", false) }
        if let (status, body, headers) = httpRequest(base + "/safety.js?v=6") {
            check("safety gate asset 200", status == 200, "status \(status)")
            check("safety gate asset is bundled",
                  String(data: body, encoding: .utf8)?.contains("TelemetryFreshness") == true)
            check("safety gate asset has JavaScript content type",
                  headers["content-type"]?.contains("application/javascript") == true)
        } else { check("safety gate asset reachable", false) }

        // 3) command rejected without token
        if let (status, _, _) = httpRequest(base + "/command", method: "POST",
                                            body: Data(#"{"type":"setSafe","on":true}"#.utf8)) {
            check("command blocked without pairing", status == 401, "status \(status)")
        } else { check("command endpoint reachable", false) }

        // 4) pairing
        var cookie = ""
        var bearerToken = ""
        if let response = httpRequest(base + "/pair", method: "POST",
                                      body: Data(#"{"code":"424242","label":"smoke"}"#.utf8)) {
            check("pair 200", response.status == 200, "status \(response.status)")
            let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
            check("pair keeps token out of JSON", object?["token"] == nil)
            cookie = response.headers["set-cookie"]?
                .split(separator: ";", maxSplits: 1)
                .first
                .map(String.init) ?? ""
            bearerToken = cookie
                .split(separator: "=", maxSplits: 1)
                .last
                .map(String.init) ?? ""
            check("pair sets HttpOnly cookie",
                  response.headers["set-cookie"]?.contains("HttpOnly") == true)
            check("pair cookie is SameSite strict",
                  response.headers["set-cookie"]?.contains("SameSite=Strict") == true)
            check("pair response is not cacheable",
                  response.headers["cache-control"] == "no-store")
            check("pair returns cookie credential", !cookie.isEmpty)
        } else { check("pair reachable", false) }

        // 5) wrong code rejected
        if let (status, _, _) = httpRequest(base + "/pair", method: "POST",
                                            body: Data(#"{"code":"000000"}"#.utf8)) {
            check("wrong pairing code rejected", status == 401, "status \(status)")
        }

        // 6) legacy script-readable header is rejected
        if let (status, _, _) = httpRequest(base + "/command", method: "POST",
                                            body: Data(#"{"type":"setSafe","on":true}"#.utf8),
                                            headers: ["X-AMToken": bearerToken]) {
            check("legacy token header rejected", status == 401, "status \(status)")
        }

        // 7) paired control still fails closed without a fresh client snapshot.
        let commandSnapshotTs = Int64(Date().timeIntervalSince1970 * 1_000)
        publishSnapshot(at: commandSnapshotTs)
        if let (status, body, headers) = httpRequest(
            base + "/command",
            method: "POST",
            body: Data(#"{"type":"setSafe","on":true}"#.utf8),
            headers: ["Cookie": cookie]
        ) {
            check("command without snapshot rejected", status == 409, "status \(status)")
            check("freshness rejection is not cacheable", headers["cache-control"] == "no-store")
            check("freshness rejection explains reload",
                  String(data: body, encoding: .utf8)?.contains("fresh telemetry") == true)
        } else { check("freshness-gated command reachable", false) }

        let staleClientTs =
            commandSnapshotTs -
            RemoteControlFreshness.maximumClientSnapshotLagMs -
            1
        if let (status, body, _) = httpRequest(
            base + "/command",
            method: "POST",
            body: Data(
                #"{"type":"setSafe","on":true,"snapshotTs":\#(staleClientTs)}"#.utf8
            ),
            headers: ["Cookie": cookie]
        ) {
            check("stale client command rejected", status == 409, "status \(status)")
            check("stale client rejection is explicit",
                  String(data: body, encoding: .utf8)?.contains("stale remote telemetry") == true)
        } else { check("stale client command reachable", false) }

        let staleServerTs =
            Int64(Date().timeIntervalSince1970 * 1_000) -
            RemoteControlFreshness.maximumServerSnapshotAgeMs -
            1
        publishSnapshot(at: staleServerTs)
        if let (status, body, _) = httpRequest(
            base + "/command",
            method: "POST",
            body: Data(
                #"{"type":"setSafe","on":true,"snapshotTs":\#(staleServerTs)}"#.utf8
            ),
            headers: ["Cookie": cookie]
        ) {
            check("stalled producer command rejected", status == 503, "status \(status)")
            check("stalled producer rejection is explicit",
                  String(data: body, encoding: .utf8)?.contains("telemetry is stale") == true)
        } else { check("stalled producer command reachable", false) }

        // 8) a fresh snapshot-bound command is accepted with the HttpOnly cookie.
        let refreshedCommandTs = Int64(Date().timeIntervalSince1970 * 1_000)
        publishSnapshot(at: refreshedCommandTs)
        if let (status, body, _) = httpRequest(base + "/command", method: "POST",
                                               body: Data(
                                                #"{"type":"setSafe","on":true,"snapshotTs":\#(refreshedCommandTs)}"#.utf8
                                               ),
                                               headers: ["Cookie": cookie]) {
            check("command accepted with cookie", status == 200, "status \(status)")
            check("command ok:true", String(data: body, encoding: .utf8)?.contains("\"ok\":true") == true)
        } else { check("command with cookie reachable", false) }

        if let (status, body, _) = httpRequest(
            base + "/command",
            method: "POST",
            body: Data(
                #"{"type":"setSafe","on":false,"snapshotTs":\#(refreshedCommandTs)}"#.utf8
            ),
            headers: ["Cookie": cookie]
        ) {
            check("unconfirmed SAFE release rejected", status == 409, "status \(status)")
            check("SAFE release rejection is explicit",
                  String(data: body, encoding: .utf8)?.contains("explicit confirmation") == true)
        } else { check("unconfirmed SAFE release receives response", false) }

        if let (status, body, _) = httpRequest(
            base + "/command",
            method: "POST",
            body: Data(
                #"{"type":"setSafe","on":false,"confirmSafeRelease":true,"snapshotTs":\#(refreshedCommandTs)}"#.utf8
            ),
            headers: ["Cookie": cookie]
        ) {
            check("confirmed SAFE release accepted", status == 200, "status \(status)")
            check("confirmed SAFE release ok:true",
                  String(data: body, encoding: .utf8)?.contains("\"ok\":true") == true)
        } else { check("confirmed SAFE release reachable", false) }

        // 9) a main-actor/control handler stall receives a bounded failure response.
        core.setCommandHandler { _, _, _ in }
        if let (status, body, _) = httpRequest(
            base + "/command",
            method: "POST",
            body: Data(
                #"{"type":"setSafe","on":true,"snapshotTs":\#(refreshedCommandTs)}"#.utf8
            ),
            headers: ["Cookie": cookie]
        ) {
            check("hung command times out", status == 504, "status \(status)")
            check("hung command timeout is explicit",
                  String(data: body, encoding: .utf8)?.contains("verify the Mac") == true)
        } else { check("hung command receives response", false) }
        core.setCommandHandler { _, _, done in
            done(CommandResult(ok: true, message: "echo"))
        }

        // 10) SSE stream delivers a snapshot frame.
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
                                    timeout: TimeInterval = 3)
        -> (status: Int, body: Data, headers: [String: String])? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }

        let semaphore = DispatchSemaphore(value: 0)
        let result = HTTPResultBox()
        // Keep every probe stateless so the test proves that only the explicitly
        // supplied Cookie header authorizes a command.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        let session = URLSession(configuration: configuration)
        let task = session.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse {
                var headers: [String: String] = [:]
                for (key, value) in http.allHeaderFields {
                    headers[String(describing: key).lowercased()] = String(describing: value)
                }
                result.store(status: http.statusCode, body: data ?? Data(), headers: headers)
            }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + timeout + 1)
        session.finishTasksAndInvalidate()
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
    private var storedValue: (Int, Data, [String: String])?

    var value: (Int, Data, [String: String])? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func store(status: Int, body: Data, headers: [String: String]) {
        lock.lock()
        storedValue = (status, body, headers)
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
