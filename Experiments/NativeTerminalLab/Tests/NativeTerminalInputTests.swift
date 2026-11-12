import AppKit
import GhosttyVt
import XCTest
@testable import SanttyTerminalLab

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
                          type: NSEvent.EventType = .keyDown) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: ignoringModifiers, isARepeat: false, keyCode: code))
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
