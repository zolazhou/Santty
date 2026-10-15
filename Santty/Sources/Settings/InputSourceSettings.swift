import Foundation

@MainActor
enum InputSourceSettings {
    static let didChangeNotification = Notification.Name("Santty.InputSourceSettings.didChange")
    static let defaultsKey = "inputSources.configuration"
    nonisolated static let english = "@english"
    private static var cachedConfiguration = load(from: .standard, sources: SystemInputSources.available)

    struct Rule: Codable, Equatable, Identifiable, Sendable {
        var id = UUID()
        var program: String
        var inputSourceID: String
    }

    struct Configuration: Codable, Equatable, Sendable {
        var paneRulesEnabled = false
        var commandPaletteEnglish = false
        var englishInputSourceID = ""
        var rules: [Rule] = []

        func sourceID(for rule: Rule) -> String {
            rule.inputSourceID == InputSourceSettings.english ? englishInputSourceID : rule.inputSourceID
        }
    }

    static var configuration: Configuration {
        get { cachedConfiguration }
        set {
            cachedConfiguration = newValue
            save(newValue, to: .standard)
        }
    }

    static func load(from defaults: UserDefaults, sources: [SystemInputSources.Source]) -> Configuration {
        if let data = defaults.data(forKey: defaultsKey),
           let stored = try? JSONDecoder().decode(Configuration.self, from: data) { return stored }
        let englishID = sources.first { $0.id == "com.apple.keylayout.ABC" }?.id
            ?? sources.first { $0.languages.contains { $0 == "en" || $0.hasPrefix("en-") } }?.id ?? ""
        let chineseID = sources.first { $0.languages.contains { $0.hasPrefix("zh") } }?.id ?? ""
        return Configuration(englishInputSourceID: englishID, rules: [
            Rule(program: "claude", inputSourceID: chineseID),
            Rule(program: "codex", inputSourceID: chineseID),
            Rule(program: "nvim", inputSourceID: english),
        ])
    }

    static func save(_ value: Configuration, to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: defaultsKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}
