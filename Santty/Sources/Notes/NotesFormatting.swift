import AppKit
import Observation

enum NotesFormat: String, CaseIterable {
  case bold, italic, strikethrough, inlineCode, link, blockquote, codeBlock, unorderedList,
    orderedList, taskList

  var title: String {
    switch self {
    case .bold: "Bold"
    case .italic: "Italic"
    case .strikethrough: "Strikethrough"
    case .inlineCode: "Inline Code"
    case .link: "Insert Link"
    case .blockquote: "Blockquote"
    case .codeBlock: "Code Block"
    case .unorderedList: "Bulleted List"
    case .orderedList: "Numbered List"
    case .taskList: "Checklist"
    }
  }

  var symbol: String {
    switch self {
    case .bold: "bold"
    case .italic: "italic"
    case .strikethrough: "strikethrough"
    case .inlineCode: "chevron.left.forwardslash.chevron.right"
    case .link: "link"
    case .blockquote: "text.quote"
    case .codeBlock: "curlybraces"
    case .unorderedList: "list.bullet"
    case .orderedList: "list.number"
    case .taskList: "checklist"
    }
  }
}

@MainActor
@Observable
final class NotesFormatting {
  private(set) var active: Set<NotesFormat> = []
  private(set) var headingLevel = 0
  private(set) var canFormat = false
  @ObservationIgnored private weak var editor: NSTextView?
  @ObservationIgnored nonisolated(unsafe) private var selectionObserver: NSObjectProtocol?
  deinit {
    if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
  }

