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
        workspaceTarget: AnyObject,
        commandPaletteAction: Selector,
        checkForUpdatesAction: Selector,
        settingsAction: Selector
    ) {
        let mainMenu = NSMenu()
        NSApp.mainMenu = mainMenu

        mainMenu.addItem(
            makeApplicationMenuItem(
                target: applicationTarget,
                commandPaletteAction: commandPaletteAction,
                checkForUpdatesAction: checkForUpdatesAction,
                settingsAction: settingsAction
            )
        )
        mainMenu.addItem(makePaneMenuItem(target: workspaceTarget))
        mainMenu.addItem(makeTabMenuItem(target: workspaceTarget))
        mainMenu.addItem(makeWindowMenuItem())
    }

    private static func makeApplicationMenuItem(
        target: AnyObject,
        commandPaletteAction: Selector,
        checkForUpdatesAction: Selector,
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

        if AppUpdater.shared.isAvailable {
            let checkForUpdatesItem = menu.addItem(
                withTitle: "Check for Updates...",
                action: checkForUpdatesAction,
                keyEquivalent: ""
            )
            checkForUpdatesItem.target = target
        }

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

    private static func makePaneMenuItem(target: AnyObject) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Pane")
        item.submenu = menu

        addKeybindingMenuItem(
            to: menu,
            action: .splitPaneHorizontally,
            selector: #selector(WorkspaceViewController.splitPaneHorizontally(_:)),
            target: target
        )

        addKeybindingMenuItem(
            to: menu,
            action: .splitPaneVertically,
            selector: #selector(WorkspaceViewController.splitPaneVertically(_:)),
            target: target
        )

        menu.addItem(.separator())

        addKeybindingMenuItem(
            to: menu,
            action: .newBrowserPane,
            selector: #selector(WorkspaceViewController.newBrowserPane(_:)),
            target: target
        )

        addKeybindingMenuItem(
            to: menu,
            action: .convertPaneToBrowser,
            selector: #selector(WorkspaceViewController.convertFocusedPaneToBrowser(_:)),
            target: target
        )

        addKeybindingMenuItem(
            to: menu,
            action: .convertPaneToTerminal,
            selector: #selector(WorkspaceViewController.convertFocusedPaneToTerminal(_:)),
            target: target
        )

        menu.addItem(makeResizeSplitMenuItem(target: target))

        menu.addItem(.separator())

        addKeybindingMenuItem(
            to: menu,
            action: .focusPreviousPane,
            selector: #selector(WorkspaceViewController.focusPreviousPane(_:)),
            target: target
        )

        addKeybindingMenuItem(
            to: menu,
            action: .focusNextPane,
            selector: #selector(WorkspaceViewController.focusNextPane(_:)),
            target: target
        )

        addKeybindingMenuItem(
            to: menu,
            action: .focusLeftPane,
            selector: #selector(WorkspaceViewController.focusLeftPane(_:)),
            target: target
        )

        addKeybindingMenuItem(
            to: menu,
            action: .focusRightPane,
            selector: #selector(WorkspaceViewController.focusRightPane(_:)),
            target: target
        )

        addKeybindingMenuItem(
            to: menu,
            action: .focusAbovePane,
            selector: #selector(WorkspaceViewController.focusAbovePane(_:)),
            target: target
        )

        addKeybindingMenuItem(
            to: menu,
            action: .focusBelowPane,
            selector: #selector(WorkspaceViewController.focusBelowPane(_:)),
            target: target
        )

        addKeybindingMenuItem(
            to: menu,
            action: .movePaneLeft,
            selector: #selector(WorkspaceViewController.movePaneLeft(_:)),
            target: target
        )

        addKeybindingMenuItem(
            to: menu,
            action: .movePaneRight,
            selector: #selector(WorkspaceViewController.movePaneRight(_:)),
            target: target
        )

        addKeybindingMenuItem(
            to: menu,
            action: .movePaneUp,
            selector: #selector(WorkspaceViewController.movePaneUp(_:)),
            target: target
        )

        addKeybindingMenuItem(
            to: menu,
            action: .movePaneDown,
            selector: #selector(WorkspaceViewController.movePaneDown(_:)),
            target: target
        )

        menu.addItem(.separator())

        addKeybindingMenuItem(
            to: menu,
            action: .toggleFloatingPane,
            selector: #selector(WorkspaceViewController.toggleFloatingPane(_:)),
            target: target
        )

        addKeybindingMenuItem(
            to: menu,
            action: .detachPane,
            selector: #selector(WorkspaceViewController.detachPane(_:)),
            target: target
        )

        addKeybindingMenuItem(
            to: menu,
            action: .attachDetachedPane,
            selector: #selector(WorkspaceViewController.attachDetachedPane(_:)),
            target: target
        )

        addKeybindingMenuItem(
            to: menu,
            action: .autoResizePane,
            selector: #selector(WorkspaceViewController.showAutoResizeSettings(_:)),
            target: target
        )

        addKeybindingMenuItem(
            to: menu,
            action: .openPromptEditor,
            selector: #selector(WorkspaceViewController.openPromptEditor(_:)),
            target: target
        )

        addKeybindingMenuItem(
            to: menu,
            action: .enterScrollMode,
            selector: #selector(WorkspaceViewController.enterScrollMode(_:)),
            target: target
        )

        menu.addItem(.separator())

        addKeybindingMenuItem(
            to: menu,
            action: .closePane,
            selector: #selector(WorkspaceViewController.closePane(_:)),
            target: target
        )

        menu.addItem(.separator())

        for index in 0..<9 {
            let menuItem = menu.addItem(
                withTitle: "Show Detached Pane \(index + 1)",
                action: #selector(WorkspaceViewController.toggleDetachedPaneAtIndex(_:)),
                keyEquivalent: "\(index + 1)"
            )
            menuItem.target = target
            menuItem.tag = index
            menuItem.keyEquivalentModifierMask = [.command, .shift]
        }

        return item
    }

    private static func makeResizeSplitMenuItem(target: AnyObject) -> NSMenuItem {
        let item = NSMenuItem()
        item.title = "Resize Split"

        let menu = NSMenu(title: "Resize Split")
        item.submenu = menu

        addKeybindingMenuItem(
            to: menu,
            action: .equalizePaneSplits,
            selector: #selector(WorkspaceViewController.equalizePaneSplits(_:)),
            target: target
        )

        menu.addItem(.separator())

        addKeybindingMenuItem(
            to: menu,
            action: .movePaneDividerUp,
            selector: #selector(WorkspaceViewController.movePaneDividerUp(_:)),
            target: target
        )

        addKeybindingMenuItem(
            to: menu,
            action: .movePaneDividerDown,
            selector: #selector(WorkspaceViewController.movePaneDividerDown(_:)),
            target: target
        )

        addKeybindingMenuItem(
            to: menu,
            action: .movePaneDividerLeft,
            selector: #selector(WorkspaceViewController.movePaneDividerLeft(_:)),
            target: target
        )

        addKeybindingMenuItem(
            to: menu,
            action: .movePaneDividerRight,
            selector: #selector(WorkspaceViewController.movePaneDividerRight(_:)),
            target: target
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

    private static func makeTabMenuItem(target: AnyObject) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Tab")
        item.submenu = menu

        addKeybindingMenuItem(
            to: menu,
            action: .newTab,
            selector: #selector(WorkspaceViewController.newTab(_:)),
            target: target
        )

        addKeybindingMenuItem(
            to: menu,
            action: .closeTab,
            selector: #selector(WorkspaceViewController.closeTab(_:)),
            target: target
        )

        menu.addItem(.separator())

        addKeybindingMenuItem(
            to: menu,
            action: .focusPreviousTab,
            selector: #selector(WorkspaceViewController.focusPreviousTab(_:)),
            target: target
        )

        addKeybindingMenuItem(
            to: menu,
            action: .focusNextTab,
            selector: #selector(WorkspaceViewController.focusNextTab(_:)),
            target: target
        )

        menu.addItem(.separator())

        for index in 0..<9 {
            let menuItem = menu.addItem(
                withTitle: "Focus Tab \(index + 1)",
                action: #selector(WorkspaceViewController.focusTabAtIndex(_:)),
                keyEquivalent: "\(index + 1)"
            )
            menuItem.target = target
            menuItem.tag = index
            menuItem.keyEquivalentModifierMask = [.command]
        }

        return item
    }

    @discardableResult
    private static func addKeybindingMenuItem(
        to menu: NSMenu,
        action: KeybindingAction,
        selector: Selector,
        target: AnyObject
    ) -> NSMenuItem {
        let menuItem = menu.addItem(
            withTitle: action.title,
            action: selector,
            keyEquivalent: ""
        )
        menuItem.target = target
        KeybindingSettings.applyShortcut(for: action, to: menuItem)
        return menuItem
    }
}
