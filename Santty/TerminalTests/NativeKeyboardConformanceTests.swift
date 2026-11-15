// Keyboard vectors adapted from herdr-app terminal.rs (Apache-2.0),
// a547b16ccb5e8811b2dd8b3b901d31df8f05e55a.
// Swift port: explicit macOS snapshots and pinned libghostty-vt 1.0.0 bytes.
// See Licenses/Herdr-app.txt and INPUT-COMPATIBILITY.md.
import GhosttyVt
import XCTest
@testable import Santty

final class NativeKeyboardConformanceTests: XCTestCase {
    private struct Vector {
        let name: String
        let code: UInt16
        let text: String?
        let base: String?
        let mods: GhosttyMods
        let bytes: [String]
    }

    private static let shift = GhosttyMods(GHOSTTY_MODS_SHIFT)
    private static let ctrl = GhosttyMods(GHOSTTY_MODS_CTRL)
    private static let alt = GhosttyMods(GHOSTTY_MODS_ALT)
    private static let vectors: [Vector] = [
        .init(name: "a", code: 0, text: "a", base: "a", mods: 0, bytes: ["a", "a", "\u{1b}[97u"]),
        .init(name: "Shift A", code: 0, text: "A", base: "a", mods: shift, bytes: ["A", "A", "\u{1b}[97;2u"]),
        .init(name: "Shift ;", code: 41, text: ":", base: ";", mods: shift, bytes: [":", ":", "\u{1b}[59;2u"]),
        .init(name: "Shift 1", code: 18, text: "!", base: "1", mods: shift, bytes: ["!", "!", "\u{1b}[49;2u"]),
        .init(name: "Space", code: 49, text: " ", base: " ", mods: 0, bytes: [" ", " ", "\u{1b}[32u"]),
        .init(name: "Ctrl C", code: 8, text: "\u{3}", base: "c", mods: ctrl, bytes: ["\u{3}", "\u{1b}[99;5u", "\u{1b}[99;5u"]),
        .init(name: "Ctrl [", code: 33, text: "\u{1b}", base: "[", mods: ctrl, bytes: ["\u{1b}", "\u{1b}[91;5u", "\u{1b}[91;5u"]),
        .init(name: "Ctrl -", code: 27, text: "\u{1f}", base: "-", mods: ctrl, bytes: ["\u{1f}", "\u{1b}[45;5u", "\u{1b}[45;5u"]),
        .init(name: "Ctrl Shift -", code: 27, text: "\u{1f}", base: "-", mods: ctrl | shift, bytes: ["\u{1f}", "\u{1b}[45;6u", "\u{1b}[45;6u"]),
        .init(name: "Ctrl /", code: 44, text: "\u{1f}", base: "/", mods: ctrl, bytes: ["\u{1f}", "\u{1b}[47;5u", "\u{1b}[47;5u"]),
        .init(name: "Ctrl I", code: 34, text: "\t", base: "i", mods: ctrl, bytes: ["\t", "\u{1b}[105;5u", "\u{1b}[105;5u"]),
        .init(name: "Ctrl M", code: 46, text: "\r", base: "m", mods: ctrl, bytes: ["\r", "\u{1b}[109;5u", "\u{1b}[109;5u"]),
        .init(name: "Ctrl ]", code: 30, text: "\u{1d}", base: "]", mods: ctrl, bytes: ["\u{1d}", "\u{1b}[93;5u", "\u{1b}[93;5u"]),
        .init(name: "Ctrl backslash", code: 42, text: "\u{1c}", base: "\\", mods: ctrl, bytes: ["\u{1c}", "\u{1b}[92;5u", "\u{1b}[92;5u"]),
        .init(name: "Ctrl Space", code: 49, text: "\0", base: " ", mods: ctrl, bytes: ["\0", "\u{1b}[32;5u", "\u{1b}[32;5u"]),
        .init(name: "Option B text", code: 11, text: "∫", base: "b", mods: alt, bytes: ["∫", "∫", "\u{1b}[98;3u"]),
        .init(name: "Escape", code: 53, text: "\u{1b}", base: nil, mods: 0, bytes: ["\u{1b}", "\u{1b}[27u", "\u{1b}[27u"]),
        .init(name: "Enter", code: 36, text: "\r", base: nil, mods: 0, bytes: ["\r", "\r", "\u{1b}[13u"]),
        .init(name: "Shift Enter", code: 36, text: "\r", base: nil, mods: shift, bytes: ["\u{1b}[27;2;13~", "\u{1b}[13;2u", "\u{1b}[13;2u"]),
        .init(name: "Tab", code: 48, text: "\t", base: nil, mods: 0, bytes: ["\t", "\t", "\u{1b}[9u"]),
        .init(name: "Shift Tab", code: 48, text: "\u{19}", base: nil, mods: shift, bytes: ["\u{1b}[Z", "\u{1b}[9;2u", "\u{1b}[9;2u"]),
        .init(name: "Backspace", code: 51, text: "\u{7f}", base: nil, mods: 0, bytes: ["\u{7f}", "\u{7f}", "\u{1b}[127u"]),
        .init(name: "Up", code: 126, text: "\u{f700}", base: nil, mods: 0, bytes: ["\u{1b}[A", "\u{1b}[A", "\u{1b}[A"]),
        .init(name: "Ctrl Left", code: 123, text: nil, base: nil, mods: ctrl, bytes: ["\u{1b}[1;5D", "\u{1b}[1;5D", "\u{1b}[1;5D"]),
        .init(name: "F1", code: 122, text: nil, base: nil, mods: 0, bytes: ["\u{1b}OP", "\u{1b}[P", "\u{1b}[P"]),
        .init(name: "F5", code: 96, text: nil, base: nil, mods: 0, bytes: ["\u{1b}[15~", "\u{1b}[15~", "\u{1b}[15~"]),
    ]

