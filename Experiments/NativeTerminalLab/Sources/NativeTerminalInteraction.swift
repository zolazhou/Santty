import AppKit
import GhosttyVt

/// AppKit presentation/gesture ownership. VT remains the authority for protocol
/// modes, byte encoding, tracked selections and selected text.
@MainActor
final class NativeTerminalInteraction {
    private weak var view: NativeTerminalScrollView?
    private enum Owner { case program(NativePointerModes), selection(NativePointerModes), local }
    private var buttons: [Int: Owner] = [:]
    private var lastProgramInputs: [Int: NativeMouseInput] = [:]
    private var wheelRouter = NativeWheelRouter()
    private var selecting = false
    private var selectionWindowPoint = CGPoint.zero
    private var selectionTime: TimeInterval = 0
    private var autoscroll: Task<Void, Never>?
    private struct LinkPress {
        let match: NativeTerminalLinkMatch
        var uri: String { match.uri }
        let column: Int
        let row: Int
        let viewport: NativeViewport
        let windowPoint: CGPoint
    }
    private var linkPress: LinkPress?
    private var pointer: (screen: CGPoint, window: Int)?
    private var pointerModifiers: NSEvent.ModifierFlags = []

    init(view: NativeTerminalScrollView) { self.view = view }

    func cancelGesture(preservePointer: Bool = false) {
        // End only presses sent on this still-current channel/mode. A reset
        // changes the signature, and an offline output refuses the write.
        if let view {
            for input in lastProgramInputs.values {
                let release = NativeMouseInput(action: GHOSTTY_MOUSE_ACTION_RELEASE, button: input.button,
                    modifiers: 0, position: input.position, cell: input.cell, scale: input.scale,
                    anyButton: false, modes: input.modes)
                _ = try? view.renderer.output?.send(.mouse(release))
            }
        }
        lastProgramInputs.removeAll()
        linkPress = nil
        if !preservePointer { pointer = nil; pointerModifiers = [] }
        clearHover()
        selecting = false; buttons.removeAll(); wheelRouter.discardRemainingGesture()
        autoscroll?.cancel(); autoscroll = nil
        view?.driver.cancelSelectionGesture()
    }

    func keyboardInput() {
        linkPress = nil
        pointerModifiers = []
        clearHover()
        // Typing ends local selection/scrolling, not a program-owned button.
        selecting = false; autoscroll?.cancel(); autoscroll = nil; wheelRouter.discardRemainingGesture()
        buttons = buttons.filter { if case .program = $0.value { return true }; return false }
        view?.driver.cancelSelectionGesture()
        view?.driver.clearSelection()
        view?.scrollToLiveScreen()
        view?.refresh()
    }

    func selectAll() {
        guard let view else { return }
        cancelGesture()
        try? view.driver.selectAll()
        view.refresh()
    }

