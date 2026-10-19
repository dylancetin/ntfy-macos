import Foundation
import UserNotifications
import AppKit

/// App constants
enum AppConstants {
    static let bundleIdentifier = "com.laurentftech.ntfy-macos"

    /// Returns the bundle identifier, falling back to hardcoded value if running via symlink
    static var effectiveBundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? bundleIdentifier
    }

    /// Returns the app version from Info.plist
    static var effectiveVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}

@MainActor final class NtfyMacOS: NtfyClientDelegate {
    private var clients: [NtfyClient] = []
    private var clientToServer: [ObjectIdentifier: String] = [:]  // Maps client to server URL
    private var notificationManager: NotificationManager?
    private let scriptRunner = ScriptRunner()
    private var configWatcher: ConfigWatcher?
    private var localServer: LocalNotificationServer?
    private var serviceGeneration: UInt64 = 0

    init() {
        // Don't initialize notificationManager here - wait until it's needed
    }

    private func ensureNotificationManager() -> NotificationManager {
        if notificationManager == nil {
            notificationManager = NotificationManager.shared
            notificationManager?.setScriptRunner(scriptRunner)
        }
        return notificationManager!
    }

    func serve(configPath: String? = nil) {
        Log.info("Starting ntfy-macos service...")

        do {
            try ConfigManager.shared.loadConfig(from: configPath)
        } catch ConfigError.fileNotFound {
            let samplePath = configPath ?? ConfigManager.defaultConfigPath
            print("Configuration file not found.")
            print("Creating sample configuration at \(samplePath)")
            do {
                try ConfigManager.createSampleConfig(at: samplePath)
                print("Sample configuration created. Please edit it and restart the service.")
                exit(1)
            } catch {
                print("Failed to create sample configuration")
                exit(1)
            }
        } catch {
            print("Failed to load configuration; check its syntax, values, and permissions")
            exit(1)
        }

        guard let config = ConfigManager.shared.config else {
            print("Configuration is invalid")
            exit(1)
        }

        let allTopics = config.allTopics.map { $0.name }
        guard !allTopics.isEmpty else {
            print("No topics configured")
            exit(1)
        }

        Log.info("ntfy-macos v\(AppConstants.effectiveVersion) starting...")
        Log.info("Configured servers: \(config.servers.count)")

        // Start watching config file for changes
        configWatcher = ConfigWatcher(configPath: ConfigManager.shared.activeConfigPath)
        configWatcher?.startWatching { [weak self] in
            Task { @MainActor in self?.reloadConfig() }
        }
    }

    func startService() {
        guard ConfigManager.shared.config != nil else {
            print("Configuration is invalid")
            fflush(stdout)
            return
        }

        let notificationManager = ensureNotificationManager()
        let expectedGeneration = serviceGeneration

        // Check authorization status before starting the service
        notificationManager.getAuthorizationStatus { [weak self] status in
            Task { @MainActor in
                guard let self, self.serviceGeneration == expectedGeneration else { return }

                let statusName: String
                switch status {
                case .notDetermined: statusName = "not determined"
                case .denied: statusName = "denied"
                case .authorized: statusName = "authorized"
                case .provisional: statusName = "provisional"
                case .ephemeral: statusName = "ephemeral"
                @unknown default: statusName = "unknown"
                }
                Log.info("Authorization status: \(statusName)")

                if status == .authorized {
                    self.connectClients()
                } else {
                    Log.info("Requesting notification permission...")
                    PermissionHelper.requestPermissionsWithWindow { granted in
                        Task { @MainActor in
                            guard self.serviceGeneration == expectedGeneration else { return }
                            if granted {
                                Log.success("Permission granted!")
                                self.connectClients()
                            } else {
                                Log.error("Notification permission not granted")
                                Log.info("   Please enable notifications in System Settings → Notifications → ntfy-macos")
                                exit(1)
                            }
                        }
                    }
                }
            }
        }
    }

