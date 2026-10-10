import AppKit
import KeyboardShortcuts
import Markdown
import XCTest

@testable import Santty

@MainActor
final class NotesStoreTests: XCTestCase {
  func testMarkdownRoundTripPreservesUnicodeAndSource() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("Notes/note.md")
    let store = NotesStore(fileURL: url)
    await store.load()
    XCTAssertTrue(store.canEdit)
    let source =
      "# 笔记 👩🏽‍💻\n\n- [x] **完成**\n- [ ] [Apple](https://apple.com)\n\n```swift\nlet value = \"原文\"\n```\n"
    store.updateText(source)
    try await store.flush()
    XCTAssertFalse(store.hasUnsavedChanges)
    let restored = NotesStore(fileURL: url)
    await restored.load()
    XCTAssertEqual(restored.text, source)
    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), source)
  }

  func testDebouncedSaveWritesLatestEdit() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("note.md")
    let store = NotesStore(fileURL: url)
    await store.load()
    store.updateText("first")
    store.updateText("second")
    store.updateText("latest 中文 😀")
    try await Task.sleep(for: .milliseconds(500))
    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "latest 中文 😀")
    XCTAssertFalse(store.hasUnsavedChanges)
  }

  func testUnreadableFileCannotBeOverwritten() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("note.md")
    let original = Data([0xff, 0xfe, 0xff])
    try original.write(to: url)
    let store = NotesStore(fileURL: url)
    await store.load()
    XCTAssertTrue(store.hasReadError)
    XCTAssertFalse(store.canEdit)
    XCTAssertNotNil(store.errorMessage)
    store.updateText("replacement")
    try await store.flush()
    XCTAssertEqual(try Data(contentsOf: url), original)
    try Data("recovered".utf8).write(to: url)
    await store.load()
    XCTAssertEqual(store.text, "recovered")
    XCTAssertTrue(store.canEdit)
  }

  func testSaveFailureRetainsTextAndCanBeRetried() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("note.md")
    let store = NotesStore(fileURL: url)
    await store.load()
    try Data("blocking file".utf8).write(to: directory)
    store.updateText("keep this text")
    do {
      try await store.flush()
      XCTFail("Expected a write failure")
    } catch {}
    XCTAssertEqual(store.text, "keep this text")
    XCTAssertTrue(store.hasUnsavedChanges)
    XCTAssertNotNil(store.errorMessage)
    try FileManager.default.removeItem(at: directory)
    try await store.flush()
    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "keep this text")
    XCTAssertFalse(store.hasUnsavedChanges)
    XCTAssertNil(store.errorMessage)
  }

  func testWritingToolsSuspendsSavingUntilAcceptedTextIsReady() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("note.md")
    let store = NotesStore(fileURL: url)
    await store.load()
    store.updateText("original")
    try await store.flush()
    store.setSavingSuspended(true)
    store.updateText("temporary rewrite")
    do {
      try await store.flush()
      XCTFail("Writing Tools text must not be saved mid-session")
    } catch {}
    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "original")
    store.updateText("accepted rewrite")
    store.setSavingSuspended(false)
    try await store.flush()
    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "accepted rewrite")
  }

  func testRevertingWhileSaveIsInFlightStillPersistsLatestText() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("note.md")
    let store = NotesStore(fileURL: url)
    await store.load()
    store.updateText("baseline")
    try await store.flush()
    store.updateText(String(repeating: "temporary edit ", count: 100_000))
    let saving = Task { try await store.flush() }
    await Task.yield()
    store.updateText("baseline")
    try await store.flush()
    try await saving.value
    XCTAssertTrue(
      try String(contentsOf: url, encoding: .utf8) == "baseline",
      "The reverted text must replace the in-flight snapshot")
    XCTAssertFalse(store.hasUnsavedChanges)
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("SanttyNotesTests-\(UUID())")
  }

  func testFileMonitorUpdatesOtherInstancesAfterAtomicAndInPlaceWrites() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("note.md")
    try Data("original".utf8).write(to: url)
    let writer = NotesStore(fileURL: url)
    let reader = NotesStore(fileURL: url)
    await writer.load()
    await reader.load()
    writer.updateText("written in Santty 中文")
    try await writer.flush()
    try await waitForText("written in Santty 中文", in: reader)
    XCTAssertFalse(writer.hasExternalChange)
    try Data("external replacement".utf8).write(to: url, options: .atomic)
    try await waitForText("external replacement", in: reader)
    try Data("external in-place edit".utf8).write(to: url)
    try await waitForText("external in-place edit", in: reader)
    XCTAssertFalse(reader.hasUnsavedChanges)
  }

  func testExternalChangePreservesUnsavedTextAndRequiresExplicitResolution() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("note.md")
    try Data("original".utf8).write(to: url)
    let store = NotesStore(fileURL: url)
    await store.load()
    store.setSavingSuspended(true)
    store.updateText("local changes")
    try Data("external changes".utf8).write(to: url, options: .atomic)
    store.setSavingSuspended(false)
    do {
      try await store.flush()
      XCTFail("A stale instance must not overwrite external changes")
    } catch {
      XCTAssertEqual(error as? NotesStore.SaveError, .externalChange)
    }
    XCTAssertTrue(store.hasExternalChange)
    XCTAssertEqual(store.text, "local changes")
    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "external changes")
    await store.resolveExternalChange(keepLocal: false)
    XCTAssertEqual(store.text, "external changes")
    XCTAssertFalse(store.hasUnsavedChanges)
    XCTAssertFalse(store.hasExternalChange)

    store.setSavingSuspended(true)
    store.updateText("explicitly retained text")
    try Data("another external change".utf8).write(to: url, options: .atomic)
    store.setSavingSuspended(false)
    await store.reloadFromDisk()
    XCTAssertTrue(store.hasExternalChange)
    await store.resolveExternalChange(keepLocal: true)
    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "explicitly retained text")
    XCTAssertFalse(store.hasUnsavedChanges)
  }

  func testExternalDeletionRetainsTextWithoutRecreatingFile() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("note.md")
    try Data("keep visible".utf8).write(to: url)
    let store = NotesStore(fileURL: url)
    await store.load()
    try FileManager.default.removeItem(at: url)
    await store.reloadFromDisk()
    XCTAssertEqual(store.text, "keep visible")
    XCTAssertTrue(store.hasExternalChange)
    do { try await store.flush(); XCTFail("Deleted file requires a decision") } catch {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
  }

  func testReadRetryKeepsLocalChangesAfterExternalUnreadableUpdate() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("note.md")
    try Data("original".utf8).write(to: url)
    let store = NotesStore(fileURL: url)
    await store.load()
    store.updateText("local draft")
    try Data([0xff, 0xfe, 0xff]).write(to: url, options: .atomic)
    await store.reloadFromDisk()
    XCTAssertTrue(store.hasReadError)
    try Data("external text".utf8).write(to: url, options: .atomic)
    await store.load()
    XCTAssertEqual(store.text, "local draft")
    XCTAssertTrue(store.hasExternalChange)
    await store.resolveExternalChange(keepLocal: false)
    XCTAssertEqual(store.text, "external text")
    XCTAssertTrue(store.canEdit)
  }

  private func waitForText(_ expected: String, in store: NotesStore) async throws {
    for _ in 0..<60 {
      if store.text == expected { return }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertEqual(store.text, expected, "File notifications should refresh an idle instance")
  }
}

