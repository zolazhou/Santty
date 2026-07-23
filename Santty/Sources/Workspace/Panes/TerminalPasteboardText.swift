import AppKit

enum TerminalPasteboardText {
    static let dropTypes: Set<NSPasteboard.PasteboardType> = [
        .string,
        .fileURL,
        .URL,
    ]

    static func dropInsertionText(from pasteboard: NSPasteboard) -> String? {
        if let url = pasteboard.string(forType: .URL) {
            return escapedForTerminal(url)
        }

        if let text = urlInsertionText(from: pasteboard) {
            return text
        }

        return pasteboard.string(forType: .string)
    }

    static func urlInsertionText(from pasteboard: NSPasteboard) -> String? {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
              !urls.isEmpty else {
            return nil
        }

        return urls
            .map { url in
                url.isFileURL ? escapedForTerminal(url.path) : url.absoluteString
            }
            .joined(separator: " ")
    }

    static func escapedForTerminal(_ string: String) -> String {
        let escapeCharacters = "\\ ()[]{}<>\"'`!#$&;|*?\t"
        var result = string
        for character in escapeCharacters {
            result = result.replacingOccurrences(
                of: String(character),
                with: "\\\(character)"
            )
        }
        return result
    }
}
