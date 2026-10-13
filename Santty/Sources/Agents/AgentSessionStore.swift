import Foundation

enum AgentSessionDisplayState: Equatable {
    case running, turnCompleted, waitingForUser, idle, unknown, sessionEnded
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
    var backendStatusAvailable = true
    let binding: HerdrPaneBinding
}

struct AgentMessage: Equatable, Identifiable {
    let id: String
    let paneID: PaneID
    let kind: UInt32
    var title: String
    var body: String?
    let timestamp: Date
    var isUnread: Bool
    let binding: HerdrPaneBinding
    let agent: AgentKind
    let context: String
    var sound = false
}

@MainActor
final class AgentSessionStore {
    static let shared = AgentSessionStore()
    static let didChangeNotification = Notification.Name("AgentSessionStore.didChangeNotification")

    private struct Record {
        var snapshot: AgentSessionSnapshot
        var sequence: UInt64
        var completion: UInt64?
        var notifiedCompletion: UInt64?
        var notifiedAttention: UInt64?
        var observedWorking = false
    }
    private var records: [String: Record] = [:]
    private(set) var messages: [AgentMessage] = []
    private var published: [String: AgentSessionSnapshot] = [:]
    private var publishedMessages: [AgentMessage] = []
    private var endpoint: HerdrEndpoint?
    private var identity: HerdrServiceIdentity?
    private var bootID: String?
    private var revision: UInt64 = 0
    private var latest: HerdrShellSnapshot?
    private var completions: [String: UInt64] = [:]
    private var pending: [(HerdrShellNotification, Date)] = []
    private var customNotices: [String: Date] = [:]
    var onNotification: ((AgentMessage) -> Void)?
    var isTargetVisible: ((HerdrPaneBinding) -> Bool)?

    var snapshots: [AgentSessionSnapshot] {
        records.values.map(\.snapshot).sorted {
            if $0.isUnread != $1.isUnread { return $0.isUnread }
            if $0.displayState == .waitingForUser, $1.displayState != .waitingForUser { return true }
            if $1.displayState == .waitingForUser, $0.displayState != .waitingForUser { return false }
            return $0.lastEventAt > $1.lastEventAt
        }
    }
    var messageSnapshots: [AgentSessionSnapshot] {
        messages.reversed().map { message in
            let record = records.values.first { $0.snapshot.paneID == message.paneID }?.snapshot
            return .init(id: message.id, agent: message.agent, paneID: message.paneID, sessionID: nil,
                displayState: message.kind == 0 ? .waitingForUser : message.kind == 1 ? .turnCompleted : .idle,
                paneTitle: message.context, workingDirectory: nil,
                message: [message.title, message.body].compactMap { $0 }.joined(separator: ": "),
                lastEventAt: message.timestamp, isUnread: message.isUnread,
                backendStatusAvailable: record?.backendStatusAvailable == true, binding: message.binding)
        }
    }
    var unreadCount: Int { messages.filter(\.isUnread).count }

    func binding(for paneID: PaneID) -> HerdrPaneBinding? {
        records.values.first { $0.snapshot.paneID == paneID }?.snapshot.binding
            ?? messages.last { $0.paneID == paneID }?.binding
    }

    func configure(_ endpoint: HerdrEndpoint) {
        guard self.endpoint != endpoint else { return }
        reset()
        self.endpoint = endpoint
    }

