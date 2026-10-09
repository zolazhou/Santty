import AppKit
import SwiftUI

@MainActor
final class NotesBrowserWindowController: NSWindowController, NSWindowDelegate {
    private let library: NotesLibrary
    private weak var parent: NSWindow?
    private let onSelect: (String) -> Void
    private let onDismiss: () -> Void

    init(library: NotesLibrary, parent: NSWindow, onSelect: @escaping (String) -> Void,
         onCreate: @escaping () -> Void, onRename: @escaping (String) -> Void,
         onTrash: @escaping (String) -> Void, onDismiss: @escaping () -> Void) {
        self.library = library
        self.parent = parent
        self.onSelect = onSelect
        self.onDismiss = onDismiss
        super.init(window: nil)
        let panel = NotesBrowserPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 130),
                                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Browse Notes"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.dismiss(restoreFocus: true) }
        panel.onNavigate = { [weak self] offset in self?.navigate(offset) }
        panel.onChoose = { [weak self] in
            guard let self, let id = self.library.browserSelection else { return }
            self.onSelect(id)
        }
        panel.onCreate = onCreate
        let hosting = NSHostingView(rootView: NotesBrowserView(library: library, onSelect: onSelect,
                                                              onRename: onRename, onTrash: onTrash,
                                                              onResize: { [weak self] in self?.resizeToFit() }))
        hosting.sizingOptions = []
        panel.contentView = hosting
        window = panel
        resizeToFit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show() {
        guard let window, let parent else { return }
        library.isBrowserPresented = true
        library.searchQuery = ""
        library.browserSelection = library.activeID
        resizeToFit()
        parent.addChildWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
        Task { await library.refresh() }
    }

    func resizeToFit() {
        guard let window, let parent else { return }
        let resultsHeight = library.visibleNotes.isEmpty ? 96 : CGFloat(library.visibleNotes.count) * 36 + 16
        let height = min(240, 34 + resultsHeight + (library.errorMessage == nil ? 0 : 60))
        window.setFrame(NSRect(x: parent.frame.midX - 150, y: parent.frame.maxY - 108 - height,
                               width: 300, height: height), display: window.isVisible)
        window.invalidateShadow()
    }

    func dismiss(restoreFocus: Bool = false) {
        guard library.isBrowserPresented else { return }
        if let window { parent?.removeChildWindow(window); window.orderOut(nil) }
        library.isBrowserPresented = false
        if restoreFocus { parent?.makeKeyAndOrderFront(nil) }
        onDismiss()
    }

    func windowDidResignKey(_: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window?.isKeyWindow != true, self.window?.attachedSheet == nil else { return }
            self.dismiss()
        }
    }

    func navigate(_ offset: Int) {
        let notes = library.visibleNotes
        guard !notes.isEmpty else { return }
        let current = notes.firstIndex { $0.id == library.browserSelection } ?? (offset > 0 ? -1 : notes.count)
        library.browserSelection = notes[min(max(0, current + offset), notes.count - 1)].id
    }
}

private struct NotesBrowserView: View {
    @Bindable var library: NotesLibrary
    var onSelect: (String) -> Void
    var onRename: (String) -> Void
    var onTrash: (String) -> Void
    var onResize: () -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(.secondary)
                TextField("Search notes…", text: $library.searchQuery)
                    .textFieldStyle(.plain).focused($searchFocused).accessibilityLabel("Search notes")
                if library.isSearching { ProgressView().controlSize(.small) }
                else if !library.searchQuery.isEmpty {
                    Button { library.searchQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.plain).focusable(false).accessibilityLabel("Clear Search")
                }
            }.font(.system(size: 14)).padding(.horizontal, 12).frame(height: 34)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(library.visibleNotes) { note in
                            NotesBrowserRow(note: note, selected: note.id == library.browserSelection,
                                            onSelect: { onSelect(note.id) }, onRename: { onRename(note.id) },
                                            onTrash: { onTrash(note.id) })
                                .disabled(library.isWorking).id(note.id)
                        }
                        if library.visibleNotes.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: library.isSearching ? "clock" : "text.page").font(.system(size: 16))
                                Text(library.isSearching ? "Searching notes…" : "No notes found")
                            }.foregroundStyle(.secondary).frame(maxWidth: .infinity).frame(height: 80)
                        }
                    }.padding(8)
                }
                .onChange(of: library.browserSelection) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .center) }
                }
            }
            if let error = library.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    .lineLimit(3).padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
        .notesGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .preferredColorScheme(.dark).ignoresSafeArea()
        .onAppear { searchFocused = true }
        .onChange(of: library.visibleNotes.map(\.id)) { _, ids in
            if !ids.contains(library.browserSelection ?? "") { library.browserSelection = ids.first }
            DispatchQueue.main.async { onResize() }
        }
        .onChange(of: library.errorMessage) { _, _ in DispatchQueue.main.async { onResize() } }
    }
}

private struct NotesBrowserRow: View {
    let note: NoteSummary
    let selected: Bool
    var onSelect: () -> Void
    var onRename: () -> Void
    var onTrash: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onSelect) {
                HStack(spacing: 10) {
                    Image(systemName: "text.page").font(.system(size: 16)).foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                    Text(note.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
            }
            .buttonStyle(.plain).focusable(false).accessibilityLabel(note.title).help(note.preview)
            if selected || hovered {
                Button(action: onRename) { Image(systemName: "pencil").frame(width: 16, height: 28).contentShape(Rectangle()) }
                    .buttonStyle(.plain).focusable(false).accessibilityLabel("Rename \(note.title)").help("Rename")
                Button(action: onTrash) { Image(systemName: "trash").frame(width: 16, height: 28).contentShape(Rectangle()) }
                    .buttonStyle(.plain).focusable(false).foregroundStyle(.red)
                    .accessibilityLabel("Move \(note.title) to Trash").help("Move to Trash")
            }
        }
        .padding(.horizontal, 8).frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(selected ? Color.white.opacity(0.13) : hovered ? Color.white.opacity(0.07) : .clear))
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Rename…", action: onRename)
            Button("Move to Trash", role: .destructive, action: onTrash)
        }
    }
}

@MainActor
private final class NotesBrowserPanel: NSPanel {
    var onCancel: (() -> Void)?
    var onNavigate: ((Int) -> Void)?
    var onChoose: (() -> Void)?
    var onCreate: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        if let editor = firstResponder as? NSTextView, editor.hasMarkedText() { super.cancelOperation(sender); return }
        onCancel?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard attachedSheet == nil else { return super.performKeyEquivalent(with: event) }
        if let editor = firstResponder as? NSTextView, editor.hasMarkedText() { return super.performKeyEquivalent(with: event) }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if modifiers == .control {
            if key == "p" { onNavigate?(-1); return true }
            if key == "n" { onNavigate?(1); return true }
        }
        if modifiers.isEmpty {
            if event.keyCode == 125 { onNavigate?(1); return true }
            if event.keyCode == 126 { onNavigate?(-1); return true }
            if event.keyCode == 36 || event.keyCode == 76 { onChoose?(); return true }
            if event.keyCode == 53 { onCancel?(); return true }
        }
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "n" { onCreate?(); return true }
        if (modifiers == [.command, .shift] && key == "p") || (modifiers == .command && key == "w") { onCancel?(); return true }
        return super.performKeyEquivalent(with: event)
    }
}
