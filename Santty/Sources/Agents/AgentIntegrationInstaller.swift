import CryptoKit
import Foundation

enum AgentIntegrationInstallerError: LocalizedError {
    case invalidClaudeSettings
    case invalidCodexHooks

    var errorDescription: String? {
        switch self {
        case .invalidClaudeSettings:
            "Claude Code settings.json is not a JSON object."
        case .invalidCodexHooks:
            "Codex hooks.json is not a JSON object."
        }
    }
}

struct AgentIntegrationPaths {
    static var applicationSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Santty", isDirectory: true)
            .appendingPathComponent("AgentNotifications", isDirectory: true)
    }

    static var eventSocketURL: URL {
        applicationSupportDirectory.appendingPathComponent("agent-events.sock")
    }

    static var runtimeOwner: String {
        Bundle.main.bundleIdentifier ?? "com.zolazhou.santty"
    }
}

struct AgentIntegrationInstaller {
    struct CodexHookTrustState: Equatable {
        let key: String
        let trustedHash: String
    }

    let fileManager: FileManager
    let homeDirectory: URL
    let applicationSupportDirectory: URL
    let runtimeOwner: String

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationSupportDirectory: URL = AgentIntegrationPaths.applicationSupportDirectory,
        runtimeOwner: String = AgentIntegrationPaths.runtimeOwner
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
        self.applicationSupportDirectory = applicationSupportDirectory
        self.runtimeOwner = runtimeOwner
    }

    var hookScriptURL: URL {
        applicationSupportDirectory.appendingPathComponent("agent-hook")
    }

    var claudeHookScriptURL: URL {
        hookScriptURL
    }

    var legacyClaudeHookScriptURL: URL {
        applicationSupportDirectory.appendingPathComponent("claude-hook")
    }

    var codexNotifyScriptURL: URL {
        applicationSupportDirectory.appendingPathComponent("codex-notify")
    }

    var codexPreviousNotifyScriptURL: URL {
        applicationSupportDirectory.appendingPathComponent("codex-previous-notify")
    }

    var eventSocketURL: URL {
        applicationSupportDirectory.appendingPathComponent("agent-events.sock")
    }

    private var claudeSettingsURL: URL {
        homeDirectory
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    private var codexHooksURL: URL {
        homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("hooks.json")
    }

    private var codexConfigURL: URL {
        homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("config.toml")
    }

    func installClaudeCodeIntegration() throws {
        try installScripts()
        try fileManager.createDirectory(
            at: claudeSettingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var settings = try readJSONObject(
            at: claudeSettingsURL,
            invalidError: AgentIntegrationInstallerError.invalidClaudeSettings
        )
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        hooks["SessionStart"] = upsertingManagedHookGroups(
            existing: hooks["SessionStart"],
            action: "session-start",
            agent: .claude,
            timeout: 10
        )
        hooks["UserPromptSubmit"] = upsertingManagedHookGroups(
            existing: hooks["UserPromptSubmit"],
            action: "turn-start",
            agent: .claude,
            timeout: 10
        )
        hooks["Stop"] = upsertingManagedHookGroups(
            existing: hooks["Stop"],
            action: "stop",
            agent: .claude,
            timeout: 10
        )
        hooks["PermissionRequest"] = upsertingManagedHookGroups(
            existing: hooks["PermissionRequest"],
            action: "permission-request",
            agent: .claude,
            timeout: 10
        )
        hooks["Notification"] = upsertingManagedHookGroups(
            existing: hooks["Notification"],
            action: "notification",
            agent: .claude,
            timeout: 10
        )
        hooks["PermissionDenied"] = upsertingManagedHookGroups(
            existing: hooks["PermissionDenied"],
            action: "permission-denied",
            agent: .claude,
            timeout: 10
        )
        hooks["SessionEnd"] = upsertingManagedHookGroups(
            existing: hooks["SessionEnd"],
            action: "session-end",
            agent: .claude,
            timeout: 10
        )
        stripManagedHook(
            action: "session-start",
            agent: .claude,
            from: &hooks,
            excludingEvent: "SessionStart"
        )
        stripManagedHook(
            action: "turn-start",
            agent: .claude,
            from: &hooks,
            excludingEvent: "UserPromptSubmit"
        )
        stripManagedHook(action: "stop", agent: .claude, from: &hooks, excludingEvent: "Stop")
        stripManagedHook(
            action: "permission-request",
            agent: .claude,
            from: &hooks,
            excludingEvent: "PermissionRequest"
        )
        stripManagedHook(
            action: "notification",
            agent: .claude,
            from: &hooks,
            excludingEvent: "Notification"
        )
        stripManagedHook(
            action: "permission-denied",
            agent: .claude,
            from: &hooks,
            excludingEvent: "PermissionDenied"
        )
        stripManagedHook(action: "session-end", agent: .claude, from: &hooks, excludingEvent: "SessionEnd")
        settings["hooks"] = hooks

        try writeJSONObjectIfChanged(settings, to: claudeSettingsURL)
    }

    func installCodexIntegration() throws {
        try installScripts()
        try fileManager.createDirectory(
            at: codexHooksURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var root = try readJSONObject(
            at: codexHooksURL,
            invalidError: AgentIntegrationInstallerError.invalidCodexHooks
        )
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        hooks["SessionStart"] = upsertingManagedHookGroups(
            existing: hooks["SessionStart"],
            action: "session-start",
            agent: .codex,
            timeout: 1000
        )
        hooks["UserPromptSubmit"] = upsertingManagedHookGroups(
            existing: hooks["UserPromptSubmit"],
            action: "turn-start",
            agent: .codex,
            timeout: 1000
        )
        hooks["Stop"] = upsertingManagedHookGroups(
            existing: hooks["Stop"],
            action: "stop",
            agent: .codex,
            timeout: 1000
        )
        hooks["PermissionRequest"] = upsertingManagedHookGroups(
            existing: hooks["PermissionRequest"],
            action: "permission-request",
            agent: .codex,
            timeout: 1000
        )
        stripManagedHook(
            action: "session-start",
            agent: .codex,
            from: &hooks,
            excludingEvent: "SessionStart"
        )
        stripManagedHook(
            action: "turn-start",
            agent: .codex,
            from: &hooks,
            excludingEvent: "UserPromptSubmit"
        )
        stripManagedHook(action: "stop", agent: .codex, from: &hooks, excludingEvent: "Stop")
        stripManagedHook(
            action: "permission-request",
            agent: .codex,
            from: &hooks,
            excludingEvent: "PermissionRequest"
        )
        root["hooks"] = hooks

        try writeJSONObjectIfChanged(root, to: codexHooksURL)

        let existingConfig = (try? String(contentsOf: codexConfigURL, encoding: .utf8)) ?? ""
        let updatedConfig = codexConfigByInstallingHooks(
            in: existingConfig,
            trustStates: codexHookTrustStates(from: root)
        )
        try writeStringIfChanged(updatedConfig, to: codexConfigURL)
    }

    func uninstallClaudeCodeIntegration(removeScripts: Bool) throws {
        guard fileManager.fileExists(atPath: claudeSettingsURL.path) else {
            if removeScripts {
                try uninstallScripts()
            }
            return
        }

        var settings = try readJSONObject(
            at: claudeSettingsURL,
            invalidError: AgentIntegrationInstallerError.invalidClaudeSettings
        )
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        stripManagedHook(action: "session-start", agent: .claude, from: &hooks)
        stripManagedHook(action: "turn-start", agent: .claude, from: &hooks)
        stripManagedHook(action: "stop", agent: .claude, from: &hooks)
        stripManagedHook(action: "permission-request", agent: .claude, from: &hooks)
        stripManagedHook(action: "notification", agent: .claude, from: &hooks)
        stripManagedHook(action: "permission-denied", agent: .claude, from: &hooks)
        stripManagedHook(action: "session-end", agent: .claude, from: &hooks)
        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }

        try writeJSONObjectIfChanged(settings, to: claudeSettingsURL)

        if removeScripts {
            try uninstallScripts()
        }
    }

    func uninstallCodexIntegration(removeScripts: Bool) throws {
        var trustStateKeys: Set<String> = []
        if fileManager.fileExists(atPath: codexHooksURL.path) {
            var root = try readJSONObject(
                at: codexHooksURL,
                invalidError: AgentIntegrationInstallerError.invalidCodexHooks
            )
            trustStateKeys = Set(codexHookTrustStates(from: root).map(\.key))

            var hooks = root["hooks"] as? [String: Any] ?? [:]
            stripManagedHook(action: "session-start", agent: .codex, from: &hooks)
            stripManagedHook(action: "turn-start", agent: .codex, from: &hooks)
            stripManagedHook(action: "stop", agent: .codex, from: &hooks)
            stripManagedHook(action: "permission-request", agent: .codex, from: &hooks)
            if hooks.isEmpty {
                root.removeValue(forKey: "hooks")
            } else {
                root["hooks"] = hooks
            }

            try writeJSONObjectIfChanged(root, to: codexHooksURL)
        }

        if fileManager.fileExists(atPath: codexConfigURL.path), !trustStateKeys.isEmpty {
            let existingConfig = (try? String(contentsOf: codexConfigURL, encoding: .utf8)) ?? ""
            let updatedConfig = codexConfigByRemovingHookTrust(in: existingConfig, keys: trustStateKeys)
            if updatedConfig != existingConfig {
                try writeStringIfChanged(updatedConfig, to: codexConfigURL)
            }
        }

        if removeScripts {
            try uninstallScripts()
        }
    }

    func installScripts() throws {
        try fileManager.createDirectory(
            at: applicationSupportDirectory,
            withIntermediateDirectories: true
        )

        try helperScript().write(to: hookScriptURL, atomically: true, encoding: .utf8)
        try markExecutable(hookScriptURL)
    }

    func uninstallScripts() throws {
        for url in [
            hookScriptURL,
            legacyClaudeHookScriptURL,
            codexNotifyScriptURL,
            codexPreviousNotifyScriptURL,
        ] where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    func codexConfigByInstallingHooks(
        in config: String,
        trustStates: [CodexHookTrustState] = []
    ) -> String {
        let targetLine = "suppress_unstable_features_warning = true"
        let featuresHeader = "[features]"
        let hooksFeatureLine = "hooks = true"

        func normalized(_ line: String) -> String {
            line.trimmingCharacters(in: .whitespaces)
        }

        func isTableHeader(_ line: String) -> Bool {
            let trimmed = normalized(line)
            return trimmed.hasPrefix("[") && trimmed.hasSuffix("]")
        }

        func keyName(_ line: String) -> String? {
            let trimmed = normalized(line)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                let equalsIndex = trimmed.firstIndex(of: "=")
            else {
                return nil
            }

            return trimmed[..<equalsIndex].trimmingCharacters(in: .whitespaces)
        }

        var lines = config
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !normalized($0).hasPrefix("suppress_unstable_features_warning") }

        while lines.last?.isEmpty == true {
            lines.removeLast()
        }

        if lines.isEmpty {
            lines = [targetLine]
        } else {
            let firstTableIndex = lines.firstIndex(where: isTableHeader)
            let insertionIndex = firstTableIndex.map { index in
                var insertion = index
                while insertion > 0, normalized(lines[insertion - 1]).isEmpty {
                    insertion -= 1
                }

                return insertion
            } ?? lines.count
            lines.insert(targetLine, at: insertionIndex)
            if let firstTableIndex, insertionIndex == firstTableIndex {
                lines.insert("", at: insertionIndex + 1)
            }
        }

        if let featuresIndex = lines.firstIndex(where: { normalized($0) == featuresHeader }) {
            var sectionEnd = featuresIndex + 1
            while sectionEnd < lines.count, !isTableHeader(lines[sectionEnd]) {
                sectionEnd += 1
            }

            var hookLineIndex: Int?
            var legacyHookLineIndex: Int?
            var removalIndices: [Int] = []
            for index in (featuresIndex + 1)..<sectionEnd {
                switch keyName(lines[index]) {
                case "hooks":
                    hookLineIndex = hookLineIndex ?? index
                    if hookLineIndex != index {
                        removalIndices.append(index)
                    }
                case "codex_hooks":
                    legacyHookLineIndex = legacyHookLineIndex ?? index
                    if legacyHookLineIndex != index {
                        removalIndices.append(index)
                    }
                default:
                    break
                }
            }

            if let hookLineIndex {
                lines[hookLineIndex] = hooksFeatureLine
                if let legacyHookLineIndex {
                    removalIndices.append(legacyHookLineIndex)
                }
            } else if let legacyHookLineIndex {
                lines[legacyHookLineIndex] = hooksFeatureLine
            } else {
                lines.insert(hooksFeatureLine, at: sectionEnd)
            }

            for index in removalIndices.sorted(by: >) {
                lines.remove(at: index)
            }
        } else {
            if !lines.isEmpty, !normalized(lines.last ?? "").isEmpty {
                lines.append("")
            }
            lines.append(featuresHeader)
            lines.append(hooksFeatureLine)
        }

        lines = removingTrustStateBlocks(from: lines, keys: Set(trustStates.map(\.key)))
        if !trustStates.isEmpty {
            if !lines.contains(where: { normalized($0) == "[hooks.state]" }) {
                if !lines.isEmpty, !normalized(lines.last ?? "").isEmpty {
                    lines.append("")
                }
                lines.append("[hooks.state]")
            }

            for state in trustStates.sorted(by: { $0.key < $1.key }) {
                if !lines.isEmpty, !normalized(lines.last ?? "").isEmpty {
                    lines.append("")
                }
                lines.append("[hooks.state.\(tomlQuoted(state.key))]")
                lines.append("trusted_hash = \(tomlQuoted(state.trustedHash))")
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    func codexConfigByRemovingHookTrust(in config: String, keys: Set<String>) -> String {
        var lines = config
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        lines = removingTrustStateBlocks(from: lines, keys: keys)
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
    }

    private func upsertingManagedHookGroups(
        existing: Any?,
        action: String,
        agent: AgentKind,
        timeout: Int
    ) -> [[String: Any]] {
        let command = hookCommand(action: action, agent: agent)
        let replacement: [String: Any] = [
            "type": "command",
            "command": command,
            "timeout": timeout,
            "statusMessage": "santty \(agent.rawValue) \(statusMessageAction(for: action))",
        ]
        let groups = existing as? [[String: Any]] ?? []
        var didReplace = false
        var result: [[String: Any]] = []

        for group in groups {
            let hooks = group["hooks"] as? [[String: Any]] ?? []
            var nextHooks: [[String: Any]] = []
            for hook in hooks {
                if isManagedHook(hook, action: action, agent: agent) {
                    if !didReplace {
                        nextHooks.append(replacement)
                        didReplace = true
                    }
                } else {
                    nextHooks.append(hook)
                }
            }

            guard !nextHooks.isEmpty else {
                continue
            }

            var nextGroup = group
            nextGroup["hooks"] = nextHooks
            result.append(nextGroup)
        }

        if !didReplace {
            result.append([
                "matcher": "",
                "hooks": [replacement],
            ])
        }

        return result
    }

    private func statusMessageAction(for action: String) -> String {
        if action == "session-start" || action == "turn-start" {
            return "start"
        }
        if action == "session-end" {
            return "session end"
        }
        if action == "permission-request" {
            return "permission request"
        }
        if action == "notification" {
            return "notification"
        }
        if action == "permission-denied" {
            return "permission denied"
        }
        return "stop"
    }

    private func stripManagedHook(
        action: String,
        agent: AgentKind,
        from hooks: inout [String: Any],
        excludingEvent: String? = nil
    ) {
        for eventKey in Array(hooks.keys) where eventKey != excludingEvent {
            let groups = (hooks[eventKey] as? [[String: Any]] ?? []).compactMap { group -> [String: Any]? in
                let groupHooks = group["hooks"] as? [[String: Any]] ?? []
                let filteredHooks = groupHooks.filter { !isManagedHook($0, action: action, agent: agent) }
                guard !filteredHooks.isEmpty else {
                    return nil
                }

                var nextGroup = group
                nextGroup["hooks"] = filteredHooks
                return nextGroup
            }

            if groups.isEmpty {
                hooks.removeValue(forKey: eventKey)
            } else {
                hooks[eventKey] = groups
            }
        }
    }

    private func isManagedHook(_ hook: [String: Any], action: String, agent: AgentKind) -> Bool {
        guard (hook["type"] as? String) == "command",
            let command = hook["command"] as? String,
            command.contains(hookScriptURL.path)
        else {
            return false
        }

        guard commandContainsShellArgument(command, argument: action) else {
            return false
        }

        return commandContainsShellArgument(command, argument: runtimeOwner)
            && commandContainsShellArgument(command, argument: agent.rawValue)
    }

    private func codexHookTrustStates(from root: [String: Any]) -> [CodexHookTrustState] {
        guard let hooks = root["hooks"] as? [String: Any] else {
            return []
        }

        var states: [CodexHookTrustState] = []
        for eventName in ["SessionStart", "UserPromptSubmit", "Stop", "PermissionRequest"] {
            let groups = hooks[eventName] as? [[String: Any]] ?? []
            for (groupIndex, group) in groups.enumerated() {
                let hookEntries = group["hooks"] as? [[String: Any]] ?? []
                for (hookIndex, hook) in hookEntries.enumerated() {
                    guard (hook["type"] as? String) == "command",
                        let command = hook["command"] as? String,
                        let action = managedCodexAction(in: command),
                        commandContainsShellArgument(command, argument: runtimeOwner),
                        commandContainsShellArgument(command, argument: AgentKind.codex.rawValue)
                    else {
                        continue
                    }

                    let timeout = max(hook["timeout"] as? Int ?? 1000, 1)
                    let statusMessage = hook["statusMessage"] as? String
                    states.append(
                        CodexHookTrustState(
                            key: "\(codexHooksURL.path):\(action):\(groupIndex):\(hookIndex)",
                            trustedHash: codexCommandHookTrustHash(
                                eventName: codexTrustEventName(for: eventName),
                                command: command,
                                timeout: timeout,
                                statusMessage: statusMessage
                            )
                        )
                    )
                }
            }
        }

        return states
    }

    private func managedCodexAction(in command: String) -> String? {
        for action in ["session-start", "turn-start", "stop", "permission-request"] {
            if commandContainsShellArgument(command, argument: action) {
                return action
            }
        }

        return nil
    }

    private func codexTrustEventName(for hookEventName: String) -> String {
        switch hookEventName {
        case "SessionStart":
            "session-start"
        case "UserPromptSubmit":
            "user-prompt-submit"
        case "PermissionRequest":
            "permission-request"
        default:
            "stop"
        }
    }

    private func codexCommandHookTrustHash(
        eventName: String,
        command: String,
        timeout: Int,
        statusMessage: String?
    ) -> String {
        let statusJSON = statusMessage.map(jsonStringLiteral) ?? "null"
        let canonicalJSON =
            "{\"event_name\":\"\(eventName)\",\"hooks\":[{\"async\":false,"
            + "\"command\":\(jsonStringLiteral(command)),"
            + "\"statusMessage\":\(statusJSON),"
            + "\"timeout\":\(timeout),\"type\":\"command\"}]}"
        let digest = SHA256.hash(data: Data(canonicalJSON.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "sha256:\(digest)"
    }

    private func removingTrustStateBlocks(from lines: [String], keys: Set<String>) -> [String] {
        guard !keys.isEmpty else {
            return lines
        }

        func normalized(_ line: String) -> String {
            line.trimmingCharacters(in: .whitespaces)
        }

        func isTableHeader(_ line: String) -> Bool {
            let trimmed = normalized(line)
            return trimmed.hasPrefix("[") && trimmed.hasSuffix("]")
        }

        func hookStateKey(from line: String) -> String? {
            let trimmed = normalized(line)
            let prefix = "[hooks.state.\""
            let suffix = "\"]"
            guard trimmed.hasPrefix(prefix), trimmed.hasSuffix(suffix) else {
                return nil
            }

            let start = trimmed.index(trimmed.startIndex, offsetBy: prefix.count)
            let end = trimmed.index(trimmed.endIndex, offsetBy: -suffix.count)
            return String(trimmed[start..<end])
        }

        var result: [String] = []
        var index = 0
        while index < lines.count {
            if let key = hookStateKey(from: lines[index]), keys.contains(key) {
                index += 1
                while index < lines.count, !isTableHeader(lines[index]) {
                    index += 1
                }
            } else {
                result.append(lines[index])
                index += 1
            }
        }

        return result
    }

    private func readJSONObject(
        at url: URL,
        invalidError: AgentIntegrationInstallerError
    ) throws -> [String: Any] {
        guard fileManager.fileExists(atPath: url.path) else {
            return [:]
        }

        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw invalidError
        }

        return dictionary
    }

    private func writeJSONObject(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        try writeDataIfChanged(data, to: url)
    }

    private func writeJSONObjectIfChanged(_ object: [String: Any], to url: URL) throws {
        try writeJSONObject(object, to: url)
    }

    private func writeStringIfChanged(_ string: String, to url: URL) throws {
        try writeDataIfChanged(Data(string.utf8), to: url)
    }

    private func writeDataIfChanged(_ data: Data, to url: URL) throws {
        if let existingData = try? Data(contentsOf: url), existingData == data {
            return
        }

        try backupIfExists(url)
        try data.write(to: url, options: .atomic)
    }

    private func helperScript() -> String {
        """
        #!/bin/sh
        set -eu
        action="${1:-}"
        hook_owner="${2:-}"
        agent="${3:-}"
        payload="${4:-}"

        if [ "${SANTTY_RUNTIME_OWNER:-}" != "$hook_owner" ]; then
          exit 0
        fi
        if [ -z "${SANTTY_PANE_ID:-}" ] || [ -z "$agent" ]; then
          exit 0
        fi
        case "$action" in
          session-start|turn-start|stop|permission-request|notification|permission-denied|session-end) ;;
          *) exit 0 ;;
        esac

        if [ -z "$payload" ]; then
          payload="$(cat)"
        fi

        socket_path="${SANTTY_AGENT_SOCKET:-\(eventSocketURL.path)}"
        if [ -z "$socket_path" ] || [ ! -S "$socket_path" ]; then
          exit 0
        fi
        encoded="$(printf '%s' "$payload" | /usr/bin/base64 | /usr/bin/tr -d '\\n')"
        timestamp="$(/bin/date +%s)"
        printf '{"agent":"%s","paneID":"%s","runtimeOwner":"%s","payloadBase64":"%s","timestamp":%s}\\n' "$agent" "$SANTTY_PANE_ID" "$SANTTY_RUNTIME_OWNER" "$encoded" "$timestamp" | /usr/bin/nc -U "$socket_path" >/dev/null 2>&1 || true

        """
    }

    private func hookCommand(action: String, agent: AgentKind) -> String {
        [
            shellQuoted(hookScriptURL.path),
            shellQuoted(action),
            shellQuoted(runtimeOwner),
            shellQuoted(agent.rawValue),
        ].joined(separator: " ")
    }

    private func commandContainsShellArgument(_ command: String, argument: String) -> Bool {
        let token = shellQuoted(argument)
        return command.contains(" \(token) ")
            || command.hasPrefix("\(token) ")
            || command.hasSuffix(" \(token)")
            || command == token
    }

    private func tomlQuoted(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t") + "\""
    }

    private func jsonStringLiteral(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value])
        let json = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(json.dropFirst().dropLast())
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func backupIfExists(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backupURL = url.deletingLastPathComponent()
            .appendingPathComponent(
                "\(url.lastPathComponent).santty-backup-\(formatter.string(from: Date()))-\(UUID().uuidString)"
            )
        try fileManager.copyItem(at: url, to: backupURL)
    }

    private func markExecutable(_ url: URL) throws {
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }
}
