import AppKit
import Markdown

extension NSAttributedString.Key {
  static let notesDecoration = NSAttributedString.Key("Santty.NotesDecoration")
  static let notesFormats = NSAttributedString.Key("Santty.NotesFormats")
}

final class NotesBlockDecoration: NSObject {
  enum Kind {
    case bullet
    case number(String)
    case task(Bool, NSRange)
    case quote, code, rule
  }
  let kind: Kind
  let indent: CGFloat
  let accentColor: NSColor

  @MainActor
  init(_ kind: Kind, indent: CGFloat = 0) {
    self.kind = kind
    self.indent = indent
    self.accentColor = AppAppearanceSettings.accentColor
  }
}

// swift-markdown reports UTF-8 columns; AppKit edits and selections use UTF-16.
struct NotesSourceMap {
  let source: NSString
  private let lineStarts: [Int]
  private let offsets: [Int]

  init(_ text: String) {
    source = text as NSString
    var starts = [0]
    var mapping = [Int]()
    var utf16 = 0
    var byteOffset = 0
    var previousCR = false
    for scalar in text.unicodeScalars {
      if scalar.value == 10 {
        if previousCR { starts.removeLast() }
        starts.append(byteOffset + 1)
      } else if scalar.value == 13 {
        starts.append(byteOffset + 1)
      }
      let bytes = scalar.utf8.count
      mapping.append(contentsOf: repeatElement(utf16, count: bytes))
      byteOffset += bytes
      utf16 += scalar.utf16.count
      previousCR = scalar.value == 13
    }
    mapping.append(utf16)
    lineStarts = starts
    offsets = mapping
  }

  func offset(_ location: SourceLocation) -> Int? {
    guard location.line > 0, location.line <= lineStarts.count, location.column > 0 else {
      return nil
    }
    let byte = lineStarts[location.line - 1] + location.column - 1
    let end = location.line < lineStarts.count ? lineStarts[location.line] : offsets.count - 1
    guard byte <= end, byte < offsets.count else { return nil }
    return offsets[byte]
  }

  func range(_ sourceRange: SourceRange?) -> NSRange? {
    guard let sourceRange, let start = offset(sourceRange.lowerBound),
      let end = offset(sourceRange.upperBound), end >= start
    else { return nil }
    return NSRange(location: start, length: end - start)
  }
}

@MainActor
final class NotesMarkdownRenderer: NSObject, NSTextLayoutManagerDelegate {
  static let bodyFont = NSFont.systemFont(ofSize: 16)
  private weak var editor: NotesTextView?
  private var source = ""
  private var document = Document(parsing: "")
  private var map = NotesSourceMap("")
  private var revealed: NSRange?
  private(set) var isRendering = false

  init(editor: NotesTextView) {
    self.editor = editor
    super.init()
  }

  func render(force: Bool = false) {
    guard let editor, let storage = editor.textStorage, !isRendering,
      !editor.hasMarkedText(), !editor.isSelectingWithMouse
    else { return }
    if #available(macOS 15.0, *), editor.isWritingToolsActive { return }
    let changed = source != editor.string
    if changed {
      source = editor.string
      map = NotesSourceMap(source)
      document = Document(parsing: source)
    }
    let selection = editor.selectedRange()
    let currentSelection =
      editor.isEditable && editor.window?.firstResponder === editor
      ? NSRange(
        location: min(selection.location, map.source.length),
        length: min(selection.length, max(0, map.source.length - selection.location)))
      : nil
    guard force || changed || currentSelection != revealed else { return }
    revealed = currentSelection
    isRendering = true
    defer { isRendering = false }
    // shortcut: restyle the document using the cached AST; narrow this to affected blocks if large notes become slow.
    storage.beginEditing()
    let whole = NSRange(location: 0, length: storage.length)
    for key: NSAttributedString.Key in [
      .font, .foregroundColor, .paragraphStyle, .link, .strikethroughStyle, .backgroundColor,
      .notesDecoration, .notesFormats,
    ] {
      storage.removeAttribute(key, range: whole)
    }
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = 4
    storage.addAttributes(
      [.font: Self.bodyFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph],
      range: whole)
    style(document, storage: storage)
    storage.endEditing()
    editor.typingAttributes = [
      .font: Self.bodyFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
    ]
    editor.textLayoutManager?.invalidateLayout(for: editor.textLayoutManager!.documentRange)
    editor.invalidateIntrinsicContentSize()
    editor.needsDisplay = true
  }

