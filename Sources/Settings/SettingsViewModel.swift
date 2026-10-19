import Foundation
import Combine

struct EditableServer: Identifiable {
    let id: UUID
    var url: String
    var token: String
    var storeInKeychain: Bool
    var fetchMissed: Bool
    var topics: [EditableTopic]
    var allowedSchemes: [String]?
    var allowedDomains: [String]?

    // Track original URL for Keychain cleanup on rename
    var originalUrl: String?

    init(id: UUID = UUID(), url: String = "", token: String = "", storeInKeychain: Bool = false, fetchMissed: Bool = false, topics: [EditableTopic] = [], originalUrl: String? = nil, allowedSchemes: [String]? = nil, allowedDomains: [String]? = nil) {
        self.id = id
        self.url = url
        self.token = token
        self.storeInKeychain = storeInKeychain
        self.fetchMissed = fetchMissed
        self.topics = topics
        self.originalUrl = originalUrl
        self.allowedSchemes = allowedSchemes
        self.allowedDomains = allowedDomains
    }
}

struct EditableTopic: Identifiable {
    let id: UUID
    var name: String
    var fetchMissed: Bool?

    // Phase 2 fields (preserved during round-trip but not editable yet)
    var iconPath: String?
    var iconSymbol: String?
    var autoRunScript: String?
    var silent: Bool?
    var clickUrl: ClickUrlConfig?
    var actions: [NotificationAction]?

    init(id: UUID = UUID(), name: String = "", fetchMissed: Bool? = nil, iconPath: String? = nil, iconSymbol: String? = nil, autoRunScript: String? = nil, silent: Bool? = nil, clickUrl: ClickUrlConfig? = nil, actions: [NotificationAction]? = nil) {
        self.id = id
        self.name = name
        self.fetchMissed = fetchMissed
        self.iconPath = iconPath
        self.iconSymbol = iconSymbol
        self.autoRunScript = autoRunScript
        self.silent = silent
        self.clickUrl = clickUrl
        self.actions = actions
    }
}

@MainActor
class SettingsViewModel: ObservableObject {
    @Published var servers: [EditableServer] = []
    @Published var localServerPort: String = ""
    @Published private(set) var localServerToken: String?
    @Published var selectedServerID: UUID?
    @Published var hasUnsavedChanges: Bool = false
    @Published var isLocked: Bool = true
    @Published var saveError: String?
    @Published var serverConnectionStates: [String: StatusBarController.ConnectionState] = [:]

    func refreshConnectionStates() {
        let statuses = StatusBarController.shared.getServerStatuses()
        var states: [String: StatusBarController.ConnectionState] = [:]
        for (url, status) in statuses {
            states[url] = status.state
        }
        serverConnectionStates = states
    }

    private var cancellables = Set<AnyCancellable>()
    private let configManager: ConfigManager
    private let loadToken: (String) throws -> String?
    private let saveToken: (String, String) throws -> Void
    private let deleteToken: (String) throws -> Void
    private var credentialLoadFailed = false

    init(configManager: ConfigManager = .shared,
         loadToken: @escaping (String) throws -> String? = KeychainHelper.getToken(forServer:),
         saveToken: @escaping (String, String) throws -> Void = KeychainHelper.saveToken(_:forServer:),
         deleteToken: @escaping (String) throws -> Void = KeychainHelper.deleteToken(forServer:)) {
        self.configManager = configManager
        self.loadToken = loadToken
        self.saveToken = saveToken
        self.deleteToken = deleteToken
        // Track changes to mark unsaved state
        $servers
            .dropFirst()
            .sink { [weak self] _ in self?.hasUnsavedChanges = true }
            .store(in: &cancellables)
        $localServerPort
            .dropFirst()
            .sink { [weak self] _ in self?.hasUnsavedChanges = true }
            .store(in: &cancellables)
    }

    func loadFromConfig() {
        let config = configManager.config
        localServerToken = config?.localServerToken
        credentialLoadFailed = false

        if let port = config?.localServerPort {
            localServerPort = String(port)
        } else {
            localServerPort = ""
        }

        servers = (config?.servers ?? []).map { server in
            // Check if token is stored in Keychain
            let keychainToken: String?
            do { keychainToken = try loadToken(server.url) }
            catch { credentialLoadFailed = true; keychainToken = nil }
            let hasKeychainToken = keychainToken != nil
            let tokenValue = keychainToken ?? server.token ?? ""

            return EditableServer(
                url: server.url,
                token: tokenValue,
                storeInKeychain: hasKeychainToken,
                fetchMissed: server.fetchMissed ?? false,
                topics: server.topics.map { topic in
                    EditableTopic(
                        name: topic.name,
                        fetchMissed: topic.fetchMissed,
                        iconPath: topic.iconPath,
                        iconSymbol: topic.iconSymbol,
                        autoRunScript: topic.autoRunScript,
                        silent: topic.silent,
                        clickUrl: topic.clickUrl,
                        actions: topic.actions
                    )
                },
                originalUrl: server.url,
                allowedSchemes: server.allowedSchemes,
                allowedDomains: server.allowedDomains
            )
        }

        // Auto-select first server
        selectedServerID = servers.first?.id

        hasUnsavedChanges = false
        saveError = credentialLoadFailed ? "Cannot read Keychain credentials. Unlock Keychain and reload Settings before saving." : nil
    }

