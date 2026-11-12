import AppKit
import GhosttyVt
import SwiftTerm

/// Minimal AppKit/IME layer, following SwiftTerm's NSTextInputClient split.
/// KeyboardRouter also emits legacy bytes on several paths; rather than mix
/// encoders, this prototype forwards semantic events only to Ghostty.
@MainActor
final class NativeTerminalInputView: TerminalRenderView, @MainActor NSTextInputClient {
    var output: NativeTerminalOutput?
    var inputEnabled = false {
        didSet {
            if !inputEnabled {
                resetInputState()
                let wasFocused = hasFocus
                hasFocus = false
                if wasFocused { onFocusChange?(false) }
            }
        }
    }
    var onFocusChange: ((Bool) -> Void)?
    var onInputActivity: (() -> Void)?
    var onPointerEvent: ((NSEvent) -> Bool)?
    var onPointerModifiersChanged: ((NSEvent.ModifierFlags) -> Void)?
    var linkCursorRects: [NSRect] = [] {
        didSet { if oldValue != linkCursorRects { window?.invalidateCursorRects(for: self) } }
    }
    private var modifierMonitor: Any?
    var onWheelEvent: ((NSEvent) -> Void)?
    var onInputReset: (() -> Void)?
    var onCopySelection: (() -> Bool)?
    var onSelectAll: (() -> Void)?
    private var pointerTracking: NSTrackingArea?
    var cursorCell = (column: 0, row: 0) { didSet { positionPreedit() } }
    private var pendingKey: NSEvent?
    private var interpreted = false
    var optionBehavior: NativeOptionBehavior = .text { didSet { resetInputState() } }
    private var keys = NativeKeySequence()
    private var marked = NSAttributedString(string: "")
    private var markedSelection = NSRange(location: 0, length: 0)
    private let preedit = NSTextField(labelWithString: "")

    override var acceptsFirstResponder: Bool { inputEnabled || onPointerEvent != nil }

