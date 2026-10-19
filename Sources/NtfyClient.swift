import Foundation
import Network

enum NetworkAuthenticationPolicy {
    static func disposition(for authenticationMethod: String) -> URLSession.AuthChallengeDisposition {
        // Let the system validate TLS certificates; never use keychain/ambient auth credentials.
        authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge
    }
}

@MainActor protocol NtfyClientDelegate: AnyObject {
    func ntfyClient(_ client: NtfyClient, didReceiveMessage message: NtfyMessage)
    func ntfyClient(_ client: NtfyClient, didEncounterError error: Error)
    func ntfyClientDidConnect(_ client: NtfyClient)
    func ntfyClientDidDisconnect(_ client: NtfyClient)
}

struct NtfyMessage: Codable, Sendable {
    let id: String
    let time: Int
    let event: String
    let topic: String
    let message: String?
    let title: String?
    let priority: Int?
    let tags: [String]?
    let click: String?
    let actions: [NtfyAction]?
    let attachment: NtfyAttachment?
    let contentType: String?  // "text/markdown" when markdown is enabled

    enum CodingKeys: String, CodingKey {
        case id, time, event, topic, message, title, priority, tags, click, actions, attachment
        case contentType = "content_type"
    }

    /// Returns true if this message contains markdown content
    var isMarkdown: Bool {
        contentType?.lowercased() == "text/markdown"
    }

    /// Returns the message with markdown syntax stripped for plain text display
    var plainTextMessage: String? {
        guard let message = message else { return nil }
        guard isMarkdown else { return message }
        return MarkdownStripper.strip(message)
    }

    /// Returns the title with markdown syntax stripped for plain text display
    var plainTextTitle: String? {
        guard let title = title else { return nil }
        guard isMarkdown else { return title }
        return MarkdownStripper.strip(title)
    }

    struct NtfyAction: Codable, Sendable {
        let action: String
        let label: String
        let url: String?
        let method: String?
        let headers: [String: String]?
        let body: String?
        let clear: Bool?
    }

    struct NtfyAttachment: Codable, Sendable {
        let name: String
        let url: String
        let type: String?
        let size: Int?
        let expires: Int?
    }
}

/// Consumes records individually, never copying an unbounded network chunk into storage.
struct BoundedNDJSONBuffer {
    enum BufferError: Error { case recordTooLarge }
    static let defaultLimit = 256 * 1024
    let limit: Int
    private(set) var pending = Data()

    init(limit: Int = Self.defaultLimit) {
        precondition(limit > 0)
        self.limit = limit
    }

    mutating func reset() { pending = Data() }

    mutating func append(_ data: Data, onRecord: (Data) -> Void) throws {
        var start = data.startIndex
        while start < data.endIndex {
            let newline = data[start...].firstIndex(of: 10)
            let end = newline ?? data.endIndex
            let count = data.distance(from: start, to: end)
            guard count <= limit - pending.count else {
                reset()
                throw BufferError.recordTooLarge
            }
            pending.append(contentsOf: data[start..<end])
            if let newline {
                let record = pending
                pending = Data()
                onRecord(record)
                start = data.index(after: newline)
            } else {
                break
            }
        }
    }
}

final class NtfyClient: NSObject, @unchecked Sendable {
    /// Payload-free transport diagnostics, useful when a callback fails before logging is available.
    struct ConnectionDiagnostics: Sendable {
        var tasksStarted = 0
        var responsesReceived = 0
        var responsesAccepted = 0
        var dataCallbacksReceived = 0
        var dataCallbacksAccepted = 0
        var taskCallbacksRejected = 0
        var callbacksQueued = 0
        var callbacksDelivered = 0
        var callbacksDiscardedAsStale = 0
        var callbacksWithoutDelegate = 0
        var callbacksOverLimit = 0
        var activeTaskIdentifier: Int?
        var lastResponseTaskIdentifier: Int?
    }

