// Keyboard policy adapted from herdr-app a547b16c (Apache-2.0), ported
// to Swift and the official VT 1.0.0 ABI; see Licenses/Keyboard-Adaptation-NOTICE.txt.
import Foundation
import GhosttyVt

enum NativeTerminalError: Error, CustomStringConvertible {
    case invalidSize
    case selectionTooLarge
    case api(String, Int32)

    var description: String {
        switch self {
        case .invalidSize: return "Terminal size is outside the lab limits."
        case .selectionTooLarge: return "The selection exceeds the clipboard limit."
        case let .api(operation, code): return "\(operation) failed (Ghostty VT \(code))."
        }
    }
}

private func checkVT(_ result: GhosttyResult, _ operation: String) throws {
    guard result == GHOSTTY_SUCCESS else {
        throw NativeTerminalError.api(operation, result.rawValue)
    }
}

/// Every C call and callback state access is serialized by lock. Output may
/// parse on a transport stream queue while the main actor samples owned frames.
/// No user callbacks or UI work run while the VT lock is held.
final class GhosttyVTDriver: @unchecked Sendable {
    private let terminal: GhosttyTerminal
    private let state: GhosttyRenderState
    private let iterator: GhosttyRenderStateRowIterator
    private let cellIterator: GhosttyRenderStateRowCells
    private var previousRows: [NativeRowID: NativeTerminalRow] = [:]
    private let lock = NSRecursiveLock()
    private let callbacks: VTCallbackState
    private let encoder: GhosttyKeyEncoder
    private let keyEvent: GhosttyKeyEvent
    private let pointer: GhosttyVTPointerCore
    private let history: GhosttyVTHistoryAnchor
    private let images: GhosttyVTImages
    private let accessibleText: GhosttyVTAccessibleText
    private let animationClock: @Sendable () -> UInt64
    private var lastAnimationTime: UInt64 = 0
    private var animationDeadline: UInt64?
    private var published: NativeTerminalFrame?
    private var storedColumns: Int
    private var storedRows: Int
    var columns: Int { lock.withLock { storedColumns } }
    var rows: Int { lock.withLock { storedRows } }
    var cellSizePixels: (width: UInt32, height: UInt32) { lock.withLock { (callbacks.size.cell_width, callbacks.size.cell_height) } }

