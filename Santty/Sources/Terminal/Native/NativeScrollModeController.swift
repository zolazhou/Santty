import AppKit

/// Lab UI owner only. VT refs/selection/formatting remain in the driver. The
/// renderer stays first responder; this does not manufacture focus or key input.
@MainActor
final class NativeScrollModeController {
    private weak var view: NativeTerminalScrollView?
    private let driver: GhosttyVTDriver
    let overlay = NativeScrollModeOverlay()
    let pointer: NativeScrollModePointer
    private(set) var isActive = false
    private(set) var awaitingSecondG = false
    private(set) var lastError: String?
    private let gateID = UUID()
    private var suppressedOutput: NativeTerminalOutput?
    private var flashTask: Task<Void, Never>?
    private var flashToken: UUID?
    var copyPasteboard: () -> NSPasteboard = { .general }

    init(view: NativeTerminalScrollView) { self.view = view; driver = view.driver; pointer = NativeScrollModePointer(view:view) }
    isolated deinit {
        flashTask?.cancel()
        if isActive { _ = try? driver.performScrollMode(.end) }
        suppressedOutput?.suppressUserInput(false, owner:gateID)
    }

    @discardableResult
    func enter() -> Bool {
        guard !isActive, let view else { return isActive }
        do {
            guard view.driver.renderHoldRemaining == nil else { return false }
            // A fixture/layout can have published pixels before its first real
            // cell resize. Synchronize visible geometry before placing a cursor.
            _ = try view.synchronizeViewport()
            view.refresh(resizeTerminal:true)
            // Explicit entry before the first visible paint may establish a
            // bounded VT reading origin, without publishing AX/pixels or ticking
            // animation. Existing published reading positions still win.
            let initial = view.presentedViewport == nil ? try view.driver.presentation(rowHeight:view.renderer.cellSize.height,
                viewportHeight:view.contentSize.height,previous:nil,advanceAnimations:false) : nil
            guard let viewport = view.presentedViewport ?? initial?.viewport else { return false }
            view.prepareScrollModeEntry()
            guard try view.driver.performScrollMode(.begin,relativeTo:viewport) != nil else { return false }
            isActive = true; lastError = nil
            view.renderer.hostActions?.invalidateReview()
            suppressedOutput = view.renderer.output
            suppressedOutput?.suppressUserInput(true,owner:gateID)
            view.source.suppressProgramCursor = true
            view.renderer.resetInputState() // discard composition/press state; never commit it
            if let initial, let state = try driver.scrollModeState {
                publish(state,frame:initial.frame,viewport:viewport)
            }
            view.refresh()
            return true
        } catch { lastError = String(describing:error); return false }
    }

    func exit(refresh: Bool = true) {
        guard isActive else { return }
        if let view { _ = try? view.driver.performScrollMode(.end) }
        finish()
        view?.renderer.resetInputState()
        if refresh { view?.refreshScrollModeExit() }
    }
    private func finish() {
        isActive = false; awaitingSecondG = false
        pointer.cancel()
        resetFlash(); overlay.clear()
        suppressedOutput?.suppressUserInput(false,owner:gateID); suppressedOutput = nil
        view?.source.suppressProgramCursor = false
    }
    func coreEnded() { exit(refresh:false) }
    func outputChanged() { exit() }
    func resetTransient() { awaitingSecondG = false; resetFlash(); pointer.cancel() }
    func reportPointerError(_ error: Error) { lastError = String(describing:error); view?.refresh() }
    func preparePointerInteraction() { awaitingSecondG = false; overlay.clearPendingPrefix(); resetFlash() }

    private func resetFlash() { flashTask?.cancel(); flashTask = nil; flashToken = nil; overlay.clearFlash() }
    private func isToggle(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection([.command,.shift,.control,.option]) == [.command,.shift]
            && event.charactersIgnoringModifiers?.lowercased() == "s"
    }
    func keyEquivalent(_ event: NSEvent) -> Bool {
        guard event.window == nil || event.window === view?.window else { return false }
        if isToggle(event) { toggleFromUser(); return true }
        if let window = event.window, window.firstResponder !== view?.renderer { return false }
        guard isActive, event.modifierFlags.intersection([.command,.shift,.control,.option]) == .command else { return false }
        let key = event.charactersIgnoringModifiers?.lowercased()
        if key == "c" { _ = copy(); return true }
        if key == "v" || key == "a" { return true }
        return false // leave app-global menu shortcuts (e.g. Quit) to AppKit
    }