@MainActor
final class NotesIntegrationTests: XCTestCase {
  func testMultipleNotesPanesAndWindowHaveIndependentSelectionAndShareFileUpdates() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SanttyNotesPanes-\(UUID())")
    let suite = "SanttyNotesPanes.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("note.md")
    try Data("original".utf8).write(to: url)
    let first = NotesPaneController(store: NotesStore(fileURL: url), defaults: defaults)
    let second = NotesPaneController(store: NotesStore(fileURL: url), defaults: defaults)
    let window = NotesWindowController(store: NotesStore(fileURL: url), defaults: defaults)
    await first.content.waitForPendingOperations()
    await second.content.waitForPendingOperations()
    await window.waitForPendingOperations()
    XCTAssertNotEqual(first.id, second.id)
    XCTAssertFalse(first.content.store === second.content.store)
    XCTAssertFalse(first.content.store === window.store)
    first.hostView.frame = NSRect(x: 0, y: 0, width: 640, height: 420)
    first.hostView.layoutSubtreeIfNeeded()
    let editor = try XCTUnwrap(first.focusTargetView as? NotesTextView)
    XCTAssertEqual(first.content.view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
    XCTAssertEqual(editor.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
    XCTAssertEqual(editor.string, "original")
    editor.insertText("edited in pane", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
    XCTAssertEqual(first.content.store.text, "edited in pane")
    second.hostView.frame = NSRect(x: 0, y: 0, width: 640, height: 420)
    second.hostView.layoutSubtreeIfNeeded()
    let secondEditor = try XCTUnwrap(second.focusTargetView as? NotesTextView)
    let saved = await first.content.prepareToClose()
    XCTAssertTrue(saved)
    for _ in 0..<60 {
      if second.content.store.text == "edited in pane", window.store.text == "edited in pane",
         secondEditor.string == "edited in pane" { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertEqual(second.content.store.text, "edited in pane")
    XCTAssertEqual(secondEditor.string, "edited in pane")
    XCTAssertEqual(window.store.text, "edited in pane")
    first.content.createNote()
    await first.content.waitForPendingOperations()
    XCTAssertEqual(first.content.library.activeID, "Untitled.md")
    XCTAssertEqual(second.content.library.activeID, "note.md")
    XCTAssertEqual(window.library.activeID, "note.md")
    first.content.store.setSavingSuspended(true)
    let suspended = await first.content.prepareToClose()
    XCTAssertFalse(suspended)
    first.content.store.setSavingSuspended(false)
  }

  func testNotesShortcutIsGlobalAndExcludedFromWorkspaceDispatch() throws {
    let action = KeybindingAction.toggleNotes
    let name = action.shortcutName
    let previous = KeyboardShortcuts.getShortcut(for: name)
    let wasEnabled = KeyboardShortcuts.isEnabled(for: name)
    defer {
      KeyboardShortcuts.setShortcut(previous, for: name)
      if wasEnabled { KeyboardShortcuts.enable(name) } else { KeyboardShortcuts.disable(name) }
    }
    KeybindingSettings.resetShortcut(for: action)
    XCTAssertEqual(
      KeybindingSettings.effectiveShortcut(for: action), .init(.n, modifiers: [.control, .option]))
    XCTAssertTrue(action.isGlobal)
    XCTAssertFalse(KeybindingAction.focusBrowserLocation.isGlobal)
    let event = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [.control, .option], timestamp: 0,
        windowNumber: 0, context: nil, characters: "n", charactersIgnoringModifiers: "n",
        isARepeat: false, keyCode: UInt16(KeyboardShortcuts.Key.n.rawValue)
      ))
    XCTAssertNil(KeybindingSettings.action(matching: event))
    KeyboardShortcuts.setShortcut(nil, for: name)
    KeybindingSettings.notifyChange(for: action)
    XCTAssertNil(KeybindingSettings.effectiveShortcut(for: action))
    KeybindingSettings.resetShortcut(for: action)
    XCTAssertEqual(KeybindingSettings.effectiveShortcut(for: action), action.defaultShortcut)
    XCTAssertEqual(action.groupTitle, "Application")
  }

  func testNotesPanelIsNonactivatingAndPinStatePersists() async throws {
    let suite = "SanttyNotesTests.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SanttyNotesPanel-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = NotesStore(fileURL: directory.appendingPathComponent("note.md"))
    await store.load()
    let controller = NotesWindowController(store: store, defaults: defaults)
    await controller.waitForPendingOperations()
    let window = try XCTUnwrap(controller.window as? NSPanel)
    XCTAssertTrue(window.styleMask.contains(.nonactivatingPanel))
    XCTAssertTrue(window.canBecomeKey)
    XCTAssertFalse(window.canBecomeMain)
    XCTAssertFalse(window.hidesOnDeactivate)
    XCTAssertEqual(window.level, .floating)
    XCTAssertTrue(window.collectionBehavior.contains(.canJoinAllSpaces))
    XCTAssertFalse(controller.isPinned)
    XCTAssertNil(window.toolbar)
    XCTAssertEqual(window.titleVisibility, .hidden)
    XCTAssertTrue(controller.togglePin())
    XCTAssertTrue(controller.isPinned)
    let restored = NotesWindowController(store: store, defaults: defaults)
    await restored.waitForPendingOperations()
    XCTAssertTrue(restored.isPinned)
    XCTAssertFalse(controller.windowShouldClose(window))
  }

  func testTrafficLightsAreSeatedBeforeResizeReturns() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SanttyTrafficLights-\(UUID())")
    let suite = "SanttyTrafficLights.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
    }
    let controller = NotesWindowController(
      store: NotesStore(fileURL: directory.appendingPathComponent("note.md")), defaults: defaults)
    await controller.waitForPendingOperations()
    let window = try XCTUnwrap(controller.window)
    window.setFrameAutosaveName("")
    let buttons = try [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].map {
      try XCTUnwrap(window.standardWindowButton($0))
    }
    for size in [
      NSSize(width: 560, height: 620), NSSize(width: 760, height: 780),
      NSSize(width: 360, height: 280),
    ] {
      window.setContentSize(size)
      window.contentView?.superview?.layoutSubtreeIfNeeded()
      let spacing = zip(buttons, buttons.dropFirst()).map { $1.frame.minX - $0.frame.minX }
      controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
      XCTAssertEqual(buttons[0].frame.minX, 20, accuracy: 0.01)
      XCTAssertEqual(
        zip(buttons, buttons.dropFirst()).map { $1.frame.minX - $0.frame.minX }, spacing)
      let frames = buttons.map(\.frame)
      controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
      XCTAssertEqual(buttons.map(\.frame), frames, "Repeated layout must not drift")
      window.title = "Resized Note"
      controller.windowDidUpdate(Notification(name: NSWindow.didUpdateNotification, object: window))
      XCTAssertEqual(buttons[0].frame.minX, 20, accuracy: 0.01)
    }
  }

