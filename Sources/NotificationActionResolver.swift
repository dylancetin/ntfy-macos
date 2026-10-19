import Foundation

/// Represents the resolved action from a notification message.
/// This is used to determine what action to take when a user
/// interacts with a notification.
enum ResolvedAction: Equatable {
    case view(url: URL)
    case none
}

/// A subscription origin is separate from any publisher-supplied click destination.
/// Notifications without this metadata (including legacy/local ones) have no actions.
struct NotificationOrigin: Equatable, Sendable {
    static let userInfoKey = "originatingServerURL"
    let serverURL: String
    let topic: String

    init(serverURL: String, topic: String) {
        self.serverURL = serverURL
        self.topic = topic
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard let serverURL = userInfo[Self.userInfoKey] as? String, !serverURL.isEmpty,
              let topic = userInfo["topic"] as? String, !topic.isEmpty else { return nil }
        self.init(serverURL: serverURL, topic: topic)
    }

    func serverConfig(in config: AppConfig?) -> ServerConfig? {
        config?.serverConfig(forURL: serverURL, topic: topic)
    }
}

/// Resolves only remote web views, with the originating server's current policy.
/// Remote script/file actions are never executable, even when file URLs are configured.
final class NotificationActionResolver {

    func resolve(from message: NtfyMessage, originatingServerURL: String? = nil, config: AppConfig? = nil) -> ResolvedAction {
        guard let originatingServerURL,
              let server = config?.serverConfig(forURL: originatingServerURL, topic: message.topic) else {
            return .none
        }
        if let actions = message.actions {
            for action in actions where action.action == "view" {
                if let urlString = action.url,
                   let url = validatedURL(from: urlString, server: server) {
                    return .view(url: url)
                }
            }
        }

        // Fallback to the publisher's click URL, under the same origin policy.
        if let clickURLString = message.click,
           let clickURL = validatedURL(from: clickURLString, server: server) {
            return .view(url: clickURL)
        }

        return .none
    }

    // MARK: - URL validation

    /// Validates URLs to avoid accepting malformed or unsafe strings.
    /// Only allows web URLs without embedded credentials.
    private func validatedURL(from string: String, server: ServerConfig) -> URL? {
        guard
            let url = URL(string: string),
            let scheme = url.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            let host = url.host, !host.isEmpty,
            url.user == nil, url.password == nil,
            server.isUrlAllowed(url)
        else {
            return nil
        }
        return url
    }
}
