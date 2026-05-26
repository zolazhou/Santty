import GhosttyTerminal
import GhosttyTheme

enum TerminalDefaults {
    static let defaultThemeName = "Catppuccin Mocha"

    static var availableThemeNames: [String] {
        GhosttyThemeCatalog.allThemes
            .map(\.name)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    @MainActor
    static var theme: TerminalTheme {
        guard
            let theme = GhosttyThemeCatalog.theme(named: TerminalSettings.themeName)
                ?? GhosttyThemeCatalog.theme(named: defaultThemeName)
        else {
            assertionFailure("Missing bundled Ghostty theme: \(defaultThemeName)")
            return TerminalTheme()
        }

        return theme.toTerminalTheme()
    }

    @MainActor
    static var configuration: TerminalConfiguration {
        TerminalConfiguration(startingFrom: .default) { builder in
            builder.withFontFamily(TerminalSettings.fontFamily)
            builder.withFontSize(Float(TerminalSettings.fontSize))
            builder.withBackgroundOpacity(AppAppearanceDefaults.terminalBackgroundOpacity)
        }
    }
}
