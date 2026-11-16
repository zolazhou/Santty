import Foundation

@MainActor
enum TerminalSettings {
    static let didChangeNotification = Notification.Name("TerminalSettings.didChangeNotification")

    private static let themeNameKey = "terminal.themeName"
    private static let fontFamilyKey = "terminal.fontFamily"
    private static let fontSizeKey = "terminal.fontSize"
    private static let paddingKey = "terminal.padding"
    private static let paddingFillKey = "terminal.paddingFill"
    private static let renderingEngineKey = "terminal.renderingEngine"
    private static let userDefaults = UserDefaults.standard

    enum RenderingEngine: String, CaseIterable, Identifiable {
        case coreGraphics
        case metal

        var id: Self { self }
        var title: String { self == .coreGraphics ? "Core Graphics" : "Metal" }
    }

    static let defaultRenderingEngine: RenderingEngine = .coreGraphics
    static var renderingEngine: RenderingEngine {
        get { readRenderingEngine(from: userDefaults) }
        set { setRenderingEngine(newValue, defaults: userDefaults) }
    }

    // Explicit defaults injection keeps preference tests out of user settings.
    static func readRenderingEngine(from defaults: UserDefaults) -> RenderingEngine {
        defaults.string(forKey: renderingEngineKey).flatMap(RenderingEngine.init(rawValue:))
            ?? defaultRenderingEngine
    }

    static func setRenderingEngine(_ engine: RenderingEngine, defaults: UserDefaults) {
        defaults.set(engine.rawValue, forKey: renderingEngineKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    static func resetRenderingEngine(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: renderingEngineKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    static let defaultThemeName = "Catppuccin Mocha"
    static let defaultFontFamily = "Menlo"
    static let defaultFontSize: CGFloat = 13
    static let defaultPadding: CGFloat = 8
    static let fontSizeRange: ClosedRange<CGFloat> = 8...32
    static let paddingRange: ClosedRange<CGFloat> = 0...24

    static var themeName: String {
        get {
            guard let storedThemeName = userDefaults.string(forKey: themeNameKey) else {
                return defaultThemeName
            }

            return normalizedThemeName(storedThemeName)
        }
        set {
            userDefaults.set(normalizedThemeName(newValue), forKey: themeNameKey)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    static var fontFamily: String {
        get {
            guard let storedFamily = userDefaults.string(forKey: fontFamilyKey) else {
                return defaultFontFamily
            }

            return normalizedFontFamily(storedFamily)
        }
        set {
            userDefaults.set(normalizedFontFamily(newValue), forKey: fontFamilyKey)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    static var fontSize: CGFloat {
        get {
            guard userDefaults.object(forKey: fontSizeKey) != nil else {
                return defaultFontSize
            }

            return clampedFontSize(CGFloat(userDefaults.double(forKey: fontSizeKey)))
        }
        set {
            userDefaults.set(Double(clampedFontSize(newValue)), forKey: fontSizeKey)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    static var padding: CGFloat {
        get {
            guard userDefaults.object(forKey: paddingKey) != nil else {
                return defaultPadding
            }

            return clampedPadding(CGFloat(userDefaults.double(forKey: paddingKey)))
        }
        set {
            userDefaults.set(Double(clampedPadding(newValue)), forKey: paddingKey)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    static var paddingFill: TerminalPaddingFill {
        get { readPaddingFill(from: userDefaults) }
        set { setPaddingFill(newValue, defaults: userDefaults) }
    }

    static func readPaddingFill(from defaults: UserDefaults) -> TerminalPaddingFill {
        defaults.string(forKey: paddingFillKey).flatMap(TerminalPaddingFill.init(rawValue:)) ?? .automatic
    }

    static func setPaddingFill(_ value: TerminalPaddingFill, defaults: UserDefaults) {
        defaults.set(value.rawValue, forKey: paddingFillKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    static func resetPaddingFill(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: paddingFillKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    static func resetFontFamily() {
        userDefaults.removeObject(forKey: fontFamilyKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    static func resetThemeName() {
        userDefaults.removeObject(forKey: themeNameKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    static func resetFontSize() {
        userDefaults.removeObject(forKey: fontSizeKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    static func resetPadding() {
        userDefaults.removeObject(forKey: paddingKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    private static func normalizedThemeName(_ value: String) -> String {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? defaultThemeName : trimmedValue
    }

    private static func normalizedFontFamily(_ value: String) -> String {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? defaultFontFamily : trimmedValue
    }

    private static func clampedFontSize(_ value: CGFloat) -> CGFloat {
        min(max(value, fontSizeRange.lowerBound), fontSizeRange.upperBound)
    }

    private static func clampedPadding(_ value: CGFloat) -> CGFloat {
        min(max(value, paddingRange.lowerBound), paddingRange.upperBound)
    }
}
