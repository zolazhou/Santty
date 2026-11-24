import GhosttyVt

/// Encoding adapter only. The production CLI router must still own grants,
/// retry IDs and pane identity. Never expose this as a new mutation route.
enum NativeTerminalNamedKey {
    static func event(_ key: CLIKey) throws -> NativeTerminalKeyEvent {
        let names: [String:GhosttyKey] = ["enter":GHOSTTY_KEY_ENTER,"tab":GHOSTTY_KEY_TAB,
            "escape":GHOSTTY_KEY_ESCAPE,"backspace":GHOSTTY_KEY_BACKSPACE,"delete":GHOSTTY_KEY_DELETE,
            "home":GHOSTTY_KEY_HOME,"end":GHOSTTY_KEY_END,"pageup":GHOSTTY_KEY_PAGE_UP,"pagedown":GHOSTTY_KEY_PAGE_DOWN,
            "left":GHOSTTY_KEY_ARROW_LEFT,"right":GHOSTTY_KEY_ARROW_RIGHT,"up":GHOSTTY_KEY_ARROW_UP,"down":GHOSTTY_KEY_ARROW_DOWN]
        let native: GhosttyKey
        let scalar = key.base.unicodeScalars.first?.value ?? 0
        if let named = names[key.base] { native = named }
        else if key.control, key.base.utf8.count == 1, (97...122).contains(scalar) {
            native = GhosttyKey(rawValue:GHOSTTY_KEY_A.rawValue+scalar-97)
        } else { throw CLIError("Unsupported named key.") }
        var mods: GhosttyMods = 0
        if key.control { mods |= GhosttyMods(GHOSTTY_MODS_CTRL) }
        if key.shift { mods |= GhosttyMods(GHOSTTY_MODS_SHIFT) }
        return .init(keyCode:0,key:native,text:nil,unshiftedCodepoint:names[key.base] == nil ? scalar : 0,
            modifiers:mods,consumedModifiers:0,action:GHOSTTY_KEY_ACTION_PRESS,composing:false,optionAsAlt:false)
    }
}
