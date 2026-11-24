import Foundation

/// Owned, raw VT metadata, not a local filesystem path or a Herdr identity.
/// Empty is an explicit clear; nil means unavailable (invalid UTF-8 / cap).
struct NativeTerminalMetadata: Equatable, Sendable {
    static let maximumBytes = 16 * 1024
    var title: String? = ""
    var rawWorkingDirectory: String? = ""
    var revision: UInt64 = 0
    var resetEpoch: UInt64 = 0

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.revision == rhs.revision && lhs.resetEpoch == rhs.resetEpoch
            && same(lhs.title, rhs.title) && same(lhs.rawWorkingDirectory, rhs.rawWorkingDirectory)
    }
    static func copy(bytes: UnsafePointer<UInt8>?, count: Int) -> String? {
        guard count >= 0, count <= maximumBytes else { return nil }
        if count == 0 { return "" }
        guard let bytes else { return nil }
        return String(bytes: UnsafeBufferPointer(start: bytes, count: count), encoding: .utf8)
    }
    static func same(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (a?, b?): return a.utf8.elementsEqual(b.utf8)
        default: return false
        }
    }
}