    func copy(to pasteboard: NSPasteboard) -> Bool {
        guard let text = try? view?.driver.selectedText(), !text.isEmpty else { return false }
        // Never replace the clipboard just because selection changed.
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    private func coordinates(_ windowPoint: CGPoint) -> (document: CGPoint, viewport: CGPoint)? {
        guard let view, let document = view.documentView else { return nil }
        let point = document.convert(windowPoint, from: nil)
        let visible = view.documentVisibleRect
        return (point, CGPoint(x: point.x - visible.minX, y: point.y - visible.minY))
    }

    private func mods(_ flags: NSEvent.ModifierFlags) -> GhosttyMods {
        var value: GhosttyMods = 0
        if flags.contains(.shift) { value |= GhosttyMods(GHOSTTY_MODS_SHIFT) }
        if flags.contains(.control) { value |= GhosttyMods(GHOSTTY_MODS_CTRL) }
        if flags.contains(.option) { value |= GhosttyMods(GHOSTTY_MODS_ALT) }
        if flags.contains(.command) { value |= GhosttyMods(GHOSTTY_MODS_SUPER) }
        return value
    }

    private func mouseInput(_ event: NSEvent, action: GhosttyMouseAction, button: GhosttyMouseButton?,
                            modes: NativePointerModes, clamp: Bool = false) -> NativeMouseInput? {
        guard let view, let at = coordinates(event.locationInWindow), let total = try? view.driver.totalRows else { return nil }
        let cell = view.renderer.cellSize
        let origin = CGFloat(max(0, total - view.driver.rows)) * cell.height
        var p = CGPoint(x: at.document.x, y: at.document.y - origin)
        let width = CGFloat(view.driver.columns) * cell.width, height = CGFloat(view.driver.rows) * cell.height
        if clamp { p.x = min(max(0, p.x), width - 0.01); p.y = min(max(0, p.y), height - 0.01) }
        guard p.x >= 0, p.x < width, p.y >= 0, p.y < height else { return nil }
        let any = buttons.values.contains { if case .program = $0 { return true }; return false }
        return .init(action: action, button: button, modifiers: mods(event.modifierFlags), position: p,
                     cell: cell, scale: view.window?.backingScaleFactor ?? 1, anyButton: any, modes: modes)
    }

    private func commandLink(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command
    }

    private func displayedLink(_ point: CGPoint) -> LinkPress? {
        guard let view, let viewport = view.presentedViewport, let frame = view.presentedFrame,
              let at = coordinates(point), at.viewport.y >= 0, at.viewport.y < view.contentSize.height,
              at.document.x >= 0, at.document.y >= 0 else { return nil }
        let row = Int(floor(at.document.y / view.renderer.cellSize.height))
        var column = Int(floor(at.document.x / view.renderer.cellSize.width))
        guard let cells = frame.rows[row]?.cells, cells.indices.contains(column) else { return nil }
        if cells[column].width == 0, column > 0, cells[column - 1].width == 2 { column -= 1 }
        guard let match = NativeTerminalLinkMatcher.match(in: frame, column: column, row: row) else { return nil }
        return .init(match: match, column: column, row: row, viewport: viewport, windowPoint: point)
    }

    private func rememberPointer(_ event: NSEvent) {
        guard let window = view?.window else { return }
        pointer = (window.convertPoint(toScreen: event.locationInWindow), window.windowNumber)
        pointerModifiers = event.modifierFlags
    }

    func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        pointerModifiers = flags
        if pointer == nil, flags.contains(.command), let window = view?.window, window.isKeyWindow {
            pointer = (window.convertPoint(toScreen: window.mouseLocationOutsideOfEventStream), window.windowNumber)
        }
        presentationChanged(fromUserEvent: true)
    }

    private func clearHover(fromUserEvent: Bool = false) {
        view?.renderer.toolTip = nil
        view?.updateLinkHighlight([:], fromUserEvent: fromUserEvent)
    }

    func presentationChanged(fromUserEvent: Bool = false) {
        guard let view, let window = view.window, let pointer, pointer.window == window.windowNumber,
              pointerModifiers.intersection([.command, .control, .option, .shift]) == .command,
              !selecting, !buttons.values.contains(where: { if case .program = $0 { return true }; return false }),
              let link = displayedLink(window.convertPoint(fromScreen: pointer.screen)),
              let url = NativeTerminalLink.url(link.uri) else { clearHover(fromUserEvent: fromUserEvent); return }
        view.renderer.toolTip = url.absoluteString
        view.updateLinkHighlight(link.match.ranges, fromUserEvent: fromUserEvent)
    }

