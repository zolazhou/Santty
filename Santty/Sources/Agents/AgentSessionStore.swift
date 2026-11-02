import Foundation

enum AgentSessionDisplayState: Equatable {
    case running, turnCompleted, waitingForUser, idle, failed, unknown, sessionEnded
}

struct AgentSessionSnapshot: Equatable, Identifiable {
    let id: String
    let agent: AgentKind
    let displayState: AgentSessionDisplayState
    let paneTitle: String
    let workingDirectory: String?
    let message: String?
    let lastEventAt: Date
    let isUnread: Bool
    let backendStatusAvailable: Bool
    let binding: HerdrTerminalBinding
    let revision: UInt64
    var recordID: String? = nil
}

struct AgentMessage: Equatable, Identifiable {
    let id: String
    let agent: AgentKind
    let title: String
    let body: String?
    let context: String
    let timestamp: Date
    var isUnread: Bool
    let binding: HerdrTerminalBinding
    let recordID: String
    let revision: UInt64
    let state: AgentSessionDisplayState
}

@MainActor
final class AgentSessionStore {
    static let didChangeNotification = Notification.Name("AgentSessionStore.didChangeNotification")
    private struct Record {
        let binding: HerdrTerminalBinding
        var agent: AgentKind
        var word: String?
        var title: String
        var cwd: String
        var message: String?
        var state: AgentSessionDisplayState
        var available: Bool
        var unread: Bool
        var revision: UInt64
        var updated: Date
    }
    private var records: [String: Record] = [:]
    private var revision: UInt64 = 0
    private(set) var messages: [AgentMessage] = []
    var onNotification: ((AgentMessage) -> Void)?
    var isTargetVisible: ((HerdrTerminalBinding) -> Bool)?
    var context: ((HerdrTerminalBinding) -> String?)?

    static func key(_ binding: HerdrTerminalBinding) -> String { binding.coreID + "/" + binding.address }
    private func key(_ binding: HerdrTerminalBinding, _ record: String) -> String {
        Self.key(binding) + "#" + record
    }

    var snapshots: [AgentSessionSnapshot] {
        records.filter { $0.value.state != .sessionEnded }.map { id, record in snapshot(id, record) }.sorted {
            if $0.isUnread != $1.isUnread { return $0.isUnread }
            if ($0.displayState == .waitingForUser || $0.displayState == .failed) != ($1.displayState == .waitingForUser || $1.displayState == .failed) {
                return $0.displayState == .waitingForUser || $0.displayState == .failed
            }
            return $0.lastEventAt == $1.lastEventAt ? $0.id < $1.id : $0.lastEventAt > $1.lastEventAt
        }
    }
    var messageSnapshots: [AgentSessionSnapshot] {
        messages.reversed().map { message in
            .init(id: message.id, agent: message.agent, displayState: message.state,
                  paneTitle: context?(message.binding) ?? message.context, workingDirectory: nil,
                  message: [message.title, message.body].compactMap { $0 }.joined(separator: ": "),
                  lastEventAt: message.timestamp, isUnread: message.isUnread,
                  backendStatusAvailable: records[message.recordID]?.available == true,
                  binding: message.binding, revision: message.revision, recordID: message.recordID)
        }
    }
    var unreadCount: Int { messages.filter(\.isUnread).count }

    private func snapshot(_ id: String, _ record: Record) -> AgentSessionSnapshot {
        .init(id: id, agent: record.agent, displayState: record.state,
              paneTitle: context?(record.binding) ?? record.title, workingDirectory: record.cwd,
              message: record.message, lastEventAt: record.updated, isUnread: record.unread,
              backendStatusAvailable: record.available, binding: record.binding, revision: record.revision)
    }

    func replaceSnapshot(_ terminals: [(HerdrTerminalBinding, HerdrCoreTerminal)], now: Date = Date()) {
        let before = snapshots, oldMessages = messages
        let active = Set(terminals.map { Self.key($0.0) })
        for id in Array(records.keys) where !active.contains(Self.key(records[id]!.binding)) {
            records[id]?.available = false
        }
        for (binding, terminal) in terminals { apply(terminal, binding: binding, baseline: true, now: now, publish: false) }
        publishIfChanged(before, oldMessages)
    }

