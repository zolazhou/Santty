import Foundation

enum AgentSessionEventKind: Equatable {
    case sessionStarted
    case turnStarted
    case turnCompleted
    case waitingForUser
    case permissionRequested
    case notification
    case permissionDenied
    case sessionEnded
}

enum AgentSessionDisplayState: Equatable {
    case running
    case turnCompleted
    case waitingForUser
    case sessionEnded
}

struct AgentSessionEvent: Equatable {
    let kind: AgentSessionEventKind
    let agent: AgentKind
    let eventName: String
    let paneID: PaneID?
    let sessionID: String?
    let workingDirectory: String?
    let message: String?
    let timestamp: Date

    var isSessionStateEvent: Bool {
        switch kind {
        case .sessionStarted, .turnStarted, .turnCompleted, .waitingForUser, .sessionEnded:
            return true
        case .permissionRequested, .notification, .permissionDenied:
            return false
        }
    }

    var stopEvent: AgentStopEvent? {
        guard kind == .turnCompleted || kind == .sessionEnded else {
            return nil
        }

        return AgentStopEvent(
            agent: agent,
            eventName: eventName,
            paneID: paneID,
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            message: message,
            timestamp: timestamp
        )
    }

    var notificationEvent: AgentNotificationEvent? {
        let notificationKind: AgentNotificationEventKind
        switch kind {
        case .permissionRequested:
            notificationKind = .permissionRequested
        case .notification:
            notificationKind = .notification
        case .permissionDenied:
            notificationKind = .permissionDenied
        default:
            return nil
        }

        return AgentNotificationEvent(
            kind: notificationKind,
            agent: agent,
            eventName: eventName,
            paneID: paneID,
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            message: message,
            timestamp: timestamp
        )
    }

    var deduplicationKey: String {
        [
            String(describing: kind),
            agent.rawValue,
            eventName,
            paneID?.uuidString ?? "",
            sessionID ?? "",
            workingDirectory ?? "",
            message ?? "",
        ].joined(separator: "\u{1F}")
    }
}

struct AgentSessionSnapshot: Equatable, Identifiable {
    let id: String
    let agent: AgentKind
    let paneID: PaneID
    let sessionID: String?
    let displayState: AgentSessionDisplayState
    let paneTitle: String
    let workingDirectory: String?
    let message: String?
    let lastEventAt: Date
    let isUnread: Bool
}

@MainActor
final class AgentSessionStore {
    static let shared = AgentSessionStore()
    static let didChangeNotification = Notification.Name("AgentSessionStore.didChangeNotification")

    private struct SessionRecord {
        var id: String
        var agent: AgentKind
        var paneID: PaneID
        var sessionID: String?
        var displayState: AgentSessionDisplayState
        var workingDirectory: String?
        var message: String?
        var lastEventAt: Date
        var isUnread: Bool

        var isClearableWhenRead: Bool {
            displayState == .sessionEnded
        }
    }

    private var sessions: [String: SessionRecord] = [:]

    private init() {}

    func handle(_ event: AgentSessionEvent) {
        guard event.isSessionStateEvent else {
            return
        }
        guard let paneID = event.paneID else {
            return
        }

        let id = sessionID(for: event.agent, paneID: paneID, sessionID: event.sessionID)
        var record =
            sessions[id]
            ?? SessionRecord(
                id: id,
                agent: event.agent,
                paneID: paneID,
                sessionID: event.sessionID,
                displayState: .running,
                workingDirectory: nil,
                message: nil,
                lastEventAt: event.timestamp,
                isUnread: false
            )

        record.sessionID = event.sessionID ?? record.sessionID
        record.workingDirectory = event.workingDirectory ?? record.workingDirectory
        record.message = event.message ?? record.message
        record.lastEventAt = event.timestamp

        switch event.kind {
        case .sessionStarted:
            record.displayState = .running
        case .turnStarted:
            record.displayState = .running
        case .turnCompleted:
            record.displayState = .turnCompleted
            record.isUnread = true
        case .waitingForUser:
            record.displayState = .waitingForUser
            record.isUnread = true
        case .permissionRequested, .notification, .permissionDenied:
            break
        case .sessionEnded:
            record.displayState = .sessionEnded
        }

        sessions[id] = record
        postDidChange()
    }

    func snapshots(forPaneIDs paneIDs: Set<PaneID>) -> [AgentSessionSnapshot] {
        sortedSnapshots(
            sessions.values
                .filter { paneIDs.contains($0.paneID) }
                .map(snapshot(for:))
        )
    }

    func unreadSessionCount(forPaneIDs paneIDs: Set<PaneID>) -> Int {
        sessions.values.filter { paneIDs.contains($0.paneID) && $0.isUnread }.count
    }

    func markRead(forPaneIDs paneIDs: Set<PaneID>) {
        var didChange = false
        for (id, record) in sessions where paneIDs.contains(record.paneID) && record.isUnread {
            var updatedRecord = record
            updatedRecord.isUnread = false
            sessions[id] = updatedRecord
            didChange = true
        }

        if didChange {
            postDidChange()
        }
    }

    func clearEnded(forPaneIDs paneIDs: Set<PaneID>) {
        let removableIDs = sessions.values
            .filter { paneIDs.contains($0.paneID) && !$0.isUnread && $0.isClearableWhenRead }
            .map(\.id)
        guard !removableIDs.isEmpty else {
            return
        }

        for id in removableIDs {
            sessions.removeValue(forKey: id)
        }
        postDidChange()
    }

    func removeSessions(forPaneID paneID: PaneID) {
        let countBefore = sessions.count
        sessions = sessions.filter { _, record in record.paneID != paneID }
        if sessions.count != countBefore {
            postDidChange()
        }
    }

    func reset() {
        guard !sessions.isEmpty else {
            return
        }

        sessions.removeAll()
        postDidChange()
    }

    private func snapshot(for record: SessionRecord) -> AgentSessionSnapshot {
        let paneSnapshot = AgentPaneRegistry.shared.snapshot(for: record.paneID)
        return AgentSessionSnapshot(
            id: record.id,
            agent: record.agent,
            paneID: record.paneID,
            sessionID: record.sessionID,
            displayState: record.displayState,
            paneTitle: paneSnapshot?.title ?? "Pane",
            workingDirectory: record.workingDirectory ?? paneSnapshot?.workingDirectory,
            message: record.message,
            lastEventAt: record.lastEventAt,
            isUnread: record.isUnread
        )
    }

    private func sortedSnapshots(_ snapshots: [AgentSessionSnapshot]) -> [AgentSessionSnapshot] {
        snapshots.sorted { lhs, rhs in
            let lhsRank = sortRank(for: lhs)
            let rhsRank = sortRank(for: rhs)
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }

            return lhs.lastEventAt > rhs.lastEventAt
        }
    }

    private func sortRank(for snapshot: AgentSessionSnapshot) -> Int {
        if snapshot.displayState == .waitingForUser {
            return 0
        }
        if snapshot.isUnread {
            return 1
        }

        switch snapshot.displayState {
        case .running:
            return 2
        case .turnCompleted:
            return 3
        case .sessionEnded:
            return 4
        case .waitingForUser:
            return 0
        }
    }

    private func sessionID(for agent: AgentKind, paneID: PaneID, sessionID: String?) -> String {
        [paneID.uuidString, agent.rawValue, sessionID ?? ""].joined(separator: ":")
    }

    private func postDidChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}