    private func connectClients() {
        guard clients.isEmpty, let config = ConfigManager.shared.config else { return }

        // Start local notification server if configured
        if let port = config.localServerPort, let token = config.localServerToken, token.count >= 32 {
            localServer?.stop()
            localServer = LocalNotificationServer(port: port, authToken: token)
            do {
                try localServer?.start()
            } catch {
                Log.error("Failed to start local notification server")
            }
        } else {
            localServer?.stop()
            localServer = nil
        }

        // Initialize status bar with server info
        let serverInfos = config.servers.map { server in
            (url: server.url, topics: server.topics.map { $0.name })
        }
        StatusBarController.shared.initializeServers(servers: serverInfos)

        // Create clients for each server, grouping topics by fetch_missed setting
        for serverConfig in config.servers {
            guard !serverConfig.topics.isEmpty else { continue }

            let authToken = ConfigManager.shared.getAuthToken(forServer: serverConfig.url)

            // Group topics by their fetch_missed setting (topic-level overrides server-level)
            let topicsWithFetchMissed = serverConfig.topics.filter { topic in
                topic.fetchMissed ?? serverConfig.shouldFetchMissed
            }.map { $0.name }

            let topicsWithoutFetchMissed = serverConfig.topics.filter { topic in
                !(topic.fetchMissed ?? serverConfig.shouldFetchMissed)
            }.map { $0.name }

            // Create client for topics that need fetch_missed
            if !topicsWithFetchMissed.isEmpty {
                Log.info("Creating subscription (fetch_missed: true, topics: \(topicsWithFetchMissed.count))")
                let client = NtfyClient(
                    serverURL: serverConfig.url,
                    topics: topicsWithFetchMissed,
                    authToken: authToken,
                    fetchMissed: true
                )
                client.delegate = self
                self.clients.append(client)
                self.clientToServer[ObjectIdentifier(client)] = serverConfig.url
                client.connect()
            }

            // Create client for topics that don't need fetch_missed
            if !topicsWithoutFetchMissed.isEmpty {
                Log.info("Creating subscription (fetch_missed: false, topics: \(topicsWithoutFetchMissed.count))")
                let client = NtfyClient(
                    serverURL: serverConfig.url,
                    topics: topicsWithoutFetchMissed,
                    authToken: authToken,
                    fetchMissed: false
                )
                client.delegate = self
                self.clients.append(client)
                self.clientToServer[ObjectIdentifier(client)] = serverConfig.url
                client.connect()
            }
        }
    }

    func reloadConfig() {
        Log.info("Reloading configuration...")

        // Load transactionally from the active path before retiring working clients.
        do {
            try ConfigManager.shared.loadConfig(from: ConfigManager.shared.activeConfigPath)
            DispatchQueue.main.async {
                // Check for config warnings (unknown keys, etc.)
                if let warning = ConfigManager.shared.configWarning {
                    Log.info("Configuration contains warnings")
                    StatusBarController.shared.showConfigWarning(warning)
                } else {
                    StatusBarController.shared.clearConfigError()
                }
            }
        } catch {
            Log.error("Failed to reload configuration")
            let errorMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            DispatchQueue.main.async {
                StatusBarController.shared.showConfigError(errorMessage)
            }
            return
        }

        serviceGeneration &+= 1
        localServer?.stop()
        localServer = nil
        let retiredClients = clients
        clients.removeAll()
        clientToServer.removeAll()
        for client in retiredClients {
            client.delegate = nil
            client.disconnect()
        }
        notificationManager?.clearCategories()

        guard let config = ConfigManager.shared.config else {
            Log.error("Configuration is invalid")
            return
        }

        Log.info("Reloaded servers: \(config.servers.count)")

        // Reconnect with new config
        startService()
    }

    func ntfyClient(_ client: NtfyClient, didReceiveMessage message: NtfyMessage) {
        guard let origin = activeOrigin(for: client),
              message.event == "message", client.isSubscribed(to: message.topic),
              let topicConfig = ConfigManager.shared.topicConfig(for: message.topic, serverURL: origin) else {
            return
        }
        Log.info("Received subscribed notification")

        // Handle auto-run scripts
        if let autoRunScript = topicConfig.autoRunScript {
            if scriptRunner.validateScript(at: autoRunScript) {
                Log.info("Running configured automation")
                // Pass message context as environment variables
                var env: [String: String] = [
                    "NTFY_ID": message.id,
                    "NTFY_TOPIC": message.topic,
                    "NTFY_TIME": String(message.time),
                    "NTFY_EVENT": message.event,
                ]
                if let title = message.title { env["NTFY_TITLE"] = title }
                if let msg = message.message { env["NTFY_MESSAGE"] = msg }
                if let priority = message.priority { env["NTFY_PRIORITY"] = String(priority) }
                if let tags = message.tags { env["NTFY_TAGS"] = tags.joined(separator: ",") }
                if let click = message.click { env["NTFY_CLICK"] = click }
                scriptRunner.runScript(at: autoRunScript, withArgument: message.message, extraEnv: env)
            }
        }

        // Show notification (respects silent flag)
        ensureNotificationManager().showNotification(for: message, topicConfig: topicConfig, originatingServerURL: origin)
    }

