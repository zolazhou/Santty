import GhosttyVt
import XCTest
@testable import SanttyTerminalLab

final class NativeKeyNormalizationTests: XCTestCase {
    private let shift = GhosttyMods(GHOSTTY_MODS_SHIFT)
    private let ctrl = GhosttyMods(GHOSTTY_MODS_CTRL)
    private let alt = GhosttyMods(GHOSTTY_MODS_ALT)

    func testEveryPrintableASCIIAndUnicodeTextPreservesSeparateIdentity() {
        let strings = (32...126).compactMap(UnicodeScalar.init).map(String.init) + ["你", "e\u{301}", "👩‍💻"]
        for text in strings {
            let result = NativeKeyNormalizer.normalize(.init(keyCode: 0, text: text,
                unmodifiedText: "a", modifiers: shift | alt | ctrl))
            XCTAssertEqual(result.key, GHOSTTY_KEY_A)
            XCTAssertEqual(result.text, text)
            XCTAssertEqual(result.unshiftedCodepoint, 97)
            XCTAssertEqual(result.modifiers, shift | alt | ctrl)
            XCTAssertEqual(result.consumedModifiers, shift | alt)
        }
    }

    func testControlAndFunctionTextCannotBecomeEncoderText() {
        for value in Array(0...31) + Array(127...159) + [0xF700, 0xF8FF] {
            let result = NativeKeyNormalizer.normalize(.init(keyCode: 8, text: UnicodeScalar(value).map(String.init),
                unmodifiedText: "c", modifiers: ctrl | shift))
            XCTAssertNil(result.text, "U+\(String(value, radix: 16))")
            XCTAssertEqual(result.consumedModifiers, 0)
            XCTAssertEqual(result.modifiers, ctrl | shift)
        }
    }

    func testOptionPoliciesRespectSidesAndNeverConsumeControl() {
        for policy in NativeOptionBehavior.allCases {
            for right in [false, true] {
                let mods = alt | ctrl | shift | (right ? GhosttyMods(GHOSTTY_MODS_ALT_SIDE) : 0)
                let event = NativeKeyNormalizer.normalize(.init(keyCode: 19, text: "@", unmodifiedText: "2", modifiers: mods), option: policy)
                let meta = policy == .bothMeta || policy == (right ? .rightMeta : .leftMeta)
                XCTAssertEqual(event.optionAsAlt, meta)
                XCTAssertEqual(event.consumedModifiers, shift | (meta ? 0 : alt))
                XCTAssertEqual(event.modifiers, mods)
            }
        }
    }

    func testKnownPhysicalKeyGroupsAndUnknownKeys() {
        for (code, key): (UInt16, GhosttyKey) in [
            (76, GHOSTTY_KEY_NUMPAD_ENTER), (83, GHOSTTY_KEY_NUMPAD_1), (81, GHOSTTY_KEY_NUMPAD_EQUAL),
            (64, GHOSTTY_KEY_F17), (90, GHOSTTY_KEY_F20), (60, GHOSTTY_KEY_SHIFT_RIGHT),
            (61, GHOSTTY_KEY_ALT_RIGHT), (65535, GHOSTTY_KEY_UNIDENTIFIED),
        ] {
            XCTAssertEqual(NativeKeyNormalizer.normalize(.init(keyCode: code, text: nil, unmodifiedText: nil, modifiers: 0)).key, key)
        }
    }

    func testReleaseUsesDeliveredPressAcrossLayoutAndModifierChanges() {
        var sequence = NativeKeySequence()
        let press = NativeKeyNormalizer.normalize(.init(keyCode: 41, text: ":", unmodifiedText: ";", modifiers: shift))
        sequence.delivered(press)
        let changedLayout = NativeKeyNormalizer.normalize(.init(keyCode: 41, text: "ö", unmodifiedText: "ö", modifiers: 0))
        let release = sequence.release(changedLayout)
        XCTAssertEqual(release?.key, GHOSTTY_KEY_SEMICOLON)
        XCTAssertEqual(release?.unshiftedCodepoint, 59)
        XCTAssertEqual(release?.modifiers, 0)
        XCTAssertNil(release?.text)
        XCTAssertEqual(release?.action, GHOSTTY_KEY_ACTION_RELEASE)
        XCTAssertNil(sequence.release(changedLayout))
    }

    func testResetSuppressesOrphanRepeatsAndReleases() {
        var sequence = NativeKeySequence()
        var key = NativeKeyNormalizer.normalize(.init(keyCode: 0, text: "a", unmodifiedText: "a", modifiers: 0))
        key.action = GHOSTTY_KEY_ACTION_REPEAT
        XCTAssertFalse(sequence.accepts(key))
        key.action = GHOSTTY_KEY_ACTION_PRESS
        sequence.delivered(key)
        key.action = GHOSTTY_KEY_ACTION_REPEAT
        XCTAssertTrue(sequence.accepts(key))
        var changedLayout = key
        changedLayout.unshiftedCodepoint = 1092
        XCTAssertFalse(sequence.accepts(changedLayout))
        sequence.reset()
        XCTAssertFalse(sequence.accepts(key))
        XCTAssertNil(sequence.release(key))
    }

    func testIMECommitIsNotPhysicalKeyOrBracketedPasteInReportAllMode() throws {
        let driver = try GhosttyVTDriver()
        driver.feed("\u{1b}[>31u\u{1b}[?2004h")
        for text in ["你好", "👩‍💻", "e\u{301}"] {
            XCTAssertEqual(try driver.encode(.committedText(text)), Data(text.utf8))
        }
        let preedit = NativeKeyNormalizer.normalize(.init(keyCode: 0, text: "a", unmodifiedText: "a", modifiers: 0, composing: true))
        XCTAssertTrue(try driver.encode(.key(preedit)).isEmpty)
    }

    func testControlUsesOSLayoutTranslationBeforePhysicalFallback() throws {
        let driver = try GhosttyVTDriver()
        for (code, base, byte): (UInt16, String, UInt8) in [(8, "j", 10), (33, "ü", 29), (10, "ㅊ", 3)] {
            let event = NativeKeyNormalizer.normalize(.init(keyCode: code, text: String(UnicodeScalar(byte)),
                unmodifiedText: base, modifiers: ctrl))
            XCTAssertEqual(try driver.encodeKey(event), Data([byte]), "physical=\(code), layout=\(base)")
        }
    }

    func testNonLatinControlTranslationKeepsOSControlIdentity() throws {
        let driver = try GhosttyVTDriver()
        for text in ["с", "ㅊ", "ذ", "ψ"] {
            let event = NativeKeyNormalizer.normalize(.init(keyCode: 8, text: "\u{3}", unmodifiedText: text, modifiers: ctrl))
            XCTAssertEqual(try driver.encodeKey(event), Data([3]), text)
        }
    }
}