    init(columns: Int = 80, rows: Int = 24, scrollbackLines: UInt? = nil,
         imageLimits: NativeImageSnapshotLimits = .init(),
         animationClock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds / 1_000_000 },
         clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) throws {
        guard (1...4096).contains(columns), (1...1024).contains(rows) else {
            throw NativeTerminalError.invalidSize
        }
        try GhosttyVTSystem.prepare()
        var terminal: GhosttyTerminal?
        var state: GhosttyRenderState?
        var iterator: GhosttyRenderStateRowIterator?
        var cells: GhosttyRenderStateRowCells?
        var encoder: GhosttyKeyEncoder?
        var keyEvent: GhosttyKeyEvent?
        var pointer: GhosttyVTPointerCore?
        var images: GhosttyVTImages?
        var accessibleText: GhosttyVTAccessibleText?
        let callbacks = VTCallbackState(clock: clock)
        callbacks.size = .init(rows: UInt16(rows), columns: UInt16(columns), cell_width: 8, cell_height: 16)
        do {
            try checkVT(ghostty_terminal_new(nil, &terminal, UInt16(columns), UInt16(rows)), "terminal_new")
            // VT starts with zero physical cell dimensions. Match the 8x16
            // size callback/default resize metrics before pre-layout output
            // can create images; an OK reply alone is not a render placement.
            try checkVT(ghostty_terminal_resize(terminal, UInt16(columns), UInt16(rows), 8, 16), "initial_metrics")
            try checkVT(ghostty_render_state_new(nil, &state), "render_state_new")
            try checkVT(ghostty_render_state_row_iterator_new(nil, &iterator), "row_iterator_new")
            try checkVT(ghostty_render_state_row_cells_new(nil, &cells), "row_cells_new")
            try checkVT(ghostty_key_encoder_new(nil, &encoder), "key_encoder_new")
            try checkVT(ghostty_key_event_new(nil, &keyEvent), "key_event_new")
            try checkVT(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_USERDATA,
                Unmanaged.passUnretained(callbacks).toOpaque()), "userdata")
            try checkVT(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY,
                unsafeBitCast(vtWriteReply, to: UnsafeRawPointer.self)), "write_pty")
            try checkVT(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_RENDER_HOLD,
                unsafeBitCast(vtRenderHold, to: UnsafeRawPointer.self)), "render_hold")
            try checkVT(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE,
                unsafeBitCast(vtClipboardWrite, to: UnsafeRawPointer.self)), "clipboard_write")
            var clipboardLimit = UInt(NativeClipboardInbox.maximumBytes)
            try checkVT(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE_MAX_BYTES, &clipboardLimit), "clipboard_limit")
            // No clipboard-read callback: no program can read the OS clipboard.
            try checkVT(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_RESET,
                unsafeBitCast(vtReset, to: UnsafeRawPointer.self)), "reset_callback")
            try checkVT(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SIZE,
                unsafeBitCast(vtSize, to: UnsafeRawPointer.self)), "size_callback")
            var limit = UInt(8 * 1024 * 1024)
            try checkVT(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &limit), "scrollback_limit")
            // Optional line cap enables bounded-history fixtures/preferences;
            // the default 8 MiB byte budget is never reduced.
            if var lines = scrollbackLines {
                try checkVT(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &lines), "scrollback_lines")
            }
            var overscan = GhosttyRenderStateOverscan(above: 1, below: 3)
            try checkVT(ghostty_render_state_set(state, GHOSTTY_RENDER_STATE_OPT_OVERSCAN, &overscan), "overscan")
            pointer = try GhosttyVTPointerCore(terminal: terminal!)
            images = try GhosttyVTImages(terminal: terminal!, limits: imageLimits)
            accessibleText = try GhosttyVTAccessibleText(terminal: terminal!)
        } catch {
            accessibleText?.dispose()
            images?.dispose()
            pointer?.dispose()
            ghostty_key_event_free(keyEvent)
            ghostty_key_encoder_free(encoder)
            ghostty_render_state_row_cells_free(cells)
            ghostty_render_state_row_iterator_free(iterator)
            ghostty_render_state_free(state)
            ghostty_terminal_free(terminal)
            throw error
        }
        self.terminal = terminal!
        self.state = state!
        self.iterator = iterator!
        self.cellIterator = cells!
        self.callbacks = callbacks
        self.encoder = encoder!
        self.keyEvent = keyEvent!
        self.pointer = pointer!
        self.images = images!
        self.accessibleText = accessibleText!
        self.animationClock = animationClock
        self.history = GhosttyVTHistoryAnchor(terminal: terminal!)
        self.storedColumns = columns
        self.storedRows = rows
        self.published = try capture(topRow: 0)
    }

    deinit {
        history.invalidate()
        pointer.dispose()
        images.dispose()
        accessibleText.dispose()
        ghostty_key_event_free(keyEvent)
        ghostty_key_encoder_free(encoder)
        ghostty_render_state_row_cells_free(cellIterator)
        ghostty_render_state_row_iterator_free(iterator)
        ghostty_render_state_free(state)
        ghostty_terminal_free(terminal)
    }

    @discardableResult
    func feed(_ data: Data) -> Data {
        lock.withLock {
            data.withUnsafeBytes { bytes in
                ghostty_terminal_vt_write(terminal, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
            }
            pointer.synchronizeScreen()
            return takeReplies()
        }
    }

    @discardableResult
    func feed(_ text: String) -> Data { feed(Data(text.utf8)) }

    @discardableResult
    func resize(columns: Int, rows: Int, cellWidth: UInt32 = 8, cellHeight: UInt32 = 16) throws -> Data {
        try lock.withLock {
            guard (1...4096).contains(columns), (1...1024).contains(rows) else {
                throw NativeTerminalError.invalidSize
            }
            pointer.reset()
            callbacks.size = .init(rows: UInt16(rows), columns: UInt16(columns),
                                   cell_width: cellWidth, cell_height: cellHeight)
            try checkVT(ghostty_terminal_resize(terminal, UInt16(columns), UInt16(rows), cellWidth, cellHeight), "resize")
            storedColumns = columns
            storedRows = rows
            callbacks.heldSince = nil
            return takeReplies()
        }
    }

    /// Host defaults, not a synthetic DECSCUSR command. Programs retain their
    /// explicit cursor style; CSI 0 q asks VT to restore these defaults.
    func setDefaultCursorStyle(_ shape: NativeTerminalFrame.CursorShape, blinking: Bool) throws {
        try lock.withLock {
            var style: GhosttyCursorStyle
            switch shape {
            case .block: style = GHOSTTY_CURSOR_STYLE_BLOCK
            case .bar: style = GHOSTTY_CURSOR_STYLE_BAR
            case .underline: style = GHOSTTY_CURSOR_STYLE_UNDERLINE
            case .hollow: style = GHOSTTY_CURSOR_STYLE_BLOCK_HOLLOW
            }
            var blink = blinking
            try checkVT(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_STYLE, &style), "default_cursor_style")
            try checkVT(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_BLINK, &blink), "default_cursor_blink")
        }
    }

    func reset() {
        lock.withLock {
            history.invalidate()
            callbacks.clipboard.clear()
            pointer.reset()
            ghostty_terminal_reset(terminal)
            images.reset()
            animationDeadline = nil
            previousRows = [:]
            callbacks.heldSince = nil
            callbacks.replies = Data()
            // A hold in the first restore chunk must retain an empty frame,
            // not publish that chunk halfway through a synchronized update.
            published = try? capture(topRow: 0)
        }
    }

    var totalRows: Int {
        get throws {
            try lock.withLock {
                if holdRemainingLocked() != nil, let published { return published.totalRows }
                var scrollbar = GhosttyTerminalScrollbar()
                try checkVT(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &scrollbar), "scrollbar")
                return Int(clamping: scrollbar.total)
            }
        }
    }

    /// A bounded hold never blocks parsing, protocol replies, or credit.
    var renderHoldRemaining: TimeInterval? { lock.withLock { holdRemainingLocked() } }

    private func holdRemainingLocked() -> TimeInterval? {
        guard let since = callbacks.heldSince else { return nil }
        let remaining = since + 1 - callbacks.clock()
        if remaining > 0 { return remaining }
        // Setting the mode ourselves does not invoke the render-hold callback.
        var mode = GhosttyTerminalModeConfig(mode: ghostty_mode_new(2026, false), value: false)
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_MODE, &mode)
        callbacks.heldSince = nil
        return nil
    }

    func snapshot(topRow: Int) throws -> NativeTerminalFrame {
        try lock.withLock {
            if holdRemainingLocked() != nil {
                guard let published else {
                    throw NativeTerminalError.api("render_hold_without_frame", GHOSTTY_INVALID_VALUE.rawValue)
                }
                return published
            }
            let frame = try capture(topRow: topRow)
            published = frame
            return frame
        }
    }

    /// The same monotonic millisecond epoch is kept for this terminal's whole
    /// lifetime, including resets. Clamp test/host clock regressions; never
    /// rewind or implement per-image playback time in the host.
    private func animationNowLocked() -> UInt64 {
        lastAnimationTime = max(lastAnimationTime, animationClock())
        return lastAnimationTime
    }

    var imageAnimationWake: NativeImageAnimationWake? {
        lock.withLock {
            guard let deadline = animationDeadline else { return nil }
            let now = animationNowLocked()
            return .init(deadlineMilliseconds: deadline, delayMilliseconds: deadline > now ? deadline - now : 0)
        }
    }

    /// Resolve the last published content reference and capture the resulting
    /// viewport atomically with parsing. A requested offset is a user movement
    /// relative to the previously published document, not a stale live row ID.
    /// A hold that begins between the UI's check and this lock publishes nothing.
    func presentation(rowHeight: CGFloat, viewportHeight: CGFloat, previous: NativeViewport?,
                      requestedOffset: CGFloat? = nil, advanceAnimations: Bool = true) throws -> NativeTerminalPresentation? {
        try lock.withLock {
            guard holdRemainingLocked() == nil else { return nil }
            if advanceAnimations {
                animationDeadline = try images.advanceAnimations(terminal: terminal, now: animationNowLocked())
            }
            try history.synchronize(resetEpoch: callbacks.resetEpoch)
            let total = try totalRows
            let bounds = NativeViewport(rowHeight: rowHeight, viewportHeight: viewportHeight, totalRows: total, offset: 0)
            let intent = previous.map {
                NativeViewport(rowHeight: $0.rowHeight, viewportHeight: $0.viewportHeight,
                    totalRows: $0.totalRows, offset: requestedOffset ?? $0.offset)
            }
            let point = try history.position()
            var offset: CGFloat
            var retarget = true
            var elastic = intent.map { ($0.offset - $0.clampedOffset) / $0.rowHeight * bounds.rowHeight } ?? 0
            if history.needsLiveReset || intent == nil { elastic = 0 }
            var anchor: NativeTerminalPresentation.Anchor
            if history.needsLiveReset || intent == nil || intent?.isAtBottom == true {
                // Preserve same-screen AppKit travel, never a reset screen's
                // old overscroll (which could incorrectly disable follow).
                offset = bounds.maximumOffset + elastic
                anchor = .following
            } else if let point, let previous, let intent {
                let delta = requestedOffset == nil ? 0 : intent.firstRow - previous.firstRow
                let row = Int(point.y) + delta
                offset = CGFloat(row) * bounds.rowHeight
                    + intent.fraction / previous.rowHeight * bounds.rowHeight + elastic
                retarget = delta != 0 || row < 0
                anchor = row < 0 ? .oldestAvailable : .preserved(column: delta == 0 ? Int(point.x) : 0)
            } else {
                // The referenced cell was discarded. Do not reuse its old row
                // index (which now names unrelated output), or jump to the tail.
                offset = 0
                elastic = 0
                anchor = .oldestAvailable
            }
            // Apart from genuine elastic displacement, constrain to the new
            // document. Reaching the tail resumes the existing follow policy.
            offset = min(bounds.maximumOffset, max(0, offset - elastic)) + elastic
            let viewport = NativeViewport(rowHeight: bounds.rowHeight, viewportHeight: bounds.viewportHeight,
                totalRows: total, offset: offset)
            if viewport.isAtBottom { anchor = .following; retarget = true }
            let frame = try capture(topRow: viewport.firstRow)
            if retarget {
                try history.track(viewportRow: viewport.firstRow - frame.topRow)
            }
            published = frame
            return .init(viewport: viewport, frame: frame, anchor: anchor)
        }
    }

    func setClipboardCaptureEnabled(_ enabled: Bool) { lock.withLock { callbacks.clipboard.setEnabled(enabled) } }
    func discardClipboardOffers() { lock.withLock { callbacks.clipboard.clear() } }
    var clipboardOffer: NativeClipboardOffer? { lock.withLock { callbacks.clipboard.current(now: callbacks.clock()) } }
    func claimClipboardOffer(_ id: UUID) -> NativeClipboardOffer? {
        lock.withLock { callbacks.clipboard.take(id: id, now: callbacks.clock()) }
    }

    var displayColors: [String: String] {
        lock.withLock {
            var result: [String: String] = [:]
            for (key, field) in [("fg", GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND),
                                 ("bg", GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND),
                                 ("cursor", GHOSTTY_TERMINAL_DATA_COLOR_CURSOR)] {
                var color = GhosttyColorRgb()
                if ghostty_terminal_get(terminal, field, &color) == GHOSTTY_SUCCESS {
                    result[key] = String(format: "#%02x%02x%02x", color.r, color.g, color.b)
                }
            }
            return result
        }
    }

    private func takeReplies() -> Data {
        let result = callbacks.replies
        callbacks.replies = Data()
        return result
    }

    struct KeyboardModes {
        let kittyFlags: UInt8
        let applicationCursor: Bool
        let applicationKeypad: Bool
        let numLockOverridesKeypad: Bool
        let bracketedPaste: Bool
    }

    var keyboardModes: KeyboardModes {
        get throws {
            try lock.withLock {
                var flags: UInt8 = 0
                try checkVT(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS, &flags), "kitty_flags")
                return .init(kittyFlags: flags, applicationCursor: mode(1), applicationKeypad: mode(66),
                             numLockOverridesKeypad: mode(1035), bracketedPaste: mode(2004))
            }
        }
    }

    func encode(_ input: NativeTerminalInput) throws -> Data {
        switch input {
        case let .key(event): return try encodeKey(event)
        case let .committedText(text): return Data(text.utf8)
        case let .paste(text): return try encodePaste(text)
        case let .focus(focused): return try encodeFocus(focused)
        case let .mouse(mouse): return try encodeMouse(mouse)
        case let .wheel(wheel): return try encodeWheel(wheel)
        }
    }

    func encodeKey(_ event: NativeTerminalKeyEvent) throws -> Data {
        guard !event.composing else { return Data() }
        return try encodeKey(event.logicalKey ?? event.key, text: event.text, modifiers: event.modifiers, action: event.action,
            unshiftedCodepoint: event.unshiftedCodepoint, optionAsAlt: event.optionAsAlt,
            consumedModifiers: event.consumedModifiers)
    }

    func encodeKey(_ key: GhosttyKey, text: String? = nil, modifiers: GhosttyMods = 0,
                   action: GhosttyKeyAction = GHOSTTY_KEY_ACTION_PRESS,
                   unshiftedCodepoint: UInt32 = 0, optionAsAlt: Bool = false,
                   consumedModifiers: GhosttyMods = 0) throws -> Data {
        try lock.withLock {
            guard !mode(2, ansi: true) else { return Data() }
            if text == nil, let alias = try legacyControlAlias(key, modifiers: modifiers,
                action: action, unshiftedCodepoint: unshiftedCodepoint) { return alias }
            try checkVT(ghostty_key_encoder_set_from_terminal(encoder, terminal), "key_modes")
            var option = optionAsAlt ? GHOSTTY_OPTION_AS_ALT_TRUE : GHOSTTY_OPTION_AS_ALT_FALSE
            try checkVT(ghostty_key_encoder_set(encoder, GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT, &option), "option_as_alt")
            try checkVT(ghostty_key_event_set_key(keyEvent, key), "key")
            try checkVT(ghostty_key_event_set_action(keyEvent, action), "key_action")
            try checkVT(ghostty_key_event_set_mods(keyEvent, modifiers), "key_modifiers")
            let printable = NativeKeyNormalizer.printable(text) != nil
            try checkVT(ghostty_key_event_set_consumed_mods(keyEvent, printable ? consumedModifiers : 0), "key_consumed_modifiers")
            try checkVT(ghostty_key_event_set_composing(keyEvent, false), "key_composing")
            try checkVT(ghostty_key_event_set_unshifted_codepoint(keyEvent, unshiftedCodepoint), "key_codepoint")
            return try Array((text ?? "").utf8).withUnsafeBufferPointer { bytes in
                try checkVT(ghostty_key_event_set_utf8(keyEvent,
                    GhosttyString(ptr: bytes.baseAddress, len: bytes.count)), "key_text")
                return try encode { pointer, capacity, written in
                    ghostty_key_encoder_encode(encoder, keyEvent, pointer, capacity, written)
                }
            }
        }
    }

    /// The pinned encoder leaves legacy aliases to its caller (as in Herdr's
    /// terminal adapter). Kitty keeps the original chord. With no mode-2 getter,
    /// probe the encoder so negotiated modifyOtherKeys still owns its sequence.
    private func legacyControlAlias(_ key: GhosttyKey, modifiers: GhosttyMods,
                                    action: GhosttyKeyAction, unshiftedCodepoint: UInt32) throws -> Data? {
        guard action != GHOSTTY_KEY_ACTION_RELEASE,
              modifiers & GhosttyMods(GHOSTTY_MODS_CTRL) != 0,
              modifiers & GhosttyMods(GHOSTTY_MODS_ALT | GHOSTTY_MODS_SUPER) == 0 else { return nil }
        var flags: UInt8 = 0
        try checkVT(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS, &flags), "kitty_flags")
        guard flags == 0 else { return nil }
        let shifted = modifiers & GhosttyMods(GHOSTTY_MODS_SHIFT) != 0
        let alias: GhosttyKey
        let base: String
        switch key {
        case GHOSTTY_KEY_I where !shifted: alias = GHOSTTY_KEY_TAB; base = "i"
        case GHOSTTY_KEY_M where !shifted: alias = GHOSTTY_KEY_ENTER; base = "m"
        case GHOSTTY_KEY_BRACKET_LEFT where !shifted: alias = GHOSTTY_KEY_ESCAPE; base = "["
        case GHOSTTY_KEY_MINUS: alias = GHOSTTY_KEY_UNIDENTIFIED; base = shifted ? "_" : "-"
        default: return nil
        }
        // Don't substitute a US-layout alias when the platform reports a
        // different unshifted character for that physical key.
        guard let scalar = base.unicodeScalars.first else { return nil }
        let expectedBase = key == GHOSTTY_KEY_MINUS ? UInt32(45) : scalar.value
        guard unshiftedCodepoint == 0 || unshiftedCodepoint == expectedBase else { return nil }
        let probe = try encodeKey(key, text: base, modifiers: modifiers, action: action,
                                  unshiftedCodepoint: unshiftedCodepoint)
        if probe.starts(with: [0x1B, 0x5B, 0x32, 0x37, 0x3B]) { return probe } // CSI 27;
        if key == GHOSTTY_KEY_MINUS { return Data([0x1F]) }
        return try encodeKey(alias, action: action)
    }

    func encodePaste(_ text: String) throws -> Data {
        try lock.withLock {
            let bracketed = mode(2004)
            // Like Herdr, treat Windows CRLF as one newline in legacy paste.
            // The C encoder converts LF to CR but does not collapse CRLF.
            let normalized = bracketed ? text : text.replacingOccurrences(of: "\r\n", with: "\n")
            var bytes = Array(normalized.utf8).map { CChar(bitPattern: $0) }
            return try bytes.withUnsafeMutableBufferPointer { input in
                try encode { pointer, capacity, written in
                    ghostty_paste_encode(input.baseAddress, input.count, bracketed, pointer, capacity, written)
                }
            }
        }
    }

    func encodeFocus(_ focused: Bool) throws -> Data {
        try lock.withLock {
            guard mode(1004) else { return Data() }
            return try encode { pointer, capacity, written in
                ghostty_focus_encode(focused ? GHOSTTY_FOCUS_GAINED : GHOSTTY_FOCUS_LOST,
                                     pointer, capacity, written)
            }
        }
    }

    private func mode(_ number: UInt16, ansi: Bool = false) -> Bool {
        var value = GhosttyTerminalModeConfig(mode: ghostty_mode_new(number, ansi), value: false)
        return ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MODE, &value) == GHOSTTY_SUCCESS && value.value
    }

    private func encode(_ body: (UnsafeMutablePointer<UInt8>?, Int, UnsafeMutablePointer<Int>) -> GhosttyResult) throws -> Data {
        var needed = 0
        let result = body(nil, 0, &needed)
        if result == GHOSTTY_SUCCESS { return Data() }
        guard result == GHOSTTY_OUT_OF_SPACE else { try checkVT(result, "encode_size"); return Data() }
        var bytes = [UInt8](repeating: 0, count: needed)
        try bytes.withUnsafeMutableBufferPointer { pointer in
            try checkVT(body(pointer.baseAddress, pointer.count, &needed), "encode")
        }
        return Data(bytes.prefix(needed))
    }

    private func capture(topRow: Int) throws -> NativeTerminalFrame {
        var scroll = GhosttyTerminalScrollViewport()
        scroll.tag = GHOSTTY_TERMINAL_SCROLL_VIEWPORT_ROW
        scroll.value.row = max(0, topRow)
        try checkVT(ghostty_terminal_scroll_viewport(terminal, scroll), "scroll_viewport")
        try checkVT(ghostty_render_state_update(state, terminal), "render_state_update")

        var scrollbar = GhosttyTerminalScrollbar()
        try checkVT(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &scrollbar), "scrollbar")
        var colors = GhosttyRenderStateColors()
        colors.size = MemoryLayout<GhosttyRenderStateColors>.size
        try checkVT(ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLORS, &colors), "colors")
        let palette = withUnsafePointer(to: &colors.palette) {
            $0.withMemoryRebound(to: GhosttyColorRgb.self, capacity: 256) {
                UnsafeBufferPointer(start: $0, count: 256).map(NativeRGB.init)
            }
        }

        var rowIterator: GhosttyRenderStateRowIterator? = iterator
        try checkVT(ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &rowIterator), "rows")
        var captured: [Int: NativeTerminalRow] = [:]
        var linkBudget = NativeTerminalLink.frameByteBudget
        var selection: [Int: ClosedRange<Int>] = [:]
        var nextRows: [NativeRowID: NativeTerminalRow] = [:]
        while ghostty_render_state_row_iterator_next(iterator) {
            var position: Int32 = 0
            var identity = GhosttyRenderStateRowId()
            var raw: GhosttyRow = 0
            try checkVT(ghostty_render_state_row_get(iterator, GHOSTTY_RENDER_STATE_ROW_DATA_VIEWPORT_Y, &position), "row_position")
            try checkVT(ghostty_render_state_row_get(iterator, GHOSTTY_RENDER_STATE_ROW_DATA_ID, &identity), "row_identity")
            try checkVT(ghostty_render_state_row_get(iterator, GHOSTTY_RENDER_STATE_ROW_DATA_RAW, &raw), "row_raw")
            var wrapped = false, imagePlaceholderRow = false
            try checkVT(ghostty_row_get(raw, GHOSTTY_ROW_DATA_WRAP_CONTINUATION, &wrapped), "row_wrap")
            try checkVT(ghostty_row_get(raw, GHOSTTY_ROW_DATA_KITTY_VIRTUAL_PLACEHOLDER, &imagePlaceholderRow), "row_image_placeholder")
            let id = NativeRowID(first: identity.bits.0, second: identity.bits.1)
            var selected = GhosttyRenderStateRowSelection()
            selected.size = MemoryLayout<GhosttyRenderStateRowSelection>.size
            if ghostty_render_state_row_get(iterator, GHOSTTY_RENDER_STATE_ROW_DATA_SELECTION, &selected) == GHOSTTY_SUCCESS {
                selection[Int(clamping: scrollbar.offset) + Int(position)] = Int(selected.start_x)...Int(selected.end_x)
            }
            var dirty = true
            try checkVT(ghostty_render_state_row_get(iterator, GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY, &dirty), "row_dirty")
            if !dirty, let old = previousRows[id], old.cells.count == columns, old.isWrapped == wrapped,
               old.hyperlinkBytes <= linkBudget {
                linkBudget -= old.hyperlinkBytes
                captured[Int(clamping: scrollbar.offset) + Int(position)] = old
                nextRows[id] = old
                continue
            }
            var cells: GhosttyRenderStateRowCells? = cellIterator
            try checkVT(ghostty_render_state_row_get(iterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cells), "row_cells")
            var values: [NativeTerminalCell] = []
            values.reserveCapacity(columns)
            while ghostty_render_state_row_cells_next(cellIterator) {
                values.append(try readCell(column: values.count, row: Int(clamping: scrollbar.offset) + Int(position),
                    linkBudget: &linkBudget, imagePlaceholderRow: imagePlaceholderRow))
            }
            // Dirty can mean a row moved, not that its content changed.
            let row: NativeTerminalRow
            if let old = previousRows[id], old.cells == values, old.isWrapped == wrapped {
                row = old
            } else {
                row = NativeTerminalRow(id: id, cells: values, isWrapped: wrapped)
            }
            captured[Int(clamping: scrollbar.offset) + Int(position)] = row
            nextRows[id] = row
        }
        previousRows = nextRows  // Bounded to the viewport + overscan, never all history.
        let imageSnapshot = try images.capture(terminal: terminal, state: state, topRow: Int(clamping: scrollbar.offset))
        let formattedText = try accessibleText.capture(terminal: terminal, rows: captured, columns: columns)
        ghostty_render_state_clean(state)

        var cursor = GhosttyRenderStateCursor()
        cursor.size = MemoryLayout<GhosttyRenderStateCursor>.size
        try checkVT(ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR, &cursor), "cursor")
        var screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY
        try checkVT(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen), "active_screen")
        // AppKit can display a fractional extra row beyond Ghostty's integer
        // viewport. Its cursor may then be in our captured overscan even when
        // render-state viewport_has_value is false. Use active-screen position,
        // not the narrower Ghostty viewport's visibility/undefined coordinates.
        var cursorX: UInt16 = 0, cursorY: UInt16 = 0
        try checkVT(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_CURSOR_X, &cursorX), "cursor_x")
        try checkVT(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_CURSOR_Y, &cursorY), "cursor_y")
        let cursorLine = max(0, Int(clamping: scrollbar.total) - rows) + Int(cursorY)
        let cursorRow = captured[cursorLine]
        let wideTail = cursorRow.map { $0.cells.indices.contains(Int(cursorX)) && $0.cells[Int(cursorX)].width == 0 } ?? false
        let shape: NativeTerminalFrame.CursorShape
        switch cursor.visual_style {
        case GHOSTTY_CURSOR_STYLE_BAR: shape = .bar
        case GHOSTTY_CURSOR_STYLE_UNDERLINE: shape = .underline
        case GHOSTTY_CURSOR_STYLE_BLOCK_HOLLOW: shape = .hollow
        default: shape = .block
        }
        return NativeTerminalFrame(
            columns: columns, terminalRows: rows, totalRows: Int(clamping: scrollbar.total),
            topRow: Int(clamping: scrollbar.offset), rows: captured,
            cursor: .init(line: cursorLine,
                          column: max(0, Int(cursorX) - (wideTail ? 1 : 0)),
                          visible: cursor.visible && cursorRow != nil,
                          blinking: cursor.blinking, shape: shape),
            foreground: NativeRGB(colors.foreground), background: NativeRGB(colors.background),
            cursorColor: NativeRGB(colors.cursor_has_value ? colors.cursor : colors.foreground),
            palette: palette, isAlternateScreen: screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE,
            selection: selection,
            imageSnapshot: imageSnapshot, accessibleText: formattedText)
    }

    var pointerModes: NativePointerModes { get throws { try lock.withLock { try pointer.modes() } } }

    func encodeMouse(_ input: NativeMouseInput) throws -> Data {
        try lock.withLock {
            guard input.action == GHOSTTY_MOUSE_ACTION_RELEASE || holdRemainingLocked() == nil else { return Data() }
            return try pointer.encode(input, columns: columns, rows: rows)
        }
    }

    func encodeWheel(_ input: NativeProgramScroll) throws -> Data {
        try lock.withLock {
            guard holdRemainingLocked() == nil, try pointer.modes() == input.mouse.modes else { return Data() }
            var result = Data()
            for (steps, positive, negative) in [(input.y, GHOSTTY_MOUSE_BUTTON_FOUR, GHOSTTY_MOUSE_BUTTON_FIVE),
                                               (input.x, GHOSTTY_MOUSE_BUTTON_SIX, GHOSTTY_MOUSE_BUTTON_SEVEN)] {
                for _ in 0..<min(40, steps.magnitude) {
                    if input.route == .mouse {
                        let event = NativeMouseInput(action: GHOSTTY_MOUSE_ACTION_PRESS,
                            button: steps > 0 ? positive : negative, modifiers: input.mouse.modifiers,
                            position: input.mouse.position, cell: input.mouse.cell, scale: input.mouse.scale,
                            anyButton: input.mouse.anyButton, modes: input.mouse.modes)
                        result.append(try pointer.encode(event, columns: columns, rows: rows))
                    } else if input.route == .arrows, input.mouse.modes.alternate, input.mouse.modes.alternateScroll,
                              !input.mouse.modes.tracking, positive == GHOSTTY_MOUSE_BUTTON_FOUR {
                        result.append(try encodeKey(steps > 0 ? GHOSTTY_KEY_ARROW_UP : GHOSTTY_KEY_ARROW_DOWN,
                                                   modifiers: input.mouse.modifiers))
                    }
                }
            }
            return result
        }
    }

    @discardableResult
    func select(_ input: NativeSelectionInput, relativeTo viewport: NativeViewport? = nil) throws -> Bool {
        try lock.withLock {
            guard holdRemainingLocked() == nil else { return false }
            var target = input
            if let viewport {
                // Parsing may have pruned rows after the pixels were published
                // but before AppKit delivered this selection event. Rebase on
                // that frame's tracked content, never on its stale row index.
                try history.synchronize(resetEpoch: callbacks.resetEpoch)
                guard !history.needsLiveReset, let point = try history.position() else { return false }
                let row = Int(point.y) + input.row - viewport.firstRow
                guard row >= 0 else { return false }
                target = .init(step: input.step, column: input.column, row: row, position: input.position,
                    cell: input.cell, viewportHeight: input.viewportHeight, time: input.time,
                    doubleClickInterval: input.doubleClickInterval)
            }
            return try pointer.select(target, columns: columns)
        }
    }

    func clearSelection() { lock.withLock { pointer.clearSelection() } }
    func cancelSelectionGesture() { lock.withLock { pointer.cancelGesture() } }
    func selectAll() throws { try lock.withLock { if holdRemainingLocked() == nil { try pointer.selectAll() } } }
    func selectedText(limit: Int = 32 * 1024 * 1024) throws -> String? {
        try lock.withLock {
            guard holdRemainingLocked() == nil else { return nil }
            return try pointer.selectedText(limit: max(0, limit))
        }
    }

    /// Fresh grid references never escape this lock. Bounded URI extraction
    /// follows herdr-app vt.rs::hyperlink_uri, using VT 1.0's current ABI.
    private func hyperlink(column: Int, row: Int, maximum: Int) throws -> String? {
        guard row >= 0, column >= 0, column < columns, maximum > 0 else { return nil }
        var point = GhosttyPoint()
        point.tag = GHOSTTY_POINT_TAG_SCREEN
        point.value.coordinate = .init(x: UInt16(column), y: UInt32(clamping: row))
        var ref = GhosttyGridRef()
        guard ghostty_terminal_grid_ref(terminal, point, &ref) == GHOSTTY_SUCCESS else { return nil }
        var count = 0
        let result = ghostty_grid_ref_hyperlink_uri(&ref, nil, 0, &count)
        if result == GHOSTTY_SUCCESS { return nil }
        try checkVT(result == GHOSTTY_OUT_OF_SPACE ? GHOSTTY_SUCCESS : result, "link_size")
        guard count > 0, count <= min(maximum, NativeTerminalLink.maximumBytes) else { return nil }
        var bytes = [UInt8](repeating: 0, count: count)
        try bytes.withUnsafeMutableBufferPointer {
            try checkVT(ghostty_grid_ref_hyperlink_uri(&ref, $0.baseAddress, $0.count, &count), "link_uri")
        }
        return String(bytes: bytes.prefix(count), encoding: .utf8)
    }

    func verifyHyperlink(_ expected: String, column: Int, row: Int, relativeTo viewport: NativeViewport) throws -> Bool {
        try lock.withLock {
            guard holdRemainingLocked() == nil else { return false }
            try history.synchronize(resetEpoch: callbacks.resetEpoch)
            guard !history.needsLiveReset, let point = try history.position() else { return false }
            guard let actual = try hyperlink(column: column, row: Int(point.y) + row - viewport.firstRow,
                maximum: NativeTerminalLink.maximumBytes) else { return false }
            return actual.utf8.elementsEqual(expected.utf8)
        }
    }

    /// Re-read implicit text under the same lock as parsing and anchor rebasing.
    /// Never open an old displayed URL after an unpresented rewrite/reset.
    func verifyLink(_ expected: NativeTerminalLinkMatch, column: Int, row: Int,
                    relativeTo viewport: NativeViewport) throws -> Bool {
        if expected.isExplicit {
            return try verifyHyperlink(expected.uri, column: column, row: row, relativeTo: viewport)
        }
        return try lock.withLock {
            guard holdRemainingLocked() == nil else { return false }
            try history.synchronize(resetEpoch: callbacks.resetEpoch)
            guard !history.needsLiveReset, let point = try history.position() else { return false }
            let delta = Int(point.y) - viewport.firstRow
            let current = try capture(topRow: Int(point.y))
            return NativeTerminalLinkMatcher.match(in: current, column: column, row: row + delta)?
                .matches(expected, rowOffset: delta) == true
        }
    }

    private func readCell(column: Int, row: Int, linkBudget: inout Int, imagePlaceholderRow: Bool) throws -> NativeTerminalCell {
        var raw: GhosttyCell = 0
        var style = GhosttyStyle()
        try checkVT(ghostty_render_state_row_cells_get(cellIterator, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw), "cell_raw")
        try checkVT(ghostty_render_state_row_cells_get(cellIterator, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style), "cell_style")
        var wide = GHOSTTY_CELL_WIDE_NARROW
        try checkVT(ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide), "cell_width")
        var buffer = GhosttyBuffer()
        let result = ghostty_render_state_row_cells_get(cellIterator, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, &buffer)
        var text: String?
        if result == GHOSTTY_OUT_OF_SPACE {
            var bytes = [UInt8](repeating: 0, count: buffer.len)
            try bytes.withUnsafeMutableBufferPointer { pointer in
                buffer.ptr = pointer.baseAddress
                buffer.cap = pointer.count
                try checkVT(ghostty_render_state_row_cells_get(cellIterator, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, &buffer), "cell_text")
            }
            text = String(decoding: bytes.prefix(buffer.len), as: UTF8.self)
        } else {
            try checkVT(result, "cell_text")
        }
        // A spacer head is an empty narrow cell before a wrap; a tail must
        // remain width zero so the renderer never draws a second glyph.
        let width = wide == GHOSTTY_CELL_WIDE_WIDE ? 2 : (wide == GHOSTTY_CELL_WIDE_SPACER_TAIL ? 0 : 1)
        var background = color(style.bg_color)
        if background == .defaultColor {
            // Erased cells can carry color in packed content, not style.
            // Preserve palette identity so OSC 4 recolors even cached rows.
            var tag = GHOSTTY_CELL_CONTENT_CODEPOINT
            try checkVT(ghostty_cell_get(raw, GHOSTTY_CELL_DATA_CONTENT_TAG, &tag), "cell_content")
            if tag == GHOSTTY_CELL_CONTENT_BG_COLOR_PALETTE {
                var index: UInt8 = 0
                try checkVT(ghostty_cell_get(raw, GHOSTTY_CELL_DATA_COLOR_PALETTE, &index), "cell_background_palette")
                background = .palette(index)
            } else if tag == GHOSTTY_CELL_CONTENT_BG_COLOR_RGB {
                var rgb = GhosttyColorRgb()
                try checkVT(ghostty_cell_get(raw, GHOSTTY_CELL_DATA_COLOR_RGB, &rgb), "cell_background_rgb")
                background = .rgb(NativeRGB(rgb))
            }
        }
        var linked = false
        try checkVT(ghostty_cell_get(raw, GHOSTTY_CELL_DATA_HAS_HYPERLINK, &linked), "cell_link")
        let uri = linked ? try hyperlink(column: column, row: row, maximum: linkBudget) : nil
        linkBudget -= uri?.utf8.count ?? 0
        return .init(text: text, width: width, foreground: color(style.fg_color),
                     background: background, underlineColor: color(style.underline_color),
                     style: NativeCellStyle(rawValue: style.flags),
                     underline: UInt8((style.flags >> 8) & 7), hyperlink: uri,
                     hasExplicitHyperlink: linked, isWrapSpacer: wide == GHOSTTY_CELL_WIDE_SPACER_HEAD,
                     isImagePlaceholder: imagePlaceholderRow && text?.unicodeScalars.first?.value == 0x10EEEE)
    }

    private func color(_ value: GhosttyStyleColor) -> NativeCellColor {
        switch UInt32(value.tag) {
        case GHOSTTY_STYLE_COLOR_PALETTE.rawValue: return .palette(value.value.palette)
        case GHOSTTY_STYLE_COLOR_RGB.rawValue: return .rgb(NativeRGB(value.value.rgb))
        default: return .defaultColor
        }
    }
}

