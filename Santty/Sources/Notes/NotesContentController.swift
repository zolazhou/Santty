import AppKit
import SwiftUI

@MainActor
final class NotesContentController: NSViewController {
  let library: NotesLibrary
  let formatting = NotesFormatting()
  var store: NotesStore { library.store }
  var window: NSWindow? { view.window }
  var onTitleChange: (() -> Void)?
  var onFocus: (() -> Void)?
  var shouldFocusEditor: (() -> Bool)?
  var onDismissIfUnfocused: (() -> Void)?
  var onWritingToolsEnded: (() -> Void)?
  var isClosing = false
  private(set) var isChangingDocument = false
  private var loadTask: Task<Void, Never>?
  private var operationTask: Task<Void, Never>?
  private var browser: NotesBrowserWindowController?
  private(set) weak var editor: NSTextView?
  private var editorFileURL: URL?
  private var writingToolsObservation: NSKeyValueObservation?
  private let isPane: Bool
  private let isPinned: Bool
  private let onTogglePin: () -> Bool

  init(store: NotesStore = NotesStore(), defaults: UserDefaults = .standard,
       isPane: Bool = false, isPinned: Bool = false, onTogglePin: @escaping () -> Bool = { false }) {
    library = NotesLibrary(store: store, defaults: defaults)
    self.isPane = isPane
    self.isPinned = isPinned
    self.onTogglePin = onTogglePin
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  override func loadView() {
    let root = NotesEditorView(
      library: library, formatting: formatting, isPinned: isPinned, isPane: isPane,
      onTogglePin: onTogglePin,
      onEditorReady: { [weak self] in self?.captureEditor(bottomInset: $0) },
      onCreate: { [weak self] in self?.createNote() },
      onBrowse: { [weak self] in self?.browseNotes() },
      onOpenFolder: { [weak self] in self?.openNotesFolder() },
      onFormat: { [weak self] in self?.applyFormat($0) },
      onHeading: { [weak self] in self?.applyHeading($0) }
    )
    let hosting = NSHostingView(rootView: root)
    hosting.appearance = NSAppearance(named: .darkAqua)
    hosting.sizingOptions = []
    view = hosting
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    loadTask = Task { [weak self] in
      guard let self else { return }
      await library.load()
      onTitleChange?()
      captureEditor()
    }
  }

  func dismissBrowser() { browser?.dismiss() }
  var isBrowserKeyWindow: Bool { browser?.window?.isKeyWindow == true }

  func prepareToClose() async -> Bool {
    guard !isClosing else { return false }
    isClosing = true
    defer { isClosing = false }
    await waitForPendingOperations()
    guard !isWritingToolsActive else {
      library.errorMessage = NotesStore.SaveError.writingToolsActive.localizedDescription
      return false
    }
    synchronizeEditor()
    do {
      try await store.flush()
      dismissBrowser()
      return true
    } catch { return false }
  }

  func waitForPendingOperations() async {
    await loadTask?.value
    await operationTask?.value
  }

  func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
    guard let window = library.isBrowserPresented ? browser?.window : window else { return .abort }
    window.makeKeyAndOrderFront(nil)
    return await withCheckedContinuation { continuation in
      alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
    }
  }

  var isWritingToolsActive: Bool {
    if #available(macOS 15.0, *), editor?.isWritingToolsActive == true { return true }
    return store.isSavingSuspended
  }

  func synchronizeEditor() {
    guard let editor, editorFileURL == store.fileURL, !isWritingToolsActive else { return }
    if window?.firstResponder === editor { window?.makeFirstResponder(nil) }
    if editor.hasMarkedText() { editor.unmarkText() }
    if let native = editor as? NotesTextView, native.modelText != store.text { return }
    store.updateText(editor.string)
  }

