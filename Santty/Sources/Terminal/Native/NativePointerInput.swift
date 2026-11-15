import Foundation
import GhosttyVt

struct NativePointerModes: Equatable {
    let tracking: Bool
    let alternate: Bool
    let alternateScroll: Bool
    let pixels: Bool
    let signature: UInt64
}

struct NativeMouseInput {
    let action: GhosttyMouseAction
    let button: GhosttyMouseButton?
    let modifiers: GhosttyMods
    /// Top-left, active-screen coordinates in logical points.
    let position: CGPoint
    let cell: CGSize
    let scale: CGFloat
    let anyButton: Bool
    let modes: NativePointerModes
}

enum NativeWheelRoute: Equatable { case history, mouse, arrows, discard }

struct NativeWheelDecision {
    let route: NativeWheelRoute
    let x: Int
    let y: Int
}

/// A wheel gesture has one owner. A mode/bypass change discards its remaining
/// travel, including momentum; fractional reports never leak into history.
struct NativeWheelRouter {
    private var owner: NativeWheelRoute?
    private var signature: UInt64?
    private var discarded = false
    private var x: CGFloat = 0
    private var y: CGFloat = 0

    mutating func reset() { owner = nil; signature = nil; discarded = false; x = 0; y = 0 }
    mutating func discardRemainingGesture() { discarded = true; x = 0; y = 0 }

    mutating func route(modes: NativePointerModes, bypass: Bool, precise: Bool,
                        began: Bool, ended: Bool, momentumEnded: Bool,
                        delta: CGPoint, cell: CGSize, rows: Int, columns: Int,
                        hasGesturePhase: Bool = true) -> NativeWheelDecision {
        guard cell.width.isFinite, cell.height.isFinite, cell.width > 0, cell.height > 0,
              delta.x.isFinite, delta.y.isFinite else { reset(); return .init(route: .discard, x: 0, y: 0) }
        let requested: NativeWheelRoute = bypass ? .history : modes.tracking ? .mouse
            : modes.alternate ? (modes.alternateScroll ? .arrows : .discard) : .history
        if began || !precise { reset() }
        // Continuous devices can omit phases altogether. They have no momentum
        // stream to latch: discard the old bank, but don't disable them forever.
        if precise, !hasGesturePhase, discarded || owner != requested || signature != modes.signature { reset() }
        if owner == nil { owner = requested; signature = modes.signature }
        if owner != requested || signature != modes.signature { discarded = true; x = 0; y = 0 }
        let finishNative = (ended || momentumEnded) && owner == .history
        let route = finishNative ? NativeWheelRoute.history : discarded ? .discard : (owner ?? .discard)
        defer { if momentumEnded || (!precise && ended) { reset() } }
        guard route == .mouse || route == .arrows else { return .init(route: route, x: 0, y: 0) }
        if ended || momentumEnded { return .init(route: route, x: 0, y: 0) }
        let capX = max(1, min(columns, 40)), capY = max(1, min(rows, 40))
        if precise {
            x += max(-CGFloat(capX), min(CGFloat(capX), delta.x / max(1, cell.width)))
            y += max(-CGFloat(capY), min(CGFloat(capY), delta.y / max(1, cell.height)))
            let wholeX = Int(x.rounded(.towardZero)), wholeY = Int(y.rounded(.towardZero))
            x -= CGFloat(wholeX); y -= CGFloat(wholeY)
            return .init(route: route, x: wholeX, y: wholeY)
        }
        func ticks(_ value: CGFloat, cap: Int, multiplier: CGFloat) -> Int {
            guard value != 0 else { return 0 }
            return Int(min(CGFloat(cap), max(1, abs(value)) * multiplier)) * (value > 0 ? 1 : -1)
        }
        return .init(route: route, x: ticks(delta.x, cap: capX, multiplier: 1),
                     y: ticks(delta.y, cap: capY, multiplier: 3))
    }
}

struct NativeProgramScroll {
    let route: NativeWheelRoute
    let x: Int
    let y: Int
    let mouse: NativeMouseInput
}

struct NativeSelectionInput {
    enum Step { case press, drag, release }
    let step: Step
    let column: Int
    let row: Int
    let position: CGPoint
    let cell: CGSize
    let viewportHeight: CGFloat
    let time: TimeInterval
    let doubleClickInterval: TimeInterval
}