  func testNativeMarkdownEditorKeepsSourceAndSupportsUndo() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SanttyNotesEditor-\(UUID())")
    let suite = "SanttyNotesEditor.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("note.md")
    let source = "# 笔记 😀\n\n**bold**\n\n- [ ] Task\n\n[Apple](https://apple.com)\n\n~~removed~~\n"
    try Data(source.utf8).write(to: url)
    let store = NotesStore(fileURL: url)
    await store.load()
    let controller = NotesWindowController(store: store, defaults: defaults)
    let content = try XCTUnwrap(controller.window?.contentView)
    content.layoutSubtreeIfNeeded()
    func findTextView(_ view: NSView) -> NSTextView? {
      if let textView = view as? NSTextView { return textView }
      return view.subviews.lazy.compactMap(findTextView).first
    }
    let editor = try XCTUnwrap(findTextView(content))
    XCTAssertNotNil(editor.textLayoutManager)
    XCTAssertEqual(editor.string, source)
    XCTAssertTrue(editor.isGrammarCheckingEnabled)
    XCTAssertTrue(editor.isContinuousSpellCheckingEnabled)
    XCTAssertTrue(editor.isAutomaticSpellingCorrectionEnabled)
    let boldRange = (source as NSString).range(of: "bold")
    let font = try XCTUnwrap(
      editor.textStorage?.attribute(.font, at: boldRange.location, effectiveRange: nil) as? NSFont)
    XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
    let linkRange = (source as NSString).range(of: "Apple")
    XCTAssertNotNil(
      editor.textStorage?.attribute(.link, at: linkRange.location, effectiveRange: nil))
    let strikeRange = (source as NSString).range(of: "removed")
    XCTAssertNotNil(
      editor.textStorage?.attribute(
        .strikethroughStyle, at: strikeRange.location, effectiveRange: nil))
    editor.insertText(
      "追加", replacementRange: NSRange(location: (source as NSString).length, length: 0))
    XCTAssertEqual(editor.string, source + "追加")
    editor.undoManager?.undo()
    XCTAssertEqual(editor.string, source)
    editor.undoManager?.redo()
    XCTAssertEqual(editor.string, source + "追加")
    editor.undoManager?.undo()

