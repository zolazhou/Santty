import AppKit

/// One local mode gesture. VT owns its anchor, hit thresholds and formatting;
/// this host retains only an opaque token, window point and wheel fraction.
@MainActor
final class NativeScrollModePointer {
    private weak var view: NativeTerminalScrollView?
    private let driver: GhosttyVTDriver
    private var token: UUID?
    private var point = CGPoint.zero
    private var time: TimeInterval = 0
    private var metrics = CGSize.zero
    private var columns = 0
    private var wheel = NativeScrollModeWheel()
    private var task: Task<Void,Never>?
    private var wakeToken: UUID?
    private(set) var isDragging = false
    var hasGesture: Bool { token != nil }
    var autoscrollArmed: Bool { task != nil }
    /// Injectable display fact for owned offscreen scheduler tests, not a user
    /// preference or a bypass for the connected presentation/input gates.
    var autoscrollIsVisible: (() -> Bool)?

    init(view: NativeTerminalScrollView) { self.view = view; driver = view.driver }
    isolated deinit { task?.cancel(); if let token { driver.cancelScrollModePointer(token:token) } }

    func cancel(discardWheel: Bool = true) {
        cancelTimer()
        if let token { driver.cancelScrollModePointer(token:token) }
        token = nil; isDragging = false
        if discardWheel { wheel.discard() }
    }
    private func cancelTimer() { task?.cancel(); task = nil; wakeToken = nil }
    private var visibleForTimer: Bool { autoscrollIsVisible?() ?? (view?.canAutoscrollScrollMode == true) }

    private func location(_ point: CGPoint) -> (document: CGPoint, local: CGPoint)? {
        guard let view, let document = view.documentView else { return nil }
        let value = document.convert(point,from:nil), visible = view.documentVisibleRect
        guard value.x.isFinite, value.y.isFinite else { return nil }
        return (value, .init(x:value.x-visible.minX,y:value.y-visible.minY))
    }
    private func input(step: NativeSelectionInput.Step, clamp: Bool) -> NativeSelectionInput? {
        guard let view, let viewport = view.presentedViewport, let frame = view.presentedFrame,
              let p = location(point), view.contentSize.height == viewport.viewportHeight,
              view.renderer.cellSize == view.presentedCellSize else { return nil }
        let cell = view.renderer.cellSize, visible = view.documentVisibleRect
        let width = CGFloat(frame.columns)*cell.width, total = CGFloat(viewport.totalRows)*cell.height
        if !clamp, p.document.x < 0 || p.document.x >= width || p.document.y < 0 || p.document.y >= total
            || p.local.y < 0 || p.local.y >= view.contentSize.height { return nil }
        let y = min(max(p.document.y,max(0,visible.minY)),min(total,visible.maxY)-0.001)
        guard y >= 0, cell.width > 0, cell.height > 0 else { return nil }
        let x = min(max(0,p.document.x),max(0,width-0.001))
        return .init(step:step,column:min(frame.columns-1,max(0,Int(floor(x/cell.width)))),
            row:min(viewport.totalRows-1,max(0,Int(floor(y/cell.height)))),
            position:.init(x:x,y:min(1_000_000,max(-1_000_000,p.local.y))),cell:cell,viewportHeight:view.contentSize.height,
            time:time,doubleClickInterval:NSEvent.doubleClickInterval)
    }

