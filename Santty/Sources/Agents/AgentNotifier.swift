import Foundation
import UserNotifications

@MainActor
final class AgentNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AgentNotifier()
    var onActivate: ((HerdrTerminalBinding) -> Void)?
    var onReadMessage: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func notifyAgent(_ message: AgentMessage) {
        guard let request = request(for: message) else { return }
        Task { [weak self] in
            let center = UNUserNotificationCenter.current()
            do {
                guard try await center.requestAuthorization(options: [.alert, .sound]) else { return }
                try await center.add(request)
            } catch { self?.onError?(error.localizedDescription) }
        }
    }

    func request(for message: AgentMessage) -> UNNotificationRequest? {
        guard let target = try? JSONEncoder().encode(message.binding).base64EncodedString() else { return nil }
        let content = UNMutableNotificationContent()
        content.title = shortened(message.title)
        content.body = shortened([message.context, message.body].compactMap { $0 }.joined(separator: ": "))
        content.sound = .default
        content.userInfo = ["herdrTarget": target]
        return UNNotificationRequest(identifier: "herdr.agent." + message.id, content: content, trigger: nil)
    }

    static func target(from userInfo: [AnyHashable: Any]) -> HerdrTerminalBinding? {
        guard let encoded = userInfo["herdrTarget"] as? String, encoded.utf8.count <= 16384,
              let data = Data(base64Encoded: encoded),
              let binding = try? JSONDecoder().decode(HerdrTerminalBinding.self, from: data),
              !binding.coreID.isEmpty, binding.coreID.utf8.count <= 128,
              binding.coreID.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil,
              binding.address.range(of: "^t[0-9a-z]+$", options: .regularExpression) != nil else { return nil }
        return binding
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            let info = response.notification.request.content.userInfo
            let messageID = response.notification.request.identifier.hasPrefix("herdr.agent.")
                ? String(response.notification.request.identifier.dropFirst("herdr.agent.".count)) : nil
            let encoded = info["herdrTarget"] as? String
            Task { @MainActor [weak self] in
                if let encoded, let binding = Self.target(from: ["herdrTarget": encoded]) {
                    if let messageID { self?.onReadMessage?(messageID) }
                    self?.onActivate?(binding)
                }
            }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    private func shortened(_ value: String) -> String {
        let text = value.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > 180 ? String(text.prefix(177)) + "…" : text
    }
}
