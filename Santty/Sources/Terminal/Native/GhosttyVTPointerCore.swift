// Uses Ghostty's mouse encoder and tracked selection gestures; the host owns
// presentation scrolling. No SwiftTerm.Terminal or second selection buffer.
import Foundation
import GhosttyVt

private func pointerCheck(_ result: GhosttyResult, _ operation: String) throws {
    guard result == GHOSTTY_SUCCESS else { throw NativeTerminalError.api(operation, result.rawValue) }
}

/// Only used under GhosttyVTDriver's lock. Disposed before its terminal.
final class GhosttyVTPointerCore {
    private let terminal: GhosttyTerminal
    private var encoder: GhosttyMouseEncoder?
    private var event: GhosttyMouseEvent?
    private var gesture: GhosttySelectionGesture?
    private var encoderSignature: UInt64?
    private var encoderSize: [UInt32] = []
    private var epoch: UInt64 = 0
    private var alternate = false

    init(terminal: GhosttyTerminal) throws {
        self.terminal = terminal
        do {
            try pointerCheck(ghostty_mouse_encoder_new(nil, &encoder), "mouse_encoder_new")
            try pointerCheck(ghostty_mouse_event_new(nil, &event), "mouse_event_new")
            try pointerCheck(ghostty_selection_gesture_new(nil, &gesture), "selection_gesture_new")
            var track = true
            try pointerCheck(ghostty_mouse_encoder_set(encoder, GHOSTTY_MOUSE_ENCODER_OPT_TRACK_LAST_CELL, &track), "mouse_dedup")
        } catch { dispose(); throw error }
    }

    func dispose() {
        if let gesture { ghostty_selection_gesture_free(gesture, terminal) }
        ghostty_mouse_event_free(event); ghostty_mouse_encoder_free(encoder)
        gesture = nil; event = nil; encoder = nil
    }

