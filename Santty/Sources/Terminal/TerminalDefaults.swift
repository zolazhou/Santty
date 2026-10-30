import AppKit
import GhosttyTerminal
import GhosttyTheme

enum TerminalDefaults {
    // Shared with the scroll-mode overlay for terminal cell positioning.
    static let innerPadding: CGFloat = 2
    static let defaultThemeName = "Catppuccin Mocha"

    static var availableThemeNames: [String] {
        GhosttyThemeCatalog.allThemes
            .map(\.name)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    @MainActor
    static var theme: TerminalTheme {
        themeDefinition?.toTerminalTheme() ?? TerminalTheme()
    }

    @MainActor
    static var themeDefinition: GhosttyThemeDefinition? {
        guard
            let theme = GhosttyThemeCatalog.theme(named: TerminalSettings.themeName)
                ?? GhosttyThemeCatalog.theme(named: defaultThemeName)
        else {
            assertionFailure("Missing bundled Ghostty theme: \(defaultThemeName)")
            return nil
        }

        return theme
    }

    @MainActor
    static var configuration: TerminalConfiguration {
        TerminalConfiguration(startingFrom: .default) { builder in
            // Preserve the previous history budget instead of 1.4's new 50 MB default.
            builder.withCustom("scrollback-limit-bytes", "10000000")
            builder.withWindowPaddingX(Int(innerPadding))
            builder.withWindowPaddingY(Int(innerPadding))
            builder.withFontFamily(TerminalSettings.fontFamily)
            builder.withFontSize(Float(TerminalSettings.fontSize))
            builder.withBackgroundOpacity(AppAppearanceDefaults.terminalBackgroundOpacity)
        }
    }
}
