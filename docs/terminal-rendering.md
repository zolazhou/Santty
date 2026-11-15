# Terminal rendering engine

Choose **Settings → Terminal → Rendering Engine**:

- **Core Graphics** (default): SwiftTerm's AppKit/Core Graphics drawing path.
- **Metal**: SwiftTerm's Metal drawing path, requiring a usable Metal device and shader library.

The choice is saved and applies immediately to existing terminals, including
background tabs/workspaces and the sidebar, as well as newly created terminals.
**Reset** restores Core Graphics.

This changes presentation only. Ghostty VT remains the sole terminal-state
owner: switching does not restart a shell, reconnect Herdr, reset history or
selection, replay input, reset per-pane font zoom, or transfer focus.

If initialization fails, the affected pane keeps its current renderer and shows
an “Unable to switch…” warning naming the actual engine. The saved choice is
still the requested preference; changing the choice away and back explicitly
retries. Font/theme/layout notifications do not repeatedly retry a failed Metal
initialization. A rendering failure does not mark the terminal session exited.

## Font size shortcuts

With a terminal focused, use **Cmd+=** (or **Cmd+Shift+= / Cmd++**) to increase
font size, **Cmd+-** to decrease it, and **Cmd+0** to restore the font size from
Settings. These actions are also available in the **View** menu and work in
Scroll Mode. Zoom is per pane and does not change saved font preferences or send
terminal input. Switching rendering engines preserves the pane's current zoom.

The main-menu and actual key-equivalent path have regression coverage in
`Santty/Tests/TerminalFontShortcutTests.swift`; testing only a direct zoom call
would miss disconnected production keyboard/menu wiring.

Both paths have automated pixel regressions; selecting Metal is not a guarantee
of better performance or lower energy use. Settings interaction, multi-display,
sleep/wake and device/energy behavior remain user/device acceptance work.
