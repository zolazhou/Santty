import Foundation
import GhosttyTerminal

enum TerminalLoggingConfiguration {
    static func apply(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let rawValue = environment["SANTTY_TERMINAL_DEBUG_LOG"] else {
            TerminalDebugLog.disable()
            return
        }

        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch value {
        case "", "0", "false", "off", "none":
            TerminalDebugLog.disable()
        case "1", "true", "on", "standard":
            TerminalDebugLog.enable(.standard)
        case "all":
            TerminalDebugLog.enable(.all)
        default:
            TerminalDebugLog.enable(categories(from: value))
        }
    }

    private static func categories(from value: String) -> TerminalDebugCategory {
        var categories: TerminalDebugCategory = []
        for token in value.split(separator: ",") {
            switch token.trimmingCharacters(in: .whitespacesAndNewlines) {
            case "lifecycle":
                categories.insert(.lifecycle)
            case "metrics":
                categories.insert(.metrics)
            case "input":
                categories.insert(.input)
            case "output":
                categories.insert(.output)
            case "ime":
                categories.insert(.ime)
            case "actions":
                categories.insert(.actions)
            case "render":
                categories.insert(.render)
            default:
                break
            }
        }
        return categories
    }
}
