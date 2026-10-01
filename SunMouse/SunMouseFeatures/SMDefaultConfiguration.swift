import Foundation

/// Shared default rules and settings bundled for first-time setup.
enum SMDefaultConfiguration {
    static func load() throws -> SMRuleStore.Backup {
        guard let url = Bundle.main.url(forResource: "DefaultConfiguration", withExtension: "json") else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let backup = try JSONDecoder().decode(SMRuleStore.Backup.self, from: Data(contentsOf: url))
        guard backup.version == 1 else { throw SMError.invalidConfiguration }
        _ = try backup.rules.validated()
        return backup
    }
}
