import AppKit

@MainActor
enum AppAppearanceSettings {
    enum ActiveTabBackground {
        case solid(NSColor)
        case gradient(NSColor, NSColor)
    }

    static let didChangeNotification = Notification.Name(
        "AppAppearanceSettings.didChangeNotification")

    private static let accentColorKey = "appearance.accentColor"
    private static let activeTabBackgroundKindKey = "appearance.activeTabBackground.kind"
    private static let activeTabBackgroundSolidColorKey =
        "appearance.activeTabBackground.solidColor"
    private static let activeTabBackgroundGradientStartColorKey =
        "appearance.activeTabBackground.gradientStartColor"
    private static let activeTabBackgroundGradientEndColorKey =
        "appearance.activeTabBackground.gradientEndColor"
    private static let activePaneBorderWidthKey = "appearance.activePane.borderWidth"
    private static let windowHiddenKey = "appearance.windowHidden"
    private static let legacyAccentColorRedKey = "appearance.accentColor.red"
    private static let legacyAccentColorGreenKey = "appearance.accentColor.green"
    private static let legacyAccentColorBlueKey = "appearance.accentColor.blue"
    private static let legacyAccentColorAlphaKey = "appearance.accentColor.alpha"
    private static let userDefaults = UserDefaults.standard

    static let defaultAccentColor = NSColor.systemBlue
    static let defaultActivePaneBorderWidth: CGFloat = 3
    static let defaultIsWindowHidden = false
    static let activePaneBorderWidthRange: ClosedRange<CGFloat> = 0 ... 12

    static var defaultActiveTabBackground: ActiveTabBackground {
        .solid(accentColor.withAlphaComponent(0.9))
    }

