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

    @MainActor func testOffSubscriptionAndMalformedMessagesNeverReachDelegate() {
        let replayKey = "lastMessageTime-https://stream-security.invalid/boundaries-subscribed"
        let idKey = "lastMessageID-https://stream-security.invalid/boundaries-subscribed"
        UserDefaults.standard.removeObject(forKey: replayKey)
        UserDefaults.standard.removeObject(forKey: idKey)
        defer {
            UserDefaults.standard.removeObject(forKey: replayKey)
            UserDefaults.standard.removeObject(forKey: idKey)
        }
        let accepted = expectation(description: "Subscribed message delivered")
        let rejected = expectation(description: "Unsubscribed/malformed event not delivered")
        rejected.isInverted = true
        let delegate = MockNtfyDelegate()
        delegate.onMessage = { message in
            if message.id == "valid" && message.topic == "subscribed" && message.message == "é" {
                accepted.fulfill()
            } else {
                rejected.fulfill()
            }
        }
        let client = makeClient(path: "boundaries", fetchMissed: true)
        defer { client.disconnect() }
        client.delegate = delegate
        client.connect()
        waitForExpectations(timeout: 0.3)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: replayKey), 1)
    }

    @MainActor func testSuccessfulConnectCannotCreateDuplicateStreamAndUnrelatedTasksAreIgnored() {
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
        let client = makeClient(path: "holding")
        defer { client.disconnect() }
        client.delegate = delegate
        client.connect()
        wait(for: [connected], timeout: 1)

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
        wait(for: [unexpected], timeout: 0.3)
        XCTAssertEqual(connectCount, 1)
    }

    @MainActor func testDisconnectRetiresQueuedMessagesAndReconnectTimers() {
        let unexpected = expectation(description: "Retired client never dispatches callbacks")
        unexpected.isInverted = true
        let delegate = MockNtfyDelegate()
        delegate.onMessage = { _ in unexpected.fulfill() }
        delegate.onConnect = { unexpected.fulfill() }
        delegate.onDisconnect = { unexpected.fulfill() }
        let client = makeClient(path: "boundaries")
        client.delegate = delegate
        client.connect()
        // The main queue cannot deliver any queued callbacks before this retirement.
        client.disconnect()
        client.connect()
        waitForExpectations(timeout: 0.3)
    }

    func testNonFiniteRetryAfterDoesNotCreateInvalidTimers() {
        let client = NtfyClient(serverURL: "https://example.invalid", topics: ["test"])
        defer { client.disconnect() }
        for value in ["nan", "inf", "-inf", "1e999"] {
            XCTAssertEqual(client.parseRetryAfter(value), 30)
        }
    }

    @MainActor func testReplayUsesExclusiveIDAndDeduplicatesBeforeAutomationDelivery() {
        let path = "cursor-\(UUID().uuidString)"
        let prefix = "https://stream-security.invalid/\(path)-subscribed"
        defer {
            UserDefaults.standard.removeObject(forKey: "lastMessageTime-" + prefix)
            UserDefaults.standard.removeObject(forKey: "lastMessageID-" + prefix)
        }
        let delivered = expectation(description: "New message arrives after reconnect with exclusive cursor")
        var ids: [String] = []
        let delegate = MockNtfyDelegate()
        delegate.onMessage = { message in
            ids.append(message.id)
            if message.id == "second-id" { delivered.fulfill() }
        }
        let client = makeClient(path: path, fetchMissed: true)
        defer { client.disconnect() }
        client.delegate = delegate
        client.connect()
        wait(for: [delivered], timeout: 3)
        XCTAssertEqual(ids, ["first-id", "second-id"])
        XCTAssertEqual(UserDefaults.standard.string(forKey: "lastMessageID-" + prefix), "second-id")
    }

    private func makeClient(path: String, fetchMissed: Bool = false) -> NtfyClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RuntimeSecurityStreamProtocol.self]
        return NtfyClient(serverURL: "https://stream-security.invalid/\(path)", topics: ["subscribed"],
                          fetchMissed: fetchMissed,
                          watchdogInterval: 60, baseReconnectDelay: 0,
                          urlSessionConfiguration: configuration)
    }
}

private final class RuntimeSecurityStreamProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if request.url!.path.contains("cursor-") {
            let cursor = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "since" }?.value
            if cursor == "all" {
                let record = "{\"id\":\"first-id\",\"time\":1,\"event\":\"message\",\"topic\":\"subscribed\"}\n"
                client?.urlProtocol(self, didLoad: Data((record + record).utf8))
                client?.urlProtocolDidFinishLoading(self)
            } else if cursor == "first-id" {
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
        client?.urlProtocol(self, didLoad: Data(payload[..<split]))
        client?.urlProtocol(self, didLoad: Data(payload[split...]))
        // Leave the stream open so EOF cannot mask delivery tests.
    }

    override func stopLoading() {}
}