/// Borrowed by C, owned by the driver; touched only while its VT lock is held.
private final class VTCallbackState {
    let clock: @Sendable () -> TimeInterval
    var replies = Data()
    var heldSince: TimeInterval?
    var resetEpoch: UInt64 = 0
    let clipboard = NativeClipboardInbox()
    var size = GhosttySizeReportSize()
    init(clock: @escaping @Sendable () -> TimeInterval) { self.clock = clock }
}

private let vtWriteReply: GhosttyTerminalWritePtyFn = { _, userdata, bytes, count in
    guard let userdata, let bytes, count > 0 else { return }
    Unmanaged<VTCallbackState>.fromOpaque(userdata).takeUnretainedValue().replies.append(bytes, count: count)
}

private let vtRenderHold: GhosttyTerminalRenderHoldFn = { _, userdata, held in
    guard let userdata else { return }
    let state = Unmanaged<VTCallbackState>.fromOpaque(userdata).takeUnretainedValue()
    state.heldSince = held ? state.clock() : nil
}

private let vtReset: GhosttyTerminalResetFn = { _, userdata in
    guard let userdata else { return }
    let state = Unmanaged<VTCallbackState>.fromOpaque(userdata).takeUnretainedValue()
    state.resetEpoch &+= 1
    state.clipboard.clear()
}

private let vtClipboardWrite: GhosttyTerminalClipboardWriteFn = { _, userdata, request in
    guard let request else { return }
    var result = GHOSTTY_CLIPBOARD_WRITE_RESULT_DENIED
    if let userdata {
        let state = Unmanaged<VTCallbackState>.fromOpaque(userdata).takeUnretainedValue()
        result = state.clipboard.capture(request.pointee, now: state.clock())
    }
    var reply = GhosttyClipboardWriteReply()
    reply.size = MemoryLayout<GhosttyClipboardWriteReply>.size
    reply.result = result
    reply.remember = false
    request.pointee.reply?(request, &reply)
}

private let vtSize: GhosttyTerminalSizeFn = { _, userdata, size in
    guard let userdata, let size else { return false }
    size.pointee = Unmanaged<VTCallbackState>.fromOpaque(userdata).takeUnretainedValue().size
    return true
}

private extension NativeRGB {
    init(_ color: GhosttyColorRgb) {
        self.init(red: color.r, green: color.g, blue: color.b)
    }
}
