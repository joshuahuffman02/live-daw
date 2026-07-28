import Foundation
import Network

// Embedded LAN HTTP/SSE server for the remote operator console. Serves the PWA,
// streams telemetry over SSE (one broadcast timer, all clients), and accepts control
// POSTs. Zero third-party dependencies. Never touches the audio thread.
final class MonitorServer: @unchecked Sendable {
    private let service: MonitorService
    private let preferredPort: UInt16
    private let advertiseBonjour: Bool
    private let pushInterval: TimeInterval
    private let queue = DispatchQueue(label: "com.livedaw.automix.monitor")

    private var listener: NWListener?
    private var connections: [UUID: HTTPConnection] = [:]
    private var sseIDs: Set<UUID> = []
    private var pushTimer: DispatchSourceTimer?

    private var _actualPort: UInt16?               // mutated only on `queue`
    var actualPort: UInt16? { queue.sync { _actualPort } }
    var onStateChange: ((String) -> Void)?

    init(service: MonitorService,
         port: UInt16 = 8420,
         advertiseBonjour: Bool = true,
         pushInterval: TimeInterval = 0.1) {
        self.service = service
        self.preferredPort = port
        self.advertiseBonjour = advertiseBonjour
        self.pushInterval = pushInterval
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        let listener: NWListener
        if preferredPort == 0 {
            listener = try NWListener(using: params)
        } else {
            guard let port = NWEndpoint.Port(rawValue: preferredPort) else {
                throw MonitorServerError.invalidPort
            }
            listener = try NWListener(using: params, on: port)
        }

        if advertiseBonjour {
            listener.service = NWListener.Service(name: nil, type: "_automix._tcp")
        }

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self._actualPort = self.listener?.port?.rawValue
                self.onStateChange?("listening")
            case .failed(let error):
                self.onStateChange?("failed: \(error.localizedDescription)")
            case .cancelled:
                self.onStateChange?("stopped")
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        self.listener = listener
        listener.start(queue: queue)
        startPushTimer()
    }

    func stop() {
        queue.sync {
            pushTimer?.cancel()
            pushTimer = nil
            for connection in connections.values { connection.close() }
            connections.removeAll()
            sseIDs.removeAll()
            listener?.cancel()
            listener = nil
        }
    }

    var connectedClientCount: Int {
        queue.sync { sseIDs.count }
    }

    private func accept(_ nwConnection: NWConnection) {
        let connection = HTTPConnection(
            connection: nwConnection,
            queue: queue,
            onRequest: { [weak self] request, conn in self?.route(request, conn) },
            onClosed: { [weak self] conn in
                self?.connections[conn.id] = nil
                self?.sseIDs.remove(conn.id)
            }
        )
        connections[connection.id] = connection
        connection.start()
    }

