import Foundation

@MainActor
enum TerminalSettings {
    static let didChangeNotification = Notification.Name("TerminalSettings.didChangeNotification")

    private static let themeNameKey = "terminal.themeName"
    private static let fontFamilyKey = "terminal.fontFamily"
    private static let fontSizeKey = "terminal.fontSize"
    private static let paddingKey = "terminal.padding"
    private static let userDefaults = UserDefaults.standard

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
