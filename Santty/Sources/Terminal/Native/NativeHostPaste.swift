import Foundation

enum NativeHostPasteError: Error { case tooLarge }

struct NativeUserInputLease: Equatable, Sendable {
    let generation: UUID
    let resetEpoch: UInt64
}

struct NativeHostPasteContext: Equatable, Sendable {
    let resetEpoch: UInt64
    let bracketed: Bool
}

enum NativeHostPasteEncoding: Sendable {
    case encoded(Data, NativeHostPasteContext)
    case needsReview(NativeHostPasteContext)
}

enum NativeHostActionResult: Equatable {
    case accepted, review(UUID), refused
    var ownsDrop: Bool { if case .refused = self { return false }; return true }
}

struct NativeHostPasteReview: Sendable {
    let id: UUID
    let byteCount: Int
    let preview: String
}