    let taskRange = (source as NSString).range(of: "Task")
    let taskRect = editor.firstRect(forCharacterRange: taskRange, actualRange: nil)
    XCTAssertGreaterThan(taskRect.width, 0)
    let window = try XCTUnwrap(controller.window)
    let checkboxPoint = window.convertPoint(
      fromScreen: NSPoint(x: taskRect.minX - 10, y: taskRect.midY))
    let down = try XCTUnwrap(
      NSEvent.mouseEvent(
        with: .leftMouseDown, location: checkboxPoint, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
      ))
    let up = try XCTUnwrap(
      NSEvent.mouseEvent(
        with: .leftMouseUp, location: checkboxPoint, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0
      ))
    // A release event keeps a hit-test regression from blocking AppKit's tracking loop.
    NSApp.postEvent(up, atStart: false)
    editor.mouseDown(with: down)
    _ = NSApp.nextEvent(
      matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true)
    XCTAssertEqual(editor.string, source.replacingOccurrences(of: "- [ ] Task", with: "- [x] Task"))
    editor.undoManager?.undo()
    XCTAssertEqual(editor.string, source)
    editor.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
    editor.setMarkedText(
      "pin", selectedRange: NSRange(location: 3, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0))
    XCTAssertTrue(editor.hasMarkedText())
    editor.insertText("拼音", replacementRange: editor.markedRange())
    XCTAssertFalse(editor.hasMarkedText())
    XCTAssertEqual(editor.string, source + "拼音")
  }

  func testShortNotesStayAtTopWhenWindowIsTallerThanContent() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SanttyNotesAlignment-\(UUID())")
    let suite = "SanttyNotesAlignment.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("note.md")
    try Data("## Heading\n- [ ] Task\n".utf8).write(to: url)
    let store = NotesStore(fileURL: url)
    await store.load()
    let controller = NotesWindowController(store: store, defaults: defaults)
    await controller.waitForPendingOperations()
    let window = try XCTUnwrap(controller.window)
    window.setFrameAutosaveName("")
    let content = try XCTUnwrap(window.contentView)
    func findEditor(_ view: NSView) -> NSTextView? {
      if let editor = view as? NSTextView { return editor }
      return view.subviews.lazy.compactMap(findEditor).first
    }
    for height in [620.0, 900.0] {
      window.setContentSize(NSSize(width: 560, height: height))
      content.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(60))
      let editor = try XCTUnwrap(findEditor(content))
      let scroll = try XCTUnwrap(editor.notesScrollView)
      let document = try XCTUnwrap(scroll.documentView)
      let top = document.convert(editor.textContainerOrigin, from: editor).y
      let distanceFromTop = top - scroll.documentVisibleRect.minY
      XCTAssertGreaterThanOrEqual(distanceFromTop, NotesLayout.titleBarHeight)
      XCTAssertLessThanOrEqual(
        distanceFromTop, NotesLayout.titleBarHeight + 24,
        "Short content must start just below the title bar at height \(height)")
    }
  }

  func testCaretScrollsIntoViewWhileTypingAndNavigating() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SanttyCaretScroll-\(UUID())")
    let suite = "SanttyCaretScroll.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("note.md")
    let source = (1...80).map { "第 \($0) 行 😀 long Markdown paragraph" }.joined(separator: "\n")
    try Data(source.utf8).write(to: url)
    let store = NotesStore(fileURL: url)
    await store.load()
    let controller = NotesWindowController(store: store, defaults: defaults)
    await controller.waitForPendingOperations()
    let window = try XCTUnwrap(controller.window)
    window.setFrameAutosaveName("")
    window.setContentSize(NSSize(width: 560, height: 280))
    let content = try XCTUnwrap(window.contentView)
    content.layoutSubtreeIfNeeded()
    func findEditor(_ view: NSView) -> NSTextView? {
      if let editor = view as? NSTextView { return editor }
      return view.subviews.lazy.compactMap(findEditor).first
    }
    let editor = try XCTUnwrap(findEditor(content))
    let scroll = try XCTUnwrap(editor.notesScrollView)
    var ancestor = editor.superview
    var scrollCount = 0
    while let view = ancestor {
      if view is NSScrollView { scrollCount += 1 }
      ancestor = view.superview
    }
    XCTAssertEqual(scrollCount, 1, "The native editor must share SwiftUI's sole scrolling viewport")
    window.makeFirstResponder(editor)
    try await Task.sleep(for: .milliseconds(60))
    XCTAssertGreaterThan(scroll.contentView.bounds.height, 0)
    editor.moveToEndOfDocument(nil)
    editor.insertText("\n末尾追加", replacementRange: NSRange(location: NSNotFound, length: 0))
    try await Task.sleep(for: .milliseconds(60))
    XCTAssertTrue(editor.string.hasSuffix("\n末尾追加"))
    XCTAssertEqual(editor.selectedRange().location, editor.string.utf16.count)
    XCTAssertEqual(
      scroll.frame.height, content.bounds.height, accuracy: 0.01,
      "Editor must extend behind both bars")
    if #available(macOS 26.0, *) {
      XCTAssertEqual(editor.textContainerInset.height, 20, accuracy: 0.01)
    } else {
      XCTAssertEqual(editor.textContainerInset.height, NotesLayout.titleBarHeight + 20, accuracy: 0.01)
    }
    XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, 0)
    func assertCaretVisible(file: StaticString = #filePath, line: UInt = #line) throws {
      let layout = try XCTUnwrap(editor.textLayoutManager)
      let content = try XCTUnwrap(layout.textContentManager)
      let location = try XCTUnwrap(
        content.location(layout.documentRange.location, offsetBy: editor.selectedRange().location))
      var rect = CGRect.zero
      layout.enumerateTextSegments(
        in: NSTextRange(location: location), type: .standard, options: []
      ) { _, frame, _, _ in
        rect = frame
        return false
      }
      let document = try XCTUnwrap(scroll.documentView)
      let inEditor = document.convert(
        rect.offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y),
        from: editor)
      let visible = scroll.documentVisibleRect
      XCTAssertGreaterThan(inEditor.height, 0, file: file, line: line)
      XCTAssertGreaterThanOrEqual(inEditor.minY, visible.minY + NotesLayout.titleBarHeight - 1, file: file, line: line)
      XCTAssertLessThanOrEqual(inEditor.maxY, visible.maxY - NotesLayout.footerHeight + 1, file: file, line: line)
    }
    try assertCaretVisible()
    editor.insertText(
      String(repeating: "soft wrap 😀 ", count: 40) + "\n",
      replacementRange: NSRange(location: NSNotFound, length: 0))
    try await Task.sleep(for: .milliseconds(60))
    try assertCaretVisible()
    scroll.contentView.scroll(to: .zero)
    scroll.reflectScrolledClipView(scroll.contentView)
    try await Task.sleep(for: .milliseconds(350))
    XCTAssertEqual(
      scroll.contentView.bounds.origin.y, 0, accuracy: 0.01,
      "Reading earlier text must not snap back to the caret")
    editor.moveToBeginningOfDocument(nil)
    try await Task.sleep(for: .milliseconds(60))
    try assertCaretVisible()
    for _ in 0..<35 { editor.moveDown(nil) }
    try await Task.sleep(for: .milliseconds(60))
    try assertCaretVisible()
    store.updateText(editor.string)
    try await store.flush()
  }

  func testBrowserArrowKeysAndReturnChooseTheSelectedNote() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SanttyBrowser-\(UUID())")
    let suite = "SanttyBrowser.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for name in ["note.md", "Other.md"] {
      try Data(name.utf8).write(to: directory.appendingPathComponent(name))
    }
    let library = NotesLibrary(
      store: NotesStore(fileURL: directory.appendingPathComponent("note.md")), defaults: defaults)
    await library.load()
    let parent = NSPanel()
    var chosen: String?
    let browser = NotesBrowserWindowController(
      library: library, parent: parent,
      onSelect: { chosen = $0 }, onCreate: {}, onRename: { _ in }, onTrash: { _ in }, onDismiss: {})
    let panel = try XCTUnwrap(browser.window)
    XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
    XCTAssertFalse(panel.isOpaque)
    XCTAssertEqual(panel.frame.size, NSSize(width: 300, height: 122))
    library.browserSelection = library.visibleNotes[0].id
    let down = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero,
        modifierFlags: [.function, .numericPad], timestamp: 0, windowNumber: panel.windowNumber,
        context: nil, characters: "\u{f701}", charactersIgnoringModifiers: "\u{f701}",
        isARepeat: false, keyCode: 125))
    XCTAssertTrue(panel.performKeyEquivalent(with: down))
    XCTAssertEqual(library.browserSelection, library.visibleNotes[1].id)
    func keyEvent(_ key: String, modifiers: NSEvent.ModifierFlags, keyCode: UInt16) throws -> NSEvent {
      try XCTUnwrap(NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
        windowNumber: panel.windowNumber, context: nil, characters: key,
        charactersIgnoringModifiers: key, isARepeat: false, keyCode: keyCode))
    }
    let previous = try keyEvent("p", modifiers: .control, keyCode: 35)
    let next = try keyEvent("n", modifiers: .control, keyCode: 45)
    XCTAssertTrue(panel.performKeyEquivalent(with: previous))
    XCTAssertEqual(library.browserSelection, library.visibleNotes[0].id)
    XCTAssertTrue(panel.performKeyEquivalent(with: previous))
    XCTAssertEqual(library.browserSelection, library.visibleNotes[0].id)
    XCTAssertTrue(panel.performKeyEquivalent(with: next))
    XCTAssertEqual(library.browserSelection, library.visibleNotes[1].id)
    XCTAssertTrue(panel.performKeyEquivalent(with: next))
    XCTAssertEqual(library.browserSelection, library.visibleNotes[1].id)
    let toggle = try keyEvent("p", modifiers: [.command, .shift], keyCode: 35)
    XCTAssertTrue(panel.performKeyEquivalent(with: toggle))
    let content = NotesContentController(store: NotesStore(fileURL: directory.appendingPathComponent("note.md")), defaults: defaults)
    XCTAssertTrue(content.handleCommand(toggle))
    XCTAssertFalse(content.handleCommand(try keyEvent("p", modifiers: .command, keyCode: 35)))
    await content.waitForPendingOperations()
    let enter = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero,
        modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber,
        context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false,
        keyCode: 36))
    XCTAssertTrue(panel.performKeyEquivalent(with: enter))
    XCTAssertEqual(chosen, library.visibleNotes[1].id)
    library.searchQuery = "no matching document"
    await library.searchNow()
    browser.resizeToFit()
    XCTAssertEqual(panel.frame.size, NSSize(width: 300, height: 130))
    let selectionWithNoResults = library.browserSelection
    XCTAssertTrue(panel.performKeyEquivalent(with: previous))
    XCTAssertTrue(panel.performKeyEquivalent(with: next))
    XCTAssertEqual(library.browserSelection, selectionWithNoResults)
  }
}

