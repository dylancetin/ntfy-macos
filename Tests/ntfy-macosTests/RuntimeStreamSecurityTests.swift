import XCTest
@testable import ntfy_macos

final class RuntimeStreamSecurityTests: XCTestCase {
    func testOversizedUnterminatedAndCompleteRecordsAreRejectedWithoutRetainedBuffer() throws {
        for suffix in [Data(), Data([10])] {
            var buffer = BoundedNDJSONBuffer(limit: 8)
            var delivered = 0
            try buffer.append(Data(repeating: 65, count: 8)) { _ in delivered += 1 }
            XCTAssertEqual(buffer.pending.count, 8)
            XCTAssertThrowsError(try buffer.append(Data([65]) + suffix) { _ in delivered += 1 })
            XCTAssertTrue(buffer.pending.isEmpty)
            XCTAssertEqual(delivered, 0)
        }
        var buffer = BoundedNDJSONBuffer(limit: 8)
        XCTAssertThrowsError(try buffer.append(Data(repeating: 65, count: 1024 * 1024) + Data([10])) { _ in
            XCTFail("Oversized complete record must never be emitted")
        })
        XCTAssertTrue(buffer.pending.isEmpty)
    }

    func testLargeNetworkChunkOfSmallRecordsDoesNotNeedUnboundedStorage() throws {
        var buffer = BoundedNDJSONBuffer(limit: 8)
        var count = 0
        try buffer.append(Data(String(repeating: "12345678\n", count: 10_000).utf8)) { record in
            XCTAssertEqual(record.count, 8)
            count += 1
        }
        XCTAssertEqual(count, 10_000)
        XCTAssertTrue(buffer.pending.isEmpty)
    }

    func testFragmentedUTF8AndExactLimitRecordsPreserveBytes() throws {
        var buffer = BoundedNDJSONBuffer(limit: 4)
        let original = Data("éé".utf8)
        var records: [Data] = []
        try buffer.append(Data(original.prefix(1))) { records.append($0) }
        try buffer.append(Data(original.dropFirst())) { records.append($0) }
        XCTAssertTrue(records.isEmpty)
        try buffer.append(Data([10])) { records.append($0) }
        XCTAssertEqual(records, [original])
        XCTAssertTrue(buffer.pending.isEmpty)
    }