    @discardableResult
    func mouse(_ event: NSEvent) -> Bool {
        guard let view, view.scrollModeController.isActive else { return false }
        guard event.window == nil || event.window === view.window else { return true }
        let press = event.type == .leftMouseDown, drag = event.type == .leftMouseDragged, release = event.type == .leftMouseUp
        guard press || drag || release else {
            if event.type == .rightMouseDown || event.type == .otherMouseDown { cancel() }
            return true // no links, hover reports or context-menu program input
        }
        guard view.permitsScrollModePointer, driver.renderHoldRemaining == nil else { cancel(); return true }
        if press {
            view.scrollModeController.preparePointerInteraction()
            cancel(discardWheel:false)
            wheel.discard()
            metrics = view.renderer.cellSize; columns = view.presentedFrame?.columns ?? 0
        } else {
            guard let token, metrics == view.renderer.cellSize, columns == view.presentedFrame?.columns,
                  driver.scrollModePointerIsCurrent(token) else { cancel(); return true }
        }
        point = event.locationInWindow; time = event.timestamp
        let step: NativeSelectionInput.Step = press ? .press : drag ? .drag : .release
        guard let input = input(step:step,clamp:!press), let viewport = view.presentedViewport else { cancel(); return true }
        do {
            guard let result = try driver.selectScrollMode(input,relativeTo:viewport,expectedColumns:columns,token:token) else { cancel(); return true }
            token = result.token; isDragging = drag
            if release { cancelTimer(); isDragging = false }
            view.refresh()
            if drag { schedule() }
        } catch { cancel(); view.scrollModeController.reportPointerError(error) }
        return true
    }

    func scrollWheel(_ event: NSEvent) {
        guard let view, view.scrollModeController.isActive else { return }
        guard event.window == nil || event.window === view.window,
              view.permitsScrollModePointer, driver.renderHoldRemaining == nil else { cancel(); return }
        view.scrollModeController.preparePointerInteraction()
        if token != nil { cancel(discardWheel:false) }
        let rows = wheel.rows(deltaY:event.scrollingDeltaY,rowHeight:view.renderer.cellSize.height,
            precise:event.hasPreciseScrollingDeltas,began:event.phase.contains(.began),ended:event.phase.contains(.ended),
            momentumEnded:event.momentumPhase.contains(.ended) || event.phase.contains(.cancelled),
            hasPhase:!event.phase.isEmpty || !event.momentumPhase.isEmpty)
        guard rows != 0 else { return }
        do { _ = try driver.scrollModeMoveRows(rows); view.refresh() }
        catch { cancel(); view.scrollModeController.reportPointerError(error) }
    }

    /// Called after publication, including output/pruning/settings. An old
    /// pointer token must not continue a replacement mode/epoch or reflow.
    func presentationChanged() {
        guard let token else { return }
        guard let view, metrics == view.renderer.cellSize, columns == view.presentedFrame?.columns,
              driver.scrollModePointerIsCurrent(token) else { cancel(); return }
        if isDragging { schedule() }
    }
    private func distance() -> CGFloat {
        guard let view, let p = location(point) else { return 0 }
        return p.local.y < 0 ? p.local.y : p.local.y > view.contentSize.height ? p.local.y-view.contentSize.height : 0
    }
    private func schedule() {
        guard token != nil, isDragging, distance() != 0, visibleForTimer else { cancelTimer(); return }
        guard task == nil else { return }
        let wake = UUID(); wakeToken = wake
        task = Task { @MainActor [weak self] in
            do { try await Task.sleep(for:.milliseconds(50)) } catch { return }
            guard !Task.isCancelled, let self, self.wakeToken == wake else { return }
            self.task = nil; self.wakeToken = nil
            guard self.visibleForTimer else { self.cancel(); return }
            if self.autoscrollStep() { self.schedule() }
        }
    }

    /// A deterministic finite step is also used by owned offscreen tests.
    /// Real timed steps additionally require visible/awake/attached display facts.
    @discardableResult
    func autoscrollStep() -> Bool {
        guard let view, let token, isDragging, view.permitsScrollModePointer,
              driver.scrollModePointerIsCurrent(token), let input = input(step:.drag,clamp:true) else { cancel(); return false }
        let delta = distance()
        guard delta != 0 else { cancelTimer(); return false }
        let rows = min(10,max(1,Int(min(10,abs(delta)/input.cell.height)))) * (delta < 0 ? -1 : 1)
        do {
            guard try driver.autoscrollScrollMode(input,rows:rows,token:token) else { cancelTimer(); return false }
            view.refresh()
            return true
        } catch { cancel(); view.scrollModeController.reportPointerError(error); return false }
    }
}