    func save() {
        saveError = nil
        guard !credentialLoadFailed else {
            saveError = "Cannot save while Keychain credentials are inaccessible. Unlock Keychain and reload Settings."
            return
        }

        // Validation
        for server in servers {
            if server.url.trimmingCharacters(in: .whitespaces).isEmpty {
                saveError = "Server URL cannot be empty"
                return
            }
            for topic in server.topics {
                if topic.name.trimmingCharacters(in: .whitespaces).isEmpty {
                    saveError = "Topic name cannot be empty"
                    return
                }
            }
            // Check for duplicate topic names within a server
            let topicNames = server.topics.map { $0.name }
            if Set(topicNames).count != topicNames.count {
                saveError = "Duplicate topic names in server \(server.url)"
                return
            }
        }

        // Parse port
        let port: UInt16?
        if localServerPort.trimmingCharacters(in: .whitespaces).isEmpty {
            port = nil
        } else if let p = UInt16(localServerPort), p >= 1024 {
            port = p
        } else {
            saveError = "Port must be between 1024 and 65535"
            return
        }

        // Build AppConfig
        let serverConfigs = servers.map { server in
            let topicConfigs = server.topics.map { topic in
                TopicConfig(
                    name: topic.name,
                    iconPath: topic.iconPath,
                    iconSymbol: topic.iconSymbol,
                    autoRunScript: topic.autoRunScript,
                    silent: topic.silent,
                    clickUrl: topic.clickUrl,
                    actions: topic.actions,
                    fetchMissed: topic.fetchMissed
                )
            }

            // If storing in Keychain, don't write token to YAML
            let yamlToken: String? = server.storeInKeychain ? nil : (server.token.isEmpty ? nil : server.token)

            return ServerConfig(
                url: server.url,
                token: yamlToken,
                topics: topicConfigs,
                allowedSchemes: server.allowedSchemes,
                allowedDomains: server.allowedDomains,
                fetchMissed: server.fetchMissed ? true : nil
            )
        }

        let savedLocalToken = port == nil ? localServerToken : (localServerToken ?? LocalNotificationServer.generateToken())
        let appConfig = AppConfig(servers: serverConfigs, localServerPort: port, localServerToken: savedLocalToken)

        var configurationSaved = false
        do {
            try ConfigValidator.validate(appConfig)
            // Never silently drop a credential when a Keychain write fails.
            for server in servers where server.storeInKeychain && !server.token.isEmpty {
                try saveToken(server.token, server.url)
            }
            try ConfigManager.saveConfig(appConfig, to: configManager.activeConfigPath)
            configurationSaved = true
            // Remove obsolete entries only after the replacement config is durable.
            let retainedKeychainURLs = Set(servers.filter { $0.storeInKeychain && !$0.token.isEmpty }.map { $0.url })
            for server in servers {
                if let oldURL = server.originalUrl,
                   !retainedKeychainURLs.contains(oldURL) {
                    try deleteToken(oldURL)
                }
                if !retainedKeychainURLs.contains(server.url) {
                    try deleteToken(server.url)
                }
            }
            localServerToken = savedLocalToken
            hasUnsavedChanges = false

            // Update originalUrl for all servers after successful save
            for i in servers.indices {
                servers[i].originalUrl = servers[i].url
            }
            // Reset unsaved flag (the assignment above triggers Combine)
            hasUnsavedChanges = false
            isLocked = true
        } catch {
            saveError = configurationSaved
                ? "Configuration saved, but Keychain cleanup failed. Old credentials may still be active; unlock Keychain and retry."
                : "Failed to save: \(error.localizedDescription)"
        }
    }

    var activeConfigPath: String { configManager.activeConfigPath }

    /// Only expose a valid, saved command; its token is a deliberate clipboard export.
    var localServerCurlCommand: String? {
        guard !hasUnsavedChanges, let port = UInt16(localServerPort), port >= 1024,
              let token = localServerToken, ConfigValidator.isValidLocalServerToken(token) else { return nil }
        return "curl --fail-with-body -X POST http://127.0.0.1:\(port)/notify -H 'Authorization: Bearer \(token)' -H 'Content-Type: application/json' -d '{\"title\":\"Hello\",\"message\":\"Hello from ntfy-macos!\"}'"
    }

    func cancel() {
        loadFromConfig()
        isLocked = true
    }

    // MARK: - Server CRUD

    func addServer() {
        let server = EditableServer(
            url: "https://",
            topics: [EditableTopic(name: "")]
        )
        servers.append(server)
        selectedServerID = server.id
    }

    func removeServer(_ server: EditableServer) {
        servers.removeAll { $0.id == server.id }
        if selectedServerID == server.id {
            selectedServerID = servers.first?.id
        }
    }

    // MARK: - Topic CRUD

    func addTopic(to serverID: UUID) {
        guard let index = servers.firstIndex(where: { $0.id == serverID }) else { return }
        servers[index].topics.append(EditableTopic(name: ""))
    }

    func removeTopic(_ topicID: UUID, from serverID: UUID) {
        guard let serverIndex = servers.firstIndex(where: { $0.id == serverID }) else { return }
        servers[serverIndex].topics.removeAll { $0.id == topicID }
    }

    // MARK: - Binding helpers

    func serverBinding(for id: UUID) -> EditableServer? {
        servers.first { $0.id == id }
    }

    var selectedServer: EditableServer? {
        guard let id = selectedServerID else { return nil }
        return servers.first { $0.id == id }
    }

    func selectedServerIndex() -> Int? {
        guard let id = selectedServerID else { return nil }
        return servers.firstIndex { $0.id == id }
    }
}
