import AppKit
import SwiftUI

struct NotesNativeEditor: NSViewRepresentable {
  @Binding var text: String
  var isEditable: Bool
  var bottomBarHeight: CGFloat
  let documentID: String

  func makeNSView(context: Context) -> NotesTextView {
    let editor = NotesTextView(usingTextLayoutManager: true)
    editor.configure()
    editor.documentID = documentID
    editor.modelText = text
    editor.string = text
    editor.onTextChange = { text = $0 }
    editor.isEditable = isEditable
    editor.bottomBarHeight = bottomBarHeight
    editor.renderer.render(force: true)
    return editor
  }

  func updateNSView(_ editor: NotesTextView, context: Context) {
    guard editor.documentID == documentID else { return }
    editor.onTextChange = { text = $0 }
    editor.isEditable = isEditable
    editor.bottomBarHeight = bottomBarHeight
    if editor.modelText != text, !editor.hasMarkedText(), !editor.notesWritingToolsActive {
      editor.modelText = text
      if editor.string != text {
        let selection = editor.selectedRange()
        editor.undoManager?.removeAllActions()
        editor.string = text
        editor.setSelectedRange(
          NSRange(location: min(selection.location, text.utf16.count),
                  length: min(selection.length, max(0, text.utf16.count - selection.location))))
      }
      editor.renderer.render(force: true)
    }
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NotesTextView, context: Context)
    -> CGSize?
  {
    let width = proposal.width ?? nsView.bounds.width
    guard width > 0 else { return nil }
    return CGSize(width: width, height: nsView.contentHeight(for: width))
  }

  static func dismantleNSView(_ editor: NotesTextView, coordinator: ()) {
    editor.onTextChange = nil
  }
}

