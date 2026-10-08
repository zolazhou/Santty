import AppKit
import XCTest
@testable import Santty

@MainActor
final class AppMenuTests: XCTestCase {
    func testMainMenuIncludesEditMenuWithStandardEditingShortcuts() throws {
        let previousMainMenu = NSApp.mainMenu
        let previousWindowsMenu = NSApp.windowsMenu
        defer {
            NSApp.mainMenu = previousMainMenu
            NSApp.windowsMenu = previousWindowsMenu
        }

        let target = NSObject()
        AppMenu.install(
            applicationTarget: target,
            workspaceTarget: target,
            commandPaletteAction: #selector(NSObject.description),
            checkForUpdatesAction: #selector(NSObject.description),
            settingsAction: #selector(NSObject.description)
        )

        let mainMenu = try XCTUnwrap(NSApp.mainMenu)
        let paneMenu = try XCTUnwrap(mainMenu.items.first { $0.submenu?.title == "Pane" }?.submenu)
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