@MainActor
final class NotesLibraryTests: XCTestCase {
  func testMultipleFilesSaveBeforeSwitchAndRestoreSelection() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SanttyLibrary-\(UUID())")
    let suite = "SanttyLibrary.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
    }
    let legacy = directory.appendingPathComponent("note.md")
    let library = NotesLibrary(store: NotesStore(fileURL: legacy), defaults: defaults)
    await library.load()
    XCTAssertNil(library.errorMessage)
    library.store.updateText("Legacy 中文 😀")
    try await library.create()
    XCTAssertEqual(try String(contentsOf: legacy, encoding: .utf8), "Legacy 中文 😀")
    XCTAssertEqual(library.activeID, "Untitled.md")
    library.store.updateText("Second document")
    try await library.create()
    XCTAssertEqual(library.activeID, "Untitled 2.md")
    try await library.rename(library.activeID, to: "项目计划")
    XCTAssertEqual(library.activeTitle, "项目计划")
    try await library.select("Untitled.md")
    XCTAssertEqual(library.store.text, "Second document")
    do {
      try await library.rename(library.activeID, to: "项目计划")
      XCTFail("Renaming must not overwrite another note")
    } catch {}
    XCTAssertEqual(library.activeID, "Untitled.md")
    XCTAssertEqual(
      try String(contentsOf: directory.appendingPathComponent("项目计划.md"), encoding: .utf8), "")
    let restored = NotesLibrary(store: NotesStore(fileURL: legacy), defaults: defaults)
    await restored.load()
    XCTAssertEqual(restored.activeID, "Untitled.md")
    XCTAssertEqual(restored.store.text, "Second document")
    XCTAssertEqual(library.notes.count, 3)
  }

  func testSearchMatchesTitleBodyAndUnsavedDraft() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SanttySearch-\(UUID())")
    let suite = "SanttySearch.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("Café roadmap\n中文正文".utf8).write(to: directory.appendingPathComponent("计划.md"))
    try Data("Other document\nroadmap".utf8).write(to: directory.appendingPathComponent("Other.md"))
    defaults.set("计划.md", forKey: "Santty.NotesLastFile")
    let library = NotesLibrary(
      store: NotesStore(fileURL: directory.appendingPathComponent("note.md")), defaults: defaults)
    await library.load()
    XCTAssertEqual(library.activeID, "计划.md")
    library.store.updateText(library.store.text + "\n尚未保存 token")
    library.searchQuery = "CAFE 计划"
    await library.searchNow()
    XCTAssertEqual(library.results.map(\.id), ["计划.md"])
    library.searchQuery = "token 尚未"
    await library.searchNow()
    XCTAssertEqual(library.results.first?.preview, "尚未保存 token")
    library.searchQuery = "no matches"
    await library.searchNow()
    XCTAssertTrue(library.results.isEmpty)
    try await library.store.flush()
  }

  func testInvalidPathsAndSaveFailureCannotDiscardCurrentDocument() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SanttyLibrarySafety-\(UUID())")
    let suite = "SanttyLibrarySafety.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("note.md")
    try Data("original".utf8).write(to: url)
    try Data("other".utf8).write(to: directory.appendingPathComponent("Other.md"))
    let library = NotesLibrary(store: NotesStore(fileURL: url), defaults: defaults)
    await library.load()
    for name in ["../outside", "", ".hidden", "name\nline"] {
      do {
        try await library.rename(library.activeID, to: name)
        XCTFail("Invalid note name accepted")
      } catch {}
    }
    do {
      try await library.select("../escape.md")
      XCTFail("Path traversal accepted")
    } catch {}
    try FileManager.default.createSymbolicLink(
      at: directory.appendingPathComponent("Alias.md"), withDestinationURL: url)
    do {
      try await library.select("Alias.md")
      XCTFail("Symbolic link accepted")
    } catch {}
    let originalStore = library.store
    originalStore.updateText("unsaved buffer")
    try FileManager.default.removeItem(at: url)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    do {
      try await library.select("Other.md")
      XCTFail("Switched despite save failure")
    } catch {}
    XCTAssertTrue(library.store === originalStore)
    XCTAssertEqual(library.store.text, "unsaved buffer")
    XCTAssertTrue(library.store.hasUnsavedChanges)
    XCTAssertNotNil(library.store.errorMessage)
    try FileManager.default.removeItem(at: url)
    do {
      try await library.store.flush()
      XCTFail("Recreating a deleted note requires explicit confirmation")
    } catch {}
    XCTAssertTrue(library.store.hasExternalChange)
    await library.store.resolveExternalChange(keepLocal: true)
    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "unsaved buffer")
  }
}

