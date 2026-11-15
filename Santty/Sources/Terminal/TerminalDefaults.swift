import AppKit

enum TerminalDefaults {
    static let innerPadding: CGFloat = NativeTerminalSettings.innerPadding
    static let defaultThemeName = NativeThemeCatalog.defaultName
    @MainActor static var availableThemeNames: [String] { (try? NativeThemeCatalog.bundled().names) ?? [defaultThemeName] }
    @MainActor static func settings() throws -> NativeTerminalSettings {
        let catalog = try NativeThemeCatalog.bundled()
        return NativeTerminalSettings(theme:catalog.theme(named:TerminalSettings.themeName) ?? catalog.defaultTheme,
            fontFamily:TerminalSettings.fontFamily,fontSize:TerminalSettings.fontSize,padding:TerminalSettings.padding,
            backgroundOpacity:AppAppearanceDefaults.terminalBackgroundOpacity)
    }
}
