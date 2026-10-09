import AppKit
import SwiftUI

@MainActor
final class NotesWindowController: NSWindowController, NSWindowDelegate {
  private var content: NotesContentController!
  var library: NotesLibrary { content.library }
  var formatting: NotesFormatting { content.formatting }
  var store: NotesStore { content.store }
  private let defaults: UserDefaults
  private var isDismissing = false
  private var pendingDismiss = false
  private var isMenuTracking = false
  private var presentationGeneration = 0
  nonisolated(unsafe) private var menuObservers: [NSObjectProtocol] = []
  nonisolated(unsafe) private var trafficLightObserver: NSObjectProtocol?

  var isPinned: Bool {
    get { defaults.bool(forKey: "Santty.NotesPinned") }
    set {
      defaults.set(newValue, forKey: "Santty.NotesPinned")
    }
  }

  init(store: NotesStore = NotesStore(), defaults: UserDefaults = .standard) {
    self.defaults = defaults
    super.init(window: nil)

    let panel = NotesPanel(
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
      styleMask: [
        .titled, .closable, .miniaturizable, .resizable, .nonactivatingPanel, .fullSizeContentView,
      ],
      backing: .buffered,
      defer: false
    )
    panel.title = "Notes"
    panel.appearance = NSAppearance(named: .darkAqua)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.isRestorable = false
    panel.isMovableByWindowBackground = false
    panel.contentMinSize = NSSize(width: 360, height: 280)
    panel.isReleasedWhenClosed = false
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.titlebarAppearsTransparent = true
    panel.titleVisibility = .hidden
    panel.titlebarSeparatorStyle = .none
    panel.delegate = self
    panel.onCancel = { [weak self] in self?.dismiss() }
    panel.onCommand = { [weak self] in self?.handleCommand($0) ?? false }
    window = panel

    content = NotesContentController(store: store, defaults: defaults, isPinned: isPinned,
      onTogglePin: { [weak self] in self?.togglePin() ?? false })
    content.onTitleChange = { [weak self] in
      guard let self else { return }
      window?.title = library.activeTitle
      positionTrafficLights()
    }
    content.onDismissIfUnfocused = { [weak self] in self?.dismissIfUnfocused() }
    content.onWritingToolsEnded = { [weak self] in
      guard let self else { return }
      if pendingDismiss { pendingDismiss = false; dismiss() }
      else { dismissIfUnfocused() }
    }
    panel.contentViewController = content
    if !panel.setFrameUsingName("Santty.NotesWindow") { panel.center() }
    panel.setFrameAutosaveName("Santty.NotesWindow")
    if let close = panel.standardWindowButton(.closeButton) {
      close.postsFrameChangedNotifications = true
      trafficLightObserver = NotificationCenter.default.addObserver(
        forName: NSView.frameDidChangeNotification, object: close, queue: .main
      ) { [weak self] _ in
        // AppKit can finish laying out the other buttons after this notification.
        DispatchQueue.main.async { [weak self] in self?.positionTrafficLights() }
      }
    }
    menuObservers = [
      NotificationCenter.default.addObserver(
        forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.isMenuTracking = true }
      },
      NotificationCenter.default.addObserver(
        forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.isMenuTracking = false
          DispatchQueue.main.async { self?.dismissIfUnfocused() }
        }
      },
    ]
  }

  deinit {
    menuObservers.forEach(NotificationCenter.default.removeObserver)
    if let trafficLightObserver { NotificationCenter.default.removeObserver(trafficLightObserver) }
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) { nil }

  func toggle() {
    if window?.isKeyWindow == true || content.isBrowserKeyWindow {
      dismiss()
    } else {
      show()
    }
  }

  func show() {
    Task { [weak self] in
      guard let self else { return }
      await content.waitForPendingOperations()
      guard let window else { return }
      presentationGeneration += 1
      pendingDismiss = false
      if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) }) {
        window.center()
      }
      window.makeKeyAndOrderFront(nil)
      window.contentView?.layoutSubtreeIfNeeded()
      positionTrafficLights()
      window.invalidateShadow()
      content.captureEditor()
      if let editor = content.editor { window.makeFirstResponder(editor) }
    }
  }

  func dismiss() {
    guard !isDismissing, !content.isChangingDocument, !library.isWorking else { return }
    if isWritingToolsActive {
      pendingDismiss = true
      return
    }
    isDismissing = true
    content.isClosing = true
    content.dismissBrowser()
    let generation = presentationGeneration
    Task { [weak self] in
      guard let self else { return }
      defer { isDismissing = false; content.isClosing = false }
      content.synchronizeEditor()
      do {
        try await store.flush()
        if presentationGeneration == generation { window?.orderOut(nil) }
      } catch {
        // Keep the editor visible with the store's retryable error.
      }
    }
  }

  func windowShouldClose(_: NSWindow) -> Bool {
    dismiss()
    return false
  }

  func windowDidResignKey(_: Notification) {
    positionTrafficLights()
    DispatchQueue.main.async { [weak self] in
      self?.dismissIfUnfocused()
    }
  }

  func windowDidBecomeKey(_: Notification) {
    positionTrafficLights()
  }

  func windowDidResize(_: Notification) {
    positionTrafficLights()
  }

  func windowDidUpdate(_: Notification) {
    positionTrafficLights()
  }

  private func positionTrafficLights() {
    guard let window else { return }
    window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
    window.standardWindowButton(.zoomButton)?.isEnabled = false
    let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
      .compactMap(window.standardWindowButton)
    guard let leading = buttons.first, let titlebar = leading.superview else { return }
    let shift = 20 - leading.frame.minX
    let y = max(titlebar.bounds.minY, titlebar.bounds.maxY - NotesLayout.titleBarHeight / 2 - leading.frame.height / 2)
    guard shift != 0 || leading.frame.minY != y else { return }
    for button in buttons {
      button.setFrameOrigin(NSPoint(x: button.frame.minX + shift, y: y))
    }
  }

  func dismissIfUnfocused() {
    guard let window, window.isVisible, !window.isKeyWindow, !isPinned,
      !isDismissing, !isWritingToolsActive, window.attachedSheet == nil,
      !(window.childWindows ?? []).contains(where: { $0.isVisible }),
      !isMenuTracking, !library.isBrowserPresented, !library.isWorking, !content.isChangingDocument
    else { return }
    dismiss()
  }

  func prepareToTerminate() async -> Bool {
    await waitForPendingOperations()
    if isWritingToolsActive {
      let alert = NSAlert()
      alert.messageText = "Finish Writing Tools before quitting"
      alert.informativeText = "Finish or cancel the current Writing Tools session, then quit again."
      alert.addButton(withTitle: "Cancel Quit")
      _ = await present(alert)
      return false
    }
    content.synchronizeEditor()
    while true {
      do {
        try await store.flush()
        return true
      } catch {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not save Notes"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "Retry")
        alert.addButton(withTitle: "Cancel Quit")
        guard await present(alert) == .alertFirstButtonReturn else { return false }
      }
    }
  }

  func waitForPendingOperations() async { await content.waitForPendingOperations() }
  private var isWritingToolsActive: Bool { content.isWritingToolsActive }
  private func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
    await content.present(alert)
  }
  func togglePin() -> Bool { isPinned.toggle(); return isPinned }
  func createNote() { content.createNote() }
  private func handleCommand(_ event: NSEvent) -> Bool { content.handleCommand(event) }

}

