import AppKit

@MainActor
final class NotesPaneController: PaneControlling {
  let id: PaneID
  let content: NotesContentController
  private let notesHostView = NotesPaneHostView()
  var hostView: NSView { notesHostView }
  var displayTitle: String { content.library.activeTitle }
  var isLive: Bool { false }
  var focusTargetView: NSView {
    content.captureEditor()
    return content.editor ?? content.view
  }
  var name: String? { didSet { notesHostView.nameBadge.name = name } }
  var onFocusRequest: ((PaneID) -> Void)?
  var onTitleChange: ((PaneID) -> Void)?

  init(id: PaneID = UUID(), store: NotesStore = NotesStore(), defaults: UserDefaults = .standard) {
    self.id = id
    content = NotesContentController(store: store, defaults: defaults, isPane: true)
    content.view.frame = notesHostView.bounds
    content.view.autoresizingMask = [.width, .height]
    notesHostView.addSubview(content.view, positioned: .below, relativeTo: notesHostView.nameBadge)
    content.shouldFocusEditor = { [weak self] in self?.notesHostView.isFocused == true }
    content.onFocus = { [weak self] in
      guard let self else { return }
      onFocusRequest?(id)
    }
    content.onTitleChange = { [weak self] in
      guard let self else { return }
      onTitleChange?(id)
    }
    notesHostView.onFocus = { [weak self] in
      guard let self else { return }
      onFocusRequest?(id)
    }
    updateAppearance()
  }

  func startIfNeeded() {}
  func fitToSize() { hostView.layoutSubtreeIfNeeded(); content.captureEditor() }
  func setNameVisible(_ visible: Bool) { notesHostView.nameBadge.isRevealed = visible }
  func updatePresentation(isFocused: Bool, isFloating: Bool) {
    notesHostView.isFocused = isFocused
    notesHostView.nameBadge.isFocused = isFocused
    updateAppearance()
  }
  func updateAppearance() { notesHostView.updateAppearance() }
}

@MainActor
private final class NotesPaneHostView: NSView {
  let nameBadge = PaneNameBadgeView()
  var isFocused = false
  var onFocus: (() -> Void)?

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.masksToBounds = true
    addSubview(nameBadge)
  }

  convenience init() { self.init(frame: .zero) }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  override func layout() {
    super.layout()
    nameBadge.layout(in: self)
  }

  override func mouseDown(with event: NSEvent) { onFocus?(); super.mouseDown(with: event) }

  func updateAppearance() {
    layer?.cornerRadius = AppAppearanceSettings.paneCornerRadius
    layer?.borderWidth = isFocused ? AppAppearanceSettings.activePaneBorderWidth : 1
    layer?.borderColor = (isFocused ? AppAppearanceSettings.accentColor
      : NSColor.separatorColor.withAlphaComponent(0.45)).cgColor
  }
}
