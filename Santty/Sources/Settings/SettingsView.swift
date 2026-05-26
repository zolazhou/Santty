import AppKit
import SwiftUI

@MainActor
struct SettingsView: View {
    @State private var selectedSection: SettingsSection? = .appearance
    @State private var accentColor: Color
    @State private var activeTabBackgroundKind: ActiveTabBackgroundKind
    @State private var activeTabSolidColor: Color
    @State private var activeTabGradientStartColor: Color
    @State private var activeTabGradientEndColor: Color
    @State private var activePaneBorderWidth: Double
    @State private var isWindowHidden: Bool
    @State private var terminalThemeName: String
    @State private var terminalFontFamily: String
    @State private var terminalFontSize: Double
    @State private var terminalPadding: Double

    init(
        accentColor: NSColor = AppAppearanceSettings.accentColor,
        activeTabBackground: AppAppearanceSettings.ActiveTabBackground =
            AppAppearanceSettings.activeTabBackground,
        activePaneBorderWidth: CGFloat = AppAppearanceSettings.activePaneBorderWidth,
        isWindowHidden: Bool = AppAppearanceSettings.isWindowHidden,
        terminalThemeName: String = TerminalSettings.themeName,
        terminalFontFamily: String = TerminalSettings.fontFamily,
        terminalFontSize: CGFloat = TerminalSettings.fontSize,
        terminalPadding: CGFloat = TerminalSettings.padding
    ) {
        _accentColor = State(initialValue: Color(nsColor: accentColor))
        switch activeTabBackground {
        case .solid(let color):
            _activeTabBackgroundKind = State(initialValue: .solid)
            _activeTabSolidColor = State(initialValue: Color(nsColor: color))
            _activeTabGradientStartColor = State(initialValue: Color(nsColor: accentColor))
            _activeTabGradientEndColor = State(
                initialValue: Color(nsColor: accentColor.withSystemEffect(.pressed))
            )
        case .gradient(let startColor, let endColor):
            _activeTabBackgroundKind = State(initialValue: .gradient)
            _activeTabSolidColor = State(initialValue: Color(nsColor: accentColor))
            _activeTabGradientStartColor = State(initialValue: Color(nsColor: startColor))
            _activeTabGradientEndColor = State(initialValue: Color(nsColor: endColor))
        }
        _activePaneBorderWidth = State(initialValue: Double(activePaneBorderWidth))
        _isWindowHidden = State(initialValue: isWindowHidden)
        _terminalThemeName = State(initialValue: terminalThemeName)
        _terminalFontFamily = State(initialValue: terminalFontFamily)
        _terminalFontSize = State(initialValue: Double(terminalFontSize))
        _terminalPadding = State(initialValue: Double(terminalPadding))
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selectedSection) { section in
                Label(section.title, systemImage: section.systemImageName)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 190, max: 240)
        } detail: {
            settingsPane(for: currentSection)
                .navigationTitle(currentSection.title)
        }
        .navigationSplitViewStyle(.prominentDetail)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                ControlGroup {
                    Button {
                        selectPreviousSection()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(previousSection == nil)
                    .help("Previous Settings Section")

                    Button {
                        selectNextSection()
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(nextSection == nil)
                    .help("Next Settings Section")
                }
                .controlGroupStyle(.navigation)
            }
        }
        .frame(width: 720, height: 520, alignment: .topLeading)
    }

    private var currentSection: SettingsSection {
        selectedSection ?? .appearance
    }

    private var currentSectionIndex: Int {
        SettingsSection.allCases.firstIndex(of: currentSection) ?? 0
    }

    private var previousSection: SettingsSection? {
        let previousIndex = currentSectionIndex - 1
        guard SettingsSection.allCases.indices.contains(previousIndex) else {
            return nil
        }

        return SettingsSection.allCases[previousIndex]
    }

    private var nextSection: SettingsSection? {
        let nextIndex = currentSectionIndex + 1
        guard SettingsSection.allCases.indices.contains(nextIndex) else {
            return nil
        }

        return SettingsSection.allCases[nextIndex]
    }

    private func selectPreviousSection() {
        guard let previousSection else {
            return
        }

        selectedSection = previousSection
    }

    private func selectNextSection() {
        guard let nextSection else {
            return
        }

        selectedSection = nextSection
    }

    @ViewBuilder
    private func settingsPane(for section: SettingsSection) -> some View {
        switch section {
        case .appearance:
            AppearanceSettingsPane(
                accentColor: $accentColor,
                activeTabBackgroundKind: $activeTabBackgroundKind,
                activeTabSolidColor: $activeTabSolidColor,
                activeTabGradientStartColor: $activeTabGradientStartColor,
                activeTabGradientEndColor: $activeTabGradientEndColor,
                activePaneBorderWidth: $activePaneBorderWidth,
                isWindowHidden: $isWindowHidden
            )
        case .terminal:
            TerminalSettingsPane(
                terminalThemeName: $terminalThemeName,
                terminalFontFamily: $terminalFontFamily,
                terminalFontSize: $terminalFontSize,
                terminalPadding: $terminalPadding
            )
        case .agents:
            AgentSettingsPane()
        case .keybindings:
            KeybindingSettingsPane()
        }
    }
}
