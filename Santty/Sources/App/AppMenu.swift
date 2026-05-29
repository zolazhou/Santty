import AppKit
import KeyboardShortcuts

@MainActor
enum AppMenuKeyEquivalents {
    static func perform(_ event: NSEvent, in menu: NSMenu?) -> Bool {
        guard event.type == .keyDown else {
            return false
        }

        guard let menu else {
            return false
        }

        if let item = matchingItem(for: event, in: menu),
            perform(item)
        {
            return true
        }

        return menu.performKeyEquivalent(with: event)
    }

    private static func perform(_ item: NSMenuItem) -> Bool {
        guard let action = item.action else {
            return false
        }

        if let target = item.target as AnyObject? {
            _ = target.perform(action, with: item)
            return true
        }

        return NSApp.sendAction(action, to: item.target, from: item)
    }

    private static func matchingItem(for event: NSEvent, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if let submenu = item.submenu,
                let match = matchingItem(for: event, in: submenu)
            {
                return match
            }

            guard item.isEnabled,
                !item.keyEquivalent.isEmpty
            else {
                continue
            }

            let itemModifiers = item.keyEquivalentModifierMask
                .intersection(.deviceIndependentFlagsMask)
                .subtracting(.capsLock)
            let eventShortcut = KeyboardShortcuts.Shortcut(event: event)
            let shortcutKeyEquivalent = eventShortcut?.nsMenuItemKeyEquivalent
            let shortcutModifiers = eventShortcut?.modifiers
                .intersection(.deviceIndependentFlagsMask)
                .subtracting(.capsLock)
            let shortcutMatches = shortcutKeyEquivalent?.lowercased()
                == item.keyEquivalent.lowercased()
                && shortcutModifiers == itemModifiers
            let characterMatches = item.keyEquivalent.lowercased()
                == event.charactersIgnoringModifiers?.lowercased()
                && event.modifierFlags
                    .intersection(.deviceIndependentFlagsMask)
                    .subtracting(.capsLock) == itemModifiers

            if shortcutMatches {
                return item
            }

            if characterMatches {
                return item
            }
        }

        return nil
    }
}

@MainActor
enum AppMenu {
    static func install(
        applicationTarget: AnyObject,
        commandPaletteAction: Selector,
        settingsAction: Selector
    ) {
        let mainMenu = NSMenu()
        NSApp.mainMenu = mainMenu

        mainMenu.addItem(
            makeApplicationMenuItem(
                target: applicationTarget,
                commandPaletteAction: commandPaletteAction,
                settingsAction: settingsAction
            )
        )
        mainMenu.addItem(makePaneMenuItem())
        mainMenu.addItem(makeTabMenuItem())
        mainMenu.addItem(makeWindowMenuItem())
    }

    private static func makeApplicationMenuItem(
        target: AnyObject,
        commandPaletteAction: Selector,
        settingsAction: Selector
    ) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Santty")
        item.submenu = menu

        let commandPaletteItem = menu.addItem(
            withTitle: "Command Palette",
            action: commandPaletteAction,
            keyEquivalent: "p"
        )
        commandPaletteItem.target = target
        commandPaletteItem.keyEquivalentModifierMask = [.command]

        menu.addItem(.separator())

        let settingsItem = menu.addItem(
            withTitle: "Settings...",
            action: settingsAction,
            keyEquivalent: ","
        )
        settingsItem.target = target
        settingsItem.keyEquivalentModifierMask = [.command]

        menu.addItem(.separator())

        menu.addItem(
            withTitle: "Quit Santty",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        return item
    }

    private static func makePaneMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Pane")
        item.submenu = menu

        addKeybindingMenuItem(
            to: menu,
            action: .splitPaneHorizontally,
            selector: #selector(WorkspaceViewController.splitPaneHorizontally(_:))
        )

        addKeybindingMenuItem(
            to: menu,
            action: .splitPaneVertically,
            selector: #selector(WorkspaceViewController.splitPaneVertically(_:))
        )

        menu.addItem(makeResizeSplitMenuItem())

        menu.addItem(.separator())

        addKeybindingMenuItem(
            to: menu,
            action: .focusPreviousPane,
            selector: #selector(WorkspaceViewController.focusPreviousPane(_:))
        )

        addKeybindingMenuItem(
            to: menu,
            action: .focusNextPane,
            selector: #selector(WorkspaceViewController.focusNextPane(_:))
        )

        addKeybindingMenuItem(
            to: menu,
            action: .focusLeftPane,
            selector: #selector(WorkspaceViewController.focusLeftPane(_:))
        )

        addKeybindingMenuItem(
            to: menu,
            action: .focusRightPane,
            selector: #selector(WorkspaceViewController.focusRightPane(_:))
        )