    func apply(_ snapshot: HerdrShellSnapshot, completions evidence: HerdrShellAgentCompletions?,
               endpoint: HerdrEndpoint, identity: HerdrServiceIdentity, now: Date = Date()) throws {
        try snapshot.validate()
        configure(endpoint)
        let sameBoot = self.identity == identity && bootID == snapshot.boot_id
        if sameBoot && snapshot.revision < revision { return }
        if !sameBoot {
            if self.identity != nil { markUnavailable(); pending.removeAll() }
            customNotices.removeAll()
            self.identity = identity; bootID = snapshot.boot_id
        }
        revision = snapshot.revision; latest = snapshot
        completions = evidence.flatMap { $0.boot_id == snapshot.boot_id && $0.revision == snapshot.revision ? $0.completions : nil } ?? [:]
        guard let agents = snapshot.agents else { markUnavailable(); return }
        let active = Set(agents.map { key(identity, snapshot.boot_id, $0.pane_id) })
        for id in records.keys where !active.contains(id) {
            guard let old = records[id] else { continue }
            records[id]?.snapshot = replacing(old.snapshot, state: .sessionEnded, available: false)
        }
        for agent in agents {
            let id = key(identity, snapshot.boot_id, agent.pane_id)
            let old = records[id]
            if let old, sameBoot, old.sequence > agent.state_change_seq { continue }
            guard let pane = snapshot.panes.first(where: { $0.pane_id == agent.pane_id }),
                  let binding = try? HerdrPaneBinding(endpoint: endpoint,
                    pane: .init(pane_id: pane.pane_id, terminal_id: nil, workspace_id: pane.workspace_id,
                                tab_id: pane.tab_id, serviceIdentity: identity)) else { continue }
            let kind = AgentKind(rawValue: agent.agent ?? agent.display_agent ?? "Agent")
            let explicitCompletion = completions[agent.pane_id] == agent.state_change_seq
            let completed = explicitCompletion || (old?.observedWorking == true && ["idle", "done"].contains(agent.agent_status))
            let completion = completed ? agent.state_change_seq : old?.completion
            let state: AgentSessionDisplayState
            switch agent.agent_status {
            case "working": state = .running
            case "blocked": state = .waitingForUser
            case "idle", "done": state = completed && old?.snapshot.isUnread == true ? .turnCompleted : .idle
            default: state = .unknown
            }
            let space = snapshot.workspaces.first { $0.workspace_id == pane.workspace_id }?.label ?? pane.workspace_id
            let tab = snapshot.tabs.first { $0.tab_id == pane.tab_id }?.label ?? pane.tab_id
            let context = "\(space) › \(tab) › \(pane.label ?? agent.title ?? pane.pane_id)"
            let changed = old?.sequence != agent.state_change_seq
            var record = Record(snapshot: .init(id: id, agent: kind, paneID: old?.snapshot.paneID ?? UUID(), sessionID: nil,
                displayState: state, paneTitle: context, workingDirectory: pane.foreground_cwd ?? pane.cwd,
                message: old?.snapshot.message, lastEventAt: changed ? now : old?.snapshot.lastEventAt ?? now,
                isUnread: old?.snapshot.isUnread ?? false, binding: binding), sequence: agent.state_change_seq,
                completion: completion, notifiedCompletion: old?.notifiedCompletion ?? (old == nil ? completion : nil),
                notifiedAttention: old?.notifiedAttention ?? (old == nil && state == .waitingForUser ? agent.state_change_seq : nil),
                observedWorking: state == .running)
            records[id] = record
            if old != nil, (changed && state == .waitingForUser) || (completed && old?.completion != completion) {
                let messageKind: UInt32 = state == .waitingForUser ? 0 : 1
                appendMessage(for: record, kind: messageKind, title: "\(kind.displayName) \(messageKind == 0 ? "needs attention" : "finished")", body: nil, now: now)
                record.snapshot = replacing(record.snapshot, state: messageKind == 1 ? .turnCompleted : state, unread: true)
                records[id] = record
            }
        }
        // Keep ended history bounded independently of the server's live-agent limit.
        if records.count > 1024 {
            let ended = records.values.filter { !active.contains($0.snapshot.id) }.sorted { $0.snapshot.lastEventAt < $1.snapshot.lastEventAt }
            for old in ended.prefix(records.count - 1024) { records.removeValue(forKey: old.snapshot.id) }
        }
        drainPending(now: now)
        postDidChange()
    }

    func receive(_ event: HerdrShellNotification, now: Date = Date()) {
        guard event.title.utf8.count <= 4096, (event.body?.utf8.count ?? 0) <= 16384 else { return }
        // The server can send a notification before its matching metadata update.
        if !consume(event, now: now), pending.count < 64 { pending.append((event, now.addingTimeInterval(5))) }
    }

    func drainPending(now: Date = Date()) {
        let work = pending; pending.removeAll()
        for (event, deadline) in work where now < deadline {
            if !consume(event, now: now) { pending.append((event, deadline)) }
        }
    }

    private func consume(_ event: HerdrShellNotification, now: Date) -> Bool {
        guard let latest, let paneID = event.pane_id,
              let pane = latest.panes.first(where: { $0.pane_id == paneID
                  && (event.workspace_id == nil || $0.workspace_id == event.workspace_id)
                  && (event.tab_id == nil || $0.tab_id == event.tab_id) }),
              let identity, let bootID else { return false }
        let id = key(identity, bootID, pane.pane_id)
        guard var record = records[id] else { return false }
        let status = latest.agents?.first { $0.pane_id == paneID }?.agent_status
        if event.kind == 0 {
            guard status == "blocked" else { return false }
            guard record.notifiedAttention != record.sequence else { return true }
            record.notifiedAttention = record.sequence
        } else if event.kind == 1 {
            guard ["idle", "done"].contains(status ?? ""), record.completion == record.sequence else { return false }
            guard record.notifiedCompletion != record.completion else { return true }
            record.notifiedCompletion = record.completion
        } else {
            let digest = [id, String(event.kind), event.title, event.body ?? ""].joined(separator: "\u{1F}")
            if let previous = customNotices[digest], now.timeIntervalSince(previous) < 2 { return true }
            if customNotices.count >= 64, let oldest = customNotices.min(by: { $0.value < $1.value })?.key { customNotices.removeValue(forKey: oldest) }
            customNotices[digest] = now
            customNotices = customNotices.filter { now.timeIntervalSince($0.value) < 2 }
        }
        var message = appendMessage(for: record, kind: event.kind, title: event.title, body: event.body, now: now)
        message.sound = event.sound != nil
        if let index = messages.firstIndex(where: { $0.id == message.id }) { messages[index].sound = message.sound }
        record.snapshot = replacing(record.snapshot, state: event.kind == 0 ? .waitingForUser : event.kind == 1 ? .turnCompleted : record.snapshot.displayState,
            unread: true, message: [event.title, event.body].compactMap { $0 }.joined(separator: ": "))
        records[id] = record
        if !((event.kind == 0 || event.kind == 1) && isTargetVisible?(record.snapshot.binding) == true) {
            onNotification?(message)
        }
        postDidChange()
        return true
    }

