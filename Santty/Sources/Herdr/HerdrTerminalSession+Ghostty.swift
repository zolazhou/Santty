import Foundation
import GhosttyTerminal

/// All legacy surface types stay here; the shared Herdr state machine can
/// also be compiled into the native-VT lab without linking GhosttyKit.
extension HerdrTerminalSession {
    convenience init(paneID: UUID, cwd: String?, binding: HerdrTerminalBinding?,
                     remote: HerdrRemote? = nil, runPending: Bool = false,
                     viewerOnly: Bool = false, client: HerdrCoreClient = .shared) {
        self.init(paneID: paneID, cwd: cwd, binding: binding, remote: remote,
                  runPending: runPending, viewerOnly: viewerOnly, client: client,
                  outputFactory: { write, resize in LegacyHerdrOutput(write: write, resize: resize) },
                  controlSocketPath: CLITransport.socketPath,
                  displayColors: {
                      guard let theme = TerminalDefaults.themeDefinition else { return [:] }
                      func hex(_ value: String) -> String { value.hasPrefix("#") ? value : "#" + value }
                      return ["fg": hex(theme.foreground), "bg": hex(theme.background),
                              "cursor": hex(theme.cursorColor ?? theme.foreground)]
                  })
    }

    var memory: InMemoryTerminalSession {
        // Only the convenience initializer above is used by legacy panes.
        (output as! LegacyHerdrOutput).memory
    }
}

private final class LegacyHerdrOutput: TerminalStreamEndpoint, @unchecked Sendable {
    let memory: InMemoryTerminalSession
    init(write: @escaping @Sendable (Data) -> Void,
         resize: @escaping @Sendable (TerminalStreamViewport) -> Void) {
        memory = InMemoryTerminalSession(write: write, resize: { value in
            resize(.init(columns: value.columns, rows: value.rows,
                         widthPixels: value.widthPixels, heightPixels: value.heightPixels,
                         cellWidthPixels: value.cellWidthPixels, cellHeightPixels: value.cellHeightPixels))
        })
    }
    func receive(_ data: Data) { memory.receive(data) }
    func waitForPendingOutput() -> Bool { memory.waitForPendingOutput() }
    func reset() { memory.receive("\u{1b}c\u{1b}[3J") }
}
