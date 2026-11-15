import AppKit
import GhosttyVt

extension NativeKeySnapshot {
    @MainActor
    static func modifierIsDown(_ event: NSEvent) -> Bool? {
        let flag: NSEvent.ModifierFlags
        let side: UInt
        let pair: UInt
        switch event.keyCode {
        case 56, 60: flag = .shift; side = event.keyCode == 56 ? 0x2 : 0x4; pair = 0x6
        case 59, 62: flag = .control; side = event.keyCode == 59 ? 0x1 : 0x2000; pair = 0x2001
        case 58, 61: flag = .option; side = event.keyCode == 58 ? 0x20 : 0x40; pair = 0x60
        case 55, 54: flag = .command; side = event.keyCode == 55 ? 0x8 : 0x10; pair = 0x18
        case 57: return event.modifierFlags.contains(.capsLock)
        case 63: return event.modifierFlags.contains(.function)
        default: return nil
        }
        let raw = event.modifierFlags.rawValue
        return raw & pair != 0 ? raw & side != 0 : event.modifierFlags.contains(flag)
    }

    /// Capture OS data once. Tests can supply the same fields without consulting
    /// or changing the machine's current keyboard layout/input source.
    @MainActor
    init(event: NSEvent, text: String? = nil, composing: Bool = false, action: GhosttyKeyAction? = nil) {
        var mods: GhosttyMods = 0
        for (flag, ghostty) in [(NSEvent.ModifierFlags.shift, GHOSTTY_MODS_SHIFT),
                                (.control, GHOSTTY_MODS_CTRL), (.option, GHOSTTY_MODS_ALT),
                                (.command, GHOSTTY_MODS_SUPER), (.capsLock, GHOSTTY_MODS_CAPS_LOCK)] {
            if event.modifierFlags.contains(flag) { mods |= GhosttyMods(ghostty) }
        }
        // Device-dependent side masks from macOS IOKit/hidsystem/ev_keymap.h.
        for (mask, side) in [(UInt(0x4), GHOSTTY_MODS_SHIFT_SIDE), (0x2000, GHOSTTY_MODS_CTRL_SIDE),
                             (0x40, GHOSTTY_MODS_ALT_SIDE), (0x10, GHOSTTY_MODS_SUPER_SIDE)] {
            if event.modifierFlags.rawValue & mask != 0 { mods |= GhosttyMods(side) }
        }
        // AppKit raises NSInternalInconsistencyException if character fields
        // are read from flagsChanged events. Modifier reports have no text.
        let hasCharacters = event.type == .keyDown || event.type == .keyUp
        self.init(keyCode: event.keyCode, text: text ?? (hasCharacters ? event.characters : nil),
            unmodifiedText: hasCharacters ? (event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers) : nil,
            modifiers: mods, action: action ?? (hasCharacters && event.isARepeat ? GHOSTTY_KEY_ACTION_REPEAT : GHOSTTY_KEY_ACTION_PRESS),
            composing: composing)
    }
}
