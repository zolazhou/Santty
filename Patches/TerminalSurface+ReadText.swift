// Santty's additive API patch for libghostty-spm 1.3.1.
// Compiled inside GhosttyTerminal; uses the existing prebuilt C library.
import Foundation
import GhosttyKit

extension TerminalSurface {
    /// Snapshot the active screen including retained scrollback, without
    /// changing the viewport, selection, clipboard, or keyboard focus.
    public func readScreenText() -> String? {
        guard let surface = rawValue else { return nil }
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_SCREEN,
                coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_SCREEN,
                coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false
        )
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let pointer = text.text, text.text_len > 0 else { return "" }
        return String(
            decoding: UnsafeRawBufferPointer(start: pointer, count: Int(text.text_len)),
            as: UTF8.self)
    }
}

#if canImport(AppKit) && !canImport(UIKit)
    extension AppTerminalView {
        public func readScreenText() -> String? { surface?.readScreenText() }
    }
#endif