    private func activeOrigin(for client: NtfyClient) -> String? {
        guard clients.contains(where: { $0 === client }),
              let origin = clientToServer[ObjectIdentifier(client)],
              origin == client.serverURL else { return nil }
        return origin
    }

    func ntfyClient(_ client: NtfyClient, didEncounterError error: Error) {
        guard activeOrigin(for: client) != nil else { return }
        Log.error("Subscription error (code \((error as NSError).code))")
    }

    func ntfyClientDidConnect(_ client: NtfyClient) {
        guard let serverUrl = activeOrigin(for: client) else { return }
        Log.success("Connected to subscription server")
        StatusBarController.shared.setServerConnected(serverUrl, connected: true)
    }

    func ntfyClientDidDisconnect(_ client: NtfyClient) {
        guard let serverUrl = activeOrigin(for: client) else { return }
        Log.info("Disconnected from subscription server")
        StatusBarController.shared.setServerConnected(serverUrl, connected: false)
    }
}

struct CLI {
    // Keep a strong reference to prevent deallocation
    @MainActor
    static var ntfyAppInstance: NtfyMacOS?

    @MainActor
    static func main() -> Bool {
        let arguments = CommandLine.arguments

        // When launched without arguments (e.g., via double-click or `open`),
        // start serve mode directly
        if arguments.count < 2 {
            print("🚀 Starting ntfy-macos service...")
            ntfyAppInstance = NtfyMacOS()
            ntfyAppInstance?.serve(configPath: nil)

            guard ConfigManager.shared.config != nil else {
                print("Configuration is invalid. Run 'ntfy-macos serve' to create a sample config.")
                return false
            }

            // Schedule the actual service start for after RunLoop begins
            // Use Timer to ensure RunLoop is actively running
            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [ntfyAppInstance] _ in
                Task { @MainActor in ntfyAppInstance?.startService() }
            }

            return true // Needs RunLoop
        }

        let command = arguments[1]

        switch command {
        case "serve":
            let configPath = getFlag(arguments: arguments, flag: "--config")
            ntfyAppInstance = NtfyMacOS()
            ntfyAppInstance?.serve(configPath: configPath)

            // Extract config for later use
            guard ConfigManager.shared.config != nil else {
                print("Configuration is invalid")
                exit(1)
            }

            // Schedule the actual service start for after RunLoop begins
            // Use Timer to ensure RunLoop is actively running
            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [ntfyAppInstance] _ in
                Task { @MainActor in ntfyAppInstance?.startService() }
            }

            return true // Needs RunLoop

        case "auth":
            handleAuth(arguments: arguments)
            return false

        case "test-notify":
            handleTestNotify(arguments: arguments)
            return true // Needs RunLoop

        case "init":
            handleInit(arguments: arguments)
            return false

        case "help", "--help", "-h":
            printUsage()
            exit(0)