  func captureEditor(bottomInset: CGFloat? = nil) {
    if let bottomInset { (editor as? NotesTextView)?.bottomBarHeight = bottomInset }
    guard let found = findEditor(in: view) else { return }
    if found === editor {
      formatting.refresh()
      return
    }
    editor = found
    editorFileURL = store.fileURL
    formatting.attach(found)
    found.setAccessibilityLabel("Notes editor")
    store.canReload = { [weak found] in
      guard found?.hasMarkedText() != true else { return false }
      if #available(macOS 15.0, *), found?.isWritingToolsActive == true { return false }
      return true
    }
    (found as? NotesTextView)?.onFocus = { [weak self] in self?.onFocus?() }
    if window?.isKeyWindow == true, !isPane || shouldFocusEditor?() == true {
      window?.makeFirstResponder(found)
    }
    if #available(macOS 15.0, *) {
      writingToolsObservation = found.observe(\.isWritingToolsActive, options: [.new]) {
        [weak self] _, change in
        let active = change.newValue ?? false
        Task { @MainActor in
          guard let self else { return }
          self.store.setSavingSuspended(active)
          self.formatting.refresh()
          if !active {
            // Wait for the native editor to finish the accepted replacement.
            DispatchQueue.main.async { [weak self] in
              guard let self else { return }
              if let editor = self.editor { self.store.updateText(editor.string) }
              self.onWritingToolsEnded?()
            }
          }
        }
      }
    }
  }

  private func findEditor(in view: NSView?) -> NSTextView? {
    guard let view else { return nil }
    if let editor = view as? NSTextView { return editor }
    for child in view.subviews {
      if let editor = findEditor(in: child) { return editor }
    }
    return nil
  }

  func createNote() {
    changeDocument { [library] in try await library.create() }
  }

  func selectNote(_ id: String) {
    if id == library.activeID {
      browser?.dismiss(restoreFocus: true)
      focusEditor()
      return
    }
    changeDocument { [library] in try await library.select(id) }
  }

  private func changeDocument(_ operation: @escaping @MainActor () async throws -> Void) {
    guard !isClosing, !isChangingDocument, !library.isWorking,
      !isWritingToolsActive, editor?.hasMarkedText() != true
    else { return }
    synchronizeEditor()
    isChangingDocument = true
    editor?.isEditable = false
    operationTask = Task { [weak self] in
      guard let self else { return }
      defer {
        isChangingDocument = false
        DispatchQueue.main.async { [weak self] in
          guard let self else { return }
          captureEditor()
          editor?.isEditable = store.canEdit && !library.isWorking
          onDismissIfUnfocused?()
        }
      }
      do {
        try await operation()
        browser?.dismiss(
          restoreFocus: window?.isKeyWindow == true || browser?.window?.isKeyWindow == true)
        onTitleChange?()
      } catch { library.errorMessage = error.localizedDescription }
    }
  }

  private func focusEditor() {
    captureEditor()
    editor?.isEditable = store.canEdit && !library.isWorking
    guard let window, window.isVisible, !library.isBrowserPresented else { return }
    window.makeKeyAndOrderFront(nil)
    if let editor { window.makeFirstResponder(editor) }
  }

  func browseNotes() {
    guard !isClosing, !library.isWorking, !isChangingDocument, !isWritingToolsActive,
      editor?.hasMarkedText() != true, let window
    else { return }
    if library.isBrowserPresented {
      browser?.dismiss(restoreFocus: true)
      focusEditor()
      return
    }
    synchronizeEditor()
    if browser == nil {
      browser = NotesBrowserWindowController(
        library: library, parent: window,
        onSelect: { [weak self] in self?.selectNote($0) },
        onCreate: { [weak self] in self?.createNote() },
        onRename: { [weak self] in self?.renameNote($0) },
        onTrash: { [weak self] in self?.trashNote($0) },
        onDismiss: { [weak self] in
          DispatchQueue.main.async { self?.onDismissIfUnfocused?() }
        }
      )
    }
    browser?.show()
  }

  func openNotesFolder() { NSWorkspace.shared.open(library.directoryURL) }

  private func renameNote(_ id: String) {
    guard !isClosing, !library.isWorking, !isChangingDocument else { return }
    let alert = NSAlert()
    alert.messageText = "Rename Note"
    alert.addButton(withTitle: "Rename")
    alert.addButton(withTitle: "Cancel")
    let field = NSTextField(string: NotesLibrary.title(for: id))
    field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
    alert.accessoryView = field
    Task {
      guard await present(alert) == .alertFirstButtonReturn else { return }
      changeDocument { [library] in try await library.rename(id, to: field.stringValue) }
    }
  }

  private func trashNote(_ id: String) {
    guard !isClosing, !library.isWorking, !isChangingDocument else { return }
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Move “\(NotesLibrary.title(for: id))” to Trash?"
    alert.informativeText = "You can recover the Markdown file from the Trash."
    alert.addButton(withTitle: "Move to Trash")
    alert.addButton(withTitle: "Cancel")
    Task {
      guard await present(alert) == .alertFirstButtonReturn else { return }
      changeDocument { [library] in try await library.trash(id) }
    }
  }

  func applyHeading(_ level: Int) {
    guard !isClosing, !library.isWorking, !isChangingDocument, !isWritingToolsActive else { return }
    captureEditor()
    formatting.applyHeading(level)
  }

  func applyFormat(_ action: NotesFormat) {
    guard !isClosing, !library.isWorking, !isChangingDocument, !isWritingToolsActive,
      editor?.hasMarkedText() != true
    else { return }
    captureEditor()
    if action != .link {
      formatting.apply(action)
      return
    }
    let alert = NSAlert()
    alert.messageText = "Insert Link"
    alert.addButton(withTitle: "Insert")
    alert.addButton(withTitle: "Cancel")
    let field = NSTextField(string: "https://")
    field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
    alert.accessoryView = field
    Task {
      guard await present(alert) == .alertFirstButtonReturn else { return }
      let raw = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let url = URL(string: raw),
        ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? ""),
        !raw.contains(where: { $0.isWhitespace }),
        url.scheme == "mailto" || url.host != nil
      else {
        library.errorMessage = "Enter a valid http, https, or mailto URL."
        return
      }
      formatting.apply(
        .link,
        url: raw.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(
          of: ")", with: "%29"))
      focusEditor()
    }
  }

  func handleCommand(_ event: NSEvent) -> Bool {
    guard window?.attachedSheet == nil, browser?.window?.attachedSheet == nil,
      event.type == .keyDown, let key = event.charactersIgnoringModifiers?.lowercased()
    else { return false }
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(
      .capsLock)
    if modifiers == .command {
      switch key {
      case "n": createNote()
      case "o": openNotesFolder()
      case "b": applyFormat(.bold)
      case "i": applyFormat(.italic)
      case "e": applyFormat(.inlineCode)
      case "k": applyFormat(.link)
      default: return false
      }
      return true
    }
    if modifiers == [.command, .option], key == "t" {
      library.isFormattingExpanded.toggle()
      return true
    }
    if modifiers == [.command, .option], key == "c" {
      applyFormat(.codeBlock)
      return true
    }
    if modifiers == [.command, .shift] {
      if key == "p" { browseNotes(); return true }
      let action: NotesFormat?
      switch event.keyCode {
      case 7: action = .strikethrough
      case 11: action = .blockquote
      case 26: action = .orderedList
      case 28: action = .unorderedList
      case 25: action = .taskList
      default: action = nil
      }
      if let action {
        applyFormat(action)
        return true
      }
    }
    return false
  }
}