        addKeybindingMenuItem(
            to: menu,
            action: .focusAbovePane,
            selector: #selector(WorkspaceViewController.focusAbovePane(_:))
        )

        addKeybindingMenuItem(
            to: menu,
            action: .focusBelowPane,
            selector: #selector(WorkspaceViewController.focusBelowPane(_:))
        )

        menu.addItem(.separator())

        addKeybindingMenuItem(
            to: menu,
            action: .toggleFloatingPane,
            selector: #selector(WorkspaceViewController.toggleFloatingPane(_:))
        )

        addKeybindingMenuItem(
            to: menu,
            action: .detachPane,
            selector: #selector(WorkspaceViewController.detachPane(_:))
        )

        addKeybindingMenuItem(
            to: menu,
            action: .attachDetachedPane,
            selector: #selector(WorkspaceViewController.attachDetachedPane(_:))
        )

        addKeybindingMenuItem(
            to: menu,
            action: .autoResizePane,
            selector: #selector(WorkspaceViewController.showAutoResizeSettings(_:))
        )

        addKeybindingMenuItem(
            to: menu,
            action: .openPromptEditor,
            selector: #selector(WorkspaceViewController.openPromptEditor(_:))
        )

        menu.addItem(.separator())

        addKeybindingMenuItem(
            to: menu,
            action: .closePane,
            selector: #selector(WorkspaceViewController.closePane(_:))
        )

        menu.addItem(.separator())

        for index in 0..<9 {
            let menuItem = menu.addItem(
                withTitle: "Show Detached Pane \(index + 1)",
                action: #selector(WorkspaceViewController.toggleDetachedPaneAtIndex(_:)),
                keyEquivalent: "\(index + 1)"
            )
            menuItem.tag = index
            menuItem.keyEquivalentModifierMask = [.command, .shift]
        }

        return item
    }

    private static func makeResizeSplitMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        item.title = "Resize Split"

        let menu = NSMenu(title: "Resize Split")
        item.submenu = menu

        addKeybindingMenuItem(
            to: menu,
            action: .equalizePaneSplits,
            selector: #selector(WorkspaceViewController.equalizePaneSplits(_:))
        )

        menu.addItem(.separator())

        addKeybindingMenuItem(
            to: menu,
            action: .movePaneDividerUp,
            selector: #selector(WorkspaceViewController.movePaneDividerUp(_:))
        )

        addKeybindingMenuItem(
            to: menu,
            action: .movePaneDividerDown,
            selector: #selector(WorkspaceViewController.movePaneDividerDown(_:))
        )

        addKeybindingMenuItem(
            to: menu,
            action: .movePaneDividerLeft,
            selector: #selector(WorkspaceViewController.movePaneDividerLeft(_:))
        )

        addKeybindingMenuItem(
            to: menu,
            action: .movePaneDividerRight,
            selector: #selector(WorkspaceViewController.movePaneDividerRight(_:))
        )

        return item
    }

    private static func makeWindowMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Window")
        item.submenu = menu

        menu.addItem(
            withTitle: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )

        menu.addItem(
            withTitle: "Zoom",
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: ""
        )

        menu.addItem(
            withTitle: "Close Window",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )

        NSApp.windowsMenu = menu
        return item
    }

    private static func makeTabMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Tab")
        item.submenu = menu

        addKeybindingMenuItem(
            to: menu,
            action: .newTab,
            selector: #selector(WorkspaceViewController.newTab(_:))
        )

        addKeybindingMenuItem(
            to: menu,
            action: .closeTab,
            selector: #selector(WorkspaceViewController.closeTab(_:))
        )

        menu.addItem(.separator())

        addKeybindingMenuItem(
            to: menu,
            action: .focusPreviousTab,
            selector: #selector(WorkspaceViewController.focusPreviousTab(_:))
        )

        addKeybindingMenuItem(
            to: menu,
            action: .focusNextTab,
            selector: #selector(WorkspaceViewController.focusNextTab(_:))
        )

        menu.addItem(.separator())

        for index in 0..<9 {
            let menuItem = menu.addItem(
                withTitle: "Focus Tab \(index + 1)",
                action: #selector(WorkspaceViewController.focusTabAtIndex(_:)),
                keyEquivalent: "\(index + 1)"
            )
            menuItem.tag = index
            menuItem.keyEquivalentModifierMask = [.command]
        }

        return item
    }

    @discardableResult
    private static func addKeybindingMenuItem(
        to menu: NSMenu,
        action: KeybindingAction,
        selector: Selector
    ) -> NSMenuItem {
        let menuItem = menu.addItem(
            withTitle: action.title,
            action: selector,
            keyEquivalent: ""
        )
        KeybindingSettings.applyShortcut(for: action, to: menuItem)
        return menuItem
    }
}
