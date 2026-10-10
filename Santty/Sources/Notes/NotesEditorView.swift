import AppKit
import SwiftUI

enum NotesLayout {
    static let titleBarHeight: CGFloat = 52
    static let footerToolbarHeight: CGFloat = 36
    static let footerVerticalPadding: CGFloat = 8
    static let footerHeight = footerToolbarHeight + footerVerticalPadding * 2
}

@MainActor
struct NotesEditorView: View {
    @Bindable var library: NotesLibrary
    let formatting: NotesFormatting
    @State var isPinned: Bool
    var isPane = false
    @State private var footerHeight = NotesLayout.footerHeight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var onTogglePin: () -> Bool
    var onEditorReady: (CGFloat) -> Void
    var onCreate: () -> Void
    var onBrowse: () -> Void
    var onOpenFolder: () -> Void
    var onFormat: (NotesFormat) -> Void
    var onHeading: (Int) -> Void

    private var store: NotesStore { library.store }

    var body: some View {
        editorWithBars
            .background(Color.black.opacity(isPane ? 0 : 0.40))
            .background {
                if isPane {
                    NotesPaneBackground()
                } else {
                    NotesGlassBackground()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: isPane ? AppAppearanceSettings.paneCornerRadius : 26, style: .continuous))
            .ignoresSafeArea()
            .preferredColorScheme(.dark)
            .onAppear { DispatchQueue.main.async { onEditorReady(footerHeight) } }
            .onChange(of: store.fileURL) { _, _ in
                DispatchQueue.main.async { onEditorReady(footerHeight) }
            }
            .onChange(of: library.isWorking) { _, working in
                if !working { DispatchQueue.main.async { onEditorReady(footerHeight) } }
            }
            .onChange(of: footerHeight) { _, height in
                DispatchQueue.main.async { onEditorReady(height) }
            }
    }

    private func editor(minimumHeight: CGFloat) -> some View {
        ScrollView {
            NotesNativeEditor(
                text: Binding(
                    get: { [store] in store.text }, set: { [store] in store.updateText($0) }),
                isEditable: store.canEdit && !library.isWorking,
                bottomBarHeight: footerHeight,
                documentID: store.documentID
            )
            .frame(maxWidth: .infinity, minHeight: max(0, minimumHeight), alignment: .top)
            .accessibilityLabel("Notes editor")
        }
        .scrollClipDisabled()
        .id(store.fileURL.path)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var editorWithBars: some View {
        GeometryReader { geometry in
            if #available(macOS 26.0, *) {
                editor(minimumHeight: geometry.size.height - NotesLayout.titleBarHeight - footerHeight)
                    .safeAreaBar(edge: .top, spacing: 0) { titleBar }
                    .safeAreaBar(edge: .bottom, spacing: 0) { footer }
                    .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
            } else {
                editor(minimumHeight: geometry.size.height)
                    .overlay(alignment: .top) {
                        titleBar.background { edgeBackdrop(top: true, height: NotesLayout.titleBarHeight) }
                    }
                    .overlay(alignment: .bottom) {
                        footer.background { edgeBackdrop(top: false, height: footerHeight) }
                    }
            }
        }
    }