@MainActor
final class NotesFormattingTests: XCTestCase {
  func testFormattingPreservesUnicodeAndNativeUndo() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SanttyFormats-\(UUID())")
    let suite = "SanttyFormats.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let source = "你好 👩🏽‍💻"
    let url = directory.appendingPathComponent("note.md")
    try Data(source.utf8).write(to: url)
    let store = NotesStore(fileURL: url)
    await store.load()
    let controller = NotesWindowController(store: store, defaults: defaults)
    await controller.waitForPendingOperations()
    let content = try XCTUnwrap(controller.window?.contentView)
    content.layoutSubtreeIfNeeded()
    let editor = try XCTUnwrap(findEditor(content))
    controller.formatting.attach(editor)
    for (action, expected) in [
      (NotesFormat.bold, "**\(source)**"), (.italic, "*\(source)*"),
      (.strikethrough, "~~\(source)~~"), (.inlineCode, "`\(source)`"),
    ] {
      editor.setSelectedRange(NSRange(location: 0, length: source.utf16.count))
      controller.formatting.apply(action)
      XCTAssertEqual(editor.string, expected)
      XCTAssertEqual(editor.selectedRange().length, source.utf16.count)
      editor.undoManager?.undo()
      XCTAssertEqual(editor.string, source)
      editor.undoManager?.removeAllActions()
    }
    editor.setSelectedRange(NSRange(location: 0, length: source.utf16.count))
    controller.formatting.apply(.link, url: "https://example.com")
    XCTAssertEqual(editor.string, "[\(source)](https://example.com)")
    XCTAssertEqual(editor.selectedRange().location, editor.string.utf16.count)
    editor.undoManager?.undo()
    XCTAssertEqual(editor.string, source)
    editor.undoManager?.removeAllActions()
    editor.setSelectedRange(NSRange(location: 0, length: source.utf16.count))
    controller.formatting.apply(.codeBlock)
    XCTAssertEqual(editor.string, "```\n\(source)\n```\n")
    editor.undoManager?.undo()
    XCTAssertEqual(editor.string, source)
    editor.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
    editor.setMarkedText(
      "pin", selectedRange: NSRange(location: 3, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0))
    let marked = editor.string
    controller.formatting.apply(.bold)
    XCTAssertEqual(editor.string, marked)
    XCTAssertTrue(editor.hasMarkedText())
    controller.createNote()
    XCTAssertEqual(controller.library.activeID, "note.md")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: directory.appendingPathComponent("Untitled.md").path))
    editor.insertText("拼音", replacementRange: editor.markedRange())
    store.updateText(editor.string)
    try await store.flush()
  }

  func testParagraphFormatsAndFileSwitchKeepIndependentUndo() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SanttyParagraphs-\(UUID())")
    let suite = "SanttyParagraphs.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let source = "第一项 😀\n第二项\n"
    let url = directory.appendingPathComponent("note.md")
    try Data(source.utf8).write(to: url)
    let store = NotesStore(fileURL: url)
    await store.load()
    let controller = NotesWindowController(store: store, defaults: defaults)
    await controller.waitForPendingOperations()
    let content = try XCTUnwrap(controller.window?.contentView)
    content.layoutSubtreeIfNeeded()
    let editor = try XCTUnwrap(findEditor(content))
    controller.formatting.attach(editor)
    for (action, expected) in [
      (NotesFormat.unorderedList, "- 第一项 😀\n- 第二项\n"), (.orderedList, "1. 第一项 😀\n2. 第二项\n"),
      (.taskList, "- [ ] 第一项 😀\n- [ ] 第二项\n"), (.blockquote, "> 第一项 😀\n> 第二项\n"),
    ] {
      editor.setSelectedRange(NSRange(location: 0, length: source.utf16.count))
      controller.formatting.apply(action)
      XCTAssertEqual(editor.string, expected)
      controller.formatting.apply(action)
      XCTAssertEqual(editor.string, source)
      editor.undoManager?.removeAllActions()
    }
    editor.setSelectedRange(NSRange(location: 0, length: source.utf16.count))
    controller.formatting.applyHeading(2)
    XCTAssertEqual(editor.string, "## 第一项 😀\n## 第二项\n")
    controller.formatting.applyHeading(0)
    XCTAssertEqual(editor.string, source)
    editor.insertText("末尾", replacementRange: NSRange(location: source.utf16.count, length: 0))
    controller.createNote()
    await controller.waitForPendingOperations()
    try await Task.sleep(for: .milliseconds(50))
    content.layoutSubtreeIfNeeded()
    let nextEditor = try XCTUnwrap(findEditor(content))
    XCTAssertFalse(nextEditor === editor)
    XCTAssertEqual(controller.library.activeID, "Untitled.md")
    XCTAssertEqual(nextEditor.string, "")
    nextEditor.undoManager?.undo()
    XCTAssertEqual(nextEditor.string, "")
    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), source + "末尾")
    controller.formatting.attach(nextEditor)
    nextEditor.insertText("new", replacementRange: NSRange(location: 0, length: 0))
    nextEditor.setSelectedRange(NSRange(location: 0, length: 3))
    controller.formatting.apply(.bold)
    XCTAssertEqual(nextEditor.string, "**new**")
    XCTAssertEqual(editor.string, source + "末尾")
    nextEditor.insertText(
      "", replacementRange: NSRange(location: 0, length: nextEditor.string.utf16.count))
    nextEditor.undoManager?.removeAllActions()
    controller.formatting.apply(.taskList)
    XCTAssertEqual(nextEditor.string, "- [ ] ")
    XCTAssertEqual(nextEditor.selectedRange().location, 6)
    nextEditor.undoManager?.undo()
    XCTAssertEqual(nextEditor.string, "")
    nextEditor.insertText("``` hi", replacementRange: NSRange(location: 0, length: 0))
    nextEditor.setSelectedRange(NSRange(location: 0, length: nextEditor.string.utf16.count))
    controller.formatting.apply(.codeBlock)
    XCTAssertEqual(nextEditor.string, "````\n``` hi\n````\n")
    controller.store.updateText(nextEditor.string)
    try await controller.store.flush()
  }

  private func findEditor(_ view: NSView) -> NSTextView? {
    if let editor = view as? NSTextView { return editor }
    return view.subviews.lazy.compactMap(findEditor).first
  }
}

