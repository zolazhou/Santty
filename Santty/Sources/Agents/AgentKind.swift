import Foundation

struct AgentKind: RawRepresentable, Codable, Sendable, Equatable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue.lowercased() }
    static let claude = Self(rawValue: "claude")
    static let codex = Self(rawValue: "codex")
    var displayName: String {
        switch rawValue {
        case "claude", "claude-code", "claude_code", "claude code": "Claude Code"
        case "codex": "Codex"
        default: rawValue
        }
    }
}
