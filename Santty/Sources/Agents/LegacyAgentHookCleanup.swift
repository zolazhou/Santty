import Foundation

// Remove this bundle's previously installed hooks without installing helpers.
struct LegacyAgentHookCleanup {
    let home: URL
    let support: URL
    let owner: String

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         support: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Santty/AgentNotifications", isDirectory: true),
         owner: String = Bundle.main.bundleIdentifier ?? "com.zolazhou.santty") {
        self.home = home; self.support = support; self.owner = owner
    }

    func run() throws {
        let fm = FileManager.default
        let hook = support.appendingPathComponent("agent-hook").path
        let files = [(home.appendingPathComponent(".claude/settings.json"), "claude"),
                     (home.appendingPathComponent(".codex/hooks.json"), "codex")]
        var plans: [(URL, Data, Data)] = []
        var trustKeys = Set<String>()
        var remainingHelperReferences = false
        for (url, agent) in files where fm.fileExists(atPath: url.path) {
            let original = try Data(contentsOf: url)
            guard var root = try JSONSerialization.jsonObject(with: original) as? [String: Any] else {
                throw CLIError("Legacy agent hooks were not removed: invalid JSON object at \(url.path)")
            }
            guard var hooks = root["hooks"] as? [String: Any] else {
                remainingHelperReferences = remainingHelperReferences || referencesHelper(root)
                continue
            }
            var changed = false
            for event in Array(hooks.keys) {
                guard let groups = hooks[event] as? [[String: Any]] else { continue }
                var keptGroups: [[String: Any]] = []
                for (groupIndex, group) in groups.enumerated() {
                    guard let entries = group["hooks"] as? [[String: Any]] else { keptGroups.append(group); continue }
                    var kept: [[String: Any]] = []
                    for (hookIndex, entry) in entries.enumerated() {
                        let action = managedAction(entry, hook: hook, agent: agent)
                        if let action {
                            changed = true
                            if agent == "codex" { trustKeys.insert("\(url.path):\(action):\(groupIndex):\(hookIndex)") }
                        } else {
                            kept.append(entry)
                            if (entry["command"] as? String)?.contains(hook) == true { remainingHelperReferences = true }
                        }
                    }
                    if !kept.isEmpty || entries.isEmpty {
                        var next = group; next["hooks"] = kept; keptGroups.append(next)
                    }
                }
                if keptGroups.isEmpty { hooks.removeValue(forKey: event) }
                else { hooks[event] = keptGroups }
            }
            if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
            remainingHelperReferences = remainingHelperReferences || referencesHelper(root)
            guard changed else { continue }
            plans.append((url, original, try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])))
        }
        let configURL = home.appendingPathComponent(".codex/config.toml")
        if !trustKeys.isEmpty, fm.fileExists(atPath: configURL.path) {
            let original = try Data(contentsOf: configURL)
            guard let text = String(data: original, encoding: .utf8) else { throw CLIError("Codex configuration is not UTF-8") }
            let headers = Set(trustKeys.map { "[hooks.state.\"\($0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"]" })
            var skipping = false
            let lines = text.components(separatedBy: "\n").filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") { skipping = headers.contains(trimmed) }
                return !skipping
            }
            let replacement = Data(lines.joined(separator: "\n").utf8)
            if replacement != original { plans.append((configURL, original, replacement)) }
        }
        if fm.fileExists(atPath: configURL.path) {
            let data: Data
            if let planned = plans.first(where: { $0.0 == configURL }) { data = planned.2 }
            else { data = try Data(contentsOf: configURL) }
            let text = String(decoding: data, as: UTF8.self)
            for name in ["agent-hook", "claude-hook", "codex-notify", "codex-previous-notify"] {
                if text.contains(support.appendingPathComponent(name).path) { remainingHelperReferences = true }
            }
        }
        // Prepare all changes first; preserve invalid or concurrently edited configurations.
        for (url, original, _) in plans {
            guard try Data(contentsOf: url) == original else { throw CLIError("Agent configuration changed during cleanup: \(url.path)") }
        }
        for (url, original, replacement) in plans {
            let permissions = try fm.attributesOfItem(atPath: url.path)[.posixPermissions]
            let backup = url.appendingPathExtension("santty-backup-\(UUID().uuidString)")
            try original.write(to: backup, options: .withoutOverwriting)
            if let permissions { try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: backup.path) }
            try replacement.write(to: url, options: .atomic)
            if let permissions { try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
        }
        if !remainingHelperReferences {
            for name in ["agent-hook", "claude-hook", "codex-notify", "codex-previous-notify"] {
                let url = support.appendingPathComponent(name)
                guard fm.fileExists(atPath: url.path),
                      let text = try? String(contentsOf: url, encoding: .utf8),
                      text.contains("SANTTY_AGENT_SOCKET") || text.contains("SANTTY_RUNTIME_OWNER") else { continue }
                try fm.removeItem(at: url)
            }
        }
    }

    private func referencesHelper(_ value: Any) -> Bool {
        if let text = value as? String { return text.contains(support.path + "/") }
        if let values = value as? [Any] { return values.contains(where: referencesHelper) }
        if let values = value as? [String: Any] { return values.values.contains(where: referencesHelper) }
        return false
    }

    private func managedAction(_ entry: [String: Any], hook: String, agent: String) -> String? {
        guard entry["type"] as? String == "command", let command = entry["command"] as? String else { return nil }
        for action in ["session-start", "turn-start", "stop", "permission-request", "notification", "permission-denied", "session-end", "codex-start", "codex-stop", "codex-session-end"] {
            let expected = [hook, action, owner, agent].map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
            if command == expected { return action }
        }
        return nil
    }
}