  private func style(_ node: any Markup, storage: NSTextStorage) {
    guard let range = map.range(node.range), NSMaxRange(range) <= storage.length else {
      for child in node.children { style(child, storage: storage) }
      return
    }
    switch node {
    case let heading as Heading:
      applyFont(
        size: max(17, 30 - CGFloat(heading.level) * 2), traits: .boldFontMask, range: range,
        storage: storage)
      hideOutsideChildren(node, range: range, storage: storage)
    case is Strong:
      markFormat(.bold, range: range, storage: storage)
      applyFont(traits: .boldFontMask, range: range, storage: storage)
      hideOutsideChildren(node, range: range, storage: storage)
    case is Emphasis:
      markFormat(.italic, range: range, storage: storage)
      applyFont(traits: .italicFontMask, range: range, storage: storage)
      hideOutsideChildren(node, range: range, storage: storage)
    case is Strikethrough:
      markFormat(.strikethrough, range: range, storage: storage)
      storage.addAttribute(
        .strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
      hideOutsideChildren(node, range: range, storage: storage)
    case let link as Link:
      markFormat(.link, range: range, storage: storage)
      if let destination = link.destination, let url = URL(string: destination) {
        storage.addAttributes([.link: url, .foregroundColor: NSColor.systemBlue], range: range)
      }
      hideOutsideChildren(node, range: range, storage: storage)
    case is InlineCode:
      markFormat(.inlineCode, range: range, storage: storage)
      storage.addAttributes(
        [
          .font: NSFont.monospacedSystemFont(ofSize: 15, weight: .regular),
          .backgroundColor: NSColor.white.withAlphaComponent(0.08),
        ], range: range)
      let literal = map.source.substring(with: range)
      let count = literal.prefix { $0 == "`" }.count
      if !isRevealed(range), count > 0, range.length >= count * 2 {
        hide(NSRange(location: range.location, length: count), storage: storage)
        hide(NSRange(location: NSMaxRange(range) - count, length: count), storage: storage)
        let code = String(literal.dropFirst(count).dropLast(count))
        if code.hasPrefix(" "), code.hasSuffix(" "), !code.allSatisfy({ $0 == " " }) {
          hide(NSRange(location: range.location + count, length: 1), storage: storage)
          hide(NSRange(location: NSMaxRange(range) - count - 1, length: 1), storage: storage)
        }
      }
    case let item as ListItem:
      styleList(item, range: range, storage: storage)
    case is BlockQuote:
      lines(in: range) { line in
        let raw = map.source.substring(with: line)
        if let prefix = raw.range(of: "^[ \\t]*> ?", options: .regularExpression) {
          let marker = NSRange(prefix, in: raw)
          hide(
            NSRange(location: line.location + marker.location, length: marker.length),
            storage: storage, nodeRange: range)
        }
        if !isRevealed(range) {
          decorate(line, .init(.quote), indent: 16, storage: storage)
        }
      }
    case is CodeBlock:
      markFormat(.codeBlock, range: range, storage: storage)
      storage.addAttribute(
        .font, value: NSFont.monospacedSystemFont(ofSize: 15, weight: .regular), range: range)
      lines(in: range) { line in
        decorate(line, .init(.code), indent: 10, storage: storage)
        let raw = map.source.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("```") || raw.hasPrefix("~~~") {
          hide(line, storage: storage, nodeRange: range)
        }
      }
    case is ThematicBreak:
      if !isRevealed(range) {
        decorate(range, .init(.rule), indent: 0, storage: storage)
        hide(range, storage: storage)
      }
    default:
      break
    }
    for child in node.children { style(child, storage: storage) }
  }

  private func markFormat(_ format: NotesFormat, range: NSRange, storage: NSTextStorage) {
    storage.enumerateAttribute(.notesFormats, in: range) { value, run, _ in
      var formats = value as? [String] ?? []
      if !formats.contains(format.rawValue) { formats.append(format.rawValue) }
      storage.addAttribute(.notesFormats, value: formats, range: run)
    }
  }

  private func applyFont(
    size: CGFloat? = nil, traits: NSFontTraitMask, range: NSRange, storage: NSTextStorage
  ) {
    storage.enumerateAttribute(.font, in: range) { value, run, _ in
      var font = value as? NSFont ?? Self.bodyFont
      if let size { font = NSFontManager.shared.convert(font, toSize: size) }
      font = NSFontManager.shared.convert(font, toHaveTrait: traits)
      storage.addAttribute(.font, value: font, range: run)
    }
  }

  private func hideOutsideChildren(_ node: any Markup, range: NSRange, storage: NSTextStorage) {
    guard !isRevealed(range) else { return }
    let childRanges = node.children.compactMap { map.range($0.range) }
    guard let first = childRanges.first, let last = childRanges.last,
      first.location >= range.location, NSMaxRange(last) <= NSMaxRange(range)
    else { return }
    hide(
      NSRange(location: range.location, length: first.location - range.location),
      storage: storage, nodeRange: range)
    hide(
      NSRange(location: NSMaxRange(last), length: NSMaxRange(range) - NSMaxRange(last)),
      storage: storage, nodeRange: range)
  }

  private func isRevealed(_ range: NSRange) -> Bool {
    guard let revealed else { return false }
    if revealed.length > 0 { return NSIntersectionRange(revealed, range).length > 0 }
    if NSLocationInRange(revealed.location, range) { return true }
    guard range.length > 0, revealed.location == NSMaxRange(range) else { return false }
    let last = map.source.character(at: NSMaxRange(range) - 1)
    return last != 10 && last != 13
  }

  private func hide(_ range: NSRange, storage: NSTextStorage, nodeRange: NSRange? = nil) {
    guard range.length > 0, !isRevealed(nodeRange ?? range) else { return }
    storage.addAttributes(
      [.font: NSFont.systemFont(ofSize: 0.01), .foregroundColor: NSColor.clear], range: range)
    storage.removeAttribute(.backgroundColor, range: range)
  }

  private func styleList(_ item: ListItem, range: NSRange, storage: NSTextStorage) {
    let line = map.source.lineRange(for: NSRange(location: range.location, length: 0))
    let raw = map.source.substring(with: line)
    guard
      let match = raw.range(
        of: "^[ \\t]*(?:[-+*]|[0-9]+[.)]) +(?:\\[[ xX]\\] +)?", options: .regularExpression)
    else { return }
    let prefix = NSRange(match, in: raw)
    let marker = NSRange(location: line.location + prefix.location, length: prefix.length)
    let indent = CGFloat(raw.prefix { $0 == " " || $0 == "\t" }.count) * 4
    let kind: NotesBlockDecoration.Kind
    if let checkbox = item.checkbox,
      let check = raw.range(of: "\\[[ xX]\\]", options: .regularExpression)
    {
      let checkRange = NSRange(check, in: raw)
      let state = NSRange(location: line.location + checkRange.location + 1, length: 1)
      kind = .task(checkbox == .checked, state)
      if checkbox == .checked {
        let text = item.children.first(where: { _ in true }).flatMap { map.range($0.range) } ?? line
        storage.addAttributes(
          [
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            .foregroundColor: NSColor.secondaryLabelColor,
          ], range: text)
      }
    } else if let ordered = item.parent as? OrderedList {
      kind = .number("\(ordered.startIndex + UInt(item.indexInParent)).")
    } else {
      kind = .bullet
    }
    let syntaxLength = raw[match].trimmingCharacters(in: .whitespaces).utf16.count
    let syntax = NSRange(location: marker.location, length: syntaxLength)
    let isRevealed = isRevealed(syntax)
    lines(in: range) { paragraph in
      let style = NSMutableParagraphStyle()
      style.lineSpacing = 4
      style.firstLineHeadIndent =
        indent + (isRevealed && paragraph.location == line.location ? 0 : 24)
      style.headIndent = indent + 24
      storage.addAttribute(.paragraphStyle, value: style, range: paragraph)
    }
    if !isRevealed {
      hide(marker, storage: storage, nodeRange: syntax)
      storage.addAttribute(
        .notesDecoration, value: NotesBlockDecoration(kind, indent: indent), range: line)
    }
  }

  private func decorate(
    _ range: NSRange, _ decoration: NotesBlockDecoration, indent: CGFloat, storage: NSTextStorage
  ) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = 4
    paragraph.firstLineHeadIndent = indent
    paragraph.headIndent = indent
    storage.addAttributes([.notesDecoration: decoration, .paragraphStyle: paragraph], range: range)
  }