    static var accentColor: NSColor {
        get {
            if let hex = userDefaults.string(forKey: accentColorKey),
                let color = color(fromHex: hex)
            {
                return color
            }

            return legacyAccentColor ?? defaultAccentColor
        }
        set {
            let color = rgbaColor(from: newValue)
            userDefaults.set(hexString(from: color), forKey: accentColorKey)
            removeLegacyAccentColor()
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    static var isWindowHidden: Bool {
        get {
            guard userDefaults.object(forKey: windowHiddenKey) != nil else {
                return defaultIsWindowHidden
            }

            return userDefaults.bool(forKey: windowHiddenKey)
        }
        set {
            userDefaults.set(newValue, forKey: windowHiddenKey)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    static var activePaneBorderWidth: CGFloat {
        get {
            guard userDefaults.object(forKey: activePaneBorderWidthKey) != nil else {
                return defaultActivePaneBorderWidth
            }

            return clampedActivePaneBorderWidth(
                CGFloat(userDefaults.double(forKey: activePaneBorderWidthKey))
            )
        }
        set {
            userDefaults.set(
                Double(clampedActivePaneBorderWidth(newValue)),
                forKey: activePaneBorderWidthKey
            )
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    static var activeTabBackground: ActiveTabBackground {
        get {
            switch userDefaults.string(forKey: activeTabBackgroundKindKey) {
            case "solid":
                guard
                    let hex = userDefaults.string(forKey: activeTabBackgroundSolidColorKey),
                    let color = color(fromHex: hex)
                else {
                    return defaultActiveTabBackground
                }

                return .solid(color)
            case "gradient":
                guard
                    let startHex = userDefaults.string(
                        forKey: activeTabBackgroundGradientStartColorKey),
                    let endHex = userDefaults.string(
                        forKey: activeTabBackgroundGradientEndColorKey),
                    let startColor = color(fromHex: startHex),
                    let endColor = color(fromHex: endHex)
                else {
                    return defaultActiveTabBackground
                }

                return .gradient(startColor, endColor)
            default:
                return defaultActiveTabBackground
            }
        }
        set {
            switch newValue {
            case .solid(let color):
                userDefaults.set("solid", forKey: activeTabBackgroundKindKey)
                userDefaults.set(
                    hexString(from: rgbaColor(from: color)),
                    forKey: activeTabBackgroundSolidColorKey)
                userDefaults.removeObject(forKey: activeTabBackgroundGradientStartColorKey)
                userDefaults.removeObject(forKey: activeTabBackgroundGradientEndColorKey)
            case .gradient(let startColor, let endColor):
                userDefaults.set("gradient", forKey: activeTabBackgroundKindKey)
                userDefaults.set(
                    hexString(from: rgbaColor(from: startColor)),
                    forKey: activeTabBackgroundGradientStartColorKey)
                userDefaults.set(
                    hexString(from: rgbaColor(from: endColor)),
                    forKey: activeTabBackgroundGradientEndColorKey)
                userDefaults.removeObject(forKey: activeTabBackgroundSolidColorKey)
            }
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    static func resetAccentColor() {
        userDefaults.removeObject(forKey: accentColorKey)
        removeLegacyAccentColor()
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    static func resetWindowHidden() {
        userDefaults.removeObject(forKey: windowHiddenKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    static func resetActivePaneBorderWidth() {
        userDefaults.removeObject(forKey: activePaneBorderWidthKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    static func resetActiveTabBackground() {
        userDefaults.removeObject(forKey: activeTabBackgroundKindKey)
        userDefaults.removeObject(forKey: activeTabBackgroundSolidColorKey)
        userDefaults.removeObject(forKey: activeTabBackgroundGradientStartColorKey)
        userDefaults.removeObject(forKey: activeTabBackgroundGradientEndColorKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    private static func rgbaColor(from color: NSColor) -> NSColor {
        color.usingColorSpace(.deviceRGB) ?? defaultAccentColor.usingColorSpace(.deviceRGB)
            ?? .systemBlue
    }

    private static var legacyAccentColor: NSColor? {
        guard
            userDefaults.object(forKey: legacyAccentColorRedKey) != nil,
            userDefaults.object(forKey: legacyAccentColorGreenKey) != nil,
            userDefaults.object(forKey: legacyAccentColorBlueKey) != nil,
            userDefaults.object(forKey: legacyAccentColorAlphaKey) != nil
        else {
            return nil
        }

        return NSColor(
            red: CGFloat(userDefaults.double(forKey: legacyAccentColorRedKey)),
            green: CGFloat(userDefaults.double(forKey: legacyAccentColorGreenKey)),
            blue: CGFloat(userDefaults.double(forKey: legacyAccentColorBlueKey)),
            alpha: CGFloat(userDefaults.double(forKey: legacyAccentColorAlphaKey))
        )
    }

    private static func hexString(from color: NSColor) -> String {
        let red = UInt8((color.redComponent * 255).rounded())
        let green = UInt8((color.greenComponent * 255).rounded())
        let blue = UInt8((color.blueComponent * 255).rounded())
        let alpha = UInt8((color.alphaComponent * 255).rounded())
        return String(format: "#%02X%02X%02X%02X", red, green, blue, alpha)
    }

    private static func color(fromHex hex: String) -> NSColor? {
        let value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard digits.count == 8,
            let rgba = UInt32(digits, radix: 16)
        else {
            return nil
        }

        return NSColor(
            red: CGFloat((rgba >> 24) & 0xFF) / 255,
            green: CGFloat((rgba >> 16) & 0xFF) / 255,
            blue: CGFloat((rgba >> 8) & 0xFF) / 255,
            alpha: CGFloat(rgba & 0xFF) / 255
        )
    }

    private static func clampedActivePaneBorderWidth(_ value: CGFloat) -> CGFloat {
        min(
            max(value, activePaneBorderWidthRange.lowerBound),
            activePaneBorderWidthRange.upperBound
        )
    }

    private static func removeLegacyAccentColor() {
        userDefaults.removeObject(forKey: legacyAccentColorRedKey)
        userDefaults.removeObject(forKey: legacyAccentColorGreenKey)
        userDefaults.removeObject(forKey: legacyAccentColorBlueKey)
        userDefaults.removeObject(forKey: legacyAccentColorAlphaKey)
    }
}
