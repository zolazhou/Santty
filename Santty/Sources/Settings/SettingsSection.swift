import SwiftUI

enum SettingsSection: String, CaseIterable, Hashable, Identifiable {
    case general
    case appearance
    case terminal
    case herdr
    case keybindings

    var id: Self { self }

    var title: String {
        switch self {
        case .general:
            "General"
        case .appearance:
            "Appearance"
        case .terminal:
            "Terminal"
        case .herdr:
            "Herdr"
        case .keybindings:
            "Keybindings"
        }
    }

    var systemImageName: String {
        switch self {
        case .general:
            "gear"
        case .appearance:
            "paintpalette"
        case .terminal:
            "terminal"
        case .herdr:
            "network"
        case .keybindings:
            "keyboard"
        }
    }
}
