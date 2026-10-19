import Foundation
@preconcurrency import UserNotifications
import AppKit

enum NotificationURLPolicy {
    static func isAllowed(_ url: URL, server: ServerConfig) -> Bool {
        guard !url.isFileURL, url.user == nil, url.password == nil,
              url.absoluteString.utf8.count <= HTTPActionPolicy.maxURLBytes,
              server.isUrlAllowed(url) else { return false }
        if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            return url.host?.isEmpty == false
        }
        return true
    }
}

enum HTTPActionPolicy {
    static let maxURLBytes = 8192
    static let maxBodyBytes = 64 * 1024
    static let maxHeaderBytes = 16 * 1024
    static let maxHeaders = 32
    static let maxResponseBytes = 1024 * 1024
    static let maxConcurrentRequests = 4
    static let requestTimeout: TimeInterval = 15
    static let resourceTimeout: TimeInterval = 30

    /// Publisher-triggered HTTP requires explicit domain consent, including for LAN hosts.
    static func request(url: URL, details: [String: Any], server: ServerConfig) -> URLRequest? {
        guard url.absoluteString.utf8.count <= maxURLBytes,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil,
              let domains = server.allowedDomains, !domains.isEmpty,
              server.isUrlAllowed(url) else { return nil }

        let method = (details["method"] as? String)?.uppercased() ?? "POST"
        guard ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"].contains(method) else { return nil }
        if details["method"] != nil && !(details["method"] is String) { return nil }
        if details["body"] != nil && !(details["body"] is String) { return nil }
        if details["headers"] != nil && !(details["headers"] is [String: String]) { return nil }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: requestTimeout)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        if let body = details["body"] as? String {
            guard body.utf8.count <= maxBodyBytes else { return nil }
            request.httpBody = Data(body.utf8)
        }
        if let headers = details["headers"] as? [String: String] {
            guard headers.count <= maxHeaders else { return nil }
            let forbidden: Set<String> = ["host", "cookie", "cookie2", "proxy-authorization", "proxy-connection", "connection", "content-length", "transfer-encoding", "upgrade", "expect", "te", "trailer"]
            let tokenCharacters = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
            var bytes = 0
            var names: Set<String> = []
            for (name, value) in headers {
                guard !name.isEmpty, name.unicodeScalars.allSatisfy({ tokenCharacters.contains($0) }),
                      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                      !forbidden.contains(name.lowercased()), names.insert(name.lowercased()).inserted,
                      name.utf8.count <= maxHeaderBytes - bytes else { return nil }
                bytes += name.utf8.count
                guard value.utf8.count <= maxHeaderBytes - bytes else { return nil }
                bytes += value.utf8.count
                request.setValue(value, forHTTPHeaderField: name)
            }
        }
        return request
    }

    static func sessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        config.httpMaximumConnectionsPerHost = maxConcurrentRequests
        return config
    }
}

/// Streaming accounting: response bodies are discarded, never accumulated or logged.
struct HTTPActionResponseBudget {
    private(set) var received = 0
    private var rejected = false

    mutating func accept(byteCount: Int) -> Bool {
        guard !rejected, byteCount >= 0, byteCount <= HTTPActionPolicy.maxResponseBytes - received else {
            rejected = true
            return false
        }
        received += byteCount
        return true
    }
}