    private func check(mode: Int) throws {
        for vector in Self.vectors {
            let driver = try GhosttyVTDriver()
            if mode > 0 { driver.feed("\u{1b}[>\(mode == 1 ? 1 : 9)u") }
            let key = NativeKeyNormalizer.normalize(.init(keyCode: vector.code, text: vector.text,
                unmodifiedText: vector.base, modifiers: vector.mods))
            XCTAssertEqual(try driver.encodeKey(key), Data(vector.bytes[mode].utf8), "\(vector.name), mode=\(mode)")
        }
    }

    func testHerdrLegacyVectors() throws { try check(mode: 0) }
    func testHerdrKittyDisambiguationVectors() throws { try check(mode: 1) }
    func testHerdrKittyReportAllVectors() throws { try check(mode: 2) }

    func testSideSpecificOptionMetaPoliciesEncodeTextOrShortcut() throws {
        for policy in NativeOptionBehavior.allCases {
            for right in [false, true] {
                for kitty in [false, true] {
                    let driver = try GhosttyVTDriver()
                    if kitty { driver.feed("\u{1b}[>1u") }
                    let meta = policy == .bothMeta || policy == (right ? .rightMeta : .leftMeta)
                    let mods = Self.alt | (right ? GhosttyMods(GHOSTTY_MODS_ALT_SIDE) : 0)
                    let event = NativeKeyNormalizer.normalize(.init(keyCode: 11, text: meta ? "b" : "∫",
                        unmodifiedText: "b", modifiers: mods), option: policy)
                    let expected = meta ? (kitty ? "\u{1b}[98;3u" : "\u{1b}b") : "∫"
                    XCTAssertEqual(try driver.encode(event.input), Data(expected.utf8))
                }
            }
        }
    }

    func testEveryKittyFlagCombinationTracksRepeatAndRelease() throws {
        for flags in 1...31 {
            let driver = try GhosttyVTDriver()
            driver.feed("\u{1b}[>\(flags)u")
            XCTAssertEqual(try driver.keyboardModes.kittyFlags, UInt8(flags))
            var key = NativeKeyNormalizer.normalize(.init(keyCode: 8, text: "\u{3}", unmodifiedText: "c", modifiers: Self.ctrl))
            XCTAssertEqual(try driver.encodeKey(key), Data("\u{1b}[99;5u".utf8))
            key.action = GHOSTTY_KEY_ACTION_REPEAT
            XCTAssertEqual(try driver.encodeKey(key), Data("\u{1b}[99;5\(flags & 2 != 0 ? ":2" : "")u".utf8))
            key.action = GHOSTTY_KEY_ACTION_RELEASE
            XCTAssertEqual(try driver.encodeKey(key), flags & 2 != 0 ? Data("\u{1b}[99;5:3u".utf8) : Data())
        }
    }

