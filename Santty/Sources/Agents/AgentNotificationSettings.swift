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

    static func reset() {
        userDefaults.removeObject(forKey: claudeCodeEnabledKey)
        userDefaults.removeObject(forKey: codexEnabledKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}