@MainActor
private final class NotesPanel: NSPanel {
  var onCancel: (() -> Void)?
  var onCommand: ((NSEvent) -> Bool)?
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  override func cancelOperation(_ sender: Any?) {
    guard let editor = firstResponder as? NSTextView, !editor.hasMarkedText() else {
      super.cancelOperation(sender)
      return
    }
    if #available(macOS 15.0, *), editor.isWritingToolsActive { return }
    onCancel?()
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if onCommand?(event) == true { return true }
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(
      .capsLock)
    if modifiers == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "z",
      let editor = firstResponder as? NSTextView
    {
      if editor.undoManager?.canRedo == true { editor.undoManager?.redo() }
      return true
    }
    guard event.type == .keyDown, modifiers == .command,
      let key = event.charactersIgnoringModifiers?.lowercased()
    else {
      if KeybindingSettings.action(matching: event) != nil { return true }
      return super.performKeyEquivalent(with: event)
    }
    // A nonactivating panel doesn't own the foreground application's menu.
    let actions: [String: Selector] = [
      "a": #selector(NSText.selectAll(_:)), "c": #selector(NSText.copy(_:)),
      "v": #selector(NSText.paste(_:)), "x": #selector(NSText.cut(_:)),
    ]
    if key == "z", let editor = firstResponder as? NSTextView {
      if editor.undoManager?.canUndo == true { editor.undoManager?.undo() }
      return true
    }
    if key == "w" {
      performClose(nil)
      return true
    }
    if let action = actions[key], let editor = firstResponder as? NSTextView {
      return NSApp.sendAction(action, to: editor, from: self)
    }
    if KeybindingSettings.action(matching: event) != nil { return true }
    return super.performKeyEquivalent(with: event)
  }
}