    @MainActor func testOffSubscriptionAndMalformedMessagesNeverReachDelegate() async {
        let probe = RuntimeStreamProbe(path: "boundaries-\(UUID().uuidString)")
        let replayKey = "lastMessageTime-https://stream-security.invalid/\(probe.path)-subscribed"
        let idKey = "lastMessageID-https://stream-security.invalid/\(probe.path)-subscribed"
        UserDefaults.standard.removeObject(forKey: replayKey)
        UserDefaults.standard.removeObject(forKey: idKey)
        defer {
            UserDefaults.standard.removeObject(forKey: replayKey)
            UserDefaults.standard.removeObject(forKey: idKey)
        }
        let accepted = expectation(description: "Subscribed message delivered")
        let connected = expectation(description: "Subscription accepted HTTP 200")
        let rejected = expectation(description: "Unsubscribed/malformed event not delivered")
        rejected.isInverted = true
        let delegate = MockNtfyDelegate()
        delegate.onConnect = { connected.fulfill() }
        delegate.onError = { error in XCTFail("Local mock transport failed (code \((error as NSError).code))") }
        delegate.onMessage = { message in
            if message.id == "valid" && message.topic == "subscribed" && message.message == "é" {
                accepted.fulfill()
            } else {
                rejected.fulfill()
            }
        }
        let client = makeClient(probe: probe, fetchMissed: true)
        defer {
            client.disconnect()
            RuntimeSecurityStreamProtocol.removeProbe(probe)
            withExtendedLifetime(delegate) {}
        }
        client.delegate = delegate
        client.connect()
        guard await awaitCallbacks([probe.requestStarted, connected, accepted], client: client, probe: probe) else { return }
        let rejectionResult = await XCTWaiter.fulfillment(of: [rejected], timeout: 0.3)
        XCTAssertEqual(rejectionResult, .completed)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: replayKey), 1)
        XCTAssertEqual(UserDefaults.standard.string(forKey: idKey), "valid")
        XCTAssertEqual(client.connectionDiagnostics.taskCallbacksRejected, 0)
    }

    @MainActor func testSuccessfulConnectCannotCreateDuplicateStreamAndUnrelatedTasksAreIgnored() async {
        let probe = RuntimeStreamProbe(path: "holding-\(UUID().uuidString)")
        let connected = expectation(description: "Initial stream connected")
        let unexpected = expectation(description: "No duplicate or stale callbacks")
        unexpected.isInverted = true
        let delegate = MockNtfyDelegate()
        var connectCount = 0
        delegate.onConnect = {
            connectCount += 1
            if connectCount == 1 { connected.fulfill() } else { unexpected.fulfill() }
        }
        delegate.onMessage = { _ in unexpected.fulfill() }
        delegate.onDisconnect = { unexpected.fulfill() }
        delegate.onError = { _ in unexpected.fulfill() }
        let client = makeClient(probe: probe)
        defer {
            client.disconnect()
            RuntimeSecurityStreamProtocol.removeProbe(probe)
            withExtendedLifetime(delegate) {}
        }
        client.delegate = delegate
        client.connect()
        guard await awaitCallbacks([probe.requestStarted, connected], client: client, probe: probe) else { return }
        XCTAssertEqual(client.connectionDiagnostics.responsesAccepted, 1)
        XCTAssertEqual(client.connectionDiagnostics.taskCallbacksRejected, 0)

        client.connect() // HTTP 200 cleared the old isConnecting flag; must still be idempotent.
        let foreignSession = URLSession(configuration: .ephemeral)
        defer { foreignSession.invalidateAndCancel() }
        let foreignTask = foreignSession.dataTask(with: URL(string: "https://unrelated.invalid")!)
        let payload = Data("{\"id\":\"stale\",\"event\":\"message\",\"topic\":\"subscribed\",\"time\":1}\n".utf8)
        client.urlSession(foreignSession, dataTask: foreignTask, didReceive: payload)
        client.urlSession(foreignSession, task: foreignTask, didCompleteWithError: URLError(.timedOut))
        let response = HTTPURLResponse(url: foreignTask.originalRequest!.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        var disposition: URLSession.ResponseDisposition?
        client.urlSession(foreignSession, dataTask: foreignTask, didReceive: response) { disposition = $0 }
        XCTAssertEqual(disposition, .cancel)
        let result = await XCTWaiter.fulfillment(of: [unexpected], timeout: 0.3)
        XCTAssertEqual(result, .completed, "\(probe.snapshot); \(client.connectionDiagnostics)")
        XCTAssertEqual(connectCount, 1)
        XCTAssertEqual(probe.snapshot.requestCount, 1, "connect() must not start a second protocol request")
        XCTAssertEqual(client.connectionDiagnostics.tasksStarted, 1)
        XCTAssertEqual(client.connectionDiagnostics.taskCallbacksRejected, 3)
    }

    @MainActor func testDisconnectRetiresQueuedMessagesAndReconnectTimers() async {
        let probe = RuntimeStreamProbe(path: "boundaries-\(UUID().uuidString)")
        let unexpected = expectation(description: "Retired client never dispatches callbacks")
        unexpected.isInverted = true
        let delegate = MockNtfyDelegate()
        delegate.onMessage = { _ in unexpected.fulfill() }
        delegate.onConnect = { unexpected.fulfill() }
        delegate.onDisconnect = { unexpected.fulfill() }
        let client = makeClient(probe: probe)
        defer {
            client.disconnect()
            RuntimeSecurityStreamProtocol.removeProbe(probe)
            withExtendedLifetime(delegate) {}
        }
        client.delegate = delegate
        client.connect()
        // The main queue cannot deliver any queued callbacks before this retirement.
        client.disconnect()
        client.connect()
        // Suspending lets the main queue actually attempt delivery; a synchronous wait can hide bugs.
        let result = await XCTWaiter.fulfillment(of: [unexpected], timeout: 0.3)
        XCTAssertEqual(result, .completed, "\(probe.snapshot); \(client.connectionDiagnostics)")
        XCTAssertEqual(client.connectionDiagnostics.tasksStarted, 1)
    }

    func testNonFiniteRetryAfterDoesNotCreateInvalidTimers() {
        let client = NtfyClient(serverURL: "https://example.invalid", topics: ["test"])
        defer { client.disconnect() }
        for value in ["nan", "inf", "-inf", "1e999"] {
            XCTAssertEqual(client.parseRetryAfter(value), 30)
        }
    }

    @MainActor func testReplayUsesExclusiveIDAndDeduplicatesBeforeAutomationDelivery() async {
        let probe = RuntimeStreamProbe(path: "cursor-\(UUID().uuidString)")
        let path = probe.path
        let prefix = "https://stream-security.invalid/\(path)-subscribed"
        defer {
            UserDefaults.standard.removeObject(forKey: "lastMessageTime-" + prefix)
            UserDefaults.standard.removeObject(forKey: "lastMessageID-" + prefix)
        }
        let delivered = expectation(description: "New message arrives after reconnect with exclusive cursor")
        var ids: [String] = []
        let delegate = MockNtfyDelegate()
        delegate.onError = { error in XCTFail("Local replay transport failed (code \((error as NSError).code))") }
        delegate.onMessage = { message in
            ids.append(message.id)
            if message.id == "second-id" { delivered.fulfill() }
        }
        let client = makeClient(probe: probe, fetchMissed: true)
        defer {
            client.disconnect()
            RuntimeSecurityStreamProtocol.removeProbe(probe)
            withExtendedLifetime(delegate) {}
        }
        client.delegate = delegate
        client.connect()
        guard await awaitCallbacks([probe.requestStarted, delivered], client: client, probe: probe) else { return }
        XCTAssertEqual(ids, ["first-id", "second-id"])
        XCTAssertEqual(UserDefaults.standard.string(forKey: "lastMessageID-" + prefix), "second-id")
        XCTAssertEqual(probe.snapshot.cursors, ["all", "first-id"])
    }

    @MainActor private func awaitCallbacks(_ expectations: [XCTestExpectation], client: NtfyClient,
                                           probe: RuntimeStreamProbe, file: StaticString = #filePath, line: UInt = #line) async -> Bool {
        // Do not use synchronous XCTest waits on MainActor: NtfyClient delivers on the main queue.
        // The static async waiter also avoids sending this non-Sendable XCTestCase off its actor.
        let result = await XCTWaiter.fulfillment(of: expectations, timeout: 3)
        XCTAssertEqual(result, .completed, "Protocol stages: \(probe.snapshot); client stages: \(client.connectionDiagnostics)", file: file, line: line)
        return result == .completed
    }

    private func makeClient(probe: RuntimeStreamProbe, fetchMissed: Bool = false) -> NtfyClient {
        RuntimeSecurityStreamProtocol.registerProbe(probe)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RuntimeSecurityStreamProtocol.self]
        return NtfyClient(serverURL: "https://stream-security.invalid/\(probe.path)", topics: ["subscribed"],
                          fetchMissed: fetchMissed,
                          watchdogInterval: 60, baseReconnectDelay: 0,
                          urlSessionConfiguration: configuration)
    }
}

