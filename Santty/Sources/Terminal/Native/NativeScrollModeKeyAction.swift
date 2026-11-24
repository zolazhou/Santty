// Santty's existing Scroll Mode bindings; no terminal byte encoder.
import AppKit

enum NativeScrollModeKeyAction: Equatable {
    case exit
    case cancel
    case move(NativeScrollMovement)
    case select(linewise: Bool)
    case copy
    case awaitSecondG
    case consume

    init(event: NSEvent, awaitingSecondG: Bool) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if event.keyCode == 53 || event.characters == "\u{1b}" {
            self = .cancel
            return
        }

        if modifiers.isEmpty, key == "q" || key == "i" || event.keyCode == 36 {
            self = .exit
            return
        }

        if awaitingSecondG {
            if modifiers.isEmpty, key == "g" {
                self = .move(.top)
                return
            }
        }

        switch (modifiers, key, event.keyCode) {
        case ([], "h", _), ([], _, 123): self = .move(.left)
        case ([], "l", _), ([], _, 124): self = .move(.right)
        case ([], "j", _), ([], _, 125): self = .move(.down)
        case ([], "k", _), ([], _, 126): self = .move(.up)
        case ([], "0", _): self = .move(.lineStart)
        case ([.shift], "^", _), ([.shift], "6", _), ([], "^", _): self = .move(.firstNonblank)
        case ([], "w", _): self = .move(.wordForward(big: false))
        case ([], "b", _): self = .move(.wordBackward(big: false))
        case ([], "e", _): self = .move(.wordEnd(big: false))
        case ([.shift], "w", _): self = .move(.wordForward(big: true))
        case ([.shift], "b", _): self = .move(.wordBackward(big: true))
        case ([.shift], "e", _): self = .move(.wordEnd(big: true))
        case ([.shift], "$", _), ([.shift], "4", _), ([], "$", _): self = .move(.lineEnd)
        case ([], "v", _): self = .select(linewise: false)
        case ([.shift], "v", _): self = .select(linewise: true)
        case ([], "y", _), ([.command], "c", _): self = .copy
        case ([.control], "d", _):
            self = .move(.halfDown)
        case ([.control], "u", _):
            self = .move(.halfUp)
        case ([.control], "f", _), ([], _, 121):
            self = .move(.pageDown)
        case ([.control], "b", _), ([], _, 116):
            self = .move(.pageUp)
        case ([.shift], "g", _), ([], _, 119):
            self = .move(.bottom)
        case ([], "g", _):
            self = .awaitSecondG
        case ([], _, 115):
            self = .move(.top)
        default:
            self = .consume
        }
    }
}

