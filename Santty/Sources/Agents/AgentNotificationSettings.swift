import Foundation

@MainActor
enum AgentNotificationSettings {
    static let didChangeNotification = Notification.Name(
        "AgentNotificationSettings.didChangeNotification")

    private static let claudeCodeEnabledKey = "agents.notifications.claudeCode.enabled"
    private static let codexEnabledKey = "agents.notifications.codex.enabled"
    private static let userDefaults = UserDefaults.standard

    static var isClaudeCodeEnabled: Bool {
        get {
            userDefaults.bool(forKey: claudeCodeEnabledKey)
        }
        set {
            userDefaults.set(newValue, forKey: claudeCodeEnabledKey)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    static var isCodexEnabled: Bool {
        get {
            userDefaults.bool(forKey: codexEnabledKey)
        }
        set {
            userDefaults.set(newValue, forKey: codexEnabledKey)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    static var isOtherAgentsEnabled: Bool {
        get { userDefaults.bool(forKey: "agents.notifications.herdrOther.enabled") }
        set { userDefaults.set(newValue, forKey: "agents.notifications.herdrOther.enabled") }
    }

    static func allows(_ agent: AgentKind) -> Bool {
        if agent.displayName == "Claude Code" { return isClaudeCodeEnabled }
        if agent == .codex { return isCodexEnabled }
        return isOtherAgentsEnabled
    }

    static func reset() {
        userDefaults.removeObject(forKey: "agents.notifications.herdrOther.enabled")
        userDefaults.removeObject(forKey: claudeCodeEnabledKey)
        userDefaults.removeObject(forKey: codexEnabledKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}
