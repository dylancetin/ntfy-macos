import XCTest
@testable import ntfy_macos

class NotificationActionResolverTests: XCTestCase {
    private let origin = "https://ntfy.example.com"
    private var configuration: AppConfig {
        AppConfig(servers: [ServerConfig(url: origin, topics: [TopicConfig(name: "test")], allowedDomains: ["example.com"])])
    }

    func testRemoteScriptActionIsIgnoredInFavorOfAllowedView() {
        let message = NtfyMessage(
            id: "msg1",
            time: 1,
            event: "message",
            topic: "test",
            message: "Hello",
            title: "Test",
            priority: nil,
            tags: nil,
            click: nil,
            actions: [
                NtfyMessage.NtfyAction(
                    action: "view",
                    label: "Open",
                    url: "https://example.com",
                    method: nil,
                    headers: nil,
                    body: nil,
                    clear: nil
                ),
                NtfyMessage.NtfyAction(
                    action: "script",
                    label: "Run",
                    url: "file:///tmp/test.sh",
                    method: nil,
                    headers: nil,
                    body: nil,
                    clear: nil
                )
            ],
            attachment: nil,
            contentType: nil
        )

        let resolver = NotificationActionResolver()
        let action = resolver.resolve(from: message, originatingServerURL: origin, config: configuration)

        XCTAssertEqual(action, .view(url: URL(string: "https://example.com")!))
    }

    func testViewActionIsChosenWhenNoScriptAction() {
        let message = NtfyMessage(
            id: "msg1",
            time: 1,
            event: "message",
            topic: "test",
            message: "Hello",
            title: "Test",
            priority: nil,
            tags: nil,
            click: nil,
            actions: [
                NtfyMessage.NtfyAction(
                    action: "view",
                    label: "Open",
                    url: "https://example.com",
                    method: nil,
                    headers: nil,
                    body: nil,
                    clear: nil
                )
            ],
            attachment: nil,
            contentType: nil
        )

        let resolver = NotificationActionResolver()
        let action = resolver.resolve(from: message, originatingServerURL: origin, config: configuration)

        XCTAssertEqual(action, .view(url: URL(string: "https://example.com")!))
    }

    func testClickURLIsUsedAsFallback() {
        let message = NtfyMessage(
            id: "msg1",
            time: 1,
            event: "message",
            topic: "test",
            message: "Hello",
            title: "Test",
            priority: nil,
            tags: nil,
            click: "https://example.com/click",
            actions: [],
            attachment: nil,
            contentType: nil
        )

        let resolver = NotificationActionResolver()
        let action = resolver.resolve(from: message, originatingServerURL: origin, config: configuration)

        XCTAssertEqual(action, .view(url: URL(string: "https://example.com/click")!))
    }

    func testNoActionIsReturnedWhenNoActionsOrClickURL() {
        let message = NtfyMessage(
            id: "msg1",
            time: 1,
            event: "message",
            topic: "test",
            message: "Hello",
            title: "Test",
            priority: nil,
            tags: nil,
            click: nil,
            actions: [],
            attachment: nil,
            contentType: nil
        )

        let resolver = NotificationActionResolver()
        let action = resolver.resolve(from: message, originatingServerURL: origin, config: configuration)

        XCTAssertEqual(action, .none)
    }

    func testMalformedURLinActionIsIgnored() {
        let message = NtfyMessage(
            id: "msg1",
            time: 1,
            event: "message",
            topic: "test",
            message: "Hello",
            title: "Test",
            priority: nil,
            tags: nil,
            click: nil,
            actions: [
                NtfyMessage.NtfyAction(
                    action: "view",
                    label: "View",
                    url: "a malformed url",
                    method: nil,
                    headers: nil,
                    body: nil,
                    clear: nil
                )
            ],
            attachment: nil,
            contentType: nil
        )

        let resolver = NotificationActionResolver()
        let action = resolver.resolve(from: message, originatingServerURL: origin, config: configuration)

        XCTAssertEqual(action, .none)
    }

    func testRemoteFileScriptCredentialsAndUnknownSchemesAreRejected() throws {
        for (type, url) in [
            ("script", "file:///tmp/publisher.sh"),
            ("view", "file:///tmp/publisher.sh"),
            ("view", "https://user:password@example.com"),
            ("view", "javascript:alert(1)"),
            ("view", "https://example.com.evil.invalid"),
            ("view", "https:/missing-host")
        ] {
            let message = try message(action: type, url: url, click: url)
            XCTAssertEqual(NotificationActionResolver().resolve(from: message, originatingServerURL: origin, config: configuration), .none, url)
        }
    }

    func testMissingOrRemovedOriginFailsClosed() throws {
        let message = try message(action: "view", url: "https://example.com")
        let resolver = NotificationActionResolver()
        XCTAssertEqual(resolver.resolve(from: message, config: configuration), .none)
        XCTAssertEqual(resolver.resolve(from: message, originatingServerURL: "https://removed.example.com", config: configuration), .none)
    }

    func testSameTopicOnDifferentServersUsesOriginPolicy() throws {
        let config = AppConfig(servers: [
            ServerConfig(url: "https://trusted.invalid", topics: [TopicConfig(name: "test")], allowedDomains: ["example.com"]),
            ServerConfig(url: "https://publisher.invalid", topics: [TopicConfig(name: "test")], allowedDomains: [])
        ])
        let message = try message(action: "view", url: "https://example.com")
        let resolver = NotificationActionResolver()
        XCTAssertEqual(resolver.resolve(from: message, originatingServerURL: "https://publisher.invalid", config: config), .none)
        XCTAssertEqual(resolver.resolve(from: message, originatingServerURL: "https://trusted.invalid", config: config), .view(url: URL(string: "https://example.com")!))
    }

    private func message(action: String, url: String, click: String? = nil) throws -> NtfyMessage {
        var json: [String: Any] = [
            "id": "security", "time": 1, "event": "message", "topic": "test",
            "actions": [["action": action, "label": "Untrusted", "url": url]]
        ]
        if let click { json["click"] = click }
        return try JSONDecoder().decode(NtfyMessage.self, from: JSONSerialization.data(withJSONObject: json))
    }
}
