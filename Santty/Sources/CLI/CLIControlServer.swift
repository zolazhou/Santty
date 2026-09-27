import Darwin
import Foundation

@MainActor
final class CLIControlServer {
    static let shared = CLIControlServer()
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "cliAccessEnabled") }
        set {
            UserDefaults.standard.set(newValue, forKey: "cliAccessEnabled")
            if newValue { shared.start() } else { shared.stop() }
        }
    }

    weak var workspace: WorkspaceViewController?
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "santty.cli")

    func start() {
        guard Self.isEnabled, source == nil else { return }
        do {
            try CLITransport.prepareDirectory()
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw CLITransport.systemError("Create socket") }
            var installed = false
            defer { if !installed { close(fd) } }
            CLITransport.configure(fd)
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            let path = CLITransport.socketPath
            // A PID-specific path cannot belong to another live instance.
            unlink(path)
            try CLITransport.withAddress(path) { address, length in
                guard bind(fd, address, length) == 0 else {
                    throw CLITransport.systemError("Bind socket")
                }
            }
            guard chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
                unlink(path)
                throw CLITransport.systemError("Listen on socket")
            }
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler(handler: Self.acceptHandler(server: self, fd: fd))
            // Unlink synchronously in stop(), so a rapid re-enable cannot have
            // its new socket removed by the previous source's cancel handler.
            source.setCancelHandler(handler: Self.cancelHandler(fd: fd))
            self.source = source
            installed = true
            source.resume()
        } catch {
            NSLog("Santty CLI: %@", error.localizedDescription)
        }
    }

    private nonisolated static func cancelHandler(fd: CInt) -> DispatchWorkItem {
        DispatchWorkItem { close(fd) }
    }

    private nonisolated static func acceptHandler(server: CLIControlServer, fd: CInt)
        -> DispatchWorkItem
    {
        DispatchWorkItem { [weak server] in
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                CLITransport.configure(client)
                do {
                    try CLITransport.verifyPeer(client)
                    let data = try CLITransport.readLine(client, limit: 16_384)
                    let request = try JSONDecoder().decode(CLIRequest.self, from: data)
                    try request.validate()
                    let processes =
                        request.command == "list"
                        ? AgentForegroundProcessInspector.currentProcessTable() : []
                    Task { @MainActor [weak server] in
                        var response: CLIResponse
                        do {
                            guard let server, Self.isEnabled, let workspace = server.workspace
                            else {
                                throw CLIError(
                                    "CLI access is disabled or the workspace is unavailable.")
                            }
                            response = try workspace.handleCLIRequest(request)
                            if var tabs = response.tabs {
                                for t in tabs.indices {
                                    for p in tabs[t].panes.indices {
                                        let group = tabs[t].panes[p].foregroundProcessGroupID
                                        tabs[t].panes[p].processes =
                                            processes
                                            .filter { $0.processGroupID == group }
                                            .map {
                                                CLIProcess(pid: $0.processID, command: $0.command)
                                            }
                                    }
                                }
                                response.tabs = tabs
                            }
                        } catch { response = CLIResponse(error: error.localizedDescription) }
                        let result = response
                        DispatchQueue.global(qos: .utility).async {
                            defer { close(client) }
                            try? CLITransport.write(result, to: client)
                        }
                    }
                } catch {
                    try? CLITransport.write(
                        CLIResponse(error: error.localizedDescription), to: client)
                    close(client)
                }
            }
        }
    }

    func stop() {
        guard let source else { return }
        unlink(CLITransport.socketPath)
        source.cancel()
        self.source = nil
    }
}