    /// Immutable subscription origin; never derived from publisher-controlled fields.
    let serverURL: String
    private let topics: [String]
    private let fetchMissed: Bool
    // All mutable connection state is protected by this lock, including timer callbacks.
    private let lock = NSRecursiveLock()
    private var _authToken: String?

    private var authToken: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _authToken
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _authToken = newValue
        }
    }

    weak var delegate: NtfyClientDelegate?

    private var session: URLSession!
    private let delegateQueue: OperationQueue
    private var dataTask: URLSessionDataTask?
    private var buffer = BoundedNDJSONBuffer()
    private var generation: UInt64 = 0
    private var pendingCallbacks = 0
    private let maxPendingCallbacks = 128
    private var diagnostics = ConnectionDiagnostics()

    var connectionDiagnostics: ConnectionDiagnostics {
        lock.lock()
        defer { lock.unlock() }
        var snapshot = diagnostics
        snapshot.activeTaskIdentifier = dataTask?.taskIdentifier
        return snapshot
    }

    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 10
    private let baseReconnectDelay: TimeInterval
    private let maxReconnectDelay: TimeInterval = 300.0  // 5 minutes max
    private var reconnectTimer: Timer?
    private var isConnecting = false
    private var shouldReconnect = true
    private var retryAfterDelay: TimeInterval?  // From Retry-After header
    private var lastMessageTime: Int  // Track last message timestamp for fetch_missed
    private let lastMessageTimeKey: String  // UserDefaults key for persistence
    private let lastMessageIDKey: String
    private var lastMessageID: String?
    private var recentMessageIDs: Set<String> = []
    private var recentMessageOrder: [String] = []

    // Watchdog: reconnect if no data received for this long (ntfy sends keepalives every ~55s)
    private let watchdogInterval: TimeInterval
    private var watchdogTimer: Timer?
    private var lastDataReceived: Date = .distantPast

    // Network path monitor: reconnect immediately when network becomes available
    private var pathMonitor: NWPathMonitor?
    private var pathMonitorGeneration: UInt64 = 0
    private var isPathSatisfied = true  // Assume connected initially

    init(serverURL: String, topics: [String], authToken: String? = nil, fetchMissed: Bool = false, watchdogInterval: TimeInterval = 120.0, baseReconnectDelay: TimeInterval = 2.0, urlSessionConfiguration: URLSessionConfiguration? = nil) {
        self.serverURL = serverURL
        self.topics = topics
        self._authToken = authToken
        self.fetchMissed = fetchMissed
        self.watchdogInterval = watchdogInterval
        self.baseReconnectDelay = baseReconnectDelay

        // Restore last message time from UserDefaults for fetch_missed
        let topicsKey = topics.sorted().joined(separator: ",")
        self.lastMessageTimeKey = "lastMessageTime-\(serverURL)-\(topicsKey)"
        self.lastMessageTime = UserDefaults.standard.integer(forKey: lastMessageTimeKey)
        self.lastMessageIDKey = "lastMessageID-\(serverURL)-\(topicsKey)"
        self.lastMessageID = fetchMissed ? UserDefaults.standard.string(forKey: lastMessageIDKey) : nil

        // Create a dedicated serial queue for URLSession callbacks
        self.delegateQueue = OperationQueue()
        self.delegateQueue.maxConcurrentOperationCount = 1
        self.delegateQueue.name = "com.ntfy-macos.urlsession"

        super.init()

        if let id = lastMessageID, !id.isEmpty, id.utf8.count <= 256 {
            recentMessageIDs.insert(id)
            recentMessageOrder.append(id)
        } else {
            lastMessageID = nil
        }

        let config = urlSessionConfiguration ?? URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = .infinity
        config.timeoutIntervalForResource = .infinity
        config.httpMaximumConnectionsPerHost = 1
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
    }

    deinit {
        disconnect()
    }

    // Thread-safe delegate call helper
    private func callDelegate(_ block: @escaping @MainActor @Sendable (NtfyClientDelegate) -> Void) {
        // Caller holds lock. Bound queued delivery too, not only partial wire records.
        guard pendingCallbacks < maxPendingCallbacks else {
            diagnostics.callbacksOverLimit &+= 1
            return
        }
        pendingCallbacks += 1
        diagnostics.callbacksQueued &+= 1
        let expectedGeneration = generation
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            self.pendingCallbacks -= 1
            guard self.shouldReconnect, self.generation == expectedGeneration else {
                self.diagnostics.callbacksDiscardedAsStale &+= 1
                return
            }
            guard let delegate = self.delegate else {
                self.diagnostics.callbacksWithoutDelegate &+= 1
                return
            }
            self.diagnostics.callbacksDelivered &+= 1
            block(delegate)
        }
    }

    func isSubscribed(to topic: String) -> Bool { topics.contains(topic) }

    func connect() {
        lock.lock()
        defer { lock.unlock() }
        guard shouldReconnect, !isConnecting, dataTask == nil else { return }
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        isConnecting = true
        generation &+= 1

        let topicsString = topics.joined(separator: ",")
        guard var components = URLComponents(string: serverURL),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              !topics.isEmpty else {
            isConnecting = false
            return
        }

        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = (basePath.isEmpty ? "" : "/\(basePath)") + "/\(topicsString)/json"
        components.query = nil
        components.fragment = nil

        // Add since parameter to fetch missed messages when enabled
        if fetchMissed {
            if let lastMessageID {
                // ntfy's ID cursor is exclusive; timestamp cursors replay the last second.
                components.queryItems = [URLQueryItem(name: "since", value: lastMessageID)]
            } else if lastMessageTime > 0 {
                // Migrate an existing timestamp-only cursor without losing missed messages.
                components.queryItems = [URLQueryItem(name: "since", value: String(lastMessageTime))]
            } else {
                // First connect: fetch all cached messages
                components.queryItems = [URLQueryItem(name: "since", value: "all")]
            }
        }

        guard let url = components.url else {
            isConnecting = false
            return
        }

        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.httpMethod = "GET"
        request.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")

        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        startPathMonitor()

        buffer.reset()
        dataTask = session.dataTask(with: request)
        diagnostics.tasksStarted &+= 1
        dataTask?.resume()

        Log.info("Connecting to ntfy subscription")
    }

    func disconnect() {
        lock.lock()
        defer { lock.unlock() }
        shouldReconnect = false
        generation &+= 1
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        stopWatchdog()
        stopPathMonitor()
        dataTask?.cancel()
        dataTask = nil
        isConnecting = false
        buffer.reset()
        session?.invalidateAndCancel()
    }

    private func startWatchdog() {
        stopWatchdog()
        lastDataReceived = Date()
        let expectedGeneration = generation
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard self.shouldReconnect, self.generation == expectedGeneration, self.dataTask != nil else { return }
            self.watchdogTimer = Timer.scheduledTimer(withTimeInterval: self.watchdogInterval, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                defer { self.lock.unlock() }
                guard self.shouldReconnect, self.generation == expectedGeneration else { return }
                let elapsed = Date().timeIntervalSince(self.lastDataReceived)
                if elapsed >= self.watchdogInterval {
                    Log.info("Watchdog: no data received for \(Int(elapsed))s, reconnecting...")
                    self.reconnect()
                }
            }
        }
    }

    private func stopWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        pathMonitorGeneration &+= 1
        let expectedMonitorGeneration = pathMonitorGeneration
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard self.shouldReconnect, self.pathMonitor != nil,
                  self.pathMonitorGeneration == expectedMonitorGeneration else { return }
            let satisfied = path.status == .satisfied
            if satisfied && !self.isPathSatisfied {
                Log.info("Network became available, reconnecting...")
                self.reconnect()
            }
            self.isPathSatisfied = satisfied
        }
        monitor.start(queue: .global(qos: .background))
    }

    private func stopPathMonitor() {
        pathMonitorGeneration &+= 1
        pathMonitor?.cancel()
        pathMonitor = nil
        isPathSatisfied = true
    }

    func updateAuthToken(_ token: String?) {
        lock.lock()
        defer { lock.unlock() }
        self.authToken = token
        if dataTask != nil {
            reconnect()
        }
    }

    private func reconnect(invalidateCallbacks: Bool = true) {
        guard shouldReconnect else { return }

        if invalidateCallbacks { generation &+= 1 }
        let expectedGeneration = generation
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        stopWatchdog()
        dataTask?.cancel()
        dataTask = nil
        isConnecting = false
        buffer.reset()

        // Calculate delay with exponential backoff
        var delay: TimeInterval

        if let retryAfter = retryAfterDelay {
            // Server told us exactly when to retry (Retry-After header)
            delay = min(retryAfter, maxReconnectDelay)
            retryAfterDelay = nil  // Clear for next time
            Log.info("Server requested retry after \(Int(delay)) seconds")
        } else {
            // Exponential backoff: 2s, 4s, 8s, 16s, 32s, 64s, 128s, 256s, 300s (capped)
            delay = min(baseReconnectDelay * pow(2.0, Double(reconnectAttempts)), maxReconnectDelay)
        }

        // Add jitter (±10%) to prevent thundering herd
        let jitter = delay * Double.random(in: -0.1...0.1)
        delay += jitter

        reconnectAttempts += 1

        if reconnectAttempts <= maxReconnectAttempts {
            Log.info("Reconnecting in \(String(format: "%.1f", delay)) seconds (attempt \(reconnectAttempts)/\(maxReconnectAttempts))...")
        } else {
            // Max attempts reached — schedule a last-resort retry every 5 minutes indefinitely
            Log.error("Max reconnection attempts reached. Retrying every 5 minutes...")
            reconnectAttempts = 0  // Reset so next success resets state correctly
            delay = maxReconnectDelay
        }
        let scheduledDelay = delay
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard self.shouldReconnect, self.generation == expectedGeneration else { return }
            self.reconnectTimer = Timer.scheduledTimer(withTimeInterval: scheduledDelay, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                defer { self.lock.unlock() }
                guard self.shouldReconnect, self.generation == expectedGeneration else { return }
                self.connect()
            }
        }
    }

    /// Parse Retry-After header value (can be seconds or HTTP date)
    /// Internal for testing
    func parseRetryAfter(_ value: String) -> TimeInterval {
        // Try parsing as seconds first
        if let seconds = TimeInterval(value), seconds.isFinite {
            return max(seconds, 1.0)  // At least 1 second
        }

        // Try parsing as HTTP date (e.g., "Sun, 18 Jan 2026 23:59:59 GMT")
        let httpDateFormatter = DateFormatter()
        httpDateFormatter.locale = Locale(identifier: "en_US_POSIX")
        httpDateFormatter.timeZone = TimeZone(identifier: "GMT")

        // RFC 7231 formats
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss zzz",  // IMF-fixdate
            "EEEE, dd-MMM-yy HH:mm:ss zzz",   // RFC 850
            "EEE MMM d HH:mm:ss yyyy"          // ANSI C asctime()
        ]

        for format in formats {
            httpDateFormatter.dateFormat = format
            if let date = httpDateFormatter.date(from: value) {
                let delay = date.timeIntervalSinceNow
                return max(delay, 1.0)  // At least 1 second, even if date is in past
            }
        }

        // Fallback if parsing fails
        return 30.0
    }

    private func processLine(_ data: Data) {
        guard !data.isEmpty, !data.allSatisfy({ [9, 13, 32].contains($0) }) else { return }

        do {
            let message = try JSONDecoder().decode(NtfyMessage.self, from: data)
            guard message.event == "message", isSubscribed(to: message.topic),
                  !message.id.isEmpty, message.id.utf8.count <= 256 else { return }

            callDelegate { delegate in
                guard self.recentMessageIDs.insert(message.id).inserted else { return }
                self.recentMessageOrder.append(message.id)
                if self.recentMessageOrder.count > 512 {
                    self.recentMessageIDs.remove(self.recentMessageOrder.removeFirst())
                }
                if self.fetchMissed {
                    self.lastMessageID = message.id
                    UserDefaults.standard.set(message.id, forKey: self.lastMessageIDKey)
                }
                // Only delivered records may advance replay state; stale/overflowed callbacks cannot.
                if message.time > self.lastMessageTime {
                    self.lastMessageTime = message.time
                    if self.fetchMissed {
                        UserDefaults.standard.set(self.lastMessageTime, forKey: self.lastMessageTimeKey)
                    }
                }
                delegate.ntfyClient(self, didReceiveMessage: message)
            }
        } catch {
            Log.error("Discarded malformed stream record")
        }
    }
}