    func apply(_ terminal: HerdrCoreTerminal, binding: HerdrTerminalBinding, baseline: Bool = false,
               now: Date = Date(), publish: Bool = true) {
        let before = publish ? snapshots : [], oldMessages = publish ? messages : []
        var reports = terminal.records ?? [:]
        if let status = terminal.status { reports[""] = status }
        let live = terminal.state == "live" && terminal.reason == nil
        let ids = Set(reports.keys.map { key(binding, $0) })
        for id in Array(records.keys) where Self.key(records[id]!.binding) == Self.key(binding) && (!live || !ids.contains(id)) {
            if records[id]?.state != .sessionEnded {
                revision += 1
                records[id]?.revision = revision
                records[id]?.updated = now
            }
            records[id]?.state = .sessionEnded
            records[id]?.word = nil
            records[id]?.available = live
        }
        if live {
            for (reportID, status) in reports {
                let id = key(binding, reportID), old = records[id]
                let app = status.app?.trimmingCharacters(in: .whitespacesAndNewlines)
                let kind = AgentKind(rawValue: app?.isEmpty == false ? app! : "agent")
                let changed = old?.word != status.state || old?.agent != kind
                if changed { revision += 1 }
                let state: AgentSessionDisplayState = switch status.state {
                case "working": .running
                case "blocked": .waitingForUser
                case "error": .failed
                case "done": old?.unread == true ? .turnCompleted : .idle
                case "idle": .idle
                default: .unknown
                }
                let title = [terminal.title.isEmpty ? nil : terminal.title, binding.routedAddress,
                             reportID.isEmpty ? nil : reportID].compactMap { $0 }.joined(separator: " · ")
                let summary = [status.title.map { String($0.prefix(4096)) }, status.msg.map { String($0.prefix(16384)) }]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ": ")
                var record = Record(binding: binding, agent: kind, word: status.state,
                    title: title, cwd: terminal.foreground?.cwd ?? terminal.cwd,
                    message: summary.isEmpty ? nil : summary,
                    state: state, available: true, unread: old?.unread ?? false,
                    revision: changed ? revision : old?.revision ?? revision, updated: changed ? now : old?.updated ?? now)
                if !baseline, changed, ["blocked", "error", "done"].contains(status.state) {
                    let state: AgentSessionDisplayState = status.state == "blocked" ? .waitingForUser : status.state == "error" ? .failed : .turnCompleted
                    let verb = status.state == "done" ? "finished" : status.state == "error" ? "reported an error" : "needs attention"
                    let message = AgentMessage(id: UUID().uuidString, agent: record.agent,
                        title: record.agent.displayName + " " + verb, body: record.message,
                        context: context?(binding) ?? title, timestamp: now, isUnread: true,
                        binding: binding, recordID: id, revision: record.revision, state: state)
                    record.unread = true
                    record.state = state
                    records[id] = record
                    messages.append(message)
                    if messages.count > 256 { messages.removeFirst(messages.count - 256) }
                    if isTargetVisible?(binding) != true { onNotification?(message) }
                }
                records[id] = record
            }
        }
        // Retain unread and live entries; only evict old ended records.
        if records.count > 1024 {
            let ended = records.filter { $0.value.state == .sessionEnded && !$0.value.unread }.sorted { $0.value.updated < $1.value.updated }
            for (id, _) in ended.prefix(records.count - 1024) { records.removeValue(forKey: id) }
        }
        if publish { publishIfChanged(before, oldMessages) }
    }

    func markUnavailable(coreID: String? = nil) {
        guard records.values.contains(where: { $0.available && (coreID == nil || $0.binding.coreID == coreID) }) else { return }
        let before = snapshots
        for id in Array(records.keys) where coreID == nil || records[id]?.binding.coreID == coreID { records[id]?.available = false }
        publishIfChanged(before, messages)
    }

    func remove(_ binding: HerdrTerminalBinding) {
        let before = snapshots
        for id in Array(records.keys) where Self.key(records[id]!.binding) == Self.key(binding) {
            records[id]?.state = .sessionEnded
            records[id]?.available = false
        }
        publishIfChanged(before, messages)
    }

    func markViewed(_ observed: [AgentSessionSnapshot]) {
        let before = snapshots, oldMessages = messages
        for item in observed {
            guard var record = records[item.id], record.available, record.revision == item.revision else { continue }
            record.unread = false
            if record.state == .turnCompleted { record.state = .idle }
            records[item.id] = record
            for i in messages.indices where messages[i].recordID == item.id && messages[i].revision <= item.revision { messages[i].isUnread = false }
        }
        publishIfChanged(before, oldMessages)
    }

    func acknowledge(_ item: AgentSessionSnapshot) {
        let before = snapshots, oldMessages = messages
        if let index = messages.firstIndex(where: { $0.id == item.id && $0.revision == item.revision }) {
            messages[index].isUnread = false
            let message = messages[index]
            if var record = records[message.recordID] {
                record.unread = messages.contains { $0.recordID == message.recordID && $0.isUnread }
                if !record.unread, record.state == .turnCompleted { record.state = .idle }
                records[message.recordID] = record
            }
        } else if var record = records[item.id], record.revision == item.revision {
            record.unread = false
            if record.state == .turnCompleted { record.state = .idle }
            records[item.id] = record
            for index in messages.indices where messages[index].recordID == item.id && messages[index].revision <= item.revision {
                messages[index].isUnread = false
            }
        }
        publishIfChanged(before, oldMessages)
    }

    func clearEnded() {
        let before = snapshots, oldMessages = messages
        records = records.filter { $0.value.state != .sessionEnded || $0.value.unread }
        messages.removeAll { !$0.isUnread }
        publishIfChanged(before, oldMessages)
    }

    private func publishIfChanged(_ before: [AgentSessionSnapshot], _ oldMessages: [AgentMessage]) {
        if before != snapshots || oldMessages != messages {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }
}
