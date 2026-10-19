import XCTest
import UserNotifications
@testable import ntfy_macos

final class RuntimeNotificationSecurityTests: XCTestCase {
    private let originURL = "https://notifications.example"

    private func server(domains: [String]? = ["actions.example"], schemes: [String]? = nil) -> ServerConfig {
        ServerConfig(url: originURL, topics: [TopicConfig(name: "shared")], allowedSchemes: schemes, allowedDomains: domains)
    }

    func testNotificationOriginNeverUsesClickURLOrLegacyTopicFallback() throws {
        let config = AppConfig(servers: [
            server(domains: []),
            ServerConfig(url: "https://privileged.example", topics: [TopicConfig(name: "shared", autoRunScript: "/trusted/script")])
        ])
        XCTAssertNil(NotificationOrigin(userInfo: ["topic": "shared", "serverUrl": "https://privileged.example"]))
        XCTAssertNil(NotificationOrigin(userInfo: ["topic": "shared", "clickURL": originURL]))
        let origin = try XCTUnwrap(NotificationOrigin(userInfo: [
            NotificationOrigin.userInfoKey: originURL,
            "topic": "shared",
            "clickURL": "https://privileged.example"
        ]))
        XCTAssertEqual(origin.serverConfig(in: config)?.url, originURL)
        XCTAssertNil(origin.serverConfig(in: config)?.topics.first?.autoRunScript)
        XCTAssertNil(NotificationOrigin(serverURL: originURL, topic: "unsubscribed").serverConfig(in: config))
        XCTAssertNil(NotificationOrigin(serverURL: "https://removed.example", topic: "shared").serverConfig(in: config))
    }

    func testLocalNotificationContentHasNoActionsEvenWithMaliciousPayload() throws {
        let json = """
        {"id":"local", "time":1, "event":"message", "topic":"shared", "message":"local message",
         "click":"https://actions.example", "actions":[{"action":"script","label":"Run","url":"file:///tmp/evil"}]}
        """
        let message = try JSONDecoder().decode(NtfyMessage.self, from: Data(json.utf8))
        let content = NotificationManager.basicContent(for: message)
        XCTAssertEqual(content.body, "local message")
        XCTAssertTrue(content.userInfo.isEmpty)
        XCTAssertTrue(content.categoryIdentifier.isEmpty)
    }

    func testHTTPActionsRequireExplicitDomainConsent() {
        for destination in ["https://actions.example", "http://127.0.0.1/admin", "http://192.168.1.1", "http://[::1]", "http://169.254.169.254/latest/meta-data"] {
            let url = URL(string: destination)!
            XCTAssertNil(HTTPActionPolicy.request(url: url, details: [:], server: server(domains: nil)))
            XCTAssertNil(HTTPActionPolicy.request(url: url, details: [:], server: server(domains: [])))
        }
        XCTAssertNotNil(HTTPActionPolicy.request(url: URL(string: "https://actions.example/run")!, details: [:], server: server()))
    }

    func testHTTPActionsObeySchemesDomainsAndCredentialRules() {
        let policy = server(schemes: ["https", "file", "custom"])
        for destination in [
            "http://actions.example", "https://actions.example.attacker.invalid", "https://attacker.invalid/actions.example",
            "https://user:secret@actions.example", "https://user@actions.example", "https://@actions.example",
            "https://actions.example/#fragment", "file:///tmp/evil", "custom://actions.example", "https:/missing-host"
        ] {
            XCTAssertNil(HTTPActionPolicy.request(url: URL(string: destination)!, details: [:], server: policy), destination)
        }
        let wildcard = server(domains: ["*.actions.example"])
        XCTAssertNotNil(HTTPActionPolicy.request(url: URL(string: "https://api.actions.example")!, details: [:], server: wildcard))
        XCTAssertNil(HTTPActionPolicy.request(url: URL(string: "https://evilactions.example")!, details: [:], server: wildcard))
    }

    func testHTTPActionsRejectFramingHeadersCredentialsCookiesAndInjection() {
        let url = URL(string: "https://actions.example")!
        for headers in [
            ["Host": "other.example"], ["COOKIE": "session=secret"], ["Proxy-Authorization": "Basic secret"],
            ["Content-Length": "999"], ["Transfer-Encoding": "chunked"], ["Connection": "keep-alive"],
            ["X-Test\r\nInjected": "value"], ["X-Test": "value\r\nInjected: yes"], ["X-Test": "a\u{0}b"],
            ["X-Test": "a", "x-test": "b"]
        ] {
            XCTAssertNil(HTTPActionPolicy.request(url: url, details: ["headers": headers], server: server()))
        }
        for method in ["CONNECT", "TRACE", "GET\r\nInjected: yes", "arbitrary"] {
            XCTAssertNil(HTTPActionPolicy.request(url: url, details: ["method": method], server: server()))
        }
        XCTAssertNil(HTTPActionPolicy.request(url: url, details: ["headers": ["X-Test": 1]], server: server()))
    }

