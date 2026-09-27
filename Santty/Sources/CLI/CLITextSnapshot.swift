import Foundation

enum CLITextSnapshot {
    static let maximumBytes = 256 * 1024

    static func response(_ text: String, request: CLIRequest) throws -> CLIResponse {
        try request.validate()
        // Keep the same line numbering for tail, ranges, and search. Empty grid
        // rows below the prompt are omitted; internal blank lines are retained.
        var content = text[...]
        while content.last == "\n" { content.removeLast() }
        let lines =
            content.isEmpty ? [] : content.split(separator: "\n", omittingEmptySubsequences: false)
        if request.command == "search" {
            return search(lines, request: request)
        }
        guard request.command == "read" else { throw CLIError("Expected read or search.") }
        if let start = request.startLine, start > lines.count {
            throw CLIError(
                "--start-line exceeds the current buffer (\(lines.count) lines). Search again to refresh line numbers."
            )
        }
        guard !lines.isEmpty else {
            return CLIResponse(text: "", truncated: false, totalLines: 0)
        }
        let start = request.startLine ?? max(1, lines.count - (request.tail ?? 200) + 1)
        let end = min(request.endLine ?? lines.count, lines.count)
        let selected = lines[(start - 1)..<end].joined(separator: "\n")
        let fromEnd = request.startLine == nil
        let output = boundedText(selected, bytes: maximumBytes, fromEnd: fromEnd)
        let returnedLines = output.utf8.filter { $0 == 10 }.count + 1
        return CLIResponse(
            text: output,
            truncated: selected.utf8.count > maximumBytes || (fromEnd && start > 1),
            startLine: fromEnd ? end - returnedLines + 1 : start,
            endLine: fromEnd ? end : start + returnedLines - 1,
            totalLines: lines.count
        )
    }

    private static func search(_ lines: [Substring], request: CLIRequest) -> CLIResponse {
        var matches: [CLIMatch] = []
        var totalMatches = 0
        var remainingBytes = maximumBytes
        let options: String.CompareOptions =
            request.ignoreCase == true ? [.literal, .caseInsensitive] : [.literal]
        for (index, line) in lines.enumerated() {
            guard line.range(of: request.query!, options: options) != nil else { continue }
            totalMatches += 1
            guard matches.count < (request.limit ?? 100), remainingBytes > 0 else { continue }
            let output = boundedText(String(line), bytes: remainingBytes, fromEnd: false)
            let truncated = output.utf8.count < line.utf8.count
            matches.append(CLIMatch(line: index + 1, text: output, truncated: truncated))
            remainingBytes -= output.utf8.count
            if truncated { remainingBytes = 0 }
        }
        return CLIResponse(
            truncated: matches.count < totalMatches || matches.contains(where: \.truncated),
            totalLines: lines.count, matches: matches, totalMatches: totalMatches
        )
    }

    private static func boundedText(_ text: String, bytes limit: Int, fromEnd: Bool) -> String {
        guard text.utf8.count > limit else { return text }
        var bytes = Array(fromEnd ? text.utf8.suffix(limit) : text.utf8.prefix(limit))
        if fromEnd {
            while let first = bytes.first, first & 0xC0 == 0x80 { bytes.removeFirst() }
        } else {
            // A prefix can end inside a scalar; remove only its incomplete bytes.
            while String(bytes: bytes, encoding: .utf8) == nil { bytes.removeLast() }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
