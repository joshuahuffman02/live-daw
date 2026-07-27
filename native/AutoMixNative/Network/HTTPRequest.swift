import Foundation

// Minimal HTTP/1.1 request model + an incremental-friendly parser. Only what the
// embedded monitor server needs: request line, headers, query, cookies, and a
// Content-Length body. No chunked transfer (the dashboard never sends it).

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]   // keys lowercased
    let body: Data

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    func cookie(_ name: String) -> String? {
        guard let raw = header("cookie") else { return nil }
        for pair in raw.split(separator: ";") {
            let trimmed = pair.trimmingCharacters(in: .whitespaces)
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq])
            if key == name {
                return String(trimmed[trimmed.index(after: eq)...])
            }
        }
        return nil
    }
}

enum HTTPParse {
    // Returns a parsed request + the number of bytes it consumed, or nil if the
    // buffer does not yet contain a complete request (caller reads more bytes).
    static func parse(_ buffer: Data) -> (request: HTTPRequest, consumed: Int)? {
        let terminator = Data("\r\n\r\n".utf8)
        guard let headerRange = buffer.range(of: terminator) else { return nil }

        let headerData = buffer.subdata(in: buffer.startIndex..<headerRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }

        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }

        let requestLine = lines.removeFirst().split(separator: " ", maxSplits: 2).map(String.init)
        guard requestLine.count >= 2 else { return nil }
        let method = requestLine[0]
        let target = requestLine[1]

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let (path, query) = splitTarget(target)

        let headerEnd = headerRange.upperBound
        var body = Data()
        var consumed = headerEnd - buffer.startIndex
        if let lengthString = headers["content-length"], let length = Int(lengthString), length > 0 {
            let available = buffer.endIndex - headerEnd
            if available < length { return nil }
            body = buffer.subdata(in: headerEnd..<(headerEnd + length))
            consumed += length
        }

        let request = HTTPRequest(method: method, path: path, query: query,
                                  headers: headers, body: body)
        return (request, consumed)
    }

    private static func splitTarget(_ target: String) -> (path: String, query: [String: String]) {
        // Percent-decode the path so an encoded "%2e%2e" surfaces as a literal ".."
        // before the static-file traversal guard runs.
        func decode(_ s: String) -> String { s.removingPercentEncoding ?? s }
        guard let q = target.firstIndex(of: "?") else { return (decode(target), [:]) }
        let path = decode(String(target[..<q]))
        let queryString = String(target[target.index(after: q)...])
        var query: [String: String] = [:]
        for pair in queryString.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 {
                query[kv[0]] = kv[1].removingPercentEncoding ?? kv[1]
            } else if kv.count == 1 {
                query[kv[0]] = ""
            }
        }
        return (path, query)
    }
}
