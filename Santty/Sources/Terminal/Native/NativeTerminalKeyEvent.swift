import Foundation
import GhosttyVt

/// Platform-independent input contract. Physical identity is distinct from the
/// layout's text and unshifted codepoint; no terminal protocol is encoded here.
struct NativeTerminalKeyEvent {
    let keyCode: UInt16
    var key: GhosttyKey
    var text: String?
    var unshiftedCodepoint: UInt32
    var modifiers: GhosttyMods
    var consumedModifiers: GhosttyMods
    var action: GhosttyKeyAction
    var composing: Bool
    var optionAsAlt: Bool
    var logicalKey: GhosttyKey? = nil

    /// AppKit Option/AltGr composition is text, even when a program requests
    /// report-all without associated text. Match SwiftTerm's macOS policy;
    /// otherwise the composed glyph can be lost as an Alt+base-key chord.
    var isTextInput: Bool {
        text != nil && !optionAsAlt && modifiers & GhosttyMods(GHOSTTY_MODS_ALT) != 0
            && modifiers & GhosttyMods(GHOSTTY_MODS_CTRL | GHOSTTY_MODS_SUPER) == 0
    }

    var input: NativeTerminalInput {
        if isTextInput, let text { return .committedText(text) }
        return .key(self)
    }
}

enum NativeTerminalInput {
    case key(NativeTerminalKeyEvent)
    case committedText(String)
    case paste(String)
    case focus(Bool)
    case mouse(NativeMouseInput)
    case wheel(NativeProgramScroll)
}

struct NativeKeySnapshot {
    let keyCode: UInt16
    let text: String?
    let unmodifiedText: String?
    let modifiers: GhosttyMods
    var action: GhosttyKeyAction = GHOSTTY_KEY_ACTION_PRESS
    var composing = false
}

enum NativeOptionBehavior: CaseIterable {
    case text, bothMeta, leftMeta, rightMeta

    func isMeta(_ modifiers: GhosttyMods) -> Bool {
        guard modifiers & GhosttyMods(GHOSTTY_MODS_ALT) != 0 else { return false }
        let right = modifiers & GhosttyMods(GHOSTTY_MODS_ALT_SIDE) != 0
        switch self {
        case .text: return false
        case .bothMeta: return true
        case .leftMeta: return !right
        case .rightMeta: return right
        }
    }
}

enum NativeKeyNormalizer {
    static func printable(_ text: String?) -> String? {
        guard let text, !text.isEmpty, text.unicodeScalars.allSatisfy({
            $0.value >= 0x20 && !(0x7F...0x9F).contains($0.value) && !(0xF700...0xF8FF).contains($0.value)
        }) else { return nil }
        return text
    }

    static func normalize(_ source: NativeKeySnapshot, option: NativeOptionBehavior = .text) -> NativeTerminalKeyEvent {
        let key = keys[source.keyCode] ?? GHOSTTY_KEY_UNIDENTIFIED
        let text = printable(source.text)
        let asAlt = option.isMeta(source.modifiers)
        var consumed: GhosttyMods = 0
        if text != nil {
            consumed = source.modifiers & GhosttyMods(GHOSTTY_MODS_SHIFT)
            if !asAlt { consumed |= source.modifiers & GhosttyMods(GHOSTTY_MODS_ALT) }
        }
        let fallback = baseCodepoint(key)
        var base = printable(source.unmodifiedText)?.unicodeScalars.first?.value ?? fallback
        var logical: GhosttyKey?
        // AppKit's C0 translation is authoritative for Control character keys,
        // even on non-Latin/ISO layouts. Describe its logical identity without
        // ever passing that C0 byte back as encoder text. Keep physical identity
        // separately for lifecycle matching. See SwiftTerm's AppKit fixtures.
        if source.modifiers & GhosttyMods(GHOSTTY_MODS_CTRL) != 0,
           key.rawValue <= GHOSTTY_KEY_SLASH.rawValue || key == GHOSTTY_KEY_SPACE,
           let raw = source.text, raw.unicodeScalars.count == 1,
           let control = raw.unicodeScalars.first?.value, (1...31).contains(control) {
            if control <= 26 { base = control + 96 }
            else if base > 127 { base = control + 64 }
            logical = asciiKey(base)
        }
        return .init(keyCode: source.keyCode, key: key, text: text, unshiftedCodepoint: base,
            modifiers: source.modifiers, consumedModifiers: consumed, action: source.action,
            composing: source.composing, optionAsAlt: asAlt, logicalKey: logical)
    }

