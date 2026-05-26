import Darwin
import Foundation

@MainActor
final class AgentEventMonitor {
    static let shared = AgentEventMonitor()

    private let parser = AgentEventParser()
    private let socketURL: URL
    private let eventQueue = DispatchQueue(label: "com.zolazhou.santty.agent-events")
    private var acceptSource: DispatchSourceRead?
    private var serverFileDescriptor: CInt = -1
    private var recentEvents: [String: Date] = [:]

    init(socketURL: URL = AgentIntegrationPaths.eventSocketURL) {
        self.socketURL = socketURL
    }

    func start() {
        guard acceptSource == nil else {
            return
        }

        installSocketEventSource()
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        serverFileDescriptor = -1
    }

    func handle(_ event: AgentSessionEvent) {
        guard isEnabled(for: event.agent),
            let paneID = event.paneID,
            AgentPaneRegistry.shared.snapshot(for: paneID) != nil,
            shouldDeliver(event)
        else {
            return
        }

        if event.isSessionStateEvent {
            AgentSessionStore.shared.handle(event)
        }
        if let stopEvent = event.stopEvent {
            AgentNotifier.shared.notifyStop(stopEvent)
        }
        if let notificationEvent = event.notificationEvent {
            AgentNotifier.shared.notify(notificationEvent)
        }
    }

    private func installSocketEventSource() {
        do {
            try prepareSocketDirectory()
            try removeStaleSocket()
        } catch {
            return
        }

        let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            return
        }
        _ = fcntl(fileDescriptor, F_SETFL, O_NONBLOCK)

        guard bindSocket(fileDescriptor) else {
            close(fileDescriptor)
            return
        }

        chmod(socketURL.path, mode_t(0o600))

        guard listen(fileDescriptor, 16) == 0 else {
            close(fileDescriptor)
            try? removeStaleSocket()
            return
        }

        serverFileDescriptor = fileDescriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: fileDescriptor, queue: eventQueue)
        source.setEventHandler(handler: Self.makeAcceptHandler(
            monitor: self,
            fileDescriptor: fileDescriptor
        ))
        source.setCancelHandler(handler: Self.makeCancelHandler(
            fileDescriptor: fileDescriptor,
            socketPath: socketURL.path
        ))
        acceptSource = source
        source.resume()
    }

    private func prepareSocketDirectory() throws {
        try FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    private func removeStaleSocket() throws {
        guard FileManager.default.fileExists(atPath: socketURL.path) else {
            return
        }

        try FileManager.default.removeItem(at: socketURL)
    }

    private func bindSocket(_ fileDescriptor: CInt) -> Bool {
        let path = socketURL.path
        guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            return false
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let copied = path.withCString { pathPointer in
            withUnsafeMutablePointer(to: &address.sun_path) { sunPathPointer in
                sunPathPointer.withMemoryRebound(to: CChar.self, capacity: 104) { destination in
                    strncpy(destination, pathPointer, 103)
                }
            }
        }
        _ = copied

        return withUnsafePointer(to: &address) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(
                    fileDescriptor,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                ) == 0
            }
        }
    }

    nonisolated private func handleClient(fileDescriptor: CInt) {
        defer { close(fileDescriptor) }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let bytesRead = read(fileDescriptor, &buffer, buffer.count)
            if bytesRead <= 0 {
                break
            }
            data.append(contentsOf: buffer[0..<bytesRead])
            if data.count > 65_536 {
                return
            }
        }

        guard let message = String(data: data, encoding: .utf8) else {
            return
        }

        let lines = message.split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty else {
            return
        }

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            for line in lines {
                if let event = parser.parseSessionEventLine(String(line)) {
                    handle(event)
                }
            }
        }
    }

    private func isEnabled(for agent: AgentKind) -> Bool {
        switch agent {
        case .claude:
            AgentNotificationSettings.isClaudeCodeEnabled
        case .codex:
            AgentNotificationSettings.isCodexEnabled
        }
    }

    private func shouldDeliver(_ event: AgentSessionEvent) -> Bool {
        let now = Date()
        recentEvents = recentEvents.filter { now.timeIntervalSince($0.value) < 30 }

        let key = event.deduplicationKey
        if let lastSeen = recentEvents[key],
            now.timeIntervalSince(lastSeen) < 2
        {
            return false
        }

        recentEvents[key] = now
        return true
    }

    private nonisolated static func makeAcceptHandler(
        monitor: AgentEventMonitor,
        fileDescriptor: CInt
    ) -> DispatchWorkItem {
        DispatchWorkItem { [weak monitor] in
            while true {
                let clientFileDescriptor = accept(fileDescriptor, nil, nil)
                guard clientFileDescriptor >= 0 else {
                    return
                }

                monitor?.handleClient(fileDescriptor: clientFileDescriptor)
            }
        }
    }

    private nonisolated static func makeCancelHandler(
        fileDescriptor: CInt,
        socketPath: String
    ) -> DispatchWorkItem {
        DispatchWorkItem {
            close(fileDescriptor)
            unlink(socketPath)
        }
    }
}
