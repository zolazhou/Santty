import Foundation
import GhosttyVt

/// receive() parses synchronously on the transport's serial stream queue.
/// Only one UI invalidation may be pending; the UI is not part of the credit
/// barrier. No input or protocol response is queued for a later connection.
final class NativeTerminalOutput: TerminalStreamEndpoint, @unchecked Sendable {
    let driver: GhosttyVTDriver
    private let lock = NSLock()
    private var writer: (@Sendable (Data) -> Bool)?
    private var replyWriter: (@Sendable (Data) -> Bool)?
    private var enabled = false
    private var inputSuppressions: Set<UUID> = []
    private var userInputGeneration = UUID()
    private var pending = false
    private var resetPending = false
    private let onPresentation: @MainActor @Sendable (Bool) -> Void
    @MainActor var onClipboardOfferChange: (() -> Void)?
    @MainActor var onMetadataChange: ((NativeTerminalMetadata) -> Void)?
    @MainActor private var deliveredMetadata: NativeTerminalMetadata?

    init(driver: GhosttyVTDriver, onPresentation: @escaping @MainActor @Sendable (Bool) -> Void) {
        self.driver = driver
        self.onPresentation = onPresentation
    }

    func bind(writer: @escaping @Sendable (Data) -> Void) {
        bindChecked { data in writer(data); return true }
    }

    /// true is queue acceptance, never proof the child consumed/executed it.
    func bindChecked(writer: @escaping @Sendable (Data) -> Bool,
                     automaticReplies: (@Sendable (Data) -> Bool)? = nil) {
        lock.withLock { self.writer = writer; self.replyWriter = automaticReplies ?? writer; userInputGeneration = UUID() }
        driver.discardClipboardOffers()
        notifyClipboardChange()
    }

    /// UI ownership gate, not a permission grant. Automatic replies and real
    /// focus changes keep their separate paths; no bytes are queued for exit.
    func suppressUserInput(_ suppressed: Bool, owner: UUID) {
        lock.withLock {
            let changed: Bool
            if suppressed { changed = inputSuppressions.insert(owner).inserted }
            else { changed = inputSuppressions.remove(owner) != nil }
            if changed { userInputGeneration = UUID() }
        }
    }

    func setInputEnabled(_ enabled: Bool) {
        let changed = lock.withLock {
            let changed = self.enabled != enabled; self.enabled = enabled
            if changed { userInputGeneration = UUID() }
            return changed
        }
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
            if !replies.isEmpty { _ = lock.withLock { replyWriter }?(replies) }
        }
        requestPresentation()
    }

    func waitForPendingOutput() -> Bool { true } // receive() already parsed it.

    func reset() {
        lock.withLock { userInputGeneration = UUID() }
        driver.reset()
        lock.withLock { resetPending = true }
        requestPresentation()
    }

    /// One user-input encoding and send point. Automatic protocol replies use
    /// their own always-draining path below, independent of user-input grants.
    func send(_ input: NativeTerminalInput) throws -> Bool {
        let isFocus: Bool
        if case .focus = input { isFocus = true } else { isFocus = false }
        guard let snapshot = lock.withLock({ () -> (UUID, @Sendable (Data) -> Bool)? in
            guard enabled, isFocus || inputSuppressions.isEmpty, let writer else { return nil }
            return (userInputGeneration, writer)
        }) else { return false }
        let bytes = try driver.encode(input)
        guard !bytes.isEmpty else { return true }
        guard lock.withLock({
            guard enabled, userInputGeneration == snapshot.0, isFocus || inputSuppressions.isEmpty else { return false }
            if !isFocus { userInputGeneration = UUID() }
            return true
        }) else { return false }
        return snapshot.1(bytes)
    }

    /// Launch/binding/input-owner receipt for deferred host actions. No writer
    /// closure or C pointer escapes, and a successful send is not delivery.
    var userInputLease: NativeUserInputLease? {
        guard let generation = lock.withLock({ enabled && inputSuppressions.isEmpty && writer != nil ? userInputGeneration : nil }) else { return nil }
        return .init(generation: generation, resetEpoch: driver.metadata.resetEpoch)
    }

    func sendHostPaste(_ bytes: Data, lease: NativeUserInputLease) -> Bool {
        guard driver.metadata.resetEpoch == lease.resetEpoch else { return false }
        let write = lock.withLock { () -> (@Sendable (Data) -> Bool)? in
            guard enabled, inputSuppressions.isEmpty, userInputGeneration == lease.generation, let writer else { return nil }
            userInputGeneration = UUID() // refusal/partial failure is never retried
            return writer
        }
        guard let write else { return false }
        return bytes.isEmpty || write(bytes)
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
        if !replies.isEmpty { _ = lock.withLock { replyWriter }?(replies) }
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
            let metadata = self.driver.metadata
            if metadata != self.deliveredMetadata {
                self.deliveredMetadata = metadata
                self.onMetadataChange?(metadata)
            }
            self.onPresentation(reset)
            self.onClipboardOfferChange?()
        }
    }
}