  private func lines(in range: NSRange, body: (NSRange) -> Void) {
    var offset = range.location
    while offset < NSMaxRange(range) {
      let line = map.source.lineRange(for: NSRange(location: offset, length: 0))
      guard line.length > 0 else { break }
      body(line)
      offset = NSMaxRange(line)
    }
  }

  nonisolated func textLayoutManager(
    _ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation,
    in textElement: NSTextElement
  ) -> NSTextLayoutFragment {
    if let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0,
      let decoration = paragraph.attributedString.attribute(
        .notesDecoration, at: 0, effectiveRange: nil) as? NotesBlockDecoration
    {
      return NotesLayoutFragment(textElement: textElement, decoration: decoration)
    }
    return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
  }
}

final class NotesLayoutFragment: NSTextLayoutFragment {
  let decoration: NotesBlockDecoration

  init(textElement: NSTextElement, decoration: NotesBlockDecoration) {
    self.decoration = decoration
    super.init(textElement: textElement, range: textElement.elementRange)
  }

  required init?(coder: NSCoder) { nil }

  private var firstLine: CGRect { textLineFragments.first?.typographicBounds ?? .zero }
  var checkboxRect: CGRect {
    CGRect(
      x: decoration.indent + 3 - layoutFragmentFrame.minX,
      y: firstLine.midY - 7, width: 14, height: 14)
  }

