import XCTest
@testable import ntfy_macos

final class LocalRequestSecurityTests: XCTestCase {
    func testRejectsAmbiguousAndExcessiveFraming() {
        let invalidHeaders = [
            "Content-Length: 1\r\nContent-Length: 2",
            "Content-Length: 0\r\nTransfer-Encoding: chunked",
            "Content-Length: -1", "Content-Length: 4097",
            "Content-Length: 999999999999999999999999999999",
            "Content-Length: 0\r\n folded-header: value",
            "Content-Length: 0\r\nX-Test: bad\nvalue"
        ]
        for headers in invalidHeaders {
            let request = Data("POST /notify HTTP/1.1\r\nHost: localhost:9292\r\n\(headers)\r\n\r\n".utf8)
            XCTAssertThrowsError(try LocalRequestHeader.parse(request), headers)
        }
        XCTAssertThrowsError(try LocalRequestHeader.parse(Data(repeating: 65, count: 4097)))
    }

    func testPartialHeadersWaitAndUnicodeBodyIsCountedAsBytes() throws {
        XCTAssertNil(try LocalRequestHeader.parse(Data("POST /notify HTTP/1.1\r\n".utf8)))
        let body = "{\"message\":\"🔔\"}"
        let request = Data("POST /notify HTTP/1.1\r\nHost: localhost:9292\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8)
        let header = try XCTUnwrap(LocalRequestHeader.parse(request))
        XCTAssertEqual(request.count - header.bodyOffset, header.contentLength)
    }

    func testGeneratedTokenWorksWithConfigWhileHeaderInjectionDoesNot() {
        let token = LocalNotificationServer.generateToken()
        XCTAssertEqual(token.count, 64)
        XCTAssertTrue(ConfigValidator.isValidLocalServerToken(token))
        XCTAssertFalse(ConfigValidator.isValidLocalServerToken(String(repeating: "a", count: 32) + "\r\n"))
    }
}
