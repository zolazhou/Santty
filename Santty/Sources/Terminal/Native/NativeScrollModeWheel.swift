import Foundation

/// Physical-row navigation bank only, never program input or another scroller.
/// Phased gestures require a fresh began; an inherited momentum tail is dropped.
struct NativeScrollModeWheel {
    private var fraction: CGFloat = 0
    private var discarded = true
    mutating func discard() { fraction = 0; discarded = true }

    mutating func rows(deltaY: CGFloat, rowHeight: CGFloat, precise: Bool,
                       began: Bool, ended: Bool, momentumEnded: Bool, hasPhase: Bool) -> Int {
        guard deltaY.isFinite, rowHeight.isFinite, rowHeight > 0 else { discard(); return 0 }
        if began || !precise || !hasPhase { if discarded { fraction = 0 }; discarded = false }
        if began { fraction = 0; discarded = false }
        if momentumEnded { discard(); return 0 }
        guard !discarded, !ended else { return 0 }
        let value = max(-40,min(40, precise ? -deltaY/rowHeight : -deltaY))
        if !precise { fraction = 0; return Int(value.rounded(.awayFromZero)) }
        fraction += value
        let whole = Int(fraction.rounded(.towardZero))
        fraction -= CGFloat(whole)
        return whole
    }
}
