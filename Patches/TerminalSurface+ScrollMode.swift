// Santty's Swift-only scroll/selection bridge for the prebuilt Ghostty core.
import Foundation
import GhosttyKit

public struct TerminalScrollViewport: Equatable, Sendable {
    public var total: Int
    public var offset: Int
    public var rows: Int

    public init(total: Int, offset: Int, rows: Int) {
        self.total = total
        self.offset = offset
        self.rows = rows
    }
}

@MainActor
public protocol TerminalScrollViewportDelegate: TerminalSurfaceViewDelegate {
    func terminalDidScroll(_ viewport: TerminalScrollViewport)
}

#if canImport(AppKit) && !canImport(UIKit)
    extension AppTerminalView {
        public var scrollModeGrid: TerminalGridMetrics? { surface?.size() }
        public var scrollModeViewport: TerminalScrollViewport? { core.bridge.scrollModeViewport }
        public var scrollModeInputPoint: CGPoint? {
            guard let point = surface?.imePoint() else { return nil }
            return CGPoint(x: point.x, y: point.y - point.height / 2)
        }
        public func readScrollModeSelection() -> String? { surface?.readSelection() }

        /// Read one native grid cell without changing the selection. Wide glyphs
        /// and combining sequences are decoded by Ghostty, not measured in Swift.
        public func readScrollModeCell(column: Int, row: Int) -> String? {
            guard let raw = surface?.rawValue, column >= 0, row >= 0 else { return nil }
            let point = ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT,
                                       x: UInt32(clamping: column), y: UInt32(clamping: row))
            var text = ghostty_text_s()
            guard ghostty_surface_read_text(raw, ghostty_selection_s(
                top_left: point, bottom_right: point, rectangle: false
            ), &text) else { return nil }
            defer { ghostty_surface_free_text(raw, &text) }
            guard let pointer = text.text, text.text_len > 0 else { return "" }
            return String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(text.text_len)), as: UTF8.self)
        }

        /// Call only while mouse reporting, URL matching, prompt clicking and
        /// copy-on-select are disabled in the surface configuration.
        public func clearScrollModeSelection() {
            guard let surface else { return }
            // Two distant clicks reset multi-click detection even for rapid v/Esc.
            for distance in [-1000.0, -100.0] {
                surface.sendMousePos(x: distance, y: distance, mods: GHOSTTY_MODS_NONE)
                surface.sendMouseButton(state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT, mods: GHOSTTY_MODS_NONE)
                surface.sendMouseButton(state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT, mods: GHOSTTY_MODS_NONE)
            }
        }

        /// Coordinates are top-origin view points, relative to their respective
        /// viewports. Both endpoints are included by crossing the cell threshold.
        @discardableResult
        public func selectScrollModeText(
            start: CGPoint, startViewport: Int,
            end: CGPoint, endViewport: Int,
            restoringViewport: Int
        ) -> Bool {
            guard let surface else { return false }
            clearScrollModeSelection()
            surface.scrollToRow(UInt(max(0, startViewport)))
            surface.sendMousePos(x: start.x, y: start.y, mods: GHOSTTY_MODS_NONE)
            surface.sendMouseButton(state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT, mods: GHOSTTY_MODS_NONE)
            // Never leave a synthetic button held between user events.
            defer {
                surface.sendMouseButton(state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT, mods: GHOSTTY_MODS_NONE)
                surface.scrollToRow(UInt(max(0, restoringViewport)))
            }
            surface.scrollToRow(UInt(max(0, endViewport)))
            // mouse_pos suppresses unchanged pixel coordinates. Move through an
            // interior point so cross-page endpoints at the same position work.
            surface.sendMousePos(x: end.x + 2, y: end.y, mods: GHOSTTY_MODS_NONE)
            surface.sendMousePos(x: end.x, y: end.y, mods: GHOSTTY_MODS_NONE)
            return surface.hasSelection()
        }
    }
#endif
