import Foundation
import Yams

extension ConfigManager {
    /// Serializes an AppConfig to YAML and writes it to the config file
    static func saveConfig(_ config: AppConfig, to path: String? = nil) throws {
        let configPath = path ?? defaultConfigPath
        try ConfigValidator.validate(config)

        let encoder = YAMLEncoder()
        let yamlString = try encoder.encode(config)

        let output = "# ntfy-macos configuration\n# Edit manually or use Settings in the menu bar\n\n" + yamlString

        try SecureConfigFile.write(output, to: configPath)
    }
}