    func testPasteFramingSafetyAndWindowsNewlines() throws {
        let driver = try GhosttyVTDriver()
        XCTAssertEqual(try driver.encode(.paste("a\r\nb\nc")), Data("a\rb\rc".utf8))
        driver.feed("\u{1b}[?2004h")
        XCTAssertEqual(try driver.encode(.paste("a\r\nb")), Data("\u{1b}[200~a\r\nb\u{1b}[201~".utf8))
        XCTAssertEqual(try driver.encode(.paste("a\0b\u{1b}[201~c\u{7f}d")),
                       Data("\u{1b}[200~a b [201~c d\u{1b}[201~".utf8))
        driver.feed("\u{1b}[?2004l")
        XCTAssertEqual(try driver.encode(.paste("x\ny")), Data("x\ry".utf8))
    }

    func testModePushPopAndEscapeRemainSeparate() throws {
        let driver = try GhosttyVTDriver()
        let escape = NativeKeyNormalizer.normalize(.init(keyCode: 53, text: "\u{1b}", unmodifiedText: nil, modifiers: 0))
        let a = NativeKeyNormalizer.normalize(.init(keyCode: 0, text: "a", unmodifiedText: "a", modifiers: 0))
        for (setup, first, second) in [
            ("", "\u{1b}", "a"), ("\u{1b}[>9u", "\u{1b}[27u", "\u{1b}[97u"),
            ("\u{1b}[>0u", "\u{1b}", "a"), ("\u{1b}[<u", "\u{1b}[27u", "\u{1b}[97u"),
            ("\u{1b}[<u", "\u{1b}", "a"),
        ] {
            driver.feed(setup)
            XCTAssertEqual(try driver.encodeKey(escape) + driver.encodeKey(a), Data((first + second).utf8))
        }
    }

    func testApplicationCursorAndKeypad() throws {
        let driver = try GhosttyVTDriver()
        let up = NativeKeyNormalizer.normalize(.init(keyCode: 126, text: nil, unmodifiedText: nil, modifiers: 0))
        let one = NativeKeyNormalizer.normalize(.init(keyCode: 83, text: "1", unmodifiedText: "1", modifiers: 0))
        XCTAssertEqual(try driver.encodeKey(up), Data("\u{1b}[A".utf8))
        XCTAssertEqual(try driver.encodeKey(one), Data("1".utf8))
        driver.feed("\u{1b}[?1h\u{1b}=")
        XCTAssertTrue(try driver.keyboardModes.applicationKeypad, "VT must accept the keypad mode request")
        XCTAssertTrue(try driver.keyboardModes.numLockOverridesKeypad, "VT defaults to Num Lock overriding application keypad")
        XCTAssertEqual(try driver.encodeKey(up), Data("\u{1b}OA".utf8))
        XCTAssertEqual(try driver.encodeKey(one), Data("1".utf8))
        driver.feed("\u{1b}[?1035l")
        XCTAssertFalse(try driver.keyboardModes.numLockOverridesKeypad)
        XCTAssertEqual(try driver.encodeKey(one), Data("\u{1b}Oq".utf8))
    }

    func testModifyOtherKeysControlAliasTransitions() throws {
        let driver = try GhosttyVTDriver()
        let key = NativeKeyNormalizer.normalize(.init(keyCode: 34, text: "\t", unmodifiedText: "i", modifiers: Self.ctrl))
        for (setup, bytes) in [("", "\t"), ("\u{1b}[>4;2m", "\u{1b}[27;5;105~"),
                               ("\u{1b}[>4;0m", "\t"), ("\u{1b}[>1u", "\u{1b}[105;5u")] {
            driver.feed(setup)
            XCTAssertEqual(try driver.encodeKey(key), Data(bytes.utf8))
        }
    }
}