        default:
            print("Unknown command")
            printUsage()
            exit(1)
        }
    }

    static func handleAuth(arguments: [String]) {
        // Check for subcommand: add, list, remove
        guard arguments.count >= 3 else {
            printAuthUsage()
            exit(1)
        }

        let subcommand = arguments[2]

        switch subcommand {
        case "add":
            // ntfy-macos auth add <server-url> <token>
            guard arguments.count >= 5 else {
                print("Usage: ntfy-macos auth add <server-url> <token>")
                exit(1)
            }
            let server = arguments[3]
            let token = arguments[4]

            do {
                try KeychainHelper.saveToken(token, forServer: server)
                print("✅ Token saved")
            } catch {
                print("❌ Failed to save token")
                exit(1)
            }

        case "list":
            // ntfy-macos auth list
            do {
                let servers = try KeychainHelper.listServers()
                if servers.isEmpty {
                    print("No tokens stored in Keychain.")
                } else {
                    print("Stored tokens for servers:")
                    for server in servers {
                        print("  • \(server)")
                    }
                }
            } catch {
                print("❌ Failed to list servers")
                exit(1)
            }

        case "remove":
            // ntfy-macos auth remove <server-url>
            guard arguments.count >= 4 else {
                print("Usage: ntfy-macos auth remove <server-url>")
                exit(1)
            }
            let server = arguments[3]

            do {
                try KeychainHelper.deleteToken(forServer: server)
                print("✅ Token removed")
            } catch {
                print("❌ Failed to remove token")
                exit(1)
            }

        default:
            print("Unknown auth subcommand")
            printAuthUsage()
            exit(1)
        }
    }

    static func printAuthUsage() {
        print("""
        Usage: ntfy-macos auth <subcommand>

        Subcommands:
            add <server-url> <token>    Store a token in Keychain
            list                        List all servers with stored tokens
            remove <server-url>         Remove a token from Keychain

        Examples:
            ntfy-macos auth add https://ntfy.sh tk_mytoken
            ntfy-macos auth list
            ntfy-macos auth remove https://ntfy.sh
        """)
    }

    @MainActor
    static func handleTestNotify(arguments: [String]) {
        guard let topic = getFlag(arguments: arguments, flag: "--topic") else {
            print("Usage: ntfy-macos test-notify --topic <NAME>")
            exit(1)
        }

        print("🚀 Requesting notification permissions with GUI window...")

        PermissionHelper.requestPermissionsWithWindow { granted in
            Task { @MainActor in
                if granted {
                    let notificationManager = NotificationManager.shared
                    notificationManager.showTestNotification(topic: topic)
                    print("✅ Test notification sent")
                    // Give time for notification to be delivered, then exit cleanly
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        NSApp.terminate(nil)
                    }
                } else {
                    print("❌ Notification permission denied")
                    print("")
                    print("💡 The app should now appear in System Settings → Notifications")
                    print("   Please enable notifications there and try again.")
                    NSApp.terminate(nil)
                }
            }
        }

        // Don't call RunLoop here - it's managed by the entry point
    }

    static func handleInit(arguments: [String]) {
        let configPath = getFlag(arguments: arguments, flag: "--path") ?? ConfigManager.defaultConfigPath

        do {
            try ConfigManager.createSampleConfig(at: configPath)
            print("Sample configuration created at: \(configPath)")
            print("Please edit the configuration file and run 'ntfy-macos serve' to start the service.")
        } catch {
            print("Failed to create configuration")
            exit(1)
        }
    }

    static func getFlag(arguments: [String], flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    static func printUsage() {
        print("""
        ntfy-macos - Native macOS CLI Notifier & Automation Agent

        USAGE:
            ntfy-macos <COMMAND> [OPTIONS]

        COMMANDS:
            serve                    Start the notification service
                --config <PATH>      Optional: Custom configuration file path

            auth <subcommand>        Manage authentication tokens in Keychain
                add <url> <token>    Store a token for a server
                list                 List all servers with stored tokens
                remove <url>         Remove a token for a server

            test-notify              Send a test notification
                --topic <NAME>       Topic name to test

            init                     Create a sample configuration file
                --path <PATH>        Optional: Custom path for config file

            help                     Show this help message

        EXAMPLES:
            # Create configuration
            ntfy-macos init

            # Store authentication token in Keychain
            ntfy-macos auth add https://ntfy.sh tk_mytoken

            # List stored tokens
            ntfy-macos auth list

            # Remove a token
            ntfy-macos auth remove https://ntfy.sh

            # Start the service
            ntfy-macos serve

            # Test notifications
            ntfy-macos test-notify --topic alerts

        CONFIGURATION:
            Default config location: ~/.config/ntfy-macos/config.yml

            Tokens can be stored either:
            - In the config file (token: field under each server)
            - In the Keychain (using 'auth add' command) - more secure

        For more information, visit: https://github.com/laurentftech/ntfy-macos
        """)
    }
}

// App delegate to disable state restoration (prevents crashes from corrupted saved state)
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldRestoreSecureUntitleableWindows(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Unregister from launchctl to allow clean restart via brew services
        // This silently fails if not launched via brew services, which is fine
        let uid = getuid()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["bootout", "gui/\(uid)/homebrew.mxcl.ntfy-macos"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
    }
}

// Entry point - Initialize NSApplication for proper macOS app behavior
let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate

// Schedule CLI execution after the run loop starts to ensure AppKit is fully initialized
// This fixes the frozen window issue where events weren't being processed
DispatchQueue.main.async {
    let needsRunLoop = CLI.main()
    if !needsRunLoop {
        // Commands that don't need the run loop can exit immediately
        NSApp.terminate(nil)
    } else {
        // For serve command: use accessory mode (menu bar only, no Dock icon)
        app.setActivationPolicy(.accessory)
        StatusBarController.shared.setup()
        StatusBarController.shared.onReloadConfig = {
            CLI.ntfyAppInstance?.reloadConfig()
        }

        // Show any initial config warnings
        if let warning = ConfigManager.shared.configWarning {
            Log.info("Configuration contains warnings")
            StatusBarController.shared.showConfigWarning(warning)
        }
    }
}

// Start the run loop - this properly initializes AppKit and processes events
app.run()
