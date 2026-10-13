import AppKit
import GhosttyTerminal

enum HerdrClientShellInput {
    static func modifiers(_ flags: NSEvent.ModifierFlags) -> UInt8 {
        var result: UInt8 = 0
        if flags.contains(.shift) { result |= 1 }
        if flags.contains(.control) { result |= 2 }
        if flags.contains(.option) { result |= 4 }
        if flags.contains(.command) { result |= 8 }
        return result
    }

    static func mouse(kind: UInt32, button: UInt32? = nil, point: NSPoint, grid: TerminalGridMetrics,
                      scale: NSSize, pixel: Bool, flags: NSEvent.ModifierFlags, lines: UInt16 = 1,
                      clamp: Bool = false) -> HerdrShellInput.Mouse? {
        guard kind <= 7, (kind <= 2) == (button != nil), button.map({ $0 <= 2 }) ?? true,
              lines > 0, grid.columns > 0, grid.rows > 0, grid.cellWidthPixels > 0, grid.cellHeightPixels > 0,
              point.x.isFinite, point.y.isFinite, scale.width.isFinite, scale.height.isFinite,
              scale.width > 0, scale.height > 0 else { return nil }
        let width = UInt64(grid.columns) * UInt64(grid.cellWidthPixels)
        let height = UInt64(grid.rows) * UInt64(grid.cellHeightPixels)
        guard width <= UInt32.max, height <= UInt32.max else { return nil }
        var x = floor(point.x * scale.width), y = floor(point.y * scale.height)
        guard x.isFinite, y.isFinite else { return nil }
        if clamp { x = min(max(0, x), CGFloat(width - 1)); y = min(max(0, y), CGFloat(height - 1)) }
        guard x >= 0, y >= 0, x < CGFloat(width), y < CGFloat(height) else { return nil }
        return .init(kind: kind, button: button, column: UInt16(UInt32(x) / grid.cellWidthPixels),
                     row: UInt16(UInt32(y) / grid.cellHeightPixels), pixels: pixel ? (UInt32(x), UInt32(y)) : nil,
                     geometry: pixel ? (grid.columns, grid.rows, UInt32(width), UInt32(height)) : nil,
                     modifiers: modifiers(flags), lines: lines)
    }

    @MainActor
    static func key(_ event: NSEvent, translated: NSEvent, text: String?) -> HerdrShellInput.Key? {
        let special: UInt32?
        switch event.keyCode {
        case 51: special = 0
        case 36, 76: special = 1
        case 123: special = 2
        case 124: special = 3
        case 126: special = 4
        case 125: special = 5
        case 115: special = 6
        case 119: special = 7
        case 116: special = 8
        case 121: special = 9
        case 48: special = event.modifierFlags.contains(.shift) ? 11 : 10
        case 117: special = 12
        case 114: special = 13
        case 53: special = 14
        default: special = nil
        }
        let functions: [UInt16: UInt8] = [122: 1, 120: 2, 99: 3, 118: 4, 96: 5, 97: 6, 98: 7,
            100: 8, 101: 9, 109: 10, 103: 11, 111: 12, 105: 13, 107: 14, 113: 15,
            106: 16, 64: 17, 79: 18, 80: 19, 90: 20]
        let function = functions[event.keyCode]
        let base = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? ""
        let character = base.unicodeScalars.first.flatMap { scalar -> Unicode.Scalar? in
            scalar.value >= 32 && scalar.value != 127 && !(0xf700...0xf8ff).contains(scalar.value) ? scalar : nil
        }
        guard special != nil || function != nil || character != nil else { return nil }
        var modifiers = modifiers(event.modifierFlags)
        let code = special ?? (function == nil ? 15 : 16)
        let shifted = event.characters(byApplyingModifiers: [.shift])?.unicodeScalars.first
        let generated = text.flatMap { value in
            value.isEmpty || value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127
                || (0xf700...0xf8ff).contains($0.value) }) ? nil : value
        }
        if generated != nil, translated.modifierFlags.contains(.option) { modifiers &= ~4 }
        return .init(code: code, character: code == 15 ? character : nil, function: function,
                     modifiers: modifiers, kind: event.type == .keyUp ? 2 : event.isARepeat ? 1 : 0,
                     shiftedCodepoint: code == 15 && shifted != character ? shifted?.value : nil,
                     text: event.type == .keyUp ? nil : generated, tracksRelease: true,
                     physicalKeyID: UInt32(event.keyCode))
    }
}
