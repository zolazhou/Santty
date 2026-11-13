import Foundation

final class AXTestBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ data: Data) { lock.withLock { bytes.append(data) } }
    var count: Int { lock.withLock { bytes.count } }
}
