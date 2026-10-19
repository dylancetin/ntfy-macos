import Foundation
import Network

/// A deliberately small, authenticated, loopback-only HTTP/1.1 notification API.
/// It cannot dispatch scripts, remote actions, or configuration-derived actions.
final class LocalNotificationServer: @unchecked Sendable {
    private var listener: NWListener?
    private let port: UInt16
    private let authToken: String
    private let queue = DispatchQueue(label: "com.ntfy-macos.local-server")
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var requestWindowStart = ProcessInfo.processInfo.systemUptime
    private var requestCount = 0
    private let connectionTimeout: TimeInterval
    private static let maximumConnections = 16
    private static let maximumRequestsPerMinute = 60

    var onNotification: (@Sendable (NtfyMessage) -> Void)?

    init(port: UInt16, authToken: String, connectionTimeout: TimeInterval = 5) {
        self.port = port
        self.authToken = authToken
        self.connectionTimeout = connectionTimeout
        self.onNotification = { message in
            DispatchQueue.main.async {
                NotificationManager.shared.showNotification(for: message, topicConfig: nil)
            }
        }
    }

    static func generateToken() -> String {
        var random = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &random)) }.joined()
    }

    func start() throws {
        guard port >= 1024, ConfigValidator.isValidLocalServerToken(authToken) else {
            throw ConfigError.insecureFilePermissions("Local server requires a nonprivileged port and a valid local_server_token")
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        let newListener = try NWListener(using: parameters)
        newListener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }
        newListener.stateUpdateHandler = { state in
            if case .failed = state { Log.error("Local notification listener failed") }
        }
        listener = newListener
        newListener.start(queue: queue)
        Log.info("Starting authenticated loopback notification server")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        queue.async { [self] in
            for connection in connections.values { connection.cancel() }
            connections.removeAll()
        }
    }

    private func handleConnection(_ connection: NWConnection) {
        guard connections.count < Self.maximumConnections else { connection.cancel(); return }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.connections.removeValue(forKey: id)
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + connectionTimeout) { [weak self, weak connection] in
            guard let self, let connection, self.connections[id] != nil else { return }
            connection.cancel()
        }
        readData(connection: connection, buffer: Data())
    }

    private func readData(connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self, error == nil else { connection.cancel(); return }
            var accumulated = buffer
            if let data { accumulated.append(data) }
            do {
                guard accumulated.count <= LocalRequestHeader.maximumHeaderBytes + LocalRequestHeader.maximumBodyBytes else {
                    throw LocalRequestError(status: 413, message: "Request too large")
                }
                if let header = try LocalRequestHeader.parse(accumulated) {
                    try self.authorize(header)
                    let body = accumulated.dropFirst(header.bodyOffset)
                    if body.count == header.contentLength {
                        self.processRequest(header: header, body: Data(body), connection: connection)
                        return
                    }
                    guard body.count < header.contentLength else {
                        throw LocalRequestError(status: 400, message: "Unexpected trailing bytes")
                    }
                }
                guard !complete else { throw LocalRequestError(status: 400, message: "Incomplete request") }
                self.readData(connection: connection, buffer: accumulated)
            } catch let error as LocalRequestError {
                self.sendResponse(connection: connection, status: error.status, message: error.message)
            } catch {
                self.sendResponse(connection: connection, status: 400, message: "Invalid request")
            }
        }
    }

    private func authorize(_ header: LocalRequestHeader) throws {
        guard header.headers["origin"] == nil,
              header.headers["sec-fetch-site"] == nil else {
            throw LocalRequestError(status: 403, message: "Browser requests are not accepted")
        }
        let expectedHosts = ["127.0.0.1:\(port)", "localhost:\(port)"]
        guard let host = header.headers["host"], expectedHosts.contains(host.lowercased()) else {
            throw LocalRequestError(status: 400, message: "Invalid Host")
        }
        let supplied = Array((header.headers["authorization"] ?? "").utf8)
        let expected = Array("Bearer \(authToken)".utf8)
        var difference = supplied.count ^ expected.count
        for index in expected.indices {
            difference |= Int(expected[index] ^ (index < supplied.count ? supplied[index] : 0))
        }
        guard difference == 0 else { throw LocalRequestError(status: 401, message: "Unauthorized") }
        if header.method == "POST" {
            let contentType = header.headers["content-type"]?.split(separator: ";", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespaces).lowercased()
            guard contentType == "application/json" else {
                throw LocalRequestError(status: 415, message: "Content-Type must be application/json")
            }
        }
    }

    private func processRequest(header: LocalRequestHeader, body: Data, connection: NWConnection) {
        let now = ProcessInfo.processInfo.systemUptime
        if now - requestWindowStart >= 60 { requestWindowStart = now; requestCount = 0 }
        guard requestCount < Self.maximumRequestsPerMinute else {
            sendResponse(connection: connection, status: 429, message: "Rate limit exceeded")
            return
        }
        requestCount += 1
        if header.method == "GET", header.path == "/health" {
            sendResponse(connection: connection, status: 200, json: "{\"status\":\"ok\"}")
            return
        }
        guard header.method == "POST", header.path == "/notify" else {
            sendResponse(connection: connection, status: 404, message: "Not found")
            return
        }
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            sendResponse(connection: connection, status: 400, message: "Invalid JSON")
            return
        }
        guard let title = json["title"] as? String, !title.isEmpty else {
            sendResponse(connection: connection, status: 400, message: "Missing required field: title")
            return
        }
        guard let message = json["message"] as? String, !message.isEmpty else {
            sendResponse(connection: connection, status: 400, message: "Missing required field: message")
            return
        }
        let notification = NtfyMessage(
            id: UUID().uuidString, time: Int(Date().timeIntervalSince1970), event: "message", topic: "local",
            message: message, title: title, priority: json["priority"] as? Int, tags: json["tags"] as? [String],
            click: nil, actions: nil, attachment: nil, contentType: nil
        )
        Log.info("Accepted local notification")
        onNotification?(notification)
        sendResponse(connection: connection, status: 200, json: "{\"success\":true}")
    }

    private func sendResponse(connection: NWConnection, status: Int, message: String) {
        let data = (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data("{}".utf8)
        sendResponse(connection: connection, status: status, json: String(decoding: data, as: UTF8.self))
    }

    private func sendResponse(connection: NWConnection, status: Int, json: String) {
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
                      413: "Payload Too Large", 415: "Unsupported Media Type", 429: "Too Many Requests"][status] ?? "Error"
        let response = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(json.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n\(json)"
        connection.send(content: Data(response.utf8), contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }
}

struct LocalRequestError: Error {
    let status: Int
    let message: String
}

/// Strict framing avoids duplicate Content-Length, chunked bodies, and slow/unbounded headers.
struct LocalRequestHeader {
    static let maximumHeaderBytes = 4096
    static let maximumBodyBytes = 4096
    let method: String
    let path: String
    let headers: [String: String]
    let contentLength: Int
    let bodyOffset: Int

    static func parse(_ data: Data) throws -> LocalRequestHeader? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            guard data.count <= maximumHeaderBytes else { throw LocalRequestError(status: 413, message: "Headers too large") }
            return nil
        }
        guard end.upperBound <= maximumHeaderBytes else { throw LocalRequestError(status: 413, message: "Headers too large") }
        guard let text = String(data: data[..<end.lowerBound], encoding: .ascii) else {
            throw LocalRequestError(status: 400, message: "Invalid headers")
        }
        let lines = text.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3, requestLine[2] == "HTTP/1.1" else {
            throw LocalRequestError(status: 400, message: "Invalid request line")
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty,
                  parts[0].utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
                  parts[1].utf8.allSatisfy({ $0 == 9 || (32...126).contains($0) }) else {
                throw LocalRequestError(status: 400, message: "Invalid header")
            }
            let name = parts[0].lowercased()
            guard headers[name] == nil else { throw LocalRequestError(status: 400, message: "Duplicate header") }
            headers[name] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil, headers["expect"] == nil else {
            throw LocalRequestError(status: 400, message: "Unsupported request framing")
        }
        let lengthText = headers["content-length"] ?? (requestLine[0] == "GET" ? "0" : "")
        guard !lengthText.isEmpty, lengthText.utf8.allSatisfy({ (48...57).contains($0) }),
              let length = Int(lengthText), length <= maximumBodyBytes else {
            throw LocalRequestError(status: 413, message: "Invalid or excessive Content-Length")
        }
        guard requestLine[0] != "GET" || length == 0 else {
            throw LocalRequestError(status: 400, message: "GET bodies are not supported")
        }
        return LocalRequestHeader(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers,
                                  contentLength: length, bodyOffset: end.upperBound)
    }
}
