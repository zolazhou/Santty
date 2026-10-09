import AppKit
import KeyboardShortcuts

enum KeybindingAction: String, CaseIterable, Identifiable {
    case toggleNotes
    case toggleMaximizeWindow
    case splitPaneHorizontally
    case splitPaneVertically
    case equalizePaneSplits
    case movePaneDividerUp
    case movePaneDividerDown
    case movePaneDividerLeft
    case movePaneDividerRight
    case focusPreviousPane
    case focusNextPane
    case focusLeftPane
    case focusRightPane
    case focusAbovePane
    case focusBelowPane
    case movePaneLeft
    case movePaneRight
    case movePaneUp
    case movePaneDown
    case newBrowserPane
    case newNotesPane
    case focusBrowserLocation
    case convertPaneToBrowser
    case convertPaneToTerminal
    case toggleFloatingPane
    case detachPane
    case attachDetachedPane
    case openPromptEditor
    case enterScrollMode
    case autoResizePane
    case closePane
    case newTab
    case closeTab
    case focusPreviousTab
    case focusNextTab

    var id: String { rawValue }
    var isGlobal: Bool { self == .toggleNotes }

    var commandID: String {
        switch self {
        case .toggleNotes:
            "app.notes"
        case .toggleMaximizeWindow:
            "window.zoom"
        case .splitPaneHorizontally:
            "pane.split.horizontal"
        case .splitPaneVertically:
            "pane.split.vertical"
        case .equalizePaneSplits:
            "pane.resize.equalize"
        case .movePaneDividerUp:
            "pane.resize.up"
        case .movePaneDividerDown:
            "pane.resize.down"
        case .movePaneDividerLeft:
            "pane.resize.left"
        case .movePaneDividerRight:
            "pane.resize.right"
        case .focusPreviousPane:
            "pane.focus.previous"
        case .focusNextPane:
            "pane.focus.next"
        case .focusLeftPane:
            "pane.focus.left"
        case .focusRightPane:
            "pane.focus.right"
        case .focusAbovePane:
            "pane.focus.above"
        case .focusBelowPane:
            "pane.focus.below"
        case .movePaneLeft:
            "pane.move.left"
        case .movePaneRight:
            "pane.move.right"
        case .movePaneUp:
            "pane.move.up"
        case .movePaneDown:
            "pane.move.down"
        case .newNotesPane:
            "pane.notes.new"
        case .newBrowserPane:
            "pane.browser.new"
        case .focusBrowserLocation:
            "pane.browser.location"
        case .convertPaneToBrowser:
            "pane.browser.convert"
        case .convertPaneToTerminal:
            "pane.terminal.convert"
        case .toggleFloatingPane:
            "pane.floating.toggle"
        case .detachPane:
            "pane.detach"
        case .attachDetachedPane:
            "pane.detached.attach"
        case .openPromptEditor:
            "pane.promptEditor"
        case .enterScrollMode:
            "pane.scrollMode.enter"
        case .autoResizePane:
            "pane.autoResize"
        case .closePane:
            "pane.close"
        case .newTab:
            "tab.new"
        case .closeTab:
            "tab.close"
        case .focusPreviousTab:
            "tab.focus.previous"
        case .focusNextTab:
            "tab.focus.next"
        }
    }

    var title: String {
        switch self {
        case .toggleNotes:
            "Toggle Notes"
        case .toggleMaximizeWindow:
            "Toggle Maximize Window"
        case .splitPaneHorizontally:
            "Split Horizontally"
        case .splitPaneVertically:
            "Split Vertically"
        case .equalizePaneSplits:
            "Equalize Splits"
        case .movePaneDividerUp:
            "Move Divider Up"
        case .movePaneDividerDown:
            "Move Divider Down"
        case .movePaneDividerLeft:
            "Move Divider Left"
        case .movePaneDividerRight:
            "Move Divider Right"
        case .focusPreviousPane:
            "Focus Previous Pane"
        case .focusNextPane:
            "Focus Next Pane"
        case .focusLeftPane:
            "Focus Left Pane"
        case .focusRightPane:
            "Focus Right Pane"
        case .focusAbovePane:
            "Focus Above Pane"
        case .focusBelowPane:
            "Focus Below Pane"
        case .movePaneLeft:
            "Move Pane Left"
        case .movePaneRight:
            "Move Pane Right"
        case .movePaneUp:
            "Move Pane Up"
        case .movePaneDown:
            "Move Pane Down"
        case .newNotesPane:
            "Open Notes in Pane"
        case .newBrowserPane:
            "New Browser Pane"
        case .focusBrowserLocation:
            "Focus Location Bar"
        case .convertPaneToBrowser:
            "Switch Pane to Browser"
        case .convertPaneToTerminal:
            "Switch Pane to Terminal"
        case .toggleFloatingPane:
            "Toggle Floating Pane"
        case .detachPane:
            "Detach Pane"
        case .attachDetachedPane:
            "Attach Detached Pane"
        case .openPromptEditor:
            "Open Prompt Editor"
        case .enterScrollMode:
            "Enter Scroll Mode"
        case .autoResizePane:
            "Auto Resize"
        case .closePane:
            "Close Pane"
        case .newTab:
            "New Tab"
        case .closeTab:
            "Close Tab"
        case .focusPreviousTab:
            "Previous Tab"
        case .focusNextTab:
            "Next Tab"
        }
    }

