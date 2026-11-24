import Foundation

/// The existing pane URL parser, shared with the isolated native adapter.
/// Parsing is not approval: callers must separately enforce scheme/host policy.
enum TerminalLinkValidation {
    static func url(_ text: String) -> URL? {
        guard !text.isEmpty, text.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        if text.hasPrefix("/") { return URL(fileURLWithPath: text) }
        guard let url = URL(string: text, encodingInvalidCharacters: false),
              let scheme = url.scheme?.lowercased() else { return nil }
        if ["http", "https"].contains(scheme), url.host?.isEmpty != false { return nil }
        return url
    }
}
