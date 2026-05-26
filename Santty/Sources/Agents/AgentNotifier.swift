import Foundation
import UserNotifications

@MainActor
final class AgentNotifier {
    static let shared = AgentNotifier()

    private init() {}

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
            _, _ in
        }
    }

    func notifyStop(_ event: AgentStopEvent) {
        let content = UNMutableNotificationContent()
        content.title = "\(event.agent.displayName) finished"
        content.body = notificationBody(for: event)
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "agent-stop-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func notify(_ event: AgentNotificationEvent) {
        let content = UNMutableNotificationContent()
        content.title = notificationTitle(for: event)
        content.body = notificationBody(for: event)
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "agent-notification-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func notificationBody(for event: AgentStopEvent) -> String {
        let paneTitle = event.paneID
            .flatMap { AgentPaneRegistry.shared.snapshot(for: $0)?.title }

        if let message = event.message {
            return [paneTitle, shortened(message)]
                .compactMap { $0 }
                .joined(separator: ": ")
        }

        if let workingDirectory = event.workingDirectory {
            let directoryName = URL(fileURLWithPath: workingDirectory).lastPathComponent
            return [paneTitle, directoryName]
                .compactMap { $0 }
                .joined(separator: ": ")
        }

        return paneTitle.map { "\($0): Agent turn completed." } ?? "Agent turn completed."
    }

    private func notificationTitle(for event: AgentNotificationEvent) -> String {
        switch event.kind {
        case .permissionRequested:
            return "\(event.agent.displayName) needs permission"
        case .notification:
            return "\(event.agent.displayName) notification"
        case .permissionDenied:
            return "\(event.agent.displayName) denied permission"
        }
    }

    private func notificationBody(for event: AgentNotificationEvent) -> String {
        let paneTitle = event.paneID
            .flatMap { AgentPaneRegistry.shared.snapshot(for: $0)?.title }

        if let message = event.message {
            return [paneTitle, shortened(message)]
                .compactMap { $0 }
                .joined(separator: ": ")
        }

        if let workingDirectory = event.workingDirectory {
            let directoryName = URL(fileURLWithPath: workingDirectory).lastPathComponent
            return [paneTitle, directoryName]
                .compactMap { $0 }
                .joined(separator: ": ")
        }

        return switch event.kind {
        case .permissionRequested:
            paneTitle.map { "\($0): Permission request." } ?? "Permission request."
        case .notification:
            paneTitle.map { "\($0): Notification." } ?? "Notification."
        case .permissionDenied:
            paneTitle.map { "\($0): Permission denied." } ?? "Permission denied."
        }
    }

    private func shortened(_ value: String) -> String {
        let normalizedValue =
            value
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedValue.count > 140 else {
            return normalizedValue
        }

        return String(normalizedValue.prefix(137)) + "..."
    }
}
