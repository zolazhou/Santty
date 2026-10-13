import AppKit
import GhosttyTerminal

@MainActor
final class HerdrClientShellPopupController: NSObject, TerminalSurfaceLifecycleDelegate, TerminalSurfaceClipboardWriteDelegate {
    let terminalID: String
    let bootID: String
    let terminalView = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
    private weak var session: HerdrClientShellSession?
    private let controller: TerminalController
    private let memory: InMemoryTerminalSession
    private let feedback: HerdrShellDisplayFeedback
    private var renderer = HerdrClientShellRenderer()
    private var renderEpoch = 0
    private var clientShellPressedKeys: [UInt16: HerdrShellInput.Key] = [:]
    private var clientShellPressedButtons = Set<UInt32>()
    private var clientShellWheelX: CGFloat = 0
    private var clientShellWheelY: CGFloat = 0
    private var clientShellMouseReporting = false
    private var clientShellPixelMouse = false
    private var attached = false
    private var isPresented = false
    private(set) var displayError: String?

    init(session: HerdrClientShellSession, bootID: String, terminalID: String) {
        self.session = session; self.bootID = bootID; self.terminalID = terminalID
        let feedback = HerdrShellDisplayFeedback()
        self.feedback = feedback
        memory = InMemoryTerminalSession(write: { feedback.receive($0) }, resize: { _ in })
        controller = TerminalController(configuration: Self.configuration(), theme: TerminalDefaults.theme)
        super.init()
        terminalView.configuration = .init(backend: .inMemory(memory))
        terminalView.controller = controller
        terminalView.delegate = self
        feedback.setHandler { [weak self] failure in
            Task { @MainActor in
                guard let self, self.renderer.ownsImage(failure.imageID) else { return }
                self.displayError = "Ghostty popup image \(failure.imageID): \(failure.message)"
                self.terminalView.toolTip = self.displayError
            }
        }
        terminalView.semanticKeyHandler = { [weak self] event, translated, text in
            guard let self else { return }
            if event.type == .keyUp {
                guard var key = self.clientShellPressedKeys.removeValue(forKey: event.keyCode) else { return }
                key.kind = 2; key.text = nil
                _ = self.sendClientShellRelease(.key(key))
            } else {
                guard !event.isARepeat || self.clientShellPressedKeys[event.keyCode] != nil,
                      let key = HerdrClientShellInput.key(event, translated: translated, text: text) else { return }
                if self.sendClientShellInput([.key(key)]) { self.clientShellPressedKeys[event.keyCode] = key }
            }
        }
        terminalView.semanticTextCommitHandler = { [weak self] in _ = self?.sendClientShellInput([.text($0)]) }
        terminalView.semanticPasteHandler = { [weak self] in
            guard let text = TerminalPasteboardText.dropInsertionText(from: .general) else { return }
            _ = self?.sendClientShellInput([.paste(text)])
        }
        terminalView.semanticMouseHandler = { [weak self] in self?.handleClientShellMouse($0) ?? true }
    }

    var canAcceptInput: Bool {
        isPresented && attached && terminalView.window != nil && session?.state == .interactive
            && session?.isPresentationReady == true && session?.projection.snapshot?.boot_id == bootID
            && session?.projection.coherentSurface?.containsInputTarget(terminalID, popup: true) == true
    }

    func prepareRender(_ surface: HerdrShellSurface, assets: [HerdrShellAssetKey: Data]) async throws
        -> HerdrShellPreparedRender? {
        guard let session, surface.boot_id == bootID,
              session.canPresent(surface),
              let popup = surface.popup, popup.terminal_id == terminalID else { return nil }
        guard attached, terminalView.window != nil else { return nil }
        terminalView.fitToSize()
        guard let grid = terminalView.scrollModeGrid, grid.columns == popup.frame.width,
              grid.rows == popup.frame.height else { return nil }
        let epoch = renderEpoch
        let isCurrent: @MainActor () -> Bool = { [self] in
            renderEpoch == epoch && attached && terminalView.window != nil && self.session === session
                && session.projection.snapshot?.boot_id == bootID
                && session.canPresent(surface)
        }
        try await feedback.waitForViewport(.init(cols: popup.frame.width, rows: popup.frame.height), in: memory)
        guard isCurrent() else { return nil }
        let prepared = try await renderer.prepare(.popup(terminalID), from: surface, assets: assets)
        try Task.checkCancellation()
        guard isCurrent() else { return nil }
        let bytes = prepared.bytes, preparedRenderer = prepared.renderer
        return .init(byteCount: bytes.count, isCurrent: isCurrent, commit: { [self] in
            guard isCurrent() else { return nil }
            guard memory.receiveIfAttached(bytes) else { return nil }
            renderer = preparedRenderer
            clientShellMouseReporting = popup.mouse_reporting; clientShellPixelMouse = popup.sgr_pixel_mouse
            return memory
        })
    }

    func applyState(_ state: HerdrConnectionState) {
        if state != .interactive {
            terminalView.invalidateClipboardWrites()
            clientShellWheelX = 0; clientShellWheelY = 0; terminalView.unmarkText()
        }
        clientShellPressedKeys = clientShellPressedKeys.filter { entry in
            session?.hasHeldKey(target: terminalID, popup: true, physicalKeyID: UInt32(entry.key)) == true
        }
        clientShellPressedButtons = clientShellPressedButtons.filter { button in
            session?.hasHeldMouse(target: terminalID, popup: true, button: button) == true
        }
    }

    func applySettings() {
        renderEpoch += 1; renderer.reset(); displayError = nil
        _ = controller.setTheme(TerminalDefaults.theme)
        _ = controller.setTerminalConfiguration(Self.configuration())
    }

