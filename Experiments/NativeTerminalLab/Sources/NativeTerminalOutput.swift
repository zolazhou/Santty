import Foundation
import GhosttyVt

/// receive() parses synchronously on the transport's serial stream queue.
/// Only one UI invalidation may be pending; the UI is not part of the credit
/// barrier. No input or protocol response is queued for a later connection.
final class NativeTerminalOutput: TerminalStreamEndpoint, @unchecked Sendable {
    let driver: GhosttyVTDriver
    private let lock = NSLock()
    private var writer: (@Sendable (Data) -> Void)?
    private var enabled = false
    private var pending = false
    private var resetPending = false
    private let onPresentation: @MainActor @Sendable (Bool) -> Void
    @MainActor var onClipboardOfferChange: (() -> Void)?

    init(driver: GhosttyVTDriver, onPresentation: @escaping @MainActor @Sendable (Bool) -> Void) {
        self.driver = driver
        self.onPresentation = onPresentation
    }

    func bind(writer: @escaping @Sendable (Data) -> Void) {
        lock.withLock { self.writer = writer }
        driver.discardClipboardOffers()
        notifyClipboardChange()
    }

    func setInputEnabled(_ enabled: Bool) {
        let changed = lock.withLock { let changed = self.enabled != enabled; self.enabled = enabled; return changed }
        driver.setClipboardCaptureEnabled(enabled)
        if changed { notifyClipboardChange() }
    }

    var clipboardOffer: NativeClipboardOffer? { driver.clipboardOffer }
    func claimClipboardOffer(_ id: UUID) -> NativeClipboardOffer? {
        guard lock.withLock({ enabled && writer != nil }) else { return nil }
        let offer = driver.claimClipboardOffer(id)
        notifyClipboardChange()
        return offer
    }

    private func notifyClipboardChange() {
        Task { @MainActor [weak self] in self?.onClipboardOfferChange?() }
    }

    func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        // Bound temporary reply buffers even if a transport delivers a large
        // frame containing thousands of terminal queries.
        for start in stride(from: 0, to: data.count, by: 16 * 1024) {
            let lower = data.index(data.startIndex, offsetBy: start)
            let upper = data.index(data.startIndex, offsetBy: min(start + 16 * 1024, data.count))
            let replies = driver.feed(Data(data[lower..<upper]))
            if !replies.isEmpty { lock.withLock { writer }?(replies) }
        }
        requestPresentation()
    }

    func waitForPendingOutput() -> Bool { true } // receive() already parsed it.

    func reset() {
        driver.reset()
        lock.withLock { resetPending = true }
        requestPresentation()
    }

    /// One user-input encoding and send point. Automatic protocol replies use
    /// their own always-draining path below, independent of user-input grants.
    func send(_ input: NativeTerminalInput) throws -> Bool {
        guard let write = lock.withLock({ enabled ? writer : nil }) else { return false }
        let bytes = try driver.encode(input)
        if !bytes.isEmpty { write(bytes) }
        return true
    }

    func send(_ key: NativeTerminalKeyEvent) throws -> Bool { try send(.key(key)) }

    func sendKey(_ key: GhosttyKey, text: String? = nil, modifiers: GhosttyMods = 0,
                 action: GhosttyKeyAction = GHOSTTY_KEY_ACTION_PRESS,
                 unshiftedCodepoint: UInt32 = 0, optionAsAlt: Bool = false,
                 consumedModifiers: GhosttyMods = 0) throws -> Bool {
        try send(.key(.init(keyCode: 0, key: key, text: text, unshiftedCodepoint: unshiftedCodepoint,
            modifiers: modifiers, consumedModifiers: consumedModifiers, action: action,
            composing: false, optionAsAlt: optionAsAlt)))
    }

    func sendText(_ text: String) throws -> Bool { try send(.committedText(text)) }
    func paste(_ text: String) throws -> Bool { try send(.paste(text)) }
    func setFocused(_ focused: Bool) throws { _ = try send(.focus(focused)) }

    func sendAutomaticReplies(_ replies: Data) {
        if !replies.isEmpty { lock.withLock { writer }?(replies) }
    }

    private func requestPresentation() {
        let schedule = lock.withLock {
            guard !pending else { return false }
            pending = true
            return true
        }
        guard schedule else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let reset = self.lock.withLock {
                self.pending = false
                let reset = self.resetPending
                self.resetPending = false
                return reset
            }
            self.onPresentation(reset)
            self.onClipboardOfferChange?()
        }
    }
}