extension NtfyClient: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        defer { lock.unlock() }
        diagnostics.dataCallbacksReceived &+= 1
        guard shouldReconnect, dataTask === self.dataTask else {
            diagnostics.taskCallbacksRejected &+= 1
            return
        }
        diagnostics.dataCallbacksAccepted &+= 1
        lastDataReceived = Date()
        do {
            try buffer.append(data) { self.processLine($0) }
        } catch {
            Log.error("Stream record exceeded size limit")
            reconnect()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        guard shouldReconnect, task === dataTask else {
            diagnostics.taskCallbacksRejected &+= 1
            return
        }
        isConnecting = false
        stopWatchdog()

        // Preserve records accepted before a natural EOF; replacement tasks get a new generation.
        reconnect(invalidateCallbacks: false)
        if let error = error {
            let nsError = error as NSError
            // Cancelled errors are expected when we cancel the task ourselves (reconnect/disconnect) — ignore them
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                return
            }
            Log.error("Subscription connection failed (code \(nsError.code))")
            callDelegate { delegate in
                delegate.ntfyClient(self, didEncounterError: error)
                delegate.ntfyClientDidDisconnect(self)
            }
        } else {
            Log.info("Connection closed by server")
            callDelegate { delegate in
                delegate.ntfyClientDidDisconnect(self)
            }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        diagnostics.responsesReceived &+= 1
        diagnostics.lastResponseTaskIdentifier = dataTask.taskIdentifier
        guard shouldReconnect, dataTask === self.dataTask else {
            diagnostics.taskCallbacksRejected &+= 1
            completionHandler(.cancel)
            return
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }

        if httpResponse.statusCode == 200 {
            diagnostics.responsesAccepted &+= 1
            isConnecting = false
            reconnectAttempts = 0
            startWatchdog()
            callDelegate { delegate in
                delegate.ntfyClientDidConnect(self)
            }
            completionHandler(.allow)
        } else {
            Log.error("Server returned status code: \(httpResponse.statusCode)")

            // Handle rate limiting (429) - extract Retry-After header
            if httpResponse.statusCode == 429 {
                if let retryAfterString = httpResponse.value(forHTTPHeaderField: "Retry-After") {
                    retryAfterDelay = parseRetryAfter(retryAfterString)
                } else {
                    // No Retry-After header, use a conservative default for 429
                    retryAfterDelay = 30.0
                }
            }

            completionHandler(.cancel)
            reconnect()
        }
    }

    // Never transfer a subscription token or its origin identity across redirects.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(NetworkAuthenticationPolicy.disposition(for: challenge.protectionSpace.authenticationMethod), nil)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(NetworkAuthenticationPolicy.disposition(for: challenge.protectionSpace.authenticationMethod), nil)
    }
}
