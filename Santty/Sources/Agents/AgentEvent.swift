import Foundation

enum AgentKind: String, Codable {
    case claude
    case codex

    var displayName: String {
        switch self {
        case .claude:
            "Claude Code"
        case .codex:
            "Codex"
        }
    }
}

struct AgentStopEvent: Equatable {
    let agent: AgentKind
    let eventName: String
    let paneID: PaneID?
    let sessionID: String?
    let workingDirectory: String?
    let message: String?
    let timestamp: Date

    var deduplicationKey: String {
        [
            agent.rawValue,
            eventName,
            paneID?.uuidString ?? "",
            sessionID ?? "",
            workingDirectory ?? "",
            message ?? "",
        ].joined(separator: "\u{1F}")
    }
}

enum AgentNotificationEventKind: Equatable {
    case permissionRequested
    case notification
    case permissionDenied
}

struct AgentNotificationEvent: Equatable {
    let kind: AgentNotificationEventKind
    let agent: AgentKind
    let eventName: String
    let paneID: PaneID?
    let sessionID: String?
    let workingDirectory: String?
    let message: String?
    let timestamp: Date
}

struct AgentEventParser {
    private struct WrappedEvent: Decodable {
        let agent: AgentKind
        let payloadBase64: String
        let timestamp: TimeInterval?
        let paneID: String?
    }

    func parseLine(_ line: String) -> AgentStopEvent? {
        parseSessionEventLine(line)?.stopEvent
    }

    func parseSessionEventLine(_ line: String) -> AgentSessionEvent? {
        guard let data = line.data(using: .utf8),
            let wrappedEvent = try? JSONDecoder().decode(WrappedEvent.self, from: data),
            let payloadData = Data(base64Encoded: wrappedEvent.payloadBase64),
            let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        else {
            return nil
        }

        switch wrappedEvent.agent {
        case .claude:
            return parseClaudeSessionEvent(
                payload,
                paneID: parsePaneID(wrappedEvent.paneID),
                timestamp: wrappedEvent.timestamp
            )
        case .codex:
            return parseCodexSessionEvent(
                payload,
                paneID: parsePaneID(wrappedEvent.paneID),
                timestamp: wrappedEvent.timestamp
            )
        }
    }

    private func parseClaudeSessionEvent(
        _ payload: [String: Any],
        paneID: PaneID?,
        timestamp: TimeInterval?
    ) -> AgentSessionEvent? {
        let hookEventName = stringValue(
            for: ["hook_event_name", "hookEventName", "event"],
            in: payload
        )
        let eventKind: AgentSessionEventKind
        switch hookEventName {
        case "SessionStart":
            eventKind = .sessionStarted
        case "UserPromptSubmit":
            eventKind = .turnStarted
        case "Stop":
            eventKind = .turnCompleted
        case "PermissionRequest":
            eventKind = .permissionRequested
        case "Notification":
            eventKind = .notification
        case "PermissionDenied":
            eventKind = .permissionDenied
        case "SessionEnd":
            eventKind = .sessionEnded
        default:
            return nil
        }

        return AgentSessionEvent(
            kind: eventKind,
            agent: .claude,
            eventName: hookEventName ?? "Stop",
            paneID: paneID,
            sessionID: stringValue(for: ["session_id", "sessionId"], in: payload),
            workingDirectory: stringValue(for: ["cwd", "working_directory"], in: payload),
            message: stringValue(
                for: [
                    "last_assistant_message",
                    "message",
                    "reason",
                    "tool_name",
                    "toolName",
                    "notification_type",
                    "notificationType",
                    "permissionDecisionReason",
                ],
                in: payload
            ),
            timestamp: date(from: timestamp)
        )
    }

    private func parseCodexSessionEvent(
        _ payload: [String: Any],
        paneID: PaneID?,
        timestamp: TimeInterval?
    ) -> AgentSessionEvent? {
        let type = stringValue(for: ["type", "event"], in: payload)
        let hookEventName = stringValue(
            for: ["hook_event_name", "hookEventName"],
            in: payload
        )
        let eventKind: AgentSessionEventKind
        switch (type, hookEventName) {
        case ("agent-session-start", _), (_, "SessionStart"):
            eventKind = .sessionStarted
        case ("agent-turn-start", _), (_, "UserPromptSubmit"):
            eventKind = .turnStarted
        case ("agent-turn-complete", _), (nil, nil), (_, "Stop"):
            eventKind = .turnCompleted
        case ("agent-permission-request", _), (_, "PermissionRequest"):
            eventKind = .permissionRequested
        case ("agent-notification", _), (_, "Notification"):
            eventKind = .notification
        case ("agent-permission-denied", _), (_, "PermissionDenied"):
            eventKind = .permissionDenied
        case ("agent-waiting-for-user", _):
            eventKind = .waitingForUser
        default:
            return nil
        }

        return AgentSessionEvent(
            kind: eventKind,
            agent: .codex,
            eventName: type ?? hookEventName ?? "agent-turn-complete",
            paneID: paneID,
            sessionID: stringValue(for: ["thread-id", "thread_id", "turn-id", "turn_id"], in: payload),
            workingDirectory: stringValue(for: ["cwd", "working_directory"], in: payload),
            message: stringValue(
                for: [
                    "last-assistant-message",
                    "last_assistant_message",
                    "message",
                    "reason",
                    "tool_name",
                    "toolName",
                    "notification_type",
                    "notificationType",
                    "permission_decision_reason",
                    "permissionDecisionReason",
                ],
                in: payload
            ),
            timestamp: date(from: timestamp)
        )
    }

    private func stringValue(for keys: [String], in payload: [String: Any]) -> String? {
        for key in keys {
            guard let value = payload[key] else {
                continue
            }

            if let string = value as? String {
                let trimmedString = string.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmedString.isEmpty ? nil : trimmedString
            }

            if let number = value as? NSNumber {
                return number.stringValue
            }
        }

        return nil
    }

    private func date(from timestamp: TimeInterval?) -> Date {
        guard let timestamp else {
            return Date()
        }

        return Date(timeIntervalSince1970: timestamp)
    }

    private func parsePaneID(_ value: String?) -> PaneID? {
        guard let value else {
            return nil
        }

        return UUID(uuidString: value)
    }
}