@MainActor
final class NotesTextView: NSTextView, NSTextViewDelegate, NSTextStorageDelegate {
  private let documentUndo = UndoManager()
  private(set) var renderer: NotesMarkdownRenderer!
  var onTextChange: ((String) -> Void)?
  var onFocus: (() -> Void)?
  weak var formatting: NotesFormatting?
  var documentID = ""
  var modelText = ""
  var bottomBarHeight = NotesLayout.footerHeight {
    didSet {
      if #unavailable(macOS 26.0) {
        textContainerInset.height = max(NotesLayout.titleBarHeight, bottomBarHeight) + 20
        invalidateIntrinsicContentSize()
      }
    }
  }
  private var pendingUpdate = false
  private var isMeasuring = false
  private(set) var isSelectingWithMouse = false
  nonisolated(unsafe) private var undoObservers: [NSObjectProtocol] = []
  nonisolated(unsafe) private var appearanceObserver: NSObjectProtocol?
  override var undoManager: UndoManager? { documentUndo }
  var notesWritingToolsActive: Bool {
    if #available(macOS 15.0, *) { return isWritingToolsActive }
    return false
  }

  func configure() {
    appearanceObserver = NotificationCenter.default.addObserver(
      forName: AppAppearanceSettings.didChangeNotification, object: nil, queue: nil
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.insertionPointColor = AppAppearanceSettings.accentColor
        self?.renderer.render(force: true)
      }
    }
    undoObservers = [
      Notification.Name.NSUndoManagerDidUndoChange, Notification.Name.NSUndoManagerDidRedoChange,
    ].map { name in
      NotificationCenter.default.addObserver(forName: name, object: documentUndo, queue: .main) {
        [weak self] _ in
        MainActor.assumeIsolated {
          self?.publishAndRender()
          self?.window?.contentView?.layoutSubtreeIfNeeded()
        }
      }
    }
    delegate = self
    textStorage?.delegate = self
    renderer = NotesMarkdownRenderer(editor: self)
    textLayoutManager?.delegate = renderer
    isRichText = false
    importsGraphics = false
    allowsUndo = true
    drawsBackground = false
    backgroundColor = .clear
    font = NotesMarkdownRenderer.bodyFont
    textColor = .labelColor
    insertionPointColor = AppAppearanceSettings.accentColor
    isContinuousSpellCheckingEnabled = true
    isGrammarCheckingEnabled = true
    isAutomaticSpellingCorrectionEnabled = true
    isAutomaticQuoteSubstitutionEnabled = false
    isAutomaticDashSubstitutionEnabled = false
    isAutomaticTextReplacementEnabled = true
    isAutomaticLinkDetectionEnabled = false
    isAutomaticDataDetectionEnabled = false
    isAutomaticTextCompletionEnabled = true
    if #available(macOS 15.0, *) { writingToolsBehavior = .complete }
    textContainerInset = NSSize(width: 24, height: 20)
    if #unavailable(macOS 26.0) { textContainerInset.height += NotesLayout.titleBarHeight }
    textContainer?.lineFragmentPadding = 0
    textContainer?.widthTracksTextView = false
    textContainer?.heightTracksTextView = false
    isHorizontallyResizable = false
    isVerticallyResizable = false
    maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    setAccessibilityLabel("Notes editor")
  }

  deinit {
    if let appearanceObserver { NotificationCenter.default.removeObserver(appearanceObserver) }
    for observer in undoObservers { NotificationCenter.default.removeObserver(observer) }
  }

  private func replaceSource(_ range: NSRange, with replacement: String, selection: NSRange) {
    breakUndoCoalescing()
    guard shouldChangeText(in: range, replacementString: replacement) else { return }
    textStorage?.replaceCharacters(in: range, with: replacement)
    didChangeText()
    setSelectedRange(selection)
    breakUndoCoalescing()
  }

  func contentHeight(for width: CGFloat) -> CGFloat {
    guard let container = textContainer, let layout = textLayoutManager, !isMeasuring else {
      return max(1, bounds.height)
    }
    isMeasuring = true
    defer { isMeasuring = false }
    container.size = NSSize(
      width: max(1, width - textContainerInset.width * 2), height: CGFloat.greatestFiniteMagnitude)
    layout.ensureLayout(for: layout.documentRange)
    return ceil(
      max(24, layout.usageBoundsForTextContainer.maxY) + textContainerInset.height * 2 + 24)
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: contentHeight(for: max(1, bounds.width)))
  }

  override func setFrameSize(_ newSize: NSSize) {
    let changed = bounds.width != newSize.width
    super.setFrameSize(newSize)
    if changed {
      textContainer?.size.width = max(1, newSize.width - textContainerInset.width * 2)
      invalidateIntrinsicContentSize()
    }
  }

  func textDidChange(_ notification: Notification) {
    publishAndRender()
    scheduleUpdate()
  }

  func textViewDidChangeSelection(_ notification: Notification) {
    scheduleUpdate()
  }

  @available(macOS 15.0, *)
  func textViewWritingToolsDidEnd(_ textView: NSTextView) {
    scheduleUpdate()
  }

  nonisolated func textStorage(
    _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
    range editedRange: NSRange, changeInLength delta: Int
  ) {
    if editedMask.contains(.editedCharacters) {
      MainActor.assumeIsolated { scheduleUpdate() }
    }
  }

  private func publishAndRender() {
    guard !hasMarkedText(), !notesWritingToolsActive else { return }
    renderer.render()
    formatting?.refresh()
    modelText = string
    onTextChange?(string)
    invalidateIntrinsicContentSize()
  }

  private func scheduleUpdate() {
    guard !pendingUpdate else { return }
    pendingUpdate = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.pendingUpdate = false
      self.publishAndRender()
      self.window?.contentView?.layoutSubtreeIfNeeded()
      if self.window?.firstResponder === self, !self.hasMarkedText(), !self.notesWritingToolsActive,
        !self.isSelectingWithMouse
      {
        self.scrollRangeToVisible(self.selectedRange())
      }
    }
  }

  override func becomeFirstResponder() -> Bool {
    let result = super.becomeFirstResponder()
    if result { onFocus?() }
    scheduleUpdate()
    return result
  }

  override func resignFirstResponder() -> Bool {
    let result = super.resignFirstResponder()
    DispatchQueue.main.async { [weak self] in self?.renderer.render() }
    return result
  }

  override func unmarkText() {
    super.unmarkText()
    scheduleUpdate()
  }

  override func scrollRangeToVisible(_ range: NSRange) {
    guard !hasMarkedText(), !notesWritingToolsActive, let layout = textLayoutManager,
      let content = layout.textContentManager, let scroll = notesScrollView,
      let document = scroll.documentView,
      let start = content.location(
        layout.documentRange.location, offsetBy: min(range.location, string.utf16.count))
    else { return }
    let caret = NSTextRange(location: start)
    layout.ensureLayout(for: caret)
    layout.enumerateTextSegments(in: caret, type: .standard, options: [.rangeNotRequired]) {
      _, frame, _, _ in
      guard frame.height > 0 else { return false }
      let rect = document.convert(
        frame.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y), from: self)
      let padding: CGFloat = 8
      document.scrollToVisible(
        CGRect(
          x: rect.minX - 1, y: rect.minY - NotesLayout.titleBarHeight - padding, width: max(2, rect.width + 2),
          height: rect.height + NotesLayout.titleBarHeight + self.bottomBarHeight + padding * 2))
      return false
    }
  }

  override func mouseDown(with event: NSEvent) {
    guard isEditable, !hasMarkedText(), !notesWritingToolsActive, let layout = textLayoutManager
    else {
      super.mouseDown(with: event)
      return
    }
    let point = convert(event.locationInWindow, from: nil)
    let inContainer = CGPoint(
      x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
    renderer.render()
    layout.ensureLayout(for: layout.documentRange)
    var hit: (Bool, NSRange)?
    layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: []) {
      fragment in
      guard let fragment = fragment as? NotesLayoutFragment,
        case .task(let checked, let state) = fragment.decoration.kind
      else { return true }
      let box = fragment.checkboxRect.offsetBy(
        dx: fragment.layoutFragmentFrame.minX, dy: fragment.layoutFragmentFrame.minY)
      if box.insetBy(dx: -4, dy: -4).contains(inContainer) {
        hit = (checked, state)
        return false
      }
      return true
    }
    if let (checked, range) = hit {
      let selection = selectedRange()
      replaceSource(range, with: checked ? " " : "x", selection: selection)
      return
    }
    isSelectingWithMouse = true
    defer {
      isSelectingWithMouse = false
      scheduleUpdate()
    }
    super.mouseDown(with: event)
  }

  override func insertNewline(_ sender: Any?) {
    breakUndoCoalescing()
    defer { breakUndoCoalescing() }
    guard !hasMarkedText(), !notesWritingToolsActive, selectedRange().length == 0 else {
      super.insertNewline(sender)
      return
    }
    let source = string as NSString
    let selection = selectedRange()
    let lineRange = source.lineRange(for: selection)
    let beforeCaret = source.substring(
      with: NSRange(location: lineRange.location, length: selection.location - lineRange.location))
    if source.length > 0,
      let decoration = textStorage?.attribute(
        .notesDecoration, at: min(selection.location, source.length - 1), effectiveRange: nil)
        as? NotesBlockDecoration,
      case .code = decoration.kind
    {
      super.insertNewline(sender)
      return
    }
    let pattern = "^([ \\t]*)([-+*] +(?:\\[[ xX]\\] +)?|[0-9]+[.)] +|> +)"
    guard let expression = try? NSRegularExpression(pattern: pattern),
      let match = expression.firstMatch(
        in: beforeCaret, range: NSRange(location: 0, length: beforeCaret.utf16.count))
    else {
      super.insertNewline(sender)
      return
    }
    let prefix = (beforeCaret as NSString).substring(with: match.range)
    if prefix.utf16.count == beforeCaret.utf16.count {
      replaceSource(
        NSRange(location: lineRange.location, length: prefix.utf16.count), with: "",
        selection: NSRange(location: lineRange.location, length: 0))
      return
    }
    var next = prefix.replacingOccurrences(
      of: "\\[[xX]\\]", with: "[ ]", options: .regularExpression)
    if let digits = next.range(of: "[0-9]+", options: .regularExpression),
      let number = Int(next[digits]), number < Int.max
    {
      next.replaceSubrange(digits, with: String(number + 1))
    }
    let replacement = "\n" + next
    replaceSource(
      selection, with: replacement,
      selection: NSRange(location: selection.location + replacement.utf16.count, length: 0))
  }
}
