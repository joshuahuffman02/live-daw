import Foundation
import Network

// One client TCP connection. Accumulates bytes, parses complete HTTP requests, and
// hands them to the server's router. Can be promoted to an SSE stream that stays open
// for telemetry pushes. All callbacks run on the shared monitor queue.
final class HTTPConnection: @unchecked Sendable {
    let id = UUID()
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let onRequest: (HTTPRequest, HTTPConnection) -> Void
    private var onClosed: ((HTTPConnection) -> Void)?
    private var buffer = Data()
    private(set) var isSSE = false
    // Hard cap so a malformed/slow client that never completes a request (no header
    // terminator, or a huge Content-Length) cannot grow the buffer without bound.
    private let maxRequestBytes = 512 * 1024

    init(connection: NWConnection,
         queue: DispatchQueue,
         onRequest: @escaping (HTTPRequest, HTTPConnection) -> Void,
         onClosed: @escaping (HTTPConnection) -> Void) {
        self.connection = connection
        self.queue = queue
        self.onRequest = onRequest
        self.onClosed = onClosed
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.handleClosed()
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            // Once promoted to SSE we only read to notice the peer leaving; client
            // bytes are ignored, never buffered.
            if let data, !data.isEmpty, !self.isSSE {
                self.buffer.append(data)
                if self.buffer.count > self.maxRequestBytes {
                    self.connection.cancel()
                    self.handleClosed()
                    return
                }
                self.drainRequests()
            }
            if isComplete || error != nil {
                self.handleClosed()
                return
            }
            self.receive()
        }
    }

    private func drainRequests() {
        while let (request, consumed) = HTTPParse.parse(buffer), consumed > 0 {
            buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + consumed))
            onRequest(request, self)
            if isSSE { break }
        }
    }

    func promoteToSSE() {
        isSSE = true
    }

    func send(_ data: Data, close: Bool) {
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            if close { self?.connection.cancel() }
        })
    }

    func sendRaw(_ data: Data) {
        connection.send(content: data, completion: .idempotent)
    }

    // SSE push with a real completion so a failed write (dead/departed peer) can prune
    // the client instead of queuing frames forever.
    func sendEvent(_ data: Data, onError: @escaping @Sendable () -> Void) {
        connection.send(content: data, completion: .contentProcessed { error in
            if error != nil { onError() }
        })
    }

    func close() {
        connection.cancel()
    }

    private func handleClosed() {
        let closed = onClosed
        onClosed = nil
        closed?(self)
    }
}