  override var renderingSurfaceBounds: CGRect {
    super.renderingSurfaceBounds.union(
      CGRect(
        x: -layoutFragmentFrame.minX, y: 0,
        width: textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width,
        height: layoutFragmentFrame.height))
  }

  override func draw(at point: CGPoint, in context: CGContext) {
    context.saveGState()
    let left = point.x - layoutFragmentFrame.minX
    let width = textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
    switch decoration.kind {
    case .code:
      context.setFillColor(NSColor.white.withAlphaComponent(0.06).cgColor)
      context.fill(CGRect(x: left, y: point.y, width: width, height: layoutFragmentFrame.height))
    case .quote:
      context.setFillColor(NSColor.secondaryLabelColor.cgColor)
      context.fill(CGRect(x: left, y: point.y, width: 3, height: layoutFragmentFrame.height))
    case .rule:
      context.setFillColor(NSColor.separatorColor.cgColor)
      context.fill(CGRect(x: left, y: point.y + firstLine.midY, width: width, height: 1))
    case .bullet:
      context.setFillColor(decoration.accentColor.cgColor)
      context.fillEllipse(
        in: CGRect(
          x: left + decoration.indent + 8, y: point.y + firstLine.midY - 2.5, width: 5, height: 5))
    case .number(let label):
      let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 16), .foregroundColor: decoration.accentColor,
      ]
      let line = CTLineCreateWithAttributedString(
        NSAttributedString(string: label, attributes: attributes))
      context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
      let baseline =
        textLineFragments.first.map { $0.typographicBounds.minY + $0.glyphOrigin.y }
        ?? firstLine.maxY
      context.textPosition = CGPoint(
        x: left + decoration.indent + 20 - CTLineGetTypographicBounds(line, nil, nil, nil),
        y: point.y + baseline)
      CTLineDraw(line, context)
    case .task(let checked, _):
      let box = checkboxRect.offsetBy(dx: point.x, dy: point.y)
      context.addPath(CGPath(roundedRect: box, cornerWidth: 3, cornerHeight: 3, transform: nil))
      context.setStrokeColor(decoration.accentColor.cgColor)
      context.setFillColor(decoration.accentColor.cgColor)
      context.setLineWidth(1.25)
      context.drawPath(using: checked ? .fillStroke : .stroke)
      if checked {
        context.setStrokeColor(NSColor.windowBackgroundColor.cgColor)
        context.setLineWidth(1.8)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.move(to: CGPoint(x: box.minX + 3, y: box.midY))
        context.addLine(to: CGPoint(x: box.minX + 6, y: box.maxY - 3))
        context.addLine(to: CGPoint(x: box.maxX - 3, y: box.minY + 3))
        context.strokePath()
      }
    }
    context.restoreGState()
    super.draw(at: point, in: context)
  }
}