/// Per-test instrumentation, independent of the app's logger and main-queue delegate delivery.
private final class RuntimeStreamProbe: @unchecked Sendable {
    struct Snapshot: Sendable {
        var requestCount = 0
        var requestsWithoutProtocolClient = 0
        var responsesSent = 0
        var dataChunksSent = 0
        var cursors: [String] = []
    }

    let path: String
    let requestStarted = XCTestExpectation(description: "Local URLProtocol startLoading ran")
    private let lock = NSLock()
    private var state = Snapshot()

    init(path: String) { self.path = path }

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    func start(cursor: String?, hasClient: Bool) {
        lock.lock()
        state.requestCount += 1
        let isFirst = state.requestCount == 1
        if !hasClient { state.requestsWithoutProtocolClient += 1 }
        if state.cursors.count < 8 { state.cursors.append(cursor ?? "none") }
        lock.unlock()
        if isFirst { requestStarted.fulfill() }
    }

    func sentResponse() {
        lock.lock()
        state.responsesSent += 1
        lock.unlock()
    }

    func sentData() {
        lock.lock()
        state.dataChunksSent += 1
        lock.unlock()
    }
}

private final class RuntimeSecurityStreamProtocol: URLProtocol {
    private static let probeLock = NSLock()
    nonisolated(unsafe) private static var probes: [String: RuntimeStreamProbe] = [:]

    static func registerProbe(_ probe: RuntimeStreamProbe) {
        probeLock.lock()
        defer { probeLock.unlock() }
        probes["/\(probe.path)/subscribed/json"] = probe
    }

    static func removeProbe(_ probe: RuntimeStreamProbe) {
        probeLock.lock()
        defer { probeLock.unlock() }
        probes.removeValue(forKey: "/\(probe.path)/subscribed/json")
    }

    private static func probe(for path: String) -> RuntimeStreamProbe? {
        probeLock.lock()
        defer { probeLock.unlock() }
        return probes[path]
    }

    // Claim every request, including unexpected URLs, so these tests can never fall through to DNS/network.
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let probe = Self.probe(for: url.path) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let cursor = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "since" }?.value
        probe.start(cursor: cursor, hasClient: client != nil)
        // Match ntfy's streaming response. A missing MIME type permits CFNetwork content sniffing,
        // which may buffer a small/open mock stream instead of immediately delivering its response.
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/x-ndjson"])!
        probe.sentResponse()
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if request.url!.path.contains("cursor-") {
            if cursor == "all" {
                let record = "{\"id\":\"first-id\",\"time\":1,\"event\":\"message\",\"topic\":\"subscribed\"}\n"
                probe.sentData()
                client?.urlProtocol(self, didLoad: Data((record + record).utf8))
                client?.urlProtocolDidFinishLoading(self)
            } else if cursor == "first-id" {
                probe.sentData()
                client?.urlProtocol(self, didLoad: Data("{\"id\":\"second-id\",\"time\":1,\"event\":\"message\",\"topic\":\"subscribed\"}\n".utf8))
            }
            return
        }
        guard request.url!.path.contains("boundaries") else { return }
        let payload = Data("""
        {"id":"foreign","time":999,"event":"message","topic":"privileged","message":"must not execute"}
        {"id":"keepalive","time":999,"event":"keepalive","topic":"subscribed"}
        invalid json
        {"id":"valid","time":1,"event":"message","topic":"subscribed","message":"é"}

        """.utf8)
        // Split inside a multi-byte UTF-8 sequence.
        let split = payload.firstIndex(of: 0xC3)!.advanced(by: 1)
        probe.sentData()
        client?.urlProtocol(self, didLoad: Data(payload[..<split]))
        probe.sentData()
        client?.urlProtocol(self, didLoad: Data(payload[split...]))
        // Leave the stream open so EOF cannot mask delivery tests.
    }

    override func stopLoading() {}
}
