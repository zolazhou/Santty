import Foundation

/// Backend-independent byte boundary. receive() may enqueue work, but its
/// barrier must report actual parsing completion, not just queue acceptance.
protocol TerminalStreamEndpoint: AnyObject, Sendable {
    func receive(_ data: Data)
    func waitForPendingOutput() -> Bool
    func reset()
}

struct TerminalStreamViewport: Sendable, Equatable {
    var columns: UInt16
    var rows: UInt16
    var widthPixels: UInt32 = 0
    var heightPixels: UInt32 = 0
    var cellWidthPixels: UInt32 = 0
    var cellHeightPixels: UInt32 = 0
}