    @discardableResult
    private func appendMessage(for record: Record, kind: UInt32, title: String, body: String?, now: Date) -> AgentMessage {
        let id = "\(record.snapshot.id):\(kind):\(kind < 2 ? String(record.sequence) : UUID().uuidString)"
        if let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].title = title; messages[index].body = body
            return messages[index]
        }
        let message = AgentMessage(id: id, paneID: record.snapshot.paneID, kind: kind, title: title, body: body,
            timestamp: now, isUnread: true, binding: record.snapshot.binding, agent: record.snapshot.agent, context: record.snapshot.paneTitle)
        messages.append(message)
        if messages.count > 256 { messages.removeFirst(messages.count - 256) }
        return message
    }

    func markRead(forPaneIDs paneIDs: Set<PaneID>) {
        guard records.values.contains(where: { paneIDs.contains($0.snapshot.paneID) && $0.snapshot.isUnread })
            || messages.contains(where: { paneIDs.contains($0.paneID) && $0.isUnread }) else { return }
        for id in records.keys where records[id].map({ paneIDs.contains($0.snapshot.paneID) }) == true {
            if let old = records[id] { records[id]?.snapshot = replacing(old.snapshot, state: old.snapshot.displayState == .turnCompleted ? .idle : nil, unread: false) }
        }
        for index in messages.indices where paneIDs.contains(messages[index].paneID) { messages[index].isUnread = false }
        postDidChange()
    }

    func markViewed(_ bindings: [HerdrPaneBinding], snapshot: HerdrShellSnapshot) {
        guard snapshot.boot_id == bootID else { return }
        let ids = records.values.filter { record in
            bindings.contains { $0.endpoint == record.snapshot.binding.endpoint && $0.serviceIdentity == record.snapshot.binding.serviceIdentity && $0.paneID == record.snapshot.binding.paneID }
                && snapshot.agents?.contains(where: { $0.pane_id == record.snapshot.binding.paneID && $0.state_change_seq == record.sequence }) == true
        }.map { $0.snapshot.paneID }
        if !ids.isEmpty { markRead(forPaneIDs: Set(ids)) }
    }

    func clearEnded() {
        records = records.filter { $0.value.snapshot.isUnread || $0.value.snapshot.displayState != .sessionEnded }
        messages.removeAll { !$0.isUnread }
        postDidChange()
    }

    func markUnavailable() {
        for id in records.keys {
            if let old = records[id] { records[id]?.snapshot = replacing(old.snapshot, available: false) }
        }
        latest = nil
        pending.removeAll()
        postDidChange()
    }

    func reset() {
        endpoint = nil
        records.removeAll(); messages.removeAll(); pending.removeAll(); customNotices.removeAll()
        identity = nil; bootID = nil; latest = nil; completions.removeAll(); revision = 0
        postDidChange()
    }

    private func key(_ identity: HerdrServiceIdentity, _ boot: String, _ pane: String) -> String {
        (try? JSONEncoder().encode([String(identity.pid), String(identity.startedSeconds), String(identity.startedMicroseconds), boot, pane]).base64EncodedString()) ?? pane
    }

    private func replacing(_ old: AgentSessionSnapshot, state: AgentSessionDisplayState? = nil,
                           available: Bool? = nil, unread: Bool? = nil, message: String? = nil) -> AgentSessionSnapshot {
        .init(id: old.id, agent: old.agent, paneID: old.paneID, sessionID: old.sessionID,
              displayState: state ?? old.displayState, paneTitle: old.paneTitle, workingDirectory: old.workingDirectory,
              message: message ?? old.message, lastEventAt: old.lastEventAt, isUnread: unread ?? old.isUnread,
              backendStatusAvailable: available ?? old.backendStatusAvailable, binding: old.binding)
    }
    private func postDidChange() {
        let snapshots = records.mapValues(\.snapshot)
        guard snapshots != published || messages != publishedMessages else { return }
        published = snapshots; publishedMessages = messages
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}
