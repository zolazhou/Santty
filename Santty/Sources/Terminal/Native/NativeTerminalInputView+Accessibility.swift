import AppKit

/// Read-only navigable terminal output. Queries use the owned published page;
/// they never sample VT, scroll/reveal output, set selection or send input.
@MainActor
extension NativeTerminalInputView {
    override func isAccessibilityElement() -> Bool { !isHiddenOrHasHiddenAncestor }
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override func accessibilityLabel() -> String? { "Terminal" }
    override func accessibilityHelp() -> String? {
        accessibleTerminal.limited ? "Terminal text is unavailable within the bounded accessibility snapshot."
            : "Read-only terminal text window. Scroll to read other history."
    }
    override func accessibilityValue() -> Any? { accessibleTerminal.text }
    override func accessibilityNumberOfCharacters() -> Int { accessibleTerminal.length }
    override func accessibilitySelectedTextRange() -> NSRange { accessibleTerminal.selectedRange }
    override func accessibilitySelectedTextRanges() -> [NSValue]? {
        accessibleTerminal.valid(accessibleTerminal.selectedRange) ? [NSValue(range: accessibleTerminal.selectedRange)] : []
    }
    override func accessibilitySelectedText() -> String? { accessibleTerminal.string(accessibleTerminal.selectedRange) }
    override func accessibilityInsertionPointLineNumber() -> Int {
        guard let cursor = accessibleTerminal.cursor else { return -1 }
        return accessibleTerminal.lines.firstIndex { $0.row == cursor.row } ?? -1
    }
    override func accessibilityVisibleCharacterRange() -> NSRange {
        accessibleTerminal.visibleRange(topRow: accessibleTopRow, cell: cellSize, height: bounds.height, clip: visibleRect)
    }
    override func accessibilityString(for range: NSRange) -> String? { accessibleTerminal.string(range) }
    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        accessibleTerminal.string(range).map { NSAttributedString(string: $0, attributes: [.font: font]) }
    }
    override func accessibilityRange(for index: Int) -> NSRange { accessibleTerminal.range(at: index) }
    override func accessibilityRange(forLine line: Int) -> NSRange { accessibleTerminal.rangeForLine(line) }
    override func accessibilityLine(for index: Int) -> Int { accessibleTerminal.line(for: index) }
    override func accessibilityRange(for point: NSPoint) -> NSRange {
        guard point.x.isFinite, point.y.isFinite, let window else { return NativeTerminalAccessibility.missing }
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        guard visibleRect.contains(local), cellSize.width > 0, cellSize.height > 0 else { return NativeTerminalAccessibility.missing }
        let row = accessibleTopRow + Int(floor((bounds.maxY - local.y) / cellSize.height))
        let column = Int(floor(local.x / cellSize.width))
        return accessibleTerminal.range(row: row, column: column)
    }
    override func accessibilityFrame(for range: NSRange) -> NSRect {
        guard let window else { return .zero }
        let rect = accessibleTerminal.bounds(for: range, topRow: accessibleTopRow, cell: cellSize, height: bounds.height, clip: visibleRect)
        guard !rect.isEmpty else { return .zero }
        return window.convertToScreen(convert(rect, to: nil))
    }
    override func accessibilityFrame() -> NSRect {
        guard let window, !visibleRect.isEmpty else { return .zero }
        return window.convertToScreen(convert(visibleRect, to: nil))
    }
    override func accessibilityChildren() -> [Any]? { [] } // no Metal/preedit duplicate text elements
    override func isAccessibilityFocused() -> Bool { window?.firstResponder === self }
    override func setAccessibilityValue(_ value: Any?) {} // no input/paste path
    override func setAccessibilitySelectedText(_ text: String?) {}
    override func setAccessibilitySelectedTextRange(_ range: NSRange) {}
    override func setAccessibilitySelectedTextRanges(_ ranges: [NSValue]?) {}
    override func setAccessibilityFocused(_ focused: Bool) {}
    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        if NSStringFromSelector(selector).hasPrefix("setAccessibility") { return false }
        return super.isAccessibilitySelectorAllowed(selector)
    }
}
