import AppKit
import GhosttyVt
import XCTest
@testable import Santty

@MainActor
final class NativeTerminalInputTests: XCTestCase {
    private func input(driver: GhosttyVTDriver? = nil) throws -> (NativeTerminalInputView, InputBytes) {
        let bytes = InputBytes()
        let view = NativeTerminalInputView(frame: NSRect(x: 0, y: 0, width: 640, height: 240))
        let output = NativeTerminalOutput(driver: try driver ?? GhosttyVTDriver()) { _ in }
        output.bind(writer: { bytes.append($0) })
        output.setInputEnabled(true)
        view.output = output
        view.inputEnabled = true
        return (view, bytes)
    }

    private func keyEvent(code: UInt16, characters: String, ignoringModifiers: String,
                          modifiers: NSEvent.ModifierFlags = .control,
                          type: NSEvent.EventType = .keyDown, repeatKey: Bool = false,
                          window: NSWindow? = nil) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: window?.windowNumber ?? 0, context: nil, characters: characters,
            charactersIgnoringModifiers: ignoringModifiers, isARepeat: repeatKey, keyCode: code))
    }

    func testShiftedPrintablePunctuationIsTextUnderKittyDisambiguation() throws {
        for (code, text): (UInt16, String) in [(41, ":"), (44, "?"), (18, "!"), (24, "+"), (0, "A")] {
            let driver = try GhosttyVTDriver()
            driver.feed("\u{1b}[>1u") // the disambiguation mode used by Neovim
            let (view, bytes) = try input(driver: driver)
            view.keyDown(with: try keyEvent(code: code, characters: text,
                ignoringModifiers: text, modifiers: .shift))
            XCTAssertEqual(bytes.data, Data(text.utf8), "Shift already produced \(text); it must not become another shortcut")
        }
    }

    func testPrintableShiftIsConsumedOnKittyPressAndRelease() throws {
        let driver = try GhosttyVTDriver()
        driver.feed("\u{1b}[>11u") // disambiguate + report events + report all
        let (view, bytes) = try input(driver: driver)
        let modifiers = GhosttyMods(GHOSTTY_MODS_SHIFT)
        let press = try driver.encodeKey(GHOSTTY_KEY_SEMICOLON, text: ":", modifiers: modifiers,
            unshiftedCodepoint: 59, consumedModifiers: modifiers)
        let release = try driver.encodeKey(GHOSTTY_KEY_SEMICOLON, text: ":", modifiers: modifiers,
            action: GHOSTTY_KEY_ACTION_RELEASE, unshiftedCodepoint: 59, consumedModifiers: modifiers)
        view.keyDown(with: try keyEvent(code: 41, characters: ":", ignoringModifiers: ":", modifiers: .shift))
        view.keyUp(with: try keyEvent(code: 41, characters: ":", ignoringModifiers: ":", modifiers: .shift, type: .keyUp))
        XCTAssertFalse(press.isEmpty)
        XCTAssertFalse(release.isEmpty)
        XCTAssertEqual(bytes.data, press + release)
    }

    func testShiftRemainsOnFunctionKeysWithoutPrintableText() throws {
        for (code, text, key): (UInt16, String, GhosttyKey) in [
            (126, "\u{F700}", GHOSTTY_KEY_ARROW_UP), (48, "\u{19}", GHOSTTY_KEY_TAB),
        ] {
            let driver = try GhosttyVTDriver()
            driver.feed("\u{1b}[>1u")
            let (view, bytes) = try input(driver: driver)
            let expected = try driver.encodeKey(key, modifiers: GhosttyMods(GHOSTTY_MODS_SHIFT))
            view.keyDown(with: try keyEvent(code: code, characters: text, ignoringModifiers: text, modifiers: .shift))
            XCTAssertFalse(expected.isEmpty)
            XCTAssertEqual(bytes.data, expected)
        }
    }

    func testOptionAsTextConsumesOnlyTheModifiersThatProducedPrintableText() throws {
        for (code, text, flags): (UInt16, String, NSEvent.ModifierFlags) in [
            (1, "ß", .option), (19, "@", [.option, .shift]),
        ] {
            let driver = try GhosttyVTDriver()
            driver.feed("\u{1b}[>1u")
            let (view, bytes) = try input(driver: driver)
            view.keyDown(with: try keyEvent(code: code, characters: text, ignoringModifiers: text, modifiers: flags))
            XCTAssertEqual(bytes.data, Data(text.utf8))
        }
    }

    func testOptionCompositionIsTextAndHasNoOrphanReleaseInReportAllModes() throws {
        for flags in [9, 11, 31] {
            let driver = try GhosttyVTDriver()
            driver.feed("\u{1b}[>\(flags)u")
            let (view, bytes) = try input(driver: driver)
            view.keyDown(with: try keyEvent(code: 1, characters: "ß", ignoringModifiers: "s", modifiers: .option))
            view.keyUp(with: try keyEvent(code: 1, characters: "ß", ignoringModifiers: "s", modifiers: .option, type: .keyUp))
            XCTAssertEqual(bytes.data, Data("ß".utf8))
        }
    }

    func testMacCommandEditingBindingsSendLiteralShellActionsInEveryKeyboardMode() throws {
        for mode in ["", "\u{1b}[?1h", "\u{1b}[>4;2m", "\u{1b}[>1u", "\u{1b}[>11u"] {
            for (code, text, expected): (UInt16, String, String) in [
                (51, "\u{7f}", "\u{15}"), (117, "\u{F728}", "\u{b}"),
                (123, "\u{F702}", "\u{1}"), (124, "\u{F703}", "\u{5}"),
            ] {
                let driver = try GhosttyVTDriver()
                driver.feed(mode)
                let (view, bytes) = try input(driver: driver)
                let event = try keyEvent(code: code, characters: text, ignoringModifiers: text, modifiers: .command)
                view.keyDown(with: event)
                view.keyUp(with: try keyEvent(code: code, characters: text, ignoringModifiers: text,
                    modifiers: [], type: .keyUp))
                XCTAssertEqual(bytes.data, Data(expected.utf8), "Cmd+keyCode \(code), mode \(mode.debugDescription)")
            }
        }
    }

    func testMacOptionWordEditingBindingsInLegacyModeRegardlessOfTextPolicy() throws {
        for policy in NativeOptionBehavior.allCases {
            for (code, text, expected): (UInt16, String, String) in [
                (123, "\u{F702}", "\u{1b}b"), (124, "\u{F703}", "\u{1b}f"),
                (51, "\u{7f}", "\u{1b}\u{7f}"), (117, "\u{F728}", "\u{1b}d"),
            ] {
                let (view, bytes) = try input()
                view.optionBehavior = policy
                view.keyDown(with: try keyEvent(code: code, characters: text, ignoringModifiers: text, modifiers: .option))
                view.keyUp(with: try keyEvent(code: code, characters: text, ignoringModifiers: text,
                    modifiers: [], type: .keyUp))
                XCTAssertEqual(bytes.data, Data(expected.utf8), "Option+keyCode \(code), policy \(policy)")
            }
        }
    }

    func testOptionEditingKeepsPhysicalKeysAndReleasesUnderKitty() throws {
        for flags in [1, 9, 11, 31] {
            for policy in NativeOptionBehavior.allCases {
                for (code, text, key): (UInt16, String, GhosttyKey) in [
                    (123, "\u{F702}", GHOSTTY_KEY_ARROW_LEFT), (124, "\u{F703}", GHOSTTY_KEY_ARROW_RIGHT),
                    (51, "\u{7f}", GHOSTTY_KEY_BACKSPACE), (117, "\u{F728}", GHOSTTY_KEY_DELETE),
                ] {
                    let driver = try GhosttyVTDriver()
                    driver.feed("\u{1b}[>\(flags)u")
                    let (view, bytes) = try input(driver: driver)
                    view.optionBehavior = policy
                    let alt = GhosttyMods(GHOSTTY_MODS_ALT)
                    let expectedPress = try driver.encodeKey(key, modifiers: alt, optionAsAlt: policy.isMeta(alt))
                    let expectedRelease = try driver.encodeKey(key, modifiers: alt,
                        action: GHOSTTY_KEY_ACTION_RELEASE, optionAsAlt: policy.isMeta(alt))
                    view.keyDown(with: try keyEvent(code: code, characters: text, ignoringModifiers: text, modifiers: .option))
                    view.keyUp(with: try keyEvent(code: code, characters: text, ignoringModifiers: text,
                        modifiers: .option, type: .keyUp))
                    XCTAssertFalse(expectedPress.isEmpty)
                    XCTAssertEqual(bytes.data, expectedPress + expectedRelease, "flags=\(flags), policy=\(policy), keyCode=\(code)")
                }
            }
        }
    }

    func testCommandEditingKeyEquivalentRequiresThisWindowAndResponder() throws {
        let (view, bytes) = try input()
        let window = NSWindow(contentRect: view.frame, styleMask: [], backing: .buffered, defer: false)
        let other = NSWindow(contentRect: view.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.contentView = nil }
        XCTAssertTrue(window.makeFirstResponder(view))
        let event = try keyEvent(code: 51, characters: "\u{7f}", ignoringModifiers: "\u{7f}",
            modifiers: [.command, .capsLock], window: window)
        XCTAssertFalse(view.performKeyEquivalent(with: try keyEvent(code: 51, characters: "\u{7f}",
            ignoringModifiers: "\u{7f}", modifiers: .command, window: other)))
        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertFalse(view.performKeyEquivalent(with: event))
        XCTAssertTrue(window.makeFirstResponder(view))
        view.isHidden = true
        XCTAssertFalse(view.performKeyEquivalent(with: event))
        view.isHidden = false
        XCTAssertTrue(window.makeFirstResponder(view))
        XCTAssertTrue(bytes.data.isEmpty)
        var activity = 0
        view.onInputActivity = { activity += 1 }
        XCTAssertTrue(view.performKeyEquivalent(with: event))
        XCTAssertEqual(bytes.data, Data([0x15]))
        XCTAssertEqual(activity, 1)
        XCTAssertTrue(window.firstResponder === view, "responder=\(String(describing: window.firstResponder)), window=\(String(describing: view.window))")
    }

    func testEditingBindingsRepeatButDoNotReplayAfterResetOrReconnect() throws {
        for modifiers: NSEvent.ModifierFlags in [.command, .option] {
            let (view, bytes) = try input()
            let press = try keyEvent(code: 51, characters: "\u{7f}", ignoringModifiers: "\u{7f}", modifiers: modifiers)
            let repeated = try keyEvent(code: 51, characters: "\u{7f}", ignoringModifiers: "\u{7f}",
                modifiers: modifiers, repeatKey: true)
            let expected = modifiers == .command ? Data([0x15]) : Data([0x1b, 0x7f])
            view.keyDown(with: repeated)
            XCTAssertTrue(bytes.data.isEmpty, "orphan repeat")
            view.keyDown(with: press)
            view.keyDown(with: repeated)
            XCTAssertEqual(bytes.data, expected + expected)
            view.resetInputState()
            view.keyDown(with: repeated)
            view.inputEnabled = false
            view.keyDown(with: press)
            view.inputEnabled = true
            view.keyDown(with: repeated)
            XCTAssertEqual(bytes.data, expected + expected)
            view.output?.setInputEnabled(false)
            view.keyDown(with: press)
            view.output?.setInputEnabled(true)
            view.keyDown(with: repeated)
            XCTAssertEqual(bytes.data, expected + expected, "refused press must not authorize a repeat")
            view.keyDown(with: press)
            XCTAssertEqual(bytes.data, expected + expected + expected)
        }
    }

    func testHeldOptionBindingCannotBecomeAnOrphanKittyRepeatOrViceVersa() throws {
        for startsInKitty in [false, true] {
            let driver = try GhosttyVTDriver()
            if startsInKitty { driver.feed("\u{1b}[>11u") }
            let (view, bytes) = try input(driver: driver)
            let press = try keyEvent(code: 123, characters: "\u{F702}", ignoringModifiers: "\u{F702}", modifiers: .option)
            let repeated = try keyEvent(code: 123, characters: "\u{F702}", ignoringModifiers: "\u{F702}",
                modifiers: .option, repeatKey: true)
            view.keyDown(with: press)
            let before = bytes.data
            driver.feed(startsInKitty ? "\u{1b}[<u" : "\u{1b}[>11u")
            view.keyDown(with: repeated)
            XCTAssertEqual(bytes.data, before, "a host binding and a physical report must not share repeat admission")
            view.keyDown(with: press)
            XCTAssertGreaterThan(bytes.data.count, before.count, "a fresh press resumes input")
        }
    }

    func testEditingBindingsDoNotDeleteTerminalInputDuringPreedit() throws {
        for modifiers: NSEvent.ModifierFlags in [.command, .option] {
            for code: UInt16 in [51, 117, 123, 124] {
                let (view, bytes) = try input()
                view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                    replacementRange: NSRange(location: NSNotFound, length: 0))
                view.keyDown(with: try keyEvent(code: code, characters: "\u{7f}", ignoringModifiers: "\u{7f}",
                    modifiers: modifiers))
                XCTAssertTrue(bytes.data.isEmpty, "preedit owns keyCode=\(code), modifiers=\(modifiers)")
            }
        }
    }

    func testOtherCommandShortcutsAndAdditionalModifiersAreNotEditingBindings() throws {
        let (view, bytes) = try input()
        for (code, text): (UInt16, String) in [(12, "q"), (13, "w"), (17, "t"), (3, "f"), (40, "k")] {
            let event = try keyEvent(code: code, characters: text, ignoringModifiers: text, modifiers: .command)
            XCTAssertFalse(view.performKeyEquivalent(with: event))
            view.keyDown(with: event)
        }
        for modifiers: NSEvent.ModifierFlags in [[.command, .option], [.command, .control], [.command, .shift]] {
            let event = try keyEvent(code: 51, characters: "\u{7f}", ignoringModifiers: "\u{7f}", modifiers: modifiers)
            view.keyDown(with: event)
        }
        XCTAssertTrue(bytes.data.isEmpty)
    }

    func testUnmodifiedNavigationAndDeletionKeepTerminalSequences() throws {
        for (code, text, expected): (UInt16, String, String) in [
            (51, "\u{7f}", "\u{7f}"), (117, "\u{F728}", "\u{1b}[3~"),
            (115, "\u{F729}", "\u{1b}[H"), (119, "\u{F72B}", "\u{1b}[F"),
            (116, "\u{F72C}", "\u{1b}[5~"), (121, "\u{F72D}", "\u{1b}[6~"),
        ] {
            let (view, bytes) = try input()
            view.keyDown(with: try keyEvent(code: code, characters: text, ignoringModifiers: text, modifiers: []))
            XCTAssertEqual(bytes.data, Data(expected.utf8), "keyCode \(code)")
        }
    }

    func testControlShortcutsThroughAppKitKeyDownSendExactlyOneControlByte() throws {
        for (code, letter, byte): (UInt16, String, UInt8) in [
            (8, "c", 3), (2, "d", 4), (6, "z", 26), (0, "a", 1),
            (14, "e", 5), (32, "u", 21), (37, "l", 12), (49, " ", 0),
            (4, "h", 8), (34, "i", 9), (38, "j", 10), (46, "m", 13),
            (33, "[", 27), (42, "\\", 28), (30, "]", 29), (22, "6", 30),
            (19, "2", 0), (12, "q", 17), (13, "w", 23), (15, "r", 18), (27, "-", 31),
        ] {
            let driver = try GhosttyVTDriver()
            driver.feed("\u{1b}[>0u\u{1b}[>4;0m") // explicit legacy keyboard modes
            let (view, bytes) = try input(driver: driver)
            let control = String(UnicodeScalar(byte))
            let event = try keyEvent(code: code, characters: control, ignoringModifiers: control)
            XCTAssertFalse(view.performKeyEquivalent(with: event))
            view.keyDown(with: event)
            XCTAssertEqual(Array(bytes.data), [byte], "Ctrl+\(letter), layout=\(String(describing: event.characters(byApplyingModifiers: [])?.unicodeScalars.map(\.value)))")
        }
    }

    func testControlCInRestoredKeyboardModesUsesLogicalKeyNotControlText() throws {
        for mode in ["\u{1b}[>4;2m", "\u{1b}[>1u", "\u{1b}[>9u"] {
            let driver = try GhosttyVTDriver()
            driver.feed(mode)
            let (view, bytes) = try input(driver: driver)
            // Per the C API, C0 is represented by key + modifiers, not text.
            // Ghostty owns whether the live protocol uses ETX or CSI-u.
            let expected = try driver.encodeKey(GHOSTTY_KEY_C,
                modifiers: GhosttyMods(GHOSTTY_MODS_CTRL), unshiftedCodepoint: 99)
            let event = try keyEvent(code: 8, characters: "\u{3}", ignoringModifiers: "\u{3}")
            view.keyDown(with: event)
            XCTAssertFalse(expected.isEmpty)
            XCTAssertEqual(bytes.data, expected)
        }
    }

    func testLegacyAliasesPreserveNegotiatedKittyAndModifyOtherKeysChords() throws {
        for mode in ["\u{1b}[>4;2m", "\u{1b}[>9u"] {
            for (code, key, text, byte): (UInt16, GhosttyKey, String, UInt8) in [
                (34, GHOSTTY_KEY_I, "i", 9), (46, GHOSTTY_KEY_M, "m", 13),
                (33, GHOSTTY_KEY_BRACKET_LEFT, "[", 27), (27, GHOSTTY_KEY_MINUS, "-", 31),
            ] {
                let driver = try GhosttyVTDriver()
                driver.feed(mode)
                let (view, bytes) = try input(driver: driver)
                let expected = try driver.encodeKey(key, text: text,
                    modifiers: GhosttyMods(GHOSTTY_MODS_CTRL),
                    unshiftedCodepoint: text.unicodeScalars.first?.value ?? 0)
                let control = String(UnicodeScalar(byte))
                view.keyDown(with: try keyEvent(code: code, characters: control, ignoringModifiers: control))
                XCTAssertFalse(expected.isEmpty)
                XCTAssertEqual(bytes.data, expected, "negotiated Ctrl+\(text) must not become a legacy alias")
            }
        }
    }

    func testShiftControlKeyPreservesModifiersUnderKittyKeyboardProtocol() throws {
        let driver = try GhosttyVTDriver()
        driver.feed("\u{1b}[>9u") // disambiguate + report all keys
        let (view, bytes) = try input(driver: driver)
        // Real macOS Control events retain C0 translation even in
        // charactersIgnoringModifiers; those bytes are not encoder text.
        let event = try keyEvent(code: 8, characters: "\u{3}", ignoringModifiers: "\u{3}",
                                 modifiers: [.control, .shift])
        view.keyDown(with: event)
        XCTAssertEqual(bytes.data, Data("\u{1b}[99;6u".utf8))
    }

    func testEmptyMarkedTextEndsCompositionAndRemovesOverlay() throws {
        let (view, bytes) = try input()
        let baseline = view.subviews.count
        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertGreaterThan(view.subviews.count, baseline)
        view.setMarkedText("", selectedRange: NSRange(location: 0, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(view.hasMarkedText())
        XCTAssertEqual(view.subviews.count, baseline)
        XCTAssertTrue(bytes.data.isEmpty)
    }

    func testPreeditDeleteDoesNotEscapeToTerminalAndCommitWorksInReportAll() throws {
        for deletion in ["\u{8}", "\u{7f}"] {
            let driver = try GhosttyVTDriver()
            driver.feed("\u{1b}[>31u")
            let (view, bytes) = try input(driver: driver)
            view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
            view.insertText(deletion, replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertTrue(bytes.data.isEmpty)
            view.insertText("你好👩‍💻", replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertEqual(bytes.data, Data("你好👩‍💻".utf8))
        }
    }

    func testModifierReportingAndShiftReleasedBeforeTextKey() throws {
        let driver = try GhosttyVTDriver()
        driver.feed("\u{1b}[>11u")
        let (view, bytes) = try input(driver: driver)
        let down = try keyEvent(code: 56, characters: "", ignoringModifiers: "", modifiers: .shift, type: .flagsChanged)
        view.flagsChanged(with: down)
        view.keyDown(with: try keyEvent(code: 0, characters: "A", ignoringModifiers: "A", modifiers: .shift))
        view.flagsChanged(with: try keyEvent(code: 56, characters: "", ignoringModifiers: "", modifiers: [], type: .flagsChanged))
        view.keyUp(with: try keyEvent(code: 0, characters: "a", ignoringModifiers: "a", modifiers: [], type: .keyUp))
        XCTAssertEqual(bytes.data, Data("\u{1b}[57441;2u\u{1b}[97;2u\u{1b}[57441;1:3u\u{1b}[97;1:3u".utf8))
    }

    func testFocusLossDropsPendingReleasesAndComposition() throws {
        let driver = try GhosttyVTDriver()
        driver.feed("\u{1b}[>11u")
        let (view, bytes) = try input(driver: driver)
        view.keyDown(with: try keyEvent(code: 0, characters: "a", ignoringModifiers: "a", modifiers: []))
        let before = bytes.data
        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.resignFirstResponder())
        view.keyUp(with: try keyEvent(code: 0, characters: "a", ignoringModifiers: "a", modifiers: [], type: .keyUp))
        XCTAssertFalse(view.hasMarkedText())
        XCTAssertEqual(bytes.data, before)
    }

    func testPreeditDoesNotSendUntilCommitAndOfflineTextDoesNotReplay() throws {
        let (view, bytes) = try input()
        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertTrue(bytes.data.isEmpty)
        view.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(view.hasMarkedText())
        XCTAssertEqual(String(decoding: bytes.data, as: UTF8.self), "你")
        view.inputEnabled = false
        view.insertText("must-not-replay", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.inputEnabled = true
        view.insertText("好", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(String(decoding: bytes.data, as: UTF8.self), "你好")
    }

    func testDisablingInputClearsSessionFocusWithoutWaitingForAWindowEvent() throws {
        let (view, _) = try input()
        var changes: [Bool] = []
        view.onFocusChange = { changes.append($0) }
        view.hasFocus = true
        view.inputEnabled = false
        XCTAssertFalse(view.hasFocus)
        XCTAssertEqual(changes, [false])
    }

    func testCompositionCancelAndCandidateRectangleFollowActualViewCoordinates() throws {
        let (view, bytes) = try input()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 240),
                              styleMask: [], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.contentView = nil }
        view.cursorCell = (column: 4, row: 2)
        let expected = window.convertToScreen(view.convert(view.rect(column: 4, row: 2), to: nil))
        XCTAssertEqual(view.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil), expected)
        view.setMarkedText("cancel", selectedRange: NSRange(location: 6, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        view.unmarkText()
        XCTAssertFalse(view.hasMarkedText())
        XCTAssertTrue(bytes.data.isEmpty)
    }

    func testHiddenLiveViewKeepsParsingWithoutConvertingOrDrawingRows() throws {
        let driver = try GhosttyVTDriver()
        let view = NativeTerminalScrollView(driver: driver, frame: NSRect(x: 0, y: 0, width: 640, height: 240))
        view.refresh(resizeTerminal: true)
        let output = NativeTerminalOutput(driver: driver) { [weak view] reset in
            view?.parsedOutput(reset: reset)
        }
        view.renderer.output = output
        let converted = view.source.convertedRows
        output.receive(Data("background".utf8))
        XCTAssertTrue(output.waitForPendingOutput())
        view.parsedOutput(reset: false)
        XCTAssertTrue(view.hasPendingOutput)
        XCTAssertEqual(view.source.convertedRows, converted)
        XCTAssertEqual(try driver.snapshot(topRow: 0).rows[0]?.cells[0].text, "b")
    }
}

private final class InputBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ data: Data) { lock.withLock { bytes.append(data) } }
    var data: Data { lock.withLock { bytes } }
}