    func terminalShouldWriteClipboard(afterConfirmation: Bool) -> Bool {
        guard isPresented, attached, let window = terminalView.window,
              window.firstResponder === terminalView else { return false }
        return window.isKeyWindow || afterConfirmation
    }

    func receiveClipboard(_ text: String) throws {
        guard canAcceptInput else { return }
        guard terminalView.requestClipboardWrite(text) else { throw CLIError("Ghostty clipboard target or policy is unavailable") }
    }

    func terminalDidAttachSurface(_: TerminalSurface) { attached = true; invalidateDisplay() }
    func terminalDidDetachSurface() { attached = false; invalidateDisplay() }

    private func invalidateDisplay() {
        renderEpoch += 1; renderer.reset(); displayError = nil
        applyState(.connecting)
        guard isPresented else { return }
        do { try session?.invalidatePresentation() }
        catch { session?.disconnect(); displayError = error.localizedDescription; terminalView.toolTip = displayError }
    }

    func setPresented(_ presented: Bool) {
        isPresented = presented
        if !presented {
            terminalView.invalidateClipboardWrites()
            clientShellPressedKeys.removeAll(); clientShellPressedButtons.removeAll()
            clientShellWheelX = 0; clientShellWheelY = 0
            terminalView.unmarkText()
        }
    }

    private static func configuration() -> TerminalConfiguration {
        TerminalConfiguration(startingFrom: TerminalDefaults.configuration) { builder in
            builder.withCustom("window-padding-x", "0")
            builder.withCustom("window-padding-y", "0")
            builder.withCustom("window-padding-balance", "false")
        }
    }

    @discardableResult
    private func sendClientShellInput(_ events: [HerdrShellInput]) -> Bool {
        guard canAcceptInput else { return false }
        return session?.input(target: terminalID, popup: true, events: events) == true
    }

    private func sendClientShellRelease(_ event: HerdrShellInput) -> Bool {
        guard session?.projection.snapshot?.boot_id == bootID else { return false }
        return session?.input(target: terminalID, popup: true, events: [event]) == true
    }

    private func handleClientShellMouse(_ event: NSEvent) -> Bool {
        clientShellPressedButtons = clientShellPressedButtons.filter { button in
            session?.hasHeldMouse(target: terminalID, popup: true, button: button) == true
        }
        let wheel = event.type == .scrollWheel
        let button: UInt32? = event.buttonNumber == 0 ? 0 : event.buttonNumber == 1 ? 1 : event.buttonNumber == 2 ? 2 : nil
        let held = button.map { clientShellPressedButtons.contains($0) } == true
        if !wheel, !held, (!clientShellMouseReporting || event.modifierFlags.contains(.shift)) { return false }
        let release = [NSEvent.EventType.leftMouseUp, .rightMouseUp, .otherMouseUp].contains(event.type) && held
        guard canAcceptInput || release, let grid = terminalView.scrollModeGrid,
              grid.cellWidthPixels > 0, grid.cellHeightPixels > 0 else { return true }
        let scale = terminalView.convertToBacking(NSSize(width: 1, height: 1))
        let p = terminalView.convert(event.locationInWindow, from: nil)
        let point = NSPoint(x: p.x, y: terminalView.bounds.height - p.y)
        var events: [HerdrShellInput] = []
        func mouse(_ kind: UInt32, _ button: UInt32? = nil, _ lines: UInt16 = 1) -> HerdrShellInput.Mouse? {
            HerdrClientShellInput.mouse(kind: kind, button: button, point: point, grid: grid, scale: scale,
                pixel: clientShellPixelMouse, flags: event.modifierFlags, lines: lines, clamp: held)
        }
        if wheel {
            guard event.scrollingDeltaX.isFinite, event.scrollingDeltaY.isFinite else { return true }
            let cellWidth = CGFloat(grid.cellWidthPixels) / scale.width
            let cellHeight = CGFloat(grid.cellHeightPixels) / scale.height
            let limit = CGFloat(UInt16.max)
            clientShellWheelX = min(max(clientShellWheelX + event.scrollingDeltaX / (event.hasPreciseScrollingDeltas ? cellWidth : 1), -limit), limit)
            clientShellWheelY = min(max(clientShellWheelY + event.scrollingDeltaY / (event.hasPreciseScrollingDeltas ? cellHeight : 1), -limit), limit)
            for vertical in [true, false] {
                let delta = vertical ? clientShellWheelY : clientShellWheelX
                let count = min(floor(abs(delta)), CGFloat(UInt16.max))
                if count >= 1, let value = mouse(vertical ? (delta > 0 ? 4 : 5) : (delta > 0 ? 6 : 7), nil, UInt16(count)) {
                    events.append(.mouse(value))
                    let consumed = delta > 0 ? count : -count
                    if vertical { clientShellWheelY -= consumed } else { clientShellWheelX -= consumed }
                }
            }
        } else {
            let kind: UInt32
            switch event.type {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                terminalView.window?.makeFirstResponder(terminalView); kind = 0
            case .leftMouseUp, .rightMouseUp, .otherMouseUp: guard held else { return true }; kind = 1
            case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: guard held else { return true }; kind = 2
            case .mouseMoved: kind = 3
            default: return true
            }
            guard let value = mouse(kind, kind <= 2 ? button : nil) else { return true }
            if kind == 1, let button { clientShellPressedButtons.remove(button) }
            let sent = kind == 1 ? sendClientShellRelease(.mouse(value)) : sendClientShellInput([.mouse(value)])
            if sent, let button {
                if kind == 0 { clientShellPressedButtons.insert(button) }
            }
            return true
        }
        if !events.isEmpty { _ = sendClientShellInput(events) }
        return true
    }

}
