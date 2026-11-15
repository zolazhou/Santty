import Foundation
import GhosttyVt

enum NativeReadSnapshotError: Error, Equatable {
    case invalidLimit, tooLarge, invalidUTF8
}

/// Temporary plaintext owned by ONE read. No render-state update, terminal
/// selection, scrolling, tick, input or persistent history mirror is involved.
/// The caller holds the driver's VT lock for formatter lifetime + all writes.
enum GhosttyVTReadSnapshot {
    static let maximumBytes = 32 * 1024 * 1024

    static func capture(terminal: GhosttyTerminal, maximumBytes limit: Int) throws -> String {
        guard (0...maximumBytes).contains(limit) else { throw NativeReadSnapshotError.invalidLimit }
        try Task.checkCancellation()
        var formatter: GhosttyFormatter?
        try check(ghostty_formatter_terminal_new(nil, &formatter, terminal), "read_formatter_new")
        defer { ghostty_formatter_free(formatter) }
        var plain = GHOSTTY_FORMATTER_FORMAT_PLAIN, yes = true
        try check(ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_EMIT, &plain), "read_plain")
        try check(ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_UNWRAP, &yes), "read_unwrap")
        try check(ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_TRIM, &yes), "read_trim")
        // A formatter-local nil selection means the entire ACTIVE SCREEN,
        // including its retained history. It never reads the user's selection.
        try check(ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_SELECTION, nil), "read_entire_screen")
        let sink = NativeReadSink(limit: limit)
        let writer = GhosttyWriter(write: nativeReadWrite, userdata: Unmanaged.passUnretained(sink).toOpaque())
        let result = ghostty_formatter_format(formatter, writer)
        if sink.cancelled { throw CancellationError() }
        if sink.limited { throw NativeReadSnapshotError.tooLarge }
        try check(result, "read_format")
        try Task.checkCancellation()
        guard let text = String(data: sink.bytes, encoding: .utf8) else { throw NativeReadSnapshotError.invalidUTF8 }
        return text
    }

    private static func check(_ result: GhosttyResult, _ operation: String) throws {
        guard result == GHOSTTY_SUCCESS else { throw NativeTerminalError.api(operation, result.rawValue) }
    }
}

/// This internal C writer is synchronous, thread-confined and copies borrowed
/// slices immediately. A failure discards its prefix; there is no partial reply
/// or retry. The byte cap is NOT a total-RSS bound on VT/Foundation temporaries.
private final class NativeReadSink {
    let limit: Int
    var bytes = Data()
    var limited = false
    var cancelled = false
    init(limit: Int) { self.limit = limit }
}

private let nativeReadWrite: GhosttyWriterFn = { userdata, pointer, count in
    guard let userdata, let pointer else { return false }
    let sink = Unmanaged<NativeReadSink>.fromOpaque(userdata).takeUnretainedValue()
    if Task.isCancelled { sink.cancelled = true; return false }
    guard count >= 0, count <= sink.limit - sink.bytes.count else { sink.limited = true; return false }
    sink.bytes.append(pointer, count: count)
    return true
}
