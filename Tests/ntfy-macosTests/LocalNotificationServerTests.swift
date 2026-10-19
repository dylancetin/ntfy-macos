import XCTest
import Network
@testable import ntfy_macos

final class LocalNotificationServerTests: XCTestCase {
    var server: LocalNotificationServer!
    let testPort: UInt16 = 19292  // Use a non-standard port for tests
    let token = String(repeating: "a", count: 64)

    override func setUp() {
        super.setUp()
        server = LocalNotificationServer(port: testPort, authToken: token)
        server.onNotification = nil  // Disable actual notifications in tests
        try? server.start()
        // Give the server time to start
        Thread.sleep(forTimeInterval: 0.5)
    }

    override func tearDown() {
        server.stop()
        server = nil
        // Give the server time to release the port
        Thread.sleep(forTimeInterval: 0.3)
        super.tearDown()
    }

    // MARK: - Helpers

    private func sendRequest(method: String = "POST", path: String = "/notify", body: String? = nil,
                             authorized: Bool = true, contentType: String = "application/json",
                             extraHeaders: [String: String] = [:]) -> (statusCode: Int, body: String)? {
        let expectation = XCTestExpectation(description: "HTTP request")
        nonisolated(unsafe) var resultStatus: Int = 0
        nonisolated(unsafe) var resultBody: String = ""

        guard let url = URL(string: "http://127.0.0.1:\(testPort)\(path)") else {
            XCTFail("Invalid URL")
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        if authorized { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (name, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: name) }
        if let body = body {
            request.httpBody = body.data(using: .utf8)
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let httpResponse = response as? HTTPURLResponse {
                resultStatus = httpResponse.statusCode
            }
            if let data = data {
                resultBody = String(data: data, encoding: .utf8) ?? ""
            }
            expectation.fulfill()
        }.resume()

        wait(for: [expectation], timeout: 5.0)
        return (resultStatus, resultBody)
    }

    // MARK: - Health Check

    func testHealthCheck() throws {
        let result = sendRequest(method: "GET", path: "/health")
        XCTAssertEqual(result?.statusCode, 200)
        XCTAssertTrue(result?.body.contains("\"status\":\"ok\"") ?? false)
    }

    // MARK: - POST /notify

    func testValidNotification() throws {
        let body = """
        {"title": "Test", "message": "Hello World"}
        """
        let result = sendRequest(body: body)
        XCTAssertEqual(result?.statusCode, 200)
        XCTAssertTrue(result?.body.contains("\"success\":true") ?? false)
    }

    func testNotificationWithAllFields() throws {
        let body = """
        {"title": "Alert", "message": "Server down", "priority": 5, "tags": ["warning", "fire"]}
        """
        let result = sendRequest(body: body)
        XCTAssertEqual(result?.statusCode, 200)
        XCTAssertTrue(result?.body.contains("\"success\":true") ?? false)
    }

    func testMissingTitle() throws {
        let body = """
        {"message": "No title here"}
        """
        let result = sendRequest(body: body)
        XCTAssertEqual(result?.statusCode, 400)
        XCTAssertTrue(result?.body.contains("title") ?? false)
    }

    func testMissingMessage() throws {
        let body = """
        {"title": "No message"}
        """
        let result = sendRequest(body: body)
        XCTAssertEqual(result?.statusCode, 400)
        XCTAssertTrue(result?.body.contains("message") ?? false)
    }

    func testEmptyTitle() throws {
        let body = """
        {"title": "", "message": "Hello"}
        """
        let result = sendRequest(body: body)
        XCTAssertEqual(result?.statusCode, 400)
        XCTAssertTrue(result?.body.contains("title") ?? false)
    }

    func testEmptyMessage() throws {
        let body = """
        {"title": "Test", "message": ""}
        """
        let result = sendRequest(body: body)
        XCTAssertEqual(result?.statusCode, 400)
        XCTAssertTrue(result?.body.contains("message") ?? false)
    }

    func testInvalidJSON() throws {
        let result = sendRequest(body: "not json at all")
        XCTAssertEqual(result?.statusCode, 400)
        XCTAssertTrue(result?.body.contains("Invalid JSON") ?? false)
    }

    // MARK: - Wrong Path / Method

    func testWrongPath() throws {
        let result = sendRequest(method: "GET", path: "/wrong")
        XCTAssertEqual(result?.statusCode, 404)
    }

    func testGetOnNotify() throws {
        let result = sendRequest(method: "GET", path: "/notify")
        XCTAssertEqual(result?.statusCode, 404)
    }

    func testUnauthenticatedNotificationAndHealthRejected() {
        XCTAssertEqual(sendRequest(body: "{\"title\":\"test\",\"message\":\"body\"}", authorized: false)?.statusCode, 401)
        XCTAssertEqual(sendRequest(method: "GET", path: "/health", authorized: false)?.statusCode, 401)
    }

    func testWrongBearerTokenRejected() {
        XCTAssertEqual(sendRequest(body: "{}", extraHeaders: ["Authorization": "Bearer wrong"])?.statusCode, 401)
    }

    func testBrowserOriginAndTextPlainRejected() {
        XCTAssertEqual(sendRequest(body: "{}", extraHeaders: ["Origin": "https://evil.example"])?.statusCode, 403)
        XCTAssertEqual(sendRequest(body: "{}", contentType: "text/plain")?.statusCode, 415)
    }

    func testLocalPayloadCannotAttachActions() {
        let notification = expectation(description: "local notification")
        server.onNotification = { message in
            XCTAssertNil(message.actions)
            XCTAssertNil(message.click)
            XCTAssertEqual(message.topic, "local")
            notification.fulfill()
        }
        let body = """
        {"title":"test","message":"body","click":"file:///tmp/payload","actions":[{"action":"script","url":"file:///tmp/payload"}]}
        """
        XCTAssertEqual(sendRequest(body: body)?.statusCode, 200)
        wait(for: [notification], timeout: 2)
    }
}