    private func startPushTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + pushInterval, repeating: pushInterval)
        timer.setEventHandler { [weak self] in
            guard let self, !self.sseIDs.isEmpty else { return }
            let frame = Self.sseFrame(self.service.currentSnapshotJSON())
            for id in self.sseIDs {
                // onError fires on the same serial monitor queue, so pruning is safe.
                self.connections[id]?.sendEvent(frame) { [weak self] in
                    self?.sseIDs.remove(id)
                    self?.connections[id]?.close()
                    self?.connections[id] = nil
                }
            }
        }
        timer.resume()
        pushTimer = timer
    }

    // MARK: - Routing

    private func route(_ request: HTTPRequest, _ conn: HTTPConnection) {
        switch (request.method, request.path) {
        case ("GET", "/health"):
            sendPrimaryAudioHeartbeat(conn)
        case ("GET", "/events"):
            startSSE(conn)
        case ("POST", "/pair"):
            handlePair(request, conn)
        case ("POST", "/command"):
            handleCommand(request, conn)
        case ("GET", _), ("HEAD", _):
            serveStatic(request, conn)
        default:
            conn.send(Self.response(status: 404, contentType: "text/plain", body: Data("not found".utf8)), close: true)
        }
    }

    private func startSSE(_ conn: HTTPConnection) {
        conn.promoteToSSE()
        sseIDs.insert(conn.id)
        var headers = "HTTP/1.1 200 OK\r\n"
        headers += "Content-Type: text/event-stream\r\n"
        headers += "Cache-Control: no-cache\r\n"
        headers += "Connection: keep-alive\r\n"
        headers += "\r\n"
        conn.sendRaw(Data(headers.utf8))
        conn.sendEvent(Self.sseFrame(service.currentSnapshotJSON())) { [weak self] in
            self?.sseIDs.remove(conn.id)
            self?.connections[conn.id] = nil
        }
    }

    private func handlePair(_ request: HTTPRequest, _ conn: HTTPConnection) {
        struct PairRequest: Decodable { let code: String; let label: String? }
        guard let body = try? JSONDecoder().decode(PairRequest.self, from: request.body) else {
            sendJSON(conn, object: ["ok": false, "message": "bad request"], close: true)
            return
        }
        let label = body.label ?? "device"
        if let token = service.pair(code: body.code, clientLabel: label) {
            // Keep the bearer credential out of JavaScript and browser storage.
            // The console is served over plain HTTP on a trusted management LAN, so
            // Secure cannot be used; HttpOnly + strict same-site cookies still
            // remove the avoidable script-readable copy.
            let cookie = "amtoken=\(token); Path=/; HttpOnly; SameSite=Strict; Max-Age=86400"
            sendJSON(conn, object: ["ok": true], close: true,
                     extraHeaders: ["Set-Cookie": cookie, "Cache-Control": "no-store"])
        } else if service.isPairingLockedOut {
            sendJSON(conn, object: ["ok": false, "message": "too many attempts, locked out"],
                     status: 429, close: true)
        } else {
            sendJSON(conn, object: ["ok": false, "message": "wrong code"], status: 401, close: true)
        }
    }

    private func handleCommand(_ request: HTTPRequest, _ conn: HTTPConnection) {
        let token = request.cookie("amtoken") ?? ""
        guard service.isPaired(token: token) else {
            sendJSON(conn, object: ["ok": false, "message": "pair to control"],
                     status: 401, close: true,
                     extraHeaders: ["Cache-Control": "no-store"])
            return
        }
        guard let command = try? JSONDecoder().decode(RemoteCommand.self, from: request.body) else {
            sendJSON(conn, object: ["ok": false, "message": "bad command"],
                     status: 400, close: true,
                     extraHeaders: ["Cache-Control": "no-store"])
            return
        }
        let connectionID = conn.id
        service.applyCommand(command) { [weak self] result in
            // Hop back onto the monitor queue so HTTPConnection is only touched there.
            self?.queue.async { [weak self] in
                guard let self, let conn = self.connections[connectionID] else { return }
                let data = (try? JSONEncoder().encode(result)) ?? Data(#"{"ok":false}"#.utf8)
                conn.send(Self.response(status: result.ok ? 200 : 400,
                                        contentType: "application/json; charset=utf-8",
                                        body: data,
                                        extraHeaders: ["Cache-Control": "no-store"]), close: true)
            }
        }
    }

    private func serveStatic(_ request: HTTPRequest, _ conn: HTTPConnection) {
        guard let resource = service.staticResource(forPath: request.path) else {
            conn.send(Self.response(status: 404, contentType: "text/plain", body: Data("not found".utf8)), close: true)
            return
        }
        conn.send(Self.response(status: 200, contentType: resource.contentType, body: resource.data), close: true)
    }

    // MARK: - Helpers

    private func sendPrimaryAudioHeartbeat(_ conn: HTTPConnection) {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1_000)
        let heartbeat = service.currentPrimaryAudioHeartbeat().evaluated(at: nowMs)
        let body = (try? JSONEncoder().encode(heartbeat)) ?? Data(
            #"{"ok":false,"healthy":false,"streaming":false,"audioActive":false}"#.utf8
        )
        conn.send(
            Self.response(
                status: heartbeat.healthy ? 200 : 503,
                contentType: "application/json; charset=utf-8",
                body: body,
                extraHeaders: ["Cache-Control": "no-store"]
            ),
            close: true
        )
    }

    private func sendJSON(_ conn: HTTPConnection,
                          object: [String: Any],
                          status: Int = 200,
                          close: Bool,
                          extraHeaders: [String: String] = [:]) {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        conn.send(Self.response(status: status,
                                contentType: "application/json; charset=utf-8",
                                body: body,
                                extraHeaders: extraHeaders), close: close)
    }

    private static func sseFrame(_ json: Data) -> Data {
        var frame = Data("data: ".utf8)
        frame.append(json)
        frame.append(Data("\n\n".utf8))
        return frame
    }

    private static func response(status: Int,
                                 contentType: String,
                                 body: Data,
                                 extraHeaders: [String: String] = [:]) -> Data {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 404: reason = "Not Found"
        case 503: reason = "Service Unavailable"
        default: reason = "Status"
        }
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n"
        head += "Content-Security-Policy: default-src 'self'; connect-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; worker-src 'self'; manifest-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'\r\n"
        head += "Referrer-Policy: no-referrer\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        head += "X-Frame-Options: DENY\r\n"
        for (key, value) in extraHeaders {
            head += "\(key): \(value)\r\n"
        }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }
}

enum MonitorServerError: Error {
    case invalidPort
}