    var groupTitle: String {
        switch self {
        case .toggleNotes, .toggleMaximizeWindow:
            "Application"
        case .splitPaneHorizontally, .splitPaneVertically, .equalizePaneSplits,
            .movePaneDividerUp, .movePaneDividerDown, .movePaneDividerLeft,
            .movePaneDividerRight, .focusPreviousPane, .focusNextPane, .focusLeftPane,
            .focusRightPane, .focusAbovePane, .focusBelowPane, .movePaneLeft,
            .movePaneRight, .movePaneUp, .movePaneDown, .newBrowserPane, .newNotesPane,
            .focusBrowserLocation,
            .convertPaneToBrowser, .convertPaneToTerminal, .toggleFloatingPane, .detachPane,
            .attachDetachedPane, .openPromptEditor, .enterScrollMode, .autoResizePane, .closePane:
            "Pane"
        case .newTab, .closeTab, .focusPreviousTab, .focusNextTab:
            "Tab"
        }
    }

    var defaultShortcut: KeyboardShortcuts.Shortcut? {
        switch self {
        case .toggleNotes:
            .init(.n, modifiers: [.control, .option])
        case .toggleMaximizeWindow:
            .init(.m, modifiers: [.command, .option])
        case .splitPaneHorizontally:
            .init(.backslash, modifiers: [.command, .shift])
        case .splitPaneVertically:
            .init(.minus, modifiers: [.command, .shift])
        case .equalizePaneSplits:
            .init(.equal, modifiers: [.command, .shift])
        case .movePaneDividerUp:
            .init(.k, modifiers: [.command, .shift])
        case .movePaneDividerDown:
            .init(.j, modifiers: [.command, .shift])
        case .movePaneDividerLeft:
            .init(.h, modifiers: [.command, .shift])
        case .movePaneDividerRight:
            .init(.l, modifiers: [.command, .shift])
        case .focusPreviousPane:
            .init(.leftBracket, modifiers: [.command])
        case .focusNextPane:
            .init(.rightBracket, modifiers: [.command])
        case .focusLeftPane:
            .init(.h, modifiers: [.command])
        case .focusRightPane:
            .init(.l, modifiers: [.command])
        case .focusAbovePane:
            .init(.k, modifiers: [.command])
        case .focusBelowPane:
            .init(.j, modifiers: [.command])
        case .movePaneLeft:
            .init(.h, modifiers: [.option, .command])
        case .movePaneRight:
            .init(.l, modifiers: [.option, .command])
        case .movePaneUp:
            .init(.k, modifiers: [.option, .command])
        case .movePaneDown:
            .init(.j, modifiers: [.option, .command])
        case .newBrowserPane, .newNotesPane, .convertPaneToBrowser, .convertPaneToTerminal:
            nil
        case .focusBrowserLocation:
            .init(.l, modifiers: [.control])
        case .toggleFloatingPane:
            .init(.f, modifiers: [.command, .shift])
        case .detachPane, .attachDetachedPane:
            nil
        case .openPromptEditor:
            nil
        case .enterScrollMode:
            .init(.s, modifiers: [.command, .shift])
        case .autoResizePane:
            .init(.r, modifiers: [.command, .shift])
        case .closePane:
            .init(.w, modifiers: [.command])
        case .newTab:
            .init(.t, modifiers: [.command])
        case .closeTab:
            .init(.w, modifiers: [.command, .shift])
        case .focusPreviousTab:
            .init(.leftBracket, modifiers: [.command, .shift])
        case .focusNextTab:
            .init(.rightBracket, modifiers: [.command, .shift])
        }
    }

    @MainActor
    var shortcutName: KeyboardShortcuts.Name {
        let identifier = isGlobal ? "SanttyToggleNotes" : "Santty.\(rawValue)"
        let name = KeyboardShortcuts.Name(identifier, initial: defaultShortcut)
        // Notes is global; workspace shortcuts must remain local to Santty.
        if !isGlobal { KeyboardShortcuts.disable(name) }
        return name
    }
}

@MainActor
enum KeybindingSettings {
    static let didChangeNotification = Notification.Name("SanttyKeybindingSettingsDidChange")

    static func shortcut(for action: KeybindingAction) -> KeyboardShortcuts.Shortcut? {
        KeyboardShortcuts.getShortcut(for: action.shortcutName)
    }

    static func effectiveShortcut(for action: KeybindingAction) -> KeyboardShortcuts.Shortcut? {
        shortcut(for: action)
    }

    static func resetShortcut(for action: KeybindingAction) {
        KeyboardShortcuts.reset(action.shortcutName)
        notifyChange(for: action)
    }

    static func notifyChange(for action: KeybindingAction) {
        if action.isGlobal { KeyboardShortcuts.enable(action.shortcutName) }
        else { KeyboardShortcuts.disable(action.shortcutName) }
        NotificationCenter.default.post(name: didChangeNotification, object: action)
    }

    static func displayShortcut(for action: KeybindingAction) -> String? {
        effectiveShortcut(for: action)?.description
    }

    static func action(matching event: NSEvent) -> KeybindingAction? {
        guard let eventShortcut = KeyboardShortcuts.Shortcut(event: event) else {
            return nil
        }

        return KeybindingAction.allCases.first {
            !$0.isGlobal && effectiveShortcut(for: $0) == eventShortcut
        }
    }

    static func applyShortcut(for action: KeybindingAction, to menuItem: NSMenuItem) {
        guard let shortcut = effectiveShortcut(for: action),
            let keyEquivalent = shortcut.nsMenuItemKeyEquivalent
        else {
            menuItem.keyEquivalent = ""
            menuItem.keyEquivalentModifierMask = []
            return
        }

        menuItem.keyEquivalent = keyEquivalent
        menuItem.keyEquivalentModifierMask = shortcut.modifiers
    }
}
