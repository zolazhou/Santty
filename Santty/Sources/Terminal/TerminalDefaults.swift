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
            // Bounded history budget instead of 1.4's 50 MB default. The
            // surface keeps this per pane for the whole session, and retained
            // panes (other workspaces, hidden tabs) hold their scrollback, so
            // this is the app's largest memory term. 6 MB keeps a 6000-row
            // burst of wide, CJK-heavy output in scroll mode — the depth
            // HerdrWorkspaceTests locks in — while spending 40% less than the
            // previous 10 MB.
            builder.withCustom("scrollback-limit-bytes", "6000000")
            builder.withWindowPaddingX(Int(innerPadding))
            builder.withWindowPaddingY(Int(innerPadding))
            builder.withFontFamily(TerminalSettings.fontFamily)
            builder.withFontSize(Float(TerminalSettings.fontSize))
            builder.withBackgroundOpacity(AppAppearanceDefaults.terminalBackgroundOpacity)
        }
    }
}
