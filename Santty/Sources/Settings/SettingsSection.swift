import SwiftUI

enum SettingsSection: String, CaseIterable, Hashable, Identifiable {
    case appearance
    case terminal
    case agents
    case keybindings

    var id: Self { self }

    var title: String {
        switch self {
        case .appearance:
            "Appearance"
        case .terminal:
            "Terminal"
        case .agents:
            "Agents"
        case .keybindings:
            "Keybindings"
        }
    }

    var systemImageName: String {
        switch self {
        case .appearance:
            "paintpalette"
        case .terminal:
            "terminal"
        case .agents:
            "sparkles"
        case .keybindings:
            "keyboard"
        }
    }
}