    func reset(clear: Bool = true) {
        epoch &+= 1; encoderSignature = nil; encoderSize = []
        ghostty_selection_gesture_reset(gesture, terminal)
        _ = ghostty_mouse_encoder_reset(encoder)
        if clear { _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, nil) }
    }

    func cancelGesture() { ghostty_selection_gesture_reset(gesture, terminal) }

    private func mode(_ n: UInt16) -> Bool {
        var query = GhosttyTerminalModeConfig(mode: ghostty_mode_new(n, false), value: false)
        _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MODE, &query)
        return query.value
    }

    func synchronizeScreen() {
        var screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY
        _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen)
        let next = screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE
        if next != alternate { alternate = next; reset() }
    }

    func modes() throws -> NativePointerModes {
        synchronizeScreen()
        var tracking = false
        try pointerCheck(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &tracking), "mouse_tracking")
        var signature = epoch << 16
        for (bit, modeNumber) in [UInt16(9), 1000, 1002, 1003, 1005, 1006, 1015, 1016, 1007].enumerated() {
            if mode(modeNumber) { signature |= UInt64(1) << bit }
        }
        if alternate { signature |= 1 << 15 }
        return .init(tracking: tracking, alternate: alternate, alternateScroll: mode(1007),
                     pixels: mode(1016), signature: signature)
    }

    func encode(_ input: NativeMouseInput, columns: Int, rows: Int) throws -> Data {
        guard try modes() == input.modes, input.modes.tracking,
              input.position.x.isFinite, input.position.y.isFinite,
              input.cell.width.isFinite, input.cell.height.isFinite,
              input.cell.width > 0, input.cell.width <= 1024, input.cell.height > 0, input.cell.height <= 4096,
              input.scale.isFinite, input.scale > 0, input.scale <= 16,
              input.position.x >= 0, input.position.x < CGFloat(columns) * input.cell.width,
              input.position.y >= 0, input.position.y < CGFloat(rows) * input.cell.height else { return Data() }
        if encoderSignature != input.modes.signature {
            try pointerCheck(ghostty_mouse_encoder_set_from_terminal(encoder, terminal), "mouse_modes")
            encoderSignature = input.modes.signature
        }
        // Cell formats use 1/64 point units to preserve fractional cell widths.
        // SGR-pixels instead receives actual device pixels, never scaled units.
        let unit: CGFloat = input.modes.pixels ? input.scale : 64
        var size = GhosttyMouseEncoderSize()
        size.size = MemoryLayout<GhosttyMouseEncoderSize>.size
        size.cell_width = UInt32(max(1, (input.cell.width * unit).rounded()))
        size.cell_height = UInt32(max(1, (input.cell.height * unit).rounded()))
        size.screen_width = UInt32(columns) * size.cell_width
        size.screen_height = UInt32(rows) * size.cell_height
        let dimensions = [size.cell_width, size.cell_height, size.screen_width, size.screen_height]
        if encoderSize != dimensions {
            try pointerCheck(ghostty_mouse_encoder_set(encoder, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size), "mouse_size")
            encoderSize = dimensions
        }
        var any = input.anyButton
        try pointerCheck(ghostty_mouse_encoder_set(encoder, GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &any), "mouse_buttons")
        try pointerCheck(ghostty_mouse_event_set_action(event, input.action), "mouse_action")
        if let button = input.button { try pointerCheck(ghostty_mouse_event_set_button(event, button), "mouse_button") }
        else { try pointerCheck(ghostty_mouse_event_clear_button(event), "mouse_no_button") }
        try pointerCheck(ghostty_mouse_event_set_mods(event, input.modifiers), "mouse_mods")
        try pointerCheck(ghostty_mouse_event_set_position(event, .init(x: Float(input.position.x * unit), y: Float(input.position.y * unit))), "mouse_position")
        // One call: a size-probe must not accidentally consume motion dedup.
        var bytes = [UInt8](repeating: 0, count: 128), count = 0
        try bytes.withUnsafeMutableBufferPointer {
            try pointerCheck(ghostty_mouse_encoder_encode(encoder, event, $0.baseAddress, $0.count, &count), "mouse_encode")
        }
        return Data(bytes.prefix(count))
    }

    func select(_ input: NativeSelectionInput, columns: Int) throws -> Bool {
        synchronizeScreen()
        let type: GhosttySelectionGestureEventType
        switch input.step {
        case .press: type = GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_PRESS
        case .drag: type = GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_DRAG
        case .release: type = GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_RELEASE
        }
        var e: GhosttySelectionGestureEvent?
        try pointerCheck(ghostty_selection_gesture_event_new(nil, &e, type), "selection_event_new")
        defer { ghostty_selection_gesture_event_free(e) }
        var point = GhosttyPoint()
        point.tag = GHOSTTY_POINT_TAG_SCREEN
        point.value.coordinate = .init(x: UInt16(max(0, min(columns - 1, input.column))), y: UInt32(max(0, input.row)))
        var ref = GhosttyGridRef()
        guard ghostty_terminal_grid_ref(terminal, point, &ref) == GHOSTTY_SUCCESS else { return false }
        try pointerCheck(ghostty_selection_gesture_event_set(e, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref), "selection_ref")
        if input.step != .release {
            var position = GhosttySurfacePosition(x: Double(input.position.x * 64), y: Double(input.position.y * 64))
            try pointerCheck(ghostty_selection_gesture_event_set(e, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &position), "selection_position")
        }
        if input.step == .press {
            var time = UInt64(max(0, input.time) * 1_000_000_000)
            var interval = UInt64(max(0, input.doubleClickInterval) * 1_000_000_000)
            var distance = Double(4 * 64)
            try pointerCheck(ghostty_selection_gesture_event_set(e, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_TIME_NS, &time), "selection_time")
            try pointerCheck(ghostty_selection_gesture_event_set(e, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_INTERVAL_NS, &interval), "selection_interval")
            try pointerCheck(ghostty_selection_gesture_event_set(e, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_DISTANCE, &distance), "selection_distance")
        } else if input.step == .drag {
            var geometry = GhosttySelectionGestureGeometry(columns: UInt32(columns),
                cell_width: UInt32(max(1, (input.cell.width * 64).rounded())), padding_left: 0,
                screen_height: UInt32(max(1, (input.viewportHeight * 64).rounded())))
            try pointerCheck(ghostty_selection_gesture_event_set(e, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_GEOMETRY, &geometry), "selection_geometry")
        }
        var selection = GhosttySelection()
        let result = ghostty_selection_gesture_event(gesture, terminal, e, &selection)
        if result == GHOSTTY_SUCCESS {
            try pointerCheck(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &selection), "set_selection")
        } else if result == GHOSTTY_NO_VALUE {
            if input.step == .press { _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, nil) }
        } else { try pointerCheck(result, "selection_gesture") }
        return true
    }

    func selectAll() throws {
        var selection = GhosttySelection()
        let result = ghostty_terminal_select_all(terminal, &selection)
        if result == GHOSTTY_SUCCESS {
            try pointerCheck(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &selection), "select_all")
        } else if result != GHOSTTY_NO_VALUE { try pointerCheck(result, "select_all") }
    }

    func clearSelection() { _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, nil) }

    func selectedText(limit: Int) throws -> String? {
        var selection = GhosttySelection()
        guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SELECTION, &selection) == GHOSTTY_SUCCESS else { return nil }
        var formatter: GhosttyFormatter?
        try pointerCheck(ghostty_formatter_terminal_new(nil, &formatter, terminal), "selection_formatter")
        defer { ghostty_formatter_free(formatter) }
        var yes = true
        try pointerCheck(ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_UNWRAP, &yes), "selection_unwrap")
        try pointerCheck(ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_TRIM, &yes), "selection_trim")
        try pointerCheck(ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_SELECTION, &selection), "selection_format_range")
        var count = 0
        let query = ghostty_formatter_format_buf(formatter, nil, 0, &count)
        if query == GHOSTTY_SUCCESS { return nil }
        guard query == GHOSTTY_OUT_OF_SPACE else { try pointerCheck(query, "selection_format_size"); return nil }
        guard count <= limit else { throw NativeTerminalError.selectionTooLarge }
        var bytes = [UInt8](repeating: 0, count: count)
        try bytes.withUnsafeMutableBufferPointer {
            try pointerCheck(ghostty_formatter_format_buf(formatter, $0.baseAddress, $0.count, &count), "selection_format")
        }
        return String(decoding: bytes.prefix(count), as: UTF8.self)
    }
}
