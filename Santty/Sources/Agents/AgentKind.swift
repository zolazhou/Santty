import Foundation

struct AgentKind: RawRepresentable, Codable, Sendable, Equatable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue.lowercased() }
    static let claude = Self(rawValue: "claude")
    static let codex = Self(rawValue: "codex")
    var brandIcon: BrandIcon? {
        switch rawValue {
        case "claude", "claude-code", "claude_code", "claude code": .claudeCode
        case "codex": .codex
        case "pi", "pi-coding-agent": .pi
        case "opencode", "open-code": .opencode
        case "copilot", "github-copilot", "github_copilot", "github copilot", "copilot-cli": .copilot
        default: nil
        }
    }
    var displayName: String {
        switch brandIcon {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .pi: "pi"
        case .opencode: "OpenCode"
        case .copilot: "GitHub Copilot"
        case .herdr, nil: rawValue.isEmpty || rawValue == "agent" ? "Agent" : rawValue
        }
    }
}
