import AppKit

/// Explicit responder/menu/drop actions, not a pane resolver or CLI mutation
/// route. Deferred consent is single-use and bound to this exact writer epoch.
@MainActor
final class NativeTerminalHostActions {
    enum Action { case copy, paste, selectAll, zoom }
    private weak var view: NativeTerminalScrollView?
    private struct Pending {
        let review: NativeHostPasteReview
        let text: String
        let output: NativeTerminalOutput
        let lease: NativeUserInputLease
        let context: NativeHostPasteContext
        let created: TimeInterval
    }
    private var pending: Pending?
    private let clock: () -> TimeInterval
    var pasteboard: () -> NSPasteboard = { .general }
    var reviewPresenter: ((NativeHostPasteReview, @escaping @MainActor (Bool) -> Void) -> Void)?
    var zoomResetSize: CGFloat = 13
    private(set) var lastError: String?
    var pendingReviewID: UUID? { pending?.review.id }
    static let maximumPasteBytes = 1024 * 1024
    static let maximumReviewAge: TimeInterval = 120

    init(view: NativeTerminalScrollView, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.view = view; self.clock = clock
    }
    private var focused: Bool {
        guard let view, !view.isHiddenOrHasHiddenAncestor, !view.renderer.isHiddenOrHasHiddenAncestor,
              let window = view.window else { return false }
        return window.firstResponder === view.renderer && window.attachedSheet == nil
    }
    private var live: Bool {
        guard let view, !view.isHiddenOrHasHiddenAncestor, !view.renderer.isHiddenOrHasHiddenAncestor else { return false }
        guard let output = view.renderer.output, output.driver === view.driver else { return false }
        return view.renderer.inputEnabled && !view.scrollModeController.isActive && output.userInputLease != nil
    }
    func canPerform(_ action: Action) -> Bool {
        guard let view, focused else { return false }
        switch action {
        case .copy: return view.presentedFrame != nil
        case .paste: return live
        case .selectAll: return view.presentedFrame != nil && !view.scrollModeController.isActive
        case .zoom: return view.presentedFrame != nil
        }
    }
    func invalidateReview() { pending = nil }

    @discardableResult func copy() -> Bool {
        guard canPerform(.copy), let view else { return false }
        return view.copySelection(to:pasteboard())
    }
    func selectAll() {
        guard canPerform(.selectAll), let view else { return }
        view.renderer.onSelectAll?()
    }
    func dragOperation(types: [NSPasteboard.PasteboardType]?) -> NSDragOperation {
        guard live, let types, !Set(types).isDisjoint(with:TerminalPasteboardText.dropTypes) else { return [] }
        return .copy
    }
    @discardableResult func paste() -> NativeHostActionResult {
        guard canPerform(.paste) else { return .refused }
        let board = pasteboard()
        guard let text = TerminalPasteboardText.urlInsertionText(from:board) ?? board.string(forType:.string) else { return .refused }
        return submit(text)
    }
    @discardableResult func drop(from board: NSPasteboard) -> NativeHostActionResult {
        guard live, let view, let output = view.renderer.output, let lease = output.userInputLease,
              let text = TerminalPasteboardText.dropInsertionText(from:board), valid(text) else { return .refused }
        // Explicit drop may focus its own renderer, never another pane/window.
        guard view.window?.makeFirstResponder(view.renderer) == true,
              view.renderer.output === output, output.userInputLease == lease else { return .refused }
        return submit(text)
    }
    private func valid(_ text: String) -> Bool { !text.isEmpty && text.utf8.count <= Self.maximumPasteBytes }

    @discardableResult func submit(_ text: String) -> NativeHostActionResult {
        guard canPerform(.paste), valid(text), let view, let output = view.renderer.output,
              let lease = output.userInputLease else { return .refused }
        invalidateReview(); lastError = nil
        do {
            guard let prepared = try view.driver.prepareHostPaste(text) else { return .refused }
            switch prepared {
            case let .encoded(bytes,context):
                guard context.resetEpoch == lease.resetEpoch, output.userInputLease == lease else { return .refused }
                guard output.sendHostPaste(bytes,lease:lease) else { return .refused }
                view.renderer.clearComposition(); view.renderer.onInputActivity?()
                return .accepted
            case let .needsReview(context):
                guard context.resetEpoch == lease.resetEpoch, output.userInputLease == lease else { return .refused }
                let id = UUID()
                let preview = NativeClipboardOffer(id:id,payload:.text(text),createdAt:clock()).preview
                let review = NativeHostPasteReview(id:id,byteCount:text.utf8.count,preview:preview)
                pending = .init(review:review,text:text,output:output,lease:lease,context:context,created:clock())
                let reply: @MainActor (Bool) -> Void = { [weak self] approved in _ = self?.completeReview(id:id,approved:approved) }
                if let reviewPresenter { reviewPresenter(review,reply) }
                else if let window = view.window { Self.present(review,in:window,reply:reply) }
                else { pending = nil; return .refused }
                return .review(id)
            }
        } catch { lastError = String(describing:error); return .refused }
    }

    @discardableResult func completeReview(id: UUID, approved: Bool) -> Bool {
        guard let request = pending, request.review.id == id else { return false }
        pending = nil // consume before checking/encoding/writing; no retry on refusal
        guard approved, clock() >= request.created, clock()-request.created < Self.maximumReviewAge,
              canPerform(.paste), let view, view.renderer.output === request.output,
              request.output.userInputLease == request.lease else { return false }
        do {
            guard let prepared = try view.driver.prepareHostPaste(request.text,allowUnsafe:true,expected:request.context),
                  case let .encoded(bytes,context) = prepared, context == request.context,
                  request.output.userInputLease == request.lease,
                  request.output.sendHostPaste(bytes,lease:request.lease) else { return false }
            view.renderer.clearComposition(); view.renderer.onInputActivity?()
            return true
        } catch { lastError = String(describing:error); return false }
    }

    private static func present(_ review: NativeHostPasteReview, in window: NSWindow,
                                reply: @escaping @MainActor (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Paste text that could execute commands?"
        alert.informativeText = "VT rejected this paste without confirmation. Paste Once sends only these \(review.byteCount) bytes to the current terminal.\n\nPreview (escaped, truncated):\n\(review.preview)"
        alert.addButton(withTitle:"Cancel"); alert.addButton(withTitle:"Paste Once")
        alert.beginSheetModal(for:window) { reply($0 == .alertSecondButtonReturn) }
    }

    func zoom(by delta: CGFloat?) {
        guard canPerform(.zoom), let view else { return }
        do {
            let old = try view.settings ?? NativeTerminalSettings(theme:NativeThemeCatalog.bundled().defaultTheme,
                fontFamily:view.renderer.font.familyName ?? "Menlo",fontSize:view.renderer.font.pointSize,backgroundOpacity:1)
            let size = delta.map { old.fontSize+$0 } ?? zoomResetSize
            try view.applySettings(.init(theme:old.theme,fontFamily:old.fontFamily,fontSize:size,padding:old.padding,
                backgroundOpacity:old.backgroundOpacity,cursorShape:old.cursorShape,cursorBlink:old.cursorBlink))
        } catch { lastError = String(describing:error) }
    }
}