    isolated deinit {
        if let modifierMonitor { NSEvent.removeMonitor(modifierMonitor) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let modifierMonitor { NSEvent.removeMonitor(modifierMonitor); self.modifierMonitor = nil }
        if window != nil {
            // Hover remains usable when a toolbar, rather than this view, is
            // first responder. Local observation only; never consume/repost keys.
            modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                guard let self, event.window === self.window, self.window?.isKeyWindow == true else { return event }
                self.onPointerModifiersChanged?(event.modifierFlags)
                return event
            }
        }
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        if let window {
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(refreshFocus), name: name, object: window)
            }
        }
        refreshFocus()
    }

    @objc func refreshFocus() {
        let focused = inputEnabled && window?.isKeyWindow == true && window?.firstResponder === self
        guard focused != hasFocus else { return }
        hasFocus = focused
        if !focused { resetInputState() }
        try? output?.setFocused(focused)
        onFocusChange?(focused)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        _ = onPointerEvent?(event)
    }
    override func mouseUp(with event: NSEvent) { _ = onPointerEvent?(event) }
    override func mouseDragged(with event: NSEvent) { _ = onPointerEvent?(event) }
    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if onPointerEvent?(event) != true { super.rightMouseDown(with: event) }
    }
    override func rightMouseUp(with event: NSEvent) { _ = onPointerEvent?(event) }
    override func rightMouseDragged(with event: NSEvent) { _ = onPointerEvent?(event) }
    override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        _ = onPointerEvent?(event)
    }
    override func otherMouseUp(with event: NSEvent) { _ = onPointerEvent?(event) }
    override func otherMouseDragged(with event: NSEvent) { _ = onPointerEvent?(event) }
    override func mouseMoved(with event: NSEvent) { _ = onPointerEvent?(event) }
    override func mouseEntered(with event: NSEvent) { _ = onPointerEvent?(event) }
    override func mouseExited(with event: NSEvent) { _ = onPointerEvent?(event) }
    override func resetCursorRects() {
        super.resetCursorRects()
        for rect in linkCursorRects { addCursorRect(rect, cursor: .pointingHand) }
    }
    override func scrollWheel(with event: NSEvent) {
        if let onWheelEvent { onWheelEvent(event) } else { super.scrollWheel(with: event) }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); pointerTracking = area
    }

    override func becomeFirstResponder() -> Bool {
        guard acceptsFirstResponder else { return false }
        let focused = inputEnabled && window?.isKeyWindow == true
        hasFocus = focused
        if focused { try? output?.setFocused(true) }
        onFocusChange?(focused)
        return true
    }

    override func resignFirstResponder() -> Bool {
        resetInputState()
        let wasFocused = hasFocus
        hasFocus = false
        if wasFocused { try? output?.setFocused(false) }
        onFocusChange?(false)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard inputEnabled else { return }
        if event.modifierFlags.contains(.command) { super.keyDown(with: event); return }
        onInputActivity?()
        // Cocoa text-editing bindings can consume terminal shortcuts (for
        // example Ctrl+[) without producing an insertText/doCommand callback.
        // Keep active composition with the IME; otherwise Ghostty owns Ctrl.
        if event.modifierFlags.contains(.control), !hasMarkedText() {
            send(event)
            return
        }
        pendingKey = event
        interpreted = false
        defer { pendingKey = nil }
        interpretKeyEvents([event])
        if !interpreted, !hasMarkedText() { send(event) }
    }

    override func keyUp(with event: NSEvent) {
        guard inputEnabled else { return }
        let current = NativeKeyNormalizer.normalize(.init(event: event, action: GHOSTTY_KEY_ACTION_RELEASE), option: optionBehavior)
        guard let release = keys.release(current) else { return }
        _ = try? output?.send(release)
    }

    override func flagsChanged(with event: NSEvent) {
        onPointerModifiersChanged?(event.modifierFlags)
        guard inputEnabled, !hasMarkedText(),
              ((try? output?.driver.keyboardModes.kittyFlags) ?? 0) & UInt8(GHOSTTY_KITTY_KEY_REPORT_ALL) != 0,
              let down = NativeKeySnapshot.modifierIsDown(event) else { return }
        if down { send(event, action: GHOSTTY_KEY_ACTION_PRESS) }
        else { keyUp(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            if event.charactersIgnoringModifiers?.lowercased() == "c", let onCopySelection { return onCopySelection() }
            if event.charactersIgnoringModifiers?.lowercased() == "a", let onSelectAll { onSelectAll(); return true }
        }
        if inputEnabled, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "v" {
            paste(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    @objc func paste(_ sender: Any?) {
        guard inputEnabled, let text = NSPasteboard.general.string(forType: .string) else { return }
        clearComposition()
        onInputActivity?()
        _ = try? output?.paste(text)
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard inputEnabled else { return }
        interpreted = true
        let text = (string as? NSAttributedString)?.string ?? (string as? String ?? "")
        let wasComposing = hasMarkedText()
        clearComposition()
        guard !text.isEmpty else { return }
        // Like SwiftTerm, a delete which only ends preedit must not also
        // delete terminal input. Real control shortcuts still use VT modes.
        if wasComposing, text == "\u{8}" || text == "\u{7F}" { return }
        let control = text.unicodeScalars.count == 1 && NativeKeyNormalizer.printable(text) == nil
        if let event = pendingKey, !wasComposing || control {
            send(event, text: text)
        } else {
            _ = try? output?.sendText(text)
        }
        resetCaretBlink()
    }

    override func doCommand(by selector: Selector) {
        interpreted = true
        guard inputEnabled, !hasMarkedText(), let event = pendingKey else { return }
        send(event)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard inputEnabled else { return }
        interpreted = true
        marked = (string as? NSAttributedString) ?? NSAttributedString(string: string as? String ?? "")
        guard marked.length > 0 else { clearComposition(); return }
        markedSelection = selectedRange
        preedit.stringValue = marked.string
        preedit.font = font
        preedit.textColor = nativeForegroundColor
        preedit.backgroundColor = nativeBackgroundColor
        preedit.drawsBackground = true
        if preedit.superview == nil { addSubview(preedit) }
        positionPreedit()
    }

    func unmarkText() { clearComposition() }
    func hasMarkedText() -> Bool { marked.length > 0 }
    func markedRange() -> NSRange { NSRange(location: hasMarkedText() ? 0 : NSNotFound, length: marked.length) }
    func selectedRange() -> NSRange { hasMarkedText() ? markedSelection : NSRange(location: NSNotFound, length: 0) }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [.underlineStyle, .foregroundColor] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = range
        let cell = rect(column: cursorCell.column, row: cursorCell.row)
        return window?.convertToScreen(convert(cell, to: nil)) ?? .zero
    }

    func clearComposition() {
        marked = NSAttributedString(string: "")
        markedSelection = NSRange(location: 0, length: 0)
        preedit.removeFromSuperview()
    }

    private func positionPreedit() {
        guard hasMarkedText() else { return }
        let cell = rect(column: cursorCell.column, row: cursorCell.row)
        preedit.frame = NSRect(x: cell.minX, y: cell.minY,
                              width: max(cell.width, preedit.intrinsicContentSize.width),
                              height: cell.height)
    }

    func resetInputState() {
        let wasComposing = hasMarkedText()
        pendingKey = nil
        interpreted = true
        keys.reset()
        onInputReset?()
        clearComposition()
        if wasComposing { inputContext?.discardMarkedText() }
    }

    private func send(_ event: NSEvent, text: String? = nil,
                      action: GhosttyKeyAction? = nil) {
        let value = NativeKeyNormalizer.normalize(.init(event: event, text: text,
            composing: hasMarkedText(), action: action), option: optionBehavior)
        guard keys.accepts(value), !value.composing else { return }
        if (try? output?.send(value.input)) == true {
            keys.delivered(value, reportsRelease: !value.isTextInput)
            if value.action != GHOSTTY_KEY_ACTION_RELEASE { resetCaretBlink() }
        }
    }
}
