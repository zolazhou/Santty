import Foundation

@MainActor
struct HerdrSettings {
    static let shared = HerdrSettings()
    static let defaultHistoryLines = 2000
    static let historyRange = 0...10_000
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var executablePath: String? { defaults.string(forKey: "herdr.executablePath") }

    func saveExecutablePath(_ path: String?) {
        if let path { defaults.set(path, forKey: "herdr.executablePath") }
        else { defaults.removeObject(forKey: "herdr.executablePath") }
    }

    var historyLines: Int {
        get {
            guard defaults.object(forKey: "herdr.historyLines") != nil else { return Self.defaultHistoryLines }
            return Self.clampedHistoryLines(defaults.integer(forKey: "herdr.historyLines"))
        }
        nonmutating set { defaults.set(Self.clampedHistoryLines(newValue), forKey: "herdr.historyLines") }
    }

    static func clampedHistoryLines(_ value: Int) -> Int { min(max(value, historyRange.lowerBound), historyRange.upperBound) }

    static func executableURL(for path: String?) throws -> URL? {
        guard let path, !path.isEmpty else { return nil }
        guard path.hasPrefix("/"), path.rangeOfCharacter(from: .controlCharacters) == nil,
              FileManager.default.isExecutableFile(atPath: path),
              (try? URL(fileURLWithPath: path).resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw HerdrCoreError("Choose an executable hc file using its absolute path.", kind: "invalid_executable")
        }
        return URL(fileURLWithPath: path)
    }
}