  func attach(_ editor: NSTextView) {
    if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
    (self.editor as? NotesTextView)?.formatting = nil
    self.editor = editor
    (editor as? NotesTextView)?.formatting = self
    selectionObserver = NotificationCenter.default.addObserver(
      forName: NSTextView.didChangeSelectionNotification, object: editor, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.refresh() }
    }
    refresh()
  }

  func refresh() {
    guard let editor else {
      canFormat = false
      return
    }
    canFormat = editor.isEditable && !editor.hasMarkedText()
    if #available(macOS 15.0, *), editor.isWritingToolsActive { canFormat = false }
    active = []
    headingLevel = 0
    let source = editor.string as NSString
    let position = min(editor.selectedRange().location, source.length)
    guard source.length > 0 else { return }
    let attributes =
      editor.textStorage?.attributes(at: min(position, source.length - 1), effectiveRange: nil)
      ?? [:]
    active = Set(
      (attributes[.notesFormats] as? [String] ?? []).compactMap(NotesFormat.init(rawValue:)))
    if active.contains(.codeBlock) { return }
    let line = source.substring(with: source.lineRange(for: NSRange(location: position, length: 0)))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if let match = line.range(of: "^#{1,6} ", options: .regularExpression) {
      headingLevel = line[match].filter { $0 == "#" }.count
    }
    if line.hasPrefix("> ") { active.insert(.blockquote) }
    if line.range(of: "^[-+*] \\[[ xX]\\] ", options: .regularExpression) != nil {
      active.insert(.taskList)
    } else if line.range(of: "^[-+*] ", options: .regularExpression) != nil {
      active.insert(.unorderedList)
    } else if line.range(of: "^[0-9]+[.)] ", options: .regularExpression) != nil {
      active.insert(.orderedList)
    }
  }

  func apply(_ action: NotesFormat, url: String? = nil) {
    guard let editor, isAvailable(editor) else { return }
    let selection = editor.selectedRange()
    let original = editor.string as NSString
    let selected = original.substring(with: selection)
    switch action {
    case .bold, .italic, .strikethrough, .inlineCode:
      let marker: String
      switch action {
      case .bold: marker = "**"
      case .italic: marker = "*"
      case .strikethrough: marker = "~~"
      default:
        let longest = selected.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
        marker = String(repeating: "`", count: longest + 1)
      }
      let count = marker.utf16.count
      let padded = NSRange(
        location: max(0, selection.location - count - 1), length: selection.length + (count + 1) * 2
      )
      let surrounding = NSRange(
        location: max(0, selection.location - count), length: selection.length + count * 2)
      if action == .inlineCode, selection.location >= count + 1,
        NSMaxRange(padded) <= original.length,
        original.substring(with: padded) == marker + " " + selected + " " + marker
      {
        replace(
          padded, with: selected,
          selection: NSRange(location: padded.location, length: selection.length), in: editor)
      } else if selection.location >= count, NSMaxRange(surrounding) <= original.length,
        original.substring(with: surrounding) == marker + selected + marker
      {
        replace(
          surrounding, with: selected,
          selection: NSRange(location: surrounding.location, length: selection.length), in: editor)
      } else {
        let padding =
          action == .inlineCode && (selected.hasPrefix("`") || selected.hasSuffix("`")) ? " " : ""
        let prefix = marker + padding
        replace(
          selection, with: prefix + selected + padding + marker,
          selection: NSRange(
            location: selection.location + prefix.utf16.count, length: selection.length), in: editor
        )
      }
      return
    case .link:
      guard let url else { return }
      let destination = url.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "(", with: "\\(")
        .replacingOccurrences(of: ")", with: "\\)")
      let replacement = "[" + selected + "](" + destination + ")"
      replace(
        selection, with: replacement,
        selection: NSRange(location: selection.location + replacement.utf16.count, length: 0),
        in: editor)
      return
    case .codeBlock:
      let longest = selected.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
      let fence = String(repeating: "`", count: max(3, longest + 1))
      let leading =
        selection.location > 0 && original.character(at: selection.location - 1) != 10 ? "\n" : ""
      let replacement =
        leading + fence + "\n" + selected + (selected.hasSuffix("\n") ? "" : "\n") + fence + "\n"
      replace(
        selection, with: replacement,
        selection: NSRange(
          location: selection.location + (leading + fence + "\n").utf16.count,
          length: selection.length), in: editor)
      return
    case .blockquote, .unorderedList, .orderedList, .taskList:
      applyParagraph(action, heading: nil, in: editor)
      return
    }
  }

  func applyHeading(_ level: Int) {
    guard (0...6).contains(level), let editor, isAvailable(editor) else { return }
    applyParagraph(nil, heading: level, in: editor)
  }

  private func isAvailable(_ editor: NSTextView) -> Bool {
    guard editor.isEditable, !editor.hasMarkedText() else { return false }
    if #available(macOS 15.0, *), editor.isWritingToolsActive { return false }
    return true
  }

  private func applyParagraph(_ action: NotesFormat?, heading: Int?, in editor: NSTextView) {
    let source = editor.string as NSString
    var selection = editor.selectedRange()
    if selection.length > 0, NSMaxRange(selection) > 0,
      source.character(at: NSMaxRange(selection) - 1) == 10
    {
      selection.length -= 1
    }
    let range = source.lineRange(for: selection)
    let lines = source.substring(with: range).components(separatedBy: "\n")
    let pattern: String
    switch action {
    case .blockquote: pattern = "^([ \\t]*)(> )"
    case .taskList: pattern = "^([ \\t]*)([-+*] \\[[ xX]\\] )"
    case .unorderedList: pattern = "^([ \\t]*)([-+*] (?!\\[[ xX]\\] ))"
    case .orderedList: pattern = "^([ \\t]*)([0-9]+[.)] )"
    default: pattern = "^([ \\t]*)(#{1,6} )"
    }
    let nonemptyLines = lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    let allMatch =
      !nonemptyLines.isEmpty
      && nonemptyLines.allSatisfy { $0.range(of: pattern, options: .regularExpression) != nil }
    let remove = heading == 0 || (heading == nil && allMatch)
    var number = 0
    let replacement = lines.enumerated().map { index, line -> String in
      if line.isEmpty && index == lines.count - 1 && range.length > 0 { return line }
      let indent = String(line.prefix { $0 == " " || $0 == "\t" })
      let stripPattern =
        heading != nil
        ? "^#{1,6} " : action == .blockquote ? "^> " : "^(?:[-+*] (?:\\[[ xX]\\] )?|[0-9]+[.)] )"
      let content = String(line.dropFirst(indent.count)).replacingOccurrences(
        of: stripPattern, with: "", options: .regularExpression)
      if remove { return indent + content }
      number += 1
      let prefix: String
      if let heading {
        prefix = String(repeating: "#", count: heading) + " "
      } else {
        switch action {
        case .blockquote: prefix = "> "
        case .unorderedList: prefix = "- "
        case .orderedList: prefix = "\(number). "
        default: prefix = "- [ ] "
        }
      }
      return indent + prefix + content
    }.joined(separator: "\n")
    let length = replacement.utf16.count
    let prefixDelta =
      (replacement.components(separatedBy: "\n").first?.utf16.count ?? 0)
      - (lines.first?.utf16.count ?? 0)
    let newSelection =
      editor.selectedRange().length == 0
      ? NSRange(
        location: max(
          range.location, min(range.location + length, selection.location + prefixDelta)), length: 0
      )
      : NSRange(location: range.location, length: length)
    replace(range, with: replacement, selection: newSelection, in: editor)
  }

  private func replace(
    _ range: NSRange, with text: String, selection: NSRange, in editor: NSTextView
  ) {
    guard editor.shouldChangeText(in: range, replacementString: text) else { return }
    editor.breakUndoCoalescing()
    editor.textStorage?.replaceCharacters(in: range, with: text)
    editor.didChangeText()
    editor.setSelectedRange(selection)
    editor.breakUndoCoalescing()
    refresh()
  }
}

extension NSTextView {
  var notesScrollView: NSScrollView? {
    var ancestor = superview
    while let view = ancestor {
      if let scroll = view as? NSScrollView { return scroll }
      ancestor = view.superview
    }
    return nil
  }
}