@MainActor
final class NotesRendererTests: XCTestCase {
  func testCursorAndListMarkersFollowAccentColorChangesAndReset() throws {
    let keys = ["appearance.accentColor"] + ["red", "green", "blue", "alpha"].map {
      "appearance.accentColor.\($0)"
    }
    let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
    defer {
      for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) }
      NotificationCenter.default.post(name: AppAppearanceSettings.didChangeNotification, object: nil)
    }
    AppAppearanceSettings.accentColor = .systemOrange
    let editor = NotesTextView(usingTextLayoutManager: true)
    editor.configure()
    let source = "- [ ] Task\n- [x] Checked\n\n- Bullet\n\n1. Number\n"
    editor.string = source
    editor.renderer.render(force: true)
    func assertAccentColor() throws {
      XCTAssertEqual(editor.insertionPointColor, AppAppearanceSettings.accentColor)
      for marker in ["- [ ]", "- [x]", "- Bullet", "1."] {
        let decoration = try XCTUnwrap(
          editor.textStorage?.attribute(
            .notesDecoration, at: (source as NSString).range(of: marker).location,
            effectiveRange: nil) as? NotesBlockDecoration)
        XCTAssertEqual(decoration.accentColor, AppAppearanceSettings.accentColor)
      }
      XCTAssertEqual(editor.string, source)
      XCTAssertFalse(editor.undoManager?.canUndo ?? true)
    }
    try assertAccentColor()
    AppAppearanceSettings.accentColor = .systemPurple
    try assertAccentColor()
    AppAppearanceSettings.resetAccentColor()
    try assertAccentColor()
  }

  func testNodesOnSameLineRevealIndependentlyAtCaretBoundaries() throws {
    let source = "- [ ] 中文 😀 **bold** and `code` and [link](https://example.com)\n"
    let editor = NotesTextView(usingTextLayoutManager: true)
    editor.configure()
    editor.string = source
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.contentView = editor
    window.makeFirstResponder(editor)
    let storage = try XCTUnwrap(editor.textStorage)
    let original = source as NSString
    let nodes = ["- [ ]", "**bold**", "`code`", "[link](https://example.com)"]
    func assertRevealed(_ active: Set<Int>, selection: NSRange) throws {
      editor.setSelectedRange(selection)
      editor.renderer.render()
      for (index, node) in nodes.enumerated() {
        let range = original.range(of: node)
        for position in [range.location, NSMaxRange(range) - 1] {
          let font = try XCTUnwrap(
            storage.attribute(.font, at: position, effectiveRange: nil) as? NSFont)
          XCTAssertEqual(font.pointSize > 1, active.contains(index), "\(node) at \(selection)")
        }
      }
      XCTAssertEqual(
        storage.attribute(.notesDecoration, at: 0, effectiveRange: nil) == nil, active.contains(0))
    }
    try assertRevealed(
      [], selection: NSRange(location: original.range(of: "中文").location, length: 0))
    for (index, node) in nodes.enumerated() {
      let range = original.range(of: node)
      for position in [range.location, range.location + 1, NSMaxRange(range)] {
        try assertRevealed([index], selection: NSRange(location: position, length: 0))
      }
      try assertRevealed([], selection: NSRange(location: NSMaxRange(range) + 1, length: 0))
    }
    let bold = original.range(of: "**bold**")
    let code = original.range(of: "`code`")
    try assertRevealed(
      [1, 2],
      selection: NSRange(location: bold.location + 2, length: NSMaxRange(code) - bold.location - 2))
    XCTAssertEqual(editor.string, source)
    XCTAssertFalse(editor.undoManager?.canUndo ?? true)
  }

  func testMultilineCodeNodeRevealsBothFencesWithoutRevealingNeighbor() throws {
    let source = "```swift\nlet value = 1\n```\n\n**neighbor**\n"
    let editor = NotesTextView(usingTextLayoutManager: true)
    editor.configure()
    editor.string = source
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.contentView = editor
    window.makeFirstResponder(editor)
    editor.setSelectedRange(
      NSRange(location: (source as NSString).range(of: "value").location, length: 0))
    editor.renderer.render(force: true)
    let storage = try XCTUnwrap(editor.textStorage)
    for position in [0, (source as NSString).range(of: "```\n").location] {
      let font = try XCTUnwrap(
        storage.attribute(.font, at: position, effectiveRange: nil) as? NSFont)
      XCTAssertGreaterThan(font.pointSize, 1)
    }
    let neighbor = (source as NSString).range(of: "**neighbor**").location
    let font = try XCTUnwrap(
      storage.attribute(.font, at: neighbor, effectiveRange: nil) as? NSFont)
    XCTAssertLessThan(font.pointSize, 1)
  }

  func testInlineCodeWithBackticksTogglesWithoutLosingUnicode() throws {
    let source = "`中文 👩🏽‍💻`"
    let editor = NotesTextView(usingTextLayoutManager: true)
    editor.configure()
    editor.string = source
    editor.renderer.render(force: true)
    let formatting = NotesFormatting()
    formatting.attach(editor)
    editor.setSelectedRange(NSRange(location: 0, length: source.utf16.count))
    formatting.apply(.inlineCode)
    let wrapped = "`` " + source + " ``"
    XCTAssertEqual(editor.string, wrapped)
    editor.undoManager?.removeAllActions()
    formatting.apply(.inlineCode)
    XCTAssertEqual(editor.string, source)
    editor.undoManager?.undo()
    XCTAssertEqual(editor.string, wrapped)
  }

  func testToolbarStateUsesMarkdownSyntaxRatherThanPresentationFonts() throws {
    let source = "# Heading\n\n**bold**\n\n- [x] checked\n\n```\n- plain\n```\n"
    let editor = NotesTextView(usingTextLayoutManager: true)
    editor.configure()
    editor.string = source
    editor.renderer.render(force: true)
    let formatting = NotesFormatting()
    formatting.attach(editor)
    for (text, expected) in [
      ("Heading", Set<NotesFormat>()), ("bold", [.bold]), ("checked", [.taskList]),
      ("plain", [.codeBlock]),
    ] {
      editor.setSelectedRange(
        NSRange(location: (source as NSString).range(of: text).location, length: 0))
      formatting.refresh()
      XCTAssertEqual(formatting.active, expected)
    }
  }

  func testSourceLocationsAndNestedStylingPreserveUnicodeAndCRLF() throws {
    let source =
      "中文 👩🏽‍💻 **粗体 *斜体*** [链接](https://example.com)\r\n\r\n`**literal**`\r\n\r\n```swift\r\n- [x] literal\r\n```\r\n\r\n- [x] 完成 😀\r\n  - nested\r\n\r\n7. ordered\r\n\r\n> quote\r\n"
    let editor = NotesTextView(usingTextLayoutManager: true)
    editor.configure()
    editor.string = source
    editor.renderer.render(force: true)
    let storage = try XCTUnwrap(editor.textStorage)
    let original = source as NSString
    func font(_ text: String) throws -> NSFont {
      try XCTUnwrap(
        storage.attribute(.font, at: original.range(of: text).location, effectiveRange: nil)
          as? NSFont)
    }
    XCTAssertEqual(editor.string, source)
    XCTAssertTrue(NSFontManager.shared.traits(of: try font("粗体")).contains(.boldFontMask))
    let nestedTraits = NSFontManager.shared.traits(of: try font("斜体"))
    XCTAssertTrue(nestedTraits.contains(.boldFontMask))
    XCTAssertTrue(nestedTraits.contains(.italicFontMask))
    XCTAssertNotNil(
      storage.attribute(.link, at: original.range(of: "链接").location, effectiveRange: nil))
    XCTAssertEqual((try font("**literal**")).pointSize, 15)
    XCTAssertNil(
      storage.attribute(
        .strikethroughStyle, at: original.range(of: "literal\r\n").location, effectiveRange: nil),
      "Code must not be styled as a task")
    let checked = try XCTUnwrap(
      storage.attribute(
        .notesDecoration, at: original.range(of: "- [x] 完成").location, effectiveRange: nil)
        as? NotesBlockDecoration)
    guard case .task(true, let state) = checked.kind else {
      return XCTFail("Missing checked task decoration")
    }
    XCTAssertEqual(original.substring(with: state), "x")
    XCTAssertNotNil(
      storage.attribute(
        .strikethroughStyle, at: original.range(of: "完成").location, effectiveRange: nil))
    XCTAssertLessThan(
      (try font("**粗体")).pointSize, 1, "Markdown markers should collapse outside the active node")
    let mapping = NotesSourceMap(source)
    XCTAssertEqual(
      mapping.offset(SourceLocation(line: 1, column: "中文 👩🏽‍💻 ".utf8.count + 1, source: nil)),
      original.range(of: "**粗体").location)
    XCTAssertEqual(
      mapping.offset(SourceLocation(line: 3, column: 1, source: nil)),
      original.range(of: "`**literal**`").location)
  }

  func testSelectionRevealsSyntaxWithoutChangingSourceOrUndo() throws {
    let source = "**中文 😀**\n\n- [ ] Task\n"
    let editor = NotesTextView(usingTextLayoutManager: true)
    editor.configure()
    editor.string = source
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.contentView = editor
    window.makeFirstResponder(editor)
    editor.setSelectedRange(NSRange(location: 2, length: 0))
    editor.renderer.render(force: true)
    var markerFont = try XCTUnwrap(
      editor.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
    XCTAssertGreaterThan(markerFont.pointSize, 1)
    editor.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
    editor.renderer.render()
    markerFont = try XCTUnwrap(
      editor.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
    XCTAssertLessThan(markerFont.pointSize, 1)
    XCTAssertEqual(editor.string, source)
    XCTAssertFalse(editor.undoManager?.canUndo ?? true)
  }

  func testCompositionPublishesOnlyCommittedTextAndListReturnSupportsUndo() async throws {
    let editor = NotesTextView(usingTextLayoutManager: true)
    editor.configure()
    editor.string = "- [x] 第一项 😀"
    editor.renderer.render(force: true)
    var published = [String]()
    editor.onTextChange = { published.append($0) }
    editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
    editor.insertNewline(nil)
    XCTAssertEqual(editor.string, "- [x] 第一项 😀\n- [ ] ")
    editor.insertNewline(nil)
    XCTAssertEqual(editor.string, "- [x] 第一项 😀\n")
    // Programmatic commands in one event share the native Undo group.
    editor.undoManager?.undo()
    XCTAssertEqual(editor.string, "- [x] 第一项 😀")
    editor.undoManager?.redo()
    XCTAssertEqual(editor.string, "- [x] 第一项 😀\n")
    editor.undoManager?.undo()
    XCTAssertEqual(editor.string, "- [x] 第一项 😀")
    editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
    published.removeAll()
    editor.setMarkedText(
      "pin", selectedRange: NSRange(location: 3, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0))
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertFalse(published.contains(where: { $0.hasSuffix("pin") }))
    editor.insertText("拼音", replacementRange: editor.markedRange())
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertEqual(published.last, "- [x] 第一项 😀拼音")
  }
}