final class HTTPActionExecutor: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct ActiveRequest {
        let task: URLSessionDataTask
        var budget = HTTPActionResponseBudget()
    }
    private let lock = NSLock()
    private var requests: [Int: ActiveRequest] = [:]
    private var session: URLSession!

    init(protocolClasses: [AnyClass]? = nil) {
        super.init()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let configuration = HTTPActionPolicy.sessionConfiguration()
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    func cancelAll() {
        lock.lock()
        defer { lock.unlock() }
        for request in requests.values { request.task.cancel() }
        requests.removeAll()
    }

    func invalidate() {
        cancelAll()
        session.invalidateAndCancel()
    }

    @discardableResult
    func execute(url: URL, details: [String: Any], server: ServerConfig) -> Bool {
        guard let request = HTTPActionPolicy.request(url: url, details: details, server: server) else {
            Log.info("HTTP action rejected by security policy")
            return false
        }
        lock.lock()
        defer { lock.unlock() }
        guard requests.count < HTTPActionPolicy.maxConcurrentRequests else { return false }
        let task = session.dataTask(with: request)
        requests[task.taskIdentifier] = ActiveRequest(task: task)
        task.resume()
        return true
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
        task.cancel()
        Log.info("HTTP action redirect rejected")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(NetworkAuthenticationPolicy.disposition(for: challenge.protectionSpace.authenticationMethod), nil)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(NetworkAuthenticationPolicy.disposition(for: challenge.protectionSpace.authenticationMethod), nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard response is HTTPURLResponse,
              response.expectedContentLength <= Int64(HTTPActionPolicy.maxResponseBytes) else {
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let accepted = requests[dataTask.taskIdentifier]?.budget.accept(byteCount: data.count) ?? false
        lock.unlock()
        if !accepted { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let completed = requests.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard completed != nil else { return }
        if error != nil {
            Log.error("HTTP action failed or exceeded a limit")
        } else if let response = task.response as? HTTPURLResponse {
            Log.info("HTTP action completed (status \(response.statusCode))")
        }
    }
}

/// Main-queue-owned FIFO, independent of notification-center callback ordering.
struct BoundedNotificationCategories {
    static let limit = 128
    private(set) var categories: [UNNotificationCategory] = []

    mutating func insert(_ category: UNNotificationCategory) {
        categories.removeAll { $0.identifier == category.identifier }
        categories.append(category)
        if categories.count > Self.limit { categories.removeFirst(categories.count - Self.limit) }
    }
}

final class NotificationManager: NSObject, @unchecked Sendable {
    static let shared = NotificationManager()

    private lazy var center: UNUserNotificationCenter = {
        dispatchPrecondition(condition: .onQueue(.main))
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        return center
    }()

    private let lock = NSLock()
    private var _scriptRunner: (any ScriptRunnerProtocol)?
    private var categories = BoundedNotificationCategories()
    private let httpActions = HTTPActionExecutor()

    private override init() {
        super.init()
        // Don't call clearCategories() here - it accesses UNUserNotificationCenter
        // which requires the run loop to be active
    }

    /// Clears all notification categories to remove stale actions
    func clearCategories() {
        dispatchPrecondition(condition: .onQueue(.main))
        categories = BoundedNotificationCategories()
        httpActions.cancelAll()
        center.setNotificationCategories([])
        Log.info("Cleared notification categories")
    }

    /// Sets the script runner - accepts protocol for DI/testing
    func setScriptRunner(_ runner: any ScriptRunnerProtocol) {
        lock.lock()
        defer { lock.unlock() }
        self._scriptRunner = runner
    }

    private var scriptRunner: (any ScriptRunnerProtocol)? {
        lock.lock()
        defer { lock.unlock() }
        return _scriptRunner
    }

    /// Requests notification permissions from the user
    func requestAuthorization(completion: @escaping @Sendable (Bool, Error?) -> Void) {
        // Check current authorization status first
        center.getNotificationSettings { settings in
            if settings.authorizationStatus == .notDetermined {
                // Permission not requested yet - request directly without blocking alert
                print("📱 Requesting notification permissions...")
                print("   A system dialog will appear - please click 'Allow'")

                DispatchQueue.main.async {
                    NSApplication.shared.activate(ignoringOtherApps: true)

                    // Request authorization directly - this will show the system dialog
                    self.center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                        if granted {
                            print("✅ Notification permission granted!")
                        } else {
                            print("")
                            print("⚠️  Notification permission was denied or the dialog didn't appear")
                            print("")
                            print("💡 The app is now registered in System Settings.")
                            print("   To enable notifications manually:")
                            print("   1. Open System Settings → Notifications")
                            print("   2. Scroll down and find 'ntfy-macos'")
                            print("   3. Toggle on 'Allow Notifications'")
                            print("")
                            print("   Then restart ntfy-macos")
                        }
                        completion(granted, error)
                    }
                }
            } else if settings.authorizationStatus == .authorized {
                print("✅ Notification permissions already granted")
                completion(true, nil)
            } else {
                print("")
                print("⚠️  Notification permissions are currently denied or restricted")
                print("")
                print("💡 To enable notifications:")
                print("   1. Open System Settings → Notifications")
                print("   2. Scroll down and find 'ntfy-macos' in the list")
                print("   3. Toggle on 'Allow Notifications'")
                print("")
                print("   Then restart ntfy-macos")
                completion(false, nil)
            }
        }
    }

    func getAuthorizationStatus(completion: @escaping @Sendable (UNAuthorizationStatus) -> Void) {
        center.getNotificationSettings { settings in
            completion(settings.authorizationStatus)
        }
    }

    /// Displays a notification based on an ntfy message and topic configuration
    func showNotification(for message: NtfyMessage, topicConfig: TopicConfig?, originatingServerURL: String? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        // Resolve again from immutable origin. The caller's topic-only configuration is not authority.
        guard let originatingServerURL,
              let serverConfig = ConfigManager.shared.config?.serverConfig(forURL: originatingServerURL, topic: message.topic),
              let topicConfig = serverConfig.topics.first(where: { $0.name == message.topic }) else {
            showBasicNotification(for: message)
            return
        }

        // Skip notification if silent mode is enabled
        if topicConfig.silent == true {
            Log.info("Silent notification - skipping display")
            return
        }

        let content = UNMutableNotificationContent()
        let emojiPrefix = EmojiTags.emojiPrefix(for: message.tags)
        // Use plain text versions to strip markdown syntax (macOS notifications don't render markdown)
        content.title = emojiPrefix + (message.plainTextTitle ?? message.title ?? "\(message.topic)")
        content.body = message.plainTextMessage ?? message.message ?? "\(message.topic)"
        // Use Glass sound to distinguish from other notification services
        content.sound = UNNotificationSound(named: UNNotificationSoundName("Glass.aiff"))

        // Map ntfy priority to interruption levels
        if let priority = message.priority {
            switch priority {
            case 5:
                content.interruptionLevel = .critical
                content.sound = .defaultCritical
            case 4:
                content.interruptionLevel = .timeSensitive
            default:
                content.interruptionLevel = .active
            }
        }

        if let attachment = createIconAttachment(from: topicConfig) {
            content.attachments = [attachment]
        }

        // Determine click URL. Priority order:
        // 1. `click_url` from topic config (`false`, custom URL)
        // 2. `click` URL from the message itself
        // 3. Default server URL
        let clickUrl: String
        let isCustomClickUrl: Bool

        switch topicConfig.clickUrl {
        case .custom(let customUrl):
            // 1. Highest priority: custom URL from config
            clickUrl = customUrl
            isCustomClickUrl = true
        case .disabled:
            // 1. Highest priority: disabled from config
            clickUrl = ""
            isCustomClickUrl = false // Not applicable
        case .enabled, .none:
            // Config doesn't specify an override, so check the message
            if let messageClickUrl = message.click, !messageClickUrl.isEmpty {
                // 2. Next priority: URL from the message
                clickUrl = messageClickUrl
                isCustomClickUrl = true
            } else {
                // 3. Fallback: default server URL
                clickUrl = serverConfig.url
                isCustomClickUrl = false
            }
        }

        var userInfo: [String: Any] = [
            "messageBody": message.message ?? "",
            "topic": message.topic,
            NotificationOrigin.userInfoKey: originatingServerURL,
            "clickURL": clickUrl,
            "isCustomClickUrl": isCustomClickUrl,
            "messageId": message.id
        ]

        // Handle actions: config actions override message actions
        if let actions = topicConfig.actions, !actions.isEmpty {
            // Config actions take priority - use them instead of message actions
            let categoryId = "config-\(UUID().uuidString)"
            registerCategory(categoryId: categoryId, actions: actions)
            content.categoryIdentifier = categoryId
        } else {
            let messageActions = Array((message.actions ?? []).filter { $0.action == "view" || $0.action == "http" }.prefix(4))
            // No config actions - use message actions
            if !messageActions.isEmpty {
                let categoryId = "message-\(UUID().uuidString)"
                registerCategoryFromMessage(categoryId: categoryId, actions: messageActions)
                content.categoryIdentifier = categoryId
            }

            // Store action URLs, types, and HTTP details in userInfo for later retrieval
            var actionUrls: [String: String] = [:]
            var actionTypes: [String: String] = [:]
            var actionDetailsJson: [String: String] = [:]
            for (index, action) in messageActions.enumerated() {
                let key = "ntfy-action-\(index)"
                if let url = action.url {
                    actionUrls[key] = url
                }
                actionTypes[key] = action.action
                if action.action == "http" {
                    var details: [String: Any] = [:]
                    details["method"] = action.method ?? "POST"
                    details["url"] = action.url ?? ""
                    if let body = action.body {
                        details["body"] = body
                    }
                    if let headers = action.headers {
                        details["headers"] = headers
                    }
                    // Serialize as JSON string for plist compatibility
                    if let data = try? JSONSerialization.data(withJSONObject: details),
                       let json = String(data: data, encoding: .utf8) {
                        actionDetailsJson[key] = json
                    }
                }
            }
            userInfo["actionUrls"] = actionUrls
            userInfo["actionTypes"] = actionTypes
            userInfo["actionDetailsJson"] = actionDetailsJson
        }

        content.userInfo = userInfo

        // Create and schedule notification
        let identifier = UUID().uuidString
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)

        center.add(request) { error in
            if error != nil {
                Log.error("Failed to show notification")
            }
        }
    }

    /// Shows a basic notification without topic configuration
    private func showBasicNotification(for message: NtfyMessage) {
        let content = Self.basicContent(for: message)
        let identifier = UUID().uuidString
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)

        center.add(request) { error in
            if error != nil {
                Log.error("Failed to show notification")
            }
        }
    }

    /// Local/unscoped messages cannot carry any actionable notification metadata.
    static func basicContent(for message: NtfyMessage) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        let emojiPrefix = EmojiTags.emojiPrefix(for: message.tags)
        // Use plain text versions to strip markdown syntax (macOS notifications don't render markdown)
        content.title = emojiPrefix + (message.plainTextTitle ?? message.title ?? "ntfy-macos")
        content.body = message.plainTextMessage ?? message.message ?? ""
        // Use Glass sound to distinguish from other notification services
        content.sound = UNNotificationSound(named: UNNotificationSoundName("Glass.aiff"))
        return content
    }

    /// Creates an icon attachment from the topic configuration
    private func createIconAttachment(from topicConfig: TopicConfig) -> UNNotificationAttachment? {
        // Try SF Symbol first
        if let symbolName = topicConfig.iconSymbol {
            if let symbolImage = createSFSymbolImage(named: symbolName) {
                return createAttachment(from: symbolImage)
            }
        }

        // Try local file path
        if let iconPath = topicConfig.iconPath {
            let url = URL(fileURLWithPath: iconPath)
            if FileManager.default.fileExists(atPath: iconPath) {
                do {
                    return try UNNotificationAttachment(identifier: UUID().uuidString, url: url, options: nil)
                } catch {
                    Log.error("Failed to create configured icon attachment")
                }
            }
        }

        return nil
    }

    /// Creates an NSImage from an SF Symbol
    private func createSFSymbolImage(named symbolName: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 64, weight: .regular)
        return NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    /// Converts an NSImage to a notification attachment
    private func createAttachment(from image: NSImage) -> UNNotificationAttachment? {
        guard let tiffData = image.tiffRepresentation,
              let bitmapImage = NSBitmapImageRep(data: tiffData),
              let pngData = bitmapImage.representation(using: .png, properties: [:]) else {
            return nil
        }

        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "\(UUID().uuidString).png"
        let fileURL = tempDir.appendingPathComponent(fileName)

        do {
            try pngData.write(to: fileURL)
            let attachment = try UNNotificationAttachment(identifier: UUID().uuidString, url: fileURL, options: nil)
            try? FileManager.default.removeItem(at: fileURL)
            return attachment
        } catch {
            Log.error("Failed to write SF Symbol attachment")
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
    }

    /// Registers a notification category with actions from config
    private func registerCategory(categoryId: String, actions: [NotificationAction]) {
        let unActions = actions.prefix(4).map { action in
            UNNotificationAction(
                identifier: "action-\(action.title.lowercased().replacingOccurrences(of: " ", with: "-"))",
                title: action.title,
                options: [.foreground]
            )
        }

        let category = UNNotificationCategory(
            identifier: categoryId,
            actions: unActions,
            intentIdentifiers: [],
            options: []
        )

        categories.insert(category)
        center.setNotificationCategories(Set(categories.categories))
    }

    /// Registers a notification category with actions from ntfy message
    private func registerCategoryFromMessage(categoryId: String, actions: [NtfyMessage.NtfyAction]) {
        let unActions = actions.prefix(4).enumerated().map { (index, action) in
            UNNotificationAction(
                identifier: "ntfy-action-\(index)",
                title: action.label,
                options: [.foreground]
            )
        }

        let category = UNNotificationCategory(
            identifier: categoryId,
            actions: unActions,
            intentIdentifiers: [],
            options: []
        )

        categories.insert(category)
        center.setNotificationCategories(Set(categories.categories))
    }

    /// Opens a URL securely by validating its scheme and domain against the allowed values in server config
    /// - Parameters:
    ///   - url: The URL to open
    ///   - origin: The immutable subscription origin stored at delivery time.
    @MainActor private func openUrlSecurely(_ url: URL, origin: NotificationOrigin) {
        guard let serverConfig = origin.serverConfig(in: ConfigManager.shared.config),
              NotificationURLPolicy.isAllowed(url, server: serverConfig) else {
            Log.info("URL action rejected by origin security policy")
            return
        }

        NSWorkspace.shared.open(url)
    }

    func showTestNotification(topic: String) {
        let content = UNMutableNotificationContent()
        content.title = "Test Notification"
        content.body = "This is a test notification for topic: \(topic)"
        content.sound = .default

        // The app icon on the left side of the notification is automatically
        // taken from the app bundle's CFBundleIconFile by macOS

        let identifier = UUID().uuidString
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)

        center.add(request) { error in
            if error != nil {
                Log.error("Failed to show test notification")
            }
        }
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        DispatchQueue.main.async { [self, response] in
            handleResponse(response)
        }

        // Clear badge when user interacts with a notification.
        center.setBadgeCount(0) { _ in }
        completionHandler()
    }

    @MainActor private func handleResponse(_ response: UNNotificationResponse) {
        dispatchPrecondition(condition: .onQueue(.main))
        let userInfo = response.notification.request.content.userInfo
        guard let origin = NotificationOrigin(userInfo: userInfo),
              origin.serverConfig(in: ConfigManager.shared.config) != nil else { return }
        let messageBody = userInfo["messageBody"] as? String ?? ""

        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            // User clicked on the notification itself - open web view
            openNotificationInWeb(userInfo: userInfo, origin: origin)
        } else if response.actionIdentifier != UNNotificationDismissActionIdentifier {
            handleActionResponse(response, messageBody: messageBody, origin: origin)
        }
    }

    @MainActor private func openNotificationInWeb(userInfo: [AnyHashable: Any], origin: NotificationOrigin) {
        guard let clickURL = userInfo["clickURL"] as? String, !clickURL.isEmpty,
              let baseURL = URL(string: clickURL),
              let topicConfig = ConfigManager.shared.topicConfig(for: origin.topic, serverURL: origin.serverURL) else {
            return
        }
        if case .disabled = topicConfig.clickUrl { return }

        let isCustomClickUrl = userInfo["isCustomClickUrl"] as? Bool ?? false

        // If custom URL, use it directly; otherwise append topic to server URL
        let url = isCustomClickUrl ? baseURL : baseURL.appendingPathComponent(origin.topic)
        openUrlSecurely(url, origin: origin)
    }

    @MainActor private func handleActionResponse(_ response: UNNotificationResponse, messageBody: String, origin: NotificationOrigin) {
        let actionIdentifier = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo
        guard let server = origin.serverConfig(in: ConfigManager.shared.config) else { return }

        // Check for ntfy message actions
        if actionIdentifier.hasPrefix("ntfy-action-") {
            let actionTypes = userInfo["actionTypes"] as? [String: String] ?? [:]
            guard let actionType = actionTypes[actionIdentifier] else { return }

            if actionType == "http",
               let actionDetailsJson = userInfo["actionDetailsJson"] as? [String: String],
               let jsonString = actionDetailsJson[actionIdentifier],
               let jsonData = jsonString.data(using: .utf8),
               let details = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
               let urlString = details["url"] as? String,
               let url = URL(string: urlString) {
                httpActions.execute(url: url, details: details, server: server)
            } else if actionType == "view",
                      let actionUrls = userInfo["actionUrls"] as? [String: String],
                      let urlString = actionUrls[actionIdentifier],
                      let url = URL(string: urlString) {
                openUrlSecurely(url, origin: origin)
            }
            return
        }

        // Handle config-based actions
        guard let topicConfig = ConfigManager.shared.topicConfig(for: origin.topic, serverURL: origin.serverURL),
              let actions = topicConfig.actions else {
            return
        }

        let matchingAction = actions.prefix(4).first { action in
            let actionId = "action-\(action.title.lowercased().replacingOccurrences(of: " ", with: "-"))"
            return actionId == actionIdentifier
        }

        if let action = matchingAction {
            if action.type == "script", let path = action.path {
                Log.info("Executing configured script action")
                scriptRunner?.runScript(at: path, withArgument: messageBody, extraEnv: nil)
            } else if action.type == "view", let urlString = action.url, let url = URL(string: urlString) {
                openUrlSecurely(url, origin: origin)
            } else if action.type == "shortcut", let name = action.name {
                Log.info("Running configured shortcut action")
                scriptRunner?.runShortcut(named: name, withInput: messageBody)
            } else if action.type == "applescript" {
                if let scriptSource = action.script {
                    Log.info("Running inline AppleScript from config action")
                    scriptRunner?.runAppleScript(source: scriptSource)
                } else if let path = action.path {
                    Log.info("Running configured AppleScript file action")
                    scriptRunner?.runAppleScriptFile(at: path)
                }
            }
        }
    }
}
