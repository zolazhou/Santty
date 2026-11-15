import AppKit
import Foundation

enum NativeSettingsError: Error, Equatable {
    case catalogUnavailable, invalidCatalog, reentrantUpdate
}

/// Pure owned RGB values. No GhosttyTerminal/config objects or old C dependency.
struct NativeTerminalTheme: Equatable, Sendable {
    let name: String
    let foreground: NativeRGB
    let background: NativeRGB
    let cursor: NativeRGB?
    let cursorText: NativeRGB?
    let selectionForeground: NativeRGB?
    let selectionBackground: NativeRGB?
    let palette: [UInt8: NativeRGB]
}

struct NativeThemeCatalog: Sendable {
    static let sourceRevision = "1d84cf66fe29abd1f24f10b88dcfc25882cf68ee"
    static let defaultName = "Catppuccin Mocha"
    let themes: [NativeTerminalTheme]
    var names: [String] { themes.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
    func theme(named name: String) -> NativeTerminalTheme? { themes.first { $0.name == name } }
    var defaultTheme: NativeTerminalTheme { themes.first { $0.name == Self.defaultName }! }

    private struct Resource: Decodable { let schemaVersion: Int; let sourceRevision: String; let themes: [Entry] }
    private struct Entry: Decodable {
        let name: String
        let foreground: String
        let background: String
        let cursorColor: String?
        let cursorText: String?
        let selectionForeground: String?
        let selectionBackground: String?
        let palette: [String: String]?
    }
    private final class Locator: NSObject {}
    private static let packaged: Result<NativeThemeCatalog, Error> = Result {
        guard let url = Bundle(for: Locator.self).url(forResource: "TerminalThemes", withExtension: "json") else {
            throw NativeSettingsError.catalogUnavailable
        }
        return try NativeThemeCatalog(data: Data(contentsOf: url))
    }
    static func bundled() throws -> NativeThemeCatalog { try packaged.get() }

    init(data: Data) throws {
        let resource = try JSONDecoder().decode(Resource.self, from: data)
        guard resource.schemaVersion == 1, resource.sourceRevision == Self.sourceRevision,
              !resource.themes.isEmpty, Set(resource.themes.map(\.name)).count == resource.themes.count,
              resource.themes.contains(where: { $0.name == Self.defaultName }) else { throw NativeSettingsError.invalidCatalog }
        func color(_ hex: String) throws -> NativeRGB {
            let value = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
            guard value.utf8.count == 6, value.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                  let rgb = UInt32(value, radix: 16) else { throw NativeSettingsError.invalidCatalog }
            return .init(red: UInt8((rgb >> 16) & 255), green: UInt8((rgb >> 8) & 255), blue: UInt8(rgb & 255))
        }
        themes = try resource.themes.map { entry in
            var palette: [UInt8: NativeRGB] = [:]
            for (index, hex) in entry.palette ?? [:] {
                guard let i = UInt8(index), String(i) == index else { throw NativeSettingsError.invalidCatalog }
                palette[i] = try color(hex)
            }
            return try .init(name: entry.name, foreground: color(entry.foreground), background: color(entry.background),
                cursor: entry.cursorColor.map(color), cursorText: entry.cursorText.map(color),
                selectionForeground: entry.selectionForeground.map(color), selectionBackground: entry.selectionBackground.map(color), palette: palette)
        }
    }
}

/// Matches the existing main preferences without reading or mutating them here.
/// The JSON catalog is an internal artifact, NOT a new user theme/config format.
struct NativeTerminalSettings: Equatable, Sendable {
    let theme: NativeTerminalTheme
    let fontFamily: String
    let fontSize: CGFloat
    let padding: CGFloat
    let backgroundOpacity: CGFloat
    let cursorShape: NativeTerminalFrame.CursorShape
    let cursorBlink: Bool
    static let innerPadding: CGFloat = 2

    init(theme: NativeTerminalTheme, fontFamily: String = "Menlo", fontSize: CGFloat = 13,
         padding: CGFloat = 8, backgroundOpacity: CGFloat = 0,
         cursorShape: NativeTerminalFrame.CursorShape = .block, cursorBlink: Bool = true) {
        self.theme = theme
        let name = fontFamily.trimmingCharacters(in: .whitespacesAndNewlines)
        self.fontFamily = name.isEmpty || name.utf8.count > 256 || name.utf8.contains(0) ? "Menlo" : name
        self.fontSize = fontSize.isFinite ? min(32, max(8, fontSize)) : 13
        self.padding = padding.isFinite ? min(24, max(0, padding)) : 8
        self.backgroundOpacity = backgroundOpacity.isFinite ? min(1, max(0, backgroundOpacity)) : 0
        self.cursorShape = cursorShape; self.cursorBlink = cursorBlink
    }

    @MainActor
    static func preferences(_ defaults: UserDefaults, catalog: NativeThemeCatalog, backgroundOpacity: CGFloat = 0) -> Self {
        let name = (defaults.string(forKey: "terminal.themeName") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(theme: catalog.theme(named: name) ?? catalog.defaultTheme,
            fontFamily: defaults.string(forKey: "terminal.fontFamily") ?? "Menlo",
            fontSize: defaults.object(forKey: "terminal.fontSize") == nil ? 13 : CGFloat(defaults.double(forKey: "terminal.fontSize")),
            padding: defaults.object(forKey: "terminal.padding") == nil ? 8 : CGFloat(defaults.double(forKey: "terminal.padding")),
            backgroundOpacity: backgroundOpacity)
    }

    @MainActor var font: NSFont { NSFont(name: fontFamily, size: fontSize) ?? NSFont(name: "Menlo", size: fontSize) ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular) }
}
