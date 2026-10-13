import Foundation
import UserNotifications

@MainActor
final class AgentNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AgentNotifier()
    var onActivate: ((HerdrPaneBinding) -> Void)?
    private var recentTerminalNotices: [Int: TimeInterval] = [:]

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func notifyAgent(_ message: AgentMessage) {
        guard AgentNotificationSettings.allows(message.agent),
              let target = try? JSONEncoder().encode(message.binding).base64EncodedString() else { return }
        let content = UNMutableNotificationContent()
        content.title = shortened(message.title)
        content.body = shortened([message.context, message.body].compactMap { $0 }.joined(separator: ": "))
        if message.sound { content.sound = .default }
        content.userInfo = ["herdrTarget": target]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "herdr.agent.\(message.id)", content: content, trigger: nil))
    }

    func notifyTerminal(title: String, body: String?, sound: Bool, identity: String) {
        let title = shortened(title), body = shortened(body ?? "")
        var hasher = Hasher(); hasher.combine(identity); hasher.combine(title); hasher.combine(body)
        let key = hasher.finalize(), now = ProcessInfo.processInfo.systemUptime
        if let previous = recentTerminalNotices[key], now - previous < 2 { return }
        if recentTerminalNotices.count >= 64, let oldest = recentTerminalNotices.min(by: { $0.value < $1.value })?.key { recentTerminalNotices.removeValue(forKey: oldest) }
        recentTerminalNotices[key] = now
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body
        if sound { content.sound = .default }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "herdr-\(key)", content: content, trigger: nil))
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let target = response.notification.request.content.userInfo["herdrTarget"] as? String
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           let target, target.utf8.count <= 16384, let data = Data(base64Encoded: target),
           let binding = try? JSONDecoder().decode(HerdrPaneBinding.self, from: data) {
            Task { @MainActor [weak self] in self?.onActivate?(binding) }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    private func shortened(_ value: String) -> String {
        let text = value.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > 180 ? String(text.prefix(177)) + "..." : text
    }
}