    private func toggleFromUser() {
        if isActive { exit() }
        else if enter(), let view { view.window?.makeFirstResponder(view.renderer) }
    }

    func keyDown(_ event: NSEvent) -> Bool {
        guard event.window == nil || event.window === view?.window else { return isActive }
        if isToggle(event) { toggleFromUser(); return true }
        guard isActive else { return false }
        guard event.window == nil || event.window === view?.window else { return true }
        guard let view else { finish(); return true }
        // A reset may precede its coalesced UI callback. Consume THIS event;
        // never reinterpret the exit/reset key as terminal input on a new epoch.
        if view.driver.renderHoldRemaining == nil, (try? view.driver.scrollModeState) == nil {
            exit(refresh:false); view.refresh(); return true
        }
        pointer.cancel()
        let action = NativeScrollModeKeyAction(event:event,awaitingSecondG:awaitingSecondG)
        awaitingSecondG = false
        lastError = nil
        do {
            switch action {
            case .exit: exit(); return true
            case .cancel:
                if view.driver.renderHoldRemaining != nil { exit(); return true }
                if try view.driver.scrollModeState?.selection == nil { exit(); return true }
                _ = try view.driver.performScrollMode(.cancelSelection)
            case let .move(movement): resetFlash(); _ = try view.driver.performScrollMode(.move(movement))
            case let .select(linewise): resetFlash(); _ = try view.driver.performScrollMode(.toggleSelection(linewise:linewise))
            case .copy: _ = copy()
            case .awaitSecondG: awaitingSecondG = true
            case .consume: break
            }
        } catch { lastError = String(describing:error) }
        view.refresh()
        return true
    }

    @discardableResult
    func copy(to pasteboard: NSPasteboard? = nil) -> Bool {
        guard isActive, let view else { return false }
        pointer.cancel()
        do {
            guard let text = try view.driver.readScrollModeSelection(), !text.isEmpty else { return false }
            let board = pasteboard ?? copyPasteboard()
            board.clearContents()
            guard board.setString(text,forType:.string) else { return false }
            resetFlash(); overlay.flash()
            let token = UUID(); flashToken = token
            flashTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for:.milliseconds(300)) } catch { return }
                guard !Task.isCancelled, let self, self.flashToken == token else { return }
                self.overlay.clearFlash(); self.flashTask = nil; self.flashToken = nil
            }
            return true
        } catch { lastError = String(describing:error); return false }
    }

    func move(_ movement: NativeScrollMovement) {
        guard isActive, let view else { return }
        pointer.cancel(); resetFlash(); _ = try? driver.performScrollMode(.move(movement)); view.refresh()
    }
    func toggleSelection(linewise: Bool) {
        guard isActive, let view else { return }
        pointer.cancel(); _ = try? driver.performScrollMode(.toggleSelection(linewise:linewise)); view.refresh()
    }
    @discardableResult func cancelSelection() -> Bool {
        guard isActive, (try? driver.scrollModeState?.selection) != nil else { return false }
        _ = try? driver.performScrollMode(.cancelSelection); view?.refresh(); return true
    }

    func publish(_ state: NativeScrollModeState, frame: NativeTerminalFrame, viewport: NativeViewport) {
        guard isActive, let renderer = view?.renderer else { return }
        let old = overlay.cursorRect
        overlay.update(state:state,frame:frame,topRow:viewport.firstRow,cell:renderer.cellSize,
            bounds:renderer.bounds,clip:renderer.visibleRect,awaitingG:awaitingSecondG,limited:lastError != nil)
        if old != overlay.cursorRect { resetFlash() }
        renderer.addSubview(overlay,positioned:.above,relativeTo:nil)
        pointer.presentationChanged()
    }
}
