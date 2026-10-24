import AppKit
import KeyboardShortcuts
import XCTest
@testable import Santty

@MainActor
final class AppMenuTests: XCTestCase {
    func testMaximizeMenuUsesConfigurableLocalShortcut() throws {
        let action = KeybindingAction.toggleMaximizeWindow
        let shortcutName = action.shortcutName
        let previousShortcut = KeyboardShortcuts.getShortcut(for: shortcutName)
        let previousMainMenu = NSApp.mainMenu
        let previousWindowsMenu = NSApp.windowsMenu
        defer {
            KeyboardShortcuts.setShortcut(previousShortcut, for: shortcutName)
            NSApp.mainMenu = previousMainMenu
            NSApp.windowsMenu = previousWindowsMenu
        }
        XCTAssertEqual(action.defaultShortcut, .init(.m, modifiers: [.command, .option]))
        KeyboardShortcuts.setShortcut(.init(.m, modifiers: [.command, .shift]), for: shortcutName)
        let target = AppDelegate()
        AppMenu.install(
            applicationTarget: target, workspaceTarget: NSObject(),
            commandPaletteAction: #selector(NSObject.description),
            checkForUpdatesAction: #selector(NSObject.description),
            settingsAction: #selector(NSObject.description)
        )
        let item = try XCTUnwrap(NSApp.windowsMenu?.item(withTitle: action.title))
        XCTAssertTrue(item.target === target)
        XCTAssertEqual(item.action, #selector(AppDelegate.toggleMaximizeWindow(_:)))
        XCTAssertEqual(item.keyEquivalent, "m")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .shift])
    }

    func testMainMenuIncludesEditMenuWithStandardEditingShortcuts() throws {
        let previousMainMenu = NSApp.mainMenu
        let previousWindowsMenu = NSApp.windowsMenu
        defer {
            NSApp.mainMenu = previousMainMenu
            NSApp.windowsMenu = previousWindowsMenu
        }

        let target = NSObject()
        let workspace = WorkspaceViewController()
        AppMenu.install(
            applicationTarget: target,
            workspaceTarget: workspace,
            commandPaletteAction: #selector(NSObject.description),
            checkForUpdatesAction: #selector(NSObject.description),
            settingsAction: #selector(NSObject.description)
        )

        let mainMenu = try XCTUnwrap(NSApp.mainMenu)
        let paneMenu = try XCTUnwrap(mainMenu.items.first { $0.submenu?.title == "Pane" }?.submenu)
        XCTAssertEqual(paneMenu.item(withTitle: "New Workspace")?.action,
            #selector(WorkspaceViewController.newWorkspace(_:)))
        XCTAssertNil(KeybindingAction.newWorkspace.defaultShortcut)
        XCTAssertEqual(paneMenu.item(withTitle: "Close Workspace")?.action,
            #selector(WorkspaceViewController.closeWorkspace(_:)))
        XCTAssertNil(KeybindingAction.closeWorkspace.defaultShortcut)
        XCTAssertEqual(KeybindingAction.closeWorkspace.rawValue, "closeWorkspace")
        XCTAssertEqual(paneMenu.item(withTitle: "Rename Workspace")?.action,
            #selector(WorkspaceViewController.renameWorkspace(_:)))
        XCTAssertNil(KeybindingAction.renameWorkspace.defaultShortcut)
        let tabMenu = try XCTUnwrap(mainMenu.items.first { $0.submenu?.title == "Tab" }?.submenu)
        XCTAssertEqual(tabMenu.item(withTitle: "Rename Tab")?.action,
            #selector(WorkspaceViewController.renameTab(_:)))
        XCTAssertNil(KeybindingAction.renameTab.defaultShortcut)
        XCTAssertEqual(paneMenu.item(withTitle: "Rename Pane...")?.action,
            #selector(WorkspaceViewController.renamePane(_:)))
        let editMenu = try XCTUnwrap(
            mainMenu.items.first { $0.submenu?.title == "Edit" }?.submenu
        )

        func assertItem(
            _ title: String,
            keyEquivalent: String,
            action: Selector,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            let item = editMenu.item(withTitle: title)
            XCTAssertNotNil(item, "Missing Edit menu item \(title)", file: file, line: line)
            XCTAssertEqual(item?.keyEquivalent, keyEquivalent, file: file, line: line)
            XCTAssertEqual(item?.action, action, file: file, line: line)
            // Nil target keeps the action on the responder chain so the
            // first responder (WKWebView, text field, terminal) receives it.
            XCTAssertNil(item?.target, file: file, line: line)
        }

        assertItem("Undo", keyEquivalent: "z", action: #selector(UndoManager.undo))
        assertItem("Redo", keyEquivalent: "Z", action: #selector(UndoManager.redo))
        assertItem("Cut", keyEquivalent: "x", action: #selector(NSText.cut(_:)))
        assertItem("Copy", keyEquivalent: "c", action: #selector(NSText.copy(_:)))
        assertItem("Paste", keyEquivalent: "v", action: #selector(NSText.paste(_:)))
        assertItem("Select All", keyEquivalent: "a", action: #selector(NSText.selectAll(_:)))
    }
}
