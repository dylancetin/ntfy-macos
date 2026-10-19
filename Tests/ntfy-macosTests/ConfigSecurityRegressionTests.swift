import XCTest
import Yams
@testable import ntfy_macos

final class ConfigSecurityRegressionTests: XCTestCase {
    private var directory: URL!
    private var path: String { directory.appendingPathComponent("config.yml").path }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ntfy-security-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private var fixture: AppConfig {
        AppConfig(servers: [ServerConfig(url: "https://\(UUID().uuidString.lowercased()).example", topics: [TopicConfig(name: "alerts")])])
    }

    func testConfigWritesArePrivateAndNeverFollowSymlinks() throws {
        try ConfigManager.saveConfig(fixture, to: path)
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let link = directory.appendingPathComponent("linked.yml").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: path)
        XCTAssertThrowsError(try SecureConfigFile.read(from: link))
        XCTAssertThrowsError(try ConfigManager.saveConfig(fixture, to: link))
        XCTAssertThrowsError(try ConfigManager.createSampleConfig(at: path))
    }

    func testRejectsReadableOrGroupWritableConfigAndWritableParents() throws {
        try ConfigManager.saveConfig(fixture, to: path)
        for mode in [0o644, 0o660, 0o666] {
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
            XCTAssertThrowsError(try ConfigManager().loadConfig(from: path))
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o770], ofItemAtPath: directory.path)
        XCTAssertThrowsError(try ConfigManager().loadConfig(from: path))
    }

    func testValidationRunsOnActualLoadAndFailedLoadsPreserveOriginPath() throws {
        let manager = ConfigManager()
        try ConfigManager.saveConfig(fixture, to: path)
        try manager.loadConfig(from: path)
        let bad = directory.appendingPathComponent("invalid.yml").path
        try SecureConfigFile.write("servers:\n  - url: file:///tmp/untrusted\n    topics:\n      - name: alerts\n", to: bad)
        XCTAssertThrowsError(try manager.loadConfig(from: bad))
        XCTAssertEqual(manager.activeConfigPath, try SecureConfigFile.canonicalPath(for: path))
        XCTAssertEqual(manager.config?.servers.count, 1)
    }

    func testConfigErrorsDoNotEchoSecretYAML() throws {
        let secret = "sentinel-private-token"
        try SecureConfigFile.write("servers: [\ntoken: \(secret)", to: path)
        XCTAssertThrowsError(try ConfigManager().loadConfig(from: path)) { error in
            XCTAssertFalse(error.localizedDescription.contains(secret))
        }
    }

    func testConfigSizeBound() throws {
        let oversized = String(repeating: "x", count: SecureConfigFile.maximumBytes + 1)
        XCTAssertThrowsError(try SecureConfigFile.write(oversized, to: path))
        try Data(oversized.utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        XCTAssertThrowsError(try SecureConfigFile.read(from: path))
    }

    func testOriginScopedLookupNeverFallsBackToOtherServer() throws {
        let config = AppConfig(servers: [
            ServerConfig(url: "https://private.example", topics: [TopicConfig(name: "deploy", autoRunScript: "/trusted/deploy.sh")]),
            ServerConfig(url: "https://public.example", topics: [TopicConfig(name: "deploy")])
        ])
        try ConfigManager.saveConfig(config, to: path)
        let manager = ConfigManager()
        try manager.loadConfig(from: path)
        XCTAssertNil(manager.topicConfig(for: "deploy", serverURL: "https://public.example")?.autoRunScript)
        XCTAssertEqual(manager.topicConfig(for: "deploy", serverURL: "https://private.example")?.autoRunScript, "/trusted/deploy.sh")
        XCTAssertNil(manager.topicConfig(for: "deploy", serverURL: "https://unknown.example"))
        XCTAssertNil(manager.topicConfig(for: "deploy"))
        XCTAssertNil(config.serverConfig(forTopic: "deploy"))
    }

    @MainActor
    func testSettingsRoundTripPreservesPoliciesTokenAndActivePath() async throws {
        let config = AppConfig(servers: [
            ServerConfig(url: "https://\(UUID().uuidString.lowercased()).example", topics: [TopicConfig(name: "alerts")],
                         allowedSchemes: ["https"], allowedDomains: []),
            ServerConfig(url: "https://\(UUID().uuidString.lowercased()).example", topics: [TopicConfig(name: "events")],
                         allowedSchemes: [], allowedDomains: ["trusted.example"])
        ], localServerPort: 19292, localServerToken: String(repeating: "b", count: 64))
        try ConfigManager.saveConfig(config, to: path)
        let manager = ConfigManager()
        try manager.loadConfig(from: path)
        let model = SettingsViewModel(configManager: manager, loadToken: { _ in nil },
                                      saveToken: { _, _ in }, deleteToken: { _ in })
        model.loadFromConfig()
        model.servers[0].topics[0].name = "updated"
        model.save()
        XCTAssertNil(model.saveError)
        try manager.loadConfig(from: model.activeConfigPath)
        XCTAssertEqual(manager.activeConfigPath, try SecureConfigFile.canonicalPath(for: path))
        XCTAssertEqual(manager.config?.servers[0].topics[0].name, "updated")
        XCTAssertEqual(manager.config?.servers[0].allowedSchemes, ["https"])
        XCTAssertEqual(manager.config?.servers[0].allowedDomains, [])
        XCTAssertEqual(manager.config?.servers[1].allowedSchemes, [])
        XCTAssertEqual(manager.config?.servers[1].allowedDomains, ["trusted.example"])
        XCTAssertEqual(manager.config?.localServerToken, config.localServerToken)
        XCTAssertTrue(model.localServerCurlCommand?.contains("Authorization: Bearer") ?? false)
    }

    func testLocalServerCannotBeEnabledWithoutStrongToken() throws {
        XCTAssertThrowsError(try ConfigValidator.validate(AppConfig(servers: fixture.servers, localServerPort: 9292)))
        XCTAssertThrowsError(try ConfigValidator.validate(AppConfig(servers: fixture.servers, localServerPort: 9292, localServerToken: "short")))
        XCTAssertThrowsError(try ConfigValidator.validate(AppConfig(servers: fixture.servers, localServerPort: 0,
                                                                  localServerToken: String(repeating: "a", count: 64))))
    }

    func testRejectsParentAliasesAndDotDotBeforeFollowingFinalSymlinks() throws {
        try ConfigManager.saveConfig(fixture, to: path)
        let alias = directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: directory.path)
        XCTAssertThrowsError(try ConfigManager().loadConfig(from: alias.appendingPathComponent("config.yml").path))
        XCTAssertThrowsError(try ConfigManager.saveConfig(fixture, to: alias.appendingPathComponent("config.yml").path))
        let linked = directory.appendingPathComponent("linked.yml")
        try FileManager.default.createSymbolicLink(atPath: linked.path, withDestinationPath: path)
        XCTAssertThrowsError(try SecureConfigFile.read(from: directory.path + "/subdir/../linked.yml"))
        XCTAssertThrowsError(try SecureConfigFile.write("must not overwrite", to: directory.path + "/subdir/../linked.yml"))
        XCTAssertTrue(try SecureConfigFile.read(from: path).contains("servers:"))
    }

    private func chmod(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testACLReadGrantsRejectedDespitePrivateModeAndInheritedACLsStripped() throws {
        try ConfigManager.saveConfig(fixture, to: path)
        try chmod(["+a", "everyone allow read", path])
        XCTAssertThrowsError(try ConfigManager().loadConfig(from: path))
        try chmod(["-N", path])
        try chmod(["+a", "everyone allow read,file_inherit,directory_inherit", directory.path])
        defer { try? chmod(["-N", directory.path]) }
        try ConfigManager.saveConfig(fixture, to: path)
        // A fresh temp file inherited an allow ACL; the writer must have removed it.
        XCTAssertNoThrow(try ConfigManager().loadConfig(from: path))
    }

    func testACLWriteGrantOnParentRejected() throws {
        try ConfigManager.saveConfig(fixture, to: path)
        try chmod(["+a", "everyone allow add_file", directory.path])
        defer { try? chmod(["-N", directory.path]) }
        XCTAssertThrowsError(try ConfigManager().loadConfig(from: path))
        XCTAssertThrowsError(try ConfigManager.saveConfig(fixture, to: path))
    }

    @MainActor
    func testSettingsReportsCredentialFailuresInsteadOfDiscardingThem() async throws {
        try ConfigManager.saveConfig(fixture, to: path)
        let manager = ConfigManager()
        try manager.loadConfig(from: path)
        let locked = SettingsViewModel(configManager: manager, loadToken: { _ in throw CocoaError(.fileReadNoPermission) })
        locked.loadFromConfig()
        XCTAssertNotNil(locked.saveError)
        locked.save()
        XCTAssertTrue(locked.saveError?.contains("inaccessible") ?? false)

        let deletionFailure = SettingsViewModel(configManager: manager, loadToken: { _ in "old-test-token" },
                                                saveToken: { _, _ in },
                                                deleteToken: { _ in throw CocoaError(.fileWriteNoPermission) })
        deletionFailure.loadFromConfig()
        deletionFailure.servers[0].storeInKeychain = false
        deletionFailure.save()
        XCTAssertTrue(deletionFailure.saveError?.contains("Old credentials may still be active") ?? false)
    }
}