    func mouse(_ event: NSEvent) -> Bool {
        if event.type == .mouseExited {
            pointer = nil; clearHover(fromUserEvent: true)
            return true
        }
        rememberPointer(event)
        presentationChanged(fromUserEvent: true)
        if event.type == .mouseEntered { return true }
        guard let view, let modes = try? view.driver.pointerModes else { return true }
        let moved = event.type == .mouseMoved
        let press = [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type)
        let release = [.leftMouseUp, .rightMouseUp, .otherMouseUp].contains(event.type)
        if view.driver.renderHoldRemaining != nil, !release { return true }
        let number = moved ? -1 : event.buttonNumber
        let mapping: [GhosttyMouseButton] = [GHOSTTY_MOUSE_BUTTON_LEFT, GHOSTTY_MOUSE_BUTTON_RIGHT,
            GHOSTTY_MOUSE_BUTTON_MIDDLE, GHOSTTY_MOUSE_BUTTON_EIGHT, GHOSTTY_MOUSE_BUTTON_NINE,
            GHOSTTY_MOUSE_BUTTON_TEN, GHOSTTY_MOUSE_BUTTON_ELEVEN]
        let button: GhosttyMouseButton? = moved ? nil : mapping.indices.contains(number) ? mapping[number] : nil
        if !moved, button == nil { return true }
        let live = view.renderer.inputEnabled && view.renderer.output != nil
        if moved {
            if live, modes.tracking, !commandLink(event), !event.modifierFlags.contains(.shift), view.isAtLiveBottom,
               let input = mouseInput(event, action: GHOSTTY_MOUSE_ACTION_MOTION, button: nil, modes: modes) {
                _ = try? view.renderer.output?.send(.mouse(input))
            }
            return true
        }
        if press, number == 0, commandLink(event) {
            // The explicit host gesture wins over program mouse reporting, as
            // in herdr-app. Capture at press; open only on a matching release.
            buttons[0] = .local
            linkPress = nil
            if let link = displayedLink(event.locationInWindow), NativeTerminalLink.url(link.uri) != nil,
               (try? view.driver.verifyLink(link.match, column: link.column, row: link.row, relativeTo: link.viewport)) == true {
                linkPress = link
            }
            return true
        }
        if let link = linkPress, number == 0 {
            if release {
                linkPress = nil; buttons.removeValue(forKey: 0)
                if commandLink(event), let hit = displayedLink(event.locationInWindow),
                   hit.match.matches(link.match, rowOffset: hit.viewport.firstRow - link.viewport.firstRow),
                   hypot(event.locationInWindow.x - link.windowPoint.x, event.locationInWindow.y - link.windowPoint.y) <= 4,
                   (try? view.driver.verifyLink(hit.match, column: hit.column, row: hit.row, relativeTo: hit.viewport)) == true,
                   let url = NativeTerminalLink.url(link.uri) { _ = view.openLink(url) }
            } else if hypot(event.locationInWindow.x - link.windowPoint.x, event.locationInWindow.y - link.windowPoint.y) > 4 {
                linkPress = nil
            }
            return true
        }
        if press {
            if live, modes.tracking, !event.modifierFlags.contains(.shift) {
                // A first click in history only reveals the live screen. Never
                // apply a click to unseen program content at the same position.
                guard view.isAtLiveBottom else { buttons[number] = .local; view.scrollToLiveScreen(); return true }
                buttons[number] = .program(modes)
                view.driver.clearSelection()
            } else if number == 0 {
                buttons[number] = .selection(modes)
                selecting = true
                updateSelection(event.locationInWindow, time: event.timestamp, step: .press)
                return true
            } else { buttons[number] = .local; return false }
        }
        guard let owner = buttons[number] else { return true }
        defer {
            if release { buttons.removeValue(forKey: number); lastProgramInputs.removeValue(forKey: number) }
        }
        switch owner {
        case let .program(original):
            guard live, original == modes else { return true }
            // A button keeps the route chosen at press, even if Shift changes.
            if release { buttons.removeValue(forKey: number) }
            if let input = mouseInput(event, action: press ? GHOSTTY_MOUSE_ACTION_PRESS : release ? GHOSTTY_MOUSE_ACTION_RELEASE : GHOSTTY_MOUSE_ACTION_MOTION,
                                      button: button, modes: modes, clamp: !press) {
                _ = try? view.renderer.output?.send(.mouse(input))
                if !release { lastProgramInputs[number] = input }
            }
        case let .selection(original):
            guard original == modes else { cancelGesture(); return true }
            let applied = press || updateSelection(event.locationInWindow, time: event.timestamp, step: release ? .release : .drag)
            if release {
                selecting = false; autoscroll?.cancel(); autoscroll = nil
                // A normal release preserves VT's multi-click sequence. Only
                // an unapplied release (e.g. during a hold) needs cancellation.
                if !applied { view.driver.cancelSelectionGesture() }
            }
        case .local: break
        }
        return true
    }