    private static func asciiKey(_ scalar: UInt32) -> GhosttyKey? {
        if (97...122).contains(scalar) { return GhosttyKey(rawValue: GHOSTTY_KEY_A.rawValue + scalar - 97) }
        if (48...57).contains(scalar) { return GhosttyKey(rawValue: GHOSTTY_KEY_DIGIT_0.rawValue + scalar - 48) }
        return [UInt32(32): GHOSTTY_KEY_SPACE, 45: GHOSTTY_KEY_MINUS, 47: GHOSTTY_KEY_SLASH,
                91: GHOSTTY_KEY_BRACKET_LEFT, 92: GHOSTTY_KEY_BACKSLASH, 93: GHOSTTY_KEY_BRACKET_RIGHT,
                94: GHOSTTY_KEY_DIGIT_6, 95: GHOSTTY_KEY_MINUS][scalar]
    }

    private static func baseCodepoint(_ key: GhosttyKey) -> UInt32 {
        if key.rawValue >= GHOSTTY_KEY_A.rawValue && key.rawValue <= GHOSTTY_KEY_Z.rawValue {
            return UInt32(97 + key.rawValue - GHOSTTY_KEY_A.rawValue)
        }
        return 0
    }

    // AppKit virtual key codes, not NSEvent function-key Unicode values.
    static let keys: [UInt16: GhosttyKey] = [
        0: GHOSTTY_KEY_A, 1: GHOSTTY_KEY_S, 2: GHOSTTY_KEY_D, 3: GHOSTTY_KEY_F,
        4: GHOSTTY_KEY_H, 5: GHOSTTY_KEY_G, 6: GHOSTTY_KEY_Z, 7: GHOSTTY_KEY_X,
        8: GHOSTTY_KEY_C, 9: GHOSTTY_KEY_V, 10: GHOSTTY_KEY_INTL_BACKSLASH, 11: GHOSTTY_KEY_B, 12: GHOSTTY_KEY_Q,
        13: GHOSTTY_KEY_W, 14: GHOSTTY_KEY_E, 15: GHOSTTY_KEY_R, 16: GHOSTTY_KEY_Y, 17: GHOSTTY_KEY_T,
        18: GHOSTTY_KEY_DIGIT_1, 19: GHOSTTY_KEY_DIGIT_2, 20: GHOSTTY_KEY_DIGIT_3,
        21: GHOSTTY_KEY_DIGIT_4, 22: GHOSTTY_KEY_DIGIT_6, 23: GHOSTTY_KEY_DIGIT_5,
        24: GHOSTTY_KEY_EQUAL, 25: GHOSTTY_KEY_DIGIT_9, 26: GHOSTTY_KEY_DIGIT_7,
        27: GHOSTTY_KEY_MINUS, 28: GHOSTTY_KEY_DIGIT_8, 29: GHOSTTY_KEY_DIGIT_0,
        30: GHOSTTY_KEY_BRACKET_RIGHT, 31: GHOSTTY_KEY_O, 32: GHOSTTY_KEY_U,
        33: GHOSTTY_KEY_BRACKET_LEFT, 34: GHOSTTY_KEY_I, 35: GHOSTTY_KEY_P,
        36: GHOSTTY_KEY_ENTER, 37: GHOSTTY_KEY_L, 38: GHOSTTY_KEY_J, 39: GHOSTTY_KEY_QUOTE,
        40: GHOSTTY_KEY_K, 41: GHOSTTY_KEY_SEMICOLON, 42: GHOSTTY_KEY_BACKSLASH,
        43: GHOSTTY_KEY_COMMA, 44: GHOSTTY_KEY_SLASH, 45: GHOSTTY_KEY_N, 46: GHOSTTY_KEY_M,
        47: GHOSTTY_KEY_PERIOD, 48: GHOSTTY_KEY_TAB, 49: GHOSTTY_KEY_SPACE,
        50: GHOSTTY_KEY_BACKQUOTE, 51: GHOSTTY_KEY_BACKSPACE, 53: GHOSTTY_KEY_ESCAPE,
        54: GHOSTTY_KEY_META_RIGHT, 55: GHOSTTY_KEY_META_LEFT, 56: GHOSTTY_KEY_SHIFT_LEFT,
        57: GHOSTTY_KEY_CAPS_LOCK, 58: GHOSTTY_KEY_ALT_LEFT, 59: GHOSTTY_KEY_CONTROL_LEFT,
        60: GHOSTTY_KEY_SHIFT_RIGHT, 61: GHOSTTY_KEY_ALT_RIGHT, 62: GHOSTTY_KEY_CONTROL_RIGHT,
        63: GHOSTTY_KEY_FN, 64: GHOSTTY_KEY_F17, 65: GHOSTTY_KEY_NUMPAD_DECIMAL,
        67: GHOSTTY_KEY_NUMPAD_MULTIPLY, 69: GHOSTTY_KEY_NUMPAD_ADD, 71: GHOSTTY_KEY_NUMPAD_CLEAR,
        75: GHOSTTY_KEY_NUMPAD_DIVIDE, 76: GHOSTTY_KEY_NUMPAD_ENTER, 78: GHOSTTY_KEY_NUMPAD_SUBTRACT,
        79: GHOSTTY_KEY_F18, 80: GHOSTTY_KEY_F19, 81: GHOSTTY_KEY_NUMPAD_EQUAL,
        82: GHOSTTY_KEY_NUMPAD_0, 83: GHOSTTY_KEY_NUMPAD_1, 84: GHOSTTY_KEY_NUMPAD_2,
        85: GHOSTTY_KEY_NUMPAD_3, 86: GHOSTTY_KEY_NUMPAD_4, 87: GHOSTTY_KEY_NUMPAD_5,
        88: GHOSTTY_KEY_NUMPAD_6, 89: GHOSTTY_KEY_NUMPAD_7, 91: GHOSTTY_KEY_NUMPAD_8,
        92: GHOSTTY_KEY_NUMPAD_9, 90: GHOSTTY_KEY_F20, 93: GHOSTTY_KEY_INTL_YEN,
        94: GHOSTTY_KEY_INTL_RO, 95: GHOSTTY_KEY_NUMPAD_COMMA,
        96: GHOSTTY_KEY_F5, 97: GHOSTTY_KEY_F6, 98: GHOSTTY_KEY_F7, 99: GHOSTTY_KEY_F3,
        100: GHOSTTY_KEY_F8, 101: GHOSTTY_KEY_F9, 103: GHOSTTY_KEY_F11,
        109: GHOSTTY_KEY_F10, 111: GHOSTTY_KEY_F12, 113: GHOSTTY_KEY_F15, 114: GHOSTTY_KEY_HELP,
        115: GHOSTTY_KEY_HOME, 116: GHOSTTY_KEY_PAGE_UP, 117: GHOSTTY_KEY_DELETE,
        118: GHOSTTY_KEY_F4, 119: GHOSTTY_KEY_END, 120: GHOSTTY_KEY_F2, 121: GHOSTTY_KEY_PAGE_DOWN,
        122: GHOSTTY_KEY_F1, 123: GHOSTTY_KEY_ARROW_LEFT, 124: GHOSTTY_KEY_ARROW_RIGHT,
        125: GHOSTTY_KEY_ARROW_DOWN, 126: GHOSTTY_KEY_ARROW_UP,
    ]
}

