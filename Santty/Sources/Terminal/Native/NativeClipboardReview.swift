import AppKit

/// Explicit host action, separate from the already-denied synchronous VT write.
/// Approval consumes one exact, current offer; closing/reconnect/reset/rebind,
/// replacement, or expiry invalidates a sheet that was already open.
@MainActor
enum NativeClipboardReview {
    @discardableResult
    static func copy(id: UUID, output: NativeTerminalOutput, to pasteboard: NSPasteboard) -> Bool {
        guard let offer = output.claimClipboardOffer(id) else { return false }
        pasteboard.clearContents()
        switch offer.payload {
        case .clear: return true
        case let .text(text): return pasteboard.setString(text, forType: .string)
        }
    }

    static func present(output: NativeTerminalOutput, window: NSWindow) {
        guard let offer = output.clipboardOffer else { return }
        let alert = NSAlert()
        alert.messageText = "Copy terminal-provided text?"
        alert.informativeText = "This explicit action replaces your clipboard (\(offer.byteCount) bytes). The original protocol request was denied; clipboard reads and remembered grants are disabled.\n\nPreview (escaped, truncated):\n\(offer.preview)"
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Copy Once")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertSecondButtonReturn else { return }
            if !copy(id: offer.id, output: output, to: .general) { NSSound.beep() }
        }
    }
}
