import Foundation
import XCTest
@testable import AutoMix_Native

final class HTTPRequestParsingTests: XCTestCase {
    private func parse(_ string: String) -> (request: HTTPRequest, consumed: Int)? {
        HTTPParse.parse(Data(string.utf8))
    }

    func testParsesRequestLineMethodAndPath() throws {
        let result = try XCTUnwrap(parse("GET /events HTTP/1.1\r\nHost: x.local\r\n\r\n"))
        XCTAssertEqual(result.request.method, "GET")
        XCTAssertEqual(result.request.path, "/events")
        XCTAssertTrue(result.request.body.isEmpty)
    }

    func testParsesHeadersCaseInsensitively() throws {
        let result = try XCTUnwrap(parse("GET / HTTP/1.1\r\nContent-Type: application/json\r\n\r\n"))
        XCTAssertEqual(result.request.header("content-type"), "application/json")
        XCTAssertEqual(result.request.header("CONTENT-TYPE"), "application/json")
        XCTAssertNil(result.request.header("authorization"))
    }

    func testParsesQueryStringSeparatelyFromPath() throws {
        let result = try XCTUnwrap(parse("GET /x?a=1&b=two HTTP/1.1\r\n\r\n"))
        XCTAssertEqual(result.request.path, "/x")
        XCTAssertEqual(result.request.query["a"], "1")
        XCTAssertEqual(result.request.query["b"], "two")
    }

    func testReturnsNilWhenHeaderBlockIncomplete() {
        XCTAssertNil(parse("GET /eve"))
        XCTAssertNil(parse("GET / HTTP/1.1\r\nHost: x\r\n"))
    }

    func testParsesPostBodyByContentLength() throws {
        let body = #"{"type":"setSafe","on":true}"#
        let raw = "POST /command HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let result = try XCTUnwrap(parse(raw))
        XCTAssertEqual(result.request.method, "POST")
        XCTAssertEqual(result.request.path, "/command")
        XCTAssertEqual(String(data: result.request.body, encoding: .utf8), body)
    }

    func testReturnsNilWhenBodyIncomplete() {
        let raw = "POST /command HTTP/1.1\r\nContent-Length: 20\r\n\r\nonly-three"
        XCTAssertNil(parse(raw))
    }

    func testConsumedCountEqualsExactRequestLengthForPipelining() throws {
        let first = "GET /a HTTP/1.1\r\n\r\n"
        let second = "GET /b HTTP/1.1\r\n\r\n"
        let buffer = Data((first + second).utf8)
        let result = try XCTUnwrap(HTTPParse.parse(buffer))
        XCTAssertEqual(result.consumed, first.utf8.count)
        let remainder = buffer.subdata(in: result.consumed..<buffer.count)
        let next = try XCTUnwrap(HTTPParse.parse(remainder))
        XCTAssertEqual(next.request.path, "/b")
    }

    func testPercentDecodesPathSoTraversalGuardSeesDotDot() throws {
        let plain = try XCTUnwrap(parse("GET /ic%6Fns/a.png HTTP/1.1\r\n\r\n"))
        XCTAssertEqual(plain.request.path, "/icons/a.png")

        // Encoded dot-dot must decode to literal ".." so the static guard can reject it.
        let traversal = try XCTUnwrap(parse("GET /%2e%2e/secret HTTP/1.1\r\n\r\n"))
        XCTAssertTrue(traversal.request.path.contains(".."))
    }

    func testParsesCookieValue() throws {
        let result = try XCTUnwrap(parse("GET / HTTP/1.1\r\nCookie: amtoken=abc123; other=z\r\n\r\n"))
        XCTAssertEqual(result.request.cookie("amtoken"), "abc123")
        XCTAssertEqual(result.request.cookie("other"), "z")
        XCTAssertNil(result.request.cookie("missing"))
    }
}