/// Release identity comes from the delivered press, not a new keyboard layout.
/// Clearing on focus/reconnect also suppresses orphan repeats and releases.
struct NativeKeySequence {
    private var pressed: [UInt16: (key: NativeTerminalKeyEvent, reportsRelease: Bool, isHostBinding: Bool)] = [:]

    func accepts(_ event: NativeTerminalKeyEvent, isHostBinding: Bool = false) -> Bool {
        guard event.action == GHOSTTY_KEY_ACTION_REPEAT else { return true }
        // A held legacy host binding must not become a physical Kitty repeat
        // (or vice versa) when the foreground program changes keyboard modes.
        guard let record = pressed[event.keyCode], record.isHostBinding == isHostBinding else { return false }
        let original = record.key
        return original.key == event.key && original.unshiftedCodepoint == event.unshiftedCodepoint
    }

    mutating func delivered(_ event: NativeTerminalKeyEvent, reportsRelease: Bool = true, isHostBinding: Bool = false) {
        if event.action == GHOSTTY_KEY_ACTION_PRESS { pressed[event.keyCode] = (event, reportsRelease, isHostBinding) }
    }

    mutating func release(_ current: NativeTerminalKeyEvent) -> NativeTerminalKeyEvent? {
        guard let record = pressed.removeValue(forKey: current.keyCode), record.reportsRelease else { return nil }
        var original = record.key
        original.action = GHOSTTY_KEY_ACTION_RELEASE
        original.modifiers = current.modifiers
        original.text = nil
        original.consumedModifiers = 0
        original.composing = false
        return original
    }

    mutating func reset() { pressed.removeAll() }
}
