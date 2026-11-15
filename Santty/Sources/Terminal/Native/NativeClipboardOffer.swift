import Foundation
import GhosttyVt

struct NativeClipboardOffer: Equatable, Sendable {
    enum Payload: Equatable, Sendable { case clear, text(String) }
    let id: UUID
    let payload: Payload
    let createdAt: TimeInterval

    var byteCount: Int { if case let .text(text) = payload { return text.utf8.count }; return 0 }
    var preview: String {
        guard case let .text(text) = payload else { return "Clear the clipboard" }
        let scalars = text.unicodeScalars.prefix(256)
        let visible = scalars.map { scalar -> String in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                return "\\u{\(String(scalar.value, radix: 16))}"
            default: return String(scalar)
            }
        }.joined()
        return visible + (text.unicodeScalars.count > 256 ? "…" : "")
    }
}

/// Bounded last-value capture adapted from herdr-app vt.rs (a547b16c,
/// Apache-2.0; see Keyboard-Adaptation-NOTICE.txt). All access holds the VT lock.
/// A valid offer is NOT an acknowledged protocol write. VT 1.0's reply is
/// synchronous: we deny it, then the user may explicitly copy the offered text.
/// No OS clipboard read, remembered grant, callback pointer or delayed reply.
final class NativeClipboardInbox {
    static let maximumBytes = 1 << 20
    static let maximumAge: TimeInterval = 120
    private var enabled = false
    private var pending: NativeClipboardOffer?

    func setEnabled(_ enabled: Bool) { self.enabled = enabled; if !enabled { clear() } }
    func clear() { pending = nil }
    func current(now: TimeInterval) -> NativeClipboardOffer? {
        if let pending, now - pending.createdAt >= Self.maximumAge { self.pending = nil }
        return pending
    }
    func take(id: UUID, now: TimeInterval) -> NativeClipboardOffer? {
        guard let offer = current(now: now), enabled, offer.id == id else { return nil }
        pending = nil
        return offer
    }

    func capture(_ write: GhosttyClipboardWrite, now: TimeInterval) -> GhosttyClipboardWriteResult {
        guard enabled else { return GHOSTTY_CLIPBOARD_WRITE_RESULT_DENIED }
        pending = nil
        guard write.location == GHOSTTY_CLIPBOARD_LOCATION_STANDARD,
              (0...1).contains(write.contents_len) else { return GHOSTTY_CLIPBOARD_WRITE_RESULT_UNSUPPORTED }
        let payload: NativeClipboardOffer.Payload
        if write.contents_len == 0 { payload = .clear }
        else {
            guard let content = write.contents?.pointee,
                  (0...64).contains(content.mime.len), let mime = content.mime.ptr,
                  Data(bytes: mime, count: content.mime.len) == Data("text/plain".utf8) else {
                return GHOSTTY_CLIPBOARD_WRITE_RESULT_UNSUPPORTED
            }
            guard (0...Self.maximumBytes).contains(content.data.len),
                  content.data.len == 0 || content.data.ptr != nil else {
                return GHOSTTY_CLIPBOARD_WRITE_RESULT_INVALID_DATA
            }
            let bytes = content.data.ptr.map { Data(bytes: $0, count: content.data.len) } ?? Data()
            guard let text = String(data: bytes, encoding: .utf8), !text.contains("\0") else {
                return GHOSTTY_CLIPBOARD_WRITE_RESULT_INVALID_DATA
            }
            payload = .text(text)
        }
        // Superseding a pending offer invalidates any already-open review sheet.
        pending = .init(id: UUID(), payload: payload, createdAt: now)
        return GHOSTTY_CLIPBOARD_WRITE_RESULT_DENIED
    }
}
