import AppKit
import XCTest
@testable import Santty

@MainActor
final class TerminalFontShortcutTests: XCTestCase {
    private func fixture() throws -> (NativeTerminalScrollView, NSWindow) {
        let view = NativeTerminalScrollView(driver: try GhosttyVTDriver(), frame: .init(x: 0, y: 0, width: 640, height: 250))
        view.feed("font-shortcut sentinel 中文🙂")
        let window = NSWindow(contentRect: view.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = view
        XCTAssertTrue(window.makeFirstResponder(view.renderer))
        XCTAssertTrue(view.hostActions.canPerform(.zoom), "Positive control: focused published page permits direct zoom")
        return (view, window)
    }

    private func key(_ text: String, ignoring: String? = nil, flags: NSEvent.ModifierFlags = .command,
                     code: UInt16, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 1, windowNumber: window.windowNumber, context: nil,
            characters: text, charactersIgnoringModifiers: ignoring ?? text, isARepeat: false, keyCode: code))
    }

    private func mainMenu() throws -> NSMenu {
        let target = NSObject()
        AppMenu.install(applicationTarget: target, workspaceTarget: target,
            commandPaletteAction: Selector(("testPalette:")), checkForUpdatesAction: Selector(("testUpdates:")),
            settingsAction: Selector(("testSettings:")))
        return try XCTUnwrap(NSApp.mainMenu)
    }

    func testMainMenuDeclaresResponderChainFontShortcuts() throws {
        let oldMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = oldMenu }
        let menu = try mainMenu()
        let view = try XCTUnwrap(menu.items.first { $0.submenu?.title == "View" }?.submenu,
            "Production must install its font actions, not only the lab menu")
        for (selector, equivalent) in [
            (#selector(NativeTerminalInputView.increaseFontSize(_:)), "="),
            (#selector(NativeTerminalInputView.decreaseFontSize(_:)), "-"),
            (#selector(NativeTerminalInputView.resetFontSize(_:)), "0")
        ] {
            let item = try XCTUnwrap(view.items.first { $0.action == selector })
            XCTAssertEqual(item.keyEquivalent, equivalent)
            XCTAssertEqual(item.keyEquivalentModifierMask, .command)
            XCTAssertNil(item.target, "The focused responder, not a cached pane, owns zoom")
        }
    }

    func testCmdEqualsMinusPlusAndZeroReachActualRendererWithoutTerminalInput() throws {
        let (view, window) = try fixture()
        defer { window.contentView = nil }
        let output = NativeTerminalOutput(driver: view.driver) { _ in }
        output.bindChecked { _ in XCTFail("Font shortcuts must not write terminal input"); return false }
        output.setInputEnabled(true); view.renderer.output = output; view.renderer.inputEnabled = true
        let before = view.renderer.font.pointSize, text = try view.driver.readScreenText()
        let epoch = view.driver.metadata.resetEpoch, lease = output.userInputLease
        view.hostActions.zoomResetSize = before
        for (characters, ignoring, flags, code, expected) in [
            ("=", "=", NSEvent.ModifierFlags.command, UInt16(24), before + 1),
            ("-", "-", .command, UInt16(27), before),
            ("+", "=", [.command, .shift], UInt16(24), before + 1),
            ("0", "0", .command, UInt16(29), before),
            ("+", "+", .command, UInt16(24), before + 1),
            ("-", "-", [.command, .capsLock], UInt16(27), before)
        ] {
            let event = try key(characters, ignoring: ignoring, flags: flags, code: code, window: window)
            XCTAssertTrue(view.renderer.performKeyEquivalent(with: event), "Not handled: \(characters) \(flags)")
            XCTAssertEqual(view.renderer.font.pointSize, expected)
        }
        XCTAssertEqual(try view.driver.readScreenText(), text)
        XCTAssertEqual(view.driver.metadata.resetEpoch, epoch)
        XCTAssertEqual(output.userInputLease, lease)
        XCTAssertTrue(window.firstResponder === view.renderer)
    }

    func testFontShortcutsRefuseOtherModifiersForeignWindowAndUnfocusedView() throws {
        let (view, window) = try fixture()
        defer { window.contentView = nil }
        let before = view.renderer.font.pointSize
        for flags: NSEvent.ModifierFlags in [[], .control, [.command, .option], [.command, .control], [.command, .shift]] {
            XCTAssertFalse(view.renderer.performKeyEquivalent(with: try key("-", flags: flags, code: 27, window: window)))
            XCTAssertEqual(view.renderer.font.pointSize, before)
        }
        for text in ["=", "+"] {
            for flags: NSEvent.ModifierFlags in [[], .control, .option, [.command, .option], [.command, .control]] {
                XCTAssertFalse(view.renderer.performKeyEquivalent(with: try key(text, flags: flags, code: 24, window: window)))
                XCTAssertEqual(view.renderer.font.pointSize, before, "Ordinary text/control input must not zoom")
            }
        }
        let other = NSWindow(contentRect: view.frame, styleMask: [], backing: .buffered, defer: false)
        XCTAssertFalse(view.renderer.performKeyEquivalent(with: try key("=", code: 24, window: other)))
        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertFalse(view.renderer.performKeyEquivalent(with: try key("=", code: 24, window: window)))
        XCTAssertEqual(view.renderer.font.pointSize, before)
    }

    func testFontShortcutRemainsAvailableInScrollModeAndRefusesHiddenRenderer() throws {
        let (view, window) = try fixture()
        defer { window.contentView = nil }
        XCTAssertTrue(view.scrollModeController.enter())
        let before = view.renderer.font.pointSize
        XCTAssertTrue(view.renderer.performKeyEquivalent(with: try key("=", code: 24, window: window)))
        XCTAssertEqual(view.renderer.font.pointSize, before + 1)
        XCTAssertTrue(view.scrollModeController.isActive)
        view.scrollModeController.exit()
        view.renderer.isHidden = true
        XCTAssertFalse(view.renderer.performKeyEquivalent(with: try key("=", code: 24, window: window)))
        XCTAssertEqual(view.renderer.font.pointSize, before + 1)
    }

    func testInstalledMenuDispatchesZoomActionsToItsResolvedResponder() throws {
        let oldMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = oldMenu }
        let (view, window) = try fixture()
        defer { window.contentView = nil }
        let menu = try mainMenu()
        let viewMenu = try XCTUnwrap(menu.items.first { $0.submenu?.title == "View" }?.submenu)
        // Use our own resolved first responder without making an offscreen test
        // window key/activating it over a user's window. Matching/validation and
        // selector dispatch below are the actual production menu implementation.
        for item in viewMenu.items where item.action != nil { item.target = window.firstResponder }
        let before = view.renderer.font.pointSize
        XCTAssertTrue(AppMenuKeyEquivalents.perform(try key("=", code: 24, window: window), in: menu))
        XCTAssertEqual(view.renderer.font.pointSize, before + 1)
        XCTAssertTrue(AppMenuKeyEquivalents.perform(try key("-", code: 27, window: window), in: menu))
        XCTAssertEqual(view.renderer.font.pointSize, before)
    }
}
