import Foundation
import XCTest

final class AutomationHTTPTests: XCTestCase {
    private let client = "7C9C61CA-0795-4C7E-9A53-40501C05AA85"
    private func request(body: String = "{}", extra: String = "", length: String? = nil) -> Data {
        Data("POST /v1/command HTTP/1.1\r\nHost: 127.0.0.1:49371\r\nContent-Type: application/json\r\nContent-Length: \(length ?? String(body.utf8.count))\r\nAuthorization: Bearer \(String(repeating: "a", count: 43))\r\nX-HeyNotch-Client: \(client)\r\n\(extra)\r\n\(body)".utf8)
    }
    private func assertInvalid(_ data: Data, file: StaticString = #filePath, line: UInt = #line) {
        if case .invalid = AutomationHTTPRequest.parse(data) {} else { XCTFail("Request must be rejected", file: file, line: line) }
    }
    func testAcceptsExactRequestAndFragmentedBody() {
        let full = request(body: "{\"tool\":\"get_context\",\"arguments\":{}}")
        if case .incomplete = AutomationHTTPRequest.parse(full.dropLast()) {} else { XCTFail("Must wait for complete body") }
        guard case .request(let parsed) = AutomationHTTPRequest.parse(full) else { return XCTFail("Valid request rejected") }
        XCTAssertEqual(parsed.clientID, client)
        XCTAssertEqual(parsed.body, Data("{\"tool\":\"get_context\",\"arguments\":{}}".utf8))
    }
    func testRejectsBrowserOriginsAndHTTPAmbiguities() {
        assertInvalid(request(extra: "Origin: http://127.0.0.1:49371\r\n"))
        assertInvalid(request(extra: "Transfer-Encoding: chunked\r\n"))
        assertInvalid(request(extra: "Content-Length: 2\r\n"))
        assertInvalid(request(extra: " Authorization: Bearer fake\r\n"))
        assertInvalid(request(length: "+2"))
        assertInvalid(request(length: "0"))
        assertInvalid(request(length: "65537"))
        assertInvalid(request(body: "{}POST /v1/command HTTP/1.1", length: "2"))
    }
    func testRejectsNonLoopbackHostsAndOtherPaths() {
        let text = String(data: request(), encoding: .utf8)!
        for host in ["localhost:49371", "example.com", "127.0.0.1.evil:49371", "0.0.0.0:49371"] {
            assertInvalid(Data(text.replacingOccurrences(of: "127.0.0.1:49371", with: host).utf8))
        }
        assertInvalid(Data(text.replacingOccurrences(of: "/v1/command", with: "/v1/command?foo").utf8))
        assertInvalid(Data(text.replacingOccurrences(of: "POST ", with: "GET ").utf8))
        assertInvalid(Data(text.replacingOccurrences(of: client, with: "unknown-client").utf8))
    }
    func testRejectsOversizedAndInvalidHeaders() {
        assertInvalid(Data(repeating: 65, count: 8193))
        assertInvalid(request(extra: "X-Pad: \(String(repeating: "x", count: 8192))\r\n"))
        assertInvalid(request(extra: "Bad Header: value\r\n"))
    }
}