    func testHTTPRequestLimitsUseBytesAndPreserveValidExplicitPayload() throws {
        let url = URL(string: "https://actions.example/run")!
        let body = String(repeating: "é", count: HTTPActionPolicy.maxBodyBytes / 2)
        let request = try XCTUnwrap(HTTPActionPolicy.request(url: url, details: ["method": "post", "body": body, "headers": ["X-Explicit": "allowed"]], server: server()))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.httpBody?.count, HTTPActionPolicy.maxBodyBytes)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Explicit"), "allowed")
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.timeoutInterval, HTTPActionPolicy.requestTimeout)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(HTTPActionPolicy.request(url: url, details: ["body": body + "x"], server: server()))
        XCTAssertNil(HTTPActionPolicy.request(url: url, details: ["headers": ["X-Large": String(repeating: "x", count: HTTPActionPolicy.maxHeaderBytes)]], server: server()))
        let headers = Dictionary(uniqueKeysWithValues: (0...HTTPActionPolicy.maxHeaders).map { ("X-\($0)", "x") })
        XCTAssertNil(HTTPActionPolicy.request(url: url, details: ["headers": headers], server: server()))
        let longURL = URL(string: "https://actions.example/" + String(repeating: "x", count: HTTPActionPolicy.maxURLBytes))!
        XCTAssertNil(HTTPActionPolicy.request(url: longURL, details: [:], server: server()))
    }

    func testHTTPTransportHasNoAmbientStateAndFiniteTimeouts() {
        let configuration = HTTPActionPolicy.sessionConfiguration()
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.urlCache)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 15)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 30)
    }

    func testOnlySystemTLSTrustHandlingIsAllowedForAuthenticationChallenges() {
        XCTAssertEqual(NetworkAuthenticationPolicy.disposition(for: NSURLAuthenticationMethodServerTrust), .performDefaultHandling)
        for method in [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest,
                       NSURLAuthenticationMethodNTLM, NSURLAuthenticationMethodNegotiate,
                       NSURLAuthenticationMethodClientCertificate, NSURLAuthenticationMethodDefault] {
            XCTAssertEqual(NetworkAuthenticationPolicy.disposition(for: method), .cancelAuthenticationChallenge)
        }
    }

    func testResponseBudgetRejectsChunkedOverflowWithoutIntegerOverflow() {
        var budget = HTTPActionResponseBudget()
        XCTAssertTrue(budget.accept(byteCount: HTTPActionPolicy.maxResponseBytes - 1))
        XCTAssertTrue(budget.accept(byteCount: 1))
        XCTAssertFalse(budget.accept(byteCount: Int.max))
        XCTAssertFalse(budget.accept(byteCount: 0))
        XCTAssertEqual(budget.received, HTTPActionPolicy.maxResponseBytes)
    }

    func testHTTPRedirectsAreRejectedEvenWithinAllowedDomain() {
        let executor = HTTPActionExecutor()
        defer { executor.invalidate() }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://actions.example/start")!
        for destination in ["https://actions.example/next", "http://127.0.0.1/admin", "file:///tmp/evil"] {
            let task = session.dataTask(with: url)
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": destination])!
            var called = false
            executor.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: URL(string: destination)!)) { request in
                called = true
                XCTAssertNil(request)
            }
            XCTAssertTrue(called)
        }
    }

    func testOversizedDeclaredHTTPResponseIsCancelledBeforeBody() {
        let executor = HTTPActionExecutor()
        defer { executor.invalidate() }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://actions.example")!
        let task = session.dataTask(with: url)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": String(HTTPActionPolicy.maxResponseBytes + 1)])!
        var disposition: URLSession.ResponseDisposition?
        executor.urlSession(session, dataTask: task, didReceive: response) { disposition = $0 }
        XCTAssertEqual(disposition, .cancel)
    }

    func testHTTPConcurrencyIsBoundedAndReloadCancellationReleasesSlots() {
        let executor = HTTPActionExecutor(protocolClasses: [RuntimeSecurityHoldingHTTPProtocol.self])
        defer { executor.invalidate() }
        let url = URL(string: "https://actions.example")!
        for _ in 0..<HTTPActionPolicy.maxConcurrentRequests {
            XCTAssertTrue(executor.execute(url: url, details: [:], server: server()))
        }
        XCTAssertFalse(executor.execute(url: url, details: [:], server: server()))
        executor.cancelAll()
        XCTAssertTrue(executor.execute(url: url, details: [:], server: server()))
    }

    func testAllURLActionsRejectCredentialsAndRemoteFiles() {
        let config = server(domains: nil, schemes: ["http", "https", "file", "myapp"])
        XCTAssertFalse(NotificationURLPolicy.isAllowed(URL(string: "file:///tmp/evil")!, server: config))
        XCTAssertFalse(NotificationURLPolicy.isAllowed(URL(string: "https://user:password@actions.example")!, server: config))
        XCTAssertFalse(NotificationURLPolicy.isAllowed(URL(string: "https:/missing-host")!, server: config))
        XCTAssertTrue(NotificationURLPolicy.isAllowed(URL(string: "myapp://open")!, server: config))
    }

    func testCategoryFloodRetainsOnlyRecentBoundedSet() {
        var store = BoundedNotificationCategories()
        for index in 0..<(BoundedNotificationCategories.limit * 4) {
            store.insert(UNNotificationCategory(identifier: "notification-\(index)", actions: [], intentIdentifiers: [], options: []))
        }
        XCTAssertEqual(store.categories.count, BoundedNotificationCategories.limit)
        XCTAssertFalse(store.categories.contains { $0.identifier == "notification-0" })
        let latest = store.categories.last!
        store.insert(latest)
        XCTAssertEqual(store.categories.count, BoundedNotificationCategories.limit)
        XCTAssertEqual(store.categories.last?.identifier, latest.identifier)
    }
}

private final class RuntimeSecurityHoldingHTTPProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }
    override func stopLoading() {}
}
