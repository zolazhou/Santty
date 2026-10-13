import AppKit

@MainActor
final class HerdrHistoryView: NSView {
    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 720, height: 480))
    private let notice = NSTextField(wrappingLabelWithString: "Loading recent history…")
    private var selecting = false
    override var isOpaque: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = textView
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        applySettings()
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        notice.font = .systemFont(ofSize: 11)
        let stack = NSStackView(views: [notice, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        setAccessibilityLabel("Persistent terminal recent history snapshot")
    }
    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    func load(_ read: HerdrReadResult, paneID: UUID) throws {
        let response = try CLITextSnapshot.response(read.text, request: .init(command: "read", paneID: paneID, tail: 1000))
        textView.string = response.text ?? ""
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
        notice.stringValue = "Recent history · frozen snapshot · at most 1000 rows / 256 KiB\(read.truncated || response.truncated == true ? " · older text omitted" : ""). Inline images and live cross-history selection are unavailable."
        textView.scrollRangeToVisible(textView.selectedRange())
    }
    func showError(_ message: String) { notice.stringValue = message }
    func applySettings() {
        textView.font = NSFont(name: TerminalSettings.fontFamily, size: TerminalSettings.fontSize) ?? .monospacedSystemFont(ofSize: TerminalSettings.fontSize, weight: .regular)
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) { NSColor.textBackgroundColor.setFill(); dirtyRect.fill() }

    func move(_ movement: TerminalScrollMovement) {
        let action: String
        // shortcut: Cocoa line/word/page motions approximate Vim; add exact motions before claiming parity.
        switch movement {
        case .left: action = "moveLeft"
        case .right: action = "moveRight"
        case .up: action = "moveUp"
        case .down: action = "moveDown"
        case .lineStart, .firstNonblank: action = "moveToBeginningOfLine"
        case .lineEnd: action = "moveToEndOfLine"
        case .top: action = "moveToBeginningOfDocument"
        case .bottom: action = "moveToEndOfDocument"
        case .pageUp, .halfUp: action = "pageUp"
        case .pageDown, .halfDown: action = "pageDown"
        case .wordForward, .wordEnd: action = "moveWordForward"
        case .wordBackward: action = "moveWordBackward"
        }
        let selector = NSSelectorFromString(action + (selecting ? "AndModifySelection:" : ":"))
        if textView.responds(to: selector) { textView.perform(selector, with: nil) }
        textView.scrollRangeToVisible(textView.selectedRange())
    }
    func toggleSelection(linewise: Bool) {
        selecting.toggle()
        if selecting, linewise { textView.selectLine(nil) }
        else if !selecting { _ = cancelSelection() }
    }
    @discardableResult func cancelSelection() -> Bool {
        let hadSelection = selecting || textView.selectedRange().length > 0
        selecting = false
        textView.setSelectedRange(NSRange(location: textView.selectedRange().location, length: 0))
        return hadSelection
    }
    func copy(to pasteboard: NSPasteboard = .general) {
        let range = textView.selectedRange()
        guard range.length > 0 else { return }
        pasteboard.clearContents()
        pasteboard.setString((textView.string as NSString).substring(with: range), forType: .string)
    }
}