    /// Returns true only when AppKit should receive this event. Program paths
    /// consume it even if a fractional delta or a mode transition emits no bytes.
    func wheel(_ event: NSEvent) -> Bool {
        linkPress = nil
        rememberPointer(event)
        guard let view, let modes = try? view.driver.pointerModes, view.driver.renderHoldRemaining == nil else { return false }
        let decision = wheelRouter.route(modes: modes,
            bypass: event.modifierFlags.contains(.shift) || !view.renderer.inputEnabled || view.renderer.output == nil,
            precise: event.hasPreciseScrollingDeltas,
            began: event.phase.contains(.began), ended: event.phase.contains(.ended),
            momentumEnded: event.momentumPhase.contains(.ended) || event.phase.contains(.cancelled),
            delta: CGPoint(x: event.scrollingDeltaX, y: event.scrollingDeltaY),
            cell: view.renderer.cellSize, rows: view.driver.rows, columns: view.driver.columns,
            hasGesturePhase: !event.phase.isEmpty || !event.momentumPhase.isEmpty)
        if decision.route == .history { return true }
        guard decision.route != .discard, view.isAtLiveBottom,
              let input = mouseInput(event, action: GHOSTTY_MOUSE_ACTION_PRESS, button: nil, modes: modes, clamp: true) else { return false }
        _ = try? view.renderer.output?.send(.wheel(.init(route: decision.route, x: decision.x, y: decision.y, mouse: input)))
        return false
    }

    @discardableResult
    private func updateSelection(_ point: CGPoint, time: TimeInterval, step: NativeSelectionInput.Step) -> Bool {
        guard let view, let viewport = view.presentedViewport, let at = coordinates(point),
              viewport.totalRows > 0 else { return false }
        let cell = view.renderer.cellSize
        // An elastic blank is not a selectable cell. A drag outside the view
        // instead clamps to the visible edge, then our timer scrolls AppKit.
        if step == .press, (at.document.y < 0 || at.document.y >= CGFloat(viewport.totalRows) * cell.height
            || at.document.x < 0 || at.document.x >= CGFloat(view.driver.columns) * cell.width) {
            selecting = false; buttons[0] = .local
            view.driver.cancelSelectionGesture()
            return false
        }
        let y = min(max(at.document.y, view.documentVisibleRect.minY), view.documentVisibleRect.maxY - 0.01)
        let row = min(viewport.totalRows - 1, max(0, Int(floor(y / cell.height))))
        let column = min(view.driver.columns - 1, max(0, Int(floor(at.document.x / cell.width))))
        selectionWindowPoint = point; selectionTime = time
        let applied = (try? view.driver.select(.init(step: step, column: column, row: row,
            position: CGPoint(x: at.document.x, y: at.viewport.y), cell: cell,
            viewportHeight: view.contentSize.height, time: time, doubleClickInterval: NSEvent.doubleClickInterval), relativeTo: viewport)) == true
        if !applied {
            selecting = false; buttons[0] = .local; autoscroll?.cancel(); autoscroll = nil
            view.driver.cancelSelectionGesture()
        }
        view.refresh()
        if step == .drag, applied { scheduleAutoscroll() }
        return applied
    }

    private func scheduleAutoscroll() {
        guard let view, let p = coordinates(selectionWindowPoint)?.viewport,
              p.y < 0 || p.y > view.contentSize.height else { autoscroll?.cancel(); autoscroll = nil; return }
        guard autoscroll == nil else { return }
        autoscroll = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                guard let self, let view = self.view, self.selecting,
                      view.window?.occlusionState.contains(.visible) == true, !view.isHiddenOrHasHiddenAncestor else {
                    self?.cancelGesture()
                    return
                }
                self.autoscrollStep()
            }
        }
    }

    func autoscrollStep() {
        guard selecting, let view, let p = coordinates(selectionWindowPoint)?.viewport else { return }
        let h = view.renderer.cellSize.height
        let distance: CGFloat = p.y < 0 ? p.y : p.y > view.contentSize.height ? p.y - view.contentSize.height : 0
        guard distance != 0 else { return }
        let lines = min(10, max(1, Int(abs(distance) / h))) * (distance < 0 ? -1 : 1)
        let maximum = max(0, (view.documentView?.frame.height ?? 0) - view.contentSize.height)
        let offset = min(maximum, max(0, view.contentView.bounds.minY + CGFloat(lines) * h))
        view.contentView.scroll(to: CGPoint(x: 0, y: offset))
        view.reflectScrolledClipView(view.contentView)
        updateSelection(selectionWindowPoint, time: selectionTime, step: .drag)
    }
}