    private func edgeBackdrop(top: Bool, height: CGFloat) -> some View {
        Rectangle().fill(.ultraThinMaterial).frame(height: height)
            .mask(
                LinearGradient(
                    colors: top ? [.black, .black, .clear] : [.clear, .black, .black],
                    startPoint: .top,
                    endPoint: .bottom)
            )
            .allowsHitTesting(false)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = store.errorMessage ?? library.errorMessage {
                VStack(alignment: .leading, spacing: 6) {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                    if store.hasExternalChange {
                        ViewThatFits(in: .horizontal) {
                            HStack { conflictActions }
                            VStack(alignment: .leading) { conflictActions }
                        }
                        .disabled(store.isSaving || store.isSavingSuspended || library.isWorking)
                    } else {
                        Button("Retry") {
                            Task {
                                if store.hasReadError {
                                    await store.load()
                                } else if store.errorMessage != nil {
                                    try? await store.flush()
                                } else {
                                    await library.refresh()
                                }
                            }
                        }.disabled(
                            store.isLoading || store.isSaving || store.isSavingSuspended
                                || library.isWorking)
                    }
                }.font(.system(size: 12))
            }
            GeometryReader { geometry in
                let barWidth = min(
                    library.isFormattingExpanded ? 394.0 : 36.0, geometry.size.width)
                let remainingWidth = max(0, geometry.size.width - barWidth)
                let count = "\(store.text.count) characters"
                let countWidth = (count as NSString).size(withAttributes: [
                    .font: NSFont.systemFont(ofSize: 12)
                ]).width
                HStack(spacing: min(8, remainingWidth)) {
                    Group {
                        if remainingWidth >= ceil(countWidth) + 8 {
                            Text(count)
                                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize()
                                .help(status)
                        } else {
                            Color.clear.frame(height: 0)
                        }
                    }
                    .frame(width: max(0, remainingWidth - 8), alignment: .leading)
                    formattingToolbar.frame(width: barWidth)
                }
            }
            .frame(height: NotesLayout.footerToolbarHeight)
            .animation(
                reduceMotion ? nil : .timingCurve(0.16, 1, 0.3, 1, duration: 0.34),
                value: library.isFormattingExpanded)
        }.padding(.leading, 16).padding(.trailing, 8)
            .padding(.vertical, NotesLayout.footerVerticalPadding)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) {
                footerHeight = max(NotesLayout.footerHeight, $0)
            }
    }

    private var conflictActions: some View {
        Group {
            Button("Use File Version") {
                Task { await store.resolveExternalChange(keepLocal: false) }
            }
            Button("Overwrite File") {
                Task { await store.resolveExternalChange(keepLocal: true) }
            }
        }
    }

    private var titleBar: some View {
        GeometryReader { geometry in
            ZStack {
                if !isPane { NotesTitlebarDragRegion() }
                if isPane || geometry.size.width >= 480 {
                    Text(library.activeTitle).font(.headline).lineLimit(1)
                        .padding(.leading, isPane ? 16 : 170)
                        .padding(.trailing, isPane ? 132 : 170)
                        .frame(maxWidth: .infinity, alignment: isPane ? .leading : .center)
                        .allowsHitTesting(false)
                }
                HStack {
                    Spacer()
                    windowControls.padding(.trailing, 8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }.frame(height: NotesLayout.titleBarHeight)
    }

    private var controls: some View {
        HStack(spacing: 0) {
            NotesToolbarButton(symbol: "plus", title: "New Note (⌘N)", action: onCreate)
                .disabled(library.isWorking || store.isSavingSuspended)
            NotesToolbarButton(
                symbol: "rectangle.stack", title: "Browse Notes (⇧⌘P)",
                active: library.isBrowserPresented, action: onBrowse
            )
            .disabled(library.isWorking || store.isSavingSuspended)
            NotesToolbarButton(
                symbol: "folder", title: "Open Notes Folder (⌘O)", action: onOpenFolder)
            if !isPane {
                NotesToolbarButton(
                    symbol: isPinned ? "pin.fill" : "pin",
                    title: isPinned ? "Unpin Notes" : "Keep Notes on Top", active: isPinned
                ) {
                    isPinned = onTogglePin()
                }
            }
        }.padding(4)
    }

    @ViewBuilder
    private var windowControls: some View {
        if #available(macOS 26.0, *) {
            controls.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            controls.background(.regularMaterial, in: Capsule())
        }
    }

    private var formattingToolbar: some View {
        HStack(spacing: 6) {
            if library.isFormattingExpanded {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Menu {
                            Button("Text") { onHeading(0) }
                            ForEach(1...6, id: \.self) { level in
                                Button("Heading \(level)") { onHeading(level) }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "textformat.size").font(.system(size: 16)).frame(
                                    width: 16, height: 16)
                                Image(systemName: "chevron.down").font(
                                    .system(size: 8, weight: .semibold))
                            }
                            .frame(width: 40, height: 28).contentShape(Capsule())
                            .background(
                                Capsule().fill(
                                    formatting.headingLevel > 0 ? Color.white.opacity(0.18) : .clear
                                )
                            )
                            .accessibilityElement(children: .combine)
                        }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).focusable(
                            false
                        )
                        .accessibilityLabel("Heading Level").help("Heading Level")
                        formatGroup([.bold, .italic, .strikethrough, .inlineCode, .link])
                        formatGroup([.codeBlock, .blockquote])
                        formatGroup([.orderedList, .unorderedList, .taskList])
                    }
                    .disabled(!store.canEdit || library.isWorking || store.isSavingSuspended)
                }
                .transition(.scale(scale: 0.6, anchor: .trailing).combined(with: .opacity))
            }
            NotesToolbarButton(
                symbol: "paintbrush", title: "Formatting Toolbar (⌥⌘T)",
                active: library.isFormattingExpanded, width: 28
            ) {
                library.isFormattingExpanded.toggle()
            }
            .zIndex(1)
        }
        .padding(4)
        .background { Capsule().fill(Color.clear).notesGlass(in: Capsule()) }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .contain).accessibilityLabel("Formatting")
    }

    private func formatGroup(_ actions: [NotesFormat]) -> some View {
        HStack(spacing: 2) {
            ForEach(actions, id: \.self) { action in
                NotesToolbarButton(
                    symbol: action.symbol, title: action.title,
                    active: formatting.active.contains(action), width: 28
                ) { onFormat(action) }
            }
        }
    }

    private var status: String {
        if !store.isLoaded { return "Loading…" }
        if store.isSavingSuspended { return "Writing Tools…" }
        if store.isSaving || library.isWorking { return "Saving…" }
        if store.hasUnsavedChanges { return "Unsaved" }
        return store.hasReadError ? "Read unavailable" : "Saved"
    }
}

struct NotesToolbarButton: View {
    let symbol: String
    let title: String
    var active = false
    var width: CGFloat = 32
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 16)).symbolRenderingMode(.hierarchical)
                .frame(width: width, height: 28).contentShape(Capsule())
                .background(
                    Capsule().fill(
                        active
                            ? Color.white.opacity(0.18)
                            : hovered ? Color.white.opacity(0.10) : .clear))
        }
        .buttonStyle(.plain).focusable(false).onHover { hovered = $0 }
        .accessibilityLabel(title).help(title)
    }
}

extension View {
    @ViewBuilder
    func notesGlass<S: Shape>(in shape: S) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }
}

private struct NotesPaneBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        AppAppearanceDefaults.makeVibrancyView(tintViewAlpha: AppAppearanceDefaults.vibrancyTintAlpha)
    }

    func updateNSView(_: NSVisualEffectView, context: Context) {}
}

private struct NotesGlassBackground: View {
    var body: some View {
        if #available(macOS 26.0, *) {
            NotesGlassEffectView()
        } else {
            Rectangle().fill(.regularMaterial)
        }
    }
}

@available(macOS 26.0, *)
private struct NotesGlassEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSGlassEffectView { NSGlassEffectView() }
    func updateNSView(_: NSGlassEffectView, context: Context) {}
}

private struct NotesTitlebarDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> NotesTitlebarDragView { NotesTitlebarDragView() }
    func updateNSView(_: NotesTitlebarDragView, context: Context) {}
}

private final class NotesTitlebarDragView: NSView {
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}
